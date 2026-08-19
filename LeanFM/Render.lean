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

def stateName (s : Observation) : String :=
  s!"Client={actorStateName s.client} q={s.clientQ}/{cap Actor.client}; Gateway={actorStateName s.gateway} q={s.gatewayQ}/{cap Actor.gateway}; Worker={actorStateName s.worker} q={s.workerQ}/{cap Actor.worker}"

def authStateName (s : AuthObservation) : String :=
  s!"Auth={actorStateName s.auth} q={s.authQ}/{authCap Actor.auth}; DB={actorStateName s.db} q={s.dbQ}/{authCap Actor.db}"

def envelopeName (e : Envelope) : String :=
  s!"{actorName e.src}->{actorName e.dst}:{bytesName e.bytes}"

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

def transitionLine (t : Observation × Turn × Observation) : String :=
  s!"{stateName t.1} -- {turnName t.2.1} --> {stateName t.2.2}"

def authTransitionLine (t : AuthObservation × Turn × AuthObservation) : String :=
  s!"{authStateName t.1} -- {turnName t.2.1} --> {authStateName t.2.2}"

def dotLine (t : Observation × Turn × Observation) : String :=
  s!"  \"{stateName t.1}\" -> \"{stateName t.2.2}\" [label=\"{turnName t.2.1}\"];"

def authTransitions : List (AuthObservation × Turn × AuthObservation) :=
  (authStates.map fun s =>
    (authChoices s).flatMap fun c =>
      (Choice.support c).map fun s' => (s, Choice.label c, s')).flatten

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
    (states.map fun s => s!"  \"{stateName s}\";") ++
    (transitions.map dotLine) ++
    ["}"]

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
    , "  AuthGroup [label=\"2 actor auth group\\nP(success)=98/100\\nE(latency)=300/100\"];"
    , "  WorkerGroup [label=\"3 actor worker group\\nP(success)=95/100\\nE(latency)=795/100\"];"
    , "  Assembled [label=\"assembled system\\nP(success)=9310/10000\\nE(latency)=10791000/1000000\\nthroughput=9310000000/107910000000\"];"
    , "  AuthGroup -> WorkerGroup [label=\"on auth success\"];"
    , "  WorkerGroup -> Assembled [label=\"aggregate metrics\"];"
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

def ctlLine (name : String) (formula : CTL Observation) : String :=
  let result := CTL.holds successors initial formula
  s!"{name}: {result}"

def distributionLine (bucket : Nat × Nat) : String :=
  s!"  queue length {bucket.1}: {ratioText bucket.2 expectedLatencyNumerator} ~= {decimalText bucket.2 expectedLatencyNumerator}"

def traceName (trace : List Turn) : String :=
  joinWith ", " (trace.map turnName)

def terminalLine (path : PathStats Observation Turn) : String :=
  s!"  p={path.mass}/{path.scale}, elapsed={path.elapsed}, state={stateName path.state}, trace=[{traceName path.trace}]"

def metricLine (name : String) (num den : Nat) : String :=
  s!"{name}: {ratioText num den} ~= {decimalText num den}"

def metricsLines (label : String) (m : Metrics) : List String :=
  [ metricLine s!"{label} success probability" m.successNum m.successDen
  , metricLine s!"{label} expected latency" m.latencyNum m.latencyDen
  , metricLine s!"{label} throughput" m.throughputNum m.throughputDen
  ]

def textReport : String :=
  joinWith "\n" <|
    ["Two-actor auth group grammar"] ++
    (authGrammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Three-actor worker group grammar"] ++
    (grammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Assembled system grammar"] ++
    (assembledGrammar.map fun e => s!"  {envelopeName e}") ++
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
    metricsLines "worker group" workerMetrics ++
    metricsLines "assembled system" assembledMetrics ++
    ["", "Graphviz DOT", graphDot
    , "", "CTL from initial observation"
    , ctlLine "AF success (all paths eventually succeed)" mustEventuallySucceed
    , ctlLine "AG !fail   (all reachable observations avoid failure)" neverFails
    , ctlLine "EF fail    (some path can fail)" mayFail
    , ctlLine "AG capacity (all reachable queues stay within capacity)" queuesStayWithinCapacity
    ]

def htmlPage : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM</title>" ++
  "<meta name=\"color-scheme\" content=\"dark only\">" ++
  "<style>html,body{background:#111;color:#f8f8f8;color-scheme:dark only;forced-color-adjust:none}body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4}a{color:#93c5fd}pre{background:#050505;color:#f8f8f8;border:1px solid #333;padding:1rem;overflow:auto}code{font-family:ui-monospace,monospace}.diagram{background:#111;border:2px solid #555;margin:.5rem 0 1.5rem;padding:1rem;overflow:auto;min-height:220px;forced-color-adjust:none}.diagram img{display:block;max-width:100%;height:auto;background:#111;forced-color-adjust:none}</style>" ++
  "</head><body><h1>LeanFM</h1><p>Lean-native model of message-passing processes.</p>" ++
  "<p><a href=\"/metrics\">metrics</a> | <a href=\"/auth.dot\">auth.dot</a> | <a href=\"/graph.dot\">worker.dot</a> | <a href=\"/assembled.dot\">assembled.dot</a> | <a href=\"/diagrams/auth.svg?v=3\">auth.svg</a></p>" ++
  "<h2>Auth Group</h2><div class=\"diagram\"><img src=\"/diagrams/auth.png?v=3\" alt=\"Auth group state graph\"></div>" ++
  "<h2>Worker Group</h2><div class=\"diagram\"><img src=\"/diagrams/worker.png?v=3\" alt=\"Worker group state graph\"></div>" ++
  "<h2>Assembled System</h2><div class=\"diagram\"><img src=\"/diagrams/assembled.png?v=3\" alt=\"Assembled system graph\"></div>" ++
  "<pre>" ++ textReport ++ "</pre></body></html>"

end LeanFM
