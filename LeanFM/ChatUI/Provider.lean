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
  | [body, status] => pure (status.trim.toNat?.getD 0, body)
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

def complete (key prompt : String) : IO (Except String Completion) := do
  let model := (← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini"
  let baseUrl := (← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1"
  let instructions := LeanFM.generatedRequirementSystemPrompt
  let payload := "{\"model\":\"" ++ jsonEscape model ++ "\",\"instructions\":\"" ++ jsonEscape instructions ++ "\",\"input\":\"" ++ jsonEscape prompt ++ "\"}"
  try
    let (status, body) ← apiCall "POST" (baseUrl ++ "/responses") key payload
    if status < 200 || status ≥ 300 then return .error (apiErrorDetail status body)
    match (Json.parse body).toOption.bind completionFromJson? with
    | none => pure (.error "OpenAI returned an invalid response or no output text.")
    | some completion => pure (.ok completion)
  catch _ => pure (.error "OpenAI request failed before a response was received.")

end LeanFM.ChatUI.Provider
