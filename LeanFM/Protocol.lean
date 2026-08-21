import LeanFM.CTL
import LeanFM.MDP

namespace LeanFM

inductive Actor where
  | auth
  | db
  | client
  | gateway
  | worker
deriving DecidableEq, Repr

inductive ActorState where
  | idle
  | waiting
  | queued
  | busy
  | done
  | failed
deriving DecidableEq, Repr

structure Envelope where
  src : Actor
  dst : Actor
  bytes : List Nat
deriving DecidableEq, Repr

structure Observation where
  client : ActorState
  gateway : ActorState
  worker : ActorState
deriving DecidableEq, Repr

def submit : Envelope :=
  { src := Actor.client, dst := Actor.gateway, bytes := [0x01, 0x10] }

def dispatch : Envelope :=
  { src := Actor.gateway, dst := Actor.worker, bytes := [0x02, 0x20] }

def result : Envelope :=
  { src := Actor.worker, dst := Actor.gateway, bytes := [0x03, 0x30] }

def replyToClient : Envelope :=
  { src := Actor.gateway, dst := Actor.client, bytes := [0x04, 0x40] }

def rejectClient : Envelope :=
  { src := Actor.gateway, dst := Actor.client, bytes := [0xff] }

def authQuery : Envelope :=
  { src := Actor.auth, dst := Actor.db, bytes := [0x0a, 0x01] }

def authOk : Envelope :=
  { src := Actor.db, dst := Actor.auth, bytes := [0x0a, 0x02] }

def authFail : Envelope :=
  { src := Actor.db, dst := Actor.auth, bytes := [0x0a, 0xff] }

structure AuthObservation where
  auth : ActorState
  db : ActorState
deriving DecidableEq, Repr

def authInitial : AuthObservation :=
  { auth := ActorState.idle, db := ActorState.idle }

def authWaiting : AuthObservation :=
  { auth := ActorState.waiting, db := ActorState.busy }

def authSucceeded : AuthObservation :=
  { auth := ActorState.done, db := ActorState.done }

def authFailed : AuthObservation :=
  { auth := ActorState.failed, db := ActorState.failed }

def authGrammar : List Envelope :=
  [authQuery, authOk, authFail]

def authChoices : AuthObservation -> List (Choice AuthObservation Envelope)
  | s =>
      if s = authInitial then
        [Choice.action authQuery 1 authWaiting]
      else if s = authWaiting then
        [Choice.chance authOk
          [ { weight := 98, dwell := 2, value := authSucceeded }
          , { weight := 2, dwell := 2, value := authFailed }
          ]]
      else
        []

def authStates : List AuthObservation :=
  [authInitial, authWaiting, authSucceeded, authFailed]

def authComponent : Component AuthObservation Envelope :=
  { initial := authInitial
  , states := authStates
  , grammar := authGrammar
  , choices := authChoices
  }

def authSuccessPolicy : AuthObservation -> Option (Choice AuthObservation Envelope)
  | s =>
      if s = authInitial then
        some (Choice.action authQuery 1 authWaiting)
      else if s = authWaiting then
        some (Choice.chance authOk
          [ { weight := 98, dwell := 2, value := authSucceeded }
          , { weight := 2, dwell := 2, value := authFailed }
          ])
      else
        none

def authInitialStats : PathStats AuthObservation Envelope :=
  { mass := 1
  , scale := 1
  , lastDwell := 0
  , elapsed := 0
  , state := authInitial
  , trace := []
  }

def authStatsAfterQuery : List (PathStats AuthObservation Envelope) :=
  advancePolicy authSuccessPolicy authInitialStats

def authTerminalStats : List (PathStats AuthObservation Envelope) :=
  authStatsAfterQuery.flatMap (advancePolicy authSuccessPolicy)

def authIsSucceeded (s : AuthObservation) : Bool :=
  s.auth = ActorState.done && s.db = ActorState.done

