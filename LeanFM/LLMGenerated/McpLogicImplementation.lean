import LeanFM.LLMGenerated.SelfHosting
import LeanFM.ChatUI.Implementation

/-! Implementation mapping for the accepted `selfhost.mcp.logic.*` requirements.
    Gate 1 (requirements) accepted by the stakeholder on 2026-10-26.
    Gate 2 (this mapping) accepted by the stakeholder on 2026-10-26. -/

namespace LeanFM.LLMGenerated.McpLogicImplementation
open LeanFM.ChatUI.Implementation
open LeanFM.LLMGenerated.SelfHosting

def decisions : List ImplementationDecision :=
  [ decision "logic-formula-ast"
      ["clause:selfhost.mcp.logic.reference", "clause:selfhost.mcp.logic.safety", "proof:Submitted logic never runs as code"]
      ["LeanFM/Logic.lean"]
      "Add a pure module LeanFM.Logic with a closed inductive Formula: true, false, at(state), after(message), terminal, field(message, name, value), predicate(text), derived(name), not, and, or, implies, stronglyImplies, never, EX, AX, EF, AF, EG, AG, EU, AU, EW, AW, and an unsupported(operator) node for K, O, P, Pr and similar modal operators. Parse it from Lean.Json only; no constructor holds code, a path or a closure, so a submitted formula cannot run. Reject bare path operators X, F, G and U as typing errors naming the quantified alternatives. Bound input: 256 formula nodes, depth 64, 256-character strings and 64 KiB of arguments; exceeding an input bound yields LogicInputRejected with the bound named."
      ["LeanFM/LogicTests.lean: parse every operator; reject code-shaped strings as atoms only, unknown keys, bare F/G/X/U, depth/node/string overflow; no IO in LeanFM.Logic (checked by the module having no IO definitions)"]
  , decision "logic-ctl-model"
      ["clause:selfhost.mcp.logic.ctl", "property:Logic answers carry their evidence", "proof:Exhausted search never proves"]
      ["LeanFM/Logic.lean"]
      "Build a finite Kripke structure from a canonical task (looked up by id in the self-hosting spec) or an inline draft {states, initial, terminals, transitions[src,dst,message]}. A node is (task state, message just taken). Terminal states and deadlocked non-terminal states stutter on themselves so every path is infinite; deadlocks are reported. Evaluate by explicit fixpoint labelling over at most 4096 nodes; iteration is bounded by the node count so every check terminates. Verdicts: proved/disproved only when every atom is observable and the model fit the bound; unknown when a derived or predicate atom is present; unsupported when an unsupported operator is present; resource-limit when the model exceeds the node bound. Unknown state or message names are input errors, so typos are not silently false."
      ["LeanFM/LogicTests.lean: AG/AF/EG/EF/EU/AU/EW/AW agree with LeanFM.CTL.holds on the self-hosting tasks; a 5000-state draft yields resource-limit not proved; predicate atom yields unknown; K yields unsupported"]
  , decision "logic-evidence"
      ["clause:selfhost.mcp.logic.ctl", "property:Logic answers carry their evidence"]
      ["LeanFM/Logic.lean"]
      "Return evidence as paths of {state, message} steps. Holding existential claims (EF, EX, EU, EG, EW, stronglyImplies) return a witness: breadth-first shortest path for reachability claims and a lasso (prefix plus loop start) for EG. Failing universal claims (AG, never, AX, AF, AU, AW) return a counterexample computed as the witness of the dual existential. A proved universal claim reports the number of reachable nodes checked. A failing stronglyImplies says whether the antecedent is unreachable (vacuous) or the implication fails."
      ["LeanFM/LogicTests.lean: counterexample for AG not after(LogicInputRejected) on mcp_logic_consult ends with LogicInputRejected; lasso for AF on a draft cycle; witness for EF terminal"]
  , decision "logic-explain"
      ["clause:selfhost.mcp.logic.explain"]
      ["LeanFM/Logic.lean"]
      "explain_formula returns the English reading, the negation pushed through duals, the requirement mode (always, never, eventually, possibly or compound), typing errors, unknown atoms when an optional task is supplied, and lints: AG over implies suggests stronglyImplies; AF AG and AG AF are each read explicitly; an optional English sentence containing always/never/every/must with an existential formula, or can/may/possible with a universal one, is flagged as a likely quantifier mismatch."
      ["LeanFM/LogicTests.lean: reading and negation of AG(implies(after M, AF terminal)); stronglyImplies lint; sentence/quantifier mismatch lint"]
  , decision "logic-trace"
      ["clause:selfhost.mcp.logic.trace"]
      ["LeanFM/Logic.lean"]
      "check_trace accepts at most 512 envelopes {id, prevIds, causeIds, task, src, dst, message}. Report duplicate ids, dangling references, references to later events (a cause must precede its effect in the submitted order), cycles, src/dst contradicting the canonical message schema, concurrent pairs (unordered under the transitive closure of prev and cause edges, listing at most 64), and per task whether the events in submitted order are accepted by that task's typed transitions from its initial state, or the first rejected event. Return a Mermaid sequenceDiagram and a Mermaid causal flowchart (prev solid, cause dashed) generated from the events."
      ["LeanFM/LogicTests.lean: valid mcp_logic_consult trace accepted with diagram; duplicate, dangling, forward cause, wrong src and out-of-grammar event each reported; two independent requests reported concurrent"]
  , decision "logic-observability"
      ["clause:selfhost.mcp.logic.observability", "proof:Hidden predicates never pass as observable"]
      ["LeanFM/Logic.lean"]
      "classify_requirement takes a formula or a list of predicate texts and an optional task. at, after, terminal and field atoms are observable once they name a declared state or message; derived(name) atoms are derived and name the reducer or policy declaration that must exist; predicate text is never observable: it is derived when it mentions a declared message or state (needs a reducer over those events) and implementation-only otherwise, with the advice to move it to Implementation.lean or restate it over events and a proposed event name, actor and fields. check_ctl treats predicate and derived atoms as unknown, never as true or false."
      ["LeanFM/LogicTests.lean: 'cache is consistent' is implementation-only with a proposed event; 'LogicVerdict count' is derived; no predicate text is ever observable; check_ctl with a predicate atom never proves"]
  , decision "logic-mcp-wiring"
      ["clause:selfhost.mcp.logic.reference", "clause:selfhost.mcp.logic.knows", "clause:selfhost.mcp.logic.safety", "task:mcp_logic_consult", "message:LogicConsultRequested", "message:LogicVerdict", "message:LogicInputRejected", "property:Every consultation ends"]
      ["LeanFM/MCP.lean", "LeanFM/MCPTests.lean"]
      "Add the leanfm://language/logic-reference markdown resource. Give tools an inputSchema; list explain_formula, check_ctl, check_trace, classify_requirement and knows. Pass params.arguments to toolResult. A LogicVerdict is a tool result whose text and structuredContent hold {tool, verdict, reading, evidence, bounds}; LogicInputRejected is a tool result with isError true and {tool, verdict: rejected, reason}. knows always answers unsupported naming the deferral. The tools remain read-only, deterministic and path-free; no tool changes project state."
      ["LeanFM/MCPTests.lean: tools/list includes the logic tools with schemas; check_ctl over JSON-RPC returns a counterexample; malformed input returns isError; knows returns unsupported; logic-reference resource readable"]
  , decision "logic-book"
      ["output:selfhost.mcp.logic.interaction", "output:selfhost.mcp.logic.states"]
      ["book/chapters/web-server.tex", "book/generated/mcp-logic-examples.tex", "LogicInteractionExample.lean"]
      "Generate real tool answers (one counterexample, one classification, one trace diagram) into the book from the implemented functions so section 7.5 shows actual output rather than prose claims."
      ["make book succeeds; generated example text matches LeanFM.Logic output"]
  ]

def clauseRefs : List String := clauses.map (fun c => "clause:" ++ c.id)

def errors : List String :=
  let valid := LeanFM.requirementReferenceIds spec ++ clauseRefs
  let unknown := decisions.flatMap fun d =>
    d.requirementRefs.filterMap fun r => if valid.contains r then none else some ("unknown reference: " ++ r)
  let neverProofs := ["proof:Submitted logic never runs as code", "proof:Exhausted search never proves",
    "proof:Hidden predicates never pass as observable"]
  let unmapped := neverProofs.filterMap fun p =>
    if decisions.any (fun d => d.requirementRefs.contains p && !d.conformanceTests.isEmpty) then none
    else some ("negative requirement without control and test: " ++ p)
  let logicClauses := (clauses.filter (fun c => c.id.startsWith "selfhost.mcp.logic.")).map (fun c => "clause:" ++ c.id)
  let uncovered := logicClauses.filterMap fun c =>
    if decisions.any (fun d => d.requirementRefs.contains c) then none else some ("clause without decision: " ++ c)
  unknown ++ unmapped ++ uncovered

end LeanFM.LLMGenerated.McpLogicImplementation
