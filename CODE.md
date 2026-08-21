# Code Walkthrough

This project is a Lean 4 model of message-passing processes. The core idea is to describe only observable behavior: actor states, actor queues, messages, probabilities, dwell times, and task-level state machines. Internal implementation variables are intentionally left out. That keeps the model graphable as finite state machines and makes CTL model checks practical.

The repo has four main layers:

- `LeanFM/MDP.lean`: generic nondeterministic/probabilistic transition machinery.
- `LeanFM/CTL.lean`: generic CTL formulas and finite graph evaluation.
- `LeanFM/Protocol.lean`: the actual actor/message/task model.
- `LeanFM/Render.lean`, `Server.lean`, and `Main.lean`: reports, Graphviz, canvas visualizations, and the local web server.

## The Generic State Model

`LeanFM/MDP.lean` defines the reusable execution model.

```lean
structure Weighted (α : Type) where
  weight : Nat
  dwell : Nat
  value : α
```

A weighted value represents a probabilistic branch and how long that branch dwells. Probabilities are stored as integer weights instead of floats. For example, a 95/5 split is represented as two outcomes with weights `95` and `5`. Dwell time is also an integer, currently an abstract time unit.

```lean
inductive Choice (S A : Type) where
  | action : A -> Nat -> S -> Choice S A
  | chance : A -> List (Weighted S) -> Choice S A
  | chanceEvents : List (Weighted (A × S)) -> Choice S A
```

`Choice` is the transition shape:

- `action` is deterministic: one action, one dwell time, one next state.
- `chance` is probabilistic after one shared action.
- `chanceEvents` is probabilistic where each branch can have its own action and next state.

The protocol uses `chanceEvents` for places where the next visible message differs by outcome, such as a worker producing either `Docs.FetchResult 200` or `Docs.FetchResult 404`.

```lean
structure MDP (S A : Type) where
  choices : S -> List (Choice S A)
```

An MDP is a function from a state `S` to possible choices. This supports both nondeterminism and probability. Nondeterminism is represented by multiple available `Choice`s from the same state. Randomness is represented inside a `Choice` by weighted outcomes. This matches the project design: randomness is a way to underspecify behavior, not a hidden variable.

For metrics, the important structure is:

```lean
structure PathStats (S A : Type) where
  mass : Nat
  scale : Nat
  lastDwell : Nat
  elapsed : Nat
  state : S
  trace : List A
```

`PathStats` tracks a symbolic probability mass, total probability scale, elapsed dwell time, the current observable state, and the ordered trace of actions/messages. This is how the model gets expected latency, throughput, terminal traces, and queue length distributions.

`runPolicy` executes a selected policy for a fixed amount of fuel:

```lean
def runPolicy {S A : Type} (fuel : Nat) (policy : S -> Option (Choice S A))
    (paths : List (PathStats S A)) : List (PathStats S A)
```

A policy chooses one `Choice` at each state. This is useful when computing expected metrics for a particular scenario, such as a successful attempt at `get_docs` or `post_review`.

## CTL

`LeanFM/CTL.lean` defines Computation Tree Logic over a finite state graph.

```lean
inductive CTL (S : Type) where
  | atom : (S -> Bool) -> CTL S
  | neg : CTL S -> CTL S
  | and : CTL S -> CTL S -> CTL S
  | or : CTL S -> CTL S -> CTL S
  | ex : CTL S -> CTL S
  | ax : CTL S -> CTL S
  | ef : CTL S -> CTL S
  | af : CTL S -> CTL S
  | eg : CTL S -> CTL S
  | ag : CTL S -> CTL S
```

The evaluator is:

```lean
partial def holds [DecidableEq S] (succ : S -> List S) (s : S) : CTL S -> Bool
```

It takes a successor function, a starting state, and a formula. The CTL implementation works over explicitly listed finite states. It uses visited-state lists to terminate on cycles.

The most useful operators in this project are:

- `EX p`: some immediate successor satisfies `p`.
- `EF p`: some reachable state eventually satisfies `p`.
- `AF p`: all paths eventually satisfy `p`.
- `AG p`: all reachable states satisfy `p`.

Examples from `Protocol.lean`:

```lean
def taskTerminates : CTL Observation :=
  CTL.af (CTL.atom isTerminal)

def taskCapacitySafe : CTL Observation :=
  CTL.ag (CTL.atom withinCapacity)

def noSuccessWithoutAuth : CTL Observation :=
  CTL.ag (CTL.implies (CTL.neg (CTL.atom hasValidAuth)) (CTL.neg (CTL.atom isSucceeded)))
```

