import LeanFM.Protocol
import LeanFM.UiModel
import LeanFM.GeneratedRequirements
import LeanFM.StaticAssets

namespace LeanFM

def joinWith (sep : String) : List String -> String
  | [] => ""
  | [x] => x
  | x :: xs => x ++ sep ++ joinWith sep xs

def actorName : Actor -> String
  | Actor.auth => "Auth"
  | Actor.db => "DB"
  | Actor.client => "Client"
  | Actor.gateway => "Gateway"
  | Actor.worker => "Worker"

def actorStateName : ActorState -> String
  | ActorState.idle => "idle"
  | ActorState.waiting => "waiting"
  | ActorState.queued => "queued"
  | ActorState.busy => "busy"
  | ActorState.sleeping => "sleeping"
  | ActorState.done => "done"
  | ActorState.failed => "failed"

def bytesName (bytes : List Nat) : String :=
  "[" ++ joinWith " " (bytes.map toString) ++ "]"

def protoFieldName (f : ProtoField) : String :=
  s!"{f.number}:{f.name}={f.value}"

def protoFieldsName (fields : List ProtoField) : String :=
  "{" ++ joinWith ", " (fields.map protoFieldName) ++ "}"

def transportName : Transport -> String
  | Transport.http => "http"
  | Transport.https => "https"

def taskName : TaskKind -> String
  | TaskKind.purchaseItem => "get_docs"
  | TaskKind.postReview => "post_review"
  | TaskKind.auth => "auth"

def activeTaskName : Option TaskKind -> String
  | some task => taskName task
  | none => "none"

def proofName : Option AuthProof -> String
  | some p => s!"proof({actorName p.issuedBy}->{actorName p.issuedTo}:{bytesName p.bytes})"
  | none => "no-proof"

def envelopeName (e : Envelope) : String :=
  s!"wrapper(task={taskName e.task}, src={actorName e.src}, dst={actorName e.dst}, via={transportName e.transport}, ts={e.ts}); protobuf(type={e.proto.typeName}, bytes={bytesName e.proto.bytes}, fields={protoFieldsName e.proto.fields})"

def optionEnvelopeName : Option Envelope -> String
  | some e => envelopeName e
  | none => "empty"

def stateName (s : Observation) : String :=
  s!"task={activeTaskName s.task}; auth={proofName s.proof}; Client={actorStateName s.client} q={s.clientQ}/{cap Actor.client} head={optionEnvelopeName s.clientMsg}; Gateway={actorStateName s.gateway} q={s.gatewayQ}/{cap Actor.gateway} head={optionEnvelopeName s.gatewayMsg}; Worker={actorStateName s.worker} q={s.workerQ}/{cap Actor.worker} head={optionEnvelopeName s.workerMsg}"

def compactHeadName : Option Envelope -> String
  | some e => e.proto.typeName
  | none => "-"

def authMark (s : Observation) : String :=
  if hasValidAuth s then "auth ok" else "no auth"

def compactStateName (s : Observation) : String :=
  s!"task={activeTaskName s.task}\\nC {actorStateName s.client} q={s.clientQ}/{cap Actor.client} h={compactHeadName s.clientMsg}\\nG {actorStateName s.gateway} q={s.gatewayQ}/{cap Actor.gateway} h={compactHeadName s.gatewayMsg}\\nW {actorStateName s.worker} q={s.workerQ}/{cap Actor.worker} h={compactHeadName s.workerMsg}\\n{authMark s}"

def authStateName (s : AuthObservation) : String :=
  s!"{proofName s.proof}; Auth={actorStateName s.auth} q={s.authQ}/{authCap Actor.auth}; DB={actorStateName s.db} q={s.dbQ}/{authCap Actor.db}"

def blockReasonName : BlockReason -> String
  | BlockReason.readEmpty => "sleep(read empty)"
  | BlockReason.writeFull => "sleep(write full)"

def turnName (t : Turn) : String :=
  let emitted :=
    match t.emitted with
    | some e => envelopeName e
    | none => "no message"
  let blocked :=
    match t.blocked with
    | some reason => s!" {blockReasonName reason}"
    | none => ""
  s!"schedule {actorName t.actor}: {emitted}{blocked}"

def compactTurnName (t : Turn) : String :=
  match t.emitted with
  | some e => s!"{actorName t.actor}: {e.proto.typeName} {protoFieldsName e.proto.fields}"
  | none =>
      match t.blocked with
      | some reason => s!"{actorName t.actor}: {blockReasonName reason}"
      | none => s!"{actorName t.actor}: no message"

def transitionLine (t : Observation × Turn × Observation) : String :=
  s!"{stateName t.1} -- {turnName t.2.1} --> {stateName t.2.2}"

def authTransitionLine (t : AuthObservation × Turn × AuthObservation) : String :=
  s!"{authStateName t.1} -- {turnName t.2.1} --> {authStateName t.2.2}"

def dotLine (t : Observation × Turn × Observation) : String :=
  s!"  \"{stateName t.1}\" -> \"{stateName t.2.2}\" [label=\"{turnName t.2.1}\"];"

def compactDotLine (t : Observation × Turn × Observation) : String :=
  s!"  \"{compactStateName t.1}\" -> \"{compactStateName t.2.2}\" [label=\"{compactTurnName t.2.1}\"];"

def authTransitions : List (AuthObservation × Turn × AuthObservation) :=
  (authStates.map fun s =>
    (authChoices s).flatMap fun c =>
      (Choice.labeledSupport c).map fun step => (s, step.1, step.2)).flatten

def authDotLine (t : AuthObservation × Turn × AuthObservation) : String :=
  s!"  \"{authStateName t.1}\" -> \"{authStateName t.2.2}\" [label=\"{turnName t.2.1}\"];"

def graphStyle : List String :=
  [ "  rankdir=TB;"
  , "  graph [bgcolor=\"#111111\", pad=\"0.35\", nodesep=\"0.55\", ranksep=\"0.7\"];"
  , "  node [shape=box, style=\"rounded,filled\", fillcolor=\"black\", color=\"white\", fontcolor=\"white\", fontname=\"Arial\", fontsize=\"18\", margin=\"0.18,0.12\"];"
  , "  edge [fontname=\"Arial\", fontsize=\"14\", penwidth=\"2\", color=\"white\", fontcolor=\"white\"];"
  ]

def graphDot : String :=
  joinWith "\n" <|
    [ "digraph protocol {" ] ++
    graphStyle ++
    (states.map fun s => s!"  \"{compactStateName s}\";") ++
    (transitions.map compactDotLine) ++
    ["}"]

def clusterDot (clusterId label : String) (clusterStates : List Observation) : List String :=
  [ "  subgraph cluster_" ++ clusterId ++ " {"
  , s!"    label=\"{label}\";"
  , "    color=\"white\";"
  , "    fontcolor=\"white\";"
  , "    style=\"rounded\";"
  ] ++
  (clusterStates.map fun s => s!"    \"{compactStateName s}\";") ++
  ["  }"]

def unauthenticatedStates : List Observation :=
  [unauthenticatedInitial, unauthorized]

def noActiveTaskStates : List Observation :=
  [initial, succeeded, failed]

def getDocsActiveStates : List Observation :=
  [afterSubmit, afterDispatch, afterWorkerOk, afterWorkerFail, afterReply, afterReject]

def postReviewActiveStates : List Observation :=
  [reviewAfterSubmit, reviewAfterDispatch, reviewAfterWorkerOk, reviewAfterWorkerFail
  , reviewAfterReply, reviewAfterReject
  ]

def groupedGraphDot : String :=
  joinWith "\n" <|
    [ "digraph protocol {" ] ++
    graphStyle ++
    [ s!"  label=\"worker group overview\\nP(success)={fixed4Text workerMetrics.successNum workerMetrics.successDen}\\nget_docs={fixed4Text purchaseMetrics.successNum purchaseMetrics.successDen}, post_review={fixed4Text reviewMetrics.successNum reviewMetrics.successDen}\";"
    , "  labelloc=\"t\";"
    , "  fontcolor=\"white\";"
    , "  fontsize=\"20\";"
    ] ++
    clusterDot "unauthenticated" "no auth proof" unauthenticatedStates ++
    clusterDot "idle_terminal" "no active task" noActiveTaskStates ++
    clusterDot "get_docs" s!"active task: get_docs, P(success)={fixed4Text purchaseMetrics.successNum purchaseMetrics.successDen}" getDocsActiveStates ++
    clusterDot "post_review" s!"active task: post_review, P(success)={fixed4Text reviewMetrics.successNum reviewMetrics.successDen}" postReviewActiveStates ++
    (transitions.map compactDotLine) ++
    ["}"]

def getDocsStates : List Observation :=
  [initial, afterSubmit, afterDispatch, afterWorkerOk, afterWorkerFail
  , afterReply, afterReject, succeeded, failed
  ]

def postReviewStates : List Observation :=
  [initial, reviewAfterSubmit, reviewAfterDispatch, reviewAfterWorkerOk, reviewAfterWorkerFail
  , reviewAfterReply, reviewAfterReject, succeeded, failed
  ]

def graphDotFor (name : String) (graphStates : List Observation) : String :=
  let graphTransitions := transitions.filter fun t =>
    graphStates.contains t.1 && graphStates.contains t.2.2
  joinWith "\n" <|
    [ "digraph " ++ name ++ " {" ] ++
    graphStyle ++
    (graphStates.map fun s => s!"  \"{compactStateName s}\";") ++
    (graphTransitions.map compactDotLine) ++
    ["}"]

def getDocsGraphDot : String :=
  graphDotFor "get_docs" getDocsStates

def postReviewGraphDot : String :=
  graphDotFor "post_review" postReviewStates

def authGraphDot : String :=
  joinWith "\n" <|
    [ "digraph auth {" ] ++
    graphStyle ++
    (authStates.map fun s => s!"  \"{authStateName s}\";") ++
    (authTransitions.map authDotLine) ++
    ["}"]

