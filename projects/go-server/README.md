# GoServer — playable n-player Go

A working local-first browser board and Go HTTP server. Default: four colors,
11×11, suicide and repetition allowed, score = territory − losses. Includes
client-side worker MCTS, keyboard navigation, immutable branching history,
real animated GIF export ending at the selected node, and independently
authenticated network seats. No model API/key or paid call is used.

From this project root:

```sh
make run             # http://127.0.0.1:8082
make check           # Lean, protobuf, race, differential and HTTP conformance
make browser-check   # actual Chrome: MCTS, keyboard, GIF and two-user game
make book            # both PDFs; old PDFs retained on compiler failure
```

Dependencies: the parent LeanFM installation with `lake`/Lean, Go 1.23+ (the
parent's pinned `.toolchains/go` is reused), Node 18+, `protoc`, Python with
`protobuf`; browser checks additionally need `google-chrome` and Python
`websocket-client` and `Pillow`. PDFs need `pdflatex` with TikZ, accsupp and Latin Modern.
The new Go module uses only the standard library, not the old gorilla module.

## Durable inputs and evidence

Read [the book](book/main.pdf), its [dark copy](book/main-dark.pdf), and
[the exact rules](spec/working-contract.json). Canonical
[requirements](spec/Requirements.lean), [protobuf values](spec/Requirements.proto)
and [implementation mapping](spec/Implementation.lean) are adjacent. Published
HTTP conversions belong to requirements. `/openapi.yaml` is generated from
their routes and official protoc descriptors. Source is exclusively `source/`.

[Traceability](evidence/playable-v1/traceability.json) maps R1–R6 to controls,
negative tests and evidence. [Browser evidence](evidence/playable-v1/browser.json)
includes the selected state and observed protocol traces. The
[screenshot](evidence/playable-v1/board.png), [cell labels](evidence/playable-v1/board-labels.txt)
and [actual GIF](evidence/playable-v1/selected-line.gif) are produced by the
served application, not placeholders. `make check` validates observed HTTP
values against generated protobuf bindings and Lean-derived task grammars.

This is an explicitly requested **implementation experiment**, not retroactive
acceptance of the conflicting old drafts or a theorem about deployed Go/JS.
The protocol checker supports the event/sequence/choice constructors used here;
it does not claim general LeanFM grammar recognition. MCTS is a bounded Max-n
heuristic, not established optimal play. Screenshots are evidence, not a gate.

## Playing and isolation

Arrow keys select a labeled intersection; Enter/Space plays. Back/Forward and
the variation selector navigate local history. New local moves preserve sibling
branches. The AI checkboxes choose human/computer colors; thinking is performed
in a cancellable worker, with Pass always considered and a 60-second turn cap.

Create a two-player room and open its invitation in a **separate browser profile**
for the other player. An invitation permits reading/joining an empty seat, not
impersonating an occupied seat. A tab keeps its own token in session storage,
so reload resumes that seat; server snapshots contain only token hashes.
Network history review is read-only. State polling catches up overdue Passes.
Browser loss/score tables and all grid points are text-labeled, not canvas-only.

The server binds only to loopback, rejects non-loopback Host and cross-origin
mutations, and enforces body/time/storage limits. This is not an Internet-facing
production deployment. The CLI's `-data` must be project-relative with no symlink
escape. `.runtime/` contains private snapshots and generated exports; `.cache/`
contains project-specific builds, test profiles and complete compiler logs.
Never commit either. Shared LeanFM/toolchain inputs contain no project-owned
mutable state. Copying/deleting this root copies/deletes its entire state.

The old scaffold under `spec/internal/`, `spec/api/requirements.pb.go` (a
handwritten approximation), and `spec/legacy/` drafts are archived, unused
inputs. They are not generated bindings or the playable implementation. No
account, provider key or private conversation is included in this project.
