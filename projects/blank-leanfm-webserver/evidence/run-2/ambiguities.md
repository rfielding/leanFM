# Requirements Gate 1 ambiguities

Source boundary: only `book/main.pdf`, the generic `LeanFM/` authoring library, and `bootstrap/` tools were used.

1. Chapter 12 fixes the accepted protocol but does not specify finite inbound/outbound queue capacities, per-actor in-flight limits, or memory budgets. The positive `1` values required by the generic validator are placeholders, not accepted capacity targets.
2. Actor population sizes and production routing are not fixed. Single instances and sticky correlation routing are placeholders for validation; the book only says the server binds loopback by default and that provider request identity must remain request-local.
3. No outage probabilities, heartbeat/progress detector cadence, timeout, attribution boundary, MTTR, dependency gate, or recovery order is specified.
4. No offered-load population, observation window, latency percentile/bin, throughput floor, USL fit inputs, warm-up/censoring policy, or overload behavior is specified.
5. No infrastructure cost, demand curve, availability target, currency, or permitted supply set is specified.
6. Branch probabilities and dwell times are unknown. Transition probability `1/1` denotes that a listed transition is legal, not an empirical branch distribution; `dwellMs = 0` means no book-specified dwell contract.
7. The canonical schema names `EventEnvelope`, whereas the generic reference asks for `ScenarioEvent`. This reconstruction preserves the book's normative `EventEnvelope` and adds only a `Scenario` container; acceptance should decide whether an alias is required.
8. Chapter 12 says the canonical schema is normative, but its compact Lean field table flattens repeated/nested fields. `Requirements.proto` preserves the canonical repeated/nested cardinalities; the current generic `ProtoFieldSchema` can record only scalar boundaries.
9. The book states common HTTP statuses and the accepted route projection, but transport belongs to Implementation Gate 2 and is intentionally absent from Gate 1 Lean requirements.
10. Account creation requires an API-key check, but the accepted prose does not state credential storage lifetime, encryption-at-rest policy, provider timeout, or retry behavior.
11. Authentication credential format, password hashing policy, session lifetime/rotation/revocation, CSRF policy, and rate limits are not specified.
12. Project deletion confirmation semantics and recoverability are unspecified.
13. Artifact status vocabulary and legal promotion/supersession/staleness transitions are described conceptually but not exhaustively enumerated.
14. Web research allows searches and supplied URLs, but URL safety policy, redirect limits, content limits, citation validation, and provider failure taxonomy are unspecified.
15. Markerboard accepted/rejected revision conflict behavior is mentioned through HTTP 409 guidance but exact optimistic-concurrency predicates are not stated in the task grammar.
16. Accessibility is an observable success criterion in the project README, but the book's protocol chapter supplies no concrete accessibility conformance level or UI interaction requirements.
