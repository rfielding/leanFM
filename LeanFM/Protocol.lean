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

inductive TaskKind where
  | purchaseItem
  | postReview
  | auth
deriving DecidableEq, Repr

inductive Transport where
  | http
  | https
deriving DecidableEq, Repr

structure ProtoField where
  number : Nat
  name : String
  value : String
deriving DecidableEq, Repr

structure ProtoPayload where
  typeName : String
  summary : String
  bytes : List Nat
  fields : List ProtoField
deriving DecidableEq, Repr

structure Envelope where
  task : TaskKind
  src : Actor
  dst : Actor
  transport : Transport
  proto : ProtoPayload
  ts : Nat
deriving DecidableEq, Repr

def parseProtoFields : String -> List Nat -> List ProtoField
  | "Docs.GetRequest", [0x01, 0x10] =>
      [ { number := 1, name := "method", value := "GET" }
      , { number := 2, name := "path", value := "/docs/index.html" }
      ]
  | "Docs.FetchCommand", [0x02, 0x20] =>
      [ { number := 1, name := "path", value := "/docs/index.html" }
      , { number := 2, name := "cache_mode", value := "normal" }
      ]
  | "Docs.FetchResult", [0x03, 0x30] =>
      [ { number := 1, name := "status", value := "200" }
      , { number := 2, name := "path", value := "/docs/index.html" }
      ]
  | "Docs.FetchResult", [0x03, 0xff] =>
      [ { number := 1, name := "status", value := "404" }
      , { number := 2, name := "path", value := "/docs/index.html" }
      ]
  | "Docs.GetResponse", [0x04, 0x40] =>
      [ { number := 1, name := "status", value := "200" }
      , { number := 2, name := "path", value := "/docs/index.html" }
      ]
  | "Error.Response", [0xff] =>
      [ { number := 1, name := "status", value := "401" }
      , { number := 2, name := "reason", value := "unauthorized" }
      ]
  | "Reviews.PostRequest", [0x11, 0x10] =>
      [ { number := 1, name := "method", value := "POST" }
      , { number := 2, name := "path", value := "/reviews" }
      , { number := 3, name := "body_hash", value := "review#1" }
      ]
  | "Reviews.ModerateCommand", [0x12, 0x20] =>
      [ { number := 1, name := "body_hash", value := "review#1" }
      , { number := 2, name := "policy", value := "default" }
      ]
  | "Reviews.ModerationResult", [0x13, 0x30] =>
      [ { number := 1, name := "decision", value := "accepted" }
      , { number := 2, name := "body_hash", value := "review#1" }
      ]
  | "Reviews.ModerationResult", [0x13, 0xff] =>
      [ { number := 1, name := "decision", value := "rejected" }
      , { number := 2, name := "body_hash", value := "review#1" }
      ]
  | "Reviews.PostResponse", [0x14, 0x40] =>
      [ { number := 1, name := "status", value := "201" }
      , { number := 2, name := "path", value := "/reviews" }
      ]
  | "Reviews.PostResponse", [0x14, 0xff] =>
      [ { number := 1, name := "status", value := "400" }
      , { number := 2, name := "path", value := "/reviews" }
      ]
  | "Auth.LookupRequest", [0x0a, 0x01] =>
      [ { number := 1, name := "principal", value := "client" } ]
  | "Auth.LookupResponse", [0x0a, 0x02] =>
      [ { number := 1, name := "principal", value := "client" }
      , { number := 2, name := "authenticated", value := "true" }
      ]
  | "Auth.LookupResponse", [0x0a, 0xff] =>
      [ { number := 1, name := "principal", value := "client" }
      , { number := 2, name := "authenticated", value := "false" }
      ]
  | _, _ => []

def proto (typeName summary : String) (bytes : List Nat) : ProtoPayload :=
  { typeName := typeName
  , summary := summary
  , bytes := bytes
  , fields := parseProtoFields typeName bytes
  }

def protoWasParsed (p : ProtoPayload) : Bool :=
  !p.fields.isEmpty

def msg (task : TaskKind) (src dst : Actor) (transport : Transport)
    (typeName summary : String) (bytes : List Nat) (ts : Nat) : Envelope :=
  { task := task, src := src, dst := dst, transport := transport
  , proto := proto typeName summary bytes, ts := ts
  }

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
  msg TaskKind.purchaseItem Actor.client Actor.gateway Transport.https
    "Docs.GetRequest" "GET /docs/index.html" [0x01, 0x10] 1

