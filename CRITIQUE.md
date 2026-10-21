# Critique

This document records unresolved gaps where implementation supports less than
the book claims. A successful build alone does not resolve them.

### CTL implementation and temporal coverage remain bounded

Verified 2026-10-20: `LeanFM/CTL.lean` implements Boolean, EX/AX, EF/AF, EG/AG,
EU/AU and EW/AW; `CTLTests.lean` covers branching, vacuity, until/release and
AG/AF duals with `native_decide`. `TaskFSM.holds` supplies task results to the
executable and `/metrics`.

Still missing: derive bounded systems and witnesses/counterexamples from general
grammar/event models; prove checker/interpreter or deployed-code refinement; and
show `possibly` handlers cover every witness and terminate (validation only
requires a cited handling plan). Path-local cycle detection may be exponential
on shared graphs; validation and event-pair reconstruction use quadratic scans.
Bounded payloads, queues, tasks, clocks and truncation can hide growth, retry
loops or timing behavior; unbounded claims need an abstraction argument.

### Project-root discoverability and code-generation readiness

Fresh-session readiness is unverified: resume from durable specs, generate an
application, demonstrate grammar-conforming traces with increasingly realistic
in-project tests, and persist evidence under the root. Screenshots are not a gate.

## Book length and release reproducibility (reviewed 2026-10-20)

At 132 pages (`authoring-language.tex`: 769 lines), consolidate without losing
the preface-to-PR narrative or technical qualifications; because `book/main.pdf`
feeds code generation, verify deterministic rendering, tool-version/content
manifests, and no semantic diff after regeneration.

## The book's language and maturity claims exceed current implementation

Proposed forms (`scenario`, `declare`, `from_`, `to_`, `emit`, `receive`, exports,
`refineMessage`, role projection, symbolic encryption, `composeRoles`) lack
executable Lean definitions. The current API is `RequirementSpec`,
`TaskRequirement`, and `GrammarExpr`; guards are strings and event values are not
typed-bound. Validation checks grammar/task/message references, atom endpoints,
and threshold bounds, but cannot compile the DSL, generate or recognize traces,
or project participants.

Lean verifies only elaborated definitions and proofs; co-located Python,
JavaScript, shell, Graphviz, protobuf, and LaTeX outputs are not thereby proved.
`native_decide` covers finite decidable propositions, not empirical assumptions
or external parsers. CI should compile claimed executable listings, label
illustrative examples, and avoid treating polished figures or green builds as
stronger evidence. `LeanFM/Render.lean` hard-codes theorem-gallery cards rather
than reading declarations, risking drift and conflating definitions with
theorems. `RequiredProof` is not a proof term and its predicate is unchecked;
`lake env lean book/logic.lean` still fails without Mathlib. Generate cards from
declarations or a typed AST, linked to source and successful builds.

## The new visual gallery exposes derivation gaps

The SVG gallery is not event-derived: `interactionSvg` plots task transitions
in list order rather than `(session, scenario)` traces ordered by `priorIds`,
omitting choices/thresholds and misrendering `KVReplica -> KVReplica` as a
self-loop rather than leader/follower lifelines. `stateMachineSvg` draws a linear
chain without applying transition `src`/`dst`; latency and outcome SVGs use fixed
geometry, not event reducers. `/diagrams/` is Git-ignored, so README links are
not durable. Require typed `DesiredOutput` inputs, branch/loop/fork/join-sensitive
tests, and labels distinguishing requirement schema, example trace, observed
trace, or modeled prediction.

## Grammar-to-wire path and the Paxos example remain incomplete

The three-replica Paxos app has durable storage, browser UI, recovery/concurrency
tests and quorum, but lacks end-to-end conformance. Its requirement schema has
empty payloads; runtime uses a separate generic TCP `Envelope`, not bindings
generated from it. Requirements define a `ScenarioEvent.priorIds` quorum DAG,
but runtime `trace.Event` has no predecessors and `node.go` emits only terminal
`PutSucceeded`/`ListSucceeded`. The sink fills missing IDs/timestamps; events
identify endpoints, session and task but have no starts, so write, list,
concurrent-write and outage/recovery traces cannot be reconstructed. The modeled
outage/recovery lifecycle is not traced, and prepare is slot-scoped. Protocol tests
round-trip envelopes and reject truncated protobuf, but do not inject partial
TCP frames, loss, duplication, delay or reordering. `/metrics` exposes request
outcomes, commit latency and quorum size, not required availability, recovery
lag, queue pressure, memory headroom or per-session diagrams.

`scripts/roundtrip_generated_scenario.py` manually builds one `get_docs` scenario
from `LeanFM/LLMGenerated/Requirements.proto` and checks Python-protobuf equality
and predecessor IDs; it does not generate or recognize grammar traces. Tests
still need every `GrammarExpr` constructor and legal/illegal branch (including
`possibly`), decoded grammar/FSM acceptance, schema evolution, malformed input,
duplicate IDs, missing/cyclic predecessors and out-of-order events. The target is
`decode(encode(generate(grammar, choices)))`.

