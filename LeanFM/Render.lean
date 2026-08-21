import LeanFM.Protocol

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
  "<section><h2>Current Requirement</h2><div class=\"controlPanel\"><label><input id=\"subjectCutEdges\" type=\"checkbox\" checked> edge corridors push boxes out of arrow paths</label></div><div class=\"subjectPanel\"><canvas id=\"subjectGraph\" width=\"1180\" height=\"720\"></canvas><div><h3 id=\"subjectTitle\">No active draft</h3><p id=\"subjectSummary\">Ask the assistant to sketch a protocol or task.</p><div id=\"subjectArtifacts\" class=\"artifactPanel\"></div></div></div></section>" ++
  "<script>" ++
  "(()=>{const cv=document.getElementById('subjectGraph'),ctx=cv.getContext('2d'),title=document.getElementById('subjectTitle'),summary=document.getElementById('subjectSummary'),artifacts=document.getElementById('subjectArtifacts'),cutBox=document.getElementById('subjectCutEdges');cutBox.checked=localStorage.getItem('leanfm.subject.cutEdges')!=='false';cutBox.addEventListener('change',()=>localStorage.setItem('leanfm.subject.cutEdges',cutBox.checked?'true':'false'));" ++
  "const empty={id:'empty',task:'No active draft',actors:[],messages:[],properties:[],reducers:[],markdown:''};let model=JSON.parse(localStorage.getItem('leanfm.subject')||'null')||empty;" ++
  "function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}" ++
  "function lines(text,max){const words=String(text).split(/\\s+/),out=[];let line='';for(const w of words){if((line+' '+w).trim().length>max){if(line)out.push(line);line=w;}else line=(line+' '+w).trim();}if(line)out.push(line);return out.length?out:[''];}" ++
  "function msgParts(m){const mm=String(m).match(/^\\s*([^\\s]+)\\s*->\\s*([^\\s]+)\\s+([^\\s]+)\\s*(.*)$/);return mm?{src:mm[1],dst:mm[2],proto:mm[3],fields:mm[4]}:{src:'?',dst:'?',proto:String(m),fields:''};}" ++
  "function rect(x,y,w,h,label,color){ctx.fillStyle='#000';ctx.strokeStyle=color||'#fff';ctx.lineWidth=2;ctx.fillRect(x,y,w,h);ctx.strokeRect(x,y,w,h);ctx.fillStyle='#fff';ctx.font='13px sans-serif';ctx.textAlign='center';const ls=lines(label,Math.max(12,Math.floor(w/8))).slice(0,4);ls.forEach((t,i)=>ctx.fillText(t,x+w/2,y+h/2-(ls.length-1)*8+i*16));}" ++
  "function arrow(x1,y1,x2,y2,color){ctx.strokeStyle=color||'#93c5fd';ctx.fillStyle=color||'#93c5fd';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.stroke();const a=Math.atan2(y2-y1,x2-x1);ctx.beginPath();ctx.moveTo(x2,y2);ctx.lineTo(x2-12*Math.cos(a-.45),y2-12*Math.sin(a-.45));ctx.lineTo(x2-12*Math.cos(a+.45),y2-12*Math.sin(a+.45));ctx.closePath();ctx.fill();}" ++
  "function labelBox(x,y,text,color,w){const ls=lines(text,Math.floor((w||210)/8)).slice(0,3),h=18+ls.length*15;ctx.fillStyle='#000';ctx.strokeStyle=color||'#93c5fd';ctx.lineWidth=1.5;ctx.fillRect(x-(w||210)/2,y-h/2,w||210,h);ctx.strokeRect(x-(w||210)/2,y-h/2,w||210,h);ctx.fillStyle='#fff';ctx.font='11px sans-serif';ctx.textAlign='center';ls.forEach((t,i)=>ctx.fillText(t,x,y-(ls.length-1)*7+i*14+4));}" ++
  "function group(x,y,w,h,label){ctx.fillStyle='#111827';ctx.strokeStyle='#777';ctx.lineWidth=2;ctx.fillRect(x,y,w,h);ctx.strokeRect(x,y,w,h);ctx.fillStyle='#fff';ctx.font='16px sans-serif';ctx.textAlign='left';ctx.fillText(label,x+14,y+24);}" ++
  "let openGroups=new Set(JSON.parse(localStorage.getItem('leanfm.subject.open')||'[]'));let nodes=[],edges=[],hit=[],childById=new Map(),drag=null,started=false;" ++
  "function mdLines(){return String(model.markdown||'').split(/\\n+/).map(s=>s.replace(/^#+\\s*/, '').trim()).filter(Boolean).slice(0,8);}" ++
  "function groupChildren(n){const msgs=(model.messages||[]).map(msgParts),props=model.properties||[],reducers=model.reducers||[],md=mdLines();if(n.id==='pre')return md.length&&!msgs.length?md:['entry request','auth/proof preconditions','queue/readiness'];if(n.id==='exchange')return msgs.length?['state 0: ready'].concat(msgs.map((m,i)=>'state '+(i+1)+': after '+m.proto)).concat(['terminal observation']):(md.length?md:['Markdown-only requirement']);if(n.id==='terminal')return msgs.length?['postcondition','cleanup task','terminal observation']:(md.length?['requirement accepted','no temporal machine required']:['postcondition']);if(n.id==='annotations')return['actors: '+(model.actors||[]).join(', ')].concat(props.slice(0,3)).concat(reducers.slice(0,2)).concat(md.slice(0,3));return[];}" ++
  "function groupSize(n){if(!openGroups.has(n.id))return{w:230,h:82};const kids=groupChildren(n),baseW=n.id==='exchange'?560:360,baseH=Math.max(260,120+kids.length*58);let minX=0,maxX=0,minY=0,maxY=0;for(const c of childById.values()){if(!c.key.startsWith(n.id+'|'))continue;minX=Math.min(minX,c.x-n.x);maxX=Math.max(maxX,c.x-n.x);minY=Math.min(minY,c.y-n.y);maxY=Math.max(maxY,c.y-n.y);}return{w:Math.max(baseW,maxX-minX+360),h:Math.max(baseH,maxY-minY+180)};}" ++
  "function rectPort(a,b){const s=groupSize(a),dx=b.x-a.x,dy=b.y-a.y,m=Math.min((s.w/2+10)/Math.max(1,Math.abs(dx)),(s.h/2+10)/Math.max(1,Math.abs(dy)));return{x:a.x+dx*m,y:a.y+dy*m};}" ++
  "function drawArrowLabel(a,b,label,color){const p1=rectPort(a,b),p2=rectPort(b,a);arrow(p1.x,p1.y,p2.x,p2.y,color);labelBox((p1.x+p2.x)/2,(p1.y+p2.y)/2-16,label,color,260);}" ++
  "function concreteEdges(){const msgs=(model.messages||[]).map(msgParts),out=[['pre|entry request','exchange|state 0: ready','instantiate task FSM from queued request']];for(let i=0;i<msgs.length;i++){const m=msgs[i];out.push(['exchange|state '+i+': '+(i===0?'ready':'after '+msgs[i-1].proto),'exchange|state '+(i+1)+': after '+m.proto,m.src+' -> '+m.dst+' '+m.proto]);}if(msgs.length)out.push(['exchange|state '+msgs.length+': after '+msgs[msgs.length-1].proto,'terminal|postcondition','terminal cleanup / task completes']);out.push(['terminal|postcondition','annotations|CTL over visible states','optional CTL / reducers over visible fields']);return out;}" ++
  "function build(){const msgs=(model.messages||[]).map(msgParts);const old=new Map(nodes.map(n=>[n.id,n]));function node(id,label,rank,color,x){const o=old.get(id);return{id,label,rank,color,x:o?o.x:x,y:o?o.y:160+rank*260,vx:o?o.vx:0,vy:o?o.vy:0,pinned:o?o.pinned:false};}nodes=[node('pre','preconditions',0,'#93c5fd',250),node('exchange','message exchange',1,'#fbbf24',560),node('terminal','terminal / cleanup',2,'#22c55e',560),node('annotations','properties / reducers',1,'#a78bfa',930)];edges=msgs.length?[['pre','exchange',msgs[0].src+' -> '+msgs[0].dst+' '+msgs[0].proto],['exchange','terminal','terminal cleanup / task completes'],['terminal','annotations','CTL over visible fields']]:[['pre','exchange','entry'],['exchange','terminal','terminal cleanup / task completes'],['terminal','annotations','CTL over visible fields']];}" ++
  "function resizeCanvas(){let area=0,maxW=0,maxH=0;for(const n of nodes){const s=groupSize(n);area+=s.w*s.h;maxW=Math.max(maxW,s.w);maxH=Math.max(maxH,s.h);}const wantW=Math.max(1180,maxW+620,Math.ceil(Math.sqrt(area))*2+520),wantH=Math.max(720,maxH+420,260+nodes.length*230,Math.ceil(Math.sqrt(area))*2+360);if(cv.width!==wantW||cv.height!==wantH){const ox=cv.width/2,oy=cv.height/2;cv.width=wantW;cv.height=wantH;for(const n of nodes){n.x+=wantW/2-ox;n.y+=wantH/2-oy;}}}" ++
  "function clamp(n){const s=groupSize(n),m=84;n.x=Math.max(s.w/2+m,Math.min(cv.width-s.w/2-m,n.x));n.y=Math.max(s.h/2+m,Math.min(cv.height-s.h/2-m,n.y));}" ++
  "function separateRects(){for(let pass=0;pass<10;pass++)for(let i=0;i<nodes.length;i++)for(let j=i+1;j<nodes.length;j++){const a=nodes[i],b=nodes[j],as=groupSize(a),bs=groupSize(b);let dx=b.x-a.x,dy=b.y-a.y;if(Math.abs(dx)<1&&Math.abs(dy)<1){dx=11;dy=7;}const ox=(as.w+bs.w)/2+140-Math.abs(dx),oy=(as.h+bs.h)/2+140-Math.abs(dy);if(ox>0&&oy>0){if(ox<oy){const m=ox/2+18,sgn=Math.sign(dx||1);if(!a.pinned)a.x-=m*sgn;if(!b.pinned)b.x+=m*sgn;a.vx*=0.05;b.vx*=0.05;}else{const m=oy/2+18,sgn=Math.sign(dy||1);if(!a.pinned)a.y-=m*sgn;if(!b.pinned)b.y+=m*sgn;a.vy*=0.05;b.vy*=0.05;}clamp(a);clamp(b);}}}" ++
  "function flowWeights(ids,es){let w=new Map(ids.map(id=>[id,1])),out=new Map(ids.map(id=>[id,0]));for(const e of es)out.set(e[0],(out.get(e[0])||0)+1);for(let k=0;k<14;k++){const next=new Map(ids.map(id=>[id,.18]));for(const e of es){const share=(w.get(e[0])||1)/Math.max(1,out.get(e[0])||1);next.set(e[1],(next.get(e[1])||.18)+.82*share);}w=next;}return w;}" ++
  "function edgeCorridors(by){if(!cutBox.checked)return;for(const e of edges){const a=by.get(e[0]),b=by.get(e[1]);if(!a||!b)continue;const ax=a.x,ay=a.y,bx=b.x,byy=b.y,ex=bx-ax,ey=byy-ay,len2=Math.max(1,ex*ex+ey*ey);for(const n of nodes){if(n.id===a.id||n.id===b.id||n.pinned)continue;const s=groupSize(n),t=Math.max(0,Math.min(1,((n.x-ax)*ex+(n.y-ay)*ey)/len2)),px=ax+ex*t,py=ay+ey*t,dx=n.x-px,dy=n.y-py,d=Math.max(1,Math.sqrt(dx*dx+dy*dy)),corridor=Math.max(s.w,s.h)/2+92;if(d<corridor){const f=(corridor-d)*0.028;n.vx+=dx/d*f;n.vy+=dy/d*f;}}}}" ++
  "function stepForce(){const by=new Map(nodes.map(n=>[n.id,n])),cx=cv.width/2,weight=flowWeights(nodes.map(n=>n.id),edges);for(const n of nodes){if(n.pinned)continue;const w=weight.get(n.id)||1;n.vx+=(cx-n.x)*0.00045;n.vy+=(170+n.rank*280+w*74-n.y)*(0.0022+Math.min(w,4)*0.00045);}for(const e of edges){const a=by.get(e[0]),b=by.get(e[1]);if(!a||!b)continue;const bw=weight.get(b.id)||1,as=groupSize(a),bs=groupSize(b),dx=b.x-a.x,dy=b.y-a.y,d=Math.max(1,Math.sqrt(dx*dx+dy*dy));const targetY=(as.h+bs.h)/2+210+bw*54,targetX=Math.max((as.w+bs.w)/2+190,340);const fy=(dy-targetY)*(0.013+Math.min(bw,4)*0.0025),fx=(Math.abs(dx)-targetX)*0.0015*Math.sign(dx||1);if(!a.pinned){a.vy+=fy;a.vx+=fx;}if(!b.pinned){b.vy-=fy;b.vx-=fx;}if(b.y<a.y+targetY){const push=(a.y+targetY-b.y)*(0.034+Math.min(bw,4)*0.006);if(!a.pinned)a.vy-=push;if(!b.pinned)b.vy+=push;}}edgeCorridors(by);for(let i=0;i<nodes.length;i++)for(let j=i+1;j<nodes.length;j++){const a=nodes[i],b=nodes[j],as=groupSize(a),bs=groupSize(b);let dx=b.x-a.x,dy=b.y-a.y;if(Math.abs(dx)<1&&Math.abs(dy)<1){dx=7;dy=5;}const d2=Math.max(1,dx*dx+dy*dy),d=Math.sqrt(d2),near=Math.max((as.w+bs.w)/2+230,(as.h+bs.h)/2+210),rep=(near*near*0.34)/d2,rx=rep*dx/d,ry=rep*dy/d;if(!a.pinned){a.vx-=rx;a.vy-=ry;}if(!b.pinned){b.vx+=rx;b.vy+=ry;}}separateRects();for(const n of nodes){if(n.pinned){n.vx=0;n.vy=0;}else{n.vx=Math.max(-22,Math.min(22,n.vx*0.34));n.vy=Math.max(-22,Math.min(22,n.vy*0.34));n.x+=n.vx;n.y+=n.vy;}clamp(n);}separateRects();}" ++
  "function childState(parent,id,i,total){const key=parent.id+'|'+id;let c=childById.get(key);const s=groupSize(parent),cols=Math.max(1,Math.ceil(Math.sqrt(total))),col=i%cols,row=Math.floor(i/cols),tx=parent.x+(col-(cols-1)/2)*330,ty=parent.y-s.h/2+96+row*96;if(!c){c={id,key,x:tx,y:ty,vx:0,vy:0,pinned:false,parent:parent.id};childById.set(key,c);}if(!c.pinned){c.vx+=(tx-c.x)*0.014;c.vy+=(ty-c.y)*0.014;}for(const other of childById.values()){if(other===c||!other.key.startsWith(parent.id+'|'))continue;let dx=c.x-other.x,dy=c.y-other.y;if(Math.abs(dx)<1&&Math.abs(dy)<1){dx=4;dy=3;}const ox=350-Math.abs(dx),oy=112-Math.abs(dy);if(ox>0&&oy>0){if(ox<oy){const m=ox/2+8,sgn=Math.sign(dx||1);if(!c.pinned)c.x+=m*sgn;if(!other.pinned)other.x-=m*sgn;c.vx*=0.08;other.vx*=0.08;}else{const m=oy/2+8,sgn=Math.sign(dy||1);if(!c.pinned)c.y+=m*sgn;if(!other.pinned)other.y-=m*sgn;c.vy*=0.08;other.vy*=0.08;}}}if(!c.pinned){c.vx=Math.max(-8,Math.min(8,c.vx*0.38));c.vy=Math.max(-8,Math.min(8,c.vy*0.38));c.x+=c.vx;c.y+=c.vy;}c.x=Math.max(parent.x-s.w/2+145,Math.min(parent.x+s.w/2-145,c.x));c.y=Math.max(parent.y-s.h/2+76,Math.min(parent.y+s.h/2-46,c.y));return c;}" ++
  "function drawNode(n){const s=groupSize(n),x=n.x-s.w/2,y=n.y-s.h/2;ctx.fillStyle=openGroups.has(n.id)?'#111827':'#000';ctx.strokeStyle=n.color;ctx.lineWidth=2;ctx.fillRect(x,y,s.w,s.h);ctx.strokeRect(x,y,s.w,s.h);ctx.fillStyle='#fff';ctx.font='15px sans-serif';ctx.textAlign='center';ctx.fillText(n.label,n.x,y+26);ctx.font='12px sans-serif';ctx.fillText(openGroups.has(n.id)?'open: click to collapse':'closed: click to expand',n.x,y+47);hit.push({kind:'group',id:n.id,x,y,w:s.w,h:s.h});if(openGroups.has(n.id)){const labels=groupChildren(n),kids=labels.map((st,i)=>childState(n,st,i,labels.length));kids.forEach((c,i)=>{const color=i===0?'#93c5fd':i===labels.length-1?'#22c55e':n.color;rect(c.x-130,c.y-20,260,40,labels[i],color);hit.push({kind:'child',id:c.key,x:c.x-130,y:c.y-20,w:260,h:40});});}}" ++
  "function endpoint(id){const parent=id.split('|')[0],pn=nodes.find(n=>n.id===parent),child=childById.get(id);if(child&&openGroups.has(parent))return{kind:'child',id,x:child.x,y:child.y,w:260,h:40,parent};if(pn){const s=groupSize(pn);return{kind:'group',id:parent,x:pn.x,y:pn.y,w:s.w,h:s.h,parent};}return null;}" ++
  "function portFrom(ep,to){const dx=to.x-ep.x,dy=to.y-ep.y,m=Math.min((ep.w/2+10)/Math.max(1,Math.abs(dx)),(ep.h/2+10)/Math.max(1,Math.abs(dy)));return{x:ep.x+dx*m,y:ep.y+dy*m};}" ++
  "function drawConcreteEdges(){const seen=new Map();for(const e of concreteEdges()){const a=endpoint(e[0]),b=endpoint(e[1]);if(!a||!b)continue;const collapsed=a.kind==='group'&&b.kind==='group'&&a.id===b.id;if(collapsed){const key=a.id;seen.set(key,(seen.get(key)||[]).concat(e[2]));continue;}const p1=portFrom(a,b),p2=portFrom(b,a);arrow(p1.x,p1.y,p2.x,p2.y,'#fbbf24');labelBox((p1.x+p2.x)/2,(p1.y+p2.y)/2-16,e[2],'#fbbf24',280);}for(const [gid,labels] of seen){const n=nodes.find(x=>x.id===gid);if(!n)continue;labelBox(n.x,n.y+18,labels.length+' concrete message transitions inside: '+labels.slice(0,2).join(' | '),'#fbbf24',320);}}" ++
  "function render(){if(!nodes.length)build();if(!drag)resizeCanvas();stepForce();ctx.fillStyle='#111';ctx.fillRect(0,0,cv.width,cv.height);title.textContent=model.label||model.task||model.id||'Current draft';summary.textContent='Persistent browser model: '+(model.actors||[]).length+' actors, '+(model.messages||[]).length+' visible messages, '+(model.properties||[]).length+' properties. Click composite states to open or close them.';hit=[];for(const n of nodes)drawNode(n);drawConcreteEdges();requestAnimationFrame(render);}" ++
  "function save(next){model=Object.assign({},empty,next);localStorage.setItem('leanfm.subject',JSON.stringify(model));build();}" ++
  "function textCard(title,text){const d=document.createElement('details');d.open=true;d.innerHTML='<summary>'+esc(title)+'</summary><pre>'+esc(text)+'</pre>';artifacts.prepend(d);}" ++
  "function linkCard(title,links){const d=document.createElement('details');d.open=true;d.innerHTML='<summary>'+esc(title)+'</summary>'+links.map(x=>'<p><a href=\"'+esc(x.href)+'\">'+esc(x.label)+'</a></p>').join('');artifacts.prepend(d);}" ++
  "function point(ev){const r=cv.getBoundingClientRect();return{x:(ev.clientX-r.left)*cv.width/r.width,y:(ev.clientY-r.top)*cv.height/r.height};}function hitAt(p){return hit.filter(h=>p.x>=h.x-12&&p.x<=h.x+h.w+12&&p.y>=h.y-12&&p.y<=h.y+h.h+12).sort((a,b)=>(a.w*a.h)-(b.w*b.h))[0];}cv.style.touchAction='none';cv.style.cursor='grab';cv.addEventListener('pointerdown',ev=>{ev.preventDefault();const p=point(ev),h=hitAt(p);if(!h)return;if(h.kind==='child'){const c=childById.get(h.id);if(!c)return;c.pinned=true;c.vx=0;c.vy=0;drag={kind:'child',node:c,offX:p.x-c.x,offY:p.y-c.y,moved:false};}else{const n=nodes.find(x=>x.id===h.id);if(!n)return;n.pinned=true;n.vx=0;n.vy=0;drag={kind:'group',node:n,offX:p.x-n.x,offY:p.y-n.y,moved:false};}cv.setPointerCapture(ev.pointerId);cv.style.cursor='grabbing';});cv.addEventListener('pointermove',ev=>{const p=point(ev);if(!drag){cv.style.cursor=hitAt(p)?'grab':'default';return;}ev.preventDefault();drag.moved=true;drag.node.x=p.x-drag.offX;drag.node.y=p.y-drag.offY;drag.node.vx=0;drag.node.vy=0;if(drag.kind==='group')clamp(drag.node);});cv.addEventListener('pointerup',ev=>{if(drag){ev.preventDefault();try{cv.releasePointerCapture(ev.pointerId);}catch(e){}if(!drag.moved&&drag.kind==='group'){openGroups.has(drag.node.id)?openGroups.delete(drag.node.id):openGroups.add(drag.node.id);localStorage.setItem('leanfm.subject.open',JSON.stringify([...openGroups]));}drag=null;cv.style.cursor='grab';}});cv.addEventListener('pointercancel',ev=>{drag=null;cv.style.cursor='grab';});cv.addEventListener('dblclick',ev=>{ev.preventDefault();const p=point(ev),h=hitAt(p);if(!h)return;if(h.kind==='child'){const c=childById.get(h.id);if(c)c.pinned=false;}else{const n=nodes.find(x=>x.id===h.id);if(n)n.pinned=false;}});" ++
  "window.LeanFMUI={setSubject:save,renderText:textCard,renderLinks:linkCard,getSubject:()=>model};build();render();})();" ++
  "</script>"

