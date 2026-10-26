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

Published HTTP conversions are observable interoperability requirements, not
implementation choices. Keep methods, paths, encodings, headers, status
alternatives, authentication, correlation and framing in Requirements.lean;
Implementation.lean selects libraries and runtime machinery that realize them
and must not override the accepted wire contract. A changed released conversion
requires a requirements revision and compatibility evidence. Existing
implementation-owned bindings still need migration; see CRITIQUE.md.

When generating an HTTP adapter, derive OpenAPI from the resolved protobuf
request/response pairs and accepted requirements-owned HTTP contract. A default
mapping is a proposal for requirements acceptance, not permission to change a
released interface. For an otherwise ordinary default mapping, use path or query
parameters only for explicitly bounded URL-safe scalar selectors; use POST with
the protobuf request body for bytes, repeated or nested values, secrets, large
or unbounded strings, or parameters that do not naturally belong in a URL.
Unless an explicit binding selects another codec, encode HTTP bodies with the
protobuf JSON mapping and `Content-Type: application/json`. Publish the resolved
OpenAPI document at `GET /openapi.yaml`. Preserve events as independently
framed messages: every event projected as an HTTP response must set `cause_id`
to the exact corresponding request event ID within the same session and task.
`prior_ids` separately governs predecessor order and legal interleavings; never
use it as the causal pointer. Pair exchanges by `cause_id`, never by adjacency
or a global current request. Validate closure in both directions: every HTTP
request is the cause of exactly one terminal success or error response, and
every HTTP response names one compatible request in the same session and task.
Treat an orphan or multiply answered call as an invalid unchecked HTTP binding.
Do not restrict `cause_id` to HTTP or terminal events. Any intermediate event or
nested task boundary may name one direct cause. Validate that causes exist and
are acyclic, derive causal subtrees for nested interaction boxes, and do not
infer `prior_ids` or a sibling order from causal containment.

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

For every feature request, review stability and security before declaring the
feature complete. Record the desired behavior as a positive invariant (usually
always/AG), then identify applicable forbidden behavior as negative invariants
(usually never or AG not-bad). Consider regression, failure, concurrency,
resource, authorization, isolation, secret, injection, and path-boundary
effects in proportion to the change. Map every material negative invariant to
an implementation control and negative test or proof. An unmitigated material
risk blocks completion.

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

### Start and resume from the project root

A fresh agent invocation needs only the project-root directory. Load the
manifest, editable and rendered book, canonical requirements and protobuf,
canonical implementation mapping, acceptance revisions, source tree, generated
views and evidence from their stable project-relative paths. Do not require the
user to paste an earlier transcript or manufacture a bootstrap prompt.

If the project has no durable problem statement, begin by asking: "What problem
are you trying to solve?" Do not begin with framework selection or a proposed
solution. After the answer, identify concrete ambiguities whose resolution can
change observable requirements, derived views, proof obligations, or
implementation choices. Resolve routine choices using existing conventions and
reasonable reversible defaults within recorded requirements and authorization.
Record the decisions; briefly list only those the stakeholder may challenge.
Ask only about a consequential ambiguity that no authorized default resolves,
or a missing explicit acceptance gate. Name its concrete effect on scope,
observable behavior, compatibility, security/privacy, irreversible data or
material spending and the artifact or gate it affects. Compiler syntax,
formatting and already-authorized validation are engineering work: inspect the
logged exit code and diagnostic, narrow and check the correction, and never
repeat an unchanged failure class or ask the stakeholder to approve that work.
A readiness review can report ready with zero questions; it must not manufacture
questions. These defaults neither override a recorded requirement nor accept
either gate for the stakeholder. Each subsequent turn should do at least one of:
record a durable decision, update a derived view, ask a blocking ambiguity,
report deterministic validation, or advance an explicit acceptance gate.

Revise the project book as durable understanding develops. Regenerate
`book/main.pdf` and `book/main-dark.pdf` from the same editable source and link
the prose and diagrams to the requirement, implementation and evidence
revisions they explain. The conversation may disappear; the project directory
must remain sufficient to resume.

## Consolidate the vibecoded book

