import LeanFM.Protocol

namespace LeanFM

structure TaskKey where
  session : String
  task : String
deriving DecidableEq, Repr

inductive TaskOutcome where
  | succeeded
  | failed
deriving DecidableEq, Repr

inductive TaskBoundary where
  | started
  | progress
  | succeeded
  | failed
deriving DecidableEq, Repr

structure JoinThreshold where
  required : Nat
  total : Nat
  selected : List String
deriving DecidableEq, Repr

structure ObservedTaskEvent where
  id : String
  prior : List String
  key : TaskKey
  timeAt : ClockTimestamp
  boundary : TaskBoundary
  join : Option JoinThreshold := none
deriving DecidableEq, Repr

def ObservedTaskEvent.hasValidJoinEvidence (event : ObservedTaskEvent) : Bool :=
  match event.join with
  | none => true
  | some threshold =>
      threshold.required > 0 &&
      threshold.required <= threshold.total &&
      threshold.selected.length == threshold.required &&
      threshold.selected.eraseDups.length == threshold.selected.length &&
      threshold.selected.all event.prior.contains

/-- One `(session, task)` attempt reconstructed from an observed event stream. -/
structure TaskAttempt where
  key : TaskKey
  started : ObservedTaskEvent
  completed : Option ObservedTaskEvent
  outcome : Option TaskOutcome
deriving DecidableEq, Repr

def TaskAttempt.latency (attempt : TaskAttempt) : Option Duration :=
  match attempt.completed with
  | some completed =>
      if attempt.started.timeAt <= completed.timeAt then
        some (completed.timeAt - attempt.started.timeAt)
      else
        none
  | none => none

private def closeAttempt (event : ObservedTaskEvent)
    (outcome : TaskOutcome) : List TaskAttempt -> List TaskAttempt
  | [] => []
  | attempt :: rest =>
      if attempt.key = event.key && attempt.completed.isNone &&
          event.prior.contains attempt.started.id then
        { attempt with completed := some event, outcome := some outcome } :: rest
      else
        attempt :: closeAttempt event outcome rest

def observeTaskEvent (attempts : List TaskAttempt)
    (event : ObservedTaskEvent) : List TaskAttempt :=
  match event.boundary with
  | .started =>
      attempts ++
        [{ key := event.key
         , started := event
         , completed := none
         , outcome := none }]
  | .progress => attempts
  | .succeeded => closeAttempt event .succeeded attempts
  | .failed => closeAttempt event .failed attempts

/-- Reconstruct attempts by terminal-to-start backpointer, not by stream adjacency. -/
def attemptsFromEventStream (events : List ObservedTaskEvent) : List TaskAttempt :=
  events.foldl observeTaskEvent []

structure TaskEstimate where
  started : Nat
  completed : Nat
  succeeded : Nat
  failed : Nat
  inFlight : Nat
  totalCompletedLatency : Duration
deriving DecidableEq, Repr

def emptyTaskEstimate : TaskEstimate :=
  { started := 0
  , completed := 0
  , succeeded := 0
  , failed := 0
  , inFlight := 0
  , totalCompletedLatency := 0
  }

def TaskEstimate.observe (estimate : TaskEstimate) (attempt : TaskAttempt) : TaskEstimate :=
  match attempt.completed, attempt.outcome with
  | some _, some .succeeded =>
      { estimate with
        started := estimate.started + 1
        completed := estimate.completed + 1
        succeeded := estimate.succeeded + 1
        totalCompletedLatency := estimate.totalCompletedLatency + attempt.latency.getD 0 }
  | some _, some .failed =>
      { estimate with
        started := estimate.started + 1
        completed := estimate.completed + 1
        failed := estimate.failed + 1
        totalCompletedLatency := estimate.totalCompletedLatency + attempt.latency.getD 0 }
  | some _, none =>
      { estimate with
        started := estimate.started + 1
        completed := estimate.completed + 1
        totalCompletedLatency := estimate.totalCompletedLatency + attempt.latency.getD 0 }
  | none, _ =>
      { estimate with
        started := estimate.started + 1
        inFlight := estimate.inFlight + 1 }

def estimateTasks (attempts : List TaskAttempt) : TaskEstimate :=
  attempts.foldl TaskEstimate.observe emptyTaskEstimate

def estimateEventStream (events : List ObservedTaskEvent) : TaskEstimate :=
  estimateTasks (attemptsFromEventStream events)

def TaskEstimate.completionProbability (estimate : TaskEstimate) : Nat × Nat :=
  (estimate.completed, estimate.started)

def TaskEstimate.successProbabilityGivenCompletion (estimate : TaskEstimate) : Nat × Nat :=
  (estimate.succeeded, estimate.completed)

def TaskEstimate.meanCompletedLatency (estimate : TaskEstimate) : Option (Nat × Nat) :=
  if estimate.completed = 0 then
    none
  else
    some (estimate.totalCompletedLatency, estimate.completed)

