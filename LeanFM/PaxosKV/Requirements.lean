import LeanFM.Artifacts

namespace LeanFM.PaxosKV.Requirements

def protoSource : String := include_str "Requirements.proto"
def framing : MessageFraming := { kind := .protobufMessage, dispatchField := some "type", note := "Length-delimited protobuf Envelope atom." }
def field (n : Nat) (name : String) (scalar : ProtoScalar) : ProtoFieldSchema := { number := n, name, scalar }
def message (name src dst : String) (fields : List ProtoFieldSchema) : MessageSchema := { name, src, dst, framing, fields }

def messages : List MessageSchema :=
  [ message "PutRequest" "Browser" "WebApp" [field 1 "session" .string, field 2 "request_id" .string, field 3 "key" .string, field 4 "value" .string]
  , message "Propose" "WebApp" "KVReplica" [field 1 "request_id" .string, field 2 "key" .string, field 3 "value" .string]
  , message "Prepare" "KVReplica" "KVReplica" [field 1 "ballot_counter" .uint64, field 2 "ballot_node" .string, field 3 "slot" .uint64]
  , message "Promise" "KVReplica" "KVReplica" [field 1 "ballot_counter" .uint64, field 2 "ballot_node" .string, field 3 "slot" .uint64]
  , message "Accept" "KVReplica" "KVReplica" [field 1 "ballot_counter" .uint64, field 2 "ballot_node" .string, field 3 "slot" .uint64, field 4 "key" .string, field 5 "value" .string]
  , message "DurableAccepted" "KVReplica" "KVReplica" [field 1 "ballot_counter" .uint64, field 2 "ballot_node" .string, field 3 "slot" .uint64]
  , message "Commit" "KVReplica" "KVReplica" [field 1 "slot" .uint64, field 2 "key" .string, field 3 "value" .string]
  , message "PutResult" "KVReplica" "WebApp" [field 1 "request_id" .string, field 2 "slot" .uint64, field 3 "success" .bool]
  , message "PutResponse" "WebApp" "Browser" [field 1 "request_id" .string, field 2 "slot" .uint64, field 3 "success" .bool]
  , message "ListRequest" "Browser" "WebApp" [field 1 "session" .string, field 2 "request_id" .string]
  , message "ReadBarrier" "WebApp" "KVReplica" [field 1 "request_id" .string]
  , message "ReadBarrierAck" "KVReplica" "KVReplica" [field 1 "committed_slot" .uint64]
  , message "Snapshot" "KVReplica" "WebApp" [field 1 "committed_slot" .uint64, field 2 "entries" .bytes]
  , message "ListResponse" "WebApp" "Browser" [field 1 "committed_slot" .uint64, field 2 "entries" .bytes]
  , message "Unavailable" "KVReplica" "WebApp" [field 1 "replica_id" .string]
  , message "Restarted" "KVReplica" "WebApp" [field 1 "replica_id" .string]
  , message "RecoverAcceptedLog" "KVReplica" "KVReplica" [field 1 "replica_id" .string, field 2 "committed_slot" .uint64]
  , message "Available" "KVReplica" "WebApp" [field 1 "replica_id" .string, field 2 "committed_slot" .uint64]
  ]

def state (id label group : String) (terminal : Bool := false) : RequirementState := { id, label, group, markdown := label, terminal }
def transition (src dst msg : String) (ms : Nat := 1) : RequirementTransition := { src, dst, message := msg, probabilityNum := 1, probabilityDen := 1, dwellMs := ms }

def writeTask : TaskRequirement :=
  { id := "quorum_write", title := "Durable quorum write", actors := ["Browser", "WebApp", "KVReplica"], initialState := "start"
  , states := [state "start" "browser form ready" "browser", state "requested" "PUT received" "web", state "proposed" "slot proposed" "consensus", state "preparing" "prepare in flight" "consensus", state "promised" "prepare quorum" "consensus", state "accepting" "accept in flight" "consensus", state "accepted" "durable accept quorum" "durability", state "committed" "slot committed" "consensus", state "result" "result at web app" "web", state "done" "listing includes write" "terminal" true]
  , transitions := [transition "start" "requested" "PutRequest", transition "requested" "proposed" "Propose", transition "proposed" "preparing" "Prepare", transition "preparing" "preparing" "Promise", transition "preparing" "promised" "Promise", transition "promised" "accepting" "Accept", transition "accepting" "accepting" "DurableAccepted", transition "accepting" "accepted" "DurableAccepted", transition "accepted" "committed" "Commit", transition "committed" "result" "PutResult", transition "result" "done" "PutResponse"] }

