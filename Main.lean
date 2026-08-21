import LeanFM

open LeanFM

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
  | ActorState.done => "done"
  | ActorState.failed => "failed"

def bytesName (bytes : List Nat) : String :=
  "[" ++ joinWith " " (bytes.map toString) ++ "]"

def stateName (s : Observation) : String :=
  s!"Client={actorStateName s.client}; Gateway={actorStateName s.gateway}; Worker={actorStateName s.worker}"

def envelopeName (e : Envelope) : String :=
  s!"{actorName e.src}->{actorName e.dst}:{bytesName e.bytes}"

def transitionLine (t : Observation × Envelope × Observation) : String :=
  s!"{stateName t.1} -- {envelopeName t.2.1} --> {stateName t.2.2}"

def dotLine (t : Observation × Envelope × Observation) : String :=
  s!"  \"{stateName t.1}\" -> \"{stateName t.2.2}\" [label=\"{envelopeName t.2.1}\"];"

def weightedLine (label : String) (w : Weighted Observation) : String :=
  s!"    {label} [weight={w.weight}, dwell={w.dwell}] -> {stateName w.value}"

def choiceLines (s : Observation) (choice : Choice Observation Envelope) : List String :=
  match choice with
  | Choice.action e dwell s' =>
      [s!"  {stateName s} action {envelopeName e} [dwell={dwell}] -> {stateName s'}"]
  | Choice.chance e outcomes =>
      s!"  {stateName s} chance after {envelopeName e}:" ::
        outcomes.map (weightedLine (envelopeName e))

def ctlLine (name : String) (formula : CTL Observation) : String :=
  let result := CTL.holds successors initial formula
  s!"{name}: {result}"

def distributionLine (bucket : Nat × Nat) : String :=
  s!"  queue length {bucket.1}: {ratioText bucket.2 expectedLatencyNumerator} ~= {decimalText bucket.2 expectedLatencyNumerator}"

def traceName (trace : List Envelope) : String :=
  joinWith ", " (trace.map envelopeName)

def terminalLine (path : PathStats Observation Envelope) : String :=
  s!"  p={path.mass}/{path.scale}, elapsed={path.elapsed}, state={stateName path.state}, trace=[{traceName path.trace}]"

def metricLine (name : String) (num den : Nat) : String :=
  s!"{name}: {ratioText num den} ~= {decimalText num den}"

def metricsLines (label : String) (m : Metrics) : List String :=
  [ metricLine s!"{label} success probability" m.successNum m.successDen
  , metricLine s!"{label} expected latency" m.latencyNum m.latencyDen
  , metricLine s!"{label} throughput" m.throughputNum m.throughputDen
  ]

def main : IO Unit := do
  IO.println "Two-actor auth group grammar"
  for e in authGrammar do
    IO.println s!"  {envelopeName e}"

  IO.println ""
  IO.println "Three-actor worker group grammar"
  for e in grammar do
    IO.println s!"  {envelopeName e}"

  IO.println ""
  IO.println "Assembled system grammar"
  for e in assembledGrammar do
    IO.println s!"  {envelopeName e}"

  IO.println ""
  IO.println "Observable actor-state transitions"
  for t in transitions do
    IO.println s!"  {transitionLine t}"

  IO.println ""
  IO.println "MDP choices"
  for s in states do
    for line in (choices s).flatMap (choiceLines s) do
      IO.println line

  IO.println ""
  IO.println "Time-weighted queue length distribution under successPolicy"
  for bucket in queueLengthTimeDistribution do
    IO.println (distributionLine bucket)

  IO.println ""
  IO.println "Global visible terminal traces under successPolicy"
  for path in terminalStats do
    IO.println (terminalLine path)

  IO.println ""
  IO.println "Expected metrics under successPolicy"
  IO.println (metricLine "expected latency" expectedLatencyNumerator expectedLatencyDenominator)
  IO.println (metricLine "success probability" successMass terminalMass)
  IO.println (metricLine "throughput" throughputNumerator throughputDenominator)

  IO.println ""
  IO.println "Component and assembled metrics"
  for line in metricsLines "auth group" authMetrics do
    IO.println line
  for line in metricsLines "worker group" workerMetrics do
    IO.println line
  for line in metricsLines "assembled system" assembledMetrics do
    IO.println line

  IO.println ""
  IO.println "Graphviz DOT"
  IO.println "digraph protocol {"
  for s in states do
    IO.println s!"  \"{stateName s}\";"
  for t in transitions do
    IO.println (dotLine t)
  IO.println "}"

  IO.println ""
  IO.println "CTL from initial observation"
  IO.println (ctlLine "AF success (all paths eventually succeed)" mustEventuallySucceed)
  IO.println (ctlLine "AG !fail   (all reachable observations avoid failure)" neverFails)
  IO.println (ctlLine "EF fail    (some path can fail)" mayFail)
