import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.McpLogicImplementation

open LeanFM.LLMGenerated.SelfHosting

-- Structural regression tests; these do not prove the proposed clause predicates.
example : errors = [] := by native_decide
example : spec.tasks.length = LeanFM.ChatUI.Requirements.spec.tasks.length + 2 := by native_decide
example : spec.messages.length = LeanFM.ChatUI.Requirements.spec.messages.length + 14 := by native_decide
example : clauses.length = 22 := by native_decide
example : (clauses.map (·.id)).contains "selfhost.mcp.context" = true := by native_decide
example : (clauses.map (·.id)).contains "selfhost.lazy" = true := by native_decide
example : (clauses.map (·.id)).contains "selfhost.probability" = true := by native_decide
example : workflow.transitions.any (fun t => t.message == "WorkflowRejected" && t.dst == "rejected") = true := by native_decide
example : LeanFM.LLMGenerated.Requirements.all.length = 2 := by native_decide
example : (successfulBranchAtoms workflowGrammar.body).length = 10 := by native_decide
example : ["selfhost.mcp.logic.reference", "selfhost.mcp.logic.explain", "selfhost.mcp.logic.ctl", "selfhost.mcp.logic.trace",
    "selfhost.mcp.logic.observability", "selfhost.mcp.logic.knows", "selfhost.mcp.logic.safety"].all
    (fun id => (clauses.map (·.id)).contains id) = true := by native_decide
example : logicTask.transitions.any (fun t => t.message == "LogicInputRejected" && t.dst == "rejected") = true := by native_decide
example : (spec.requiredProofs.map (·.name)).contains "Submitted logic never runs as code" = true := by native_decide
example : LeanFM.LLMGenerated.McpLogicImplementation.errors = [] := by native_decide
example : (clauses.filter (fun c => c.id.startsWith "selfhost.mcp.logic." && c.status == "implemented")).length = 6 := by native_decide
