import LeanFM.LLMGenerated.SharedProjects

/- Self-hosting consolidation proposal. Structural validation does not prove
   predicates or implement the proposed language/checker extensions. -/
namespace LeanFM.LLMGenerated.SelfHosting
open LeanFM

structure Component where
  id : String
  requirements : String
  protobuf : String
  implementation : String
  status : String
deriving Repr

def components : List Component :=
  [ { id := "leanfm.chatui", requirements := "LeanFM/ChatUI/Requirements.lean",
      protobuf := "LeanFM/ChatUI/Requirements.proto", implementation := "LeanFM/ChatUI/Implementation.lean",
      status := "existing product component; conformance must be audited" }
  , { id := "leanfm.selfhost", requirements := "LeanFM/LLMGenerated/SelfHosting.lean",
      protobuf := "LeanFM/LLMGenerated/SelfHosting.proto", implementation := "LeanFM/LLMGenerated/Implementation.lean",
      status := "proposed workflow and clauses; MCP read-only context adapter implemented; remaining mappings pending" }
  , { id := "worker.example", requirements := "LeanFM/LLMGenerated/Requirements.lean",
      protobuf := "LeanFM/LLMGenerated/Requirements.proto", implementation := "LeanFM/LLMGenerated/Implementation.lean",
      status := "preserved example, not whole-product implementation" } ]

def workflowProto : String := include_str "SelfHosting.proto"

structure Clause where
  id : String
  area : String
  requirement : String
  status : String := "proposed"
deriving Repr