/-- A completed unit of measured work, retaining its two boundary messages. -/
structure WorkObservation where
  client : String
  server : String
  started : ObservedTaskEvent
  completed : ObservedTaskEvent
  work : Nat
deriving DecidableEq, Repr

def WorkObservation.observationTime (observation : WorkObservation) : Option Duration :=
  if observation.started.key = observation.completed.key &&
      observation.completed.prior.contains observation.started.id &&
      observation.started.timeAt <= observation.completed.timeAt then
    some (observation.completed.timeAt - observation.started.timeAt)
  else
    none

structure WorkRate where
  work : Nat
  milliseconds : Nat
deriving DecidableEq, Repr

/-- Pooled rate weighted by every client's own observation time. -/
def clientExperiencedRate (observations : List WorkObservation) : Option WorkRate :=
  let valid := observations.filterMap fun observation =>
    observation.observationTime.map fun elapsed => (observation.work, elapsed)
  if valid.length != observations.length || valid.isEmpty then none
  else
    some
      { work := valid.foldl (fun total sample => total + sample.1) 0
      , milliseconds := valid.foldl (fun total sample => total + sample.2) 0
      }

/-- Server throughput over the wall-clock observation window. -/
def serverAggregateRate (observations : List WorkObservation) : Option WorkRate :=
  match observations with
  | [] => none
  | first :: rest =>
      let startAt := rest.foldl
        (fun earliest observation => min earliest observation.started.timeAt)
        first.started.timeAt
      let stopAt := rest.foldl
        (fun latest observation => max latest observation.completed.timeAt)
        first.completed.timeAt
      if observations.all (fun observation => observation.observationTime.isSome) && startAt < stopAt then
        some
          { work := observations.foldl (fun total observation => total + observation.work) 0
          , milliseconds := stopAt - startAt
          }
      else none

/-- One measured point suitable for fitting the Universal Scalability Law. -/
structure ScalabilityObservation where
  clientCount : Nat
  clientExperienced : WorkRate
  serverAggregate : WorkRate
deriving DecidableEq, Repr

def scalabilityObservation (clientCount : Nat)
    (observations : List WorkObservation) : Option ScalabilityObservation := do
  if clientCount == 0 then none else pure ()
  let clientRate ← clientExperiencedRate observations
  let serverRate ← serverAggregateRate observations
  pure { clientCount := clientCount, clientExperienced := clientRate, serverAggregate := serverRate }

/-- One observed outage, delimited by Unavailable and Recovered messages. -/
structure OutageObservation where
  actorSpec : String
  actorInstance : String
  unavailable : ObservedTaskEvent
  recovered : ObservedTaskEvent
deriving DecidableEq, Repr

def OutageObservation.repairTime (outage : OutageObservation) : Option Duration :=
  if outage.recovered.prior.contains outage.unavailable.id &&
      outage.unavailable.timeAt <= outage.recovered.timeAt then
    some (outage.recovered.timeAt - outage.unavailable.timeAt)
  else none

/-- Exact observed reliability totals; ratios remain numerator/denominator pairs. -/
structure ReliabilityEstimate where
  actorSpec : String
  replicaCount : Nat
  outageTimeMs : Nat
  capacityTimeMs : Nat
  incidents : Nat
  totalRepairTimeMs : Nat
deriving DecidableEq, Repr

def ReliabilityEstimate.outageFraction (estimate : ReliabilityEstimate) : Nat × Nat :=
  (estimate.outageTimeMs, estimate.capacityTimeMs)

def ReliabilityEstimate.meanTimeToRepair (estimate : ReliabilityEstimate) : Option (Nat × Nat) :=
  if estimate.incidents == 0 then none
  else some (estimate.totalRepairTimeMs, estimate.incidents)

def estimateReliability (actorSpec : String) (replicaCount : Nat)
    (windowStart windowEnd : ClockTimestamp)
    (outages : List OutageObservation) : Option ReliabilityEstimate :=
  if replicaCount == 0 || windowEnd <= windowStart then none
  else
    let selected := outages.filter (fun outage => outage.actorSpec == actorSpec)
    let durations := selected.filterMap OutageObservation.repairTime
    let insideWindow := selected.all fun outage =>
      windowStart <= outage.unavailable.timeAt && outage.recovered.timeAt <= windowEnd
    if durations.length != selected.length || !insideWindow then none
    else
      let outageTime := durations.foldl (fun total duration => total + duration) 0
      some
        { actorSpec := actorSpec
        , replicaCount := replicaCount
        , outageTimeMs := outageTime
        , capacityTimeMs := replicaCount * (windowEnd - windowStart)
        , incidents := durations.length
        , totalRepairTimeMs := outageTime
        }

end LeanFM
