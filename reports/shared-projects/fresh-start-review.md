# Fresh-start requirements revision

Status: concrete requirements proposal, not accepted by validation.

The requested outcome is a repaired LeanFM with an empty ordinary-project
workspace. A new project must be created, specified, checked, reviewed and
implemented through ChatUI without depending on examples or an earlier chat.

## Reset scope

Discard these five ordinary project roots, including their chats, books,
specifications, implementation experiments, generated media and caches:

- `data/accounts/rob/projects/c931835956ab201b` (live GoServer)
- `projects/go-server`
- `projects/blank-leanfm-webserver`
- `projects/kubernetes-document-site`
- `projects/world-risk-2026-10-10`

Preserve the LeanFM repository itself: its source, book, canonical specifications,
tests and Git history. Preserve encrypted API keys and account login records
byte-for-byte, placing them in `.leanfm/accounts/`. They are not projects.
No project deletion may follow a symlink outside the enumerated root. Remove
`./data` only after credential preservation has been verified.

## Required behavior

1. Every ordinary project lives entirely in `projects/<project_id>/`, independent
   of account identity. Its manifest records the book, requirements, protobuf,
   implementation mapping, source, evidence and acceptance paths.
2. Open, list, create, inspect and edit projects without credential login. Login
   unlocks only the initiating caller's model keys. Provider-backed work requires
   that caller's valid unlocked session; local validation requires no key.
3. A fresh project visibly asks for the problem. Normal chat advances actual
   typed specifications and their generated views, rather than repeatedly asking
   permission to edit, validate, rebuild or import an existing attachment.
4. Requirements acceptance and implementation-specification acceptance remain
   separate explicit decisions tied to the actual checked artifacts. Missing
   gates are named once; earlier accepted decisions are not reopened by default.
5. Only a successful current canonical check can justify specification completion.
   Failed checks retain bounded diagnostics and last-valid views. Edits and
   provider calls are bounded and project-confined; model work cannot use another
   caller's key or collide silently with another project writer.
6. A real production-browser regression creates a fresh project and reaches a
   checked simple server specification using deterministic local providers,
   with no examples, old conversations, external coding client or real API bill.

Positive invariant: one self-contained shared root per project and one private
credential identity per paid operation. Negative requirements forbid credential
disclosure, cross-site mutation, path/symlink escape, overlapping writers,
fabricated acceptance, stale completion and unbounded paid recovery.

The typed source is `LeanFM/LLMGenerated/SharedProjects.lean`, including
`explicit_fresh_start_erases_projects_not_credentials`. Structural validation
and implementation-reference resolution pass. See the generated
[interaction](manage_projects.interaction.mmd), [state machine](manage_projects.state.mmd),
[full requirements review](requirements-review.md), and separate
[implementation mapping](implementation-review.md).

The implementation gate is separate. Validation and this review accept neither
gate. The earlier request to preserve old project contents is superseded only
for the explicitly enumerated reset; account preservation still applies.
