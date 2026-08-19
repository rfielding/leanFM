Lean Formal Methods, based on communicating heirarchial processes.
=======
# LeanFM

A tiny Lean 4 formal-methods sketch for message-passing processes.

The model treats a protocol as globally observable behavior:

- each actor has its own observable local state machine
- every actor has exactly one observable input queue
- each queue has a fixed capacity
- actors take scheduled turns and run at most one step per turn
- messages are globally visible byte envelopes
- each envelope carries `src`, `dst`, and protocol `bytes`
- the global graph is the product observation of actor states
- optional chance nodes support MDP-style probabilistic outcomes
- dwell time supports expected latency, throughput, and queue metrics
- components can be built independently and assembled into larger systems
- CTL formulas run over the support graph

Run it with:

```sh
lake exe leanfm
```

Serve it with:

```sh
lake exe leanfm-server
```

The Lean HTTP server listens on:

```text
http://127.0.0.1:8080
```

Endpoints:

```text
GET /          HTML report
GET /metrics   plain-text report
GET /graph.dot Graphviz DOT
GET /auth.dot  auth group DOT
GET /assembled.dot assembled-system DOT
GET /diagrams/auth.svg rendered auth diagram
GET /diagrams/worker.svg rendered worker diagram
GET /diagrams/assembled.svg rendered assembled-system diagram
GET /health    health check
```

Generate the diagrams without starting the server:

```sh
lake exe leanfm-diagrams
```

Generated files:

```text
diagrams/auth.dot
diagrams/auth.svg
diagrams/worker.dot
diagrams/worker.svg
diagrams/assembled.dot
diagrams/assembled.svg
```

The current example has three actors:

```text
Client
Gateway
Worker
```

It also includes a separate two-actor authorization group:

```text
Auth
DB
```

The executable assembles the two-actor group and the three-actor group by concatenating their globally visible message grammars and composing their metric summaries.

Two-actor auth group grammar:

```text
Auth->DB:[10 1]
DB->Auth:[10 2]
DB->Auth:[10 255]
```

Three-actor worker group grammar:

```text
Client->Gateway:[1 16]
Gateway->Worker:[2 32]
Worker->Gateway:[3 48]
Worker->Gateway:[3 255]
Gateway->Client:[4 64]
Gateway->Client:[255]
```

Because the source is part of every message, an actor can reply to the sender by constructing a new envelope with its own `src` and the previous sender as `dst`.

The executable prints:

- the byte-level message grammar
- observable actor-state and queue transitions
- MDP choices with weights and dwell times
- a time-weighted queue-length distribution
- globally visible terminal traces
- expected latency, success probability, and throughput
- Graphviz DOT for the state machine
- CTL results from the initial observation

Queue semantics:

```text
write to non-full queue: enqueue at dst
write to full queue: scheduled actor sleeps
read from non-empty queue: scheduled actor consumes one message
read from empty queue: scheduled actor sleeps
wake condition: the actor's queue becomes non-empty
```

Worker group capacities:

```text
Client queue capacity: 1
Gateway queue capacity: 2
Worker queue capacity: 1
```

Example metrics:

```text
auth group success probability: 98/100 ~= 0.98
auth group expected latency: 400/100 ~= 4.00
worker group success probability: 95/100 ~= 0.95
worker group expected latency: 900/100 ~= 9.00
assembled system success probability: 9310/10000 ~= 0.93
assembled system expected latency: 12820000/1000000 ~= 12.82
assembled system throughput: 9310000000/128200000000 ~= 0.07
```

For sequential composition, the current metric rule is:

```text
P(success A;B) = P(success A) * P(success B)
E(latency A;B) = E(latency A) + P(success A) * E(latency B)
throughput A;B = P(success A;B) / E(latency A;B)
```

The standalone three-actor worker metrics are:

```text
expected latency: 900/100 ~= 9.00
success probability: 95/100 ~= 0.95
throughput: 95/900 ~= 0.10
```

The graph deliberately excludes private variables. Internal counters, retries, queues, and timers should only appear if they change an actor's observable state, a globally visible message, a probability, or a dwell time.