def listTask : TaskRequirement :=
  { id := "linearizable_list", title := "Linearizable complete listing", actors := ["Browser", "WebApp", "KVReplica"], initialState := "start"
  , states := [state "start" "browser requests listing" "browser", state "requested" "list received" "web", state "barrier" "quorum read barrier" "consensus", state "snapshot" "one committed prefix" "consensus", state "done" "listing rendered" "terminal" true]
  , transitions := [transition "start" "requested" "ListRequest", transition "requested" "barrier" "ReadBarrier", transition "barrier" "barrier" "ReadBarrierAck", transition "barrier" "snapshot" "Snapshot", transition "snapshot" "done" "ListResponse"] }

def recoveryTask : TaskRequirement :=
  { id := "recover_replica", title := "Durable replica recovery", actors := ["WebApp", "KVReplica"], initialState := "available"
  , states := [state "available" "replica available" "service", state "down" "replica unavailable" "outage", state "restarted" "process restarted" "recovery", state "catching_up" "durable log recovery" "recovery", state "done" "replica caught up" "terminal" true]
  , transitions := [transition "available" "down" "Unavailable", transition "down" "restarted" "Restarted", transition "restarted" "catching_up" "RecoverAcceptedLog", transition "catching_up" "done" "Available"] }

def atom (task src dst msg : String) : GrammarExpr := .event { task, src, dst, message := msg }
def writeGrammar : TaskGrammar :=
  { task := "quorum_write", entry := "start", terminals := ["done"], body := GrammarExpr.seqList
      [ atom "quorum_write" "Browser" "WebApp" "PutRequest", atom "quorum_write" "WebApp" "KVReplica" "Propose"
      , atom "quorum_write" "KVReplica" "KVReplica" "Prepare"
      , .mOfN 2 [atom "quorum_write" "KVReplica" "KVReplica" "Promise", atom "quorum_write" "KVReplica" "KVReplica" "Promise", atom "quorum_write" "KVReplica" "KVReplica" "Promise"]
      , atom "quorum_write" "KVReplica" "KVReplica" "Accept"
      , .mOfN 2 [atom "quorum_write" "KVReplica" "KVReplica" "DurableAccepted", atom "quorum_write" "KVReplica" "KVReplica" "DurableAccepted", atom "quorum_write" "KVReplica" "KVReplica" "DurableAccepted"]
      , atom "quorum_write" "KVReplica" "KVReplica" "Commit", atom "quorum_write" "KVReplica" "WebApp" "PutResult", atom "quorum_write" "WebApp" "Browser" "PutResponse"] }
def listGrammar : TaskGrammar := { task := "linearizable_list", entry := "start", terminals := ["done"], body := GrammarExpr.seqList [atom "linearizable_list" "Browser" "WebApp" "ListRequest", atom "linearizable_list" "WebApp" "KVReplica" "ReadBarrier", .mOfN 2 [atom "linearizable_list" "KVReplica" "KVReplica" "ReadBarrierAck", atom "linearizable_list" "KVReplica" "KVReplica" "ReadBarrierAck", atom "linearizable_list" "KVReplica" "KVReplica" "ReadBarrierAck"], atom "linearizable_list" "KVReplica" "WebApp" "Snapshot", atom "linearizable_list" "WebApp" "Browser" "ListResponse"] }
def recoveryGrammar : TaskGrammar := { task := "recover_replica", entry := "available", terminals := ["done"], body := GrammarExpr.seqList [atom "recover_replica" "KVReplica" "WebApp" "Unavailable", atom "recover_replica" "KVReplica" "WebApp" "Restarted", atom "recover_replica" "KVReplica" "KVReplica" "RecoverAcceptedLog", atom "recover_replica" "KVReplica" "WebApp" "Available"] }

