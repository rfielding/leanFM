# Critique

This document records unresolved gaps where implementation supports less than
the book claims. A successful build alone does not resolve them.

### CTL implementation and temporal coverage remain bounded

Verified 2026-10-20: `LeanFM/CTL.lean` implements `holds` for Boolean,
EX/AX, EF/AF, EG/AG, EU/AU and EW/AW. `CTLTests.lean` checks branching,
vacuity, until/release and AG/AF duals with `native_decide`; `TaskFSM.holds`
feeds task-property results to the executable and `/metrics`.

Still missing: derive bounded transition systems and witnesses/counterexamples
from general grammar/event models, prove the checker/interpreter or deployed-code
refinement, and establish that `possibly` handlers cover every witness and
terminate. Its current check only requires a mapping to cite the possibility
proof. Path-local cycle detection may be exponential on shared graphs;
validation and event-pair reconstruction use quadratic scans. Bounded payloads,
queues, tasks and clocks plus truncation can hide growth, retry loops or timing
behavior, so unbounded claims need an explicit abstraction argument.

### Project-root discoverability and code-generation readiness

Fresh-session readiness is unverified: resume from durable specs, generate an
application, demonstrate grammar-conforming traces with increasingly realistic
in-project tests, and persist evidence under the root. Screenshots are not a gate.

## Book length and release reproducibility (reviewed 2026-10-20)

At 134 pages (`authoring-language.tex`: 769 lines), consolidate without losing
the preface-to-PR narrative or technical qualifications. Because `book/main.pdf`
feeds code generation, release checks must verify deterministic rendering from
committed inputs, record tool versions and a content manifest, and leave no
semantic diff after regeneration.

## The book's language and maturity claims exceed current implementation

Proposed forms (`scenario`, `declare`, `from_`, `to_`, `emit`, `receive`, exports,
`refineMessage`, role projection, symbolic encryption, `composeRoles`) lack
executable Lean definitions. The current API is `RequirementSpec`,
`TaskRequirement`, and `GrammarExpr`; guards are strings and event values are
not typed-bound. Validation checks grammar/task/message references, atom
endpoints, and threshold bounds, but cannot compile the DSL, generate/recognize
traces, or project participants.

Lean verifies only elaborated definitions and proofs; Python, JavaScript, shell,
Graphviz, protobuf, and LaTeX outputs are not proved by co-location.
`native_decide` covers finite decidable propositions, not empirical assumptions
or external parsers. Compile claimed executable listings in CI, label examples
illustrative, and do not infer stronger evidence from a polished figure or green
build. `LeanFM/Render.lean` hard-codes theorem-gallery cards instead of reading
declarations, so they can drift or conflate definitions with theorems.
`RequiredProof` is not a proof term, and its predicate is unchecked;
`lake env lean book/logic.lean` still fails without Mathlib.
Generate cards from declarations or a typed AST and link them to source and
successful builds.

## The new visual gallery exposes derivation gaps

The SVG gallery is not derived from event semantics. `interactionSvg` draws flat
task transitions instead of `(session, scenario)` traces ordered by `priorIds`,
losing choices/thresholds and rendering `KVReplica -> KVReplica` as a self-loop
rather than leader/follower lifelines. `stateMachineSvg` ignores transition
`src`/`dst`; `latencyLineSvg` and `outcomePieSvg` hard-code geometry instead of
reducing paired events or terminal mass. `/diagrams/` is Git-ignored, so README
links are not durable. Require typed `DesiredOutput` inputs and input-sensitive
tests for branches, loops, forks and joins; label each result as a requirement
schema, example trace, observed trace or modeled prediction. A polished view
must not become a second specification.

## Grammar-to-wire path and the Paxos example remain incomplete

The three-replica Paxos app has durable storage, a browser UI, recovery tests,
concurrency, and a real quorum, but does not yet validate the integrated method.
`LeanFM/PaxosKV/Requirements.proto` declares empty payload messages while
`internal/protocol/requirements.proto` defines the generic executable
`Envelope`; the requirement schema is not the source of those bindings.
Requirements check a `ScenarioEvent.priorIds` quorum DAG, but runtime tracing
emits only terminal `PutSucceeded`/`ListSucceeded` events. The sink assigns IDs
and timestamps, and these events name their source, destination, session, and
task; they have no predecessor links or starts, so they cannot reconstruct
write, outage/recovery, concurrent-write, or list interactions. Outage atoms are
mapped to TCP without the full declared outage/recovery protocol. `node.go`
prepares per slot; protocol tests reject truncated protobuf payloads but do not
inject partial TCP frames, loss, duplication, delay, or reordering. Metrics omit
accepted outputs for availability, recovery lag, queue pressure, memory
headroom, and per-session diagrams.

