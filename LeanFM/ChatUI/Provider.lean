import Lean.Data.Json
import LeanFM.ChatUI.Store

namespace LeanFM.ChatUI.Provider

open Lean
open LeanFM.ChatUI.Store

structure Completion where
  text : String
  inputTokens : Nat
  cachedInputTokens : Nat
  outputTokens : Nat
  totalTokens : Nat
  failure : Option String := none
  checkpoint : Option String := none
deriving Repr

def zeroCompletion : Completion :=
  {text := "", inputTokens := 0, cachedInputTokens := 0, outputTokens := 0, totalTokens := 0}

-- Normalized project-owned pixels, never a provider-fetched URL.
structure ImageInput where
  data : String
  mediaType : String := "image/png"
  label : String := "Attached image"

def imageContent (provider : String) (image : ImageInput) : List Json :=
  if provider == "anthropic" then
    [Json.mkObj [("type", toJson "text"), ("text", toJson image.label)],
     Json.mkObj [("type", toJson "image"), ("source", Json.mkObj [
       ("type", toJson "base64"), ("media_type", toJson image.mediaType), ("data", toJson image.data)])]]
  else
    [Json.mkObj [("type", toJson "input_text"), ("text", toJson image.label)],
     Json.mkObj [("type", toJson "input_image"),
       ("image_url", toJson ("data:" ++ image.mediaType ++ ";base64," ++ image.data))]]

def userContent (provider prompt : String) (images : List ImageInput) : Json :=
  if images.isEmpty then toJson prompt else
    toJson (Json.mkObj [("type", toJson (if provider == "anthropic" then "text" else "input_text")),
      ("text", toJson prompt)] :: images.flatMap (imageContent provider))

def openAIInput (prompt : String) (images : List ImageInput) : String :=
  if images.isEmpty then (toJson prompt).compress else
    (toJson [Json.mkObj [("role", toJson "user"), ("content", userContent "openai" prompt images)]]).compress

structure ModelInfo where
  id : String
  model : String
  provider : String
  label : String
  maxOutputTokens : Nat := 4096
  contextWindowTokens : Nat := 0
  webSearch : Bool := false
deriving Repr

def providerName (provider : String) : String := if provider == "anthropic" then "Anthropic" else "OpenAI"

