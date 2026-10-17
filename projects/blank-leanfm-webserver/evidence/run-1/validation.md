# Requirements-discovery validation evidence

Run date: 2026-10-15. Working directory:
`/tmp/leanfm-reconstruction.V3BLfD`.

## Input custody

- `book/main.pdf` SHA-256:
  `b46bdf51fcff8a81d231810155f299ee337da4eb28fa1340a600bd83d294407b`
- `book/main-dark.pdf` SHA-256:
  `627ca892175d63caf51eca00b6ce5847a37f3542940c321f6a98e79846f8cff0`
- `pdftotext -layout` output for the two PDFs compared byte-for-byte equal.
- No original repository, Git history, prior specification, or implementation
  source was inspected.

## Deterministic checks

| Check | Result | Scope |
|---|---|---|
| Lean 4 elaboration (`lean -o .cache/requirements-validation/Requirements.olean specification/Requirements.lean`) | PASS | Syntax, types, four stated theorems (task/message counts, alternative count, endpoint example). |
| Protobuf parse/descriptor generation (`protoc --proto_path=specification --descriptor_set_out=...`) | PASS | Proto syntax, tag legality/uniqueness, referenced message types. |
| Payload oneof count | PASS: 55 | Every named payload has a discriminator in fields 20–74. |
| Proto top-level message count | PASS: 56 | One envelope plus 55 payload messages. |
| Typed task count | PASS: 10 | Matches chapter 12.7–12.16. |
| Interaction review sections | PASS: 10 | One per typed task. |
| Residual state names | PASS: 10 | One per typed task. |
| Requirement records | PASS: 15 | Each has a stable ID and book section provenance. |
| Ambiguity records | PASS: 34 | All known gaps are explicit at this gate. |
| Markdown/Mermaid fence balance | PASS: 22 fences | All generated diagram blocks are closed. |
| No implementation or test source | PASS | No `Implementation.lean`; `source/` and `tests/` contain no authored files. |
| Mermaid renderer | NOT RUN | No Mermaid CLI was installed; source remains reviewable Markdown. |
| Temporal/model checking | NOT CLAIMED | Bounds and a LeanFM temporal checker are not provided by the book-only environment. |
| Metrics/reliability validation | INDETERMINATE | No event corpus, targets, bounds, or probability/dwell inputs exist. |

Lean emitted a non-fatal warning that it could not query the latest release and
used installed Lean `v4.28.0`; elaboration exited successfully.

## Candidate artifact digests

- `specification/Requirements.lean`:
  `34c295864774f7bdd8aef798fa9bdd087778d31155312cf09b11a3d32f602baa`
- `specification/Requirements.proto`:
  `a57471444fde859bd22b2add6d0bc7425aaab72d1bb3e5135a49c3f495a01f34`
- `generated/review/interaction-diagrams.md`:
  `d6bcf57ccf1fd233eee30898660deb2a78a74c0654847bec5d401fb1c3a069a3`
- `generated/review/state-machines.md`:
  `749ef1bf48d3fca05630c9372d7ebee116cd7ab863bc4f1873e846328f6df992`

These hashes identify the exact candidate offered for requirements acceptance.

## Evidence classification

- **Proved by Lean:** only the four small finite facts named above.
- **Parsed/structurally checked:** protobuf and artifact/task coverage counts.
- **Derived review views:** interaction and residual state Markdown/Mermaid.
- **Assumed/open:** security details not explicitly fixed by the book, queue
  bounds, byte budgets, temporal liveness, capacity, probabilities, and
  durability strength; see `evidence/ambiguities.md`.
