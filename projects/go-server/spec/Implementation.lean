/- Implementation mapping: package layout and runtime/component plan for the
   n-player Go server (minimal Go skeleton, WebSocket + HTTP, DuckDB
   persistence, proto-based JSON on the wire). -/
namespace Project.Implementation

/- High level package layout (suggested):

cmd/goserver/main.go         -- program entrypoint, HTTP router, lifecycle
internal/server              -- WebSocket/HTTP handlers, connection manager
internal/game                -- board model, n-player ruleset primitives
internal/store               -- persistence adapter (DuckDB), migrations
api                          -- generated protobuf Go stubs and wire helpers
scripts                      -- helper scripts (proto generation, build)

-/

/- Runtime components and actors:

1. Main (process) - starts HTTP server, initializes store and game manager.
2. ConnectionManager (actor in internal/server) - manages WebSocket client
   sessions, routes incoming Commands -> GameManager, and broadcasts Events.
3. GameManager (in internal/game) - maintains in-memory games, applies
   observable-command handlers (validate move, update board, run rule
   engine), and emits Events for persistence and broadcast.
4. Store (in internal/store) - durable write-ahead persistence and query
   operations against DuckDB; also supports snapshot/restore for GameManager.
-/

/- Message mapping (implementation notes):

- Use the proto-defined Requirements.proto as the canonical message schema.
  During development, wire payloads may be sent as JSON over WebSocket/HTTP
  (encoded/decoded with the generated proto->Go types). A scripts/generate_proto.sh
  is provided to run protoc --go_out and produce api/ requirements stubs.

- ConnectionManager will accept client JSON commands, unmarshal to proto
  Command messages, and forward typed commands to GameManager methods.
-/

/- Minimal API surface (initial skeleton):

- HTTP /health
- HTTP /ws (WebSocket upgrade for command/event exchange)
- HTTP /games (REST list/create for convenience)
-/

/- Build, dev and generation helpers:

- scripts/generate_proto.sh -- runs protoc against spec/Requirements.proto
- go mod in project root under module github.com/leanfm/c931835956ab201b
- Makefile targets (not included here) should wrap the script and go build/test
-/

/- Development guidance / next steps:

1. Run scripts/generate_proto.sh (requires protoc and protoc-gen-go)
   to populate api/ with generated Go message types.
2. Implement GameManager rule engine in internal/game; include unit tests
   for n-player capture, liberties, and turn order.
3. Wire persistence via internal/store to DuckDB using a simple events table
   and snapshots for fast restore.
4. Harden ConnectionManager: authentication, per-connection goroutine model,
   backpressure, and graceful shutdown.
-/

/- Short lived notes on minimal skeleton included in repository:

The repository contains a small, runnable Go skeleton under cmd/goserver and
internal/ which starts an HTTP server and exposes a WebSocket endpoint.
It deliberately keeps dependencies minimal and provides a script to generate
proto stubs from spec/Requirements.proto rather than committing generated
code so that generated code is always reproducible.
-/

end Project.Implementation