These are evaluated either against the whole worker MDP or against per-task FSMs.

## Messages and Protobuf-Like Payloads

The protocol layer starts by defining visible actors and messages.

```lean
inductive Actor where
  | auth
  | db
  | client
  | gateway
  | worker

inductive TaskKind where
  | purchaseItem
  | postReview
  | auth
```

The current task names render as:

- `purchaseItem` -> `get_docs`
- `postReview` -> `post_review`
- `auth` -> `auth`

Every protocol message is an `Envelope`:

```lean
structure Envelope where
  task : TaskKind
  src : Actor
  dst : Actor
  transport : Transport
  proto : ProtoPayload
  ts : Nat
```

This is the wrapper around a protobuf-like message body. The wrapper carries sequencing information: task, source actor, destination actor, transport, and timestamp. The payload carries the message type, bytes, and parsed fields.

```lean
structure ProtoPayload where
  typeName : String
  summary : String
  bytes : List Nat
  fields : List ProtoField
```

`parseProtoFields` is a small hand-written parser for the sample protocol bytes. In a real system this would be replaced by actual protobuf parsing or generated schema metadata. The important design point is the separation:

- clients can exchange protobuf bytes;
- the proof/model layer wraps those bytes with valid-sequence constraints;
- visualization and CTL use the wrapper and parsed fields.

The model includes messages for:

- authentication: `Auth.LookupRequest`, `Auth.LookupResponse`;
- docs fetch: `Docs.GetRequest`, `Docs.FetchCommand`, `Docs.FetchResult`, `Docs.GetResponse`;
- review posting: `Reviews.PostRequest`, `Reviews.ModerateCommand`, `Reviews.ModerationResult`, `Reviews.PostResponse`;
- failure: `Error.Response`.

## Turns, Blocking, and Actor Queues

An actor is scheduled for one turn at a time.

```lean
structure Turn where
  actor : Actor
  emitted : Option Envelope
  blocked : Option BlockReason
```

A turn either emits a globally visible message or records that an actor slept.

```lean
inductive BlockReason where
  | readEmpty
  | writeFull
```

This models the queue rules:

- every actor has one queue;
- queues have capacity;
- an actor sleeps on read from empty;
- an actor sleeps on write into full.

The sample worker-world queue capacities are defined by:

```lean
def cap (a : Actor) : Nat :=
  match a with
  | Actor.client => 1
  | Actor.gateway => 2
  | Actor.worker => 1
  | _ => 0
```

The observable worker-world state is:

```lean
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
```

This is deliberately not an implementation state. It contains only visible things:

- current task, if any;
- observable actor states;
- queue lengths;
- queue heads;
- auth proof artifact.

`withinCapacity` checks queue capacities, and CTL uses it to prove/check that all reachable states stay within declared bounds.

## Authentication

Authentication is modeled as its own smaller component over `AuthObservation`.

```lean
structure AuthObservation where
  auth : ActorState
  authQ : Nat
  db : ActorState
  dbQ : Nat
  proof : Option AuthProof
```

The auth component has two actors, `Auth` and `DB`, each with capacity 1. Its successful terminal state produces:

```lean
def loginProof : AuthProof :=
  { issuedBy := Actor.auth, issuedTo := Actor.client, bytes := [0xa0, 0x01] }
```

The success probability is encoded in `authChoices`:

```lean
Choice.chanceEvents
  [ { weight := 98, dwell := 2, value := (emitTurn Actor.db authOk, authAfterOk) }
  , { weight := 2, dwell := 2, value := (emitTurn Actor.db authFail, authAfterFail) }
  ]
```

The aggregate graph visual starts in `unauthorized`, transitions through auth, and reaches `authenticated session` when `Auth.LookupResponse ok` is observed. Worker operations require a valid auth proof:

```lean
def hasValidAuth (s : Observation) : Bool :=
  s.proof == some loginProof
```

The property:

```lean
def noSuccessWithoutAuth : CTL Observation :=
  CTL.ag (CTL.implies (CTL.neg (CTL.atom hasValidAuth)) (CTL.neg (CTL.atom isSucceeded)))
```

says that no reachable unauthenticated state is a successful terminal state.

## Worker Tasks

