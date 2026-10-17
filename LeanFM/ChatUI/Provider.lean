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
deriving Repr

structure FunctionCall where
  callId : String
  name : String
  arguments : String
deriving Repr

abbrev ToolRunner := String → String → IO String

def curlConfigEscape (value : String) : String :=
  String.join <| value.toList.map fun c =>
    if c == '\\' then "\\\\" else if c == '"' then "\\\""
    else if c == '\n' then "\\n" else if c == '\r' then "" else c.toString

def apiCall (method url key payload : String) : IO (Nat × String) := do
  let dataLine := if payload.isEmpty then "" else "data = \"" ++ curlConfigEscape payload ++ "\"\n"
  let config := "url = \"" ++ url ++ "\"\nrequest = \"" ++ method ++ "\"\n" ++
    "header = \"Authorization: Bearer " ++ curlConfigEscape key ++ "\"\n" ++
    (if payload.isEmpty then "" else "header = \"Content-Type: application/json\"\n") ++
    dataLine ++ "silent\nshow-error\n"
  let out ← IO.Process.output {
    cmd := "curl", args := #["--max-time", "120", "--config", "-", "--write-out", "\n__LEANFM_STATUS__%{http_code}"]
  } (some config)
  if out.exitCode != 0 then throw <| IO.userError "model provider request failed"
  match out.stdout.splitOn "\n__LEANFM_STATUS__" with
  | [body, status] => pure (status.trimAscii.toString.toNat?.getD 0, body)
  | _ => pure (0, out.stdout)

def verifyKey (key : String) : IO (Except String Unit) := do
  try
    let baseUrl := (← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1"
    let (status, _) ← apiCall "GET" (baseUrl ++ "/models") key ""
    if status == 200 then pure (.ok ()) else pure (.error ("OpenAI rejected the API key (HTTP " ++ toString status ++ ")."))
  catch _ => pure (.error "OpenAI key verification could not reach the provider.")

def jsonStringField? (json : Json) (key : String) : Option String :=
  ((json.getObjVal? key).bind Json.getStr?).toOption

def jsonNatField? (json : Json) (key : String) : Option Nat :=
  ((json.getObjVal? key).bind Json.getNat?).toOption

def jsonArrayField? (json : Json) (key : String) : Option (Array Json) :=
  ((json.getObjVal? key).bind Json.getArr?).toOption

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
    "{\"type\":\"function\",\"name\":\"workspace_list\",\"description\":\"List tracked and untracked files below the authorized launch workspace.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_read\",\"description\":\"Read a UTF-8 text file below the authorized launch workspace.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_search\",\"description\":\"Search text below the authorized launch workspace using a literal query.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"query\",\"path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_patch\",\"description\":\"Apply a unified diff to files in the authorized launch workspace. Use repository-relative paths and preserve unrelated changes.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"patch\":{\"type\":\"string\"}},\"required\":[\"patch\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_write\",\"description\":\"Create or replace one UTF-8 text file below the authorized launch workspace. Read it first when it exists and preserve unrelated work.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_check\",\"description\":\"Run one bounded repository check.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\",\"enum\":[\"build\",\"check\",\"book\",\"http-check\",\"go-test\"]}},\"required\":[\"target\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_run_gif_generator\",\"description\":\"Run one self-contained project-local Python/Pillow generator in a filesystem/process sandbox and validate its GIF output. Use this when the user explicitly requests a real animated GIF.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"script_path\":{\"type\":\"string\"},\"output_path\":{\"type\":\"string\"}},\"required\":[\"script_path\",\"output_path\"],\"additionalProperties\":false}}",
    "{\"type\":\"function\",\"name\":\"workspace_transcode_mp4\",\"description\":\"Transcode a project-local animated GIF or WebM into a real broadly compatible H.264 MP4, validate it, and leave it below the project workspace for inline chat rendering. Use this when the user explicitly requests MP4.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"input_path\":{\"type\":\"string\"},\"output_path\":{\"type\":\"string\"}},\"required\":[\"input_path\",\"output_path\"],\"additionalProperties\":false}}"
  ] ++ "]"

def toolOutputJson (callId output : String) : String :=
  "{\"type\":\"function_call_output\",\"call_id\":\"" ++ jsonEscape callId ++
  "\",\"output\":\"" ++ jsonEscape output ++ "\"}"

partial def completeAgentLoop (key baseUrl model instructions prompt previousId : String)
    (pending : List String) (runTool : ToolRunner) (usage : Completion) (remaining : Nat) : IO (Except String Completion) := do
  if remaining == 0 then return .error "The workspace agent exceeded its 16-step tool limit."
  let input := if previousId.isEmpty then "\"" ++ jsonEscape prompt ++ "\"" else
    "[" ++ String.intercalate "," pending ++ "]"
  let continuation := if previousId.isEmpty then "" else
    ",\"previous_response_id\":\"" ++ jsonEscape previousId ++ "\""
  let payload := "{\"model\":\"" ++ jsonEscape model ++ "\",\"instructions\":\"" ++
    jsonEscape instructions ++ "\",\"input\":" ++ input ++ continuation ++
    ",\"tools\":" ++ workspaceToolsJson ++ ",\"tool_choice\":\"auto\"}"
  try
    let (status, body) ← apiCall "POST" (baseUrl ++ "/responses") key payload
    if status < 200 || status ≥ 300 then
      let error := (Json.parse body).toOption.bind fun value => (value.getObjVal? "error").toOption
      let code := error.bind (jsonStringField? · "code")
      let suffix := code.map (fun value => "; code=" ++ value) |>.getD ""
      return .error ("OpenAI workspace request failed (HTTP " ++ toString status ++ suffix ++ ").")
    let some json := (Json.parse body).toOption | return .error "OpenAI returned invalid JSON to the workspace agent."
    let nextUsage := addUsage usage (usageFromJson json)
    let calls := functionCalls json
    if calls.isEmpty then
      match responseText? json with
      | some text => return .ok { nextUsage with text }
      | none => return .error "OpenAI returned neither workspace tool calls nor answer text."
    let some responseId := responseId? json | return .error "OpenAI omitted the response ID needed to continue workspace tools."
    let mut outputs : List String := []
    for call in calls do
      let result ← runTool call.name call.arguments
      outputs := toolOutputJson call.callId result :: outputs
    completeAgentLoop key baseUrl model instructions prompt responseId outputs.reverse runTool nextUsage (remaining - 1)
  catch _ => pure (.error "OpenAI workspace-agent request failed before a response was received.")

