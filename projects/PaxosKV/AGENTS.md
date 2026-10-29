# PaxosKV agent instructions

This directory is the exclusive project root. Read `book/main.pdf` (or
`book/main.tex`), `spec/Requirements.lean`, `spec/Requirements.proto`,
`spec/Implementation.lean` and the existing `source/` before changing
anything. Chat history is disposable; the book and spec are the record.

Work in the LeanFM order: book, then requirements, then implementation
mapping, then source. After a change run `make spec-check`, `make views`,
`make app-check`, and with the app running `make browser-check`, then
`make book`. Keep all project state (cache, events, reports, renders) under
this directory. Review and acceptance happen in git.

The "Known gaps" chapter of the book is the work queue. When an item is
closed, remove it there and add the evidence under `reports/`.
