# Critique

This document records weaknesses, unresolved questions, and places where the
current implementation supports a smaller claim than the book may suggest. It
is intentionally critical. Passing the build does not resolve these issues.

## Audit snapshot: 2026-10-02

The book has a compelling core idea: make externally meaningful histories the
durable specification boundary, argue requirements into typed artifacts, and
derive code, tests, diagrams, metrics, and proofs from those artifacts. The
software demonstrates many ingredients of that idea. It does not yet implement
the integrated method described by the book.

The largest gap is no longer a missing data type. It is the absence of a single
executable semantic path connecting the types that now exist. `GrammarExpr`
has constructors and structural validators, but there is no general interpreter
that generates accepted event DAGs or recognizes an arbitrary decoded event DAG.
The server, charts, diagrams, protobuf round trip, finite protocol model, and Go
Paxos example each use related but separate representations. Consequently, a
successful build establishes local consistency, not the book's stronger claim
that one scenario grammar produced all of the reviewable and executable
artifacts.

The current evidence should be separated by kind rather than presented as one
undifferentiated notion of verification:

| Area | What exists | What the evidence establishes | What it does not establish |
| --- | --- | --- | --- |
| Lean requirement values | Typed records plus structural validation | Names, references, tags, coverage, and several well-formedness conditions | That the requirement matches user intent or has executable trace semantics |
| Finite protocol model | Executable transitions and `native_decide` checks | Properties of the bounded enumerated model | Refinement to arbitrary generated requirements or deployed code |
| Protobuf test | One generated worker scenario round trip | Equality after one Python protobuf encode/decode path | Grammar generation, recognition after decode, schema evolution, or generality |
| Paxos application | Working three-process Go example and tests | Useful behavior for the tested executions | Refinement from `Requirements.lean`, complete trace emission, or full Multi-Paxos |
| SVG/HTML output | Browser-visible files and gallery routes | The server can display ordinary visual artifacts | That every picture is reduced from the declared event source |
| Book theorems | Some real Lean theorems plus many proposed statements | The checked `book/logic.lean` statements compile when separately run | That pseudocode theorem schemas or typed `RequiredProof` records are proved |

The software is therefore best described as an executable design notebook with
several checked islands. Calling it an end-to-end formal-methods environment is
premature until those islands share one trace semantics and refinement story.

## The rendered book is not currently a reproducible release artifact

The checked-in `book/main.pdf` is stale relative to its source. For example,
`book/chapters/vision.tex` now explains why protocols and persistent disk formats
outlive chaotic internal structures, but the rendered PDF still moves directly
from state-space explosion to “We therefore begin with behaviour.” Current
source edits have not been rebuilt into the user-facing book.

This matters because `book/main.pdf` is also declared to be an input to code
generation. If source and PDF disagree, two agents can receive different
languages and requirements. The build should fail when the committed PDF is not
the deterministic product of the committed TeX, generated tables, figures, and
code listings. Ideally the release records tool versions and a content manifest,
then tests that regenerating the book leaves no diff.

## The implemented language is smaller than the book's authoring language

Chapters 4, 5, 7, and 11 use an attractive surface language with `scenario`,
`declare`, `from_`, `to_`, `emit`, `receive`, exported bindings,
`refineMessage`, actor-local role projection, symbolic encryption, and
`composeRoles`. Most of these forms do not exist as executable Lean definitions
in the repository. The implemented artifact language is principally
`RequirementSpec`, `TaskRequirement`, and `GrammarExpr`, whose guards are strings
and whose events contain names rather than typed bound values.

The book sometimes labels the fictional compiler's behavior in the present
tense: it “reads all referenced scenarios,” “checks exported bindings,”
“detects cycles,” “builds one grammar,” generates traces, recognizes traces, and
projects executable participants. The current code structurally walks grammar
atoms and references for validation; it does not implement that compiler. The
security-protocol theorem scripts explicitly depend on a library “still to be
built,” but comparable caveats are not consistently attached to the Chapter 5
surface syntax.