def clauses : List Clause :=
  [ { id := "selfhost.revision", area := "workflow", requirement := "A snapshot is identified by exact book, requirements, protobuf, implementation, and repository revisions. Changes invalidate affected checks and derived artifacts; stale requests fail without overwriting current state." }
  , { id := "selfhost.gates", area := "workflow", status := "implemented", requirement := "Review and acceptance are git commits made by the user; LeanFM records no approvals and never blocks an edit, source write or launch on one. Code generation requires the current snapshot's requirements and implementation mapping to pass their canonical checks. Project status reports whether each is checked and committed." }
  , { id := "selfhost.pr", area := "workflow", requirement := "PR delivery requires an actual patch, requirement-to-code/test mappings, reproducible check results, base revision, and remaining limitations. The PR may be delivered as a local reviewable bundle; remote publication requires explicit authority. Failed checks cannot be labeled completed." }
  , { id := "selfhost.checker", area := "checker", requirement := "Check results distinguish proved, disproved, unknown, unsupported, and resource-limit reached. Identify model revision, formula, assumptions, bounds, terminal-path convention, fairness, and witness or counterexample. Schema validation is not a semantic proof." }
  , { id := "selfhost.formulas", area := "language", requirement := "Requirements must support typed nested CTL state formulas and separately typed path conditions. AF AG p is eventual permanent safety; AG AF p is universal recurrence. Preserve existential counterexample duals without claiming CTL covers all LTL." }
  , { id := "selfhost.modal", area := "language", requirement := "Knowledge quantifies over legal histories with identical declared actor observations. Obligation and permission quantify over all and some nonempty named ideal policy futures. Never conflate legal, observable, ideal, and probabilistic alternatives. Belief and morality are outside this extension." }
  , { id := "selfhost.lazy", area := "checker", requirement := "Retain modality-specific indexes only while current formulas reference the corresponding actor or policy relation. Rebuild them from retained source evidence; release unreferenced indexes. Index lifetimes must not alter truth. Isolate caches by project and model revision." }
  , { id := "selfhost.probability", area := "language", requirement := "Probabilities are optional and distinct from existence. Identify declared model probability versus observed frequency versus unknown. Specify normalization, conditioning, scheduler or min/max policy, horizon, threshold comparison, and sample boundary. Do not infer independence or treat unknown as zero." }
  , { id := "selfhost.history", area := "language", requirement := "Immutable events carry predecessor links; derived successor indexes preserve event identity and partial order. State whether a past monitor uses causal ancestry or a declared linearization. Strictly prior facts exclude the current event." }
  , { id := "selfhost.coverage", area := "traceability", requirement := "Every normative book claim is linked to an accepted requirement, an explicitly pending proposal, or a deferred/illustrative classification. Every accepted requirement maps to implementation decisions and evidence; unmapped claims prevent a claim of complete one-shot readiness." }
  , { id := "selfhost.handoff", area := "workflow", requirement := "A new session starts from book/main.pdf, book/main-dark.pdf, canonical requirements/protobuf/implementation, component registry, current repository, and generated review report. Application goals also retain spec/ProjectMemory.md, spec/runtime.json, revision-bound actual-launch evidence, failure remedies and PR/base-revision context. Conversation history is not required input." }
  , { id := "selfhost.bounds", area := "checker", requirement := "Declare finite exploration and resource bounds. Exhaustion yields resource-limit or unknown, never proved. Compaction must preserve the declared observation and monitor semantics." }
  , { id := "selfhost.mcp.context", area := "agent interface", status := "implemented", requirement := "A stateless MCP endpoint exposes the project book, canonical requirements, protobuf, implementation specification, and live language references through fixed resource URIs. Initialization states that the book is durable agent context comparable to maintained system-prompt material." }
  , { id := "selfhost.mcp.readonly", area := "agent interface", status := "implemented", requirement := "The MCP endpoint is read-only: its tools return deterministic interrogation, generation, and validation material, cannot read arbitrary paths, and cannot mutate project state." }
  , { id := "selfhost.mcp.transport", area := "agent interface", status := "implemented", requirement := "POST /mcp accepts JSON-RPC initialization, ping, resource, prompt, and tool methods using MCP protocol version 2025-06-18. The loopback service requires deployment authentication before remote exposure." }
  , { id := "selfhost.mcp.logic.reference", area := "agent interface", status := "implemented", requirement := "Resource leanfm://language/logic-reference states the JSON formula grammar, the operators and their English readings, the five verdicts, the witness/counterexample conventions, the terminal-state convention and the bounds, so an agent never guesses logic syntax." }
  , { id := "selfhost.mcp.logic.explain", area := "agent interface", status := "implemented", requirement := "Tool explain_formula takes one JSON formula and returns its English reading, its negation with existential/universal duals, the requirement mode it fits (always, never, eventually or possibly), typing errors (a path condition used as a state formula and the reverse), unknown atoms, and lints: an implication whose antecedent may be unreachable is reported with the stronglyImplies alternative; AF/EF, AG/EG and AF AG/AG AF readings are distinguished." }
  , { id := "selfhost.mcp.logic.ctl", area := "agent interface", status := "implemented", requirement := "Tool check_ctl takes a task, either a canonical task id or an inline draft with states, initial state and message-labelled transitions, plus one JSON CTL formula over that task's observable atoms (at state, after message, terminal). It returns one of proved, disproved, unknown, unsupported or resource-limit, the reading, the declared bounds and terminal convention, and evidence: a witness path for an existential or possibly claim that holds, a counterexample path for a universal or never claim that fails, each as states and messages." }
  , { id := "selfhost.mcp.logic.trace", area := "agent interface", status := "implemented", requirement := "Tool check_trace takes event envelopes (id, prevIds, causeIds, task, src, dst, message). It reports duplicate or dangling ids, cycles, causes that do not precede their effects, src/dst that contradict a message schema, which events are concurrent, and for each task whether its events are accepted by that task's grammar or the first event that is not. It returns the interaction diagram and causal graph derived from the events, so agents design sequence diagrams by writing events rather than drawing them." }
  , { id := "selfhost.mcp.logic.observability", area := "agent interface", status := "implemented", requirement := "Tool classify_requirement takes a formula or a predicate text and classifies every atom as observable (a message, a field of a message, a task state reachable from messages), derived (knowledge from the causal past, a policy permission or obligation, a where_ predicate over message fields) or implementation-only (internal state with no observable consequence). For derived atoms it names the declaration that must exist; for implementation-only atoms it says the claim belongs in Implementation.lean or must be restated through observable events, and proposes the events that would make it testable. It never reports a hidden predicate as observable." }
  , { id := "selfhost.mcp.logic.knows", area := "agent interface", status := "accepted; deferred", requirement := "Tool knows takes event envelopes, an actor, an event id and declared derivation rules (pairing, projection, encryption and decryption with held keys) and returns the values the actor can derive from messages delivered to it in the causal past of that event, with the delivering event for each. Deferred to a later revision; until then the tool is listed as unsupported." }
  , { id := "selfhost.mcp.logic.safety", area := "agent interface", status := "implemented", requirement := "Logic tools treat formulas, tasks and traces strictly as JSON data: never compiled, evaluated or executed as Lean, shell or any other code. Inputs are bounded (formula nodes, task states and transitions, trace events, string lengths); exceeding a bound yields resource-limit or an input error, never proved. Tools are deterministic, stateless and read no paths." } ]

