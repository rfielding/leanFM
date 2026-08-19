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
  | sleeping
  | done
  | failed
deriving DecidableEq, Repr

structure Envelope where
  src : Actor
  dst : Actor
  bytes : List Nat
deriving DecidableEq, Repr

inductive BlockReason where
  | readEmpty
  | writeFull
deriving DecidableEq, Repr

structure Turn where
  actor : Actor
  emitted : Option Envelope
  blocked : Option BlockReason
deriving DecidableEq, Repr

def emitTurn (actor : Actor) (msg : Envelope) : Turn :=
  { actor := actor, emitted := some msg, blocked := none }

def sleepRead (actor : Actor) : Turn :=
  { actor := actor, emitted := none, blocked := some BlockReason.readEmpty }

def sleepWrite (actor : Actor) : Turn :=
  { actor := actor, emitted := none, blocked := some BlockReason.writeFull }

def submit : Envelope :=
  { src := Actor.client, dst := Actor.gateway, bytes := [0x01, 0x10] }

def dispatch : Envelope :=
  { src := Actor.gateway, dst := Actor.worker, bytes := [0x02, 0x20] }

def resultOk : Envelope :=
  { src := Actor.worker, dst := Actor.gateway, bytes := [0x03, 0x30] }

def resultFail : Envelope :=
  { src := Actor.worker, dst := Actor.gateway, bytes := [0x03, 0xff] }

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
  authQ : Nat
  db : ActorState
  dbQ : Nat
deriving DecidableEq, Repr

def authCap (a : Actor) : Nat :=
  match a with
  | Actor.auth => 1
  | Actor.db => 1
  | _ => 0

def authWithinCapacity (s : AuthObservation) : Bool :=
  s.authQ <= authCap Actor.auth && s.dbQ <= authCap Actor.db

def authInitial : AuthObservation :=
  { auth := ActorState.idle, authQ := 0, db := ActorState.idle, dbQ := 0 }

def authAfterQuery : AuthObservation :=
  { auth := ActorState.waiting, authQ := 0, db := ActorState.queued, dbQ := 1 }

def authAfterOk : AuthObservation :=
  { auth := ActorState.queued, authQ := 1, db := ActorState.done, dbQ := 0 }

def authAfterFail : AuthObservation :=
  { auth := ActorState.queued, authQ := 1, db := ActorState.failed, dbQ := 0 }

def authSucceeded : AuthObservation :=
  { auth := ActorState.done, authQ := 0, db := ActorState.done, dbQ := 0 }

def authFailed : AuthObservation :=
  { auth := ActorState.failed, authQ := 0, db := ActorState.failed, dbQ := 0 }

def authGrammar : List Envelope :=
  [authQuery, authOk, authFail]

def turnGrammar (messages : List Envelope) : List Turn :=
  messages.map fun e => emitTurn e.src e

def authChoices : AuthObservation -> List (Choice AuthObservation Turn)
  | s =>
      if s = authInitial then
        [Choice.action (emitTurn Actor.auth authQuery) 1 authAfterQuery]
      else if s = authAfterQuery then
        [Choice.chance (emitTurn Actor.db authOk)
          [ { weight := 98, dwell := 2, value := authAfterOk }
          , { weight := 2, dwell := 2, value := authAfterFail }
          ]]
      else if s = authAfterOk then
        [Choice.action (emitTurn Actor.auth authOk) 1 authSucceeded]
      else if s = authAfterFail then
        [Choice.action (emitTurn Actor.auth authFail) 1 authFailed]
      else
        []

def authStates : List AuthObservation :=
  [authInitial, authAfterQuery, authAfterOk, authAfterFail, authSucceeded, authFailed]

def authComponent : Component AuthObservation Turn :=
  { initial := authInitial
  , states := authStates
  , grammar := turnGrammar authGrammar
  , choices := authChoices
  }

def authSuccessPolicy : AuthObservation -> Option (Choice AuthObservation Turn)
  | s =>
      if s = authInitial then
        some (Choice.action (emitTurn Actor.auth authQuery) 1 authAfterQuery)
      else if s = authAfterQuery then
        some (Choice.chance (emitTurn Actor.db authOk)
          [ { weight := 98, dwell := 2, value := authAfterOk }
          , { weight := 2, dwell := 2, value := authAfterFail }
          ])
      else if s = authAfterOk then
        some (Choice.action (emitTurn Actor.auth authOk) 1 authSucceeded)
      else if s = authAfterFail then
        some (Choice.action (emitTurn Actor.auth authFail) 1 authFailed)
      else
        none

def authInitialStats : PathStats AuthObservation Turn :=
  { mass := 1, scale := 1, lastDwell := 0, elapsed := 0, state := authInitial, trace := [] }

