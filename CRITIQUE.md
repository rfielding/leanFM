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

Metrics still need typed boundaries that distinguish empirical frequencies,
specified distributions, unresolved nondeterminism, policy choices, and
epistemic uncertainty; these support different claims and verification methods.

The reproducible synthetic bakery corpus validates the analysis pipeline, not
real-world behavior. Its descriptive analysis lacks confidence intervals,
sensitivity/stationarity checks, and treatment of censored in-flight tasks.

The code now emits separate client-experienced and server-aggregate work rates
by client population. These are observations suitable for a Universal
Scalability Law fit; the project does not yet estimate USL parameters or report
fit uncertainty. The formulas also assume an exhaustive observation list.
Warm-up, unfinished tasks, client think time, changing populations, and omitted
failed work can materially change the result and need explicit policies.

## Requirements and implementation are separated structurally, not logically

Separate requirements/implementation files and actor/message coverage are only
structural; validation does not prove generated-code conformance.

HTTP records method/path and associates responses with requests, but validation
omits endpoint/status/content-type maps, authentication, timeouts and complete
response alternatives. Headers, streaming, retries, idempotency, connection
reuse, intermediaries, redirects, cancellation and request/connection
correlation remain unspecified. Bind each response to its request and test
conformance against observable traces.

Generation uses the book, specifications and existing code: this reduces
transcript dependence, not variance. Pin model, prompt, tools and sampling;
review diffs and test behavior. Justifications do not prove correctness; require
stable fine-grained IDs, bidirectional coverage and behavioral tests, and
classify handwritten code as justified or infrastructure. The
`custom "unassigned" ""` fallback can hide transport gaps and should be rejected
in production validation.

## Security knowledge is not yet a complete epistemic model

Replacing an overstrong “secrecy” theorem with “who can calculate this value?”
is an improvement. The answer still depends on explicit deduction rules:
decryption keys, signatures, hashes, randomness, compromise, browser scripting,
logs, caches, and side channels.

A list of actors who receive a value is not equivalent to the set of actors who
can derive it. Any knowledge calculation should state its symbolic algebra and
trusted boundaries. Computational security claims would require a substantially
different model.

## Generated specifications need intent and distribution review

Structural validation catches missing actors, duplicate names, malformed fields,
and some coverage gaps; it cannot determine whether a requirement matches user
intent. Review assumptions, trust boundaries, failure alternatives, cost models,
probability provenance, and observability. Generated prose must not invent facts.

Characterize-and-synthesize currently defines similarity by finite reducers such
as latency percentiles, throughput, uptime, and histogram bins. Different event
processes can match these while differing in burstiness, tail dependence,
predecessor order, or rare failures. Passing tolerances establishes agreement
only on the named reducers, not the joint distribution or operational risk.
Specify tolerances, sample sizes, random seeds, and distributional tests.