def workflowMessages : List MessageSchema :=
  [ LeanFM.ChatUI.Requirements.message "RevisionProposed" "UserBrowser" "LeanFMServer" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "RequirementsChecked" "LeanFMServer" "UserBrowser" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "RequirementsCommitted" "UserBrowser" "LeanFMServer" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "ImplementationProposed" "LeanFMServer" "UserBrowser" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "ImplementationCommitted" "UserBrowser" "LeanFMServer" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "GenerationRequested" "UserBrowser" "LeanFMServer" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "GenerationDispatched" "LeanFMServer" "ModelProvider" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "PatchReturned" "ModelProvider" "LeanFMServer" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "VerificationReported" "LeanFMServer" "UserBrowser" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "PRDelivered" "LeanFMServer" "UserBrowser" [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "artifact_digest" .string]
  , LeanFM.ChatUI.Requirements.message "WorkflowRejected" "LeanFMServer" "UserBrowser"
      [LeanFM.ChatUI.Requirements.field 1 "project_id" .string, LeanFM.ChatUI.Requirements.field 2 "snapshot_id" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string, LeanFM.ChatUI.Requirements.field 4 "reason" .string] ]

def workflow : TaskRequirement :=
  { id := "selfhost_workflow", title := "Revision-bound requirements to a verified PR"
  , actors := LeanFM.ChatUI.Requirements.spec.actors, initialState := "start"
  , states := [LeanFM.ChatUI.Requirements.state "start" "Start" "selfhost" false, LeanFM.ChatUI.Requirements.state "s1" "RevisionProposed" "selfhost" false, LeanFM.ChatUI.Requirements.state "s2" "RequirementsChecked" "selfhost" false, LeanFM.ChatUI.Requirements.state "s3" "RequirementsCommitted" "selfhost" false, LeanFM.ChatUI.Requirements.state "s4" "ImplementationProposed" "selfhost" false, LeanFM.ChatUI.Requirements.state "s5" "ImplementationCommitted" "selfhost" false, LeanFM.ChatUI.Requirements.state "s6" "GenerationRequested" "selfhost" false, LeanFM.ChatUI.Requirements.state "s7" "GenerationDispatched" "selfhost" false, LeanFM.ChatUI.Requirements.state "s8" "PatchReturned" "selfhost" false, LeanFM.ChatUI.Requirements.state "s9" "VerificationReported" "selfhost" false, LeanFM.ChatUI.Requirements.state "s10" "PRDelivered" "selfhost" true, LeanFM.ChatUI.Requirements.state "rejected" "Workflow rejected" "selfhost" true]
  , transitions := [LeanFM.ChatUI.Requirements.transition "start" "s1" "RevisionProposed", LeanFM.ChatUI.Requirements.transition "s1" "s2" "RequirementsChecked", LeanFM.ChatUI.Requirements.transition "s2" "s3" "RequirementsCommitted", LeanFM.ChatUI.Requirements.transition "s3" "s4" "ImplementationProposed", LeanFM.ChatUI.Requirements.transition "s4" "s5" "ImplementationCommitted", LeanFM.ChatUI.Requirements.transition "s5" "s6" "GenerationRequested", LeanFM.ChatUI.Requirements.transition "s6" "s7" "GenerationDispatched", LeanFM.ChatUI.Requirements.transition "s7" "s8" "PatchReturned", LeanFM.ChatUI.Requirements.transition "s8" "s9" "VerificationReported", LeanFM.ChatUI.Requirements.transition "s9" "s10" "PRDelivered", LeanFM.ChatUI.Requirements.transition "s1" "rejected" "WorkflowRejected"] }

