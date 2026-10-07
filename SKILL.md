---
name: leanfm
description: Argue a software design into checked LeanFM requirements and implementation specifications, render prompt-derived diagrams and metrics during the conversation, then implement the accepted specifications in the actual source tree. Use for requirements discovery, architecture disputes, LeanFM artifact generation, or spec-driven implementation.
---

# LeanFM requirements-to-code workflow

Use LeanFM as the durable memory and visualization engine for a requirements
argument. The conversation is provisional; checked artifacts are authoritative.

## Inputs

Every LeanFM project, including the LeanFM repository itself, always contains
`book/main.pdf` as a central Codex input. `book/main-dark.pdf` is an accessible
rendering of the same source, not a different specification. Read
`book/main.pdf` as part of the language and method reference. When source
and rendered book are both available, also call the live language-reference
routes below; report any material disagreement rather than silently choosing.

Preserve these separate inputs:

- `Requirements.lean`: observable behavior, grammars, properties, desired
  outputs, and proof obligations;
- `Requirements.proto`: values that resolve to bytes, without choosing their
  transport;
- `Implementation.lean`: runtime, transport, file, actor, channel, and message
  mappings justified by requirement IDs;
- the existing source tree: code to preserve, revise, or replace after the
  specifications are accepted.

## Keep one project in one directory

At project creation, choose one exclusive project root and record it in the
project manifest. Create or snapshot the exact book at `book/main.pdf` beneath
that root and generate `book/main-dark.pdf` from the same source. Store all
project-owned requirements, implementation
specifications, source, tests, generated views, traces, reports, logs, and
project-specific caches beneath the same root. Reject output paths and symlinks
that escape it.

A LeanFM installation and a content-addressed dependency cache may be shared
outside project roots only when they contain no project-owned mutable state.
Any external project index must be disposable and reconstructible by scanning
project manifests. Deleting the project root must delete the complete project;
never require a user to discover project files elsewhere.

Keep `Requirements.lean`, `Requirements.proto`, and the one canonical accepted
`Implementation.lean` together at stable project-relative paths recorded by the
manifest. Multiple deliberate implementation targets may use explicitly named
sibling files, but each must identify its target and retain full traceability.
Copying the project root must yield a directory ready to initialize or use as a
repository with Codex; it must not require project-owned state from LeanFM's
installation.

## Connect to LeanFM

Use `${LEANFM_URL:-http://127.0.0.1:8080}`. Before authoring artifacts, obtain:

- `/tools/leanfm-language/requirements-reference`
- `/tools/leanfm-language/implementation-reference`
- `/tools/requirements/interrogation`

For the implementation pass also obtain `/tools/code-generation/prompt`.
If the service is not running in this repository, build it and start it on the
loopback interface. Do not guess the LeanFM object language when the reference
cannot be obtained; state the limitation.

## Argue toward requirements

Treat disagreement as requirements discovery. On each substantive turn:

1. Identify the claim, boundary, or missing observation under dispute.
2. Update the durable requirements artifacts when the new information changes
   the model.
3. Re-run the relevant Lean elaboration and LeanFM validation.
4. Regenerate the affected views from the specification and event reducers.
5. Show the user the resulting diagram, chart, metric, report, or validation
   result and name the prompt/question it answers.

Do not hand-author a persuasive diagram independently of the model. Every
interaction diagram, state machine, scalar, and 2D function rendering must have
`DesiredOutput` provenance: originating prompt, precise question, observable
event source, reducer, unit, and accounting/scenario boundary.

Plan the complete derived-output catalog before freezing the event schema.
Default to one interaction diagram and one residual state machine per
`(session, scenario)`, adding prior-pointer order graphs for concurrency,
fork/join, and nested task-start/task-complete structure. Include only metrics
and charts that answer an explicit prompt. Numeric event reductions should be
available at `/metrics`; visual results should be available through `/renders/`
or another generated artifact named by the requirement.

Continue the argument until the user explicitly accepts the requirements
specification. Do not interpret silence, a successful build, or an attractive
diagram as acceptance.

## Settle the implementation specification

After requirements acceptance, resolve implementation choices in
`Implementation.lean`: target language and files, actor instances and
homogeneous clusters, routing, bounded queues and memory, concurrency,
transports, protobuf bindings, failure handling, observability, tests, and
requirement-to-code traceability. Keep implementation choices out of
`Requirements.lean` unless they change observable behavior.

Validate the requirements and implementation independently and together. Ask
for explicit acceptance of the implementation specification. Before that gate,
do not represent application code as the final implementation.

## One-shot the actual code

Once both specifications are explicitly accepted, perform one implementation
pass using all of these inputs together:

```text
book/main.pdf
Requirements.lean
Requirements.proto
Implementation.lean
existing source tree
```

One-shot means edit the actual project files and tests to completion in the
current turn; it does not mean produce another plan, sample, scaffold, patch
description, or prose implementation. Inspect the existing code first,
preserve conforming behavior, replace conflicting behavior, generate required
bindings and runtime paths, and add deterministic conformance tests and a
traceability manifest. Each generated code unit and test must cite its durable
requirement justification.

Do not ask design questions already settled by the accepted artifacts. If an
essential decision is still absent or contradictory, stop rather than inventing
it, identify the exact durable field or obligation that prevents implementation,
and return to the appropriate specification phase.

Finish only after running the repository's proportional build, tests, LeanFM
artifact validation, and generated trace round trips. Report changed source
files, validation evidence, and any requirement that could not be implemented.
