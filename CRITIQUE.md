# Critique

This document records unresolved gaps where implementation supports less than
the book claims. A successful build alone does not resolve them.

## Editorial and scope update: 2026-10-13

General knowledge/policy checking and past-logic extensions remain deferred.

### CTL implementation status and scope

Verified 2026-10-20:

CTL is implemented in `LeanFM/CTL.lean`: `holds` evaluates Boolean, EX/AX,
EF/AF, EG/AG, EU/AU, and EW/AW formulas. `CTLTests.lean` checks branching,
vacuity, until/release, and AG/AF duals with `native_decide`; `TaskFSM.holds`
feeds task-property results to the executable and `/metrics`.

The remaining gap is deriving bounded transition systems with
witnesses/counterexamples from general grammar/event models. `holds` is not a
proved-correct model checker, grammar interpreter, or deployed-code refinement
proof. Its path-local cycle detection can be exponential on shared graphs;
requirement validation and event-pair reconstruction use quadratic list scans.

### Project-root discoverability and code-generation readiness

End-to-end readiness remains unverified: a fresh session must recover the
project specifications, generate an application whose observable traces conform
to its grammar, and validate it with increasingly realistic in-project tests.
Persist that evidence in the project; screenshots are auxiliary, not a readiness
gate.

## Book length and consolidation (reviewed 2026-10-20)

The 139-page book still overconcentrates grammar and non-functional material in
`authoring-language.tex`; continue consolidating without losing the preface-to-PR
narrative or technical qualifications.

## The rendered book still needs a reproducible release check

Because `book/main.pdf` is also an input to code generation, the build should
fail when the committed PDF is not the deterministic product of the committed
TeX, generated tables, figures, and code listings. Ideally the release records
tool versions and a content manifest, then tests that regenerating the book
leaves no semantic diff.

## The book's language and maturity claims exceed current implementation

Chapters 5–7 and 11 now reference one evidence-label vocabulary, distinguishing
proposal from current implementation. Proposed forms (`scenario`, `declare`,
`from_`, `to_`, `emit`, `receive`, exported bindings, `refineMessage`, role
projection, symbolic encryption, `composeRoles`) still lack executable Lean
definitions. Current types are `RequirementSpec`,
`TaskRequirement`, and `GrammarExpr`; guards are strings and event values are
named, not typed-bound. Validation checks grammar/task and message references,
atom endpoints, and threshold bounds, but cannot compile that DSL, generate or
recognize traces, or derive participant projections. Chapter 7 and claims about
cost optimization, test generation, and OAuth artifact reproduction still need
evidence-matched labels.

Lean evidence covers only definitions and proofs actually checked in Lean;
Python, JavaScript, shell, Graphviz, protobuf, and LaTeX outputs are not proved
by their presence in the same project. `native_decide` checks finite decidable
propositions, not empirical assumptions or external parsers.
Compile claimed executable listings in CI, label the rest illustrative, and do
not let a polished figure or successful build imply stronger evidence.

## The new visual gallery exposes derivation gaps

The SVG gallery is not derived from the claimed event semantics:

- `interactionSvg` renders a flat `TaskRequirement.transitions` list, not a
  `(session, scenario)` stream ordered by `priorIds`; it loses choices and
  threshold branches, and a `KVReplica -> KVReplica` actor spec becomes a
  self-loop instead of leader/follower lifelines. These are schema, not
  per-session, diagrams.
- `stateMachineSvg` lays out states and edges by list position, ignoring
  `RequirementTransition.src` and `.dst`; branches or loops can therefore be
  drawn falsely.
- `latencyLineSvg` and `outcomePieSvg` hard-code geometry rather than reducing
  paired events or terminal mass to named metrics.
- `/diagrams/` is Git-ignored, so generated README links do not publish durable
  artifacts.

Require each renderer to consume typed inputs tied to its `DesiredOutput`, with
input-sensitive tests for branches, loops, forks and joins. Label each result as
a requirement schema, example trace, observed trace or modeled prediction; a
polished view must not become a second specification.

## The theorem gallery can drift from its Lean source

`LeanFM/Render.lean` hard-codes theorem cards instead of reading elaborated
declarations, so they can drift or conflate definitions and theorems. Although
the page labels them summaries, `RequiredProof` is an obligation, not a proof
term, and validation does not check its predicate. `lake env lean book/logic.lean`
fails because Mathlib is unavailable. Generate cards from declarations or a
typed AST, and link evidence labels to their source and build.

## The Paxos example is useful but does not yet validate the method

The three-replica application has durable storage, a browser interface, recovery
tests, concurrency and a real quorum, but does not yet validate the integrated
method:

