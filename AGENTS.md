# LeanFM agent instructions

These instructions apply to the entire repository.

Read and follow `SKILL.md` whenever a request involves requirements discovery,
design or architecture arguments, LeanFM artifacts, diagrams, implementation
specifications, or implementation from an accepted specification.

This repository is itself a valid LeanFM project. `book/main.pdf` always exists
and is a central input to Codex, not merely a publication output.
`book/main-dark.pdf` is the equivalent accessible reading copy generated from
the same source.
Use it together with the live LeanFM language references, the canonical
specifications in `LeanFM/LLMGenerated/`, and the existing source tree:

- `SelfHosting.lean`: LeanFM's own requirements, one clause per behavior
  (MCP, hosting, the logic tools and their view, the session-type library, and
  the proposed workflow). Start here to learn what LeanFM is held to.
- `McpLogicImplementation.lean` and `SessionImplementation.lean`: how each of
  those clauses is implemented and tested.
- `Requirements.lean`: the registry (`selfHostingRequirement` and the accepted
  components); its Worker types and `Requirements.proto` are a preserved example
  of the requirements language, not a description of LeanFM.
- `Implementation.lean`: the implementation registry and its status summary.

Keep these canonical self-hosting specifications together at that stable
project-relative location.

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

**Features need strong implication; security guarantees need weak implication.**
Write a feature as `(leadsTo a b)` or `(stronglyImplies a b)`: its trigger `a`
must be able to happen (`possibly a`), so a system that never allows it fails.
Write a security guarantee as `(weaklyImplies a b)` or a `never`: a trigger that
can never happen is fine. Never write a feature as `(always (implies a b))`,
which passes vacuously when `a` cannot happen. `possibly` speaks of some future,
which LTL cannot express; this is why requirements are written in CTL.

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

An agent with a shell in this repository does its own work: it edits any file, the Makefile
included, and runs the builds, tests and checks itself, then reports what passed. It never
commits or pushes, and never asks the user to commit or push so that something can be checked:
everything is checked in the working tree, and the user reviews the diff and commits.

The agent stages its work with `git add`, because only the agent knows which new files belong.
It stages source, specifications, tests, and the generated outputs meant to be read in git (the
dark book PDF, generated views and reports the book or README points at). It does not stage
build byproducts (Lake output, LaTeX intermediates, caches, logs); when such a file shows up
untracked and is not yet ignored, it adds a rule to `.gitignore` instead. Before finishing it
reports `git status --short` so the user sees exactly what is staged.

LeanFM is developed with the LeanFM method. A change to LeanFM starts in its own requirements
(`LeanFM/LLMGenerated/SelfHosting.lean`), then the implementation mapping
(`SessionImplementation.lean`, `McpLogicImplementation.lean`), then the source, each checked
with LeanFM's own tools (the MCP server from `make serve`) before the next.

LeanFM's own specification is the default example for testing the MCP session-type viewer
(session_explore and the other views): the distillation chain from the book through
`SelfHosting.lean` and the implementation mappings to the source, and LeanFM's own protocols
(MCP client and server, the tools it serves). Other projects such as GoServer are secondary
examples. If a view cannot show LeanFM yet, that gap is the work to do, not a reason to switch
examples.

Only steps the agent's environment refuses (a sandbox that cannot write a file or run a
command) go in `./update` at the project root, rewritten for each request. Keep each step safe
to run again, never commit or push from it, and do not ask the user to paste commands instead.
`./update` is in `.gitignore` and is never added to git.

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
