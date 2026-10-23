import LeanFM.ChatUI.Server

namespace LeanFM.ChatUI.ProviderTests

open Lean LeanFM.ChatUI.Provider LeanFM.ChatUI.Server

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