The book should either:

1. mark every non-executable listing as proposed notation and give the current
   executable equivalent beside it; or
2. implement the surface elaborator and make every major book example compile
   in CI.

Until then, the book teaches a better system than the repository contains.

## The new visual gallery exposes derivation gaps

Serving ordinary SVG files is a real usability improvement. The gallery now
contains multiple interaction diagrams, state machines, a line graph, a pie
chart, and a MathML theorem page. Their current captions overclaim their
provenance.

- `interactionSvg` iterates over `TaskRequirement.transitions`, not over a
  `(session, scenario)` event stream ordered by `priorIds`. Choices become a
  flat transition list, threshold branches are not recovered from the grammar,
  and actor specifications such as `KVReplica -> KVReplica` become a self-loop
  rather than concrete leader/follower lifelines. These are schema diagrams,
  not per-session scenario interactions.
- `stateMachineSvg` positions states and transitions by independent list index.
  It does not use `RequirementTransition.src` or `.dst` to draw edges. A branch,
  loop, or transition ordering different from the state list can therefore
  render a false machine while still looking polished.
- `latencyLineSvg` contains literal point coordinates and labels. It does not
  reduce paired start/end events or even interpolate the named Lean metric
  values into the SVG.
- `outcomePieSvg` is fixed geometry rather than a reduction of terminal-event
  mass. The wedge has no checked connection to the displayed categories.
- The portable `diagrams/` gallery is regenerated locally but the entire
  directory is ignored by Git. A README link to those paths works in a developer
  checkout only after generation; it does not publish durable artifacts.

This directly violates one of the book's best rules: a persuasive diagram must
not become a second specification. Each renderer needs an explicit typed input,
the matching `DesiredOutput`, and a test showing that changing the input changes
the expected geometry or series. The gallery should distinguish “requirement
schema,” “example trace,” “observed trace,” and “modeled prediction.”

## The theorem gallery conflates rendering, obligations, and proofs

The MathML page improves readability but has three different epistemic statuses:

- theorem statements manually copied from `book/logic.lean`;
- hand-authored mathematical paraphrases of those statements; and
- `RequiredProof` records rendered as modal formulas.

Only the first category has actual Lean proof terms. A `RequiredProof` value is
an obligation, not a theorem, and structural validation does not prove its
predicate. The page now labels these as typed proof obligations, which is better,
but the mathematical and Lean views are still separately maintained and can
drift. The derivative formula already demonstrated this risk when the first
rendering omitted `deriv` from the displayed equation.

The theorem page should be generated from elaborated declarations or a small
typed mathematical AST, not duplicated HTML strings. It should show a badge for
`proved`, `decided on finite model`, `tested`, `assumed`, or `unproved
obligation`, and link each proof to the declaration and build result that
supports the badge.

The `-1/12` chapter also needs unusually careful wording. `book/logic.lean`
defines `Tail_S` algebraically so that the finite-prefix-plus-tail identity is
true and proves self-similarity properties of that definition. This is a valid
discrete account of a chosen summation assignment. It is not a proof that the
ordinary divergent series of natural-number partial sums converges to `-1/12`.
The text should keep “regularized value under these definitions” visibly
separate from ordinary convergence.

## The Paxos example is useful but does not yet validate the method

The three-replica application is the strongest implementation example because
it has durable storage, a browser interface, recovery tests, concurrency, and a
real quorum. It also exposes important inconsistencies:

- `LeanFM/PaxosKV/Requirements.proto` declares empty payload messages while
  `internal/protocol/requirements.proto` uses one generic `Envelope` with the
  executable fields. The requirement artifact is therefore not the schema from
  which the implementation bindings were generated.
- The requirement now defines `ScenarioEvent.priorIds` and a checked example
  DAG, but runtime tracing emits only `PutSucceeded` and `ListSucceeded` events
  and supplies no predecessor IDs. The detailed quorum graph is an authored
  requirement example, not a rendering of a live execution.
