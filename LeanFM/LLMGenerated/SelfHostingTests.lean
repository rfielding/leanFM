import LeanFM.LLMGenerated.Requirements

open LeanFM.LLMGenerated.SelfHosting

-- Structural regression tests; these do not prove the proposed clause predicates.
example : errors = [] := by native_decide
example : spec.tasks.length = LeanFM.ChatUI.Requirements.spec.tasks.length + 1 := by native_decide
example : spec.messages.length = LeanFM.ChatUI.Requirements.spec.messages.length + 11 := by native_decide
example : clauses.length = 12 := by native_decide
example : (clauses.map (·.id)).contains "selfhost.lazy" = true := by native_decide
example : (clauses.map (·.id)).contains "selfhost.probability" = true := by native_decide
example : workflow.transitions.any (fun t => t.message == "WorkflowRejected" && t.dst == "rejected") = true := by native_decide
example : LeanFM.LLMGenerated.Requirements.all.length = 2 := by native_decide
example : (successfulBranchAtoms workflowGrammar.body).length = 10 := by native_decide
