import LeanFM.ChatUI.Server

namespace LeanFM.ChatUI.ProviderTests

open Lean LeanFM.ChatUI.Provider LeanFM.ChatUI.Server

-- Local infrastructure failures cannot consume another paid tool round.
example : (fatalWorkspaceFailure? "FATAL: local_checker_unavailable: failed to create thread").isSome = true := by native_decide
example : (fatalWorkspaceFailure? "FATAL: initiating credential session ended").isSome = true := by native_decide
example : (fatalWorkspaceFailure? "ERROR: unknown identifier; edit the candidate").isNone = true := by native_decide
example : safeSourceURL "javascript:alert(1)" = false := by native_decide
example : safeSourceURL "file:///private" = false := by native_decide
example : safeSourceURL "https://example.com/\nprivate" = false := by native_decide
example : safeSourceURL "https://example.com/official-docs" = true := by native_decide

-- Unsupported models never receive a hosted tool; supported ones receive it once.
example : (((Json.parse (openAITools false)).toOption.bind (·.getArr?.toOption)).getD #[]).all
    (fun tool => jsonStringField? tool "type" == some "function") = true := by native_decide
example : ((((Json.parse (openAITools true)).toOption.bind (·.getArr?.toOption)).getD #[]).filter
    (fun tool => jsonStringField? tool "type" == some "web_search")).size = 1 := by native_decide

#eval do
  let base ← IO.currentDir
  let root := base.toString ++ "/.cache/mcp-reference-" ++ (← LeanFM.ChatUI.Store.randomHex 8)
  IO.FS.createDirAll (System.FilePath.mk root)
  try
    let trace ← IO.mkRef ([] : List String)
    let requirements ← runWorkspaceTool root "leanfm_reference" "{\"section\":\"requirements\"}" trace
    if requirements != LeanFM.leanFMRequirementsReference then throw (IO.userError "MCP requirements reference diverged")
    let prompt ← runWorkspaceTool root "leanfm_reference" "{\"section\":\"code-generation\"}" trace
    if prompt != LeanFM.codeGenerationSystemPrompt then throw (IO.userError "MCP generation prompt diverged")
    if !(← trace.get).any (·.contains "via MCP") then throw (IO.userError "ChatUI did not report MCP-backed guidance")
    let rejected ← runWorkspaceTool root "leanfm_reference" "{\"section\":\"leanfm://project/specification/Requirements.lean\"}" trace
    if !rejected.startsWith "ERROR:" then throw (IO.userError "foreign project context was exposed as a language reference")
    let journalBefore ← LeanFM.ChatUI.Store.readOr (diagnosticLogPath root) ""
    let missing ← readProjectOptional root "spec/ProjectMemory.md"
    if !missing.startsWith "[Not recorded:" then throw (IO.userError "optional missing handoff was not identified")
    if (← LeanFM.ChatUI.Store.readOr (diagnosticLogPath root) "") != journalBefore then
      throw (IO.userError "optional missing handoff displaced real failure diagnostics")
  finally IO.FS.removeDirAll (System.FilePath.mk root)

#eval do
  let base ← IO.currentDir
  let root := base.toString ++ "/.cache/work-path-" ++ (← LeanFM.ChatUI.Store.randomHex 8)
  IO.FS.createDirAll (System.FilePath.mk (root ++ "/.leanfm/work"))
  try
    IO.FS.writeFile (System.FilePath.mk (root ++ "/.leanfm/work/checkpoint.json")) "private checkpoint"
    let linked ← IO.Process.output {cmd := "ln", args := #["-s", root ++ "/.leanfm/work/checkpoint.json", root ++ "/alias.json"]}
    if linked.exitCode != 0 then throw (IO.userError "could not create path-isolation fixture")
    if (← resolveWorkspacePath root "alias.json").isOk then throw (IO.userError "checkpoint alias was readable")
  finally IO.FS.removeDirAll (System.FilePath.mk root)

-- An implementation specification is an artifact layer, not a source request.
example : requestsImplementationSource "Prepare the implementation specification" = false := by native_decide
example : requestsImplementationSource "Update spec/Implementation.lean" = false := by native_decide
example : requestsImplementationSource "Implement the server now" = true := by native_decide

example : requestsRunnableApplication "implement the app" = true := by native_decide
example : requestsRunnableApplication "make run should launch it" = true := by native_decide
example : requestsRunnableApplication "implement the mapping" = false := by native_decide
example : requestsRunnableApplication "implement a library" = false := by native_decide

-- property:selected_project_context_drives_chat; task:inspect_task_model.
-- An overlapping task ID must never substitute the host application's grammar.
def foreignTask : LeanFM.TaskRequirement :=
  { LeanFM.ChatUI.Requirements.chatTask with actors := ["Client", "ForeignServer"] }
def foreignGrammar : LeanFM.TaskGrammar :=
  { task := foreignTask.id, entry := "ready", terminals := ["rendered"]
  , body := .event { task := foreignTask.id, src := "Client", dst := "ForeignServer", message := "ForeignRequest" } }
def foreignSpec : LeanFM.RequirementSpec :=
  { LeanFM.ChatUI.Requirements.spec with
    messages := [LeanFM.ChatUI.Requirements.message "ForeignRequest" "Client" "ForeignServer" []]
    tasks := [foreignTask]
    grammars := [foreignGrammar] }
example : (LeanFM.ChatUI.Requirements.interactionMermaid foreignTask foreignSpec).contains
    "Client->>ForeignServer: ForeignRequest" = true := by native_decide
example : (LeanFM.ChatUI.Requirements.interactionMermaid foreignTask foreignSpec).contains
    "ChatPromptSubmitted" = false := by native_decide
example : (LeanFM.ChatUI.Requirements.interactionMermaid foreignTask foreignSpec).contains
    "missing task grammar" = false := by native_decide
example : (tasksJson "foreign" foreignSpec).contains "login_explains_openai_key_protection" = false := by native_decide
example : curlConfigEscape "quote=\" slash=\\\n\r" = "quote=\\\" slash=\\\\\\n" := by native_decide
def longImageCaption : String :=
  String.ofList (List.replicate 5000 'a') ++ "\n![image](artifacts/attachments/0123456789abcdef0123456789abcdef/image.png)"
example : (conversationExcerpt longImageCaption).length ≤ 3500 := by native_decide
example : (attachmentIdsFromText (conversationExcerpt longImageCaption)).contains
    "0123456789abcdef0123456789abcdef" = true := by native_decide
example : (conversationExcerpt "text\n\nOperational trace:\nprivate diagnostic").contains
    "private diagnostic" = false := by native_decide

example : LeanFM.ChatUI.Store.jsonStringValue? "{\"display_name\": \"Resettable project\"}" "display_name" = some "Resettable project" := by native_decide
example : LeanFM.ChatUI.Store.jsonStringValue? "{\"display_name\": \"A \\\"quote\\\"\"}" "display_name" = some "A \"quote\"" := by native_decide
example : LeanFM.ChatUI.Store.jsonNatValue? "{\"count\": 12}" "count" = some 12 := by native_decide
example : LeanFM.ChatUI.Store.jsonNatValue? "{\"count\": 12bad}" "count" = none := by native_decide

-- Requirement refs: provider_outcomes_are_distinguishable,
-- book_envelopes_never_leak_into_chat, local_token_budget_is_visible_and_enforced.
def source : String := "\\documentclass{article}\n\\begin{document}\n\\(x+1\\)\n\\end{document}"

def validEnvelope : String :=
  (Json.mkObj [("reply", toJson "Ready"), ("book_source", toJson source)]).compress

def malformedMathEnvelope : String :=
  (validEnvelope.replace "\\\\(" "\\(").replace "\\\\)" "\\)"

example : (bookChatEdit? validEnvelope).map (·.source) = some source := by native_decide
example : (bookChatEdit? validEnvelope).map (·.repairedEscapes) = some false := by native_decide
example : (bookChatEdit? malformedMathEnvelope).map (·.source) = some source := by native_decide
example : (bookChatEdit? malformedMathEnvelope).map (·.repairedEscapes) = some true := by native_decide
example : escapeJsonMathDelimiters validEnvelope = validEnvelope := by native_decide
example : escapeJsonMathDelimiters (escapeJsonMathDelimiters malformedMathEnvelope) =
    escapeJsonMathDelimiters malformedMathEnvelope := by native_decide
example : escapeJsonMathDelimiters "\\q" = "\\q" := by native_decide
example : bookVisibleText "{\"reply\":\"Ready\",\"book_source\":\"hidden" = "" := by native_decide
example : bookVisibleText "An ordinary prose response." = "An ordinary prose response." := by native_decide
example : bookVisibleText validEnvelope = "Ready" := by native_decide
example : bookVisibleText ("```\n" ++ validEnvelope ++ "\n```") = "Ready" := by native_decide
example : bookVisibleText ("Provider preface: " ++ validEnvelope) = "Ready" := by native_decide
example : (bookChatEdit? ("Here is the update:\n```json\n" ++ validEnvelope ++ "\n```\nDone.")).map (·.unwrapped) = some true := by native_decide
example : (bookChatEdit? ("Update:\n" ++ malformedMathEnvelope)).map (·.source) = some source := by native_decide
example : bookChatEdit? (validEnvelope ++ "\n" ++ validEnvelope) |>.isNone := by native_decide
example : bookChatEdit? ("[" ++ validEnvelope ++ "]") |>.isNone := by native_decide
example : bookChatEdit? ("Update: " ++ validEnvelope ++ "\n{\"unfinished\":") |>.isNone := by native_decide
example : bookChatEdit? ("Update: {\"reply\":\"private\",\"book_source\":\"hidden") |>.isNone := by native_decide
example : !(bookReplyShape "HIDDEN_PREFIX").contains "HIDDEN" := by native_decide
example : !(bookReplyShape validEnvelope).contains "Ready" := by native_decide
example : (bookReplyShape "HIDDEN_PREFIX").contains "leading_token=other" := by native_decide
example : roundOutcome (Json.mkObj [("stop_reason", toJson "HIDDEN_PROVIDER_STATUS")]) = "unknown" := by native_decide
example : (bookEnvelopeDiagnostic "{\"reply\":\"private\",\"book_source\":\"secret").contains "offset" := by native_decide
example : !(bookEnvelopeDiagnostic "{\"reply\":\"private\",\"book_source\":\"secret").contains "secret" := by native_decide
example : bookEnvelopeDiagnostic "{\"reply\":123,\"book_source\":\"hidden\"}" =
    "The reply field must be a nonempty string." := by native_decide

def incomplete : Json := Json.mkObj
  [("status", toJson "incomplete"),
   ("incomplete_details", Json.mkObj [("reason", toJson "max_output_tokens")])]

example : (responseFailure? incomplete).any (·.startsWith "openai_output_limit:") := by native_decide
example : responseFailure? (Json.mkObj [("status", toJson "completed")]) = none := by native_decide
example : (responseFailure? (Json.mkObj [])).isSome := by native_decide

def hostileError : String :=
  "{\"error\":{\"code\":\"sk-secret\",\"type\":\"private-prompt\",\"message\":\"credential-body\"}}"

example : !(apiErrorDetail 429 hostileError).contains "sk-secret" := by native_decide
example : !(apiErrorDetail 429 hostileError).contains "private-prompt" := by native_decide
example : !(apiErrorDetail 429 hostileError).contains "credential-body" := by native_decide
example : (apiErrorDetail 429 "{\"error\":{\"code\":\"insufficient_quota\"}}")
    |>.contains "quota exhausted" := by native_decide
example : (errorResponse 409 "The local session token safety budget is exhausted.").body
    |>.contains "leanfm_session_token_budget_exhausted" := by native_decide
example : (errorResponse 409 "A different revision is current.").body
    |>.contains "leanfm_http_409" := by native_decide

-- Both provider protocols preserve the same workspace controls. Anthropic's
-- cache counters are additive, not a subset of input_tokens as in Responses.
def claudeUsage : Json := Json.mkObj [("usage", Json.mkObj
  [("input_tokens", toJson (7 : Nat)), ("cache_creation_input_tokens", toJson (2 : Nat)),
   ("cache_read_input_tokens", toJson (3 : Nat)), ("output_tokens", toJson (5 : Nat))])]

example : (anthropicUsage claudeUsage).inputTokens = 12 := by native_decide
example : (anthropicUsage claudeUsage).cachedInputTokens = 3 := by native_decide
example : (anthropicUsage claudeUsage).totalTokens = 17 := by native_decide
example : (anthropicFailure? (Json.mkObj [("stop_reason", toJson "max_tokens")])).isSome := by native_decide
example : (anthropicFailure? (Json.mkObj [("stop_reason", toJson "model_context_window_exceeded")])).isSome := by native_decide
example : (anthropicFailure? (Json.mkObj [("stop_reason", toJson "refusal")])).isSome := by native_decide
example : (anthropicFailure? (Json.mkObj [("stop_reason", toJson "end_turn")])).isNone := by native_decide
example : !(anthropicErrorDetail 402 hostileError).contains "credential-body" := by native_decide
example : !(anthropicErrorDetail 402 hostileError).contains "private-prompt" := by native_decide
example : !(anthropicErrorDetail 402 hostileError).contains "sk-secret" := by native_decide
example : (anthropicErrorDetail 400 "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Your credit balance is too low.\"}}")
    |>.contains "credit balance is too low" := by native_decide
example : ((anthropicTools false).getArr?.toOption.getD #[]).size =
    (((Json.parse workspaceToolsJson).toOption.bind fun value => value.getArr?.toOption).getD #[]).size - 1 := by native_decide
example : (submittedProviderKeys "provider=other&api_key=value").toOption.isNone := by native_decide
example : (submittedProviderKeys "openai_api_key=one&anthropic_api_key=two").toOption ==
    some [("openai", "one"), ("anthropic", "two")] := by native_decide
example : (submittedProviderKeys "provider=anthropic&api_key=one&anthropic_api_key=two").toOption.isNone := by native_decide

end LeanFM.ChatUI.ProviderTests