def providerBaseUrl (provider : String) : IO String := do
  if provider == "anthropic" then
    pure ((← IO.getEnv "LEANFM_ANTHROPIC_BASE_URL").getD "https://api.anthropic.com/v1")
  else pure ((← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1")

structure FunctionCall where
  callId : String
  name : String
  arguments : String
deriving Repr

abbrev ToolRunner := String → String → IO String
abbrev CancelCheck := IO Bool

/-- Server-owned numeric/allowlisted metadata only; never a provider body,
    prompt, tool arguments, credential, or arbitrary provider identifier. -/
structure RoundReport where
  round : Nat
  requestChars : Nat
  usage : Completion
  cumulative : Completion
  outcome : String
  toolCalls : Nat
  textChars : Nat

structure AgentHooks where
  beforeRequest : IO (Option String) := pure none
  onResponse : RoundReport → IO Unit := fun _ => pure ()
  /-- Reject a premature completion with server-owned validation feedback.
      Continuation keeps the original request, cancellation, usage and step budget. -/
  beforeFinish : String → IO (Option String) := fun _ => pure none

def curlConfigEscape (value : String) : String :=
  -- Image bodies can be megabytes: avoid allocating a list/string per byte.
  value.replace "\\" "\\\\" |>.replace "\"" "\\\"" |>.replace "\n" "\\n" |>.replace "\r" ""

def providerTimeoutSeconds : IO Nat := do
  let configured := (← IO.getEnv "LEANFM_PROVIDER_TIMEOUT_SECONDS").bind String.toNat?
  pure (max 30 (min 900 (configured.getD 300)))

def apiCallWithTimeout (timeoutSeconds : Nat) (method url key payload : String)
    (provider : String := "openai") : IO (Nat × String) := do
  if !validCredentialPairs [(provider, key)] then throw (IO.userError "invalid provider credential")
  let dataLine := if payload.isEmpty then "" else "data = \"" ++ curlConfigEscape payload ++ "\"\n"
  let authorization := if provider == "anthropic" then
    "header = \"x-api-key: " ++ curlConfigEscape key ++ "\"\nheader = \"anthropic-version: 2023-06-01\"\n"
    else "header = \"Authorization: Bearer " ++ curlConfigEscape key ++ "\"\n"
  let config := "url = \"" ++ url ++ "\"\nrequest = \"" ++ method ++ "\"\n" ++
    authorization ++
    (if payload.isEmpty then "" else "header = \"Content-Type: application/json\"\n") ++
    dataLine ++ "silent\nshow-error\n"
  let out ← IO.Process.output {
    cmd := "curl", args := #["--connect-timeout", "15", "--max-time", toString timeoutSeconds,
      "--config", "-", "--write-out", "\n__LEANFM_STATUS__%{http_code}"]
  } (some config)
  if out.exitCode == 28 then
    throw <| IO.userError ("provider_timeout:" ++ toString timeoutSeconds)
  if out.exitCode != 0 then
    throw <| IO.userError ("provider_transport_exit:" ++ toString out.exitCode)
  match out.stdout.splitOn "\n__LEANFM_STATUS__" with
  | [body, status] => pure (status.trimAscii.toString.toNat?.getD 0, body)
  | _ => pure (0, out.stdout)

def apiCall (method url key payload : String) (provider : String := "openai") : IO (Nat × String) := do
  apiCallWithTimeout (← providerTimeoutSeconds) method url key payload provider

def verifyKey (key : String) (provider : String := "openai") : IO (Except String Unit) := do
  if !validCredentialPairs [(provider, key)] then return .error "Supply a nonempty key of at most 4096 visible ASCII characters for a supported provider."
  try
    let baseUrl ← providerBaseUrl provider
    let (status, _) ← apiCall "GET" (baseUrl ++ "/models") key "" provider
    if status == 200 then pure (.ok ()) else pure (.error (providerName provider ++ " rejected the API key (HTTP " ++ toString status ++ ")."))
  catch _ => pure (.error (providerName provider ++ " key verification could not reach the provider."))

def jsonStringField? (json : Json) (key : String) : Option String :=
  ((json.getObjVal? key).bind Json.getStr?).toOption

def jsonNatField? (json : Json) (key : String) : Option Nat :=
  ((json.getObjVal? key).bind Json.getNat?).toOption

def jsonArrayField? (json : Json) (key : String) : Option (Array Json) :=
  ((json.getObjVal? key).bind Json.getArr?).toOption

def roundOutcome (json : Json) : String :=
  let reason := (jsonStringField? json "stop_reason").orElse
    (fun _ => jsonStringField? json "status") |>.getD "unknown"
  if ["completed", "incomplete", "failed", "end_turn", "stop_sequence", "tool_use",
      "pause_turn", "max_tokens", "model_context_window_exceeded", "refusal"].contains reason
    then reason else "unknown"

def listedModels (key : String) : IO (Except String (List String)) := do
  try
    let baseUrl := (← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1"
    let (status, body) ← apiCall "GET" (baseUrl ++ "/models") key ""
    if status != 200 then return .error ("OpenAI model discovery failed (HTTP " ++ toString status ++ ").")
    let some json := (Json.parse body).toOption | return .error "OpenAI model discovery returned invalid JSON."
    let some data := jsonArrayField? json "data" | return .error "OpenAI model discovery omitted its model list."
    return .ok (data.toList.filterMap fun item => jsonStringField? item "id")
  catch _ => pure (.error "OpenAI model discovery could not reach the provider.")

def jsonPath? (json : Json) (path : List String) : Option Json :=
  path.foldlM (fun value name => (value.getObjVal? name).toOption) json

def listedModelInfos (key provider : String) : IO (Except String (List ModelInfo)) := do
  try
    let baseUrl ← providerBaseUrl provider
    let query := if provider == "anthropic" then "?limit=100" else ""
    let (status, body) ← apiCall "GET" (baseUrl ++ "/models" ++ query) key "" provider
    if status != 200 then return .error (providerName provider ++ " model discovery failed (HTTP " ++ toString status ++ ").")
    let some json := (Json.parse body).toOption | return .error "Provider model discovery returned invalid JSON."
    let some data := jsonArrayField? json "data" | return .error "Provider model discovery omitted its model list."
    return .ok (data.toList.filterMap fun item => do
      let model ← jsonStringField? item "id"
      guard (jsonStringField? item "lifecycle" != some "retired")
      let maxOutput := (jsonNatField? item "max_tokens").getD 4096
      let webSearch := ((jsonPath? item ["capabilities", "server_tools", "web_search", "supported"]).bind
        (fun value => value.getBool?.toOption)).getD false
      pure { id := if provider == "anthropic" then "anthropic:" ++ model else model
           , model, provider, label := (jsonStringField? item "display_name").getD model
           , maxOutputTokens := min 20000 (if maxOutput > 0 then maxOutput else 4096)
           , contextWindowTokens := (jsonNatField? item "max_input_tokens").getD 0
           , webSearch })
  catch _ => pure (.error (providerName provider ++ " model discovery could not reach the provider."))

def responseText? (json : Json) : Option String :=
  jsonStringField? json "output_text" |>.orElse fun _ => do
    let output ← jsonArrayField? json "output"
    output.toList.findSome? fun item => do
      let content ← jsonArrayField? item "content"
      content.toList.findSome? fun part =>
        if jsonStringField? part "type" == some "output_text" then
          jsonStringField? part "text"
        else none

def completionFromJson? (json : Json) : Option Completion := do
  let text ← responseText? json
  let usage ← (json.getObjVal? "usage").toOption
  let inputTokens := (jsonNatField? usage "input_tokens").getD 0
  let outputTokens := (jsonNatField? usage "output_tokens").getD 0
  let totalTokens := (jsonNatField? usage "total_tokens").getD (inputTokens + outputTokens)
  let inputDetails := (usage.getObjVal? "input_tokens_details").toOption
  let cached := inputDetails.bind (jsonNatField? · "cached_tokens") |>.getD 0
  pure { text, inputTokens, cachedInputTokens := cached, outputTokens, totalTokens }

def responseId? (json : Json) : Option String := jsonStringField? json "id"

def functionCalls (json : Json) : List FunctionCall :=
  (jsonArrayField? json "output").getD #[] |>.toList.filterMap fun item => do
    guard (jsonStringField? item "type" == some "function_call")
    let callId ← jsonStringField? item "call_id"
    let name ← jsonStringField? item "name"
    let arguments ← jsonStringField? item "arguments"
    pure { callId, name, arguments }

def usageFromJson (json : Json) : Completion :=
  let usage := (json.getObjVal? "usage").toOption
  let inputTokens := usage.bind (jsonNatField? · "input_tokens") |>.getD 0
  let outputTokens := usage.bind (jsonNatField? · "output_tokens") |>.getD 0
  let totalTokens := usage.bind (jsonNatField? · "total_tokens") |>.getD (inputTokens + outputTokens)
  let inputDetails := usage.bind fun value => (value.getObjVal? "input_tokens_details").toOption
  let cached := inputDetails.bind (jsonNatField? · "cached_tokens") |>.getD 0
  { text := "", inputTokens, cachedInputTokens := cached, outputTokens, totalTokens }

def addUsage (left right : Completion) (text : String := "") : Completion :=
  { text
  , inputTokens := left.inputTokens + right.inputTokens
  , cachedInputTokens := left.cachedInputTokens + right.cachedInputTokens
  , outputTokens := left.outputTokens + right.outputTokens
  , totalTokens := left.totalTokens + right.totalTokens }

def workspaceToolsJson : String :=
  "[" ++ String.intercalate "," [
    "{\"type\":\"web_search\"}",
    "{\"type\":\"function\",\"name\":\"leanfm_reference\",\"description\":\"Read the live LeanFM language or workflow reference. This is read-only and never accepts a gate.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"section\":{\"type\":\"string\",\"enum\":[\"requirements\",\"implementation\",\"interrogation\",\"code-generation\"]}},\"required\":[\"section\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"leanfm_check\",\"description\":\"Compile the selected project's current spec/Requirements.lean, structurally validate its named RequirementSpec, and atomically derive spec/tasks.json for Grammar and Tasks. Read the file to find its actual constant name. Optionally check a typed ImplementationSpec and supply project TaskConstraint list constants. Runs isolated with no network or credentials; never accepts a gate.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"requirement\":{\"type\":\"string\"},\"implementation\":{\"type\":\"string\"},\"constraints\":{\"type\":\"string\"}},\"required\":[\"requirement\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_list\",\"description\":\"List tracked and untracked files below the authorized launch workspace.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_read\",\"description\":\"Read a UTF-8 text file below the authorized launch workspace.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_search\",\"description\":\"Search text below the authorized launch workspace using a literal query.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"query\",\"path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_patch\",\"description\":\"Apply a git-style unified diff with --- a/path, +++ b/path and @@ hunks below the authorized workspace. Hunk counts are recounted locally. Do not use Begin Patch syntax. After any rejection, switch to workspace_read and workspace_write; a second patch attempt stops the turn. Preserve unrelated changes.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"patch\":{\"type\":\"string\"}},\"required\":[\"patch\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_write\",\"description\":\"Create or replace one UTF-8 text file below the authorized launch workspace. Read it first when it exists and preserve unrelated work.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_check\",\"description\":\"Run an application check explicitly provided by this project. Read its Makefile or go.mod first. Use leanfm_check for LeanFM requirements and implementation specifications; build is not a substitute for that compiler.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\",\"enum\":[\"build\",\"check\",\"book\",\"http-check\",\"go-test\"]}},\"required\":[\"target\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_run_gif_generator\",\"description\":\"Run one self-contained project-local Python/Pillow generator in a filesystem/process sandbox and validate its GIF output. Use this when the user explicitly requests a real animated GIF.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"script_path\":{\"type\":\"string\"},\"output_path\":{\"type\":\"string\"}},\"required\":[\"script_path\",\"output_path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_transcode_mp4\",\"description\":\"Transcode a project-local animated GIF or WebM into a real broadly compatible H.264 MP4, validate it, and leave it below the project workspace for inline chat rendering. Use this when the user explicitly requests MP4.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"input_path\":{\"type\":\"string\"},\"output_path\":{\"type\":\"string\"}},\"required\":[\"input_path\",\"output_path\"],\"additionalProperties\":false}}"
  ] ++ "]"

/-- Fatal local failures stop both provider protocols before another paid round. -/
def fatalWorkspaceFailure? (result : String) : Option String :=
  if result.startsWith "FATAL: unchanged_unchecked_specification:" then
    some result
  else if result.startsWith "FATAL: repeated_failed_tool_call:" then
    some "A workspace operation or check failed again without verified recovery. LeanFM stopped before another paid request; exit codes and diagnostics remain in Project memory."
  else if result.startsWith "FATAL:" then
    some ("A local workspace operation cannot continue. LeanFM stopped before another paid request; no automatic model repair was attempted. " ++ result)
  else none

def toolOutputJson (callId output : String) : String :=
  "{\"type\":\"function_call_output\",\"call_id\":\"" ++ jsonEscape callId ++
  "\",\"output\":\"" ++ jsonEscape output ++ "\"}"

-- Provider messages and unknown identifiers may reflect secrets or request content.
-- Keep only known diagnostic identifiers, never the arbitrary response body.
def knownErrorIdentifier? (json : Json) (field : String) : Option String := do
  let value ← jsonStringField? json field
  guard (["credit_balance_exhausted", "organization_spend_limit_exceeded",
    "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
    "insufficient_quota", "slow_down", "rate_limit_exceeded", "rate_limit_error",
    "invalid_api_key", "authentication_error", "model_not_found",
    "context_length_exceeded", "invalid_request_error", "server_error",
    "content_filter"].contains value)
  pure value

def apiErrorDetail (status : Nat) (body : String) : String :=
  let error := (Json.parse body).toOption.bind fun json => (json.getObjVal? "error").toOption
  let errorType := error.bind (knownErrorIdentifier? · "type")
  let errorCode := error.bind (knownErrorIdentifier? · "code")
  let identifiers :=
    (errorType.map (fun value => "type=" ++ value)).toList ++
    (errorCode.map (fun value => "code=" ++ value)).toList
  let diagnosis := match errorCode, errorType with
    | some "credit_balance_exhausted", _ => "API credit balance exhausted; add credits in OpenAI billing."
    | some "organization_spend_limit_exceeded", _ => "OpenAI organization spend limit reached; review that limit in provider billing."
    | some "project_spend_limit_exceeded", _ => "OpenAI project spend limit reached; review that project's limit in provider billing."
    | some "organization_usage_limit_exceeded", _ => "OpenAI organization usage limit reached; review the provider usage limit."
    | some "insufficient_quota", _ | _, some "insufficient_quota" =>
        "OpenAI quota exhausted: available credits or an account limit blocked this request. Review provider billing and limits; the API has not supplied a remaining dollar balance."
    | some "slow_down", _ | some "rate_limit_exceeded", _ | _, some "rate_limit_error" =>
        "OpenAI rate limit reached; wait before sending another request. This does not establish credit exhaustion."
    | _, _ => "OpenAI rejected the request; inspect the HTTP status and any reported code."
  let detail := if identifiers.isEmpty then "" else "; " ++ String.intercalate "; " identifiers
  "OpenAI request failed (HTTP " ++ toString status ++ detail ++ "). " ++ diagnosis ++
    " No automatic paid retry was attempted."

/-- A successful HTTP exchange is not necessarily a completed model response.
    Check before interpreting output or executing any returned tools. -/
def responseFailure? (json : Json) : Option String :=
  match jsonStringField? json "status" with
  | some "completed" => none
  | some "incomplete" =>
      let reason := (json.getObjVal? "incomplete_details").toOption.bind
        (jsonStringField? · "reason")
      some <| (if reason == some "max_output_tokens" then
        "openai_output_limit: The model response hit its output or context token limit before completion. This is a per-response limit, not a reported API credit exhaustion."
      else if reason == some "content_filter" then
        "openai_content_filter: The provider stopped this response for content filtering."
      else "openai_response_incomplete: The provider returned an incomplete response.") ++
        " Partial answer text and tool calls were not applied. Reported usage is retained; no automatic paid retry was attempted."
  | some "failed" => some ("openai_response_failed: " ++ apiErrorDetail 200 json.compress)
  | _ => some "openai_response_not_completed: The provider did not return a completed response status. No answer or tool calls were applied and no automatic paid retry was attempted."

partial def completeAgentLoop (key baseUrl model instructions prompt previousId : String)
    (pending : List String) (runTool : ToolRunner) (cancelled : CancelCheck)
    (hooks : AgentHooks)
    (usage : Completion) (remaining : Nat) (images : List ImageInput := [])
    (roundOffset : Nat := 0) (budget : Nat := 16) (resumable : Bool := false) : IO (Except String Completion) := do
  if ← cancelled then return .error "agent_cancelled"
  if remaining == 0 then
    if resumable then return .ok {usage with checkpoint := some ((Json.mkObj [
      ("provider", toJson "openai"), ("previous_id", toJson previousId), ("pending", toJson pending)]).compress)}
    return .ok { usage with failure := some "The bounded workspace operation exhausted its tool rounds; no further request was sent." }
  if let some failure ← hooks.beforeRequest then return .ok { usage with failure := some failure }
  let input := if previousId.isEmpty then openAIInput prompt images else
    "[" ++ String.intercalate "," pending ++ "]"
  let continuation := if previousId.isEmpty then "" else
    ",\"previous_response_id\":\"" ++ jsonEscape previousId ++ "\""
  let payload := "{\"model\":\"" ++ jsonEscape model ++ "\",\"instructions\":\"" ++
    jsonEscape instructions ++ "\",\"input\":" ++ input ++ continuation ++
    ",\"tools\":" ++ workspaceToolsJson ++ ",\"tool_choice\":\"auto\"}"
  try
    let (status, body) ← apiCall "POST" (baseUrl ++ "/responses") key payload
    if status < 200 || status ≥ 300 then
      return .ok { usage with failure := some (apiErrorDetail status body) }
    let some json := (Json.parse body).toOption | return .ok { usage with failure := some "OpenAI returned invalid JSON to the workspace agent." }
    let nextUsage := addUsage usage (usageFromJson json)
    let calls := functionCalls json
    hooks.onResponse
      { round := roundOffset + budget + 1 - remaining
      , requestChars := payload.length
      , usage := usageFromJson json
      , cumulative := nextUsage
      , outcome := roundOutcome json
      , toolCalls := calls.length
      , textChars := ((responseText? json).getD "").length }
    if ← cancelled then return .error "agent_cancelled"
    if let some failure := responseFailure? json then
      return .ok { nextUsage with failure := some failure }
    if calls.isEmpty then
      match responseText? json with
      | some text =>
          if let some feedback ← hooks.beforeFinish text then
            if let some failure := fatalWorkspaceFailure? feedback then
              return .ok { nextUsage with failure := some failure }
            let some responseId := responseId? json
              | return .ok { nextUsage with failure := some "OpenAI omitted the response ID needed to continue specification repair." }
            let correction := (Json.mkObj [("role", toJson "user"), ("content", toJson feedback)]).compress
            return ← completeAgentLoop key baseUrl model instructions prompt responseId [correction]
              runTool cancelled hooks nextUsage (remaining - 1) images roundOffset budget resumable
          return .ok { nextUsage with text }
      | none => return .ok { nextUsage with failure := some "OpenAI returned neither workspace tool calls nor answer text." }
    let some responseId := responseId? json | return .ok { nextUsage with failure := some "OpenAI omitted the response ID needed to continue workspace tools." }
    let mut outputs : List String := []
    for call in calls do
      if ← cancelled then return .error "agent_cancelled"
      let result ← runTool call.name call.arguments
      if let some failure := fatalWorkspaceFailure? result then
        return .ok { nextUsage with failure := some failure }
      outputs := toolOutputJson call.callId result :: outputs
    completeAgentLoop key baseUrl model instructions prompt responseId outputs.reverse runTool cancelled hooks nextUsage (remaining - 1) images roundOffset budget resumable
  catch error =>
    let detail := error.toString
    let completedSteps := budget - remaining
    if detail.contains "provider_timeout:" then
      let timeoutSeconds ← providerTimeoutSeconds
      pure (.ok { usage with failure := some ("OpenAI workspace-agent request timed out after " ++
        toString timeoutSeconds ++
        " seconds; " ++ toString completedSteps ++ " tool rounds completed in this batch. " ++
        "The timed-out paid request was not retried automatically; usage of that unanswered request is unknown.") })
    else if detail.contains "provider_transport_exit:" then
      pure (.ok { usage with failure := some ("OpenAI workspace-agent transport failed before a response was received; " ++
        toString completedSteps ++ " tool rounds completed in this batch. The paid request was not retried automatically; usage of that unanswered request is unknown.") })
    else
      pure (.ok { usage with failure := some ("OpenAI workspace-agent failed before a response was received; " ++
        toString completedSteps ++ " tool rounds completed in this batch.") })

def anthropicErrorDetail (status : Nat) (body : String) : String :=
  let error := (Json.parse body).toOption.bind fun json => (json.getObjVal? "error").toOption
  let errorType := error.bind (jsonStringField? · "type")
  let knownType := errorType.filter (["invalid_request_error", "authentication_error", "billing_error",
    "permission_error", "not_found_error", "rate_limit_error", "api_error", "overloaded_error"].contains ·)
  let message := (error.bind (jsonStringField? · "message")).getD "" |>.toLower
  let diagnosis := if message.contains "credit balance is too low" then
      "Anthropic credit balance is too low; review Claude Console billing."
    else if message.contains "spend limit" then "Anthropic account or workspace spend limit reached."
    else match knownType with
      | some "billing_error" => "Anthropic billing or payment restriction; review Claude Console billing."
      | some "rate_limit_error" => "Anthropic rate limit reached; wait before sending another request."
      | some "authentication_error" => "Anthropic rejected this key; update the Anthropic credential."
      | some "overloaded_error" => "Anthropic is temporarily overloaded."
      | _ => "Anthropic rejected the request; inspect its HTTP status and error type."
  "Anthropic request failed (HTTP " ++ toString status ++
    (knownType.map ("; type=" ++ ·)).getD "" ++ "). " ++ diagnosis ++
    " No automatic paid retry was attempted."

def anthropicUsage (json : Json) : Completion :=
  let usage := (json.getObjVal? "usage").toOption
  let count := fun name => (usage.bind (jsonNatField? · name)).getD 0
  let cached := count "cache_read_input_tokens"
  let input := count "input_tokens" + count "cache_creation_input_tokens" + cached
  let output := count "output_tokens"
  { text := "", inputTokens := input, cachedInputTokens := cached, outputTokens := output, totalTokens := input + output }

def anthropicFailure? (json : Json) : Option String :=
  match jsonStringField? json "stop_reason" with
  | some "end_turn" | some "stop_sequence" | some "tool_use" | some "pause_turn" => none
  | some "max_tokens" | some "model_context_window_exceeded" =>
      some "anthropic_output_limit: The model response hit its output or context token limit. Its partial answer and tool calls were not applied; reported usage is retained and no automatic paid retry was attempted. This is not a reported credit exhaustion."
  | some "refusal" => some "anthropic_refusal: Anthropic declined this request. No automatic paid retry or model substitution was attempted."
  | _ => some "anthropic_response_not_completed: The provider returned no recognized terminal stop reason. No answer or tool calls were applied."

def anthropicText (json : Json) : String :=
  String.intercalate "\n" <| ((jsonArrayField? json "content").getD #[]).toList.filterMap fun block =>
    if jsonStringField? block "type" == some "text" then jsonStringField? block "text" else none

def anthropicCalls (json : Json) : List FunctionCall :=
  ((jsonArrayField? json "content").getD #[]).toList.filterMap fun block => do
    guard (jsonStringField? block "type" == some "tool_use")
    let callId ← jsonStringField? block "id"
    let name ← jsonStringField? block "name"
    let input ← (block.getObjVal? "input").toOption
    guard input.getObj?.toOption.isSome
    pure { callId, name, arguments := input.compress }

def anthropicTools (webSearch : Bool) : Json :=
  let tools := ((Json.parse workspaceToolsJson).toOption.bind fun value => value.getArr?.toOption).getD #[]
  let functions := tools.toList.filterMap fun tool => do
    guard (jsonStringField? tool "type" == some "function")
    let name ← jsonStringField? tool "name"
    let parameters ← (tool.getObjVal? "parameters").toOption
    pure <| Json.mkObj [("name", toJson name),
      ("description", toJson ((jsonStringField? tool "description").getD "")), ("input_schema", parameters)]
  toJson (functions ++ if webSearch then [Json.mkObj [("type", toJson "web_search_20250305"),
    ("name", toJson "web_search"), ("max_uses", toJson (3 : Nat))]] else [])

partial def completeAnthropicLoop (key baseUrl model instructions : String) (messages : List Json)
    (maxOutputTokens : Nat) (webSearch : Bool) (runTool : ToolRunner) (cancelled : CancelCheck)
    (hooks : AgentHooks) (usage : Completion) (remaining : Nat)
    (roundOffset : Nat := 0) (budget : Nat := 16) (resumable : Bool := false) : IO (Except String Completion) := do
  if ← cancelled then return .error "agent_cancelled"
  if remaining == 0 then
    if resumable then return .ok {usage with checkpoint := some ((Json.mkObj [
      ("provider", toJson "anthropic"), ("messages", toJson messages)]).compress)}
    return .ok { usage with failure := some "The bounded Anthropic operation exhausted its tool rounds; no further request was sent." }
  if let some failure ← hooks.beforeRequest then return .ok { usage with failure := some failure }
  let payload := (Json.mkObj [("model", toJson model), ("system", toJson instructions),
    ("cache_control", Json.mkObj [("type", toJson "ephemeral")]),
    ("max_tokens", toJson maxOutputTokens), ("messages", toJson messages), ("tools", anthropicTools webSearch)]).compress
  try
    let (status, body) ← apiCall "POST" (baseUrl ++ "/messages") key payload "anthropic"
    if status < 200 || status ≥ 300 then return .ok { usage with failure := some (anthropicErrorDetail status body) }
    let some json := (Json.parse body).toOption | return .ok { usage with failure := some "Anthropic returned invalid JSON; no tools or answer were applied." }
    let nextUsage := addUsage usage (anthropicUsage json)
    hooks.onResponse
      { round := roundOffset + budget + 1 - remaining
      , requestChars := payload.length
      , usage := anthropicUsage json
      , cumulative := nextUsage
      , outcome := roundOutcome json
      , toolCalls := (anthropicCalls json).length
      , textChars := (anthropicText json).length }
    if ← cancelled then return .error "agent_cancelled"
    if let some failure := anthropicFailure? json then return .ok { nextUsage with failure := some failure }
    let content := (jsonArrayField? json "content").getD #[]
    let assistant := Json.mkObj [("role", toJson "assistant"), ("content", toJson content)]
    let calls := anthropicCalls json
    let declaredCalls := content.toList.filter (fun block => jsonStringField? block "type" == some "tool_use")
    if calls.length != declaredCalls.length || (calls.map (·.callId)).eraseDups.length != calls.length then
      return .ok { nextUsage with failure := some "Anthropic returned malformed or duplicate tool calls; none were executed and no automatic paid retry was attempted." }
    if calls.isEmpty then
      if jsonStringField? json "stop_reason" == some "pause_turn" then
        return ← completeAnthropicLoop key baseUrl model instructions (messages ++ [assistant])
          maxOutputTokens webSearch runTool cancelled hooks nextUsage (remaining - 1) roundOffset budget resumable
      if jsonStringField? json "stop_reason" == some "tool_use" then
        return .ok { nextUsage with failure := some "Anthropic requested tool use without valid client tool calls; no completion was claimed and no automatic paid retry was attempted." }
      let text := anthropicText json
      if text.trimAscii.isEmpty then return .ok { nextUsage with failure := some "Anthropic returned no answer text or valid workspace tools; no automatic paid retry was attempted." }
      if let some feedback ← hooks.beforeFinish text then
        if let some failure := fatalWorkspaceFailure? feedback then
          return .ok { nextUsage with failure := some failure }
        return ← completeAnthropicLoop key baseUrl model instructions
          (messages ++ [assistant, Json.mkObj [("role", toJson "user"), ("content", toJson feedback)]])
          maxOutputTokens webSearch runTool cancelled hooks nextUsage (remaining - 1) roundOffset budget resumable
      return .ok { nextUsage with text }
    if jsonStringField? json "stop_reason" != some "tool_use" then
      return .ok { nextUsage with failure := some "Anthropic returned tool calls without a tool_use stop reason; they were not executed." }
    let mut results : List Json := []
    for call in calls do
      if ← cancelled then return .error "agent_cancelled"
      let result ← runTool call.name call.arguments
      if let some failure := fatalWorkspaceFailure? result then
        return .ok { nextUsage with failure := some failure }
      results := results ++ [Json.mkObj [("type", toJson "tool_result"), ("tool_use_id", toJson call.callId),
        ("content", toJson result), ("is_error", toJson (result.startsWith "ERROR:"))]]
    completeAnthropicLoop key baseUrl model instructions
      (messages ++ [assistant, Json.mkObj [("role", toJson "user"), ("content", toJson results)]])
      maxOutputTokens webSearch runTool cancelled hooks nextUsage (remaining - 1) roundOffset budget resumable
  catch error =>
    let timeout := error.toString.contains "provider_timeout:"
    return .ok { usage with failure := some (if timeout then
      "Anthropic request timed out; the paid request was not retried automatically and earlier completed workspace actions remain."
      else "Anthropic transport failed; the paid request was not retried automatically and earlier completed workspace actions remain.") }

def completeAgent (key instructions prompt model : String) (runTool : ToolRunner)
    (cancelled : CancelCheck := pure false) (provider : String := "openai")
    (maxOutputTokens : Nat := 20000) (webSearch : Bool := false)
    (hooks : AgentHooks := {}) (images : List ImageInput := [])
    (continuation : Option Json := none) (roundOffset : Nat := 0)
    (priorUsage : Completion := zeroCompletion) (resumable : Bool := false) (batchSize : Nat := 4) : IO (Except String Completion) := do
  let baseUrl ← providerBaseUrl provider
  let budget := if resumable then max 1 (min 16 batchSize) else 16
  let restart := continuation.any fun state => ((state.getObjVal? "restart").bind Json.getBool?).toOption == some true
  let state := if restart then none else continuation
  if let some current := state then
    if jsonStringField? current "provider" != some provider then return .error "Stored provider checkpoint is incompatible; no request was sent."
  if provider == "anthropic" then
    let messages := match state with
      | some current => (jsonArrayField? current "messages").getD #[] |>.toList
      | none => [Json.mkObj [("role", toJson "user"), ("content", userContent "anthropic" prompt images)]]
    if messages.isEmpty then return .error "Stored Anthropic checkpoint is empty; no request was sent."
    return ← completeAnthropicLoop key baseUrl model instructions
      messages
      maxOutputTokens webSearch runTool cancelled hooks
      priorUsage budget roundOffset budget resumable
  if provider != "openai" then return .error "Unsupported model provider; no request was sent."
  let previous := state.bind (jsonStringField? · "previous_id") |>.getD ""
  let pending := state.bind (jsonArrayField? · "pending") |>.getD #[] |>.toList |>.filterMap (·.getStr?.toOption)
  if state.isSome && previous.isEmpty then return .error "Stored OpenAI checkpoint is empty; no request was sent."
  completeAgentLoop key baseUrl model instructions prompt previous pending runTool cancelled hooks
    priorUsage budget images roundOffset budget resumable

def completeWithInstructionsTimeout (timeoutSeconds maxOutputTokens : Nat) (key instructions prompt model : String)
    (provider : String := "openai") (cancelled : CancelCheck := pure false)
    (hooks : AgentHooks := {}) : IO (Except String Completion) := do
  if ← cancelled then return .error "agent_cancelled"
  if let some failure ← hooks.beforeRequest then return .error failure
  let baseUrl ← providerBaseUrl provider
  let payload := if provider == "anthropic" then
    (Json.mkObj [("model", toJson model), ("system", toJson instructions), ("max_tokens", toJson maxOutputTokens),
      ("messages", toJson [Json.mkObj [("role", toJson "user"), ("content", toJson prompt)]])]).compress
    else "{\"model\":\"" ++ jsonEscape model ++ "\",\"instructions\":\"" ++ jsonEscape instructions ++ "\",\"input\":\"" ++ jsonEscape prompt ++ "\",\"max_output_tokens\":" ++ toString maxOutputTokens ++ "}"
  try
    let endpoint := if provider == "anthropic" then "/messages" else "/responses"
    let (status, body) ← apiCallWithTimeout timeoutSeconds "POST" (baseUrl ++ endpoint) key payload provider
    if status < 200 || status ≥ 300 then
      return .error (if provider == "anthropic" then anthropicErrorDetail status body else apiErrorDetail status body)
    let some json := (Json.parse body).toOption | return .error (providerName provider ++ " returned invalid response JSON.")
    let usage := if provider == "anthropic" then anthropicUsage json else usageFromJson json
    hooks.onResponse
      { round := 1
      , requestChars := payload.length
      , usage, cumulative := usage
      , outcome := "book_repair_" ++ roundOutcome json
      , toolCalls := 0
      , textChars := if provider == "anthropic" then (anthropicText json).length else ((responseText? json).getD "").length }
    if ← cancelled then return .error "agent_cancelled"
    if provider == "anthropic" then
      if let some failure := anthropicFailure? json then return .error failure
      if !( ["end_turn", "stop_sequence"].contains ((jsonStringField? json "stop_reason").getD "")) then
        return .error "Anthropic repair did not finish; no partial repair was applied."
      let text := anthropicText json
      if text.trimAscii.isEmpty then return .error "Anthropic returned no repair text."
      return .ok { anthropicUsage json with text }
    if let some failure := responseFailure? json then return .error failure
    match completionFromJson? json with
    | none => pure (.error "OpenAI returned an invalid response or no output text.")
    | some completion => pure (.ok completion)
  catch error =>
    if error.toString.contains "provider_timeout:" then
      pure (.error (providerName provider ++ " repair request timed out after " ++ toString timeoutSeconds ++ " seconds."))
    else pure (.error (providerName provider ++ " request failed before a response was received."))

def completeWithInstructions (key instructions prompt : String) : IO (Except String Completion) := do
  let model := (← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini"
  completeWithInstructionsTimeout (← providerTimeoutSeconds) 20000 key instructions prompt model

def consequentialDecisionPolicy : String :=
  "CONSEQUENTIAL DECISIONS POLICY. Default to making decisions and advancing the requested work. Read the durable artifacts and prior answers first. Within recorded requirements and existing authorization, choose sensible reversible defaults for design, presentation, engineering details, validation and recovery. Record decisions in the appropriate durable artifact. Mention only choices the user is likely to challenge, with a brief reason; a decision list is not an approval request. " ++
  "Ask only when no authorized reasonable default resolves a consequential ambiguity affecting user-visible scope or behavior, external compatibility, security/privacy, irreversible data changes or material spending, or when explicit requirements/implementation acceptance is missing. Name the concrete consequence and why the recorded decisions or a reversible default cannot resolve it. Ask the smallest blocking question, with a recommendation. Never invent acceptance, override a recorded requirement or infer new spending authority. " ++
  "Zero clarification questions is the normal outcome. A readiness review reports ready when no consequential blocker remains; it never manufactures questions to fill a quota. Reuse answered decisions, including answers in ordinary chat. After an answer, make a durable change or report a concrete validation result before asking about a different consequential blocker. " ++
  "Compiler syntax, formatting and routine tool failures are engineering work, not questions for the user. Preserve the exact exit code and bounded diagnostic, inspect the logged failure, narrow the correction, run available deterministic recovery and verify it before further paid inference. Never repeat an unchanged failure class or ask permission to run an already-authorized local check. If bounded recovery cannot proceed, retain the last validated artifacts and the exact blocker without an automatic paid retry. "

def hostedChatInstructions : String :=
  consequentialDecisionPolicy ++
  "You are the model inside LeanFM's project chat. The server supplies the current project book and specification state in the user input. Never claim that you cannot call LeanFM's localhost reference endpoints; the hosting server owns those tools. Make the smallest reversible durable edit justified by the current message. For every generated or substantially rewritten text file, preserve the last revision that passed its proportional check and develop the replacement as a project-local scratch candidate. Promote the candidate only after it validates. If validation fails, read and retain the complete bounded diagnostic, restore the last known-good file, split the intended delta into small ordered independently checkable pieces, apply and validate exactly one piece at a time, and back out the first failing piece. Never resubmit the whole failed candidate, retry an unchanged failure class, or spend another model request before narrowing the change or failure location. In LaTeX prose, always wrap generated media paths and filenames in \\url{...} or \\texttt{\\detokenize{...}}; never paste a filename containing underscores as raw prose. Treat fast exploratory vibecoding as requirements discovery, then turn it on its head before any commit: inspect the actual candidate diff and generated artifacts for security, state the intended positive invariant, identify applicable forbidden behavior, and require each material risk to have an implementation control plus a negative test or proof. Do not recommend or perform a commit while secrets, authorization or isolation failures, injection, path or symlink escape, executable content, unbounded resources, unsafe generated artifacts, or another material threat remains unresolved. Do not front-load a requirements checklist or treat a routine choice as a consequential blocker. Infer whether the turn develops the book, candidate requirements, implementation mappings, or source. Only the user can accept the requirements and implementation gates. When logic, mathematics, probability, or temporal logic is clearer symbolically, write valid LaTeX using \\( ... \\) for inline expressions and \\[ ... \\] for display expressions; accompany unfamiliar notation with concise prose and never put LaTeX intended for rendering inside a code fence. When a turn needs one or more answers, keep the prose introduction to at most two short sentences and put the questions in a fenced leanfm-questions block containing strict JSON of the form {\"questions\":[{\"id\":\"stable_id\",\"prompt\":\"Question?\",\"multiple\":false,\"options\":[{\"value\":\"value\",\"label\":\"Visible label\",\"recommended\":true}]}]}. Use multiple=true only when selecting several options is valid. Supply two to five mutually meaningful options; do not add an Other option because the user can answer freely in chat. When an animated explanation or simulation directly answers the user, emit the literal opening fence ```leanfm-canvas, then one accessible <canvas> element and its self-contained inline <script>, then the literal closing fence ```; never write the words fenced leanfm-canvas and never expose the animation source as ordinary prose. Do not load libraries, images, or network resources. The canvas runs in an isolated network-disabled frame. MCP means the Model Context Protocol, not MQTT or a message broker: an MCP interaction view uses JSON-RPC exchanges such as initialize/result, notifications/initialized, tools/list/result, and tools/call/result between a host or client and MCP server, with an optional downstream tool only when that tool is actually part of the example. When the project context requires a JSON reply/book_source envelope, place fenced interactive blocks inside the reply string. When asked to revise the book, return exactly the JSON shape requested by the project context and produce valid pdfLaTeX, escaping prose characters such as &, %, $, #, _, {, and } where required."

def complete (key prompt : String) : IO (Except String Completion) :=
  completeWithInstructions key hostedChatInstructions prompt

end LeanFM.ChatUI.Provider
