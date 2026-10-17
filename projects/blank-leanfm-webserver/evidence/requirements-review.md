# Candidate requirements review

## Acceptance boundary

This gate asks whether the observable protocol in
`specification/Requirements.lean`, the byte vocabulary in
`specification/Requirements.proto`, and their review views are acceptable.
It does **not** accept a programming language, runtime, HTTP handler design,
storage engine, deployment, or `Implementation.lean`.

## Included

- Three actors and 55 named message payloads.
- Ten task grammars with every alternative printed in book chapter 12.
- Length-delimited protobuf event envelopes with predecessor, correlation,
  logical-time, endpoint, and exactly-one-payload data.
- Endpoint matching, trace legality, immutable backpointer, authentication,
  owner isolation, credential secrecy, loopback, project containment,
  concurrency, bounded-queue, byte-budget, provenance, and evidence-kind
  requirements.
- Per-task interaction and residual-state review views.

## Explicitly not claimed

- No original LeanFM source or prior specification was consulted.
- No server implementation or implementation specification was created.
- Compilation proves syntax and the three small theorems only; it does not
  discharge open temporal, memory, security, or durability obligations.
- No performance/reliability measurements exist without an event corpus and
  stakeholder-supplied bounds.
- Candidate protobuf envelope tag choices are not claimed wire-compatible with
  any prior system.

## Decision requested

Accept, reject, or revise this observable candidate. In particular, acceptance
should explicitly acknowledge AMB-001 through AMB-034 or supply values/rules
for the ambiguities that must be settled before implementation design.
