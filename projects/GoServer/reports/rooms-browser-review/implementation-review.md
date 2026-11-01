# GoServer implementation review

Requirements accepted explicitly in this Codex session; the trusted revision controller recorded the answer and retained prior snapshots.

Candidate: spec/Implementation.lean, including roomsBrowserDecisions. Preserve the Go core and local inspection adapter. Add the typed correlated CreateRoom operation, expose stored challenge names, build a real browser room/challenge workspace with embedded assets, and expose membership-checked retained chat for that workspace. Keep all state in memory and make run at 127.0.0.1:8081. Use the uniform source/Makefile build/run/stop/test/check/clean/serve contract, with a foreground run and scoped stop. No provider request or new dependency is needed.

Security critique: the local browser and its JSON are untrusted; the Go core owns identities, room/game membership, authoritative results and finite storage. An attacker can submit arbitrary names/bodies/IDs, replay IDs, race requests, navigate while old requests are pending and submit foreign origins. MUST NOT controls and negative checks are in review.md. The implementation also closes the existing replay-eviction duplication hole by bounding accepted mutations rather than evicting accepted results, and fixes the already-accepted blocking-channel contract. The existing global 64-challenge admission bound is retained, which also enforces the per-room maximum and avoids multiplying worst-case chat storage by 16 rooms.

Validation proposed: Go core/HTTP tests with the race detector; original independent channel probe; a real Chrome create-room/create-challenge/chat/navigation/isolation flow; project-confined startup check. Broader protobuf byte/event conformance findings remain explicit existing follow-up work, not a claim of full refinement.

This checked mapping is proposed for the separate explicit implementation gate. No application source has been edited for this revision.