def process (actor task : String) (sends receives : List String) : RequirementProcess :=
  let states :=
    if task == "quorum_write" then ["start", "requested", "proposed", "preparing", "promised", "accepting", "accepted", "committed", "result", "done"]
    else if task == "linearizable_list" then ["start", "requested", "barrier", "snapshot", "done"]
    else ["available", "down", "restarted", "catching_up", "done"]
  { actor, task, states, sends, receives }
def processes : List RequirementProcess :=
  [ process "Browser" "quorum_write" ["PutRequest"] ["PutResponse"], process "WebApp" "quorum_write" ["Propose", "PutResponse"] ["PutRequest", "PutResult"], process "KVReplica" "quorum_write" ["Prepare", "Promise", "Accept", "DurableAccepted", "Commit", "PutResult"] ["Propose", "Prepare", "Promise", "Accept", "DurableAccepted", "Commit"]
  , process "Browser" "linearizable_list" ["ListRequest"] ["ListResponse"], process "WebApp" "linearizable_list" ["ReadBarrier", "ListResponse"] ["ListRequest", "Snapshot"], process "KVReplica" "linearizable_list" ["ReadBarrierAck", "Snapshot"] ["ReadBarrier", "ReadBarrierAck"]
  , process "WebApp" "recover_replica" [] ["Unavailable", "Restarted", "Available"], process "KVReplica" "recover_replica" ["Unavailable", "Restarted", "RecoverAcceptedLog", "Available"] ["RecoverAcceptedLog"] ]

