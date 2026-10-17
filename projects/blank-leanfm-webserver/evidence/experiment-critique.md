# Blank reconstruction experiment: Gate 1 critique

## Experiment boundary

A fresh Codex session (`gpt-5.6-sol`, low reasoning) ran in an unrelated
temporary Git repository. Its only design input was the light and dark copies
of `book/main.pdf`; local instructions prohibited reading the original LeanFM
source, specifications, history, or prior conversation. The session stopped at
the requirements acceptance gate. It used 70,477 tokens.

The exact candidate returned by that session is preserved in this project.
Nothing in this report accepts it.

## What the book successfully reconstructed

- Three externally visible actors, ten ChatUI tasks, and 55 protobuf payload
  types.
- The major user-visible conversations: account creation, login, project
  management, provider credentials, chat, markerboard work, artifact
  inspection, task-model inspection, web research, and markerboard assistance.
- Immutable event backpointers, per-session and per-task correlation,
  request-local provider credentials, project-root containment, authentication,
  owner isolation, credential redaction, bounded queues, byte budgets, and
  generated-view provenance as stated obligations.
- A parseable protobuf candidate and an elaborating Lean 4 candidate.
- One interaction view and one residual-state review section per task.
- A useful ambiguity register instead of silently inventing all missing policy.

This is enough to recover the recognizable *shape* of the intended web server.
It is not enough to one-shot a compatible implementation.

## Where the reconstruction failed as LeanFM

1. **It did not produce a LeanFM specification.** Because the blank project did
   not contain the LeanFM authoring API and the experiment prohibited consulting
   the installation, the agent invented a standalone `Task` containing a finite
   list of complete traces. It does not use `LeanFM.RequirementSpec`,
   `TaskGrammar`, `GrammarExpr`, `DesiredOutput`, message schemas, required
   proofs, or LeanFM's validators. `lean` accepting the file proves only that
   this invented model is valid Lean syntax and types.

2. **The diagrams are parallel hand-maintained artifacts.** Their prose says
   they are generated from the candidate, but no generator or checked mapping
   connects them to `Requirements.lean`. They can drift. Several state-machine
   edges also collapse two to four messages into one transition, so they are
   summaries rather than actual residual grammars after every event.

3. **The proofs are cosmetic.** The four theorems check counts and one endpoint
   example. They do not establish trace legality, session isolation, project
   containment, secrecy, bounded memory, temporal properties, serialization
   agreement, or diagram derivation.

4. **The book did not make the wire contract reproducible.** The agent had to
   invent envelope tags 1--7, payload tags 20--74, collection cardinalities,
   logical-time representation, presence rules, and opaque `bytes` payloads.
   A new server could parse its own journal while being incompatible with the
   intended one.

5. **The claimed complete grammar is not a complete server contract.** MCP,
   health/static/tool routes, collection routes, error bodies, JSON projection,
   cookies, retries, cancellation, timeouts, duplicate delivery, durability,
   and recovery remain unspecified. Thirty-four ambiguities are recorded.

6. **Major advertised LeanFM capabilities disappeared.** The candidate contains
   no CTL fixed-point obligations, probabilities or MDPs, epistemic/deontic
   predicates, fork/join or race semantics, reliability reductions, or checked
   resource accounting. Some do not belong in every web-server requirement,
   but the language must remain available to express them without being
   reinvented.

7. **The blank project was not self-hosting enough.** The repository workflow
   says agents must obtain the live requirements reference and interrogation
   prompt before authoring. In this run, those were deliberately absent. From
   the parent environment the advertised reference routes currently redirect
   to the login page, so even a permitted fresh agent could not bootstrap from
   them without credentials. The book alone describes the concepts but does
   not provide an executable language package.

8. **The rendering toolchain was not project-declared.** Mermaid source was
   produced but not rendered because the clean room had no renderer. A copyable
   project needs a reproducible command or dependency manifest for every
   required derived view.

9. **The prompt cost is high.** Reading a 123-page, roughly 38,000-word book and
   reconstructing Gate 1 consumed 70,477 model tokens. The book works as durable
   context, but it needs a compact, indexed machine contract so every run does
   not rediscover normative material from narrative prose.

## Criticism of the LeanFM design

The experiment supports the central thesis: a book can carry enough design
intent for a fresh model to recover a coherent requirements conversation. It
also exposes a circular dependency. To create checked LeanFM artifacts from the
book, an agent already needs the LeanFM language definitions, validators,
renderers, and an accessible reference endpoint. The book is central context;
it is not a substitute for the language distribution.

A copyable LeanFM project therefore needs a small, versioned bootstrap contract:

- the LeanFM language/library version and a reproducible way to obtain it;
- unauthenticated local access, or project-scoped credentials, for language
  reference and validation routes;
- canonical protobuf envelope tags and nested payload schemas;
- a machine-readable task/message/route index generated from accepted specs;
- deterministic commands that elaborate, validate, and render every derived
  view; and
- explicit classification of each book statement as requirement,
  implementation choice, example, or deferred idea.

With that bootstrap contract, the book can remain the main argument while the
machine index prevents expensive reinterpretation and invented lookalike DSLs.

## Gate decision

Do **not** accept this candidate unchanged. It is strong evidence that the book
communicates the product, but it is not a checked LeanFM requirement and cannot
yet serve as the input to a one-shot implementation. Revise Gate 1 by rerunning
the candidate through the actual LeanFM authoring API and validators, deriving
the views from that value, and resolving at least the wire-compatibility,
session/security, bounded-resource, HTTP/MCP, and durability ambiguities.