def workflowGrammar : TaskGrammar :=
  { task := workflow.id, entry := "start"
  , terminals := ["s10", "rejected"]
  , body := GrammarExpr.alt
      [ GrammarExpr.seqList [LeanFM.ChatUI.Requirements.atom workflow.id "UserBrowser" "LeanFMServer" "RevisionProposed", LeanFM.ChatUI.Requirements.atom workflow.id "LeanFMServer" "UserBrowser" "RequirementsChecked", LeanFM.ChatUI.Requirements.atom workflow.id "UserBrowser" "LeanFMServer" "RequirementsCommitted", LeanFM.ChatUI.Requirements.atom workflow.id "LeanFMServer" "UserBrowser" "ImplementationProposed", LeanFM.ChatUI.Requirements.atom workflow.id "UserBrowser" "LeanFMServer" "ImplementationCommitted", LeanFM.ChatUI.Requirements.atom workflow.id "UserBrowser" "LeanFMServer" "GenerationRequested", LeanFM.ChatUI.Requirements.atom workflow.id "LeanFMServer" "ModelProvider" "GenerationDispatched", LeanFM.ChatUI.Requirements.atom workflow.id "ModelProvider" "LeanFMServer" "PatchReturned", LeanFM.ChatUI.Requirements.atom workflow.id "LeanFMServer" "UserBrowser" "VerificationReported", LeanFM.ChatUI.Requirements.atom workflow.id "LeanFMServer" "UserBrowser" "PRDelivered"]
      , GrammarExpr.seqList [LeanFM.ChatUI.Requirements.atom workflow.id "UserBrowser" "LeanFMServer" "RevisionProposed",
          LeanFM.ChatUI.Requirements.atom workflow.id "LeanFMServer" "UserBrowser" "WorkflowRejected"] ] }

def workflowProcesses : List RequirementProcess :=
  workflow.actors.map fun actor =>
    LeanFM.ChatUI.Requirements.process actor workflow
      ((workflowMessages.filter (fun m => m.src == actor)).map (·.name))
      ((workflowMessages.filter (fun m => m.dst == actor)).map (·.name))

/-- Agent consultation of the MCP logic tools (selfhost.mcp.logic.*). -/
def logicMessages : List MessageSchema :=
  [ LeanFM.ChatUI.Requirements.message "LogicConsultRequested" "Agent" "LeanFMServer" [LeanFM.ChatUI.Requirements.field 1 "tool" .string, LeanFM.ChatUI.Requirements.field 2 "input_json" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string]
  , LeanFM.ChatUI.Requirements.message "LogicVerdict" "LeanFMServer" "Agent" [LeanFM.ChatUI.Requirements.field 1 "tool" .string, LeanFM.ChatUI.Requirements.field 2 "verdict" .string, LeanFM.ChatUI.Requirements.field 3 "reading" .string, LeanFM.ChatUI.Requirements.field 4 "evidence_json" .string, LeanFM.ChatUI.Requirements.field 5 "bounds" .string, LeanFM.ChatUI.Requirements.field 6 "request_id" .string]
  , LeanFM.ChatUI.Requirements.message "LogicInputRejected" "LeanFMServer" "Agent" [LeanFM.ChatUI.Requirements.field 1 "tool" .string, LeanFM.ChatUI.Requirements.field 2 "reason" .string, LeanFM.ChatUI.Requirements.field 3 "request_id" .string] ]