def authStats1 : List (PathStats AuthObservation Turn) :=
  advancePolicy authSuccessPolicy authInitialStats

def authStats2 : List (PathStats AuthObservation Turn) :=
  authStats1.flatMap (advancePolicy authSuccessPolicy)

def authTerminalStats : List (PathStats AuthObservation Turn) :=
  authStats2.flatMap (advancePolicy authSuccessPolicy)

def authIsSucceeded (s : AuthObservation) : Bool :=
  s.auth = ActorState.done && s.db = ActorState.done

def authTerminalMass : Nat :=
  authTerminalStats.foldl (fun n path => n + path.mass) 0

def authSuccessMass : Nat :=
  authTerminalStats.foldl (fun n path => if authIsSucceeded path.state then n + path.mass else n) 0

def authLatencyNumerator : Nat :=
  authTerminalStats.foldl (fun n path => n + path.mass * path.elapsed) 0

def authMetrics : Metrics :=
  { successNum := authSuccessMass
  , successDen := authTerminalMass
  , latencyNum := authLatencyNumerator
  , latencyDen := authTerminalMass
  }

structure Observation where
  client : ActorState
  clientQ : Nat
  gateway : ActorState
  gatewayQ : Nat
  worker : ActorState
  workerQ : Nat
deriving DecidableEq, Repr

def cap (a : Actor) : Nat :=
  match a with
  | Actor.client => 1
  | Actor.gateway => 2
  | Actor.worker => 1
  | _ => 0

def withinCapacity (s : Observation) : Bool :=
  s.clientQ <= cap Actor.client &&
    s.gatewayQ <= cap Actor.gateway &&
    s.workerQ <= cap Actor.worker

def initial : Observation :=
  { client := ActorState.idle, clientQ := 0
  , gateway := ActorState.idle, gatewayQ := 0
  , worker := ActorState.idle, workerQ := 0
  }

def afterSubmit : Observation :=
  { client := ActorState.waiting, clientQ := 0
  , gateway := ActorState.queued, gatewayQ := 1
  , worker := ActorState.idle, workerQ := 0
  }

def afterDispatch : Observation :=
  { client := ActorState.waiting, clientQ := 0
  , gateway := ActorState.waiting, gatewayQ := 0
  , worker := ActorState.queued, workerQ := 1
  }

def afterWorkerOk : Observation :=
  { client := ActorState.waiting, clientQ := 0
  , gateway := ActorState.queued, gatewayQ := 1
  , worker := ActorState.done, workerQ := 0
  }

def afterWorkerFail : Observation :=
  { client := ActorState.waiting, clientQ := 0
  , gateway := ActorState.queued, gatewayQ := 1
  , worker := ActorState.failed, workerQ := 0
  }

def afterReply : Observation :=
  { client := ActorState.queued, clientQ := 1
  , gateway := ActorState.done, gatewayQ := 0
  , worker := ActorState.done, workerQ := 0
  }

def afterReject : Observation :=
  { client := ActorState.queued, clientQ := 1
  , gateway := ActorState.failed, gatewayQ := 0
  , worker := ActorState.failed, workerQ := 0
  }

def succeeded : Observation :=
  { client := ActorState.done, clientQ := 0
  , gateway := ActorState.done, gatewayQ := 0
  , worker := ActorState.done, workerQ := 0
  }

def failed : Observation :=
  { client := ActorState.failed, clientQ := 0
  , gateway := ActorState.failed, gatewayQ := 0
  , worker := ActorState.failed, workerQ := 0
  }

def grammar : List Envelope :=
  [submit, dispatch, resultOk, resultFail, replyToClient, rejectClient]

def choices : Observation -> List (Choice Observation Turn)
  | s =>
      if s = initial then
        [ Choice.action (emitTurn Actor.client submit) 1 afterSubmit
        , Choice.action (sleepRead Actor.gateway) 1 initial
        , Choice.action (sleepRead Actor.worker) 1 initial
        ]
      else if s = afterSubmit then
        [ Choice.action (emitTurn Actor.gateway dispatch) 2 afterDispatch
        , Choice.action (emitTurn Actor.gateway rejectClient) 1 afterReject
        , Choice.action (sleepRead Actor.worker) 1 afterSubmit
        ]
      else if s = afterDispatch then
        [Choice.chance (emitTurn Actor.worker resultOk)
          [ { weight := 95, dwell := 4, value := afterWorkerOk }
          , { weight := 5, dwell := 4, value := afterWorkerFail }
          ]
        , Choice.action (sleepRead Actor.gateway) 1 afterDispatch
        , Choice.action (sleepWrite Actor.gateway) 1 afterDispatch
        ]
      else if s = afterWorkerOk then
        [Choice.action (emitTurn Actor.gateway replyToClient) 1 afterReply]
      else if s = afterWorkerFail then
        [Choice.action (emitTurn Actor.gateway rejectClient) 1 afterReject]
      else if s = afterReply then
        [Choice.action (emitTurn Actor.client replyToClient) 1 succeeded]
      else if s = afterReject then
        [Choice.action (emitTurn Actor.client rejectClient) 1 failed]
      else
        []

