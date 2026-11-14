import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.McpLogicImplementation
import LeanFM.LLMGenerated.SessionImplementation

open LeanFM.LLMGenerated.SelfHosting

-- Structural regression tests; these do not prove the proposed clause predicates.
example : errors = [] := by native_decide
example : spec.tasks.length = LeanFM.ChatUI.Requirements.spec.tasks.length + 2 := by native_decide
example : spec.messages.length = LeanFM.ChatUI.Requirements.spec.messages.length + 14 := by native_decide
example : clauses.length = 75 := by native_decide
example : (clauses.map (·.id)).contains "selfhost.mcp.hosting" = true := by native_decide
example : (clauses.map (·.id)).contains "selfhost.mcp.context" = true := by native_decide
example : (clauses.map (·.id)).contains "selfhost.lazy" = true := by native_decide
example : (clauses.map (·.id)).contains "selfhost.probability" = true := by native_decide
example : workflow.transitions.any (fun t => t.message == "WorkflowRejected" && t.dst == "rejected") = true := by native_decide
example : LeanFM.LLMGenerated.Requirements.all.length = 2 := by native_decide
example : (successfulBranchAtoms workflowGrammar.body).length = 10 := by native_decide
example : ["selfhost.mcp.logic.reference", "selfhost.mcp.logic.explain", "selfhost.mcp.logic.ctl", "selfhost.mcp.logic.trace",
    "selfhost.mcp.logic.observability", "selfhost.mcp.logic.knows", "selfhost.mcp.logic.protocol", "selfhost.mcp.logic.secrets", "selfhost.mcp.metrics", "selfhost.mcp.logic.reassembly", "selfhost.mcp.logic.view", "selfhost.mcp.logic.safety"].all
    (fun id => (clauses.map (·.id)).contains id) = true := by native_decide
example : logicTask.transitions.any (fun t => t.message == "LogicInputRejected" && t.dst == "rejected") = true := by native_decide
example : (spec.requiredProofs.map (·.name)).contains "Submitted logic never runs as code" = true := by native_decide
example : LeanFM.LLMGenerated.McpLogicImplementation.errors = [] := by native_decide
-- every logic clause is implemented, knows, protocol, reassembly and the view included
example : (clauses.filter (fun c => c.id.startsWith "selfhost.mcp.logic." && c.status == "implemented")).length = 11 := by native_decide
-- the session-type library is specified, and every clause has a decision and a test
example : (clauses.filter (fun c => c.id.startsWith "selfhost.session.")).length = 44 := by native_decide
example : LeanFM.LLMGenerated.SessionImplementation.errors = [] := by native_decide
-- the session tools and their view are specified and implemented
example : (clauses.filter (fun c => c.id.startsWith "selfhost.mcp.session." && c.status == "implemented")).length = 2 := by native_decide
