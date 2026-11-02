# IslandUploads agent instructions

This directory is the exclusive project root. Read `book/main.pdf` (or `book/main.tex`),
`spec/Requirements.lean`, `spec/Requirements.proto`, `spec/Implementation.lean`,
`spec/Session.lean` and `spec/Islands.lean` before changing anything. Chat history is
disposable; the book and spec are the record.

Work in the LeanFM order: book, then requirements, then implementation mapping, then source.
After a change run `make check`, `make mcp` (with the LeanFM server running), then `make book`.
The "Open questions" chapter lists what the source would otherwise decide by guessing; resolve
those in the specification first. Review and acceptance happen in git.