def authTerminalMass : Nat :=
  authTerminalStats.foldl (fun n path => n + path.mass) 0

def authSuccessMass : Nat :=
  authTerminalStats.foldl
    (fun n path => if authIsSucceeded path.state then n + path.mass else n)
    0

def authLatencyNumerator : Nat :=
  authTerminalStats.foldl (fun n path => n + path.mass * path.elapsed) 0

def authMetrics : Metrics :=
  { successNum := authSuccessMass
  , successDen := authTerminalMass
  , latencyNum := authLatencyNumerator
  , latencyDen := authTerminalMass
  }

def initial : Observation :=
  { client := ActorState.idle
  , gateway := ActorState.idle
  , worker := ActorState.idle
  }

def afterSubmit : Observation :=
  { client := ActorState.waiting
  , gateway := ActorState.queued
  , worker := ActorState.idle
  }

def afterDispatch : Observation :=
  { client := ActorState.waiting
  , gateway := ActorState.waiting
  , worker := ActorState.busy
  }

def afterResult : Observation :=
  { client := ActorState.waiting
  , gateway := ActorState.done
  , worker := ActorState.done
  }

def succeeded : Observation :=
  { client := ActorState.done
  , gateway := ActorState.done
  , worker := ActorState.done
  }

def failed : Observation :=
  { client := ActorState.failed
  , gateway := ActorState.failed
  , worker := ActorState.failed
  }

def clientStep (self : Actor) (st : ActorState) (e : Envelope) : ActorState :=
  if st = ActorState.idle && e.src = self && e = submit then ActorState.waiting
  else if st = ActorState.waiting && e.dst = self && e = replyToClient then ActorState.done
  else if st = ActorState.waiting && e.dst = self && e = rejectClient then ActorState.failed
  else st

def gatewayStep (self : Actor) (st : ActorState) (e : Envelope) : ActorState :=
  if st = ActorState.idle && e.dst = self && e = submit then ActorState.queued
  else if st = ActorState.queued && e.src = self && e = dispatch then ActorState.waiting
  else if st = ActorState.waiting && e.dst = self && e = result then ActorState.done
  else if st = ActorState.queued && e.src = self && e = rejectClient then ActorState.failed
  else st

def workerStep (self : Actor) (st : ActorState) (e : Envelope) : ActorState :=
  if st = ActorState.idle && e.dst = self && e = dispatch then ActorState.busy
  else if st = ActorState.busy && e.src = self && e = result then ActorState.done
  else st

def applyMessage (s : Observation) (e : Envelope) : Observation :=
  { client := clientStep Actor.client s.client e
  , gateway := gatewayStep Actor.gateway s.gateway e
  , worker := workerStep Actor.worker s.worker e
  }

def observe (s : Observation) (e : Envelope) : Option Observation :=
  let s' := applyMessage s e
  if s' = s then none else some s'

def grammar : List Envelope :=
  [submit, dispatch, result, replyToClient, rejectClient]

def choices : Observation -> List (Choice Observation Envelope)
  | s =>
      if s = initial then
        [Choice.action submit 1 afterSubmit]
      else if s = afterSubmit then
        [ Choice.action dispatch 2 afterDispatch
        , Choice.action rejectClient 1 failed
        ]
      else if s = afterDispatch then
        [Choice.chance result
          [ { weight := 95, dwell := 4, value := afterResult }
          , { weight := 5, dwell := 4, value := failed }
          ]]
      else if s = afterResult then
        [Choice.action replyToClient 1 succeeded]
      else
        []

def protocolMDP : MDP Observation Envelope :=
  { choices := choices }

def states : List Observation :=
  [initial, afterSubmit, afterDispatch, afterResult, succeeded, failed]

def workerComponent : Component Observation Envelope :=
  { initial := initial
  , states := states
  , grammar := grammar
  , choices := choices
  }