- The accepted implementation narrative says stable-leader Multi-Paxos, while
  `internal/paxos/node.go` describes classic Paxos and performs a prepare phase
  for each proposed slot. This may be correct repeated Paxos, but it is not the
  documented implementation.
- `Implementation.lean` maps outage atoms to TCP even though the code does not
  emit the complete declared outage/restart/recovery protocol over that mapping.
- Metrics expose a few counters and a latency accumulator, but not the full
  accepted output catalog for availability, recovery lag, queue pressure,
  memory headroom, or per-session diagrams.

The example should become the conformance harness for the whole project: capture
a real legal write, outage, recovery, concurrent write, and list trace; decode
them through the requirement protobuf; validate them against the grammar; and
generate the browser diagrams and metrics from those exact traces.

## The central abstraction is promising but not yet closed

LeanFM treats a scenario as a list of timestamped events with explicit immediate
predecessors. Their transitive closure gives an event order, not a causation
claim. That is a useful common representation, but the project does not
yet show that every artifact can be derived from that representation without
additional hand-authored information.

In particular, the FSMs, grammar, protobuf schema, implementation mapping,
charts, and prose often describe corresponding ideas independently. Validation
checks some names and structural properties, but it does not prove that all of
these artifacts denote the same protocol. A stronger system would have one
typed source from which the other artifacts are total, deterministic
projections.

The event-only boundary is practical for production trace conformance but loses
properties whose truth depends on uninstrumented internal state. In contrast, a
TLA+-style specification can declare such state explicitly and check invariants
over it. LeanFM must either add an observable event, accept an abstraction with a
justification, or admit that the property cannot be determined from the stream.
Avoiding internal variables reduces modeling friction; it does not make hidden
state irrelevant.

## Grammar-to-bytes is demonstrated only for one example

`scripts/roundtrip_generated_scenario.py` proves that one hand-constructed
`get_docs` scenario survives protobuf serialization and parsing. It does not yet
prove the general property:

```text
decode(encode(generate(grammar, choices))) = generated scenario
```

The script constructs the scenario directly rather than asking the Lean grammar
generator to produce it. It therefore does not test the entire path from a
grammar choice to terminal fields and then to bytes. It also uses generated
Python protobuf code rather than a verified Lean encoder and decoder.

The round trip checks protobuf equality and the expected `prior` lists, which is
valuable, but it does not prove that the decoded event sequence remains legal
under the grammar or FSM. Unknown protobuf fields, schema evolution, malformed
input, duplicate event IDs, missing predecessors, cycles, and out-of-order
events are not exercised.

## The protobuf envelope may mix requirements and serialization policy

The project correctly separates transport choices from protobuf values:
protobuf says what bytes represent a value, while `Implementation.lean` says
whether those bytes use HTTP, TCP, or a channel. However, placing
`ScenarioEvent` and `Scenario` in `Requirements.proto` also chooses a particular
serialization for event identity, predecessor order, correlation, actors, and time.

That may be appropriate as part of the observable contract, but the boundary
should be stated explicitly. If the event envelope is merely an implementation
format, it belongs beside other implementation choices. If it is required for
interoperability, it belongs in the requirements and needs compatibility rules.

## Choice is not yet fully reduced to bytes

The intended rule is strong: a grammar alternative is resolved by the terminal
bytes, without a separate hidden chooser. Some examples follow that rule using
distinct protobuf `oneof` alternatives. The validators do not yet prove that
all alternatives are byte-distinguishable.

Two alternatives could currently use the same message type and overlapping
field values. In that case the receiver could not reconstruct which production
was chosen. The system needs either a disjointness check or a precise statement
that the decoded terminal value—not merely its type—must identify the branch.

## Event time is cleaner now, but timing semantics remain incomplete

An event has one `timeAt`. A start and a completion are different messages, and
elapsed time is calculated by subtracting their timestamps. This avoids placing
a hidden interval inside an event.

