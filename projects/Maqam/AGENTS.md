# Maqam agent instructions

This directory is the exclusive project root. Read `book/main.pdf` (or
`book/main.tex`), `spec/Requirements.lean`, `spec/Requirements.proto`,
`spec/Implementation.lean`, `spec/Maqam.leanfm` and the existing `source/`
before changing anything. Chat history is disposable; the book and spec are the
record. Keep `manifest.json`'s `project_id`: LeanFM uses it to discover the
project.

`source/` is a snapshot of https://github.com/rfielding/maqam at the revision
named in `manifest.json` (`upstream_revision`), reverse-engineered into the
specification. It is a Rust terminal application with real-time audio, not a
web app: there is no HTTP runtime to launch.

Work in the LeanFM order: book, then requirements, then implementation mapping,
then source. Before a feature, state its positive invariant and its negative
requirements, and map each material negative requirement to a control and a
negative test in `source/traceability.json`. After a change run `make check`
(spec-check, protocol check, cargo build and test) and `make book`.

Never copy, print or commit `.tone3000-auth.json`, `.nam/` captures, API keys,
`.globals.ml` or recordings. The "Known gaps" chapter of the book is the work
queue: when an item is closed, remove it there and add the evidence under
`reports/`. Review and acceptance happen in git.