def logicTask : TaskRequirement :=
  { id := "mcp_logic_consult", title := "An agent consults the MCP logic tools"
  , actors := ["Agent", "LeanFMServer"], initialState := "drafting"
  , states := [LeanFM.ChatUI.Requirements.state "drafting" "Agent drafts a formula, task or event trace" "agent" false,
               LeanFM.ChatUI.Requirements.state "interpreting" "Server interprets the JSON as data within bounds" "server" false,
               LeanFM.ChatUI.Requirements.state "answered" "Verdict, reading and evidence returned" "terminal" true,
               LeanFM.ChatUI.Requirements.state "rejected" "Malformed or oversized input rejected" "terminal" true]
  , transitions := [LeanFM.ChatUI.Requirements.transition "drafting" "interpreting" "LogicConsultRequested",
                    LeanFM.ChatUI.Requirements.transition "interpreting" "answered" "LogicVerdict",
                    LeanFM.ChatUI.Requirements.transition "interpreting" "rejected" "LogicInputRejected"] }

def logicGrammar : TaskGrammar :=
  { task := logicTask.id, entry := "drafting", terminals := ["answered", "rejected"]
  , body := GrammarExpr.seq (LeanFM.ChatUI.Requirements.atom logicTask.id "Agent" "LeanFMServer" "LogicConsultRequested")
      (GrammarExpr.alt [LeanFM.ChatUI.Requirements.atom logicTask.id "LeanFMServer" "Agent" "LogicVerdict",
                        LeanFM.ChatUI.Requirements.atom logicTask.id "LeanFMServer" "Agent" "LogicInputRejected"]) }

def logicProcesses : List RequirementProcess :=
  [ LeanFM.ChatUI.Requirements.process "Agent" logicTask ["LogicConsultRequested"] ["LogicVerdict", "LogicInputRejected"]
  , LeanFM.ChatUI.Requirements.process "LeanFMServer" logicTask ["LogicVerdict", "LogicInputRejected"] ["LogicConsultRequested"] ]

def outputs : List DesiredOutput :=
  [ { id := "selfhost.workflow.interaction", prompt := "Specify LeanFM in LeanFM without depending on chat history."
    , question := "Which revision-bound messages take checked requirements to a verified PR?"
    , kind := .interactionDiagram, eventSource := "selfhost_workflow successful grammar branch"
    , reducer := "project grammar terminals to sender/receiver lifelines in sequence"
    , unit := "messages per project snapshot" }
  , { id := "selfhost.workflow.states", prompt := "Specify LeanFM in LeanFM without depending on chat history."
    , question := "Which states and rejection branches exist in the proposed development workflow?"
    , kind := .stateMachine, eventSource := "selfhost_workflow typed task transitions"
    , reducer := "render task states and message-labeled transitions", unit := "states and transitions" }
  , { id := "selfhost.mcp.interaction", prompt := "Implement MCP and document it as an agent-facing interface."
    , question := "How does an agent acquire the durable book and checked project evidence without mutating project state?"
    , kind := .interactionDiagram, eventSource := "selfhost.mcp.context, selfhost.mcp.readonly, and LeanFM.MCP dispatch methods"
    , reducer := "project initialize, resources/read, and tools/call messages onto Codex, MCP, and project lifelines"
    , unit := "JSON-RPC messages per stateless request" }
  , { id := "selfhost.mcp.logic.interaction", prompt := "Expose our modal logic to MCP, so the server can be consulted to create logic correctly, events for sequence diagrams, and requirements without observable behavior."
    , question := "Which messages carry one logic consultation, and how does malformed or oversized input end?"
    , kind := .interactionDiagram, eventSource := "mcp_logic_consult grammar"
    , reducer := "render the task grammar with both terminal branches", unit := "messages per consultation" }
  , { id := "selfhost.mcp.logic.states", prompt := "Expose our modal logic to MCP."
    , question := "Which states separate interpreting data from answering or rejecting it?"
    , kind := .stateMachine, eventSource := "mcp_logic_consult typed task transitions"
    , reducer := "render task states and message-labelled transitions", unit := "states and transitions" } ]