The worker world has three actors:

- `Client`
- `Gateway`
- `Worker`

Each actor can participate in both tasks:

- `get_docs`
- `post_review`

Task selection is message-driven:

```lean
def selectTaskFromMessage (actor : Actor) (msg : Envelope) : Option TaskKind :=
  if msg.dst = actor && actorAcceptsTask actor msg.task then
    some msg.task
  else
    none
```

This means an actor chooses the relevant task machine from the message at the head of its queue. The CTL predicate `actorQueuesSelectKnownTasks` checks that queued message heads select known actor tasks.

The task machines declare accepted and emitted messages:

```lean
structure TaskMachine where
  owner : Actor
  task : TaskKind
  accepts : List Envelope
  emits : List Envelope
```

For example, `gatewayPurchaseTask` accepts client requests and worker results, then emits worker commands or client responses. `workerPurchaseTask` accepts fetch commands and emits success or failure results.

## The Global Transition Relation

`choices : Observation -> List (Choice Observation Turn)` is the worker-world transition relation.

From `initial`, the client may start either task:

```lean
if s = initial then
  [ Choice.action (emitTurn Actor.client submit) 1 afterSubmit
  , Choice.action (emitTurn Actor.client reviewSubmit) 1 reviewAfterSubmit
  , Choice.action (sleepRead Actor.gateway) 1 initial
  , Choice.action (sleepRead Actor.worker) 1 initial
  ]
```

This is nondeterminism: multiple possible choices from the same state.

From a worker-processing state, the model uses chance events. For `get_docs`:

```lean
Choice.chanceEvents
  [ { weight := 95, dwell := 4, value := (emitTurn Actor.worker resultOk, afterWorkerOk) }
  , { weight := 5, dwell := 4, value := (emitTurn Actor.worker resultFail, afterWorkerFail) }
  ]
```

For `post_review`:

```lean
Choice.chanceEvents
  [ { weight := 90, dwell := 3, value := (emitTurn Actor.worker reviewOk, reviewAfterWorkerOk) }
  , { weight := 10, dwell := 3, value := (emitTurn Actor.worker reviewReject, reviewAfterWorkerFail) }
  ]
```

The important point is that probabilities and dwell time are both part of the observable transition relation. This is what lets the model compute latency, throughput, and queue length distributions.

The explicit graph is generated from:

```lean
def transitions : List (Observation × Turn × Observation) :=
  (states.map fun s =>
    (choices s).flatMap fun c =>
      (Choice.labeledSupport c).map fun step => (s, step.1, step.2)).flatten
```

That list is used for reports and Graphviz state diagrams.

## Per-Task FSMs

CTL properties should be run per task, so `Protocol.lean` defines `TaskFSM`:

```lean
structure TaskFSM where
  task : TaskKind
  entry : Observation
  states : List Observation
  transitions : List (Observation × Turn × Observation)
```

Each task has its own state list and policy-derived transitions:

```lean
def purchaseTaskFSM : TaskFSM := ...
def reviewTaskFSM : TaskFSM := ...
```

The per-task CTL checks include:

- `AF terminal`: all paths through the task eventually reach a terminal state.
- `EF success`: some path can succeed.
- `EF failure`: some path can fail.
- `AG capacity`: all reachable task states respect queue capacity.
- `AG terminal states clean up active task`: terminal task states have `task = none`.

These checks are reported in `/metrics` and in the command-line output from:

```sh
lake exe leanfm
```

## Metrics

Metrics are computed from `PathStats` paths.

```lean
structure Metrics where
  successNum : Nat
  successDen : Nat
  latencyNum : Nat
  latencyDen : Nat
```

Throughput is derived:

```lean
def Metrics.throughputNum (m : Metrics) : Nat :=
  m.successNum * m.latencyDen

def Metrics.throughputDen (m : Metrics) : Nat :=
  m.successDen * m.latencyNum
```

In plain terms:

- success probability is weighted successful terminal mass over total terminal mass;
- expected latency is weighted elapsed dwell time over terminal mass;
- throughput is success probability divided by expected latency.

Metrics are computed for:

- auth group;
- `get_docs`;
- `post_review`;
- worker group;
- assembled system.

Sequential composition is handled by:

```lean
def composeSequential (a b : Metrics) : Metrics := ...
```

This composes auth and worker metrics into assembled-system metrics. The semantics are: run component `a`, and on success proceed to component `b`.

