# Book ambiguities and missing requirements

This log is part of the candidate requirements gate. Nothing here was filled
from an original repository, prior specification, or general knowledge of
LeanFM. “Candidate choice” means the protobuf needs a concrete choice to parse,
but stakeholder acceptance or revision is still required.

| ID | Book gap or conflict | Candidate treatment / consequence |
|---|---|---|
| AMB-001 | The envelope metadata fields are named, and payload tags must start at 20, but metadata tags and payload-to-tag assignments are not printed. | Candidate assigns metadata 1–7 and payloads 20–74 in book order. Wire compatibility is unconfirmed. |
| AMB-002 | “Clock timestamp/time” is required, but epoch, resolution, monotonicity, wall-vs-logical semantics, and overflow are absent. | Candidate calls field 5 `logical_time` (`uint64`); timing claims remain indeterminate. |
| AMB-003 | The compact message table prints scalar types but not repeated cardinality. | Fields whose names and prose clearly imply collections are `repeated`; all others are singular. Review every such choice. |
| AMB-004 | Proto3 scalar presence/requiredness and validation rules (empty identifiers, maximum lengths, string normalization) are not specified. | Schema is proto3; semantic requiredness is an open validator obligation. |
| AMB-005 | No maximum protobuf payload, message, attachment, media, source, URL, list, or envelope size is given. | No invented bound; memory safety and admission behavior cannot yet be proved. |
| AMB-006 | Every actor queue must be finite, but inbound/outbound capacities and overflow/backpressure timeouts are not given. | REQ-011 is an unresolved proof obligation; performance behavior is indeterminate. |
| AMB-007 | Actor byte budgets and active-work footprints are required but no values or accounting rules are supplied. | REQ-012 is unresolved; only encoded queued bytes are directly measurable. |
| AMB-008 | Concrete actor populations, maximum concurrent users/sessions/tasks, scheduling fairness, and provider-channel bounds are absent. | No capacity, starvation, or scalability claim is made. |
| AMB-009 | No response-time bound, timeout, retry, cancellation, idempotency, or duplicate-delivery policy is stated. | Grammars constrain order only; liveness and retry safety remain unspecified. |
| AMB-010 | Task probabilities, dwell distributions, observation windows, histogram bins, tolerances, and percentile targets are absent. | No probability or latency chart is fabricated; such metrics are indeterminate. |
| AMB-011 | Outage/recovery events, reliability target, uptime target, and MTTR target are absent for this server. | Reliability views requested by the general method cannot be generated for this target. |
| AMB-012 | Identifier uniqueness scope and event-id generation are not specified. | REQ-002 requires uniqueness but leaves algorithm and scope for acceptance. |
| AMB-013 | Rules for predecessor count, roots, joins, cycles, cross-session/task links, and logical-time order are not fully stated. | `prior_ids` is repeated and immutable; graph validity needs stakeholder rules. |
| AMB-014 | The success/failure grammar often omits provider response before a server failure (for example research and chat), leaving unclear whether late provider messages are legal or discarded. | Candidate legal traces match the printed grammar exactly; late events are illegal. |
| AMB-015 | `research_web` admits exactly one `WebSearchPerformed` and one `WebPageOpened`; whether multiple queries/pages are represented by repeated fields or repeated events is unclear. | Candidate follows one event each, with repeated query/URL strings where printed. |
| AMB-016 | Provider and model support, credential verification semantics, billing-source values, and retention values/lifetimes are not enumerated. | Strings remain open vocabularies; interoperability and policy checks are unresolved. |
| AMB-017 | Login/account credential algorithms, password policy, session expiry/revocation/rotation, cookie `Secure` behavior on loopback, CSRF defense, and rate limiting are absent. | Only secrecy, HttpOnly/SameSite, session gating, and status behavior explicitly stated by the book are requirements. |
| AMB-018 | The book requires a “secure cookie” and later says HttpOnly/SameSite, but does not name cookie value encoding, SameSite value, path/domain, lifetime, or HTTPS policy. | Transport security details await the implementation gate, subject to an accepted observable policy. |
| AMB-019 | Account/project/artifact deletion recovery, retention, tombstones, audit behavior, and confirmation-string semantics are absent. | Only exact-root containment and the printed request/response are specified. |
| AMB-020 | Artifact lifecycle statuses are described as current/accepted/superseded/stale/candidate, but legal status strings and transition rules are not fully defined. | Status fields remain strings; only promotion conversation order is constrained. |
| AMB-021 | Artifact revision concurrency beyond `base_revision` is not defined: conflict outcome, merge policy, monotonicity, and replay behavior are missing. | No silent merge behavior is assumed. |
| AMB-022 | Mermaid rendering sandbox, supported syntax/version, SVG sanitization, media types, content-URL lifetime, and malicious content policy are absent. | Markerboard grammar is specified; safe rendering acceptance criteria remain open. |
| AMB-023 | Web research domain policy, redirects, private-network access, fetch limits, citation-part format, and clickable-citation validation are absent. | The returned source URL list is represented; SSRF and citation correctness require requirements. |
| AMB-024 | `parts`, `artifacts`, and encoded objects are opaque bytes without nested protobuf types. | Byte-level semantics, bounds, content types, and canonical encoding are unresolved. |
| AMB-025 | HTTP request/response JSON field names, complete status mapping per alternative, bytes encoding, error schema, and 204 rejection’s relationship to the event journal are not fully specified. | Proto is transport-neutral; these are deferred from requirements unless stakeholders want HTTP observables fixed now. |
| AMB-026 | Chapter 12 lists an accepted HTTP projection sourced from an implementation specification, while gate rules prohibit deriving `Implementation.lean` now. | HTTP rows are treated as book context, not encoded in this observable grammar candidate; transport mapping awaits gate 2. |
| AMB-027 | `/api/me`, conversation/task collection routes, static assets, health, MCP details, validation tools, and generated downloads lie outside the complete ChatUI grammar; their observable contracts are incomplete. | They are excluded from the task grammar rather than guessed. |
| AMB-028 | MCP protocol version(s), resource contents/URIs beyond examples, tool schemas, errors, limits, and authentication when exposed are incomplete. | No MCP wire requirements are invented in this candidate. |
| AMB-029 | Atomic promotion, crash consistency, journal fsync/durability, corruption recovery, backup, and import/export consistency are not defined. | Project containment and atomic rename are required; durability strength is unresolved. |
| AMB-030 | Whether globally shared content-addressed caches are allowed to contain sensitive derived project bytes is not stated. | Mutable project state is forbidden outside the root; privacy rules for immutable shared cache entries need acceptance. |
| AMB-031 | The book names expected generated statistical views, but supplies no target event corpus for this reconstruction. | Interaction/state views are generated; empirical metrics are correctly reported unavailable. |
| AMB-032 | The exact LeanFM authoring library/API is outside the permitted initial inputs. | `Requirements.lean` is a standalone Lean 4 semantic model rather than an import of unknown LeanFM code. |
| AMB-033 | “Unique immutable event id” is implied by immutable predecessor identifiers but no explicit collision behavior is stated. | Candidate makes uniqueness an obligation; collision response is unresolved. |
| AMB-034 | The grammar does not say whether tasks can repeat within one task id/session or how a new task instance is distinguished. | Candidate boundary is one conversation; task-instance/correlation multiplicity needs clarification. |