/-- Product composition; the Worker example stays separately available. -/
def spec : RequirementSpec :=
  { LeanFM.LLMGenerated.SharedProjects.spec with
    id := "leanfm.selfhost", title := "LeanFM Software Engineering self-hosting composition (proposal)"
    actors := LeanFM.LLMGenerated.SharedProjects.spec.actors ++ ["Agent"]
    actorPopulations := LeanFM.LLMGenerated.SharedProjects.spec.actorPopulations ++
      [{ actorSpec := "Agent", instancePrefix := "agent-", count := 4, routing := .sticky "request_id" }]
    actorResources := LeanFM.LLMGenerated.SharedProjects.spec.actorResources ++
      [{ actor := "Agent", inboundCapacity := 16, outboundCapacity := 16, maxInFlight := 4, memoryBudgetBytes := 67108864 }]
    messages := LeanFM.LLMGenerated.SharedProjects.spec.messages ++ workflowMessages ++ logicMessages
    tasks := LeanFM.LLMGenerated.SharedProjects.spec.tasks ++ [workflow, logicTask]
    grammars := LeanFM.LLMGenerated.SharedProjects.spec.grammars ++ [workflowGrammar, logicGrammar]
    processes := LeanFM.LLMGenerated.SharedProjects.spec.processes ++ workflowProcesses ++ logicProcesses
    properties := LeanFM.LLMGenerated.SharedProjects.spec.properties ++
      [{ name := "Revision-bound workflow terminal result", mode := .eventually,
         task := workflow.id, expression := "done or rejected under declared finite bounds", probability := none }
      , { name := "Logic answers carry their evidence", mode := .always, task := logicTask.id, probability := none,
          expression := "AG(answered -> verdict in {proved, disproved, unknown, unsupported, resource-limit} and reading present and (verdict = disproved of a universal claim -> counterexample path present) and (verdict = proved of an existential claim -> witness path present) and bounds stated)" }
      , { name := "Every consultation ends", mode := .always, task := logicTask.id, probability := none,
          expression := "AG(interpreting -> AF(answered or rejected)) within the declared bounds" }]
    requiredProofs := LeanFM.LLMGenerated.SharedProjects.spec.requiredProofs ++
      [{ name := "No unchecked specification authorizes generation", mode := .never,
         task := workflow.id, predicate := "generation from a snapshot whose requirements or implementation mapping has not passed its current canonical check", probability := none }
      , { name := "Submitted logic never runs as code", mode := .never, task := logicTask.id, probability := none,
          predicate := "a submitted formula, task, trace or predicate text is compiled, evaluated or executed as Lean, shell or other code, reads a file path, or changes project state" }
      , { name := "Exhausted search never proves", mode := .never, task := logicTask.id, probability := none,
          predicate := "a check that exceeded a declared bound, or used an unsupported atom, reports proved or disproved" }
      , { name := "Hidden predicates never pass as observable", mode := .never, task := logicTask.id, probability := none,
          predicate := "classify_requirement or check_ctl treats a derived or implementation-only atom as an observable message, field or state" }]
    desiredOutputs := LeanFM.LLMGenerated.SharedProjects.spec.desiredOutputs ++ outputs
    markdown := LeanFM.LLMGenerated.SharedProjects.spec.markdown ++ clauses.map (fun c =>
      { id := c.id, title := c.area ++ " (" ++ c.status ++ ")", body := c.requirement }) }