Queue length distribution is computed by sampling path states and weighting by dwell:

```lean
def queueLengthTimeDistribution : List (Nat × Nat) :=
  bucketScaledMass terminalMass queueLength queueLengthSamples
```

That produces a time-weighted distribution over total queue length.

## Rendering and Reports

`LeanFM/Render.lean` converts the Lean model into text, Graphviz DOT, HTML, and JavaScript/canvas visualizations.

Important report helpers:

- `stateName`: full observable state.
- `compactStateName`: compact multiline graph label.
- `turnName`: full scheduled actor action.
- `compactTurnName`: edge label for diagrams.
- `textReport`: full command-line and `/metrics` report.

Graphviz outputs include:

- auth group;
- worker overview;
- per-task `get_docs`;
- per-task `post_review`;
- task conversation summary;
- assembled system.

The web page adds canvas visualizations:

- Traffic animation: messages moving between actor boxes.
- Interaction diagrams by task: per-task lifeline views over the same actor set.
- Configurable charts: line/pie charts chosen from datasets.
- Aggregate graph: interactive hierarchical task/state visualization.

## Configurable Charts

The Charts section is intentionally moving toward "dataset = function of ordered messages".

`Render.lean` currently emits an `orderedMessages` JavaScript array. Each message includes:

- task;
- source actor;
- destination actor;
- protobuf type;
- byte count;
- timestamp.

Chart datasets are then defined as functions over `orderedMessages`, for example:

- cumulative bytes over ordered messages;
- messages by task;
- messages sent by actor;
- task elapsed from message timestamps.

There are also model-derived datasets:

- queue length distribution;
- success/failure probability;
- task success rates;
- expected latency and throughput.

Each chart slot can be rendered as either a line chart or a pie chart. The chart choice is presentation; the dataset is the real model artifact.

## Web Server

`Server.lean` is a small Lean-native HTTP server using `Std.Internal.Async.TCP`.

It binds to:

```lean
127.0.0.1:8080
```

Routes include:

- `/`: HTML UI.
- `/login`: built-in login form.
- `/metrics`: Prometheus metrics.
- `/report`: plain text report.
- `/tools/conversations`: conversation catalog mapping each conversation to a unique generated Lean file.
- `/lean/*.lean`: generated Lean source views for conversations.
- `/*.dot`: DOT sources.
- `/health`: health check.

The server does not serve SVG or PNG assets. The UI renders diagrams with canvas from data built into the binary. Tool catalogs, Markdown docs, DOT sources, generated Lean source views, and metrics are served directly from Lean constants.

All routes except `/login` and `/health` require the local session cookie set by the login form. The default password is `leanfm`; set `LEANFM_PASSWORD` before launch to override it.

Run it with:

```sh
lake exe leanfm-server
```

Run the text report with:

```sh
lake exe leanfm
```

## What Lean Provides Here

Lean is not just being used as a programming language. It gives the model a single language for:

- executable specification;
- algebraic data types for states/messages/tasks;
- finite graph generation;
- CTL formulas;
- probability and dwell-time metric computation;
- simple proof artifacts and theorems.

The current explicit theorems are small but useful smoke checks:

```lean
theorem initial_within_capacity :
    withinCapacity initial = true := by
  rfl
```

These prove by definitional reduction that listed model facts are true. More serious future proofs could establish stronger invariants, such as "all generated states are within capacity" from construction rules rather than from an enumerated list.

The immediate value is that the model is executable and inspectable. The same definitions feed:

- CTL checks;
- metrics;
- DOT diagrams;
- canvas state graphs;
- interaction diagrams;
- chart datasets.

That keeps the formal model and the visualization from drifting apart.

## Current Limitations and Next Directions

The model is still a prototype. Current limitations are intentional simplifications:

- protobuf parsing is sample-specific and hand-written;
- state spaces are enumerated manually;
- chart datasets are emitted in JavaScript, though they should eventually be produced from Lean traces;
- interaction diagrams are currently hardcoded from the sample tasks;
- some CTL checks are evaluated over explicit task FSMs rather than generated task machines.

Good next steps:

- generate ordered message streams from `PathStats.trace`;
- derive interaction diagrams directly from `Envelope` traces;
- make task FSM generation depend on `TaskMachine` definitions;
- move chart dataset construction into Lean;
- add stronger Lean theorems about capacities, authentication, and terminal cleanup.