def chatWorkbench : String :=
  "<section><h2>LeanFM Assistant</h2><div class=\"chatShell\"><div id=\"chatLog\" class=\"chatLog\"></div><div class=\"chatInput\"><textarea id=\"chatPrompt\" rows=\"3\" placeholder=\"Ask for a protocol sketch, diagram render, generated text, metrics, or validation\"></textarea><button id=\"chatSend\">Send</button></div><div id=\"toolLog\" class=\"toolLog\"></div></div></section>" ++
  "<script>" ++
  "const chatLog=document.getElementById('chatLog'),toolLog=document.getElementById('toolLog'),chatPrompt=document.getElementById('chatPrompt'),chatSend=document.getElementById('chatSend');" ++
  "let currentDraft=null;" ++
  "const artifactLinks=[['all canvas renders','/renders/'],['worker canvas render','/renders/worker'],['get_docs canvas render','/renders/get_docs'],['post_review canvas render','/renders/post_review'],['task interaction render','/renders/tasks'],['prometheus metrics','/metrics'],['generated text report','/report'],['generated docs','/docs/'],['worker DOT text','/graph.dot'],['auth DOT text','/auth.dot'],['get_docs DOT text','/get_docs.dot'],['post_review DOT text','/post_review.dot'],['task conversations DOT text','/tasks.dot'],['assembled DOT text','/assembled.dot']];" ++
  "function esc(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}" ++
  "function bubble(role,text){const d=document.createElement('div');d.className='bubble '+role;d.innerHTML=esc(text).replace(/\\n/g,'<br>');chatLog.appendChild(d);chatLog.scrollTop=chatLog.scrollHeight;}" ++
  "function tool(name,args){const d=document.createElement('div');d.className='toolCall';d.textContent='tool: '+name+' '+JSON.stringify(args);toolLog.prepend(d);}" ++
  "function setSubject(s){currentDraft=s;if(window.LeanFMUI)window.LeanFMUI.setSubject(s);}" ++
  "async function callMetrics(){tool('get_report',{url:'/report'});const t=await fetch('/report').then(r=>r.text());const out=t.split('\\n').filter(x=>x.includes('success probability')||x.includes('expected latency')||x.includes('throughput')||x.includes('Per-task FSM')).slice(0,18).join('\\n');if(window.LeanFMUI)window.LeanFMUI.renderText('generated metrics text',out);return out;}" ++
  "function callArtifacts(){tool('list_artifacts',{});const links=artifactLinks.map(a=>({label:a[0],href:a[1]}));if(window.LeanFMUI)window.LeanFMUI.renderLinks('generated render/text artifacts',links);return artifactLinks.map(a=>a[0]+': '+location.origin+a[1]).join('\\n');}" ++
  "function callCharts(){tool('list_chart_datasets',{});return ['cumulative bytes over ordered messages','messages by task','messages sent by actor','task elapsed from ordered message timestamps','queue length distribution','worker success/failure','task success rates','expected latency and throughput'].join('\\n');}" ++
  "async function callScenarioCatalog(){tool('scenario_catalog',{url:'/tools/scenarios'});return await fetch('/tools/scenarios').then(r=>r.json());}" ++
  "async function callProtocolSketchCatalog(){tool('protocol_sketch_catalog',{url:'/tools/protocol-sketches'});return await fetch('/tools/protocol-sketches').then(r=>r.json());}" ++
  "function validateSpec(text){tool('validate_requirement_sketch',{observableFieldsOnly:true});const needed=['actor','task','message'];const miss=needed.filter(k=>!text.toLowerCase().includes(k));const refsHidden=/database|memory|internal variable|private state/i.test(text);let out=[];if(miss.length)out.push('missing: '+miss.join(', '));if(refsHidden)out.push('reject: references hidden implementation state; use visible messages/queues/proofs instead');if(/token|proof|cert/i.test(text)&&!/message|field|payload/i.test(text))out.push('warning: capability should name the visible message field where it appears');if(!out.length)out.push('well-formed sketch: includes actor/task/message vocabulary and no obvious hidden-state references');const r=out.join('\\n');if(window.LeanFMUI)window.LeanFMUI.renderText('validation result',r);return r;}" ++
  "function requirementTemplate(){tool('spec_template',{format:'LeanFM requirement'});return 'Requirement template\\nmarkdown: each nested requirement/state may carry explanatory MD assertions\\nactor: <server or monitor actor>\\ntask instance: <transaction/task kind selected from a queued message>\\nentry message: src -> dst proto.type fields...\\nFSM states: unauthorized/authenticated/running/terminal...\\nmessages: ordered visible envelopes with concrete src,dst,task,proto fields,ts,dwell\\nproperties: optional CTL over visible fields only\\nreducers: filter/group over ordered replay for line or pie charts';}" ++
  "function wantsScenario(p){return /add|build|model|scenario|requirement|task|transaction|upload|download|delete|search|checkout|purchase|review|login/.test(p);}" ++
  "function chooseScenario(prompt,catalog){const p=prompt.toLowerCase();let hit=catalog.find(s=>p.includes(s.id)||p.includes(s.task));if(!hit&&/upload|put /.test(p))hit=catalog.find(s=>s.id==='upload_file');if(!hit&&/download|get \\/files/.test(p))hit=catalog.find(s=>s.id==='download_file');if(!hit&&/review/.test(p))hit=catalog.find(s=>s.id==='post_review');if(!hit&&/doc|get /.test(p))hit=catalog.find(s=>s.id==='get_docs');if(hit)return JSON.parse(JSON.stringify(hit));const m=prompt.match(/(?:task|scenario|transaction)\\s+([a-zA-Z0-9_/-]+)/);const name=(m?m[1]:'new_task').replace(/[^a-zA-Z0-9_]/g,'_').toLowerCase();return {id:name,task:name,actors:['Client','Gateway','Worker'],entry:'Client request for '+name,messages:['Client -> Gateway '+name+'.Request fields={request_id,payload}','Gateway -> Worker '+name+'.Command fields={request_id,payload}','Worker -> Gateway '+name+'.Result fields={status,request_id}','Gateway -> Client '+name+'.Response fields={status,request_id}'],properties:['AG no success without auth proof','AF terminal','AG terminal cleanup'],reducers:['latency by task','messages by actor','success/failure pie']};}" ++
  "function previewScenario(s){tool('scenario_preview_messages',{task:s.task,actors:s.actors});return 'Draft scenario: '+s.task+'\\nentry: '+s.entry+'\\nactors: '+s.actors.join(', ')+'\\nmessages:\\n  '+s.messages.join('\\n  ')+'\\nproperties:\\n  '+s.properties.join('\\n  ')+'\\ncharts/reducers:\\n  '+s.reducers.join('\\n  ');}" ++
  "function wantsProtocolSketch(p){return /kerberos|oauth|openid|tls|protocol sketch|sketch.*protocol|ticket granting|single sign/.test(p);}" ++
  "function chooseProtocolSketch(prompt,catalog){const p=prompt.toLowerCase();let hit=catalog.find(s=>p.includes(s.id)||p.includes(s.label.toLowerCase().split(' ')[0]));return hit||catalog[0];}" ++
  "function previewProtocolSketch(s){tool('protocol_sketch_preview',{id:s.id,actors:s.actors});return 'Protocol sketch: '+s.label+'\\nactors: '+s.actors.join(', ')+'\\nmessages:\\n  '+s.messages.join('\\n  ')+'\\nterminal states:\\n  '+s.terminal.join('\\n  ')+'\\nproperties:\\n  '+s.properties.join('\\n  ')+'\\nnotes:\\n  '+s.notes.join('\\n  ')+'\\nLean sketch: '+location.origin+'/lean/sketch/'+s.id+'.lean';}" ++
  "async function generateProtocolSketch(prompt){const catalog=await callProtocolSketchCatalog();tool('protocol_sketch_generate',{prompt:prompt,crypto:'placeholder visible proof fields'});const draft=chooseProtocolSketch(prompt,catalog);tool('protocol_sketch_validate',{observableOnly:true,id:draft.id});setSubject({id:draft.id,label:draft.label,task:draft.id,actors:draft.actors,messages:draft.messages,properties:draft.properties,reducers:['latency by phase','messages by actor','success/failure pie']});return previewProtocolSketch(draft)+'\\n\\nSay \"wire it in\" when the sketch has the right visible messages and proof fields.';}" ++
  "function wireDraft(){if(!currentDraft)return 'No current draft. Describe a task or transaction first.';tool('scenario_stage_integration',{task:currentDraft.task,mode:'message_passing_requirement'});setSubject(Object.assign({},currentDraft,{status:'staged'}));return 'Staged integration for '+currentDraft.task+'\\n1. Add/extend TaskKind and actor task membership.\\n2. Add protobuf envelope constructors with src,dst,task,transport,fields,bytes,ts,dwell.\\n3. Instantiate one per-task FSM over observable actor states, queues, messages, and auth proof fields.\\n4. Add CTL checks over visible message/proof/queue fields only.\\n5. Append reducers for chart data and Prometheus metrics.\\n6. Re-render nested FSM, interaction diagram, charts, docs, and /metrics.';}" ++
  "async function generateScenario(prompt){const catalog=await callScenarioCatalog();tool('scenario_generate',{prompt:prompt});const draft=chooseScenario(prompt,catalog);tool('scenario_validate',{observableOnly:true,task:draft.task});setSubject(draft);return previewScenario(draft)+'\\n\\nSay \"wire it in\" when this is the shape you want, or describe changes.';}" ++
  "async function assistant(prompt){const p=prompt.toLowerCase();let parts=[];if(/wire|accept|agreed|looks good|ship it/.test(p))parts.push(wireDraft());if(wantsProtocolSketch(p)&&!parts.length)parts.push(await generateProtocolSketch(prompt));if(wantsScenario(p)&&!parts.length)parts.push(await generateScenario(prompt));if(p.includes('metric')||p.includes('latency')||p.includes('throughput')||p.includes('ctl'))parts.push(await callMetrics());if(p.includes('graph')||p.includes('diagram')||p.includes('artifact')||p.includes('image'))parts.push(callArtifacts());if(p.includes('chart')||p.includes('pie')||p.includes('line')||p.includes('usl'))parts.push(callCharts());if(p.includes('validate')||p.includes('spec'))parts.push(validateSpec(prompt));if(p.includes('template')||p.includes('how do i write'))parts.push(requirementTemplate());if(parts.length===0){tool('route_intent',{intent:'design_discussion'});parts.push('Ask for a protocol sketch, for example: sketch Kerberos with visible proof fields. I will generate message-passing steps, validate the observable fields, and stage it for integration when we agree.');}return parts.join('\\n\\n');}" ++
  "chatSend.addEventListener('click',async()=>{const p=chatPrompt.value.trim();if(!p)return;bubble('user',p);chatPrompt.value='';const r=await assistant(p);bubble('assistant',r);});chatPrompt.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.ctrlKey)chatSend.click();});" ++
  "bubble('assistant','LeanFM workbench ready. Ask for a sketched protocol, for example: Kerberos with proof fields. I will keep crypto as visible placeholder evidence unless you ask for concrete bytes.');" ++
  "</script>"

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