`LeanFM/PaxosKV/Requirements.proto`'s `ScenarioEvent` role (interoperable
requirement data or implementation choice) and evolution policy are undecided.
`RequirementEnvelope.oneof atom` selects a message, but branch disjointness is
unchecked; require disjoint terminal byte languages or explicit branch metadata.

## Event order, time and concurrency need stronger validation

Events are timestamped points: paired boundaries give durations; `priorIds`
orders events but does not assert causation. Paxos `scenarioOrderWellFormed`
checks unique IDs, message fields and links only to earlier serialized IDs.
General validation still needs to establish:

- whether properties depend on hidden state; instrument it, justify an
  abstraction, or mark the property undetermined;
- unique, valid start/terminal pairing across retries and overlapping
  `(session, task)` attempts;
- clock domain, resolution, monotonicity, overflow and cross-actor sync; valid
  predecessor IDs (including declared external IDs), acyclicity independent of
  serialization, and no edge backward in `timeAt`;
- actor/message endpoint agreement with selected terminals, valid grammar
  roots/terminals, and complete joins with valid $m$-of-$n$ thresholds and
  distinct branch IDs.

Also validate `dwellMs` against boundary times and define $m$-of-$n$ completion
ties, winner selection and cancellation. Partial-order width (incomparable
point events), active work (paired starts/completions), and feasible scheduling
(also actor capacity, queues and scheduler) are distinct measures.

## Runtime queue, population, reliability, and memory models remain limited

A finite FIFO models blocking send-on-full and receive-on-empty, but not waiter
sets or wake order, `select`, cancellation, deadlines, fairness, scheduler
semantics, queue/state-transition atomicity, or duplicate byte ownership.
`ImplementationSpec` names closed-channel `BoundedMailbox` operations, but no
executable mailbox exists; these semantics therefore do not establish Go-channel
behavior.

The model expands finite instance IDs and validates one resource contract per
actor specification, inherited by its instances. It omits dynamic lifecycle,
discovery, load balancing, and migration; the concrete 20-client/2-server sample
does not establish behavior at other scales.

`queue.pressure` integrates queue length in messages, not bytes. Even payload-byte
sums omit envelopes, allocator and queue storage, decoder state, retained and
transport buffers, actor state, duplicated payloads, and blocked tasks. A memory
budget must define wire bytes, owned heap, resident memory, or another reproducible
accounting model.

`Characterization.lean` records uptime, MTTR, composed-availability, and cascade
reducer plans; tests validate plan shape and names, not their calculations. The
book's policies for censored intervals, joint failures, and outage boundaries
lack corresponding executable reducer tests.

## Probability and statistical evidence need explicit assumptions

Probability fields are rational numbers without a typed evidence kind, so
empirical frequencies, assumed distributions, unresolved nondeterminism, policy
choices, and epistemic uncertainty remain easy to conflate.

The seeded 81,039-line bakery corpus exercises the reducer pipeline but describes
synthetic data, not real behavior. Its summaries lack confidence intervals,
sensitivity/stationarity checks, and treatment of censored in-flight tasks.

`StreamStats` computes client-weighted and server-window work rates, and tests
USL curves for supplied parameters; it has no parameter-fitting or fit-uncertainty
estimator. Rates use completed, explicitly paired observations, so omitted,
unfinished or failed work can bias results. Warm-up, client think time, and
changing populations also need declared policies.

## Structural validation does not prove intent or generated conformance

Validators check typed structure, actor/message coverage, and known
justification IDs; they do not establish user intent or generated
symbol-to-test conformance. Require stable fine-grained IDs, bidirectional
coverage, behavioral trace tests, and classification of handwritten code as
requirement-justified or infrastructure. Human review must still catch
misstated assumptions, trust boundaries, failure alternatives, cost models,
probability provenance, and observability; generated prose must not invent
facts. The accepted `custom "unassigned" ""` fallback can conceal a missing
transport mapping.

Generic `TransportSpec` records an HTTP request's method/path or the request
message named by a response; its validator checks only nonempty method/path and
that the response target is any known message, not that it is an HTTP request.
The ChatUI contract now specifies status/content-type/codecs and
one-to-one event `cause_id` closure, and its implementation mapping describes
OpenAPI, but validation and tests do not prove every binding against runtime
handlers. The generic transport mapping has no fields for authentication,
deadlines, headers, streaming, retries/idempotency, connection reuse,
intermediaries, redirects, cancellation, or status alternatives, and has no
binding-level validation for them.

Generation from the book, specifications, and existing code reduces transcript
dependence, not variance. Pin model, prompt, tools, and sampling; review diffs
and behavior. Characterize-and-synthesize accepts only agreement on its named
finite metrics; matching latency, throughput, uptime, or histograms does not
establish agreement on burstiness, tail dependence, predecessor order, rare
failures, or operational risk. Specify tolerances, sample sizes, seeds, and
distributional tests.

## Security knowledge is not yet a complete epistemic model

The book sketches, but does not implement, a Dolev–Yao `Derives` relation for
initial terms, tuples/projection, and perfect encryption/decryption, plus CTL
checks over its closure. Completeness still needs explicit rules and trust
boundaries for signatures, hashes, randomness, compromise, browser scripting,
logs/caches, and side channels. This symbolic model is not a computational
cryptographic proof.