def completeAgent (key instructions prompt : String) (runTool : ToolRunner) : IO (Except String Completion) := do
  let model := (← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini"
  let baseUrl := (← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1"
  completeAgentLoop key baseUrl model instructions prompt "" [] runTool
    { text := "", inputTokens := 0, cachedInputTokens := 0, outputTokens := 0, totalTokens := 0 } 16

-- Return structured provider diagnostics, never the arbitrary response body: provider
-- messages can reflect request data, while error type/code are bounded identifiers.
def apiErrorDetail (status : Nat) (body : String) : String :=
  let error := (Json.parse body).toOption.bind fun json => (json.getObjVal? "error").toOption
  let errorType := error.bind (jsonStringField? · "type")
  let errorCode := error.bind (jsonStringField? · "code")
  let identifiers :=
    (errorType.map (fun value => "type=" ++ value)).toList ++
    (errorCode.map (fun value => "code=" ++ value)).toList
  let diagnosis := match errorCode, errorType with
    | some "credit_balance_exhausted", _ => "API credit balance exhausted; add credits in OpenAI billing."
    | some "organization_spend_limit_exceeded", _ => "OpenAI organization spend limit reached."
    | some "project_spend_limit_exceeded", _ => "OpenAI project spend limit reached."
    | some "organization_usage_limit_exceeded", _ => "OpenAI organization usage limit reached."
    | some "slow_down", _ => "OpenAI requested slower traffic; wait before retrying."
    | _, some "rate_limit_error" => "OpenAI rate limit reached; wait before retrying."
    | _, _ => "OpenAI rejected the request."
  let detail := if identifiers.isEmpty then "" else "; " ++ String.intercalate "; " identifiers
  "OpenAI request failed (HTTP " ++ toString status ++ detail ++ "). " ++ diagnosis

def completeWithInstructions (key instructions prompt : String) : IO (Except String Completion) := do
  let model := (← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini"
  let baseUrl := (← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1"
  let payload := "{\"model\":\"" ++ jsonEscape model ++ "\",\"instructions\":\"" ++ jsonEscape instructions ++ "\",\"input\":\"" ++ jsonEscape prompt ++ "\"}"
  try
    let (status, body) ← apiCall "POST" (baseUrl ++ "/responses") key payload
    if status < 200 || status ≥ 300 then return .error (apiErrorDetail status body)
    match (Json.parse body).toOption.bind completionFromJson? with
    | none => pure (.error "OpenAI returned an invalid response or no output text.")
    | some completion => pure (.ok completion)
  catch _ => pure (.error "OpenAI request failed before a response was received.")

def hostedChatInstructions : String :=
  "You are the model inside LeanFM's project chat. The server supplies the current project book and specification state in the user input. Never claim that you cannot call LeanFM's localhost reference endpoints; the hosting server owns those tools. Make the smallest reversible durable edit justified by the current message. Ask no more than two focused questions at a time and never repeat a question already answered in the supplied conversation or durable artifacts. Do not front-load a requirements checklist. Infer whether the turn develops the book, candidate requirements, implementation mappings, or source. Only the user can accept the requirements and implementation gates. When logic, mathematics, probability, or temporal logic is clearer symbolically, write valid LaTeX using \\( ... \\) for inline expressions and \\[ ... \\] for display expressions; accompany unfamiliar notation with concise prose and never put LaTeX intended for rendering inside a code fence. When a turn needs one or more answers, keep the prose introduction to at most two short sentences and put the questions in a fenced leanfm-questions block containing strict JSON of the form {\"questions\":[{\"id\":\"stable_id\",\"prompt\":\"Question?\",\"multiple\":false,\"options\":[{\"value\":\"value\",\"label\":\"Visible label\",\"recommended\":true}]}]}. Use multiple=true only when selecting several options is valid. Supply two to five mutually meaningful options; do not add an Other option because the user can answer freely in chat. When an animated explanation or simulation directly answers the user, return a fenced leanfm-canvas block containing a literal accessible <canvas> element and its self-contained inline <script>; do not load libraries, images, or network resources. The canvas runs in an isolated network-disabled frame. When the project context requires a JSON reply/book_source envelope, place fenced interactive blocks inside the reply string. When asked to revise the book, return exactly the JSON shape requested by the project context and produce valid pdfLaTeX, escaping prose characters such as &, %, $, #, _, {, and } where required."

def complete (key prompt : String) : IO (Except String Completion) :=
  completeWithInstructions key hostedChatInstructions prompt

end LeanFM.ChatUI.Provider