def assembledGraphDot : String :=
  joinWith "\n"
    [ "digraph assembled {"
    , "  rankdir=TB;"
    , "  graph [bgcolor=\"#111111\", pad=\"0.35\", nodesep=\"0.55\", ranksep=\"0.7\"];"
    , "  node [shape=box, style=\"rounded,filled\", fillcolor=\"black\", color=\"white\", fontcolor=\"white\", fontname=\"Arial\", fontsize=\"18\", margin=\"0.18,0.12\"];"
    , "  edge [fontname=\"Arial\", fontsize=\"14\", penwidth=\"2\", color=\"white\", fontcolor=\"white\"];"
    , s!"  AuthGroup [label=\"2 actor auth group\\nP(success)={fixed4Text authMetrics.successNum authMetrics.successDen}\\nE(latency)={fixed4Text authMetrics.latencyNum authMetrics.latencyDen}\\nthroughput={fixed4Text authMetrics.throughputNum authMetrics.throughputDen}\"];"
    , s!"  WorkerGroup [label=\"3 actor worker group\\nget_docs + post_review\\nP(success)={fixed4Text workerMetrics.successNum workerMetrics.successDen}\\nE(latency)={fixed4Text workerMetrics.latencyNum workerMetrics.latencyDen}\\nthroughput={fixed4Text workerMetrics.throughputNum workerMetrics.throughputDen}\"];"
    , s!"  Assembled [label=\"assembled system\\nP(success)={fixed4Text assembledMetrics.successNum assembledMetrics.successDen}\\nE(latency)={fixed4Text assembledMetrics.latencyNum assembledMetrics.latencyDen}\\nthroughput={fixed4Text assembledMetrics.throughputNum assembledMetrics.throughputDen}\"];"
    , "  AuthGroup -> WorkerGroup [label=\"on auth success\"];"
    , "  WorkerGroup -> Assembled [label=\"aggregate metrics\"];"
    , "}"
    ]

def taskGraphDot : String :=
  joinWith "\n"
    [ "digraph tasks {"
    , "  rankdir=TB;"
    , "  graph [bgcolor=\"#111111\", pad=\"0.35\", nodesep=\"0.55\", ranksep=\"0.7\"];"
    , "  node [shape=box, style=\"rounded,filled\", fillcolor=\"black\", color=\"white\", fontcolor=\"white\", fontname=\"Arial\", fontsize=\"18\", margin=\"0.18,0.12\"];"
    , "  edge [fontname=\"Arial\", fontsize=\"14\", penwidth=\"2\", color=\"white\", fontcolor=\"white\"];"
    , s!"  Purchase [label=\"get_docs\\nP(success)={fixed4Text purchaseMetrics.successNum purchaseMetrics.successDen}\\nE(latency)={fixed4Text purchaseMetrics.latencyNum purchaseMetrics.latencyDen}\\nthroughput={fixed4Text purchaseMetrics.throughputNum purchaseMetrics.throughputDen}\"];"
    , s!"  Review [label=\"post_review\\nP(success)={fixed4Text reviewMetrics.successNum reviewMetrics.successDen}\\nE(latency)={fixed4Text reviewMetrics.latencyNum reviewMetrics.latencyDen}\\nthroughput={fixed4Text reviewMetrics.throughputNum reviewMetrics.throughputDen}\"];"
    , "  Actors [label=\"shared actors\\nClient, Gateway, Worker\"];"
    , "  Purchase -> Actors [label=\"same actor group\"];"
    , "  Review -> Actors [label=\"same actor group\"];"
    , "}"
    ]

def weightedLine (label : String) (w : Weighted Observation) : String :=
  s!"    {label} [weight={w.weight}, dwell={w.dwell}] -> {stateName w.value}"

def choiceLines (s : Observation) (choice : Choice Observation Turn) : List String :=
  match choice with
  | Choice.action t dwell s' =>
      [s!"  {stateName s} action {turnName t} [dwell={dwell}] -> {stateName s'}"]
  | Choice.chance t outcomes =>
      s!"  {stateName s} chance after {turnName t}:" ::
        outcomes.map (weightedLine (turnName t))
  | Choice.chanceEvents outcomes =>
      s!"  {stateName s} chance:" ::
        outcomes.map fun outcome =>
          s!"    {turnName outcome.value.1} [weight={outcome.weight}, dwell={outcome.dwell}] -> {stateName outcome.value.2}"

def ctlLine (name : String) (formula : CTL Observation) : String :=
  let result := CTL.holds successors initial formula
  s!"{name}: {result}"

def ctlLineFrom (start : Observation) (name : String) (formula : CTL Observation) : String :=
  let result := CTL.holds successors start formula
  s!"{name}: {result}"

def distributionLine (bucket : Nat × Nat) : String :=
  s!"  queue length {bucket.1}: {ratioText bucket.2 expectedLatencyNumerator} = {fixed4Text bucket.2 expectedLatencyNumerator}"

def traceEventName (t : Turn) : String :=
  match t.emitted with
  | some e => s!"src={actorName e.src}, dst={actorName e.dst}, proto={e.proto.typeName}, fields={protoFieldsName e.proto.fields}, ts={e.ts}"
  | none =>
      match t.blocked with
      | some reason => s!"actor={actorName t.actor}, {blockReasonName reason}"
      | none => s!"actor={actorName t.actor}, no message"

def trafficTrace : List Turn -> List String
  | [] => []
  | t :: rest =>
      match t.emitted with
      | some e =>
          if t.actor = e.src then
            traceEventName t :: trafficTrace rest
          else
            trafficTrace rest
      | none => trafficTrace rest

def traceName (trace : List Turn) : String :=
  joinWith "; " (trafficTrace trace)

def terminalLine (path : PathStats Observation Turn) : String :=
  s!"  p={path.mass}/{path.scale}, elapsed={path.elapsed}, state={stateName path.state}, trace=[{traceName path.trace}]"

def metricLine (name : String) (num den : Nat) : String :=
  s!"{name}: {ratioText num den} = {fixed4Text num den}"

def metricsLines (label : String) (m : Metrics) : List String :=
  [ metricLine s!"{label} success probability" m.successNum m.successDen
  , metricLine s!"{label} expected latency" m.latencyNum m.latencyDen
  , metricLine s!"{label} throughput" m.throughputNum m.throughputDen
  ]

def promBool (b : Bool) : Nat :=
  if b then 1 else 0

def promMetricLine (name labels value : String) : String :=
  "leanfm_" ++ name ++ "{" ++ labels ++ "} " ++ value

def promComponentMetrics (component : String) (m : Metrics) : List String :=
  [ promMetricLine "success_probability" s!"component=\"{component}\"" (fixed4Text m.successNum m.successDen)
  , promMetricLine "expected_latency" s!"component=\"{component}\"" (fixed4Text m.latencyNum m.latencyDen)
  , promMetricLine "throughput" s!"component=\"{component}\"" (fixed4Text m.throughputNum m.throughputDen)
  ]

def promTaskMetrics (task : String) (fsm : TaskFSM) (m : Metrics) : List String :=
  promComponentMetrics task m ++
  [ promMetricLine "task_states" s!"task=\"{task}\"" (toString fsm.states.length)
  , promMetricLine "task_transitions" s!"task=\"{task}\"" (toString fsm.transitions.length)
  , promMetricLine "ctl_holds" s!"scope=\"task\",task=\"{task}\",property=\"AF_terminal\"" (toString (promBool (fsm.holds taskTerminates)))
  , promMetricLine "ctl_holds" s!"scope=\"task\",task=\"{task}\",property=\"EF_success\"" (toString (promBool (fsm.holds taskCanSucceed)))
  , promMetricLine "ctl_holds" s!"scope=\"task\",task=\"{task}\",property=\"EF_failure\"" (toString (promBool (fsm.holds taskCanFail)))
  , promMetricLine "ctl_holds" s!"scope=\"task\",task=\"{task}\",property=\"AG_capacity\"" (toString (promBool (fsm.holds taskCapacitySafe)))
  , promMetricLine "ctl_holds" s!"scope=\"task\",task=\"{task}\",property=\"AG_terminal_cleanup\"" (toString (promBool (fsm.holds taskTerminalStatesCleaned)))
  ]

def promMessageCount (task proto : String) (count : Nat) : String :=
  promMetricLine "messages_total" s!"task=\"{task}\",proto=\"{proto}\"" (toString count)

