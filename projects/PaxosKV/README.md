# PaxosKV

A key/value database replicated by Paxos across three replicas, with a
one-page web front end. Two browser sessions can write at the same time; a
write is acknowledged only after two replicas have fsynced it, and every
listing is one committed prefix of the log. Data survives restarts.

This is the reference LeanFM example: small enough to read in one sitting,
complete from book to running code.

| Layer | Files |
| --- | --- |
| Book | `book/main.tex` → `book/main.pdf`, `book/main-dark.pdf` |
| Requirements | `spec/Requirements.lean`, `spec/Requirements.proto` |
| Implementation mapping | `spec/Implementation.lean`, `source/traceability.json` |
| Derived views | `spec/Views.lean` → `renders/` |
| Source | `source/` (Go) |
| Evidence | `reports/` |

## Commands

From this directory, after `make build` in the LeanFM root:

```sh
make spec-check     # compile + validate the Lean spec, derive spec/tasks.json
make views          # regenerate renders/ from the requirements
make app-check      # go vet + go test -race
make run            # kv-0..kv-2 on 9100-9102, web app on http://127.0.0.1:8082
make browser-check  # in a second terminal: two concurrent browser sessions
make book           # light and dark PDFs
make stop
```

`make -C source clean-data` deletes replica state in `.cache/data/`.

## Open gaps

See the "Known gaps" chapter of the book. The biggest: replicas log only
terminal events without `priorIds`, so a real run cannot yet be replayed
through the trace and CTL checkers.