- `LeanFM/PaxosKV/Requirements.proto` declares empty payload messages while
  `internal/protocol/requirements.proto` uses one generic `Envelope` with the
  executable fields. The requirement artifact is therefore not the schema from
  which the implementation bindings were generated.
- Requirements contain a checked `ScenarioEvent.priorIds` quorum DAG, but runtime
  tracing emits only `PutSucceeded`/`ListSucceeded` without predecessor IDs.
  Write, outage/recovery, concurrent-write and list traces lack the IDs,
  predecessors, concrete actors and timestamps needed to derive runtime views.
  The implementation also maps outage atoms to TCP without emitting the full
  declared outage/recovery protocol.
- `node.go` performs a prepare phase per slot. Protocol tests reject truncated
  protobuf payloads, but do not inject partial TCP-frame delivery, loss,
  duplication, delay, or reordering.
- Metrics expose a few counters and a latency accumulator, but not the full
  accepted output catalog for availability, recovery lag, queue pressure,
  memory headroom, or per-session diagrams.

## Event-only specifications leave hidden state unresolved

The event-only boundary is practical for production trace conformance but loses
properties whose truth depends on uninstrumented internal state. In contrast, a
TLA+-style specification can declare such state explicitly and check invariants
over it. LeanFM must either add an observable event, accept an abstraction with a
justification, or admit that the property cannot be determined from the stream.
Avoiding internal variables reduces modeling friction; it does not make hidden
state irrelevant.

## Grammar, protobuf, and choice do not yet form one checked wire path

`scripts/roundtrip_generated_scenario.py` manually builds one `get_docs`
`Scenario`, round-trips it with generated Python protobuf, and checks equality
and `prior`; it does not run grammar generation or recognition. End-to-end
coverage must exercise every `GrammarExpr` constructor and legal/illegal branch
(including `possibly`), then check decoded grammar/FSM acceptance, schema
evolution and malformed input, duplicate IDs, missing or cyclic predecessors,
and out-of-order events. The target is
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

## Runtime queue, population, and reliability models remain limited

Blocking send on a full queue and blocking receive on an empty queue capture the
most important bounded-channel behavior. They do not yet model:

- multiple blocked senders or receivers and their wake-up order;
- `select`, cancellation, deadlines, or closed channels;
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

Reliability now distinguishes configured outage probability/MTTR from
`Unavailable`/`Recovered` event estimates, but assumes complete windows and
nonoverlapping intervals. It omits duplicate merging, right-censored outages,
planned maintenance, and correlated pod/node/zone/dependency failures.
Independent actor percentages can therefore overstate Kubernetes availability.

## Memory accounting is underspecified

The project can count encoded bytes waiting in queues. Actual memory pressure
also includes envelope objects, allocator overhead, queue storage, protobuf
decoder state, retained buffers, actor state, duplicated payloads, blocked
goroutines or tasks, and transport-library buffers.

A byte budget based only on payload length is a lower bound. The requirements
need to say whether they constrain wire bytes, owned heap bytes, resident memory,
or some reproducible accounting model.

## The MDP interpretation needs a sharper decision boundary

Metrics still need typed boundaries that distinguish empirical frequencies,
specified distributions, unresolved nondeterminism, policy choices, and
epistemic uncertainty; these support different claims and verification methods.

## Statistical claims need uncertainty and sampling assumptions

The reproducible synthetic bakery corpus validates the analysis pipeline, not
real-world behavior. Its descriptive analysis lacks confidence intervals,
sensitivity/stationarity checks, and treatment of censored in-flight tasks.

The code now emits separate client-experienced and server-aggregate work rates
by client population. These are observations suitable for a Universal
Scalability Law fit; the project does not yet estimate USL parameters or report
fit uncertainty. The formulas also assume an exhaustive observation list.
Warm-up, unfinished tasks, client think time, changing populations, and omitted
failed work can materially change the result and need explicit policies.

The bakery chart now labels its measure modeled contribution after ingredients
and pay, not business profit; costs absent from the event corpus remain outside
that accounting model.

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

## Temporal-logic syntax is clearer than its current coverage

Using `(p AU q)` and `(p EU q)` keeps the temporal operator outside the
subformula and avoids context-dependent notation. The main limitation is not
syntax but state-space coverage. The finite examples are tractable partly
because payload domains, queues, tasks, and clocks are heavily bounded.

Claims proved on those abstractions need an explicit abstraction argument before
being applied to unbounded implementations. State-space truncation can remove
the very queue growth, retry loop, or timing behavior a property is intended to
find.

Treating `possibly` as preparedness improves traceability, but the current check
only proves that some implementation mapping cites the possibility proof. It
does not yet prove that the cited handler correctly covers every witness trace or
that recovery itself terminates. Those require generated conformance traces and
additional necessary-eventually obligations.

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