def transitions : List (Observation × Envelope × Observation) :=
  (states.map fun s =>
    (choices s).flatMap fun c =>
      (Choice.support c).map fun s' => (s, Choice.label c, s')).flatten

def successors (s : Observation) : List Observation :=
  protocolMDP.successors s

def queueLength (s : Observation) : Nat :=
  let gatewayQueue := if s.gateway = ActorState.queued then 1 else 0
  let workerQueue := if s.worker = ActorState.busy then 1 else 0
  gatewayQueue + workerQueue

def isSucceeded (s : Observation) : Bool :=
  s.client = ActorState.done && s.gateway = ActorState.done && s.worker = ActorState.done

def isFailed (s : Observation) : Bool :=
  s.client = ActorState.failed || s.gateway = ActorState.failed || s.worker = ActorState.failed

def successPolicy : Observation -> Option (Choice Observation Envelope)
  | s =>
      if s = initial then
        some (Choice.action submit 1 afterSubmit)
      else if s = afterSubmit then
        some (Choice.action dispatch 2 afterDispatch)
      else if s = afterDispatch then
        some (Choice.chance result
          [ { weight := 95, dwell := 4, value := afterResult }
          , { weight := 5, dwell := 4, value := failed }
          ])
      else if s = afterResult then
        some (Choice.action replyToClient 1 succeeded)
      else
        none

def initialStats : PathStats Observation Envelope :=
  { mass := 1
  , scale := 1
  , lastDwell := 0
  , elapsed := 0
  , state := initial
  , trace := []
  }

def statsAfterSubmit : List (PathStats Observation Envelope) :=
  advancePolicy successPolicy initialStats

def statsAfterDispatch : List (PathStats Observation Envelope) :=
  statsAfterSubmit.flatMap (advancePolicy successPolicy)

def statsAfterResult : List (PathStats Observation Envelope) :=
  statsAfterDispatch.flatMap (advancePolicy successPolicy)

def terminalStats : List (PathStats Observation Envelope) :=
  statsAfterResult.flatMap (advancePolicy successPolicy)

def terminalMass : Nat :=
  terminalStats.foldl (fun n path => n + path.mass) 0

def expectedLatencyNumerator : Nat :=
  terminalStats.foldl (fun n path => n + path.mass * path.elapsed) 0

def expectedLatencyDenominator : Nat :=
  terminalMass

def successMass : Nat :=
  terminalStats.foldl
    (fun n path => if isSucceeded path.state then n + path.mass else n)
    0

def throughputNumerator : Nat :=
  successMass

def throughputDenominator : Nat :=
  expectedLatencyNumerator

def workerMetrics : Metrics :=
  { successNum := successMass
  , successDen := terminalMass
  , latencyNum := expectedLatencyNumerator
  , latencyDen := expectedLatencyDenominator
  }

def assembledGrammar : List Envelope :=
  authGrammar ++ grammar

def assembledMetrics : Metrics :=
  composeSequential authMetrics workerMetrics

def queueLengthSamples : List (PathStats Observation Envelope) :=
  statsAfterSubmit ++ statsAfterDispatch ++ statsAfterResult ++
    terminalStats.filter (fun path => isSucceeded path.state)

def queueLengthTimeDistribution : List (Nat × Nat) :=
  bucketScaledMass terminalMass queueLength queueLengthSamples

def mustEventuallySucceed : CTL Observation :=
  CTL.af (CTL.atom isSucceeded)

def neverFails : CTL Observation :=
  CTL.ag (CTL.neg (CTL.atom isFailed))

def mayFail : CTL Observation :=
  CTL.ef (CTL.atom isFailed)

theorem initial_observes_submit :
    observe initial submit = some afterSubmit := by
  simp [observe, applyMessage, clientStep, gatewayStep, workerStep,
    initial, submit, afterSubmit]

theorem succeeded_is_terminal_for_grammar :
    (grammar.filterMap (observe succeeded)) = [] := by
  rfl

end LeanFM
