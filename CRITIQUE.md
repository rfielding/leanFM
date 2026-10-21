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

Now 131 pages after consolidation; preserve the preface-to-PR narrative and
technical qualifications. Verify reproducible releases, tool/content manifests,
and semantic equivalence: `book/main.pdf` drives code generation.

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

## Grammar-to-code and validation claims remain incomplete

Compatibility follow-up (2026-10-21): move published HTTP bindings from
Implementation into Requirements, then enforce realization against that wire
contract. Methods, paths, codecs, headers, status alternatives, authentication,
correlation and framing affect interoperability; implementation cannot override
them. Current transport validation does not establish this guarantee.

The proposed `scenario`/`declare`/`from_`/`to_`/`emit`/`receive` DSL,
exports, `refineMessage`, role projection, `WireTerm`, and `composeRoles` are
absent from `RequirementSpec`, `TaskRequirement`, and `GrammarExpr`; guards are
strings and event values untyped. Validation checks references, atom endpoints,
and threshold bounds, but does not compile the DSL, generate/recognize traces,
or project participants.

The three-replica Paxos app lacks end-to-end conformance: requirement payloads
are empty; runtime uses a separate generic TCP `Envelope`; and quorum-DAG
`ScenarioEvent.priorIds` has no runtime counterpart (`trace.Event` has no
predecessors). `node.go` emits only terminal `PutSucceeded`/`ListSucceeded`,
while the sink fills IDs/timestamps. Endpoint/session/task events lack starts,
so write, list, concurrent-write, and outage/recovery traces are unreconstructable;
outage recovery is untraced and prepare is slot-scoped. Protocol tests cover
envelope round trips and truncated protobuf, not partial TCP frames, loss,
duplication, delay, or reordering. `/metrics` has request outcomes, commit
latency, and quorum size, but lacks availability, recovery lag, queue pressure,
memory headroom, and per-session diagrams.

`scripts/roundtrip_generated_scenario.py` manually builds one `get_docs`
scenario from `LeanFM/LLMGenerated/Requirements.proto` and checks
Python-protobuf equality and predecessor IDs, not grammar trace generation or
recognition. Tests still need every `GrammarExpr` constructor and legal/illegal
branch (including `possibly`), decoded grammar/FSM acceptance, schema evolution,
malformed input, duplicate IDs, missing/cyclic predecessors, and out-of-order
events. The target is
`decode(encode(generate(grammar, choices)))`. The role of
`LeanFM/PaxosKV/Requirements.proto`'s `ScenarioEvent` (interoperable requirement
data or implementation choice) and its evolution policy remain undecided;
`RequirementEnvelope.oneof atom` does not validate branch disjointness, which
needs disjoint terminal byte languages or explicit metadata.

Lean verifies definitions and proof terms, not co-located Python, JavaScript,
shell, Graphviz, protobuf, or LaTeX outputs. `native_decide` covers finite
decidable propositions, not empirical assumptions or external parsers.
`RequiredProof` is not a proof term and its predicate is unchecked;
`lake env lean book/logic.lean` still fails without Mathlib.
`LeanFM/Render.lean` hard-codes theorem-gallery cards instead of reading
declarations, risking drift and conflating definitions with theorems. CI should
compile claimed executable listings, label illustrative examples, and generate
cards from declarations or a typed AST linked to source and successful builds.

Structural validation checks typed shape, actor/message coverage, and known
justification IDs—not intent or generated symbol-to-test behavior. Add stable
fine-grained IDs, bidirectional coverage, behavioral trace tests, and classify
handwritten code as requirement-backed or infrastructure. Human review must
still cover assumptions, trust boundaries, failure alternatives, costs,
probability provenance, and observability; generation must not invent facts.
The `custom "unassigned" ""` fallback can hide a missing transport mapping;
`TransportSpec` checks nonempty method/path and a known response target, not an
HTTP request. ChatUI specifies status, content type, codecs, one-to-one event
`cause_id` closure, and OpenAPI, but validation/tests do not prove runtime
bindings. Generic mappings omit authentication, deadlines, headers, streaming, retry/idempotency,
connection reuse, intermediaries, redirects, cancellation, status alternatives,
and binding validation.

Generation varies with model, prompt, tools, and sampling; pin them and review
diffs and behavior. Named finite metrics do not establish burstiness, tail
dependence, predecessor order, rare failures, or operational risk; define
tolerances, sample sizes, seeds, and distributional tests.

## Event order, time and concurrency need stronger validation

Events are timestamped points: paired boundaries give durations; `priorIds`
orders events but does not assert causation. Paxos `scenarioOrderWellFormed`
checks unique IDs, message fields, and links only to earlier serialized IDs.
General validation must still:

- observe hidden state, justify an abstraction, or mark dependent properties
  undetermined;
- pair starts and terminals uniquely across retries and overlapping
  `(session, task)` attempts;
- validate clock domain, resolution, monotonicity, overflow, and cross-actor
  synchronization; ensure predecessor IDs exist (or are declared external),
  the graph is acyclic independent of serialization, and no edge contradicts
  `timeAt`;
- check actor/message endpoints against selected terminals, grammar roots and
  terminals, complete joins, valid $m$-of-$n$ thresholds, and distinct branch IDs.

Validate `dwellMs` against boundary times and define $m$-of-$n$ ties, winner
selection, and cancellation. Partial-order width (incomparable point events),
active work (paired starts/completions), and feasible scheduling (including
actor capacity, queues, and scheduler) are distinct measures.

## Runtime queue, population, reliability, and memory models remain limited

Finite FIFO semantics cover blocking send-on-full and receive-on-empty, not
waiter sets/wake order, `select`, cancellation/deadlines, fairness/scheduling,
queue/state atomicity, or duplicate byte ownership. `ImplementationSpec` names
closed-channel `BoundedMailbox` operations, but no executable mailbox exists;
it therefore establishes no Go-channel equivalence.

The model expands finite instance IDs, each inheriting one resource contract per
actor specification. Dynamic lifecycle, discovery, load balancing, and migration
are absent; the 20-client/2-server sample establishes no other scale.

`queue.pressure` integrates messages, not bytes. Payload-byte sums also omit
envelopes, allocator/queue storage, decoder state, retained/transport buffers,
actor state, duplicates, and blocked tasks. A memory budget must define a
reproducible boundary such as wire bytes, owned heap, or resident memory.

`Characterization.lean` records uptime, MTTR, composed-availability, and cascade
reducer plans; tests check plan shape/names, not calculations. The book's
censored-interval, joint-outage, and outage-boundary policies lack reducer tests.

## Probability and statistical evidence need explicit assumptions

Rational probabilities lack an evidence-kind tag, conflating empirical
frequencies, assumed distributions, unresolved nondeterminism, policies, and
epistemic uncertainty. The seeded 81,039-line bakery corpus is synthetic; its
reducer summaries lack confidence intervals, sensitivity/stationarity checks,
and censored-task treatment.

`StreamStats` computes client-weighted/server-window rates and evaluates supplied
USL parameters, but fits neither parameters nor fit uncertainty. Its completed,
paired-only observations can bias estimates when omitted, in-flight, or failed
work is excluded. Declare warm-up, think-time, and population-change policies.

## Security knowledge is not yet a complete epistemic model

The book sketches, but does not implement, a Dolev–Yao `Derives` relation for
initial terms, tuples/projection, and perfect encryption/decryption, plus CTL
checks over its closure. Completeness still needs explicit rules and trust
boundaries for signatures, hashes, randomness, compromise, browser scripting,
logs/caches, and side channels. This symbolic model is not a computational
cryptographic proof.