def prometheusMetrics : String :=
  joinWith "\n" <|
    [ "# HELP leanfm_success_probability Weighted success probability by component or task."
    , "# TYPE leanfm_success_probability gauge"
    , "# HELP leanfm_expected_latency Expected dwell-time latency by component or task."
    , "# TYPE leanfm_expected_latency gauge"
    , "# HELP leanfm_throughput Success probability divided by expected latency."
    , "# TYPE leanfm_throughput gauge"
    , "# HELP leanfm_queue_time_weight Time-weighted queue length mass for stacked queue charts."
    , "# TYPE leanfm_queue_time_weight gauge"
    , "# HELP leanfm_ctl_holds CTL property result, encoded as 1 for true and 0 for false."
    , "# TYPE leanfm_ctl_holds gauge"
    , "# HELP leanfm_task_states Number of states in a task FSM."
    , "# TYPE leanfm_task_states gauge"
    , "# HELP leanfm_task_transitions Number of transitions in a task FSM."
    , "# TYPE leanfm_task_transitions gauge"
    , "# HELP leanfm_messages_total Static modeled message count by task and protobuf type."
    , "# TYPE leanfm_messages_total gauge"
    , "# HELP leanfm_grammar_messages_total Static modeled grammar message count by scope."
    , "# TYPE leanfm_grammar_messages_total gauge"
    , "# HELP leanfm_protobuf_parsed Model protobuf parsing check, 1 for true and 0 for false."
    , "# TYPE leanfm_protobuf_parsed gauge"
    , "# HELP leanfm_visible_protocol_messages Number of messages in a typed visible protocol sketch."
    , "# TYPE leanfm_visible_protocol_messages gauge"
    , "# HELP leanfm_visible_protocol_proof_fields Number of observable proof fields in a typed visible protocol sketch."
    , "# TYPE leanfm_visible_protocol_proof_fields gauge"
    , "# HELP leanfm_visible_protocol_assertions Number of assertions attached to a typed visible protocol sketch."
    , "# TYPE leanfm_visible_protocol_assertions gauge"
    ] ++
    promComponentMetrics "auth_group" authMetrics ++
    promTaskMetrics "get_docs" purchaseTaskFSM purchaseMetrics ++
    promTaskMetrics "post_review" reviewTaskFSM reviewMetrics ++
    promComponentMetrics "worker_group" workerMetrics ++
    promComponentMetrics "assembled_system" assembledMetrics ++
    (queueLengthTimeDistribution.map fun bucket =>
      promMetricLine "queue_time_weight" s!"queue_length=\"{bucket.1}\"" (fixed4Text bucket.2 expectedLatencyNumerator)) ++
    [ promMetricLine "ctl_holds" "scope=\"worker\",property=\"AF_success\"" (toString (promBool (CTL.holds successors initial mustEventuallySucceed)))
    , promMetricLine "ctl_holds" "scope=\"worker\",property=\"AG_not_failed\"" (toString (promBool (CTL.holds successors initial neverFails)))
    , promMetricLine "ctl_holds" "scope=\"worker\",property=\"EF_failure\"" (toString (promBool (CTL.holds successors initial mayFail)))
    , promMetricLine "ctl_holds" "scope=\"worker\",property=\"AG_capacity\"" (toString (promBool (CTL.holds successors initial queuesStayWithinCapacity)))
    , promMetricLine "ctl_holds" "scope=\"worker\",property=\"AG_no_success_without_auth\"" (toString (promBool (CTL.holds successors initial noSuccessWithoutAuth)))
    , promMetricLine "ctl_holds" "scope=\"worker\",property=\"AG_queued_heads_select_known_tasks\"" (toString (promBool (CTL.holds successors initial actorQueuesSelectKnownTasks)))
    , promMetricLine "ctl_holds" "scope=\"worker\",property=\"AG_terminal_cleanup\"" (toString (promBool (CTL.holds successors initial terminalTasksAreCleanedUp)))
    , promMetricLine "protobuf_parsed" "scope=\"assembled\",property=\"all_message_bodies_parsed\"" (toString (promBool allMessageBodiesParsed))
    , promMetricLine "grammar_messages_total" "scope=\"auth\"" (toString authGrammar.length)
    , promMetricLine "grammar_messages_total" "scope=\"get_docs\"" (toString grammar.length)
    , promMetricLine "grammar_messages_total" "scope=\"post_review\"" (toString reviewGrammar.length)
    , promMetricLine "grammar_messages_total" "scope=\"assembled\"" (toString assembledGrammar.length)
    , promMetricLine "visible_protocol_messages" "protocol=\"kerberos\"" (toString kerberosDhTokenSpec.messages.length)
    , promMetricLine "visible_protocol_proof_fields" "protocol=\"kerberos\"" (toString kerberosDhTokenSpec.proofFields.length)
    , promMetricLine "visible_protocol_assertions" "protocol=\"kerberos\"" (toString kerberosDhTokenSpec.assertions.length)
    , promMessageCount "auth" "Auth.LookupRequest" 1
    , promMessageCount "auth" "Auth.LookupResponse" 2
    , promMessageCount "get_docs" "Docs.GetRequest" 1
    , promMessageCount "get_docs" "Docs.FetchCommand" 1
    , promMessageCount "get_docs" "Docs.FetchResult" 2
    , promMessageCount "get_docs" "Docs.GetResponse" 1
    , promMessageCount "get_docs" "Error.Response" 1
    , promMessageCount "post_review" "Reviews.PostRequest" 1
    , promMessageCount "post_review" "Reviews.ModerateCommand" 1
    , promMessageCount "post_review" "Reviews.ModerationResult" 2
    , promMessageCount "post_review" "Reviews.PostResponse" 2
    , promMessageCount "kerberos" "Kerberos.AsReq" 1
    , promMessageCount "kerberos" "Kerberos.AsRep" 1
    , promMessageCount "kerberos" "Kerberos.TgsReq" 1
    , promMessageCount "kerberos" "Kerberos.TgsRep" 1
    , promMessageCount "kerberos" "Kerberos.ApReq" 1
    , promMessageCount "kerberos" "Kerberos.ApRep" 1
    , ""
    ]

def taskListName (tasks : List TaskKind) : String :=
  joinWith ", " (tasks.map taskName)

def actorSpecLine (spec : ActorSpec) : String :=
  s!"  {actorName spec.actor}: queueCap={spec.queueCap}, tasks=[{taskListName spec.tasks}]"

def messageListName (messages : List Envelope) : String :=
  joinWith ", " (messages.map envelopeName)

def taskMachineLine (machine : TaskMachine) : String :=
  s!"  {actorName machine.owner}.{taskName machine.task}: accepts=[{messageListName machine.accepts}], emits=[{messageListName machine.emits}]"

def taskCtlLines (name : String) (fsm : TaskFSM) : List String :=
  [ s!"  {name}: states={fsm.states.length}, transitions={fsm.transitions.length}"
  , s!"    AF terminal: {fsm.holds taskTerminates}"
  , s!"    EF success: {fsm.holds taskCanSucceed}"
  , s!"    EF failure: {fsm.holds taskCanFail}"
  , s!"    AG capacity: {fsm.holds taskCapacitySafe}"
  , s!"    AG terminal states clean up active task: {fsm.holds taskTerminalStatesCleaned}"
  ]