Several questions remain:

- The specification still attaches `dwellMs` to transitions. The relationship
  between a transition dwell and the timestamps of emitted boundary events is
  described but not enforced everywhere.
- A timestamp difference is meaningful only after selecting the correct two
  correlated boundary events. The pairing rule is not yet a first-class typed
  part of every metric.
- Clock domain, resolution, monotonicity, overflow, and synchronization across
  actors are assumptions rather than checked properties.
- Equal timestamps do not imply concurrency, and unequal timestamps do not by
  themselves imply causality. The book says this, but some charts may encourage
  a stronger interpretation.
- A task may have retries or overlapping attempts with the same `(session,
  task)`. The stream reducer now pairs a terminal with the start ID in its
  backpointer list, but malformed, missing, or multiple start backpointers still
  need explicit validation and error reporting.

## Predecessor links permit fork and join but need stronger validation

A list-valued `priorIds` field naturally expresses roots, forks, and joins. The
Paxos example now checks unique IDs, backward references, acyclicity induced by
list order, and agreement between displayed fields and its message schema. That
is useful, but it is local to one example and assumes every predecessor occurs
earlier in the storage list. A general event-DAG validator should additionally
check:

- every predecessor exists or is explicitly external without requiring one
  particular topological serialization;
- the predecessor graph is acyclic;
- predecessor edges do not travel backward in `timeAt`;
- actor/message endpoints agree with the selected terminal;
- ordinary joins name all required branches; threshold joins preserve valid
  `m`, `n`, and distinct selected branch IDs;
- roots and terminal events agree with the selected grammar production.

Without these checks, a syntactically valid event list can describe an
impossible or incomplete execution.

The grammar and event model now represent $m$-of-$n$ joins, but no scheduler yet
defines simultaneous completion ties, deterministic winner selection, or an
automatic cancellation policy for the remaining $n-m$ branches. Those choices
can affect cost, queue pressure, and reliability and must be specified when they
matter.

## “Maximal concurrency” has multiple meanings

The width of the predecessor partial order gives the maximum number of pairwise
unordered events. That is not automatically the maximum number of concurrently
executing operations. Point events have no duration. Runtime concurrency
requires separate start and completion events and a rule pairing them.

Resource concurrency introduces another distinction: order independence may
permit two operations while actor capacity, queue capacity, or scheduling makes
their simultaneous execution impossible. The book should consistently label
partial-order width, observed in-flight work, and feasible scheduled concurrency
as different quantities.

## Queue semantics are still an abstraction of Go channels

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

Actor populations now distinguish a reusable actor specification from concrete
instances. The current checks expand finite names and apply one resource contract
to each instance, but they do not yet model dynamic creation, removal, discovery,
load balancing, or migration. Results for a population of 20 clients and 2
servers do not automatically generalize to other population sizes.

Reliability contracts now distinguish configured outage probability and MTTR
from values reduced from `Unavailable`/`Recovered` events. The reducer assumes a
complete observation window and nonoverlapping outage intervals for each
replica; it does not yet merge duplicate intervals, handle right-censored
outages, distinguish planned maintenance, or model correlated failures across
pods, nodes, zones, and dependencies. Independent actor outage percentages can
therefore substantially overstate Kubernetes availability.

## Memory accounting is underspecified

The project can count encoded bytes waiting in queues. Actual memory pressure
also includes envelope objects, allocator overhead, queue storage, protobuf
decoder state, retained buffers, actor state, duplicated payloads, blocked
goroutines or tasks, and transport-library buffers.

A byte budget based only on payload length is a lower bound. The requirements
need to say whether they constrain wire bytes, owned heap bytes, resident memory,
or some reproducible accounting model.

## The MDP interpretation needs a sharper decision boundary

Random user behavior makes downstream observations random even when servers are
deterministic. Calling the entire system an MDP additionally requires explicit
actions or decisions controlled by a policy. If there is no controllable choice,
the model may be a Markov chain or simply a stochastic transition system.

