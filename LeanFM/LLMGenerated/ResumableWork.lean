import LeanFM.Artifacts

/- Candidate requirements for client-driven, resumable ChatUI work.
   Prompt: break work into smaller steps instead of failing at a tool-step cap.
   Neither stakeholder acceptance gate is inferred by this candidate. -/
namespace LeanFM.LLMGenerated.ResumableWork
open LeanFM

def task : TaskRequirement :=
  { id := "resume_project_work", title := "Continue one requested task across bounded client batches"
  , actors := ["UserBrowser", "LeanFMServer"], initialState := "idle"
  , states := [
      {id := "idle", label := "Ready", group := "client", markdown := "No active requested work", terminal := false},
      {id := "submitted", label := "One bounded batch running", group := "server", markdown := "Same captured project, caller and model", terminal := false},
      {id := "checkpointed", label := "Progress saved; client continues", group := "client", markdown := "A batch limit is not a task failure", terminal := false},
      {id := "cancelling", label := "Cancellation requested", group := "server", markdown := "No new batch or tool starts", terminal := false},
      {id := "complete", label := "Requested outcome complete", group := "terminal", markdown := "Artifacts and validation justify completion", terminal := true},
      {id := "blocked", label := "Concrete blocker", group := "terminal", markdown := "Failure retained; no blind paid retry", terminal := true},
      {id := "gate", label := "Human decision required", group := "terminal", markdown := "Separate acceptance remains explicit", terminal := true},
      {id := "cancelled", label := "Cancelled", group := "terminal", markdown := "Earlier edits and usage retained", terminal := true} ]
  , transitions := [
      {src := "idle", dst := "submitted", message := "WorkSubmitted", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "submitted", dst := "checkpointed", message := "WorkCheckpointed", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "checkpointed", dst := "submitted", message := "WorkContinued", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "submitted", dst := "complete", message := "WorkCompleted", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "submitted", dst := "blocked", message := "WorkBlocked", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "submitted", dst := "gate", message := "WorkNeedsDecision", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "submitted", dst := "cancelling", message := "WorkCancelRequested", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "checkpointed", dst := "cancelling", message := "WorkCancelRequested", probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
      {src := "cancelling", dst := "cancelled", message := "WorkCancelled", probabilityNum := 1, probabilityDen := 1, dwellMs := 0} ] }

def messages : List MessageSchema :=
  ["WorkSubmitted", "WorkCheckpointed", "WorkContinued", "WorkCompleted", "WorkBlocked",
   "WorkNeedsDecision", "WorkCancelRequested", "WorkCancelled"].map fun name =>
    let client := ["WorkSubmitted", "WorkContinued", "WorkCancelRequested"].contains name
    {name, src := if client then "UserBrowser" else "LeanFMServer",
     dst := if client then "LeanFMServer" else "UserBrowser",
     framing := {kind := .protobufMessage, dispatchField := none, note := "One framed job event; task and checkpoint IDs are server-authorized, not model instructions"},
     fields := [{number := 1, name := "project_id", scalar := .string},
                {number := 2, name := "work_id", scalar := .string},
                {number := 3, name := "checkpoint_id", scalar := .string}]}

def atom (name : String) : GrammarExpr :=
  let client := ["WorkSubmitted", "WorkContinued", "WorkCancelRequested"].contains name
  .event {task := task.id, src := if client then "UserBrowser" else "LeanFMServer",
          dst := if client then "LeanFMServer" else "UserBrowser", message := name}

def grammar : TaskGrammar :=
  { task := task.id, entry := "idle"
  , terminals := ["complete", "blocked", "gate", "cancelled"]
  , body := .seq (atom "WorkSubmitted") (.seq (.repeat (.seq (atom "WorkCheckpointed") (atom "WorkContinued")))
      (.choice [atom "WorkCompleted", atom "WorkBlocked", atom "WorkNeedsDecision",
        .seq (atom "WorkCancelRequested") (atom "WorkCancelled"),
        .seq (atom "WorkCheckpointed") (.seq (atom "WorkCancelRequested") (atom "WorkCancelled"))])) }

def spec : RequirementSpec :=
  { id := "leanfm.resumable-work", title := "Client-driven bounded batches for one requested project task"
  , actors := task.actors
  , actorPopulations := task.actors.map fun actor => {actorSpec := actor, instancePrefix := actor, count := 1, routing := .sticky "work_id"}
  , actorResources := task.actors.map fun actor => {actor, inboundCapacity := 16, outboundCapacity := 16, maxInFlight := 1, memoryBudgetBytes := 16777216}
  , actorReliability := [], reliabilityGates := [], actorCosts := [], messages, tasks := [task]
  , grammars := [grammar]
  , processes := task.actors.map fun actor =>
      { actor, task := task.id, states := task.states.map (·.id)
      , sends := (messages.filter (·.src == actor)).map (·.name)
      , receives := (messages.filter (·.dst == actor)).map (·.name) }
  , properties := [
      {name := "Batch exhaustion preserves requested work", task := task.id, mode := .always,
       expression := "A bounded batch that exhausts its tool rounds saves a valid continuation; the client continues the same requested work instead of displaying a terminal step-limit warning", probability := none},
      {name := "Only the requested scope is continued", task := task.id, mode := .always,
       expression := "Automatic batches stop at the requested outcome, explicit human gates, cancellation, ended credentials, unchanged failure, unavailable dependency or the existing cumulative session spend boundary", probability := none}]
  , requiredProofs := [
      {name := "No replay or cross-caller continuation", task := task.id, mode := .never,
       predicate := "a reused stale checkpoint repeats a paid request or mutation, or resumes with a different project caller credential model or original task", probability := none},
      {name := "No reset of safety or acceptance across batches", task := task.id, mode := .never,
       predicate := "a new batch resets cumulative usage cancellation failed-tool history source gates or acceptance revisions, stores a key or session bearer in project state, or retries an ambiguous failed provider request", probability := none},
      {name := "No continuation without useful progress", task := task.id, mode := .never,
       predicate := "unchanged failures or repeated read-only work become an endless billable loop, or a closed client starts additional batches", probability := none}]
  , performance := [], charts := []
  , desiredOutputs := [
      {id := "resumable-work.interaction", prompt := "Break tasks up to get through the arbitrary step limit; we have a client for this reason",
       question := "How does the client continue the same requested work at a batch checkpoint and stop on completion, a gate, cancellation or a blocker?",
       kind := .interactionDiagram, eventSource := "resume_project_work grammar", reducer := "render candidate grammar branches without claiming observed durations or probabilities", unit := "framed work events within one original project task"},
      {id := "resumable-work.state", prompt := "Tasks do not all need to happen in one go",
       question := "Which states distinguish an internal batch checkpoint from a real terminal outcome?",
       kind := .stateMachine, eventSource := "resume_project_work task", reducer := "render task transitions", unit := "states of one original task; acceptance and session budgets remain external guards"}]
  , markdown := [{id := "compatibility", title := "Candidate wire extension and compatibility", body := "Keep existing chat submissions and completed response fields compatible. Add server-issued work/checkpoint continuation metadata to successful batch responses and accept that metadata only with the same authenticated caller, project and model. Existing clients that ignore continuation metadata can display progress and manually resume; they must not receive a false success or silently replay work. The model cannot forge client scheduling authority through answer text."}] }
end LeanFM.LLMGenerated.ResumableWork
