# LeanFM self-hosting handoff

Start here when conversation history is unavailable. Read `SKILL.md`,
`book/main.pdf` (or its same-source accessible `book/main-dark.pdf`), and the
canonical files in `LeanFM/LLMGenerated/`: `Requirements.lean`,
`Requirements.proto`, `Implementation.lean`, `SelfHosting.lean`, and
`SelfHosting.proto`. Inspect the existing source before changing it.

`Requirements.selfHostingRequirement` is the product composition. It imports
the existing ChatUI requirements and adds a proposed development workflow.
`SelfHosting.components` registers component specifications and bindings.
The Worker protocol is an example, not a complete specification of LeanFM.
Component source files remain in their existing paths to avoid breaking imports;
the canonical registry is their stable entry point.

Run `make selfhost-check` and read its generated `SELF_HOSTING_REVIEW.md`.
It includes the current proposed interaction/state diagrams and clauses.
Structural elaboration and schema validation do not prove English predicates.
The report is derived evidence about the specification, not a runtime trace.

## Decisions preserved from the requirements discussion

Knowledge and policy modalities use distinct relations, not reinterpretations
of CTL A/E. Retain their indexes only while referenced, scoped by project and
model revision; preserve source evidence so rebuilding preserves semantics.
Probability is optional and distinct from existence: record whether it is
declared, observed, or unknown, and specify scheduler and horizon boundaries.
Nested CTL covers persistence and recurrence without claiming full LTL coverage.
Read `MULTIMODAL_LOGIC.md` for formulas and exact readings.

## Current gate and remaining work

This consolidation is a requirements proposal. Neither a build nor this document
records user acceptance. The current whole-product specification still needs:

- executable typed formula semantics and checker outcomes/evidence schemas;
- explicit revision acceptance/invalidation and failure/cancellation/retry tasks;
- precise probability/scheduler and bounded observation-monitor contracts;
- workflow payload refinements (check results, snapshot manifests, patch and PR
  metadata), beyond the current correlated artifact references;
- implementation mappings and conformance evidence for every new clause;
- a book-wide classification of accepted, pending, deferred, and illustrative
  claims, including coverage of the language/compiler itself.

The successful workflow diagram is a high-level scenario, not a complete error
protocol. Its current rejection branch covers initial revision rejection;
later failures must be refined before implementation acceptance. PR output means
an actual reviewable patch/bundle; remote creation or publication still requires
authorization. Do not fill these gaps by guessing from missing chat history.

Existing account/project/chat/markerboard/research/inspection behavior is in
`LeanFM/ChatUI/Requirements.lean`, with mappings in its `Implementation.lean`.
Do not confuse preservation of those specifications with a full conformance audit.
After requirements acceptance, write and obtain acceptance of the separate
implementation specification, then implement against the exact accepted snapshot.