def dispatch : Envelope :=
  msg TaskKind.purchaseItem Actor.gateway Actor.worker Transport.http
    "Docs.FetchCommand" "fetch /docs/index.html" [0x02, 0x20] 3

def resultOk : Envelope :=
  msg TaskKind.purchaseItem Actor.worker Actor.gateway Transport.http
    "Docs.FetchResult" "200 /docs/index.html" [0x03, 0x30] 7

def resultFail : Envelope :=
  msg TaskKind.purchaseItem Actor.worker Actor.gateway Transport.http
    "Docs.FetchResult" "404 /docs/index.html" [0x03, 0xff] 7

def replyToClient : Envelope :=
  msg TaskKind.purchaseItem Actor.gateway Actor.client Transport.https
    "Docs.GetResponse" "200 /docs/index.html" [0x04, 0x40] 8

def rejectClient : Envelope :=
  msg TaskKind.purchaseItem Actor.gateway Actor.client Transport.https
    "Error.Response" "401 unauthorized" [0xff] 2

def reviewSubmit : Envelope :=
  msg TaskKind.postReview Actor.client Actor.gateway Transport.https
    "Reviews.PostRequest" "POST /reviews" [0x11, 0x10] 1

def reviewModerate : Envelope :=
  msg TaskKind.postReview Actor.gateway Actor.worker Transport.http
    "Reviews.ModerateCommand" "moderate review" [0x12, 0x20] 2

def reviewOk : Envelope :=
  msg TaskKind.postReview Actor.worker Actor.gateway Transport.http
    "Reviews.ModerationResult" "review accepted" [0x13, 0x30] 5

def reviewReject : Envelope :=
  msg TaskKind.postReview Actor.worker Actor.gateway Transport.http
    "Reviews.ModerationResult" "review rejected" [0x13, 0xff] 5

def reviewPosted : Envelope :=
  msg TaskKind.postReview Actor.gateway Actor.client Transport.https
    "Reviews.PostResponse" "201 /reviews" [0x14, 0x40] 6

def reviewRejectClient : Envelope :=
  msg TaskKind.postReview Actor.gateway Actor.client Transport.https
    "Reviews.PostResponse" "400 /reviews" [0x14, 0xff] 6

def authQuery : Envelope :=
  msg TaskKind.auth Actor.auth Actor.db Transport.http
    "Auth.LookupRequest" "AUTH lookup client" [0x0a, 0x01] 1

def authOk : Envelope :=
  msg TaskKind.auth Actor.db Actor.auth Transport.http
    "Auth.LookupResponse" "AUTH ok client" [0x0a, 0x02] 3

def authFail : Envelope :=
  msg TaskKind.auth Actor.db Actor.auth Transport.http
    "Auth.LookupResponse" "AUTH failed client" [0x0a, 0xff] 3

structure AuthProof where
  issuedBy : Actor
  issuedTo : Actor
  bytes : List Nat
deriving DecidableEq, Repr

def loginProof : AuthProof :=
  { issuedBy := Actor.auth, issuedTo := Actor.client, bytes := [0xa0, 0x01] }

structure AuthObservation where
  auth : ActorState
  authQ : Nat
  db : ActorState
  dbQ : Nat
  proof : Option AuthProof
deriving DecidableEq, Repr

def authCap (a : Actor) : Nat :=
  match a with
  | Actor.auth => 1
  | Actor.db => 1
  | _ => 0

def authWithinCapacity (s : AuthObservation) : Bool :=
  s.authQ <= authCap Actor.auth && s.dbQ <= authCap Actor.db

def authInitial : AuthObservation :=
  { auth := ActorState.idle, authQ := 0, db := ActorState.idle, dbQ := 0, proof := none }

def authAfterQuery : AuthObservation :=
  { auth := ActorState.waiting, authQ := 0, db := ActorState.queued, dbQ := 1, proof := none }

def authAfterOk : AuthObservation :=
  { auth := ActorState.queued, authQ := 1, db := ActorState.done, dbQ := 0, proof := none }

def authAfterFail : AuthObservation :=
  { auth := ActorState.queued, authQ := 1, db := ActorState.failed, dbQ := 0, proof := none }

def authSucceeded : AuthObservation :=
  { auth := ActorState.done, authQ := 0, db := ActorState.done, dbQ := 0, proof := some loginProof }

