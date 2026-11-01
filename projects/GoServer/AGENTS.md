# GoServer agent instructions

This directory is the exclusive project root. Read `book/main.pdf` (or
`book/main.tex`), `spec/Requirements.lean`, `spec/Requirements.proto`,
`spec/Implementation.lean` and the existing `source/` before changing
anything. Chat history is disposable; the book and spec are the record.
Keep `manifest.json`'s `project_id`: LeanFM uses it to discover the project.

The N-Player Go Lab engine in `source/cmd/demo/static/engine.js` is the rules
reference; `source/engine.go` ports it. The browser app is React + TypeScript in
`source/web` (built into `source/cmd/demo/static/app/`, which is not tracked);
keep UI pieces as components so they are easy to move around.

Work in the LeanFM order: book, then requirements, then implementation
mapping, then source. Before a feature, state its positive invariant and its
negative requirements, and map each material negative requirement to a control
and a negative test in `source/traceability.json`. After a change run
`make spec-check`, `make views`, `make app-check`, `make browser-check`, and
`make tour` when the UI changed, then `make book`. Keep all project state
(cache, reports, renders) under this directory; `make run` serves on 8081,
never LeanFM's 8080.

Review and acceptance happen in git. The "Known gaps" chapter of the book is
the work queue: when an item is closed, remove it there and add the evidence
under `reports/`. Never commit conversations, sessions, provider keys,
passwords or build caches.
