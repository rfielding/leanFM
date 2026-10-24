# Historical resumable-work runtime pause checkpoint

This records the state at `9230c4b`. The later sixteen-step failure report
resumes this work; `integration-evidence.md` records the current outcome.

The user explicitly requested a commit checkpoint and pause. Both specification
gates remain accepted; runtime implementation is saved on
`work/resumable-chatui-20261023`. It is not merged into the verified main branch.

Implemented on that branch: project-owned atomic work records and receipts,
full caller/credential tags, protected checkpoint paths, four-round provider
frontiers, client continuation and recovery controls, inter-batch reservations,
context compaction and persistent usage/failure state. Legacy clients retain a
larger batch but receive checkpoints rather than a total task-step failure.

Passed: final `make check`, `make book`, work-state and compiler/gate tests,
provider tests including checkpoint-alias isolation, the production Chrome
workflow, all 23 multi-provider tests (including 25-round tasks on both providers
and zero extra calls on replay), and all four shared-project tests.

Remaining: the complete HTTP shell suite exits unsuccessfully after its Python
tests and PDF checks. The last captured book-update reply selected an earlier
missing-image fixture response. Investigate the deterministic provider's prompt
matching and the remaining shell assertions; do not claim the full suite passed.
No live model inference was used for verification. The new runtime has not been
deployed to the running primary service.

Local diagnostics are under `.cache/model-picker-review/`; the last retained
HTTP fixture is `.cache/chatui-check.Nqb1gf/`. These operator/runtime files are
excluded from Git. All live project state and the credential vault stay local.

Resume from this committed runtime branch, rerun the failing HTTP check, then
refresh evidence hashes and deployment validation before merging. The accepted
component artifacts are immutable; historical shared-project acceptance records
refer to the earlier canonical files and need explicit snapshot/evidence
bookkeeping for the added canonical resumable-work exports.

Commit security review: the snapshot includes source, tests, rebuilt same-source
book PDFs, generated fixture evidence and this truthful verification record.
Staged paths and contents are checked for keys, bearers, private logs, runtime
projects and whitespace. Caller isolation, replay protection, checkpoint path
boundaries and the existing human gates retain negative-test coverage. A failed
functional check remains explicitly open on this separate branch.