def aggregateGraphAnimation : String :=
  "<section><h2>Aggregate Graph</h2><div class=\"controlPanel\"><label><input id=\"aggCutEdges\" type=\"checkbox\" checked> edge corridors push boxes out of arrow paths</label></div><div class=\"canvasPanel\"><canvas id=\"aggGraph\" width=\"1000\" height=\"520\"></canvas><div id=\"aggInfo\"></div></div></section>" ++
  "<script>" ++
  "const graphCanvas=document.getElementById('aggGraph');const gctx=graphCanvas.getContext('2d');const aggInfo=document.getElementById('aggInfo');const aggCutBox=document.getElementById('aggCutEdges');aggCutBox.checked=localStorage.getItem('leanfm.agg.cutEdges')!=='false';aggCutBox.addEventListener('change',()=>localStorage.setItem('leanfm.agg.cutEdges',aggCutBox.checked?'true':'false'));" ++
  "const gNodes=[" ++
  "{id:'unauthorized',group:'unauthenticated',sub:'entry',task:'none',auth:'no auth',terminal:false,q:0,label:'unauthorized'}," ++
  "{id:'idle',group:'authenticated session',sub:'ready',task:'none',auth:'auth ok',terminal:false,q:0,label:'ready for task'}," ++
  "{id:'gd_submit',group:'get_docs task',sub:'request accepted',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'GET queued at Gateway'}," ++
  "{id:'gd_worker',group:'get_docs task',sub:'worker running',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'fetch queued at Worker'}," ++
  "{id:'gd_ok',group:'get_docs task',sub:'gateway decides',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'200 queued at Gateway'}," ++
  "{id:'gd_fail',group:'get_docs task',sub:'gateway decides',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'404 queued at Gateway'}," ++
  "{id:'gd_reply',group:'get_docs task',sub:'client response',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'200 queued at Client'}," ++
  "{id:'gd_reject',group:'get_docs task',sub:'client response',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'401 queued at Client'}," ++
  "{id:'gd_done',group:'get_docs task',sub:'terminal',task:'get_docs',auth:'auth ok',terminal:true,q:0,label:'get_docs done'}," ++
  "{id:'gd_failed',group:'get_docs task',sub:'terminal',task:'get_docs',auth:'auth ok',terminal:true,q:0,label:'get_docs failed'}," ++
  "{id:'rv_submit',group:'post_review task',sub:'request accepted',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'review queued at Gateway'}," ++
  "{id:'rv_worker',group:'post_review task',sub:'worker running',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'moderate queued at Worker'}," ++
  "{id:'rv_ok',group:'post_review task',sub:'gateway decides',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'201 queued at Gateway'}," ++
  "{id:'rv_fail',group:'post_review task',sub:'gateway decides',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'reject queued at Gateway'}," ++
  "{id:'rv_reply',group:'post_review task',sub:'client response',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'201 queued at Client'}," ++
  "{id:'rv_reject',group:'post_review task',sub:'client response',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'400 queued at Client'}," ++
  "{id:'rv_done',group:'post_review task',sub:'terminal',task:'post_review',auth:'auth ok',terminal:true,q:0,label:'post_review done'}," ++
  "{id:'rv_failed',group:'post_review task',sub:'terminal',task:'post_review',auth:'auth ok',terminal:true,q:0,label:'post_review failed'}" ++
  "];" ++
  "const gEdges=[['unauthorized','idle','Auth.LookupResponse ok'],['idle','gd_submit','Docs.GetRequest'],['idle','rv_submit','Reviews.PostRequest'],['gd_submit','gd_worker','Docs.FetchCommand'],['gd_submit','gd_reject','Error.Response'],['gd_worker','gd_ok','Docs.FetchResult 200'],['gd_worker','gd_fail','Docs.FetchResult 404'],['gd_ok','gd_reply','Docs.GetResponse'],['gd_fail','gd_reject','Error.Response'],['gd_reply','gd_done','Docs.GetResponse'],['gd_reject','gd_failed','Error.Response'],['rv_submit','rv_worker','Reviews.ModerateCommand'],['rv_submit','rv_reject','Reviews.PostResponse 400'],['rv_worker','rv_ok','Reviews.ModerationResult accepted'],['rv_worker','rv_fail','Reviews.ModerationResult rejected'],['rv_ok','rv_reply','Reviews.PostResponse 201'],['rv_fail','rv_reject','Reviews.PostResponse 400'],['rv_reply','rv_done','Reviews.PostResponse 201'],['rv_reject','rv_failed','Reviews.PostResponse 400']];" ++
  "let openGroups=new Set();let simGroups=[];let simById=new Map();let groupEdges=[];let rankByGroup=new Map();let rankByNode=new Map();let hit=[];let childById=new Map();let drag=null;let dragMoved=false;" ++
  "function bucket(n){return n.group;}" ++
  "function groups(){const m=new Map();for(const n of gNodes){const b=bucket(n);if(!m.has(b))m.set(b,[]);m.get(b).push(n);}return [...m.entries()].map(([key,nodes])=>({key,nodes}));}" ++
  "function subKey(g,n){return g.key+'|'+n.sub;}" ++
  "function subGroups(g){const m=new Map();for(const n of g.nodes){const k=n.sub;if(!m.has(k))m.set(k,[]);m.get(k).push(n);}return [...m.entries()].map(([key,nodes])=>({key,id:g.key+'|'+key,nodes}));}" ++
  "function localRadius(n){return n<=1?0:Math.max(150,Math.ceil(Math.sqrt(n))*135);}" ++
  "function isPlainTop(g){return g.key==='unauthenticated'||g.key==='authenticated session';}" ++
  "function groupSize(g){if(isPlainTop(g))return{w:260,h:58};if(!openGroups.has(g.key))return{w:210,h:88};const r=localRadius(g.nodes.length);return{w:Math.max(620,2*r+460),h:Math.max(440,2*r+260)};}" ++
  "function edgeRanks(ids,edges){const set=new Set(ids);const rank=new Map(ids.map(id=>[id,0]));for(let pass=0;pass<ids.length*3+3;pass++){let changed=false;for(const e of edges){if(!set.has(e[0])||!set.has(e[1])||e[0]===e[1])continue;const a=rank.get(e[0])||0,b=rank.get(e[1])||0;if(b<a+1){rank.set(e[1],a+1);changed=true;}}if(!changed)break;}return rank;}" ++
  "function seed(id,i,total){const old=simById.get(id);if(old)return{x:old.x,y:old.y,vx:old.vx||0,vy:old.vy||0,pinned:!!old.pinned,pinX:old.pinX||old.x,pinY:old.pinY||old.y};const key=id.startsWith('group:')?id.slice(6):id;const r=rankByGroup.get(key)||0;const same=simGroups.filter(g=>(rankByGroup.get(g.key)||0)===r).length;const x=graphCanvas.width/2+(same-(total-1)/2)*260;const y=120+r*230;return{x,y,vx:0,vy:0,pinned:false};}" ++
  "function resizeGraphCanvas(){let area=0,maxW=0,maxH=0;for(const g of simGroups){const s=groupSize(g);area+=s.w*s.h;maxW=Math.max(maxW,s.w);maxH=Math.max(maxH,s.h);}const side=Math.ceil(Math.sqrt(area))*2+520;const w=Math.max(1100,maxW+620,side);const h=Math.max(760,maxH+420,side);if(graphCanvas.width!==w||graphCanvas.height!==h){const ox=graphCanvas.width/2,oy=graphCanvas.height/2;graphCanvas.width=w;graphCanvas.height=h;for(const g of simGroups){g.x+=w/2-ox;g.y+=h/2-oy;}}}" ++
  "function clampGroup(n){const sz=groupSize(n);n.x=Math.max(sz.w/2+24,Math.min(graphCanvas.width-sz.w/2-24,n.x));n.y=Math.max(sz.h/2+24,Math.min(graphCanvas.height-sz.h/2-24,n.y));}" ++
  "function resolveOverlaps(){for(let pass=0;pass<24;pass++){for(let i=0;i<simGroups.length;i++){for(let j=i+1;j<simGroups.length;j++){const a=simGroups[i],b=simGroups[j],as=groupSize(a),bs=groupSize(b);let dx=b.x-a.x,dy=b.y-a.y;if(Math.abs(dx)<0.1&&Math.abs(dy)<0.1){dx=(j-i)*9;dy=7;}const ox=(as.w+bs.w)/2+72-Math.abs(dx),oy=(as.h+bs.h)/2+72-Math.abs(dy);if(ox>0&&oy>0){if(ox<oy){const m=ox/2+6,sgn=Math.sign(dx||1);if(!a.pinned)a.x-=m*sgn;if(!b.pinned)b.x+=m*sgn;a.vx*=0.2;b.vx*=0.2;}else{const m=oy/2+6,sgn=Math.sign(dy||1);if(!a.pinned)a.y-=m*sgn;if(!b.pinned)b.y+=m*sgn;a.vy*=0.2;b.vy*=0.2;}clampGroup(a);clampGroup(b);}}}}}" ++
  "function rebuildGraph(){const gs=groups();const seen=new Set();groupEdges=[];for(const e of gEdges){const a=bucket(gNodes.find(n=>n.id===e[0])),b=bucket(gNodes.find(n=>n.id===e[1]));if(a===b)continue;const k=a+'>'+b;if(seen.has(k))continue;seen.add(k);groupEdges.push(['group:'+a,'group:'+b]);}rankByGroup=edgeRanks(gs.map(g=>g.key),groupEdges.map(e=>[e[0].slice(6),e[1].slice(6)]));simGroups=gs.map((g,i)=>Object.assign({id:'group:'+g.key,key:g.key,label:g.key,nodes:g.nodes,count:g.nodes.length},seed('group:'+g.key,i,gs.length)));simById=new Map(simGroups.map(g=>[g.id,g]));resizeGraphCanvas();for(let i=0;i<24;i++)resolveOverlaps();aggInfo.innerHTML='<p>Fixed hierarchy: edges prefer top-to-bottom layout; each discrete task is a compound node with task super-states and terminal states.</p><ul>'+gs.map(g=>'<li>'+g.key+': '+g.nodes.length+' states</li>').join('')+'</ul>';}" ++
  "function groupFlowWeights(){const ids=simGroups.map(g=>g.id),out=new Map(ids.map(id=>[id,0]));let w=new Map(ids.map(id=>[id,1]));for(const e of groupEdges)out.set(e[0],(out.get(e[0])||0)+1);for(let k=0;k<16;k++){const next=new Map(ids.map(id=>[id,.18]));for(const e of groupEdges){const share=(w.get(e[0])||1)/Math.max(1,out.get(e[0])||1);next.set(e[1],(next.get(e[1])||.18)+.82*share);}w=next;}return w;}" ++
  "function groupEdgeCorridors(){if(!aggCutBox.checked)return;for(const e of groupEdges){const a=simById.get(e[0]),b=simById.get(e[1]);if(!a||!b)continue;const ax=a.x,ay=a.y,bx=b.x,by=b.y,ex=bx-ax,ey=by-ay,len2=Math.max(1,ex*ex+ey*ey);for(const n of simGroups){if(n.id===a.id||n.id===b.id||n.pinned)continue;const s=groupSize(n),t=Math.max(0,Math.min(1,((n.x-ax)*ex+(n.y-ay)*ey)/len2)),px=ax+ex*t,py=ay+ey*t,dx=n.x-px,dy=n.y-py,d=Math.max(1,Math.sqrt(dx*dx+dy*dy)),corridor=Math.max(s.w,s.h)/2+96;if(d<corridor){const f=(corridor-d)*0.024;n.vx+=dx/d*f;n.vy+=dy/d*f;}}}}" ++
  "function stepForce(){const cx=graphCanvas.width/2,weight=groupFlowWeights();for(const n of simGroups){const r=rankByGroup.get(n.key)||0,w=weight.get(n.id)||1;n.vx+=(cx-n.x)*0.00040;n.vy+=((120+r*250+w*82)-n.y)*(0.0016+Math.min(w,4)*0.00042);}for(const e of groupEdges){const a=simById.get(e[0]),b=simById.get(e[1]);if(!a||!b)continue;const bw=weight.get(b.id)||1,as=groupSize(a),bs=groupSize(b);const dx=b.x-a.x,dy=b.y-a.y,d=Math.max(1,Math.sqrt(dx*dx+dy*dy));const targetY=(as.h+bs.h)/2+160+bw*58;const targetX=Math.max((as.w+bs.w)/2+150,240);const fx=(Math.abs(dx)-targetX)*0.0018*Math.sign(dx||1);if(!a.pinned)a.vx+=fx;if(!b.pinned)b.vx-=fx;const fy=(dy-targetY)*(0.010+Math.min(bw,4)*0.0022);if(!a.pinned)a.vy+=fy;if(!b.pinned)b.vy-=fy;if(b.y<a.y+targetY){const push=(a.y+targetY-b.y)*(0.028+Math.min(bw,4)*0.006);if(!a.pinned)a.vy-=push;if(!b.pinned)b.vy+=push;}}groupEdgeCorridors();for(let i=0;i<simGroups.length;i++){for(let j=i+1;j<simGroups.length;j++){const a=simGroups[i],b=simGroups[j],as=groupSize(a),bs=groupSize(b);let dx=b.x-a.x,dy=b.y-a.y;if(Math.abs(dx)<1&&Math.abs(dy)<1){dx=5;dy=4;}const d2=Math.max(1,dx*dx+dy*dy),d=Math.sqrt(d2);const near=Math.max((as.w+bs.w)/2+220,(as.h+bs.h)/2+180);const f=(near*near*0.22)/d2;const fx=f*dx/d,fy=f*dy/d;a.vx-=fx;a.vy-=fy;b.vx+=fx;b.vy+=fy;}}for(const n of simGroups){if(n.pinned){n.x=n.pinX;n.y=n.pinY;n.vx=0;n.vy=0;clampGroup(n);continue;}n.vx*=0.56;n.vy*=0.56;n.x+=n.vx;n.y+=n.vy;clampGroup(n);}resolveOverlaps();}" ++
  "function groupRect(g){const s=groupSize(g);return{x:g.x-s.w/2,y:g.y-s.h/2,w:s.w,h:s.h};}" ++
  "function innerPortToward(g,other){const r=groupRect(g);let dx=other.x-g.x,dy=other.y-g.y;if(Math.abs(dx)<1&&Math.abs(dy)<1){dx=1;dy=0;}const sx=(r.w/2-150)/Math.max(1,Math.abs(dx)),sy=(r.h/2-92)/Math.max(1,Math.abs(dy));const s=Math.min(sx,sy);return{x:g.x+dx*s,y:g.y+dy*s};}" ++
  "function boundaryPeer(id){const n=gNodes.find(x=>x.id===id);if(!n)return null;const g=simById.get('group:'+bucket(n));return g?{x:g.x,y:g.y}:null;}" ++
  "function childTarget(g,node){const nodes=g.nodes;rankByNode=edgeRanks(nodes.map(n=>n.id),gEdges.filter(e=>{const a=gNodes.find(n=>n.id===e[0]),b=gNodes.find(n=>n.id===e[1]);return a&&b&&bucket(a)===g.key&&bucket(b)===g.key;}));const r=rankByNode.get(node.id)||0;const row=nodes.filter(n=>(rankByNode.get(n.id)||0)===r);const idx=row.findIndex(n=>n.id===node.id);return{x:g.x+(idx-(row.length-1)/2)*310,y:g.y-120+r*105};}" ++
  "function childState(g,node){const id=g.key+'|'+node.id;let c=childById.get(id);const t=childTarget(g,node);if(!c){c={id,nodeId:node.id,groupKey:g.key,x:t.x,y:t.y,vx:0,vy:0,pinned:false,pinX:t.x,pinY:t.y};childById.set(id,c);}return c;}" ++
  "function clampChild(c,r){const w=260,h=42;c.x=Math.max(r.x+w/2+18,Math.min(r.x+r.w-w/2-18,c.x));c.y=Math.max(r.y+h/2+72,Math.min(r.y+r.h-h/2-18,c.y));}" ++
  "function layoutChildren(g){if(!openGroups.has(g.key)||isPlainTop(g))return;const r=groupRect(g);const cs=g.nodes.map(n=>childState(g,n));const byNode=new Map(g.nodes.map((n,i)=>[n.id,cs[i]]));for(let pass=0;pass<28;pass++){for(let i=0;i<g.nodes.length;i++){const c=cs[i];if(c.pinned)continue;const t=childTarget(g,g.nodes[i]);c.vx+=(t.x-c.x)*0.008;c.vy+=(t.y-c.y)*0.010;c.vx+=(g.x-c.x)*0.0008;}for(const e of gEdges){const a=byNode.get(e[0]),b=byNode.get(e[1]);if(a&&b){const dx=b.x-a.x,dy=b.y-a.y,d=Math.max(1,Math.sqrt(dx*dx+dy*dy));const target=250,force=(d-target)*0.010;const fx=force*dx/d,fy=force*dy/d;if(!a.pinned){a.vx+=fx;a.vy+=fy;}if(!b.pinned){b.vx-=fx;b.vy-=fy;}const want=110;if(!a.pinned)a.vy+=(dy-want)*0.008;if(!b.pinned)b.vy-=(dy-want)*0.008;}else if(a&&!a.pinned){const dn=gNodes.find(n=>n.id===e[1]);if(dn&&bucket(dn)!==g.key){const peer=boundaryPeer(e[1]);if(peer){const p=innerPortToward(g,peer);a.vx+=(p.x-a.x)*0.018;a.vy+=(p.y-a.y)*0.018;}}}else if(b&&!b.pinned){const sn=gNodes.find(n=>n.id===e[0]);if(sn&&bucket(sn)!==g.key){const peer=boundaryPeer(e[0]);if(peer){const p=innerPortToward(g,peer);b.vx+=(p.x-b.x)*0.010;b.vy+=(p.y-b.y)*0.010;}}}}for(let sep=0;sep<3;sep++){for(let i=0;i<cs.length;i++){for(let j=i+1;j<cs.length;j++){const a=cs[i],b=cs[j];let dx=b.x-a.x,dy=b.y-a.y;if(Math.abs(dx)<.1&&Math.abs(dy)<.1){dx=4;dy=3;}const d2=Math.max(1,dx*dx+dy*dy),d=Math.sqrt(d2);const rep=26000/d2;if(!a.pinned){a.vx-=rep*dx/d;a.vy-=rep*dy/d;}if(!b.pinned){b.vx+=rep*dx/d;b.vy+=rep*dy/d;}const ox=326-Math.abs(dx),oy=86-Math.abs(dy);if(ox>0&&oy>0){if(ox<oy){const m=ox/2+6,sgn=Math.sign(dx||1);if(!a.pinned)a.x-=m*sgn;if(!b.pinned)b.x+=m*sgn;}else{const m=oy/2+6,sgn=Math.sign(dy||1);if(!a.pinned)a.y-=m*sgn;if(!b.pinned)b.y+=m*sgn;}}}}}for(const c of cs){if(c.pinned){c.x=c.pinX;c.y=c.pinY;c.vx=0;c.vy=0;clampChild(c,r);c.pinX=c.x;c.pinY=c.y;continue;}c.vx*=0.58;c.vy*=0.58;c.x+=c.vx;c.y+=c.vy;clampChild(c,r);}}}" ++
  "function childPos(g,node){const c=childState(g,node);return{x:c.x,y:c.y};}" ++
  "function drawChild(g,n){const p=childPos(g,n);const w=260,h=42;const x=p.x-w/2,y=p.y-h/2;gctx.fillStyle='#0b0b0b';gctx.strokeStyle='#93c5fd';gctx.lineWidth=1.5;gctx.fillRect(x,y,w,h);gctx.strokeRect(x,y,w,h);gctx.fillStyle='#fff';gctx.font='11px sans-serif';gctx.textAlign='center';gctx.fillText(n.id,p.x,p.y-5);gctx.fillText(n.label,p.x,p.y+10);hit.push({key:'state:'+n.id,kind:'state',stateId:n.id,groupKey:g.key,x,y,w,h});}" ++
  "function edgePoint(g,t){const sz=groupSize(g);const dx=t.x-g.x,dy=t.y-g.y;const sx=(sz.w/2+16)/Math.max(1,Math.abs(dx)),sy=(sz.h/2+16)/Math.max(1,Math.abs(dy));const s=Math.min(sx,sy);return{x:g.x+dx*s,y:g.y+dy*s};}" ++
  "function drawArrow(ctx,x1,y1,x2,y2,color,width){ctx.strokeStyle=color;ctx.fillStyle=color;ctx.lineWidth=width;ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.stroke();const a=Math.atan2(y2-y1,x2-x1);ctx.beginPath();ctx.moveTo(x2,y2);ctx.lineTo(x2-12*Math.cos(a-.45),y2-12*Math.sin(a-.45));ctx.lineTo(x2-12*Math.cos(a+.45),y2-12*Math.sin(a+.45));ctx.closePath();ctx.fill();}" ++
  "function rectPort(from,to,w,h,pad){const dx=to.x-from.x,dy=to.y-from.y;const sx=(w/2+pad)/Math.max(1,Math.abs(dx)),sy=(h/2+pad)/Math.max(1,Math.abs(dy));const s=Math.min(sx,sy);return{x:from.x+dx*s,y:from.y+dy*s};}" ++
  "function edgeLabel(e){return e[2]||((e[0]||'?')+' -> '+(e[1]||'?'));}" ++
  "function labelBox(ctx,x,y,text,color){const t=text.length>44?text.slice(0,41)+'...':text;ctx.fillStyle=color;ctx.font='11px sans-serif';ctx.textAlign='center';ctx.fillText(t,x,y-6);}" ++
  "function visibleInnerPos(g,id){const n=g.nodes.find(x=>x.id===id);return n?childPos(g,n):null;}" ++
  "function drawSubBuckets(g){}" ++
  "function drawInternalEdges(g){if(!openGroups.has(g.key))return;for(const e of gEdges){const sn=gNodes.find(n=>n.id===e[0]),dn=gNodes.find(n=>n.id===e[1]);if(!sn||!dn||bucket(sn)!==g.key||bucket(dn)!==g.key)continue;const a=visibleInnerPos(g,e[0]),b=visibleInnerPos(g,e[1]);if(!a||!b)continue;const pa=rectPort(a,b,260,42,8),pb=rectPort(b,a,260,42,8);drawArrow(gctx,pa.x,pa.y,pb.x,pb.y,'#315f92',1.2);labelBox(gctx,(pa.x+pb.x)/2,(pa.y+pb.y)/2,edgeLabel(e),'#315f92');}}" ++
  "function visibleEndpoint(id){const n=gNodes.find(x=>x.id===id);if(!n)return null;const g=simById.get('group:'+bucket(n));if(!g)return null;if(!openGroups.has(g.key)){return{key:'group:'+g.key,kind:'group',x:g.x,y:g.y,w:groupSize(g).w,h:groupSize(g).h};}const p=childPos(g,n);return{key:'state:'+id,kind:'state',x:p.x,y:p.y,w:260,h:42};}" ++
  "function visibleNodes(){const out=[];for(const g of simGroups){if(!openGroups.has(g.key)){out.push({key:'group:'+g.key,kind:'group',x:g.x,y:g.y,w:groupSize(g).w,h:groupSize(g).h});continue;}for(const n of g.nodes)out.push(visibleEndpoint(n.id));}return out.filter(Boolean);}" ++
  "function visibleEdgeEndpoints(e){const a=visibleEndpoint(e[0]),b=visibleEndpoint(e[1]);if(!a||!b||a.key===b.key)return null;return{a,b};}" ++
  "function hasVisibleIncoming(v){for(const e of gEdges){const p=visibleEdgeEndpoints(e);if(p&&p.b.key===v.key)return true;}return false;}" ++
  "function hasVisibleOutgoing(v){for(const e of gEdges){const p=visibleEdgeEndpoints(e);if(p&&p.a.key===v.key)return true;}return false;}" ++
  "function drawBoundaryMarkers(){for(const v of visibleNodes()){if(!hasVisibleIncoming(v)){const from={x:v.x-v.w/2-42,y:v.y},to={x:v.x-v.w/2-6,y:v.y};drawArrow(gctx,from.x,from.y,to.x,to.y,'#22c55e',2);gctx.fillStyle='#22c55e';gctx.font='11px sans-serif';gctx.textAlign='right';gctx.fillText('start',from.x-4,from.y-6);}if(!hasVisibleOutgoing(v)){gctx.strokeStyle='#ef4444';gctx.lineWidth=2;gctx.strokeRect(v.x-v.w/2-5,v.y-v.h/2-5,v.w+10,v.h+10);gctx.fillStyle='#ef4444';gctx.font='11px sans-serif';gctx.textAlign='left';gctx.fillText('terminal',v.x+v.w/2+8,v.y+4);}}}" ++
  "function drawVisibleEdges(){const projected=new Map();for(const e of gEdges){const sn=gNodes.find(n=>n.id===e[0]),dn=gNodes.find(n=>n.id===e[1]);if(!sn||!dn||bucket(sn)===bucket(dn))continue;const a=visibleEndpoint(e[0]),b=visibleEndpoint(e[1]);if(!a||!b||a.key===b.key)continue;const k=a.key+'>'+b.key;if(!projected.has(k))projected.set(k,{a,b,labels:[]});const p=projected.get(k);const label=edgeLabel(e);if(!p.labels.includes(label))p.labels.push(label);}for(const p of projected.values()){const pa=rectPort(p.a,p.b,p.a.w,p.a.h,12),pb=rectPort(p.b,p.a,p.b.w,p.b.h,12);const color=(p.a.kind==='state'||p.b.kind==='state')?'#f59e0b':'#777';drawArrow(gctx,pa.x,pa.y,pb.x,pb.y,color,1.8);labelBox(gctx,(pa.x+pb.x)/2,(pa.y+pb.y)/2,p.labels.join(' / '),color);}}" ++
  "function drawAgg(){stepForce();gctx.fillStyle='#111';gctx.fillRect(0,0,graphCanvas.width,graphCanvas.height);hit=[];for(const g of simGroups){const sz=groupSize(g);const x=g.x-sz.w/2,y=g.y-sz.h/2;gctx.fillStyle=openGroups.has(g.key)&&!isPlainTop(g)?'#111827':'#000';gctx.strokeStyle='#fff';gctx.lineWidth=2;gctx.fillRect(x,y,sz.w,sz.h);}for(const g of simGroups){layoutChildren(g);drawSubBuckets(g);}for(const g of simGroups){const plain=isPlainTop(g);const sz=groupSize(g);const x=g.x-sz.w/2,y=g.y-sz.h/2;gctx.strokeStyle='#fff';gctx.lineWidth=2;gctx.strokeRect(x,y,sz.w,sz.h);gctx.fillStyle='#fff';gctx.font=plain?'14px sans-serif':'16px sans-serif';gctx.textAlign='center';gctx.fillText(g.label,g.x,plain?g.y+5:y+25);if(!plain){gctx.font='13px sans-serif';gctx.fillText(g.count+' states '+(openGroups.has(g.key)?'open':'closed'),g.x,y+47);}hit.push({key:g.key,kind:plain?'plain':'group',x,y,w:sz.w,h:sz.h});if(openGroups.has(g.key)&&!plain){for(const n of g.nodes)drawChild(g,n);}}for(const g of simGroups)drawInternalEdges(g);drawVisibleEdges();drawBoundaryMarkers();requestAnimationFrame(drawAgg);}function canvasPoint(ev){const r=graphCanvas.getBoundingClientRect();return{x:(ev.clientX-r.left)*graphCanvas.width/r.width,y:(ev.clientY-r.top)*graphCanvas.height/r.height};}function hitAt(x,y){return hit.filter(h=>x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h).sort((a,b)=>(a.w*a.h)-(b.w*b.h))[0]||null;}graphCanvas.addEventListener('pointerdown',ev=>{const p=canvasPoint(ev),h=hitAt(p.x,p.y);if(!h)return;if(h.kind==='state'){const c=childById.get(h.groupKey+'|'+h.stateId);if(!c)return;c.pinned=true;c.pinX=c.x;c.pinY=c.y;drag={kind:'state',state:c,offX:p.x-c.x,offY:p.y-c.y};graphCanvas.setPointerCapture(ev.pointerId);graphCanvas.style.cursor='grabbing';}else if(h.kind==='group'||h.kind==='plain'){const g=simById.get('group:'+h.key);if(!g)return;g.pinned=true;g.pinX=g.x;g.pinY=g.y;drag={kind:'group',group:g,offX:p.x-g.x,offY:p.y-g.y};graphCanvas.setPointerCapture(ev.pointerId);graphCanvas.style.cursor='grabbing';}});graphCanvas.addEventListener('pointermove',ev=>{if(!drag)return;const p=canvasPoint(ev);dragMoved=true;if(drag.kind==='state'){const c=drag.state;c.pinX=p.x-drag.offX;c.pinY=p.y-drag.offY;c.x=c.pinX;c.y=c.pinY;c.vx=0;c.vy=0;}else{const g=drag.group;g.pinX=p.x-drag.offX;g.pinY=p.y-drag.offY;g.x=g.pinX;g.y=g.pinY;g.vx=0;g.vy=0;}});graphCanvas.addEventListener('pointerup',ev=>{if(drag){try{graphCanvas.releasePointerCapture(ev.pointerId);}catch(e){}drag=null;graphCanvas.style.cursor='grab';}});graphCanvas.addEventListener('pointercancel',ev=>{drag=null;graphCanvas.style.cursor='grab';});graphCanvas.addEventListener('click',ev=>{if(dragMoved){dragMoved=false;return;}const p=canvasPoint(ev),h=hitAt(p.x,p.y);if(!h||h.kind!=='group')return;openGroups.has(h.key)?openGroups.delete(h.key):openGroups.add(h.key);rebuildGraph();});rebuildGraph();drawAgg();" ++
  "</script>"

