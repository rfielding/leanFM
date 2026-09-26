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

structure ObservedTaskEvent where
  id : String
  prior : List String
  key : TaskKey
  timeAt : ClockTimestamp
  boundary : TaskBoundary
deriving DecidableEq, Repr

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

end LeanFM