def authFailed : AuthObservation :=
  { auth := ActorState.failed, authQ := 0, db := ActorState.failed, dbQ := 0, proof := none }

def authGrammar : List Envelope :=
  [authQuery, authOk, authFail]

def turnGrammar (messages : List Envelope) : List Turn :=
  messages.map fun e => emitTurn e.src e

def authChoices : AuthObservation -> List (Choice AuthObservation Turn)
  | s =>
      if s = authInitial then
        [Choice.action (emitTurn Actor.auth authQuery) 1 authAfterQuery]
      else if s = authAfterQuery then
        [Choice.chanceEvents
          [ { weight := 98, dwell := 2, value := (emitTurn Actor.db authOk, authAfterOk) }
          , { weight := 2, dwell := 2, value := (emitTurn Actor.db authFail, authAfterFail) }
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
        some (Choice.chanceEvents
          [ { weight := 98, dwell := 2, value := (emitTurn Actor.db authOk, authAfterOk) }
          , { weight := 2, dwell := 2, value := (emitTurn Actor.db authFail, authAfterFail) }
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
  task : Option TaskKind
  client : ActorState
  clientQ : Nat
  clientMsg : Option Envelope
  gateway : ActorState
  gatewayQ : Nat
  gatewayMsg : Option Envelope
  worker : ActorState
  workerQ : Nat
  workerMsg : Option Envelope
  proof : Option AuthProof
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

def hasValidAuth (s : Observation) : Bool :=
  s.proof == some loginProof

def initial : Observation :=
  { task := none
  , client := ActorState.idle, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.idle, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.idle, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def unauthenticatedInitial : Observation :=
  { task := none
  , client := ActorState.idle, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.idle, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.idle, workerQ := 0
  , workerMsg := none
  , proof := none
  }

def unauthorized : Observation :=
  { task := none
  , client := ActorState.failed, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.failed, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.idle, workerQ := 0
  , workerMsg := none
  , proof := none
  }

def afterSubmit : Observation :=
  { task := some TaskKind.purchaseItem
  , client := ActorState.waiting, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.queued, gatewayQ := 1
  , gatewayMsg := some submit
  , worker := ActorState.idle, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def afterDispatch : Observation :=
  { task := some TaskKind.purchaseItem
  , client := ActorState.waiting, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.waiting, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.queued, workerQ := 1
  , workerMsg := some dispatch
  , proof := some loginProof
  }

def afterWorkerOk : Observation :=
  { task := some TaskKind.purchaseItem
  , client := ActorState.waiting, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.queued, gatewayQ := 1
  , gatewayMsg := some resultOk
  , worker := ActorState.done, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def afterWorkerFail : Observation :=
  { task := some TaskKind.purchaseItem
  , client := ActorState.waiting, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.queued, gatewayQ := 1
  , gatewayMsg := some resultFail
  , worker := ActorState.failed, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def afterReply : Observation :=
  { task := some TaskKind.purchaseItem
  , client := ActorState.queued, clientQ := 1
  , clientMsg := some replyToClient
  , gateway := ActorState.done, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.done, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def afterReject : Observation :=
  { task := some TaskKind.purchaseItem
  , client := ActorState.queued, clientQ := 1
  , clientMsg := some rejectClient
  , gateway := ActorState.failed, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.failed, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def succeeded : Observation :=
  { task := none
  , client := ActorState.done, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.done, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.done, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def failed : Observation :=
  { task := none
  , client := ActorState.failed, clientQ := 0
  , clientMsg := none
  , gateway := ActorState.failed, gatewayQ := 0
  , gatewayMsg := none
  , worker := ActorState.failed, workerQ := 0
  , workerMsg := none
  , proof := some loginProof
  }

def reviewAfterSubmit : Observation :=
  { afterSubmit with task := some TaskKind.postReview, gatewayMsg := some reviewSubmit }

def reviewAfterDispatch : Observation :=
  { afterDispatch with task := some TaskKind.postReview, workerMsg := some reviewModerate }

def reviewAfterWorkerOk : Observation :=
  { afterWorkerOk with task := some TaskKind.postReview, gatewayMsg := some reviewOk }

def reviewAfterWorkerFail : Observation :=
  { afterWorkerFail with task := some TaskKind.postReview, gatewayMsg := some reviewReject }

def reviewAfterReply : Observation :=
  { afterReply with task := some TaskKind.postReview, clientMsg := some reviewPosted }

def reviewAfterReject : Observation :=
  { afterReject with task := some TaskKind.postReview, clientMsg := some reviewRejectClient }

def reviewSucceeded : Observation :=
  succeeded

def reviewFailed : Observation :=
  failed

def grammar : List Envelope :=
  [submit, dispatch, resultOk, resultFail, replyToClient, rejectClient]

def reviewGrammar : List Envelope :=
  [reviewSubmit, reviewModerate, reviewOk, reviewReject, reviewPosted, reviewRejectClient]

def workerGrammar : List Envelope :=
  grammar ++ reviewGrammar

structure TaskMachine where
  owner : Actor
  task : TaskKind
  accepts : List Envelope
  emits : List Envelope
deriving Repr

structure ActorSpec where
  actor : Actor
  queueCap : Nat
  tasks : List TaskKind
deriving Repr

structure World where
  actors : List ActorSpec
  tasks : List TaskMachine
  initial : Observation
  choices : Observation -> List (Choice Observation Turn)

def actorAcceptsTask (actor : Actor) (task : TaskKind) : Bool :=
  match actor, task with
  | Actor.client, TaskKind.purchaseItem => true
  | Actor.client, TaskKind.postReview => true
  | Actor.gateway, TaskKind.purchaseItem => true
  | Actor.gateway, TaskKind.postReview => true
  | Actor.worker, TaskKind.purchaseItem => true
  | Actor.worker, TaskKind.postReview => true
  | Actor.auth, TaskKind.auth => true
  | Actor.db, TaskKind.auth => true
  | _, _ => false

def selectTaskFromMessage (actor : Actor) (msg : Envelope) : Option TaskKind :=
  if msg.dst = actor && actorAcceptsTask actor msg.task then
    some msg.task
  else
    none

def queuedHeadSelectsKnownTask (actor : Actor) (head : Option Envelope) : Bool :=
  match head with
  | none => true
  | some msg => selectTaskFromMessage actor msg == some msg.task

def queuedMessagesSelectKnownTasks (s : Observation) : Bool :=
  queuedHeadSelectsKnownTask Actor.client s.clientMsg &&
    queuedHeadSelectsKnownTask Actor.gateway s.gatewayMsg &&
    queuedHeadSelectsKnownTask Actor.worker s.workerMsg

def clientSpec : ActorSpec :=
  { actor := Actor.client, queueCap := cap Actor.client, tasks := [TaskKind.purchaseItem, TaskKind.postReview] }

def gatewaySpec : ActorSpec :=
  { actor := Actor.gateway, queueCap := cap Actor.gateway, tasks := [TaskKind.purchaseItem, TaskKind.postReview] }

def workerSpec : ActorSpec :=
  { actor := Actor.worker, queueCap := cap Actor.worker, tasks := [TaskKind.purchaseItem, TaskKind.postReview] }

def authSpec : ActorSpec :=
  { actor := Actor.auth, queueCap := authCap Actor.auth, tasks := [TaskKind.auth] }

def dbSpec : ActorSpec :=
  { actor := Actor.db, queueCap := authCap Actor.db, tasks := [TaskKind.auth] }

def gatewayPurchaseTask : TaskMachine :=
  { owner := Actor.gateway
  , task := TaskKind.purchaseItem
  , accepts := [submit, resultOk, resultFail]
  , emits := [dispatch, replyToClient, rejectClient]
  }

def workerPurchaseTask : TaskMachine :=
  { owner := Actor.worker
  , task := TaskKind.purchaseItem
  , accepts := [dispatch]
  , emits := [resultOk, resultFail]
  }

def gatewayReviewTask : TaskMachine :=
  { owner := Actor.gateway
  , task := TaskKind.postReview
  , accepts := [reviewSubmit, reviewOk, reviewReject]
  , emits := [reviewModerate, reviewPosted, reviewRejectClient]
  }

def workerReviewTask : TaskMachine :=
  { owner := Actor.worker
  , task := TaskKind.postReview
  , accepts := [reviewModerate]
  , emits := [reviewOk, reviewReject]
  }

def choices : Observation -> List (Choice Observation Turn)
  | s =>
      if s = initial then
        [ Choice.action (emitTurn Actor.client submit) 1 afterSubmit
        , Choice.action (emitTurn Actor.client reviewSubmit) 1 reviewAfterSubmit
        , Choice.action (sleepRead Actor.gateway) 1 initial
        , Choice.action (sleepRead Actor.worker) 1 initial
        ]
      else if s = unauthenticatedInitial then
        [ Choice.action (emitTurn Actor.client submit) 1 unauthorized
        , Choice.action (emitTurn Actor.client reviewSubmit) 1 unauthorized
        , Choice.action (sleepRead Actor.gateway) 1 unauthenticatedInitial
        , Choice.action (sleepRead Actor.worker) 1 unauthenticatedInitial
        ]
      else if s = afterSubmit then
        [ Choice.action (emitTurn Actor.gateway dispatch) 2 afterDispatch
        , Choice.action (emitTurn Actor.gateway rejectClient) 1 afterReject
        , Choice.action (sleepRead Actor.worker) 1 afterSubmit
        ]
      else if s = afterDispatch then
        [Choice.chanceEvents
          [ { weight := 95, dwell := 4, value := (emitTurn Actor.worker resultOk, afterWorkerOk) }
          , { weight := 5, dwell := 4, value := (emitTurn Actor.worker resultFail, afterWorkerFail) }
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
      else if s = reviewAfterSubmit then
        [ Choice.action (emitTurn Actor.gateway reviewModerate) 1 reviewAfterDispatch
        , Choice.action (emitTurn Actor.gateway reviewRejectClient) 1 reviewAfterReject
        , Choice.action (sleepRead Actor.worker) 1 reviewAfterSubmit
        ]
      else if s = reviewAfterDispatch then
        [Choice.chanceEvents
          [ { weight := 90, dwell := 3, value := (emitTurn Actor.worker reviewOk, reviewAfterWorkerOk) }
          , { weight := 10, dwell := 3, value := (emitTurn Actor.worker reviewReject, reviewAfterWorkerFail) }
          ]
        , Choice.action (sleepRead Actor.gateway) 1 reviewAfterDispatch
        , Choice.action (sleepWrite Actor.gateway) 1 reviewAfterDispatch
        ]
      else if s = reviewAfterWorkerOk then
        [Choice.action (emitTurn Actor.gateway reviewPosted) 1 reviewAfterReply]
      else if s = reviewAfterWorkerFail then
        [Choice.action (emitTurn Actor.gateway reviewRejectClient) 1 reviewAfterReject]
      else if s = reviewAfterReply then
        [Choice.action (emitTurn Actor.client reviewPosted) 1 reviewSucceeded]
      else if s = reviewAfterReject then
        [Choice.action (emitTurn Actor.client reviewRejectClient) 1 reviewFailed]
      else
        []

def workerWorld : World :=
  { actors := [clientSpec, gatewaySpec, workerSpec]
  , tasks := [gatewayPurchaseTask, workerPurchaseTask, gatewayReviewTask, workerReviewTask]
  , initial := initial
  , choices := choices
  }

def protocolMDP : MDP Observation Turn :=
  { choices := choices }

def states : List Observation :=
  [ unauthenticatedInitial, unauthorized
  , initial, afterSubmit, afterDispatch, afterWorkerOk, afterWorkerFail
  , afterReply, afterReject, succeeded, failed
  , reviewAfterSubmit, reviewAfterDispatch, reviewAfterWorkerOk, reviewAfterWorkerFail
  , reviewAfterReply, reviewAfterReject, reviewSucceeded, reviewFailed
  ]

def workerComponent : Component Observation Turn :=
  { initial := initial
  , states := states
  , grammar := turnGrammar workerGrammar
  , choices := choices
  }

def transitions : List (Observation × Turn × Observation) :=
  (states.map fun s =>
    (choices s).flatMap fun c =>
      (Choice.labeledSupport c).map fun step => (s, step.1, step.2)).flatten

def successors (s : Observation) : List Observation :=
  protocolMDP.successors s

def queueLength (s : Observation) : Nat :=
  s.clientQ + s.gatewayQ + s.workerQ

def isSucceeded (s : Observation) : Bool :=
  s.client = ActorState.done && s.gateway = ActorState.done && s.worker = ActorState.done

def isFailed (s : Observation) : Bool :=
  s.client = ActorState.failed || s.gateway = ActorState.failed || s.worker = ActorState.failed

def isTerminal (s : Observation) : Bool :=
  (s.client = ActorState.done || s.client = ActorState.failed) &&
    s.clientQ = 0 && s.gatewayQ = 0 && s.workerQ = 0

def isUnauthorized (s : Observation) : Bool :=
  s = unauthorized

def successPolicy : Observation -> Option (Choice Observation Turn)
  | s =>
      if s = initial then
        some (Choice.action (emitTurn Actor.client submit) 1 afterSubmit)
      else if s = afterSubmit then
        some (Choice.action (emitTurn Actor.gateway dispatch) 2 afterDispatch)
      else if s = afterDispatch then
        some (Choice.chanceEvents
          [ { weight := 95, dwell := 4, value := (emitTurn Actor.worker resultOk, afterWorkerOk) }
          , { weight := 5, dwell := 4, value := (emitTurn Actor.worker resultFail, afterWorkerFail) }
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

def reviewPolicy : Observation -> Option (Choice Observation Turn)
  | s =>
      if s = initial then
        some (Choice.action (emitTurn Actor.client reviewSubmit) 1 reviewAfterSubmit)
      else if s = reviewAfterSubmit then
        some (Choice.action (emitTurn Actor.gateway reviewModerate) 1 reviewAfterDispatch)
      else if s = reviewAfterDispatch then
        some (Choice.chanceEvents
          [ { weight := 90, dwell := 3, value := (emitTurn Actor.worker reviewOk, reviewAfterWorkerOk) }
          , { weight := 10, dwell := 3, value := (emitTurn Actor.worker reviewReject, reviewAfterWorkerFail) }
          ])
      else if s = reviewAfterWorkerOk then
        some (Choice.action (emitTurn Actor.gateway reviewPosted) 1 reviewAfterReply)
      else if s = reviewAfterWorkerFail then
        some (Choice.action (emitTurn Actor.gateway reviewRejectClient) 1 reviewAfterReject)
      else if s = reviewAfterReply then
        some (Choice.action (emitTurn Actor.client reviewPosted) 1 reviewSucceeded)
      else if s = reviewAfterReject then
        some (Choice.action (emitTurn Actor.client reviewRejectClient) 1 reviewFailed)
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
  runPolicy 5 successPolicy [initialStats]

def reviewTerminalStats : List (PathStats Observation Turn) :=
  runPolicy 5 reviewPolicy [initialStats]

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

def statsMetrics (paths : List (PathStats Observation Turn)) : Metrics :=
  let total := paths.foldl (fun n path => n + path.mass) 0
  let ok := paths.foldl (fun n path => if isSucceeded path.state then n + path.mass else n) 0
  let latency := paths.foldl (fun n path => n + path.mass * path.elapsed) 0
  { successNum := ok, successDen := total, latencyNum := latency, latencyDen := total }

def purchaseMetrics : Metrics :=
  statsMetrics terminalStats

def reviewMetrics : Metrics :=
  statsMetrics reviewTerminalStats

def workerTerminalStats : List (PathStats Observation Turn) :=
  terminalStats ++ reviewTerminalStats

def workerMetrics : Metrics :=
  statsMetrics workerTerminalStats

def assembledGrammar : List Envelope :=
  authGrammar ++ workerGrammar

def allMessageBodiesParsed : Bool :=
  assembledGrammar.all fun e => protoWasParsed e.proto

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

def unauthenticatedAttemptCanBeRejected : CTL Observation :=
  CTL.ex (CTL.atom isUnauthorized)

def noSuccessWithoutAuth : CTL Observation :=
  CTL.ag (CTL.implies (CTL.neg (CTL.atom hasValidAuth)) (CTL.neg (CTL.atom isSucceeded)))

def actorQueuesSelectKnownTasks : CTL Observation :=
  CTL.ag (CTL.atom queuedMessagesSelectKnownTasks)

def terminalTasksAreCleanedUp : CTL Observation :=
  CTL.ag (CTL.implies (CTL.atom isTerminal) (CTL.atom fun s => s.task == none))

theorem initial_within_capacity :
    withinCapacity initial = true := by
  rfl

theorem initial_has_valid_auth :
    hasValidAuth initial = true := by
  rfl

theorem unauthenticated_initial_has_no_auth :
    hasValidAuth unauthenticatedInitial = false := by
  rfl

theorem all_listed_states_within_capacity :
    states.all withinCapacity = true := by
  rfl

theorem all_listed_states_select_known_tasks :
    states.all queuedMessagesSelectKnownTasks = true := by
  rfl

theorem all_listed_terminal_states_clean_tasks :
    states.all (fun s => if isTerminal s then s.task == none else true) = true := by
  rfl

theorem all_listed_message_bodies_are_parsed :
    allMessageBodiesParsed = true := by
  rfl

end LeanFM
