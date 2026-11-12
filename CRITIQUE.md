# Critique

Open gaps where the implementation supports less than the book claims. A
successful build alone does not close one. Reviewed 2026-11-12; items resolved
since earlier reviews are listed at the end so they are not reopened.

LeanFM is a language: the protocol (a session type with its assumptions and its
`require` promises) is the program, and everything else is generated from it or
checked against it. Most gaps below are places where that is not yet true.

## Two model checkers, one of them old

`session_ctl` checks a CTL formula over a session's own state graph, which is
what the language promises. The older path still exists beside it:
`LeanFM/Logic.lean` (`check_ctl`) builds a Kripke structure from a task's typed
transitions, and `LeanFM/CTL.lean`, still used by `TaskFSM.holds`, uses
path-local cycle detection that can be exponential on shared graphs.
`GrammarExpr` (`parallel`, `thresholdJoin`, `guard`, `ref`) is not expanded into
either model. There is no proof that a checker is correct beyond agreement
tests between them.

## Search cost is measured, not managed

`/metrics` now reports each tool call's duration, model size and bound hits,
but nothing makes the search cheaper. `Attack.Protocol.explore` finds known
states by linear search, so its cost grows with the square of the states: a
protocol explored to the 4096-state bound took over ten minutes. There is no
hash index (`check_reassembly` has one), no partial-order reduction for
independent concurrent steps, and no scaling runs recorded in the book. Every
bound (4096 states, 20000 SLA expansions, 4 sessions per role) is a place an
answer can be resource-limit or undecided rather than proved.

## Distributions in the language, means in the old overlays

The session layer has real distributions: `after sample { … }` delays, `amount
sample { … }`, exact absorbing-chain solutions for loops, and SLA checks that
enumerate delay outcomes exactly and judge closed windows with exact binomial
tests. The older `LeanFM/Overlay.lean` still carries single mean delays, so the
bakery chapter's measured overlay answers 1 for "sold within 1.2 s" while only
54.5% of recorded sales meet it. Branch probabilities measured from a corpus
still show only the zero-count rule-of-three bound, not a confidence interval.
The bakery corpus is synthetic; it shows the method, not real operating data.

## SLA requirements have edges

`require per q { … }` is checked against the stated assumptions and against an
event stream, but the design-time check refuses periodic gates (`at next d`),
stops at 20000 expansions (then the verdict is undecided, with an interval), and
assumes entries are independent trials. Observed windows are tumbling, not
sliding, and a window is judged only once closed, so a long window reports late.

## Grammar-to-code refinement is not established

Implementation mappings are checked structurally (shape, coverage, known
requirement IDs), not behaviorally. `session_skeleton` generates typestate code
that logs in `session_conform`'s format, and `session_conform` checks the logs,
but no pipeline generates legal and illegal traces from a protocol, round-trips
them through protobuf (`decode(encode(generate(protocol, choices)))`), and
replays them against an implementation. `RequirementEnvelope.oneof` does not
validate branch disjointness, and `TransportSpec`'s `custom "unassigned"`
fallback can hide a missing HTTP mapping.

## Event traces: ordering is checked, clocks are not

`check_trace` and the SLA execution check reject duplicate identities and links
to missing or later events. Still missing: pairing starts and terminals across
retries and overlapping attempts; clock domain, resolution, overflow and
cross-actor synchronization; validating `dwellMs` against boundary times; and
m-of-n tie, winner and cancellation semantics.

## Paxos example lacks end-to-end conformance

`projects/PaxosKV` builds, runs and passes its project and browser checks, but
does not close the loop from a run back to the checkers: requirement payloads
are empty, the runtime uses a generic TCP `Envelope`, `node.go` emits only
terminal events without `priorIds`, and tests do not cover loss, duplication,
delay or reordering.

## Runtime models are declared, not executed

`ImplementationSpec` names `BoundedMailbox` semantics, but no executable mailbox
exists, so no Go-channel equivalence is established. Waiter sets, wake order,
`select`, cancellation and fairness are unspecified. Queue pressure counts
messages, not bytes; `Characterization.lean` reliability reducers are tested for
plan shape, not calculations.

## Lean checks definitions, not the artifacts around them

Lean does not check co-located Python, JavaScript, shell, protobuf or LaTeX.
`RequiredProof` is a named predicate, not a proof term. `book/logic.lean` needs
Mathlib and is not compiled by `make`. `LeanFM/Render.lean` hard-codes
theorem-gallery cards instead of reading declarations. Book generators added by
hand (`SlaChapterExample.lean`, `SecretsChapterExample.lean`) are not run by
`make book` until the Makefile lists them.

## Security: secrecy and authentication, not knowledge

The Dolev-Yao `Derives` relation is decided soundly (proved); completeness is
only tested, and every secrecy verdict leans on it. `check_protocol` declares
roles as scripts with every channel the attacker's, up to four sessions per role
(eight threads), variables binding names and nonces from declared domains,
never whole ciphertexts; attacks needing unboundedly many sessions are out of
reach. Marked secrets (`_secr`, or listed in `secrets`) each get an
unconditional never-knows verdict, with the keys that protect them and warnings
for unmarked names that look secret; secrecy relative to a peer is still a
formula. `knows` is derivability of a term; knowing that a fact holds (`K_a` over
indistinguishable states, CTLK) and belief (claims as beliefs, BAN-style) are
not operators. Randomness, key compromise and side channels have no rules.
`check_reassembly` covers two overlap policies on streams up to four bytes. A
symbolic model is not a computational cryptographic proof.

## The examples predate the language

The book is organised around the LeanFM language (Part I is generated from
`LanguageChapterExample.lean`), but two worked examples still use older machinery:
the bakery uses `LeanFM/Overlay.lean` with mean delays, and OAuth uses the
`GrammarExpr` and task-FSM path rather than a protocol. Both should be rewritten as
protocols with assumptions and `require` blocks. Five generators
(`TopologyExample`, `ProbabilityOverlayExample`, `StochasticUserMDPExample`,
`RuntimeReliabilityDiagram`, `NestedForkJoinExample`) no longer feed any chapter
but are still run by `make book`; the three new ones are not run by it yet.

## Reproducibility

Generation varies with model, prompt, tools and sampling. A fresh session has
not yet regenerated GoServer from only its durable artifacts. Book PDFs are
rewritten on every rebuild, so each change carries two binary files; publishing
them from releases would keep the repository text-only.

## Resolved (do not reopen)

- Witnesses and counterexamples: `check_ctl` and `session_ctl` return them for
  every verdict.
- Stakeholder approval gates: removed; review and acceptance are git commits.
- Evidence kind for probabilities: overlays are labelled declared or measured.
- Hidden-state requirements: `classify_requirement` separates observable,
  derived and implementation-only atoms and proposes events.
- Lean 4.35 upgrade and `Std.Async` networking.
- Predecessor existence, acyclicity and timestamp order in `check_trace`.
- Unbounded loops: the chain view solves them exactly as an absorbing Markov
  chain instead of rejecting cycles (2026-11).
- Delay and amount distributions in the language (`after sample`, `amount
  sample`) (2026-11).
- Probabilities as promises: `require per q` with observation windows, checked
  at design time against assumptions and at run time over closed windows
  (2026-11-12).
- Assumptions name their outcome: `[IsBusy → SlowPong: 1/10]` (2026-11-12).
- Marked secrets and check cost metrics (2026-11-12).
- The book documents the language: superseded notations (task FSMs as the main
  model, the scenario authoring language, channel presets and the topology tree as
  proposed notation) and the Chat UI guide were cut (2026-11-12).
