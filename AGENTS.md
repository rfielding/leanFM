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

There are two explicit acceptance gates:

1. observable requirements and their derived outputs;
2. the separate implementation specification and its traceability mappings.

After both gates, implement the actual code in one pass. Do not answer with an
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