The current integer weights are useful, but the project should distinguish:

- empirical frequencies estimated from an event stream;
- specified probability distributions;
- nondeterministic alternatives;
- policy-controlled actions;
- uncertainty caused by incomplete knowledge.

These categories support different claims and different verification methods.

## Statistical claims need uncertainty and sampling assumptions

The bakery corpus supplies concrete probabilities, latency distributions,
profit, pay, and waste charts. This is much stronger than invented chart data,
but the analysis is descriptive. It does not currently provide confidence
intervals, sensitivity analysis, stationarity checks, or treatment of censored
in-flight tasks.

The corpus is generated by a deterministic pseudo-random program. It validates
the analysis pipeline, but it is not evidence about a real bakery. Conclusions
should be labeled as properties of that generated population unless real data
is supplied.

The code now emits separate client-experienced and server-aggregate work rates
by client population. These are observations suitable for a Universal
Scalability Law fit; the project does not yet estimate USL parameters or report
fit uncertainty. The formulas also assume an exhaustive observation list.
Warm-up, unfinished tasks, client think time, changing populations, and omitted
failed work can materially change the result and need explicit policies.

Daily profit also depends on an accounting model. Current calculations include
sales, refunds, ingredient cost, and employee pay, but omit rent, utilities,
taxes, depreciation, payment fees, delivery costs, inventory timing, and other
expenses. The chart is contribution under the modeled costs, not necessarily
business profit.

## Requirements and implementation are separated structurally, not logically

`Requirements.lean` and `Implementation.lean` are separate files, and
validation requires actor and message coverage. This is a good boundary. The
validator does not yet prove that generated code implements the requirement.

For example, an HTTP response points back to a named request message, but the
validator does not check endpoint compatibility, status mappings, protobuf
content types, authentication behavior, timeout behavior, or whether alternative
responses are exhaustive and exclusive. A complete implementation argument
needs conformance tests or refinement proofs against observable traces.

The code-generation prompt now treats the durable requirements, protobuf, and
implementation files as its complete authority, with existing code optional for
revision. This removes dependence on chat history but does not make code
generation deterministic: model version, prompt version, backend tools, and
sampling settings can still change the output. Reproducible builds require those
inputs to be pinned, and generated diffs still require review and conformance
tests.

Requirement justifications provide traceability, not correctness. A generated
comment can cite a real requirement while the adjacent code implements it
incorrectly, and overly broad requirement IDs can become meaningless catch-all
citations. Useful enforcement still requires stable fine-grained IDs,
bidirectional coverage checks, and behavioral conformance tests. Hand-written
code also needs a policy: either acquire a valid justification or be explicitly
classified as infrastructure outside the generated requirement surface.

The `custom "unassigned"` fallback also makes generation total while potentially
hiding an unfinished transport decision. Production validation should reject
unassigned adapters.

## The HTTP example is only a mapping, not an HTTP semantics

An HTTP method and path are recorded in the implementation plan. This does not
model request correlation, headers, status codes, streaming, retries,
idempotency, connection reuse, intermediaries, redirects, cancellation, or the
fact that an HTTP response is coupled to a particular request on a connection.

Treating request and response protobuf atoms as independently transported
messages is convenient, but code generation will need a binding that explains
how their causal and correlation fields map onto actual HTTP behavior.

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

## The Lean trust story is mixed

Lean checks definitions and proofs that are actually expressed in Lean. Several
important pipeline steps currently live in Python, JavaScript, shell commands,
Graphviz, protobuf tooling, and LaTeX. Their outputs are useful but are not made
correct merely because the project also contains Lean files.

`native_decide` relies on executable decision procedures for finite values. It
does not convert empirical assumptions or external parser behavior into proved
theorems. The project should clearly label each artifact as proved, checked,
tested, generated, or illustrative.

## The LLM-facing workflow can validate form more easily than intent

