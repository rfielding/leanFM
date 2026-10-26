# LeanFM agent instructions

These instructions apply to the entire repository.

Read and follow `SKILL.md` whenever a request involves requirements discovery,
design or architecture arguments, LeanFM artifacts, diagrams, implementation
specifications, or implementation from an accepted specification.

This repository is itself a valid LeanFM project. `book/main.pdf` always exists
and is a central input to Codex, not merely a publication output.
`book/main-dark.pdf` is the equivalent accessible reading copy generated from
the same source.
Use it together with the live LeanFM language references, the accepted
`LeanFM/LLMGenerated/Requirements.lean`, `Requirements.proto`,
`Implementation.lean`, and the existing source tree. Keep these canonical
self-hosting specifications together at that stable project-relative location.

Every new project has one exclusive project-root directory. Put every
project-owned input, book snapshot, specification, source file, test, generated
view, event trace, report, log, and project-specific cache below that root; no
configured output or symlink may escape it. External LeanFM installations and
content-addressed shared dependency caches may be reused only when they contain
no project-owned state. Any global project index must be reconstructible from
the project roots. Deleting one project root must remove all state owned by that
project without searching elsewhere.

During a requirements conversation, use LeanFM to derive and show the user the
requested interaction diagrams, state machines, order graphs, charts, metrics,
and reports. A visual or number must retain the prompt, question, event source,
reducer, unit, and boundary that justify it. Do not substitute an independently
drawn diagram for a generated view of the current specification.

Before satisfying any feature request, review its stability and security
ramifications. State the intended positive invariant (commonly an always/AG
property), then identify applicable forbidden behavior as explicit negative
requirements (commonly never or AG not-bad properties). Consider regression,
failure, concurrency, resource, authorization, isolation, secret, injection,
and path-boundary consequences in proportion to the change. Map every material
negative requirement to an implementation control and negative test or proof;
do not call the feature complete while a material risk is unmitigated.

Work in three layers, in order, checking each before the next:

1. observable requirements and their derived outputs;
2. the separate implementation specification and its traceability mappings;
3. the source, written in one pass from the checked specifications.

Review and acceptance happen in git: the user reviews diffs and commits them.
LeanFM records no approvals, and an agent must not stop to ask for one. When
the user asks for the implementation, write and check whatever specification
it needs, then implement the actual code in one pass. Do not answer with an
implementation plan when the user has requested the implementation. Preserve
conforming existing code, edit the source tree, add or update tests, and run the
repository checks. Missing or contradictory durable information is a reason to
return to specification, not permission to guess from chat history.

Useful repository commands:

```sh
make check
make book
make serve
make http-check
```

The local service defaults to `http://127.0.0.1:8080`. Its authoritative routes
include `/tools/leanfm-language/requirements-reference`,
`/tools/leanfm-language/implementation-reference`,
`/tools/requirements/interrogation`, `/tools/code-generation/prompt`,
`/tools/generated-artifacts/validate`, `/renders/`, and `/metrics`.
