import LeanFM.ChatUI.Server

namespace LeanFM.ChatUI.ProviderTests

open Lean LeanFM.ChatUI.Provider LeanFM.ChatUI.Server

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
example : bookVisibleText ("Provider preface: " ++ validEnvelope) = "" := by native_decide
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

end LeanFM.ChatUI.ProviderTests
