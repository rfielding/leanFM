# Critique

This document records weaknesses, unresolved questions, and places where the
current implementation supports a smaller claim than the book may suggest. It
is intentionally critical. Passing the build does not resolve these issues.

## The central abstraction is promising but not yet closed

LeanFM treats a scenario as a list of timestamped events with explicit causal
predecessors. That is a useful common representation, but the project does not
yet show that every artifact can be derived from that representation without
additional hand-authored information.

In particular, the FSMs, grammar, protobuf schema, implementation mapping,
charts, and prose often describe corresponding ideas independently. Validation
checks some names and structural properties, but it does not prove that all of
these artifacts denote the same protocol. A stronger system would have one
typed source from which the other artifacts are total, deterministic
projections.

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
serialization for event identity, causality, correlation, actors, and time.

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
  task)`. The current stream reducer closes the first matching open attempt and
  may not reconstruct the intended pairing in every such trace.

## Causal links permit fork and join but need stronger validation

A list-valued `prior` field naturally expresses roots, forks, and joins. The
current examples use it effectively. General validation should additionally
check:

- event IDs are unique;
- every predecessor exists or is explicitly external;
- the predecessor graph is acyclic;
- causal edges do not travel backward in `timeAt`;
- actor/message endpoints agree with the selected terminal;
- joins name all required branches rather than merely some convenient subset;
- roots and terminal events agree with the selected grammar production.

Without these checks, a syntactically valid event list can describe an
impossible or incomplete execution.

## “Maximal concurrency” has multiple meanings

The width of the causal partial order gives the maximum number of pairwise
unordered events. That is not automatically the maximum number of concurrently
executing operations. Point events have no duration. Runtime concurrency
requires separate start and completion events and a rule pairing them.

Resource concurrency introduces another distinction: causal independence may
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

1. Define one typed `ScenarioEvent` model in Lean with `timeAt`, list-valued
   predecessors, correlation, terminal value, and payload.
2. Generate a scenario directly from a typed grammar and explicit random or
   policy choices.
3. Implement or bind protobuf encoding and decoding for that model, then prove
   or exhaustively check round-trip preservation for the bounded domain.
4. Revalidate the decoded trace against the grammar, FSM, actor endpoints, and
   causal graph.
5. Derive diagrams, protobuf declarations, implementation bindings, reducers,
   and test vectors from the same typed source where possible.
6. Add causal-graph validation: unique IDs, complete predecessors, acyclicity,
   monotonic timestamps, and valid fork/join boundaries.
7. Make metric boundary selection typed and explicit instead of relying on
   naming conventions.
8. Distinguish empirical probability, specified randomness, nondeterminism, and
   policy decisions in the data model and book.
9. Add implementation conformance tests that compare observed byte traces with
   the accepted requirement language.
10. Label every major claim by its evidence level: assumption, example, test,
    model check, or proof.

