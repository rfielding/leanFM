[Read the LeanFM PDF book](book/main.pdf)

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
- an end message of any kind may backpoint to its start message, so overlapping attempts are paired by event identity
- actor specifications are reusable; each finite population is a homogeneous service cluster whose instances share one actor kind and whose routing is declared as sticky, round-robin, or shard-key hash
- non-functional rates distinguish client-experienced `sum(work)/sum(observationTime)` from server aggregate `sum(work)/(max(end)-min(start))`; either can be plotted by client count for USL fitting
- actor reliability contracts specify outage probability and expected MTTR; synchronized `Unavailable`/`Recovered` intervals produce per-instance uptime, series/parallel/k-of-n composed service uptime, MTTR, and fixed-point failure-cascade reports across declared dependency gates
- denial-of-service analysis ranks dependency nodes with a declared PageRank-like centrality, then checks that heuristic against minimal cut sets, quorum thresholds, stopped protocol messages, fixed-point cascades, lost task capacity, and client-visible outcomes
- the LLM requirements interviewer plans derived properties before fixing fields; each sufficiently identified `(session, scenario)` produces its own interaction diagram and state machine plus planned line and pie/histogram derivatives
- the baseline derived-property catalog covers latency, throughput, outcomes, queues, concurrency, reliability, infrastructure cost and least-cost supply for declared demand, financial flows (including taxes and profit/loss under a declared boundary), and waste units/cost/rate; missing inputs are marked indeterminate rather than invented
- load-derived outputs include observed and fitted Universal Scalability Law curves, queue length paired with explicitly related latency boundaries, per-instance memory headroom with exhaustion treated as fatal, and outage impact propagated across actor interaction networks
- every scalar metric, 2D function rendering, interaction diagram, and state machine preserves the originating prompt, the question being answered, and the event reducer; `/metrics` exports durable output IDs alongside event-informed numeric series
- synthesized similar streams are decoded and replayed through the same named reducers, with exact-ratio comparisons against declared tolerances
- stateless code generation uses `(book/main.pdf, Requirements.lean, Implementation.lean, Requirements.proto) -> actual code`; revision adds the existing source tree as an input and never relies on prior chat history
- every generated code unit carries a requirement ID and justification; implementation validation rejects actor, message, or channel mappings with no durable requirement reference
- unlike an explicit-variable state model, LeanFM primarily recognizes and generates observable event traces; protocols and persistent disk formats tend to live forever as compatibility boundaries, while internal software structure changes more chaotically and introduces a much larger state space to explore, so private implementation variables are omitted unless they change an observable requirement
- `Requirements.lean`, `Requirements.proto`, and `Implementation.lean` are the durable memory of the requirements argument, so a new LLM session does not require the original conversation
- generated scenarios round-trip through protobuf bytes without losing `prior` predecessor links; these links induce a partial order in which incomparable concurrent events may commute, but do not alone assert causation
- correlated event streams estimate task completion probability and completed-task latency
- scenarios may carry a parallel protobuf alphabet for concrete wire bytes
- a BNF surface composes named interactions by sequence, choice, parallelism, guards, and references
- explicit `mOfN` threshold joins record both the declared threshold and the concrete branch-terminal IDs that satisfied each join
- a grammar choice resolves at the first distinguishing byte-level terminal; that terminal's source identifies the observable decision-maker, so choices do not carry a separate chooser label
- components can be built independently and assembled into larger systems
- CTL formulas run over the support graph
- LeanFM uses CTL rather than LTL for executable branching checks: LTL's always/eventually describe positions along one path, while CTL combines them with `A`/`E`, read here as necessarily/possibly over legal forward continuations
- declaring a condition `possibly` reachable means the system is prepared for it: the requirement needs a witness branch and handling plan, and implementation code must cite that possibility
- non-vacuous strong implication is `EF p ∧ AG(p → q)`; unlike weak material implication, it requires a reachable antecedent witness and a necessary temporal relationship to the consequent
- `p AW q` and `p EW q` are weak-until operators: `q` may never occur when `p` persists forever on every path or some path, respectively

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
make go-toolchain # install the checksum-pinned Go toolchain under .toolchains/
make check       # build, evaluate generated requirement validation, and emit diagrams
make serve       # run the web server on 127.0.0.1:8080
make chatui-check # deterministic BYOK ChatUI bootstrap and isolation test
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

`PROJECT_CHAT_EXAMPLE.md` is a complete example requirements chat in which a
user creates one project as an inter-related set of interaction grammars. It
shows grammar references, shared correlation fields, and prompt-derived scalar,
2D, interaction-diagram, and state-machine outputs.

The Lean HTTP server listens on:

```text
http://127.0.0.1:8080

The root URL is the LeanFM ChatUI. On first use, create an account with a
username, password, and your own OpenAI API key, then create the first project.
The server needs no `OPENAI_API_KEY`; it will not issue a model request without
an authenticated user's verified credential. Account data defaults to `data/`
and can be relocated with `LEANFM_DATA_ROOT`.
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
GET /tools/leanfm-language/reference authoritative LeanFM language reference for requirement-generation tools
GET /tools/leanfm-language/requirements-reference authoritative RequirementSpec, protobuf, grammar, logic, and output reference
GET /tools/leanfm-language/implementation-reference authoritative ImplementationSpec, transport, channel, and traceability reference
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
GET /api/session/generated/implementation.lean current session's implementation specification, falling back to the built-in example
POST /api/session/generated/implementation.lean replace the current session's implementation specification
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

## Three-replica Paxos key/value example

Build and verify the accepted Paxos requirements, implementation mapping,
protobuf framing, durable recovery, concurrent sessions, and web UI:

```sh
make paxos-check
go build -o /tmp/paxos-kv ./cmd/paxos-kv
```

Start the replicas in separate terminals (use a different durable directory for
each), then start the web application:

```sh
PEERS='kv-0=127.0.0.1:9100,kv-1=127.0.0.1:9101,kv-2=127.0.0.1:9102'
/tmp/paxos-kv replica -id kv-0 -addr 127.0.0.1:9100 -peers "$PEERS" -data ./data/kv-0
/tmp/paxos-kv replica -id kv-1 -addr 127.0.0.1:9101 -peers "$PEERS" -data ./data/kv-1
/tmp/paxos-kv replica -id kv-2 -addr 127.0.0.1:9102 -peers "$PEERS" -data ./data/kv-2
/tmp/paxos-kv web -addr 127.0.0.1:8088 -replicas 127.0.0.1:9100,127.0.0.1:9101,127.0.0.1:9102
```

Open `http://127.0.0.1:8088/` in two browser sessions. Prometheus metrics are
at `/metrics`; generated requirement diagrams are `diagrams/paxos-*.dot` and
`diagrams/paxos-*.png`.

Generated files:

```text
diagrams/auth.dot
diagrams/worker.dot
diagrams/assembled.dot
```

The web UI retains interactive `<canvas>` views, but `/renders/` now primarily
shows ordinary SVG files generated from typed Lean requirements: UML-style
interaction diagrams per scenario, message-passing state machines, line graphs,
and pie charts. Each image has a standalone `/renders/<name>.svg` route and is
also emitted under `diagrams/` by `make diagrams`.

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
