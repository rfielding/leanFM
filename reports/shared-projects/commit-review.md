# Repository snapshot review

Requirement references: `property:security_review_precedes_commit`,
`property:feature_completion_pairs_positive_and_negative_invariants`, and the
accepted shared-workspace revision in `acceptance.json`.

Positive invariant: the tracked repository contains the complete LeanFM source,
canonical specifications, book variants, portable agent configuration, tests and
sanitized conformance evidence needed to build and verify a fresh workspace.
Runtime project directories and the credential vault remain local.

The commit includes the explicitly approved removal of the checked-in GoServer
and blank-server example trees. New projects are provisioned from built-in
templates; required checks exercise an installation without examples.

| MUST NOT behavior | Control and evidence |
| --- | --- |
| Track credentials, password records, account ciphertext, sessions or cookies | Explicit staging; `.leanfm/`, `data/`, projects and caches ignored; staged pathname and content scan |
| Publish private runtime logs or old account/project inventories | Root logs and operator inventory reports excluded; retained locally outside the commit |
| Omit a required runtime helper or the accepted specification | All new command, compiler, gate, workspace, media and reset helpers staged with the importing code and traceability records |
| Claim all generated applications are proved correct | Evidence explicitly identifies local provider fixtures, real compilers, structural validation and the absence of a deployed-code refinement proof |
| Commit unsafe generated views or executable media | PDFs come from the tracked book sources; browser PNG comes from the isolated production-UI fixture; no generated executable or project media is staged |
| Introduce unreviewed authorization, path, injection or billing behavior | Exact implementation diff reviewed against `implementation-evidence.md`; negative shared-project, compiler, media, gate, provider and HTTP tests pass |

Validation carried forward from the implementation: `make check`, `make book`,
`make http-check`, the production Chrome workflow, and the focused gate,
workspace-reset, compiler, execution, credential, patch, media and framing tests.
The final staged snapshot additionally passes secret/path and accepted-artifact
hash checks. Whitespace checks preserve the trailing blank line in the
hash-bound accepted implementation review; all other whitespace checks pass.
