# IslandUploads

File uploads across islands that may be partitioned for a day. Every page shows its
classification banner at the top and the bottom; wherever people are, they see the same files,
the same latest versions and the same banners once replication has caught up. Writes never wait
for another island.

| Layer | Files |
| --- | --- |
| Book | `book/main.tex` → `book/main.pdf`, `book/main-dark.pdf` |
| Requirements | `spec/Requirements.lean`, `spec/Requirements.proto` |
| Session types | `spec/Session.lean` (global types, physics, deployment tree) |
| Models for the MCP server | `spec/Islands.lean` → `reports/mcp/*.task.json` |
| Implementation mapping | `spec/Implementation.lean` |
| Evidence | `reports/specification-check/`, `reports/mcp/results.json` |
| Source | `source/` (not yet written) |

```sh
make check   # spec-check and the session-type guards
make mcp     # models, then ask the LeanFM MCP server (make serve in the LeanFM root)
make book
```