Treat the working book as an intentionally permissive design notebook during
discovery: it may contain stream-of-consciousness exploration, alternatives,
and ideas that never become requirements. Before an acceptance gate or a
one-shot implementation, perform a separate conservative cleanup pass:

- classify each normative idea as accepted in `Requirements.lean`, assigned to
  `Implementation.lean`, explicitly deferred, or removed;
- preserve technical claims and necessary qualifications while deleting
  repetition, throat-clearing, and defensive restatement;
- when prose is mainly describing actors, message flow, states, ordering,
  dependencies, or quantities, create the corresponding `DesiredOutput` and
  replace most of that prose with the generated view plus a short interpretation;
- give every generated PDF figure meaningful invisible alt text; for an
  interaction diagram, pronounce each arrow as `Message from A to B: message`
  in diagram order rather than relying on an arrow glyph or implication-like
  notation;
- never promote a speculative book passage into an implementation obligation
  merely because it survived an early draft.

The cleanup phase does not make the book secondary. It makes the relationship
between the central design argument and the accepted typed artifacts explicit.

## Settle the implementation specification

After requirements acceptance, resolve implementation choices in
`Implementation.lean`: target language and files, actor instances and
homogeneous clusters, routing, bounded queues and memory, concurrency,
transports, protobuf bindings, failure handling, observability, tests, and
requirement-to-code traceability. Keep implementation choices out of
`Requirements.lean` unless they change observable behavior.

Treat an accepted multi-actor wire grammar as the conformance oracle: complete,
decoded traffic is either legal under that grammar or has a counterexample; an
incomplete capture cannot establish conformance. During implementation, ask
questions until the accepted behavior can be realized. Store answers that do
not change observable behavior in `Implementation.lean`, each mapped to the
requirements it realizes. If an answer changes a message, field, ordering, or
other observable behavior, return to the requirements gate instead. If a later
requirements change makes an implementation answer unnecessary, remove that
implementation detail without preserving it as a requirement.

Validate the requirements and implementation independently and together. Use
recorded choices and reasonable defaults for routine implementation details;
ask only about consequential unresolved choices. Ask for explicit acceptance
of the implementation specification. Before that gate,
do not represent application code as the final implementation.

## One-shot the actual code

Before generating or editing implementation source, perform an explicit
security critique of the accepted design and implementation mapping. Treat
security requirements primarily as forbidden observable behavior: write
durable `MUST NOT` constraints for unauthorized access, cross-tenant or
cross-project disclosure, secret persistence or logging, path and symlink
escape, injection, unsafe media or executable content, unbounded resource use,
request confusion, replay, privilege expansion, and fail-open behavior wherever
they apply. Name trust boundaries, protected assets, attacker capabilities,
abuse cases, and the intended failure response. Map every applicable negative
requirement to an implementation control and at least one negative test or proof
obligation. If a material threat has no accepted mitigation, return to the
implementation-specification gate; do not generate source and do not silently
invent policy. A security critique does not itself accept either gate.

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

For an application goal, the implementation pass must deliver a working
`source/Makefile` with uniform `build`, `run`, `stop`, `test`, `check`, `clean`,
and `serve` targets. Keep `run` in the foreground and `serve` as its alias;
`stop` affects only the project-owned app. Use relative asset/API URLs and
record `relative_urls: true` for the isolated preview. Launch with the native
Start app control or `workspace_launch`, and return the verified served Open app
link after readiness. The separate terminating smoke test uses `make run`, using a bounded loopback port separate from
LeanFM. Record its fixed launch contract in `spec/runtime.json` (version 1,
kind `http`, directory `source`, command `["make", "run"]`, host `127.0.0.1`,
port, readiness_path and page_path), then use the project-confined runtime
check to observe actual startup and its page. Preserve the original goal,
resolved defaults, exact failure remedies, verification and remaining gaps in
`spec/ProjectMemory.md`, with PR/base-revision context when applicable. These
records and current source/specifications must suffice after every conversation
is deleted. A library-only goal remains a library. Launch evidence must identify
its exact input revision and cannot imply full semantic refinement.