def outputs : List DesiredOutput :=
  [ { id := "paxos.write.interaction", prompt := "Show how a browser write becomes persistent.", question := "Which two replicas durably accepted before success?", kind := .interactionDiagram, eventSource := "quorum_write events", reducer := "partition by (session,request_id), render prior order and 2-of-3 join", unit := "events" }
  , { id := "paxos.write.state_machine", prompt := "Show the write state machine.", question := "Which write states are reachable?", kind := .stateMachine, eventSource := "quorum_write grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "paxos.list.interaction", prompt := "Show how all key/value pairs are listed.", question := "Which quorum prefix supplied the list?", kind := .interactionDiagram, eventSource := "linearizable_list events", reducer := "render browser, web, and quorum lifelines", unit := "events" }
  , { id := "paxos.list.state_machine", prompt := "Show the list state machine.", question := "Which list states are reachable?", kind := .stateMachine, eventSource := "linearizable_list grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "paxos.concurrent.order", prompt := "Access the app concurrently from two browser sessions.", question := "Which browser branches commute before slot assignment?", kind := .interactionDiagram, eventSource := "two-session events", reducer := "render prior-pointer fork, slot ordering, quorum joins, and responses", unit := "events" }
  , { id := "paxos.commit_latency", prompt := "Measure concurrent browser access.", question := "How does write latency change with concurrent sessions?", kind := .function2d, eventSource := "paired PUT start and result events", reducer := "x=max concurrent sessions; y=result.timeAt-start.timeAt", unit := "milliseconds" }
  , { id := "paxos.quorum_size", prompt := "Require persistence with two stores up.", question := "How many distinct replicas durably accepted each acknowledged slot?", kind := .scalar, eventSource := "DurableAccepted and PutResponse events", reducer := "distinct accepting instances per acknowledged slot", unit := "replicas" }
  , { id := "paxos.replica_availability", prompt := "Assume two replicas are always up.", question := "Were at least two replicas available?", kind := .function2d, eventSource := "Unavailable and Available events", reducer := "sweep outage intervals", unit := "available replicas over milliseconds" }
  , { id := "paxos.recovery_lag", prompt := "Retain data if all replicas go down.", question := "How far behind is each restarting replica?", kind := .function2d, eventSource := "Restarted, RecoverAcceptedLog, and Available events", reducer := "leader committed slot minus replica applied slot", unit := "slots over milliseconds" }
  , { id := "paxos.outcomes", prompt := "Show request outcomes.", question := "What happened to browser requests?", kind := .scalar, eventSource := "terminal browser events", reducer := "count success, rejection, timeout, and leadership loss", unit := "requests" } ]

def spec : RequirementSpec :=
  { id := "paxos_kv.visible_behavior", title := "Three-replica Paxos key-value web application", actors := ["Browser", "WebApp", "KVReplica"]
  , actorPopulations := [{actorSpec := "Browser", instancePrefix := "browser-", count := 2, routing := .sticky "session"}, {actorSpec := "WebApp", instancePrefix := "web-", count := 1, routing := .roundRobin}, {actorSpec := "KVReplica", instancePrefix := "kv-", count := 3, routing := .sticky "replica_id"}]
  , actorResources := [{actor := "Browser", inboundCapacity := 8, outboundCapacity := 8, maxInFlight := 2, memoryBudgetBytes := 1048576}, {actor := "WebApp", inboundCapacity := 128, outboundCapacity := 128, maxInFlight := 64, memoryBudgetBytes := 67108864}, {actor := "KVReplica", inboundCapacity := 256, outboundCapacity := 256, maxInFlight := 64, memoryBudgetBytes := 134217728}]
  , actorReliability := [{actor := "Browser", outageProbability := {numerator := 0, denominator := 1}, meanTimeToRepairMs := 0}, {actor := "WebApp", outageProbability := {numerator := 0, denominator := 1}, meanTimeToRepairMs := 0}, {actor := "KVReplica", outageProbability := {numerator := 1, denominator := 1000}, meanTimeToRepairMs := 1000}]
  , actorCosts := [], messages, tasks := [writeTask, listTask, recoveryTask], grammars := [writeGrammar, listGrammar, recoveryGrammar], processes
  , properties := [{name := "No success before durable quorum", mode := .never, task := "quorum_write", expression := "PutResponse(success) without two prior distinct DurableAccepted", probability := some {numerator := 0, denominator := 1}}, {name := "Last committed slot wins", mode := .always, task := "linearizable_list", expression := "each key maps to its greatest committed slot", probability := some {numerator := 1, denominator := 1}}, {name := "Recovery precedes availability", mode := .always, task := "recover_replica", expression := "Available implies prior RecoverAcceptedLog", probability := some {numerator := 1, denominator := 1}}]
  , requiredProofs := [{name := "Durable quorum before acknowledgment", mode := .always, task := "quorum_write", predicate := "two distinct fsynced DurableAccepted precede successful PutResponse", probability := some {numerator := 1, denominator := 1}}, {name := "Possibly one replica unavailable", mode := .possibly, task := "recover_replica", predicate := "Unavailable", probability := some {numerator := 1, denominator := 1000}, handlingPlan := some "Continue on the two-replica quorum, then recover and catch up the restarted replica."}]
  , performance := [{name := "browser write completion rate", task := "quorum_write", metric := .clientExperiencedRate, workField := "committed_writes", minimumWork := 1, perMilliseconds := 10000}]
  , charts := [{name := "commit latency by concurrency", kind := .xy, source := "paired write events", groupBy := some "max_concurrent_sessions", value := "latency_ms"}, {name := "request outcomes", kind := .pie, source := "terminal browser events", groupBy := some "outcome", value := "count"}], desiredOutputs := outputs
  , markdown := [{id := "durability", title := "Durability boundary", body := "Success follows two fsynced acceptances. Total shutdown causes unavailability, not data loss; quorum recovery runs before service resumes."}, {id := "bounds", title := "Input and capacity bounds", body := "Keys are 1..128 UTF-8 bytes, values at most 4096 UTF-8 bytes, and at most 10000 distinct keys are committed."}] }

def validationReport : String := match validateRequirementSpec spec with | [] => "ok: Paxos KV requirements are well formed\n" | es => "invalid Paxos KV requirements\n" ++ joinWithNewline es ++ "\n"

end LeanFM.PaxosKV.Requirements
