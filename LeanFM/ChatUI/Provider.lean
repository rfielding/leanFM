import LeanFM.ChatUI.Store

namespace LeanFM.ChatUI.Provider

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

partial def takeJsonStringLoop (cs acc : List Char) (escaped : Bool) : String :=
  match cs with
  | [] => String.ofList acc.reverse
  | c :: rest =>
      if escaped then
        let decoded := if c == 'n' then '\n' else if c == 'r' then '\r' else if c == 't' then '\t' else c
        takeJsonStringLoop rest (decoded :: acc) false
      else if c == '\\' then takeJsonStringLoop rest acc true
      else if c == '"' then String.ofList acc.reverse
      else takeJsonStringLoop rest (c :: acc) false

def responseText? (json : String) : Option String :=
  let valueAfterKey (key : String) : Option String :=
    match json.splitOn ("\"" ++ key ++ "\"") with
    | _ :: rest :: _ =>
        let afterColon := rest.toList.dropWhile (· != ':') |>.drop 1
        let value := afterColon.dropWhile (fun c => c == ' ' || c == '\n' || c == '\r' || c == '\t')
        match value with
        | '"' :: chars => some (takeJsonStringLoop chars [] false)
        | _ => none
    | _ => none
  valueAfterKey "output_text" |>.orElse (fun _ => valueAfterKey "text")

def complete (key prompt : String) : IO (Except String Completion) := do
  let model := (← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini"
  let baseUrl := (← IO.getEnv "LEANFM_OPENAI_BASE_URL").getD "https://api.openai.com/v1"
  let instructions := LeanFM.generatedRequirementSystemPrompt
  let payload := "{\"model\":\"" ++ jsonEscape model ++ "\",\"instructions\":\"" ++ jsonEscape instructions ++ "\",\"input\":\"" ++ jsonEscape prompt ++ "\"}"
  try
    let (status, body) ← apiCall "POST" (baseUrl ++ "/responses") key payload
    if status < 200 || status ≥ 300 then return .error ("OpenAI request failed (HTTP " ++ toString status ++ ").")
    match responseText? body with
    | none => pure (.error "OpenAI returned no text response.")
    | some text =>
        let inputTokens := (jsonNatValue? body "input_tokens").getD 0
        let cached := (jsonNatValue? body "cached_tokens").getD 0
        let outputTokens := (jsonNatValue? body "output_tokens").getD 0
        let totalTokens := (jsonNatValue? body "total_tokens").getD (inputTokens + outputTokens)
        pure (.ok { text, inputTokens, cachedInputTokens := cached, outputTokens, totalTokens })
  catch _ => pure (.error "OpenAI request failed before a response was received.")

end LeanFM.ChatUI.Provider
