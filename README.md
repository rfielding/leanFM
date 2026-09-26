Lean Formal Methods, based on communicating heirarchial processes.
=======
# LeanFM

A tiny Lean 4 formal-methods sketch for message-passing processes.

The model treats a protocol as globally observable behavior:

- each actor has its own observable local state machine
- every actor has distinct observable inbound and outbound queues
- both queues have fixed capacities
- messages are correlated by a `(session, task)` key
- an actor may have multiple `(session, task)` conversations in flight
- actors take scheduled turns and run at most one step per turn
- messages are globally visible byte envelopes
- every message event has a shared monotonic-clock timestamp for latency calculations
- each envelope carries `src`, `dst`, and protocol `bytes`
- the global graph is the product observation of actor states
- optional chance nodes support MDP-style probabilistic outcomes
- specifications attach dwell durations to transitions or productions
- dwell advances the event clock and supports latency, throughput, and queue metrics
- each event has one `timeAt`; latency is computed between separate start and completion messages
- generated scenarios round-trip through protobuf bytes without losing causal `prior` links
- correlated event streams estimate task completion probability and completed-task latency
- scenarios may carry a parallel protobuf alphabet for concrete wire bytes
- a BNF surface composes named interactions by sequence, choice, parallelism, guards, and references
- a grammar choice resolves at the first distinguishing byte-level terminal; that terminal's source identifies the observable decision-maker, so choices do not carry a separate chooser label
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

Common development commands:

```sh
make check       # build, evaluate generated requirement validation, and emit diagrams
make serve       # run the web server on 127.0.0.1:8080
make http-check  # validate live server routes after make serve
make stop        # stop the process listening on PORT, default 8080
make book        # build the LaTeX book, bibliography, contents, and index
make bakery-data # deterministically regenerate 20,000 bakery order traces
make bakery-stats # stream the bakery JSONL and derive probabilities/latencies
```

The book source is in `book/`; its rendered PDF is `book/main.pdf` after a
successful build. Use `make book-clean` to remove generated LaTeX artifacts.

The large quantitative example is `examples/bakery-events.jsonl`: 20,000 bakery
orders represented as a stream of fork/join events. `examples/bakery-stats.json`
contains reductions calculated from that file. See `BAKERY_SCENARIO.md` for the
grammar and data contract. Quantitative examples should read this corpus or a
reduction reproducibly derived from it instead of embedding invented percentages.

The Lean HTTP server listens on:

```text
http://127.0.0.1:8080
```

Endpoints:

```text
GET /          clean assistant workbench
GET /examples  sample dashboard with charts, graphs, and generated sources
GET /renders/  built-in canvas diagram renders
GET /metrics   Prometheus metrics
GET /openapi.yaml OpenAPI description of LeanFM routes and generated message schemas
GET /report    generated plain-text report
GET /tools/conversations conversation-to-Lean-file catalog
GET /tools/static-assets/validate static JavaScript renderer validation
GET /tools/generated-requirements/prompt LLM system prompt for generated requirements
GET /tools/llm-generated/requirements/prompt canonical LLM system prompt route
GET /tools/generated-requirements/validate generated typed Lean requirement validation
GET /tools/llm-generated/requirements/validate canonical LLM-generated requirement validation route
GET /tools/llm-generated/implementation/validate validates the separate software-generation plan
GET /tools/generated-artifacts/validate validates requirements and implementation together
GET /tools/aggregate-graph/validate typed aggregate graph data validation
GET /api/session current authenticated workspace id and per-session artifact links
GET /api/session/generated/requirements.lean current session's generated Lean file, falling back to the built-in example
POST /api/session/generated/requirements.lean replace the current session's generated Lean file
GET /api/session/generated/requirements.proto current session's generated protobuf file, falling back to the built-in example
POST /api/session/generated/requirements.proto replace the current session's generated protobuf file
GET /generated/worker.proto protobuf schema generated from requirement messages
GET /llm-generated/requirements.proto canonical LLM-generated protobuf schema
GET /lean/get_docs.lean generated Lean view for a conversation
GET /graph.dot Graphviz DOT
GET /auth.dot  auth group DOT
GET /assembled.dot assembled-system DOT
GET /health    health check
```

Export DOT sources without starting the server:

```sh
lake exe leanfm-diagrams
```

Run generated requirement validation without starting the server:

```sh
lake exe leanfm-validate
```

Generated files:

```text
diagrams/auth.dot
diagrams/worker.dot
diagrams/assembled.dot
```

The web UI renders diagrams with `<canvas>` from explicit Lean data serialized to JSON and consumed by constant JavaScript renderers. It does not serve SVG or PNG image files.

`LeanFM/LLMGenerated/Requirements.lean`, `Requirements.proto`, and `Implementation.lean` are the generated artifacts. `Requirements.lean` describes observable behavior; the proto file describes values that resolve to bytes. Neither chooses a transport. `Implementation.lean` separately chooses the target language, files, runtime APIs, and how each protobuf message is carried—for example an HTTP request with a method and path, an HTTP response, an in-process channel, TCP, or a custom adapter. Validation requires the implementation plan to cover every required actor and message without redefining the requirement. Everything outside `LeanFM/LLMGenerated/` is static committed DSL/runtime code.

Generated requirements are rejected as vacuous unless tasks involve multiple actors, message transitions, terminal states, temporal/property annotations, multiparty grammars, required proof obligations, and per-actor process send/receive coverage for each transition.

Worked design examples:

- `BROWSER_SERVER_OAUTH.md` shows a browser/server/OAuth actor set.
- `MULTIPARTY_GRAMMAR_EXAMPLE.md` shows the CFG-like multiparty grammar style.
- `LARGE_FILE_POLICY_SERVER.md` shows a JWT, OpenAPI, huge-file upload/download, and OPA/Rego policy server with manager handoff.

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
produce with outbound space: enqueue at src outbound
produce with outbound full: producing actor sleeps
transport with destination inbound space: move outbound head to dst inbound
transport with destination inbound full: transport blocks
receive from non-empty inbound: consume and dispatch by (session, task)
receive from empty inbound: receiving actor sleeps
try-receive from empty inbound: return none immediately; actor remains runnable
wake condition: the queue needed by the blocked step has capacity or data
```

Worker group capacities:

```text
Client inbound/outbound capacity: 1/1
Gateway inbound/outbound capacity: 2/2
Worker inbound/outbound capacity: 1/1
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