def pageCss : String :=
  "<meta name=\"color-scheme\" content=\"dark only\">" ++
  "<style>html,body{background:#111;color:#f8f8f8;color-scheme:dark only;forced-color-adjust:none}body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4}a{color:#93c5fd}pre{background:#050505;color:#f8f8f8;border:1px solid #333;padding:1rem;overflow:auto}code{font-family:ui-monospace,monospace}details{border:1px solid #444;margin:.75rem 0 1rem;background:#090909}summary{cursor:pointer;padding:.75rem 1rem;font-weight:700}.diagram{background:#111;border-top:1px solid #333;margin:0;padding:1rem;overflow:auto;min-height:220px;forced-color-adjust:none}.diagramGrid canvas{display:block;width:100%;max-width:900px;height:auto;background:#111;border-top:1px solid #333}.controlPanel{margin:.5rem 0 1rem}.controlPanel select{background:#000;color:#fff;border:1px solid #666;padding:.35rem}.subjectPanel{display:grid;grid-template-columns:minmax(420px,1fr) 340px;gap:1rem;align-items:start}.subjectPanel canvas{width:100%;height:auto;background:#111;border:1px solid #555}.artifactPanel details{margin:.5rem 0}.artifactPanel pre{max-height:220px}.chatShell{display:grid;grid-template-columns:minmax(320px,2fr) minmax(260px,1fr);gap:1rem;border:1px solid #444;background:#090909;padding:1rem;margin-bottom:1rem}.chatLog{height:340px;overflow:auto;background:#050505;border:1px solid #333;padding:1rem}.bubble{max-width:76%;padding:.7rem .85rem;margin:.55rem 0;border:1px solid #444;white-space:normal}.bubble.user{margin-left:auto;background:#10233f}.bubble.assistant{background:#111827}.chatInput{grid-column:1 / 2;display:grid;grid-template-columns:1fr auto;gap:.5rem}.chatInput textarea{background:#000;color:#fff;border:1px solid #666;padding:.65rem;font:14px ui-monospace,monospace;resize:vertical}.chatInput button{background:#1d4ed8;color:#fff;border:1px solid #93c5fd;padding:0 1rem;font-weight:700}.toolLog{grid-column:2;grid-row:1 / 3;height:420px;overflow:auto;background:#050505;border:1px solid #333;padding:.75rem;font:12px ui-monospace,monospace}.toolCall{border-bottom:1px solid #222;padding:.4rem 0;color:#93c5fd}.canvasPanel{display:grid;grid-template-columns:minmax(320px,900px) minmax(260px,1fr);gap:1rem;align-items:start;overflow:auto}.canvasPanel canvas{width:100%;height:auto;background:#111;border:1px solid #555;cursor:grab}.canvasPanel #aggGraph{width:auto;max-width:none}.canvasPanel ol,.canvasPanel ul{margin:0;padding-left:1.5rem;font-family:ui-monospace,monospace}.canvasPanel li{padding:.2rem .35rem}.canvasPanel li.active{background:#1d4ed8;color:#fff}.chartControls{display:grid;grid-template-columns:auto minmax(220px,1fr) auto minmax(220px,1fr);gap:.5rem;align-items:center;margin:.5rem 0 1rem}.chartControls select{background:#000;color:#fff;border:1px solid #666;padding:.4rem}.chartGrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1rem;margin-bottom:1rem}.chartGrid canvas{width:100%;height:auto;background:#111;border:1px solid #555}@media(max-width:900px){.subjectPanel,.chatShell,.canvasPanel{grid-template-columns:1fr}.toolLog{grid-column:auto;grid-row:auto}.chatInput{grid-column:auto}}</style>"

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
