# Critique

Open gaps where the implementation supports less than the book claims. A
successful build alone does not close one. Reviewed 2026-10-28; items resolved
since the previous review are listed at the end so they are not reopened.

## Model checking covers task state machines, not whole grammars

`LeanFM/Logic.lean` (`check_ctl`) builds a finite Kripke structure from a task's
typed transitions and returns a witness or counterexample path for every
verdict, using polynomial fixpoint labelling. It does not yet derive the model
from a `GrammarExpr`: `parallel`, `thresholdJoin`, `guard` and `ref` are not
expanded, so a property that depends on interleaving is checked only to the
extent the task FSM encodes it. `LeanFM/CTL.lean`, still used by `TaskFSM.holds`,
uses path-local cycle detection that can be exponential on shared graphs.
Bounded payloads, queues, clocks and truncation can hide growth or retry loops;
an unbounded claim needs an abstraction argument. There is no proof that the
checker itself is correct beyond agreement tests with `LeanFM.CTL`.

## Probability and time overlays carry means, not distributions

`LeanFM/Overlay.lean` separates declared and measured overlays and labels each
answer with its overlay, and `measure` reduces branch counts and mean delays
from recorded sessions. Delays are single values, so deadline answers from a
measured overlay can be badly wrong: the bakery corpus has a 1163 ms mean sale
and a model answer of 1 for "sold within 1.2 s", while only 54.5% of recorded
sales meet it (book chapter 4 reports both). Needed: delay distributions,
confidence intervals for branch probabilities (only the zero-count
rule-of-three bound is shown), and exact or numeric solution for tasks with
unbounded loops (run enumeration rejects cycles). The bakery corpus is
synthetic; it shows the method, not real operating data.

## Grammar-to-code refinement is not established

Implementation mappings are checked structurally (typed shape, actor/message
coverage, known requirement IDs), not behaviorally. No pipeline yet generates
legal and illegal traces from a grammar, round-trips them through protobuf
(`decode(encode(generate(grammar, choices)))`), and replays them against the
implementation. `scripts/roundtrip_generated_scenario.py` checks one hand-built
scenario. `RequirementEnvelope.oneof` does not validate branch disjointness.
HTTP bindings published to clients should live in Requirements, since methods,
paths, codecs, status alternatives and authentication affect interoperability;
`TransportSpec` checks only nonempty method/path and a known response target,
and the `custom "unassigned"` fallback can hide a missing mapping.

The proposed `scenario`/`declare`/`emit`/`receive` DSL, `refineMessage`, role
projection, `WireTerm` and `composeRoles` described in the book are absent from
`RequirementSpec`, `TaskRequirement` and `GrammarExpr`; guards are strings.

## Event traces: ordering is checked, clocks are not

`check_trace` now reports duplicate and dangling ids, references to later
events, cycles, edges whose `timeAt` runs backwards, schema src/dst mismatches,
concurrency, and per-task acceptance. Still missing: pairing starts and
terminals across retries and overlapping attempts; clock domain, resolution,
overflow and cross-actor synchronization; validating `dwellMs` against boundary
times; and m-of-n tie, winner and cancellation semantics.

## Paxos example lacks end-to-end conformance

`projects/PaxosKV` now builds, runs (three replicas plus web via `make run`),
passes the canonical project check and a two-browser check. It still does not
close the loop from a run back to the checkers: requirement payloads are empty,
the runtime uses a generic TCP `Envelope`, `node.go` emits only terminal events
without `priorIds`, and tests do not cover loss, duplication, delay or
reordering. The project book's "Known gaps" chapter is the work queue.

## Runtime models are declared, not executed

`ImplementationSpec` names `BoundedMailbox` send/receive/close semantics, but no
executable mailbox exists in LeanFM, so no Go-channel equivalence is
established. Waiter sets, wake order, `select`, cancellation and fairness are
unspecified. Populations are finite instance lists with one resource contract
each; queue pressure counts messages, not bytes; `Characterization.lean`
reliability reducers are tested for plan shape, not calculations.

## Lean checks definitions, not the artifacts around them

Lean does not check co-located Python, JavaScript, shell, protobuf or LaTeX.
`RequiredProof` is a named predicate, not a proof term. `book/logic.lean` needs
Mathlib and is not compiled by `make`. `LeanFM/Render.lean` hard-codes
theorem-gallery cards instead of reading declarations. Generated SVGs
(`interactionSvg`, `stateMachineSvg`) plot task transitions in list order, not
event-derived traces, and omit choices and thresholds.

## Security knowledge is sketched, not implemented

The Dolev-Yao `Derives` relation and `knows(actor, value)` over the causal past
are described in the book but not implemented; the MCP `knows` tool answers
`unsupported`. Signatures, hashes, randomness, compromise and side channels
have no rules. A symbolic model is not a computational cryptographic proof.

## Reproducibility

Generation varies with model, prompt, tools and sampling. A fresh session has
not yet regenerated GoServer from only its durable artifacts. Book PDFs are
committed on every rebuild, which causes binary merge conflicts and large
pushes; publishing them from releases would keep the repository text-only.

## Resolved since 2026-10-20 (do not reopen)

- Witnesses and counterexamples: `check_ctl` returns them for every verdict.
- Stakeholder approval gates: removed; review and acceptance are git commits.
- Evidence kind for probabilities: overlays are labelled declared or measured.
- Hidden-state requirements: `classify_requirement` separates observable,
  derived and implementation-only atoms and proposes events.
- Lean 4.35 upgrade and `Std.Async` networking.
- Predecessor existence, acyclicity and timestamp order in `check_trace`.
