# Candidate implementation specification: Paxos key-value application

Status: accepted by the user on 2026-10-01 and implemented in this repository.

This document maps the accepted requirements in `PAXOS_KV_SCENARIO.md` to an
implementation. It does not change their observable meaning.

## Target and processes

- Target language: Go.
- One `paxos-kv` executable with subcommands `web` and `replica`.
- One WebApp process and three independently started replica processes.
- Replica IDs and addresses are supplied explicitly; membership is fixed at
  `kv-0`, `kv-1`, and `kv-2`.
- Browser traffic uses HTTP. Replica protocol traffic uses length-delimited
  protobuf messages over TCP connections.

## Durable state

Each replica owns a separate data directory containing an append-only accepted
log and a small metadata file for the highest promised ballot. Every update is
written to a temporary record, flushed with `fsync`, and atomically made visible
before `DurableAccepted` is sent. Recovery scans and validates the log, truncates
only an incomplete final record, and reconstructs accepted slots. No process
shares a replica data directory.

The leader records commit decisions durably. On startup or leadership change it
runs Paxos recovery against a quorum before accepting HTTP work, choosing the
accepted value with the highest ballot for each slot and filling any gaps.

## Consensus and reads

- Stable-leader Multi-Paxos assigns monotonically increasing log slots.
- Ballots are ordered pairs `(counter, replica_id)`.
- A candidate must receive promises from two replicas before becoming leader.
- A value is committed after two distinct replicas have durably accepted the
  identical `(ballot, slot, key, value)` tuple.
- Repeated messages are idempotent by `(ballot, slot)` and browser
  `(session_id, request_id)`.
- The materialized key/value map applies committed slots in increasing order;
  this implements last-committed-slot-wins.
- A list request uses a quorum read barrier and returns one applied committed
  prefix. A successful PUT waits until its slot is applied, then obtains the
  listing from a prefix at least that new.

## Web application

- `GET /` obtains a linearizable listing and renders the form followed by the
  sorted key/value table.
- `POST /put` accepts form fields `key` and `value`, validates encoded byte
  limits, submits the write, and renders the resulting listing.
- A secure random cookie supplies `session_id`; every request gets a unique
  `request_id`.
- HTML is escaped. Request bodies, response bodies, and internal queues are
  bounded. Two browser sessions may progress concurrently.
- Failures return an explicit page and appropriate HTTP status; they never
  display an uncommitted value as successful.

## Resource choices

- Web request body: 8 KiB maximum.
- WebApp: 64 in-flight requests and a bounded 128-item submission queue.
- Each replica: bounded 256-message inbound queue and 64 simultaneous peer
  operations.
- Database: 10,000 distinct keys, with limits enforced before proposal.
- Timeouts cancel a client attempt but do not erase a value already accepted;
  retries use the same request ID and discover the committed result.

## Observability

Every protocol transition emits the accepted LeanFM event envelope with event
ID, repeated predecessor IDs, browser session, task/request ID, concrete source
and destination replica IDs, monotonic time, and protobuf atom. `/metrics`
exports commit latency, quorum size, available replica count, recovery lag,
request outcomes, queue depth, and memory headroom under the accepted output
IDs. Logs include ballot and slot but never unescaped HTML.

## Generated source layout

```text
cmd/paxos-kv/main.go
internal/web/app.go
internal/paxos/node.go
internal/paxos/leader.go
internal/paxos/storage.go
internal/paxos/recovery.go
internal/protocol/requirements.proto
internal/protocol/requirements.pb.go
internal/metrics/metrics.go
internal/trace/events.go
web/templates/index.html
traceability.json
```

## Conformance tests

- Two browser sessions write different keys concurrently and both listings
  converge to the same committed map.
- Two sessions write one key concurrently; the later committed slot wins.
- Every HTTP success has two prior durable acceptances from distinct replicas.
- Stop any one replica during writes; the other two continue and the stopped
  replica catches up after restart.
- Stop all replicas after acknowledged writes; restart two and recover every
  acknowledged value before serving.
- Corrupt or truncate the final log record and verify safe recovery without
  inventing a commit.
- Reject oversized, empty-key, and 10,001st-key writes without mutation.
- Reject conflicting values for one slot, stale ballots, malformed protobuf,
  and illegal trace order.
- Exercise full queues, timeouts, idempotent retries, and HTML escaping.