def textReport : String :=
  joinWith "\n" <|
    ["Two-actor auth group grammar"] ++
    (authGrammar.map fun e => s!"  {envelopeName e}") ++
    ["  artifact: " ++ proofName (some loginProof)] ++
    ["", "Three-actor get_docs grammar"] ++
    (grammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Three-actor post_review grammar"] ++
    (reviewGrammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Assembled system grammar"] ++
    (assembledGrammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Protobuf parsing"
    , s!"  all listed message bodies parsed: {allMessageBodiesParsed}"
    ] ++
    ["", "World actor/task composition"] ++
    (workerWorld.actors.map actorSpecLine) ++
    ["", "Task machines selected from queued messages"] ++
    (workerWorld.tasks.map taskMachineLine) ++
    ["", "Per-task FSM CTL checks"] ++
    taskCtlLines "get_docs" purchaseTaskFSM ++
    taskCtlLines "post_review" reviewTaskFSM ++
    ["", "Observable actor-state transitions"] ++
    (transitions.map fun t => s!"  {transitionLine t}") ++
    ["", "MDP choices"] ++
    (states.flatMap fun s => (choices s).flatMap (choiceLines s)) ++
    ["", "Time-weighted queue length distribution under successPolicy"] ++
    (queueLengthTimeDistribution.map distributionLine) ++
    ["", "Global visible terminal traces under successPolicy"] ++
    (terminalStats.map terminalLine) ++
    ["", "Expected metrics under successPolicy"
    , metricLine "expected latency" expectedLatencyNumerator expectedLatencyDenominator
    , metricLine "success probability" successMass terminalMass
    , metricLine "throughput" throughputNumerator throughputDenominator
    , "", "Component and assembled metrics"] ++
    metricsLines "auth group" authMetrics ++
    metricsLines "get_docs task" purchaseMetrics ++
    metricsLines "post_review task" reviewMetrics ++
    metricsLines "worker group" workerMetrics ++
    metricsLines "assembled system" assembledMetrics ++
    ["", "Graphviz DOT", graphDot
    , "", "CTL from initial observation"
    , ctlLine "AF success (all paths eventually succeed)" mustEventuallySucceed
    , ctlLine "AG !fail   (all reachable observations avoid failure)" neverFails
    , ctlLine "EF fail    (some path can fail)" mayFail
    , ctlLine "AG capacity (all reachable queues stay within capacity)" queuesStayWithinCapacity
    , ctlLine "AG no success without auth proof" noSuccessWithoutAuth
    , ctlLine "AG queued heads select known actor tasks" actorQueuesSelectKnownTasks
    , ctlLine "AG terminal states clean up active task" terminalTasksAreCleanedUp
    , "", "CTL from unauthenticated task attempt"
    , ctlLineFrom unauthenticatedInitial "EX unauthorized (client task step is rejected)" unauthenticatedAttemptCanBeRejected
    , ctlLineFrom unauthenticatedInitial "AG no success without auth proof" noSuccessWithoutAuth
    ]

def trafficAnimation : String :=
  "<section><h2>Traffic Animation</h2><div class=\"canvasPanel\"><canvas id=\"traffic\" width=\"900\" height=\"360\"></canvas><ol id=\"trafficTrace\"></ol></div></section>" ++
  "<script>" ++
  "const canvas=document.getElementById('traffic');const ctx=canvas.getContext('2d');" ++
  "const traceEl=document.getElementById('trafficTrace');" ++
  "const actors={Client:{x:120,y:95},Gateway:{x:450,y:95},Worker:{x:780,y:95}};" ++
  "const events=[" ++
  "{src:'Client',dst:'Gateway',payload:'GET /docs/index.html',proto:'Docs.GetRequest',bytes:'[1 16]',fields:'1:method=GET, 2:path=/docs/index.html',ts:1}," ++
  "{src:'Gateway',dst:'Worker',payload:'fetch /docs/index.html',proto:'Docs.FetchCommand',bytes:'[2 32]',fields:'1:path=/docs/index.html, 2:cache_mode=normal',ts:3}," ++
  "{src:'Worker',dst:'Gateway',payload:'200 /docs/index.html',proto:'Docs.FetchResult',bytes:'[3 48]',fields:'1:status=200, 2:path=/docs/index.html',ts:7}," ++
  "{src:'Gateway',dst:'Client',payload:'200 /docs/index.html',proto:'Docs.GetResponse',bytes:'[4 64]',fields:'1:status=200, 2:path=/docs/index.html',ts:8}," ++
  "{src:'Client',dst:'Gateway',payload:'POST /reviews',proto:'Reviews.PostRequest',bytes:'[17 16]',fields:'1:method=POST, 2:path=/reviews, 3:body_hash=review#1',ts:1}," ++
  "{src:'Gateway',dst:'Worker',payload:'moderate review',proto:'Reviews.ModerateCommand',bytes:'[18 32]',fields:'1:body_hash=review#1, 2:policy=default',ts:2}," ++
  "{src:'Worker',dst:'Gateway',payload:'review accepted',proto:'Reviews.ModerationResult',bytes:'[19 48]',fields:'1:decision=accepted, 2:body_hash=review#1',ts:5}," ++
  "{src:'Gateway',dst:'Client',payload:'201 /reviews',proto:'Reviews.PostResponse',bytes:'[20 64]',fields:'1:status=201, 2:path=/reviews',ts:6}" ++
  "];" ++
  "function drawActor(name,a){ctx.fillStyle='#000';ctx.strokeStyle='#fff';ctx.lineWidth=2;ctx.fillRect(a.x-70,a.y-36,140,72);ctx.strokeRect(a.x-70,a.y-36,140,72);ctx.fillStyle='#fff';ctx.font='18px sans-serif';ctx.textAlign='center';ctx.fillText(name,a.x,a.y+6);}" ++
  "function arrow(ctx,x1,y1,x2,y2,color,width){ctx.strokeStyle=color;ctx.fillStyle=color;ctx.lineWidth=width;ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.stroke();const a=Math.atan2(y2-y1,x2-x1);ctx.beginPath();ctx.moveTo(x2,y2);ctx.lineTo(x2-13*Math.cos(a-.45),y2-13*Math.sin(a-.45));ctx.lineTo(x2-13*Math.cos(a+.45),y2-13*Math.sin(a+.45));ctx.closePath();ctx.fill();}" ++
  "function draw(){const w=canvas.width,h=canvas.height;ctx.fillStyle='#111';ctx.fillRect(0,0,w,h);Object.entries(actors).forEach(([n,a])=>drawActor(n,a));ctx.strokeStyle='#666';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(120,180);ctx.lineTo(780,180);ctx.stroke();const now=performance.now();const span=1500;const i=Math.floor(now/span)%events.length;const p=(now%span)/span;const e=events[i];const a=actors[e.src],b=actors[e.dst];const sx=a.x+(b.x>a.x?70:-70),tx=b.x-(b.x>a.x?70:-70);const x=sx+(tx-sx)*p;const y=180+Math.sin(p*Math.PI)*-42;arrow(ctx,sx,180,tx,180,'#93c5fd',3);ctx.fillStyle='#f8f8f8';ctx.beginPath();ctx.arc(x,y,9,0,Math.PI*2);ctx.fill();ctx.font='16px sans-serif';ctx.textAlign='center';ctx.fillText(e.proto+' bytes='+e.bytes,x,250);ctx.fillText(e.fields,x,276);ctx.fillText(e.src+' -> '+e.dst+'  ts='+e.ts,x,302);traceEl.innerHTML=events.map((ev,j)=>'<li'+(j===i?' class=\"active\"':'')+'>'+ev.src+' -> '+ev.dst+' | '+ev.proto+' | bytes='+ev.bytes+' | '+ev.fields+' | ts='+ev.ts+'</li>').join('');requestAnimationFrame(draw);}draw();" ++
  "</script>"

def scenarioCatalogJson : String :=
  "[" ++
  "{\"id\":\"get_docs\",\"task\":\"get_docs\",\"actors\":[\"Client\",\"Gateway\",\"Worker\"],\"entry\":\"GET /docs/index.html\",\"messages\":[\"Client -> Gateway Docs.GetRequest fields={method,path}\",\"Gateway -> Worker Docs.FetchCommand fields={path,cache_mode}\",\"Worker -> Gateway Docs.FetchResult fields={status,path,bytes}\",\"Gateway -> Client Docs.GetResponse fields={status,path,bytes}\"],\"properties\":[\"AG no success without auth proof\",\"AF terminal\",\"AG terminal cleanup\"],\"reducers\":[\"latency by task\",\"bytes by ts\",\"queue length by ts\"]}," ++
  "{\"id\":\"post_review\",\"task\":\"post_review\",\"actors\":[\"Client\",\"Gateway\",\"Worker\"],\"entry\":\"POST /reviews\",\"messages\":[\"Client -> Gateway Reviews.PostRequest fields={method,path,body_hash}\",\"Gateway -> Worker Reviews.ModerateCommand fields={body_hash,policy}\",\"Worker -> Gateway Reviews.ModerationResult fields={decision,body_hash}\",\"Gateway -> Client Reviews.PostResponse fields={status,path}\"],\"properties\":[\"AG no success without auth proof\",\"EF rejected\",\"AF terminal\"],\"reducers\":[\"accept/reject pie\",\"latency by task\",\"messages by actor\"]}," ++
  "{\"id\":\"upload_file\",\"task\":\"upload_file\",\"actors\":[\"Client\",\"Gateway\",\"Storage\",\"Worker\"],\"entry\":\"PUT /files/{name}\",\"messages\":[\"Client -> Gateway Files.PutRequest fields={path,bytes,content_hash}\",\"Gateway -> Storage Files.StoreCommand fields={path,bytes,content_hash}\",\"Storage -> Gateway Files.StoreResult fields={status,path,stored_bytes}\",\"Gateway -> Client Files.PutResponse fields={status,path,stored_bytes}\"],\"properties\":[\"AG no success without auth proof\",\"AG stored_bytes <= bytes\",\"AF terminal\"],\"reducers\":[\"bytes by ts\",\"USL load vs throughput\",\"queue length by actor\"]}," ++
  "{\"id\":\"download_file\",\"task\":\"download_file\",\"actors\":[\"Client\",\"Gateway\",\"Storage\"],\"entry\":\"GET /files/{name}\",\"messages\":[\"Client -> Gateway Files.GetRequest fields={path}\",\"Gateway -> Storage Files.ReadCommand fields={path}\",\"Storage -> Gateway Files.ReadResult fields={status,path,bytes}\",\"Gateway -> Client Files.GetResponse fields={status,path,bytes}\"],\"properties\":[\"AG no success without auth proof\",\"EF not_found\",\"AF terminal\"],\"reducers\":[\"bytes by ts\",\"latency by path\",\"success/failure pie\"]}" ++
  "]"

def protocolSketchCatalogJson : String :=
  "[" ++
  "{\"id\":\"kerberos\",\"label\":\"Kerberos/DH trusted-token sketch\",\"actors\":[\"Client\",\"AuthServer\",\"TicketGrantingServer\",\"Service\"],\"messages\":[\"Client -> AuthServer Kerberos.AsReq fields={client_principal,realm,client_dh_share,nonce}\",\"AuthServer -> Client Kerberos.AsRep fields={client_principal,tgt_proof,server_dh_share,dh_commutativity_proof,token_server_signature_proof,nonce}\",\"Client -> TicketGrantingServer Kerberos.TgsReq fields={service_principal,tgt_proof,authenticator_proof,client_dh_share,nonce}\",\"TicketGrantingServer -> Client Kerberos.TgsRep fields={service_ticket_proof,service_session_key_proof,server_dh_share,dh_commutativity_proof,nonce}\",\"Client -> Service Kerberos.ApReq fields={service_ticket_proof,authenticator_proof,operation}\",\"Service -> Client Kerberos.ApRep fields={service_accept_proof,operation,status}\"],\"terminal\":[\"authenticated_for_service\",\"rejected\"],\"properties\":[\"AG no service success without service_ticket_proof\",\"AG TgsRep requires prior tgt_proof\",\"AG ApRep success requires prior service_accept_proof\",\"AG dh_commutativity_proof appears only after both DH shares are visible\",\"AG token_server_signature_proof appears only on AuthServer/TGS-issued tokens\",\"AF terminal\"],\"notes\":[\"proof fields are placeholders for visible protocol evidence, not real cryptographic material\",\"dh_commutativity_proof stands for both parties deriving the same shared key from exchanged DH shares\",\"token_server_signature_proof stands for a trusted token server issuing the ticket\"]}" ++
  "]"

def conversationCatalogJson : String :=
  "[" ++
  "{\"id\":\"auth\",\"label\":\"auth conversation\",\"leanFile\":\"/lean/auth.lean\",\"dot\":\"/auth.dot\"}," ++
  "{\"id\":\"get_docs\",\"label\":\"get_docs conversation\",\"leanFile\":\"/lean/get_docs.lean\",\"dot\":\"/get_docs.dot\"}," ++
  "{\"id\":\"post_review\",\"label\":\"post_review conversation\",\"leanFile\":\"/lean/post_review.lean\",\"dot\":\"/post_review.dot\"}," ++
  "{\"id\":\"kerberos\",\"label\":\"Kerberos/DH trusted-token sketch\",\"leanFile\":\"/lean/sketch/kerberos.lean\",\"dot\":\"/tasks.dot\"}," ++
  "{\"id\":\"worker\",\"label\":\"worker group\",\"leanFile\":\"/lean/worker.lean\",\"dot\":\"/graph.dot\"}," ++
  "{\"id\":\"assembled\",\"label\":\"assembled system\",\"leanFile\":\"/lean/assembled.lean\",\"dot\":\"/assembled.dot\"}" ++
  "]"

def leanFileText (title body : String) : String :=
  joinWith "\n"
    [ "import LeanFM"
    , ""
    , "namespace LeanFM.Generated"
    , ""
    , s!"-- Generated view for {title}. The source of truth is the typed LeanFM model."
    , body
    , ""
    , "end LeanFM.Generated"
    , ""
    ]

def authLeanFile : String :=
  leanFileText "auth conversation" <| joinWith "\n"
    [ "def conversationId : String := \"auth\""
    , "def grammar := LeanFM.authGrammar"
    , "def metrics := LeanFM.authMetrics"
    ]

def getDocsLeanFile : String :=
  leanFileText "get_docs conversation" <| joinWith "\n"
    [ "def conversationId : String := \"get_docs\""
    , "def grammar := LeanFM.grammar"
    , "def taskFsm := LeanFM.purchaseTaskFSM"
    , "def metrics := LeanFM.purchaseMetrics"
    , "def terminates : Bool := taskFsm.holds LeanFM.taskTerminates"
    ]

def postReviewLeanFile : String :=
  leanFileText "post_review conversation" <| joinWith "\n"
    [ "def conversationId : String := \"post_review\""
    , "def grammar := LeanFM.reviewGrammar"
    , "def taskFsm := LeanFM.reviewTaskFSM"
    , "def metrics := LeanFM.reviewMetrics"
    , "def terminates : Bool := taskFsm.holds LeanFM.taskTerminates"
    ]

def workerLeanFile : String :=
  leanFileText "worker group" <| joinWith "\n"
    [ "def conversationId : String := \"worker\""
    , "def world := LeanFM.workerWorld"
    , "def grammar := LeanFM.workerGrammar"
    , "def metrics := LeanFM.workerMetrics"
    , "def capacitySafe : Bool := LeanFM.CTL.holds LeanFM.successors LeanFM.initial LeanFM.queuesStayWithinCapacity"
    ]

def assembledLeanFile : String :=
  leanFileText "assembled system" <| joinWith "\n"
    [ "def conversationId : String := \"assembled\""
    , "def grammar := LeanFM.assembledGrammar"
    , "def metrics := LeanFM.assembledMetrics"
    , "def allMessageBodiesParsed : Bool := LeanFM.allMessageBodiesParsed"
    ]

def kerberosLeanSketch : String :=
  leanFileText "kerberos protocol sketch" <| joinWith "\n"
    [ "def conversationId : String := \"kerberos\""
    , "def spec : LeanFM.VisibleProtocolSpec := LeanFM.kerberosDhTokenSpec"
    , "def actors : List String := spec.actors"
    , "def visibleMessages : List LeanFM.VisibleMessageSpec := spec.messages"
    , "def proofFields : List String := spec.proofFields"
    , "def assertions : List String := spec.assertions"
    , ""
    , "-- This is a visible-behavior sketch. DH and token-server facts are represented"
    , "-- by observable proof fields carried in messages, not by real cryptographic values."
    ]

def conversationPicker : String :=
  "<section><h2>Conversation Source</h2><div class=\"controlPanel\"><label>Conversation <select id=\"conversationSelect\"></select></label> <a id=\"conversationLean\" href=\"/lean/get_docs.lean\">Lean file</a> <a id=\"conversationDot\" href=\"/get_docs.dot\">DOT</a></div><pre id=\"conversationPreview\"></pre></section>" ++
  "<script>" ++
  "const conversationSelect=document.getElementById('conversationSelect'),conversationLean=document.getElementById('conversationLean'),conversationDot=document.getElementById('conversationDot'),conversationPreview=document.getElementById('conversationPreview');" ++
  "async function loadConversations(){const xs=await fetch('/tools/conversations').then(r=>r.json());conversationSelect.innerHTML=xs.map(x=>'<option value=\"'+x.id+'\">'+x.label+'</option>').join('');async function pick(){const c=xs.find(x=>x.id===conversationSelect.value)||xs[0];conversationLean.href=c.leanFile;conversationDot.href=c.dot;conversationLean.textContent=c.leanFile;conversationDot.textContent=c.dot;conversationPreview.textContent=await fetch(c.leanFile).then(r=>r.text());}conversationSelect.addEventListener('change',pick);conversationSelect.value='get_docs';pick();}loadConversations();" ++
  "</script>"

def liveSubjectGraph : String :=
  "<section><h2>Current Requirement</h2><div class=\"controlPanel\"><label><input id=\"subjectCutEdges\" type=\"checkbox\" checked> edge corridors push boxes out of arrow paths</label> <span class=\"zoomControls\"><button id=\"subjectZoomOut\" type=\"button\">-</button><span id=\"subjectZoomLabel\">100%</span><button id=\"subjectZoomIn\" type=\"button\">+</button><button id=\"subjectZoomReset\" type=\"button\">reset</button></span></div><div class=\"subjectPanel\"><canvas id=\"subjectGraph\" width=\"1180\" height=\"720\"></canvas><div><h3 id=\"subjectTitle\">No active draft</h3><p id=\"subjectSummary\">Ask the assistant to sketch a protocol or task.</p><div id=\"subjectArtifacts\" class=\"artifactPanel\"></div></div></div></section>" ++
  "<script>" ++ LeanFM.StaticAssets.subjectGraphJs ++ "</script>"

def chatWorkbench : String :=
  "<section><h2>LeanFM Assistant</h2><div class=\"chatShell\"><div id=\"chatLog\" class=\"chatLog\"></div><div class=\"chatInput\"><textarea id=\"chatPrompt\" rows=\"3\" placeholder=\"Ask for a protocol sketch, diagram render, generated text, metrics, charts, or validation\"></textarea><button id=\"chatSend\">Send</button></div><div id=\"toolLog\" class=\"toolLog\"></div></div></section><section><h2>LLM Chart Workbench</h2><div class=\"chartEditor\"><label>Name <input id=\"chartName\" value=\"messages by actor\"></label><label>Kind <select id=\"chartKind\"><option value=\"xy\">xy line</option><option value=\"pie\">pie</option></select></label><label>Dataset <select id=\"chartDataset\"></select></label><button id=\"chartSave\" type=\"button\">save</button><button id=\"chartDelete\" type=\"button\">delete</button></div><div id=\"namedCharts\" class=\"namedCharts\"></div></section>" ++
  "<script>" ++ LeanFM.StaticAssets.assistantJs ++ "</script>"

def interactionDiagram : String :=
  "<section><h2>Interaction Diagrams By Task</h2><div class=\"canvasPanel\"><canvas id=\"interaction\" width=\"1000\" height=\"640\"></canvas><ol id=\"interactionTrace\"></ol></div></section>" ++
  "<script>" ++
  "const ic=document.getElementById('interaction');const ictx=ic.getContext('2d');const itrace=document.getElementById('interactionTrace');" ++
  "const lanes={Client:140,Gateway:500,Worker:860};" ++
  "const taskSeqs={" ++
  "get_docs:[" ++
  "{src:'Client',dst:'Gateway',proto:'Docs.GetRequest',bytes:'[1 16]',fields:'1:method=GET, 2:path=/docs/index.html',ts:1}," ++
  "{src:'Gateway',dst:'Worker',proto:'Docs.FetchCommand',bytes:'[2 32]',fields:'1:path=/docs/index.html, 2:cache_mode=normal',ts:3}," ++
  "{src:'Worker',dst:'Gateway',proto:'Docs.FetchResult',bytes:'[3 48]',fields:'1:status=200, 2:path=/docs/index.html',ts:7}," ++
  "{src:'Gateway',dst:'Client',proto:'Docs.GetResponse',bytes:'[4 64]',fields:'1:status=200, 2:path=/docs/index.html',ts:8}" ++
  "]," ++
  "post_review:[" ++
  "{src:'Client',dst:'Gateway',proto:'Reviews.PostRequest',bytes:'[17 16]',fields:'1:method=POST, 2:path=/reviews, 3:body_hash=review#1',ts:1}," ++
  "{src:'Gateway',dst:'Worker',proto:'Reviews.ModerateCommand',bytes:'[18 32]',fields:'1:body_hash=review#1, 2:policy=default',ts:2}," ++
  "{src:'Worker',dst:'Gateway',proto:'Reviews.ModerationResult',bytes:'[19 48]',fields:'1:decision=accepted, 2:body_hash=review#1',ts:5}," ++
  "{src:'Gateway',dst:'Client',proto:'Reviews.PostResponse',bytes:'[20 64]',fields:'1:status=201, 2:path=/reviews',ts:6}" ++
  "]" ++
  "};" ++
  "function iarrow(x1,y1,x2,y2,color){ictx.strokeStyle=color;ictx.fillStyle=color;ictx.lineWidth=2;ictx.beginPath();ictx.moveTo(x1,y1);ictx.lineTo(x2,y2);ictx.stroke();const a=Math.atan2(y2-y1,x2-x1);ictx.beginPath();ictx.moveTo(x2,y2);ictx.lineTo(x2-12*Math.cos(a-.42),y2-12*Math.sin(a-.42));ictx.lineTo(x2-12*Math.cos(a+.42),y2-12*Math.sin(a+.42));ictx.closePath();ictx.fill();}" ++
  "function drawLanes(y0,y1){for(const [name,x] of Object.entries(lanes)){ictx.fillStyle='#000';ictx.strokeStyle='#fff';ictx.lineWidth=2;ictx.fillRect(x-72,y0,144,38);ictx.strokeRect(x-72,y0,144,38);ictx.fillStyle='#fff';ictx.font='16px sans-serif';ictx.textAlign='center';ictx.fillText(name,x,y0+25);ictx.strokeStyle='#555';ictx.setLineDash([6,7]);ictx.beginPath();ictx.moveTo(x,y0+44);ictx.lineTo(x,y1);ictx.stroke();ictx.setLineDash([]);}}" ++
  "function drawTask(task,seq,y0,color){ictx.strokeStyle='#444';ictx.lineWidth=1;ictx.strokeRect(28,y0-16,944,268);ictx.fillStyle='#fff';ictx.font='18px sans-serif';ictx.textAlign='left';ictx.fillText(task,42,y0+8);drawLanes(y0+22,y0+238);seq.forEach((e,i)=>{const y=y0+82+i*42;const x1=lanes[e.src],x2=lanes[e.dst];iarrow(x1,y,x2,y,color);ictx.fillStyle='#fff';ictx.font='12px sans-serif';ictx.textAlign='center';ictx.fillText(e.proto+' bytes='+e.bytes,(x1+x2)/2,y-9);ictx.font='11px sans-serif';ictx.fillText(e.fields,(x1+x2)/2,y+16);});}" ++
  "function drawInteraction(){ictx.fillStyle='#111';ictx.fillRect(0,0,ic.width,ic.height);drawTask('get_docs',taskSeqs.get_docs,34,'#93c5fd');drawTask('post_review',taskSeqs.post_review,342,'#fbbf24');itrace.innerHTML=Object.entries(taskSeqs).flatMap(([task,seq])=>seq.map(e=>'<li>'+task+' | '+e.src+' -> '+e.dst+' | '+e.proto+' | bytes='+e.bytes+' | '+e.fields+' | ts='+e.ts+'</li>')).join('');}drawInteraction();" ++
  "</script>"

def canvasDiagramGallery : String :=
  "<section><h2>Canvas Diagram Gallery</h2>" ++
  "<p class=\"renderLinks\"><a href=\"/renders/auth\">auth render</a> | <a href=\"/renders/worker\">worker render</a> | <a href=\"/renders/get_docs\">get_docs render</a> | <a href=\"/renders/post_review\">post_review render</a> | <a href=\"/renders/tasks\">task conversations render</a> | <a href=\"/renders/assembled\">assembled render</a></p>" ++
  "<div class=\"diagramGrid\">" ++
  "<details id=\"render-auth\" open><summary>Auth Group <a href=\"/renders/auth\">render</a> <a href=\"/docs/auth.md\">md</a></summary><canvas id=\"diagAuth\" width=\"900\" height=\"320\"></canvas></details>" ++
  "<details id=\"render-worker\"><summary>Worker Group Overview <a href=\"/renders/worker\">render</a> <a href=\"/docs/worker.md\">md</a></summary><canvas id=\"diagWorker\" width=\"900\" height=\"420\"></canvas></details>" ++
  "<details id=\"render-get-docs\"><summary>get_docs Task <a href=\"/renders/get_docs\">render</a> <a href=\"/docs/get_docs.md\">md</a></summary><canvas id=\"diagGetDocs\" width=\"900\" height=\"420\"></canvas></details>" ++
  "<details id=\"render-post-review\"><summary>post_review Task <a href=\"/renders/post_review\">render</a> <a href=\"/docs/post_review.md\">md</a></summary><canvas id=\"diagPostReview\" width=\"900\" height=\"420\"></canvas></details>" ++
  "<details id=\"render-tasks\" open><summary>Task Conversations <a href=\"/renders/tasks\">render</a></summary><canvas id=\"diagTasks\" width=\"900\" height=\"360\"></canvas></details>" ++
  "<details id=\"render-assembled\" open><summary>Assembled System <a href=\"/renders/assembled\">render</a> <a href=\"/docs/assembled.md\">md</a></summary><canvas id=\"diagAssembled\" width=\"900\" height=\"360\"></canvas></details>" ++
  "</div></section>" ++
  "<script>" ++
  "function cnode(ctx,n){const w=n.w||190,h=n.h||56,x=n.x-w/2,y=n.y-h/2;ctx.fillStyle='#000';ctx.strokeStyle=n.color||'#fff';ctx.lineWidth=2;ctx.fillRect(x,y,w,h);ctx.strokeRect(x,y,w,h);ctx.fillStyle='#fff';ctx.font='15px sans-serif';ctx.textAlign='center';String(n.label).split('\\n').forEach((t,i,a)=>ctx.fillText(t,n.x,n.y-(a.length-1)*9+i*18));}" ++
  "function carrow(ctx,a,b,label,color){const dx=b.x-a.x,dy=b.y-a.y,d=Math.max(1,Math.sqrt(dx*dx+dy*dy));const x1=a.x+dx/d*((a.w||190)/2+8),y1=a.y+dy/d*((a.h||56)/2+8),x2=b.x-dx/d*((b.w||190)/2+8),y2=b.y-dy/d*((b.h||56)/2+8);ctx.strokeStyle=color||'#93c5fd';ctx.fillStyle=color||'#93c5fd';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.stroke();const ang=Math.atan2(y2-y1,x2-x1);ctx.beginPath();ctx.moveTo(x2,y2);ctx.lineTo(x2-13*Math.cos(ang-.45),y2-13*Math.sin(ang-.45));ctx.lineTo(x2-13*Math.cos(ang+.45),y2-13*Math.sin(ang+.45));ctx.closePath();ctx.fill();ctx.font='12px sans-serif';ctx.textAlign='center';ctx.fillText(label,(x1+x2)/2,(y1+y2)/2-7);}" ++
  "function drawCanvasDiagram(id,title,nodes,edges){const cv=document.getElementById(id),ctx=cv.getContext('2d');ctx.fillStyle='#111';ctx.fillRect(0,0,cv.width,cv.height);ctx.fillStyle='#fff';ctx.font='18px sans-serif';ctx.textAlign='left';ctx.fillText(title,24,30);const by=new Map(nodes.map(n=>[n.id,n]));edges.forEach(e=>carrow(ctx,by.get(e[0]),by.get(e[1]),e[2],e[3]));nodes.forEach(n=>cnode(ctx,n));}" ++
  "drawCanvasDiagram('diagAuth','auth group',[{id:'idle',label:'Auth idle',x:160,y:150},{id:'db',label:'DB lookup',x:450,y:150},{id:'ok',label:'auth proof\\nissued',x:740,y:95,color:'#22c55e'},{id:'fail',label:'reject',x:740,y:215,color:'#ef4444'}],[['idle','db','LookupRequest'],['db','ok','LookupResponse ok'],['db','fail','LookupResponse fail','#ef4444']]);" ++
  "drawCanvasDiagram('diagGetDocs','get_docs task',[{id:'u',label:'unauthorized',x:150,y:95,color:'#ef4444'},{id:'s',label:'start\\nDocs.GetRequest',x:150,y:230},{id:'g',label:'Gateway queued',x:380,y:230},{id:'w',label:'Worker fetch',x:610,y:230},{id:'d',label:'done\\n200 response',x:820,y:165,color:'#22c55e'},{id:'f',label:'failed\\n404/401',x:820,y:295,color:'#ef4444'}],[['u','f','reject'],['s','g','GetRequest'],['g','w','FetchCommand'],['w','d','FetchResult 200'],['w','f','FetchResult 404','#ef4444']]);" ++
  "drawCanvasDiagram('diagPostReview','post_review task',[{id:'u',label:'unauthorized',x:150,y:95,color:'#ef4444'},{id:'s',label:'start\\nPostRequest',x:150,y:230},{id:'g',label:'Gateway queued',x:380,y:230},{id:'m',label:'Worker moderate',x:610,y:230},{id:'d',label:'posted\\n201',x:820,y:165,color:'#22c55e'},{id:'f',label:'rejected\\n400',x:820,y:295,color:'#ef4444'}],[['u','f','reject'],['s','g','PostRequest'],['g','m','ModerateCommand'],['m','d','accepted'],['m','f','rejected','#ef4444']]);" ++
  "drawCanvasDiagram('diagWorker','worker overview',[{id:'auth',label:'authenticated\\nsession',x:150,y:210,color:'#22c55e'},{id:'docs',label:'get_docs\\nFSM',x:430,y:130,w:220,h:80},{id:'review',label:'post_review\\nFSM',x:430,y:290,w:220,h:80},{id:'metrics',label:'reducers\\ncharts + metrics',x:750,y:210,w:220,h:80}],[['auth','docs','GET /docs'],['auth','review','POST /reviews'],['docs','metrics','trace'],['review','metrics','trace']]);" ++
  "drawCanvasDiagram('diagTasks','task conversations',[{id:'c',label:'Client',x:130,y:180},{id:'g',label:'Gateway',x:450,y:180},{id:'w',label:'Worker',x:770,y:180}],[['c','g','request'],['g','w','command'],['w','g','result'],['g','c','response']]);" ++
  "drawCanvasDiagram('diagAssembled','assembled system',[{id:'auth',label:'auth group\\nP=0.9800',x:220,y:110,w:230,h:80},{id:'worker',label:'worker group\\nP=0.9250',x:450,y:215,w:230,h:80},{id:'sys',label:'assembled\\nP=0.9065\\nthroughput=0.0765',x:680,y:110,w:250,h:96}],[['auth','worker','auth proof'],['worker','sys','aggregate metrics']]);" ++
  "</script>"

def diagramRenderPage (selected : String) : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM Render</title>" ++
  "<meta name=\"color-scheme\" content=\"dark only\">" ++
  "<style>html,body{background:#111;color:#f8f8f8;color-scheme:dark only;forced-color-adjust:none}body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4}a{color:#93c5fd}details{border:1px solid #444;margin:.75rem 0 1rem;background:#090909}summary{cursor:pointer;padding:.75rem 1rem;font-weight:700}.diagramGrid canvas{display:block;width:100%;max-width:900px;height:auto;background:#111;border-top:1px solid #333}.renderLinks{margin:.5rem 0 1rem}</style>" ++
  "</head><body><h1>LeanFM Diagram Render</h1><p><a href=\"/\">root UI</a> | <a href=\"/renders/\">all renders</a> | selected: " ++ selected ++ "</p>" ++
  canvasDiagramGallery ++
  "<script>" ++
  "const sel='" ++ selected ++ "';const ids={auth:'render-auth',worker:'render-worker',get_docs:'render-get-docs',post_review:'render-post-review',tasks:'render-tasks',assembled:'render-assembled'};" ++
  "for(const [k,id] of Object.entries(ids)){const el=document.getElementById(id);if(el)el.open=(sel==='all'||sel===k);}setTimeout(()=>{const el=document.getElementById(ids[sel]);if(el)el.scrollIntoView({block:'start'});},50);" ++
  "</script></body></html>"

def queueChartData : String :=
  joinWith "," <| queueLengthTimeDistribution.map fun bucket =>
    "{q:" ++ toString bucket.1 ++ ",p:" ++ fixed4Text bucket.2 expectedLatencyNumerator ++ "}"

def chartsSection : String :=
  "<section><h2>Charts</h2><div class=\"chartControls\"><label>Left <select id=\"chartKindA\"><option value=\"line\">line</option><option value=\"pie\">pie</option></select></label><select id=\"chartDataA\"></select><label>Right <select id=\"chartKindB\"><option value=\"pie\">pie</option><option value=\"line\">line</option></select></label><select id=\"chartDataB\"></select></div><div class=\"chartGrid\"><canvas id=\"chartA\" width=\"720\" height=\"300\"></canvas><canvas id=\"chartB\" width=\"720\" height=\"300\"></canvas></div></section>" ++
  "<script>" ++
  "const orderedMessages=[" ++
  "{task:'auth',src:'Client',dst:'Auth',proto:'Auth.LookupRequest',bytes:2,ts:1}," ++
  "{task:'auth',src:'Auth',dst:'DB',proto:'Auth.LookupRequest',bytes:2,ts:2}," ++
  "{task:'auth',src:'DB',dst:'Auth',proto:'Auth.LookupResponse',bytes:2,ts:3}," ++
  "{task:'auth',src:'Auth',dst:'Client',proto:'Auth.LookupResponse',bytes:2,ts:4}," ++
  "{task:'get_docs',src:'Client',dst:'Gateway',proto:'Docs.GetRequest',bytes:2,ts:5}," ++
  "{task:'get_docs',src:'Gateway',dst:'Worker',proto:'Docs.FetchCommand',bytes:2,ts:7}," ++
  "{task:'get_docs',src:'Worker',dst:'Gateway',proto:'Docs.FetchResult',bytes:2,ts:11}," ++
  "{task:'get_docs',src:'Gateway',dst:'Client',proto:'Docs.GetResponse',bytes:2,ts:13}," ++
  "{task:'post_review',src:'Client',dst:'Gateway',proto:'Reviews.PostRequest',bytes:2,ts:14}," ++
  "{task:'post_review',src:'Gateway',dst:'Worker',proto:'Reviews.ModerateCommand',bytes:2,ts:16}," ++
  "{task:'post_review',src:'Worker',dst:'Gateway',proto:'Reviews.ModerationResult',bytes:2,ts:19}," ++
  "{task:'post_review',src:'Gateway',dst:'Client',proto:'Reviews.PostResponse',bytes:2,ts:21}" ++
  "];" ++
  "const latencyData=[" ++
  "{label:'auth',latency:" ++ fixed4Text authMetrics.latencyNum authMetrics.latencyDen ++ ",throughput:" ++ fixed4Text authMetrics.throughputNum authMetrics.throughputDen ++ "}," ++
  "{label:'get_docs',latency:" ++ fixed4Text purchaseMetrics.latencyNum purchaseMetrics.latencyDen ++ ",throughput:" ++ fixed4Text purchaseMetrics.throughputNum purchaseMetrics.throughputDen ++ "}," ++
  "{label:'post_review',latency:" ++ fixed4Text reviewMetrics.latencyNum reviewMetrics.latencyDen ++ ",throughput:" ++ fixed4Text reviewMetrics.throughputNum reviewMetrics.throughputDen ++ "}," ++
  "{label:'worker',latency:" ++ fixed4Text workerMetrics.latencyNum workerMetrics.latencyDen ++ ",throughput:" ++ fixed4Text workerMetrics.throughputNum workerMetrics.throughputDen ++ "}," ++
  "{label:'assembled',latency:" ++ fixed4Text assembledMetrics.latencyNum assembledMetrics.latencyDen ++ ",throughput:" ++ fixed4Text assembledMetrics.throughputNum assembledMetrics.throughputDen ++ "}" ++
  "];" ++
  "const queueData=[" ++ queueChartData ++ "];" ++
  "const successData=[" ++
  "{label:'success',value:" ++ fixed4Text workerMetrics.successNum workerMetrics.successDen ++ ",color:'#22c55e'}," ++
  "{label:'failure',value:" ++ fixed4Text (workerMetrics.successDen - workerMetrics.successNum) workerMetrics.successDen ++ ",color:'#ef4444'}" ++
  "];" ++
  "const taskSuccessData=[" ++
  "{label:'get_docs',value:" ++ fixed4Text purchaseMetrics.successNum purchaseMetrics.successDen ++ ",color:'#93c5fd'}," ++
  "{label:'post_review',value:" ++ fixed4Text reviewMetrics.successNum reviewMetrics.successDen ++ ",color:'#fbbf24'}" ++
  "];" ++
  "function countBy(xs,key){const m=new Map();xs.forEach(x=>m.set(x[key],(m.get(x[key])||0)+1));return [...m.entries()].map(([label,value])=>({label,value}));}" ++
  "function cumulativeBytes(){let n=0;return orderedMessages.map((m,i)=>{n+=m.bytes;return{label:String(i+1),v:n};});}" ++
  "function messageIndex(){return orderedMessages.map((m,i)=>({label:m.task.replace('_',' ')+' '+String(i+1),v:i+1}));}" ++
  "function taskElapsed(){const by=new Map();orderedMessages.forEach(m=>{const r=by.get(m.task)||{min:m.ts,max:m.ts};r.min=Math.min(r.min,m.ts);r.max=Math.max(r.max,m.ts);by.set(m.task,r);});return [...by.entries()].map(([label,r])=>({label,v:r.max-r.min+1}));}" ++
  "const chartDatasets={" ++
  "cumulative_bytes:{label:'cumulative bytes over ordered messages',line:()=>[{name:'bytes',color:'#93c5fd',values:cumulativeBytes()}],pie:()=>countBy(orderedMessages,'task').map((d,i)=>({label:d.label,value:d.value,color:['#93c5fd','#fbbf24','#22c55e'][i%3]}))}," ++
  "messages_by_task:{label:'messages by task',line:()=>[{name:'count',color:'#fbbf24',values:countBy(orderedMessages,'task').map(d=>({label:d.label,v:d.value}))}],pie:()=>countBy(orderedMessages,'task').map((d,i)=>({label:d.label,value:d.value,color:['#22c55e','#93c5fd','#fbbf24'][i%3]}))}," ++
  "messages_by_actor:{label:'messages sent by actor',line:()=>[{name:'sent',color:'#22c55e',values:countBy(orderedMessages,'src').map(d=>({label:d.label,v:d.value}))}],pie:()=>countBy(orderedMessages,'src').map((d,i)=>({label:d.label,value:d.value,color:['#93c5fd','#fbbf24','#22c55e','#ef4444','#a78bfa'][i%5]}))}," ++
  "task_elapsed:{label:'task elapsed from ordered message timestamps',line:()=>[{name:'elapsed',color:'#a78bfa',values:taskElapsed()}],pie:()=>taskElapsed().map((d,i)=>({label:d.label,value:d.v,color:['#a78bfa','#93c5fd','#fbbf24'][i%3]}))}," ++
  "queue_distribution:{label:'time-weighted queue length distribution',line:()=>[{name:'queue probability',color:'#22c55e',values:queueData.map(d=>({label:'q='+d.q,v:d.p}))}],pie:()=>queueData.map((d,i)=>({label:'q='+d.q,value:d.p,color:['#22c55e','#ef4444','#93c5fd'][i%3]}))}," ++
  "success_failure:{label:'worker success/failure',line:()=>[{name:'probability',color:'#ef4444',values:successData.map(d=>({label:d.label,v:d.value}))}],pie:()=>successData}," ++
  "task_success:{label:'task success rates',line:()=>[{name:'success',color:'#93c5fd',values:taskSuccessData.map(d=>({label:d.label,v:d.value}))}],pie:()=>taskSuccessData}," ++
  "metrics:{label:'expected latency and throughput',line:()=>[{name:'latency',color:'#93c5fd',values:latencyData.map(d=>({label:d.label,v:d.latency}))},{name:'throughput',color:'#fbbf24',values:latencyData.map(d=>({label:d.label,v:d.throughput}))}],pie:()=>latencyData.map((d,i)=>({label:d.label,value:d.latency,color:['#93c5fd','#fbbf24','#22c55e','#ef4444','#a78bfa'][i%5]}))}" ++
  "};" ++
  "function chartFrame(ctx,w,h,title){ctx.fillStyle='#111';ctx.fillRect(0,0,w,h);ctx.strokeStyle='#555';ctx.lineWidth=1;ctx.strokeRect(0,0,w,h);ctx.fillStyle='#fff';ctx.font='16px sans-serif';ctx.textAlign='left';ctx.fillText(title,18,28);ctx.strokeStyle='#444';ctx.beginPath();ctx.moveTo(58,48);ctx.lineTo(58,h-46);ctx.lineTo(w-24,h-46);ctx.stroke();}" ++
  "function lineChart(id,title,series){const c=document.getElementById(id),ctx=c.getContext('2d'),w=c.width,h=c.height;chartFrame(ctx,w,h,title);const max=Math.max(...series.flatMap(s=>s.values.map(p=>p.v)),1);for(let gi=0;gi<5;gi++){const y=48+(h-94)*gi/4;ctx.strokeStyle='#252525';ctx.beginPath();ctx.moveTo(58,y);ctx.lineTo(w-24,y);ctx.stroke();ctx.fillStyle='#aaa';ctx.font='11px sans-serif';ctx.textAlign='right';ctx.fillText((max*(1-gi/4)).toFixed(2),52,y+4);}series.forEach(s=>{ctx.strokeStyle=s.color;ctx.fillStyle=s.color;ctx.lineWidth=2;ctx.beginPath();s.values.forEach((p,i)=>{const x=72+(w-116)*i/Math.max(1,s.values.length-1);const y=h-46-(h-104)*(p.v/max);if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);});ctx.stroke();s.values.forEach((p,i)=>{const x=72+(w-116)*i/Math.max(1,s.values.length-1);const y=h-46-(h-104)*(p.v/max);ctx.beginPath();ctx.arc(x,y,4,0,Math.PI*2);ctx.fill();ctx.fillStyle='#ddd';ctx.font='11px sans-serif';ctx.textAlign='center';ctx.fillText(p.label,x,h-26);ctx.fillStyle=s.color;});});let lx=w-190,ly=26;series.forEach(s=>{ctx.fillStyle=s.color;ctx.fillRect(lx,ly,12,8);ctx.fillStyle='#fff';ctx.font='12px sans-serif';ctx.textAlign='left';ctx.fillText(s.name,lx+18,ly+8);ly+=18;});}" ++
  "function pieChart(id,title,data){const c=document.getElementById(id),ctx=c.getContext('2d'),w=c.width,h=c.height;chartFrame(ctx,w,h,title);const total=data.reduce((n,d)=>n+d.value,0);let a=-Math.PI/2;const cx=w/2,cy=150,r=78;data.forEach(d=>{const b=a+Math.PI*2*(d.value/total);ctx.fillStyle=d.color;ctx.beginPath();ctx.moveTo(cx,cy);ctx.arc(cx,cy,r,a,b);ctx.closePath();ctx.fill();a=b;});let y=242;data.forEach(d=>{ctx.fillStyle=d.color;ctx.fillRect(48,y-10,14,10);ctx.fillStyle='#fff';ctx.font='13px sans-serif';ctx.textAlign='left';ctx.fillText(d.label+' '+d.value.toFixed(4),70,y);y+=20;});}" ++
  "function fillChartSelect(id,selected){const s=document.getElementById(id);s.innerHTML=Object.entries(chartDatasets).map(([k,d])=>'<option value=\"'+k+'\"'+(k===selected?' selected':'')+'>'+d.label+'</option>').join('');}" ++
  "function renderSlot(slot){const kind=document.getElementById('chartKind'+slot).value,key=document.getElementById('chartData'+slot).value,ds=chartDatasets[key],id='chart'+slot;if(kind==='pie')pieChart(id,ds.label,ds.pie());else lineChart(id,ds.label,ds.line());}" ++
  "function renderCharts(){renderSlot('A');renderSlot('B');}" ++
  "fillChartSelect('chartDataA','cumulative_bytes');fillChartSelect('chartDataB','messages_by_task');['chartKindA','chartKindB','chartDataA','chartDataB'].forEach(id=>document.getElementById(id).addEventListener('change',renderCharts));renderCharts();" ++
  "</script>"

def authDoc : String :=
  joinWith "\n"
    [ "# Auth Group"
    , ""
    , "This Markdown artifact documents the collapsed `Auth Group` node."
    , ""
    , "## Role"
    , ""
    , "The auth group models the requirement that a client obtains a visible proof artifact before using worker transactions."
    , ""
    , "## Actors"
    , ""
    , "- `Auth`"
    , "- `DB`"
    , ""
    , "## Messages"
    , ""
    , "- `Auth.LookupRequest`"
    , "- `Auth.LookupResponse authenticated=true`"
    , "- `Auth.LookupResponse authenticated=false`"
    , ""
    , "## Metrics"
    , ""
    , s!"- Success probability: `{fixed4Text authMetrics.successNum authMetrics.successDen}`"
    , s!"- Expected latency: `{fixed4Text authMetrics.latencyNum authMetrics.latencyDen}`"
    , s!"- Throughput: `{fixed4Text authMetrics.throughputNum authMetrics.throughputDen}`"
    , ""
    , "## Visualizations"
    , ""
    , "- [DOT](/auth.dot)"
    , "- Canvas rendering is available on the root page."
    ]

def workerDoc : String :=
  joinWith "\n"
    [ "# Worker Group"
    , ""
    , "This Markdown artifact documents the worker requirement group. It contains task FSMs that share the same actor set."
    , ""
    , "## Actors"
    , ""
    , "- `Client`"
    , "- `Gateway`"
    , "- `Worker`"
    , ""
    , "## Tasks"
    , ""
    , "- `get_docs`"
    , "- `post_review`"
    , ""
    , "## Composition Rule"
    , ""
    , "Tasks interact with actors only through queued, visible message envelopes. The graph can be collapsed to the group node or expanded into per-task FSM detail."
    , ""
    , "## Metrics"
    , ""
    , s!"- Success probability: `{fixed4Text workerMetrics.successNum workerMetrics.successDen}`"
    , s!"- Expected latency: `{fixed4Text workerMetrics.latencyNum workerMetrics.latencyDen}`"
    , s!"- Throughput: `{fixed4Text workerMetrics.throughputNum workerMetrics.throughputDen}`"
    , ""
    , "## Visualizations"
    , ""
    , "- [DOT](/graph.dot)"
    , "- Canvas rendering is available on the root page."
    ]

def getDocsDoc : String :=
  joinWith "\n" <|
    [ "# get_docs Task FSM"
    , ""
    , "This Markdown artifact documents the `get_docs` task FSM."
    , ""
    , "## Entry Message"
    , ""
    , "- `Client -> Gateway: Docs.GetRequest`"
    , ""
    , "## Message Flow"
    , ""
    , "- `Gateway -> Worker: Docs.FetchCommand`"
    , "- `Worker -> Gateway: Docs.FetchResult`"
    , "- `Gateway -> Client: Docs.GetResponse` or `Error.Response`"
    , ""
    , "## CTL Checks"
    , ""
    ] ++
    taskCtlLines "get_docs" purchaseTaskFSM ++
    [ ""
    , "## Metrics"
    , ""
    , s!"- Success probability: `{fixed4Text purchaseMetrics.successNum purchaseMetrics.successDen}`"
    , s!"- Expected latency: `{fixed4Text purchaseMetrics.latencyNum purchaseMetrics.latencyDen}`"
    , s!"- Throughput: `{fixed4Text purchaseMetrics.throughputNum purchaseMetrics.throughputDen}`"
    , ""
    , "## Visualizations"
    , ""
    , "- [DOT](/get_docs.dot)"
    , "- Canvas rendering is available on the root page."
    ]

def postReviewDoc : String :=
  joinWith "\n" <|
    [ "# post_review Task FSM"
    , ""
    , "This Markdown artifact documents the `post_review` task FSM."
    , ""
    , "## Entry Message"
    , ""
    , "- `Client -> Gateway: Reviews.PostRequest`"
    , ""
    , "## Message Flow"
    , ""
    , "- `Gateway -> Worker: Reviews.ModerateCommand`"
    , "- `Worker -> Gateway: Reviews.ModerationResult`"
    , "- `Gateway -> Client: Reviews.PostResponse`"
    , ""
    , "## CTL Checks"
    , ""
    ] ++
    taskCtlLines "post_review" reviewTaskFSM ++
    [ ""
    , "## Metrics"
    , ""
    , s!"- Success probability: `{fixed4Text reviewMetrics.successNum reviewMetrics.successDen}`"
    , s!"- Expected latency: `{fixed4Text reviewMetrics.latencyNum reviewMetrics.latencyDen}`"
    , s!"- Throughput: `{fixed4Text reviewMetrics.throughputNum reviewMetrics.throughputDen}`"
    , ""
    , "## Visualizations"
    , ""
    , "- [DOT](/post_review.dot)"
    , "- Canvas rendering is available on the root page."
    ]

def assembledDoc : String :=
  joinWith "\n"
    [ "# Assembled System"
    , ""
    , "This Markdown artifact documents the top-level assembled system."
    , ""
    , "## Composition"
    , ""
    , "The assembled model composes the auth group with the worker group. On auth success, worker transactions can run with a visible proof artifact."
    , ""
    , "## Metrics"
    , ""
    , s!"- Success probability: `{fixed4Text assembledMetrics.successNum assembledMetrics.successDen}`"
    , s!"- Expected latency: `{fixed4Text assembledMetrics.latencyNum assembledMetrics.latencyDen}`"
    , s!"- Throughput: `{fixed4Text assembledMetrics.throughputNum assembledMetrics.throughputDen}`"
    , ""
    , "## Visualizations"
    , ""
    , "- [DOT](/assembled.dot)"
    , "- Canvas rendering is available on the root page."
    ]

def docsIndex : String :=
  joinWith "\n"
    [ "# LeanFM Generated Docs"
    , ""
    , "These Markdown files are deterministic artifacts generated from the LeanFM model. They correspond to collapsed or nested graph nodes."
    , ""
    , "- [Auth Group](/docs/auth.md)"
    , "- [Worker Group](/docs/worker.md)"
    , "- [get_docs Task FSM](/docs/get_docs.md)"
    , "- [post_review Task FSM](/docs/post_review.md)"
    , "- [Assembled System](/docs/assembled.md)"
    ]

def aggregateGraphDataValidationReport : String :=
  LeanFM.GeneratedRequirements.validationReport

def aggregateGraphAnimation : String :=
  "<section><h2>Aggregate Graph</h2><div class=\"controlPanel\"><label><input id=\"aggCutEdges\" type=\"checkbox\" checked> edge corridors push boxes out of arrow paths</label> <span class=\"zoomControls\"><button id=\"aggZoomOut\" type=\"button\">-</button><span id=\"aggZoomLabel\">100%</span><button id=\"aggZoomIn\" type=\"button\">+</button><button id=\"aggZoomReset\" type=\"button\">reset</button></span></div><div class=\"canvasPanel\"><canvas id=\"aggGraph\" width=\"1000\" height=\"520\"></canvas><div id=\"aggInfo\"></div></div></section>" ++
  "<script id=\"aggGraphModel\" type=\"application/json\">" ++ aggregateGraphJson LeanFM.GeneratedRequirements.aggregateGraphData ++ "</script>" ++
  "<script>" ++ LeanFM.StaticAssets.aggregateGraphJs ++ "</script>"

def pageCss : String :=
  "<meta name=\"color-scheme\" content=\"dark only\">" ++
  "<style>html,body{background:#111;color:#f8f8f8;color-scheme:dark only;forced-color-adjust:none}body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4}a{color:#93c5fd}pre{background:#050505;color:#f8f8f8;border:1px solid #333;padding:1rem;overflow:auto}code{font-family:ui-monospace,monospace}details{border:1px solid #444;margin:.75rem 0 1rem;background:#090909}summary{cursor:pointer;padding:.75rem 1rem;font-weight:700}.diagram{background:#111;border-top:1px solid #333;margin:0;padding:1rem;overflow:auto;min-height:220px;forced-color-adjust:none}.diagramGrid canvas{display:block;width:100%;max-width:900px;height:auto;background:#111;border-top:1px solid #333}.controlPanel{margin:.5rem 0 1rem}.controlPanel select{background:#000;color:#fff;border:1px solid #666;padding:.35rem}.zoomControls{display:inline-flex;gap:.35rem;align-items:center;margin-left:.75rem}.zoomControls button{background:#000;color:#fff;border:1px solid #666;padding:.25rem .55rem;min-width:2rem}.zoomControls span{font:12px ui-monospace,monospace;color:#ddd;min-width:3.5rem;text-align:center}.subjectPanel{display:grid;grid-template-columns:minmax(420px,1fr) 340px;gap:1rem;align-items:start}.subjectPanel canvas{width:100%;height:auto;background:#111;border:1px solid #555}.artifactPanel details{margin:.5rem 0}.artifactPanel pre{max-height:220px}.chatShell{display:grid;grid-template-columns:minmax(320px,2fr) minmax(260px,1fr);gap:1rem;border:1px solid #444;background:#090909;padding:1rem;margin-bottom:1rem}.chatLog{height:340px;overflow:auto;background:#050505;border:1px solid #333;padding:1rem}.bubble{max-width:76%;padding:.7rem .85rem;margin:.55rem 0;border:1px solid #444;white-space:normal}.bubble.user{margin-left:auto;background:#10233f}.bubble.assistant{background:#111827}.chatInput{grid-column:1 / 2;display:grid;grid-template-columns:1fr auto;gap:.5rem}.chatInput textarea{background:#000;color:#fff;border:1px solid #666;padding:.65rem;font:14px ui-monospace,monospace;resize:vertical}.chatInput button{background:#1d4ed8;color:#fff;border:1px solid #93c5fd;padding:0 1rem;font-weight:700}.toolLog{grid-column:2;grid-row:1 / 3;height:420px;overflow:auto;background:#050505;border:1px solid #333;padding:.75rem;font:12px ui-monospace,monospace}.toolCall{border-bottom:1px solid #222;padding:.4rem 0;color:#93c5fd}.canvasPanel{display:grid;grid-template-columns:minmax(320px,900px) minmax(260px,1fr);gap:1rem;align-items:start;overflow:auto}.canvasPanel canvas{width:100%;height:auto;background:#111;border:1px solid #555;cursor:grab}.canvasPanel #aggGraph{width:auto;max-width:none}.canvasPanel ol,.canvasPanel ul{margin:0;padding-left:1.5rem;font-family:ui-monospace,monospace}.canvasPanel li{padding:.2rem .35rem}.canvasPanel li.active{background:#1d4ed8;color:#fff}.chartControls,.chartEditor{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:.5rem;align-items:end;margin:.5rem 0 1rem}.chartControls select,.chartEditor select,.chartEditor input{background:#000;color:#fff;border:1px solid #666;padding:.4rem;width:100%;box-sizing:border-box}.chartEditor button{background:#000;color:#fff;border:1px solid #666;padding:.45rem .7rem}.chartGrid,.namedCharts{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1rem;margin-bottom:1rem}.chartGrid canvas,.namedCharts canvas{width:100%;height:auto;background:#111;border:1px solid #555}.chartCard{background:#090909;border:1px solid #444;padding:.75rem}.chartCard h3{margin:.1rem 0 .5rem;font-size:1rem}.chartCardDelete{margin-top:.5rem;background:#000;color:#fff;border:1px solid #666;padding:.35rem .65rem}@media(max-width:900px){.subjectPanel,.chatShell,.canvasPanel{grid-template-columns:1fr}.toolLog{grid-column:auto;grid-row:auto}.chatInput{grid-column:auto}}</style>"

def topNav : String :=
  "<p><a href=\"/\">ask</a> | <a href=\"/examples\">examples</a> | <a href=\"/renders/\">canvas renders</a> | <a href=\"/metrics\">prometheus metrics</a> | <a href=\"/report\">generated report</a> | <a href=\"/docs/\">generated docs</a></p>"

def htmlPage : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM Workbench</title>" ++
  pageCss ++
  "</head><body><h1>LeanFM Workbench</h1>" ++
  "<p>Ask for a visible-behavior protocol or requirement. The request router decides whether to call deterministic tools, return generated text, or link canvas renders.</p>" ++
  topNav ++
  liveSubjectGraph ++
  chatWorkbench ++
  "</body></html>"

def examplesPage : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM Examples</title>" ++
  pageCss ++
  "</head><body><h1>LeanFM</h1><p>Lean-native model of message-passing processes.</p>" ++
  topNav ++
  chatWorkbench ++
  conversationPicker ++
  trafficAnimation ++
  interactionDiagram ++
  chartsSection ++
  aggregateGraphAnimation ++
  canvasDiagramGallery ++
  "<pre>" ++ textReport ++ "</pre></body></html>"

end LeanFM