An interface resembling ChatGPT can help a user argue toward a durable
specification. It may also produce a formally well-shaped specification that
misstates the user's intent. Structural validation catches missing actors,
duplicate names, malformed fields, and some coverage gaps; it cannot determine
that a requirement is the right requirement.

The workflow needs explicit review points for assumptions, trust boundaries,
failure alternatives, cost models, probability provenance, and observability.
Generated prose should not silently supply facts that the user did not state.

The new characterize-and-synthesize loop defines similarity as agreement on a
finite list of reduced metrics. This is testable but underdetermined: many event
processes can share latency percentiles, throughput, uptime, and histogram bins
while differing in burstiness, tail dependence, predecessor-order structure, or rare
failures. Passing the tolerance check proves only equivalence under the named
reducers. It does not show that the generated process has the same joint
distribution or operational risk. Tolerances, sample sizes, random seeds, and
distributional tests still need a durable specification.

## The book occasionally gets ahead of the implementation

The book presents an integrated vision involving grammar generation, complete
artifact derivation, probabilities, queues, knowledge, temporal logic, code
generation, and replay. Individual pieces exist, but the end-to-end path is not
yet a single implementation with one checked theorem connecting all of them.

Examples should say which of the following they provide:

- an explanatory notation;
- executable code;
- a finite model check;
- a unit or round-trip test;
- a generated data analysis;
- a Lean proof;
- an intended future interface.

This distinction is especially important because polished diagrams and a
successful build can make an illustrative example appear more formally complete
than it is.

## Highest-value next steps

1. Implement one executable semantics for `GrammarExpr`: generation from
   explicit choices and recognition of partially ordered `ScenarioEvent` DAGs.
   Make sequence, choice, parallel, threshold join, guard, reference, and repeat
   testable rather than merely structurally valid.
2. Unify the event envelope and protobuf story. Generate the worker and Paxos
   requirement schemas from the same typed message definitions, remove the
   empty Paxos placeholder messages, and round-trip multiple legal and illegal
   traces through the actual runtime binding.
3. Make the Paxos program emit every declared protocol event with IDs,
   `priorIds`, concrete actor instances, timestamps, and typed payload fields.
   Replay those traces through the grammar and derive the displayed quorum DAG,
   interaction diagram, state path, latency, availability, and recovery lag.
4. Replace the SVG shortcuts with real reducers. Interaction diagrams must take
   event DAGs; state machines must use transition `src`/`dst` or grammar
   residuals; line and pie charts must consume named numeric series. Add golden
   tests for branch, loop, fork, all-of join, and `m`-of-`n` join layouts.
5. Turn evidence level into a typed, visible property of every artifact:
   `assumption`, `illustration`, `observed`, `tested`, `finite-model checked`, or
   `Lean proved`. Do not render a `RequiredProof` as though it had a proof term.
6. Either implement the book's scenario surface language or rewrite the book to
   use the actual `RequirementSpec`/`GrammarExpr` API. Compile every purportedly
   executable listing in CI and visibly mark pseudocode.
7. Add a deterministic book-release check: rebuild `book/main.pdf`, generated
   tables, SVG/PNG figures, theorem pages, and referenced-book assets, then fail
   on drift. Because the PDF is a code-generation input, stale output is a
   semantic defect, not cosmetic debt.
8. Reconcile the Paxos implementation document with the code: either implement
   stable-leader Multi-Paxos or specify repeated classic Paxos. Then add fault
   tests for lost, duplicated, delayed, reordered, and partially written frames,
   not only clean process loss.
9. Make metric boundaries typed and executable. Distinguish empirical
   probability, specified randomness, nondeterminism, and policy decisions;
   include warm-up, censorship, observation windows, uncertainty, and
   accounting boundaries in reducer inputs.
10. Prove or test refinement at the observable boundary: generated or existing
    code traces must be accepted by the requirement language, and every required
    legal branch—especially `possibly` branches—must have a tested handling
    path. Traceability comments alone are insufficient.