def protocolMDP : MDP Observation Turn :=
  { choices := choices }

def states : List Observation :=
  [ initial, afterSubmit, afterDispatch, afterWorkerOk, afterWorkerFail
  , afterReply, afterReject, succeeded, failed
  ]

def workerComponent : Component Observation Turn :=
  { initial := initial
  , states := states
  , grammar := turnGrammar grammar
  , choices := choices
  }

def transitions : List (Observation × Turn × Observation) :=
  (states.map fun s =>
    (choices s).flatMap fun c =>
      (Choice.support c).map fun s' => (s, Choice.label c, s')).flatten

def successors (s : Observation) : List Observation :=
  protocolMDP.successors s

def queueLength (s : Observation) : Nat :=
  s.clientQ + s.gatewayQ + s.workerQ

def isSucceeded (s : Observation) : Bool :=
  s.client = ActorState.done && s.gateway = ActorState.done && s.worker = ActorState.done

def isFailed (s : Observation) : Bool :=
  s.client = ActorState.failed || s.gateway = ActorState.failed || s.worker = ActorState.failed

def successPolicy : Observation -> Option (Choice Observation Turn)
  | s =>
      if s = initial then
        some (Choice.action (emitTurn Actor.client submit) 1 afterSubmit)
      else if s = afterSubmit then
        some (Choice.action (emitTurn Actor.gateway dispatch) 2 afterDispatch)
      else if s = afterDispatch then
        some (Choice.chance (emitTurn Actor.worker resultOk)
          [ { weight := 95, dwell := 4, value := afterWorkerOk }
          , { weight := 5, dwell := 4, value := afterWorkerFail }
          ])
      else if s = afterWorkerOk then
        some (Choice.action (emitTurn Actor.gateway replyToClient) 1 afterReply)
      else if s = afterWorkerFail then
        some (Choice.action (emitTurn Actor.gateway rejectClient) 1 afterReject)
      else if s = afterReply then
        some (Choice.action (emitTurn Actor.client replyToClient) 1 succeeded)
      else if s = afterReject then
        some (Choice.action (emitTurn Actor.client rejectClient) 1 failed)
      else
        none

def initialStats : PathStats Observation Turn :=
  { mass := 1, scale := 1, lastDwell := 0, elapsed := 0, state := initial, trace := [] }

def stats1 : List (PathStats Observation Turn) :=
  advancePolicy successPolicy initialStats

def stats2 : List (PathStats Observation Turn) :=
  stats1.flatMap (advancePolicy successPolicy)

def stats3 : List (PathStats Observation Turn) :=
  stats2.flatMap (advancePolicy successPolicy)

def stats4 : List (PathStats Observation Turn) :=
  stats3.flatMap (advancePolicy successPolicy)

def terminalStats : List (PathStats Observation Turn) :=
  stats4.flatMap (advancePolicy successPolicy)

def terminalMass : Nat :=
  terminalStats.foldl (fun n path => n + path.mass) 0

def expectedLatencyNumerator : Nat :=
  terminalStats.foldl (fun n path => n + path.mass * path.elapsed) 0

def expectedLatencyDenominator : Nat :=
  terminalMass

def successMass : Nat :=
  terminalStats.foldl (fun n path => if isSucceeded path.state then n + path.mass else n) 0

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

def queueLengthSamples : List (PathStats Observation Turn) :=
  stats1 ++ stats2 ++ stats3 ++ stats4 ++ terminalStats

def queueLengthTimeDistribution : List (Nat × Nat) :=
  bucketScaledMass terminalMass queueLength queueLengthSamples

def mustEventuallySucceed : CTL Observation :=
  CTL.af (CTL.atom isSucceeded)

def neverFails : CTL Observation :=
  CTL.ag (CTL.neg (CTL.atom isFailed))

def mayFail : CTL Observation :=
  CTL.ef (CTL.atom isFailed)

def queuesStayWithinCapacity : CTL Observation :=
  CTL.ag (CTL.atom withinCapacity)

theorem initial_within_capacity :
    withinCapacity initial = true := by
  rfl

theorem all_listed_states_within_capacity :
    states.all withinCapacity = true := by
  rfl

end LeanFM