The grammar-to-wire path is not yet checked end to end. `scripts/roundtrip_generated_scenario.py`
manually constructs one `get_docs` `Scenario`, round-trips it with generated
Python protobuf, and checks equality and predecessor IDs; it does not generate
or recognize traces from the grammar. Tests still need every `GrammarExpr`
constructor and legal/illegal branch (including `possibly`), decoded grammar/FSM
acceptance, schema evolution, malformed input, duplicate IDs, missing or cyclic
predecessors, and out-of-order events. The target is
`decode(encode(generate(grammar, choices)))`.

`Requirements.proto` puts event identity, order, correlation, actors, and time in
protobuf. Decide whether this envelope is interoperable requirements data or an
implementation choice, then define its evolution compatibility. Decoded bytes
also need an unambiguous grammar branch: require disjoint terminal byte
languages or define a selector. Neither boundary nor selector is validated.

## Event order, time and concurrency need stronger validation

Events are timestamped points: paired boundaries give durations, while
`priorIds` expresses predecessor order, not causation. The Paxos
`scenarioOrderWellFormed` helper checks unique IDs, message-field coverage, and
links only to IDs earlier in the supplied list. General trace validation still
needs to check:

- whether declared properties depend on hidden state the event stream cannot
  determine; instrument it, justify an abstraction, or mark it undetermined;
- unambiguous start/terminal pairing across retries and overlapping
  `(session, task)` attempts, rejecting missing, malformed, or multiple start
  backpointers;
- clock domain, resolution, monotonicity, overflow and cross-actor
  synchronization; predecessor existence (allowing declared external IDs),
  acyclicity independent of serialization, and no edge backward in `timeAt`;
- actor/message endpoint agreement with the selected terminal; grammar roots and
  terminals; complete joins with valid `m`-of-`n` thresholds and distinct branch
  IDs.

`dwellMs` is not consistently checked against boundary times. The grammar's
$m$-of-$n$ joins leave completion ties, winner selection and cancellation
unspecified. Partial-order width counts incomparable point events, not active
work; runtime concurrency needs paired starts/completions, while feasible
scheduling also depends on actor capacity, queues and the scheduler. Keep these
three measures distinct.

## Runtime queue, population, reliability, and memory models remain limited

Blocking send on a full queue and blocking receive on an empty queue capture the
most important bounded-channel behavior. They do not yet model:

- multiple blocked senders or receivers and their wake-up order;
- `select`, cancellation, or deadlines. Closed-channel behavior is named in
  `ImplementationSpec`, but no executable `BoundedMailbox` implementation was
  found in this checkout;
- fairness and starvation;
- atomicity between queue operations and actor-state transitions;
- scheduler behavior;
- whether outbound and inbound queues duplicate ownership of the same bytes.

Consequently, queue-capacity and memory-pressure conclusions apply to the
modeled channel semantics, not automatically to an implementation using Go
channels.

Checks expand finite names from reusable actor specifications and apply one
resource contract per instance, but omit dynamic creation/removal, discovery,
load balancing, and migration. Results for 20 clients and 2 servers do not
generalize to other population sizes.

The current `queue.pressure` reducer counts messages, not bytes. Summing encoded
payload lengths would still be only a lower bound: envelopes, allocator and
queue storage, protobuf decoder state, retained and transport buffers, actor
state, duplicated payloads, and blocked goroutines or tasks also consume memory.
Any byte budget must specify wire bytes, owned heap, resident memory, or a
reproducible accounting model.

`Characterization.lean` names uptime, MTTR, composed-availability, and cascade
reducers; tests only check their names. Executable handling and tests for
duplicate/censored intervals, joint failures, and the book's boundary policies
remain absent.

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

Separate `Requirements.lean`/`Implementation.lean` files and actor/message
coverage form a boundary; validation still does not prove generated-code
conformance.

HTTP records method/path and associates a request with each response, but
validation omits endpoint/status/content-type mappings, authentication, timeouts,
and exhaustive response alternatives. Independently transported request/response
atoms leave headers, streaming, retries, idempotency, connection reuse,
intermediaries, redirects, cancellation, and request/connection correlation
unspecified. Bind each response to its request and test or prove conformance
against observable traces.

Code generation treats the book and typed specifications as authority; revision
also supplies existing code. This reduces chat-history dependence, not
generation variance: pin the model, prompt, tools, and sampling; review diffs and
test behavior. Justifications link code to requirements but do not prove
correctness. Require stable fine-grained IDs, bidirectional coverage, and
behavioral tests; classify handwritten code as justified or as infrastructure
outside the generated surface.

The `custom "unassigned" ""` fallback makes generation total but can hide
transport gaps; production validation should reject it.

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