def errors : List String :=
  validateRequirementSpec spec ++
  validateRequirementProtoFile LeanFM.ChatUI.Requirements.spec LeanFM.ChatUI.Requirements.protoSource ++
  validateRequirementProtoFile { spec with messages := workflowMessages ++ logicMessages } workflowProto ++
  (clauses.filterMap fun c => if c.id.isEmpty || c.requirement.isEmpty then some "empty self-hosting clause" else none) ++
  (duplicateStrings (clauses.map (·.id))).map (fun id => "duplicate self-hosting clause: " ++ id)

/-- Projection of the first (successful) sequential grammar branch, not a trace
    claiming that implementation execution has occurred. -/
def successfulBranchAtoms : GrammarExpr -> List GrammarAtom
  | .event atom => [atom]
  | .seq left right => successfulBranchAtoms left ++ successfulBranchAtoms right
  | .choice branches => match branches with
    | [] => []
    | first :: _ => successfulBranchAtoms first
  | _ => []

def interaction : String :=
  joinWithNewline <| ["sequenceDiagram"] ++
    workflow.actors.map (fun actor => "    participant " ++ actor) ++
    (successfulBranchAtoms workflowGrammar.body).map (fun atom =>
      "    " ++ atom.src ++ "->>" ++ atom.dst ++ ": " ++ atom.message ++ "(snapshot_id)")

/-- Render a sequence/choice grammar as a Mermaid sequence diagram, every branch included. -/
partial def grammarLines : GrammarExpr -> List String
  | .event atom => ["    " ++ atom.src ++ "->>" ++ atom.dst ++ ": " ++ atom.message]
  | .seq left right => grammarLines left ++ grammarLines right
  | .choice branches =>
      match branches with
      | [] => []
      | first :: rest =>
          ["    alt branch 1"] ++ grammarLines first ++
          (rest.zipIdx.flatMap fun (b, i) => ["    else branch " ++ toString (i + 2)] ++ grammarLines b) ++ ["    end"]
  | _ => []

def logicInteraction : String :=
  joinWithNewline <| ["sequenceDiagram", "    participant Agent", "    participant LeanFMServer"] ++ grammarLines logicGrammar.body

def report : String :=
  "# Self-hosting requirements review\n\nStatus: proposal. Review and acceptance happen in git.\n\n" ++
  "Product composition: ChatUI requirements plus revision-bound requirements-to-PR workflow.\n" ++
  "Worker example: retained separately, not the specification of the whole product.\n\n" ++
  "## Component registry\n\n" ++
  joinWithNewline (components.map (fun c => "- " ++ c.id ++ ": " ++ c.requirements ++ "; " ++ c.protobuf ++ "; " ++ c.implementation ++ " — " ++ c.status)) ++ "\n\n" ++
  "## Generated interaction: successful proposed workflow\n\n```mermaid\n" ++ interaction ++ "\n```\n\n" ++
  "## Generated state machine\n\n```mermaid\n" ++ LeanFM.ChatUI.Requirements.stateMachineMermaid workflow ++ "\n```\n\n" ++
  "## Generated interaction: MCP logic consultation\n\n```mermaid\n" ++ logicInteraction ++ "\n```\n\n" ++
  "## Proposed clauses (not semantic proofs)\n\n" ++
  joinWithNewline (clauses.map (fun c => "- " ++ c.id ++ " [" ++ c.status ++ "]: " ++ c.requirement)) ++
  "\n\nImplementation mapping: pending for workflow and checker extensions. Existing ChatUI mappings remain in LeanFM/ChatUI/Implementation.lean.\n"

end LeanFM.LLMGenerated.SelfHosting
