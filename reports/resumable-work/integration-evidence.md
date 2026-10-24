# Resumable work integration

The reported implementation turn exhausted sixteen rounds while repairing
`String.protobuf`, `String.protobufMessage`, a list where `ChannelCodegen` was
required, and malformed record syntax. This resumes the previously accepted
resumable-work implementation, saved at `9230c4b`, and integrates it with the
completion-feedback repair at `1fdb54a`.

Both artifact sets in `acceptance.json` were checked against their recorded
SHA-256 values and are unchanged. The canonical self-hosting Requirements and
Implementation modules now export these accepted component specifications.
Earlier shared-project acceptance records remain historical records of their
reviewed bytes at `3601911`; they are not silently rehashed to cover a new
composition. `make check` validates the resulting component composition and
traceability. This is structural validation, not a deployed-code proof.

Positive invariant: one Send keeps the original task active through bounded
client-owned batches until its checked result, a human gate, cancellation, or
an explicit blocker. Four rounds bound a normal client request; there is no
total task-round cap. Legacy requests retain a larger batch and receive a
checkpoint when necessary. The original session spend boundary still applies.

The implementation reference now embeds a complete checked implementation
module with companion requirements. `wireType` is a String naming the payload
type. `channels` is one record with explicit channel semantics; capacity is a
requirements resource field. Tests compile the exact advertised module and
validate its requirements traceability. The platform also tells the model to
use Project memory's revision-bound acceptance controls instead of inventing
an acceptance question that cannot record a gate.

| Forbidden behavior | Control | Negative evidence |
| --- | --- | --- |
| Fail only because total work exceeds sixteen rounds | Native provider frontiers and four-round client loop | Both providers finish a 25-round specification and a 31-round mapping repair; production Chrome finishes 25 rounds |
| Replay tools or paid batches after a duplicate/uncertain response | Atomic claim consumption, bounded stored receipts, owner-authorized status reconciliation; no automatic replay of uncertain in-flight requests | Work-state transactional tests and exact provider call counts on replay |
| Reset validation or failure brakes at a checkpoint | Persist checked-input hashes, dirty-spec and dirty-implementation flags, exact compiler failure, completion-feedback candidates, failed-tool history, observations and cumulative usage | Both-provider requirements repair crosses checkpoints; mapping regression reproduces String and ChannelCodegen failures across batches, preserves requirements acceptance and leaves implementation unaccepted |
| Continue as another account, key, model or unapproved new session | Full one-way caller/credential tags plus explicit same-account resume; existing writer and session checks | Cross-caller/model/key/session unit cases; shared-project and multi-provider isolation tests |
| Forge a checkpoint or retrieve native provider context as a public artifact | Project-owned protected `.leanfm/work`, fixed command whitelist, identifier/path/symlink guards and root binding | Reserved-path, alias, traversal, foreign-root and raw-key absence tests |
| Continue forever without progress or after client closure | Client schedules each batch; persistent no-progress brake and spend guard; unavailable compiler/unchanged failures stop immediately | No-progress and budget cases; startup failure still stops without another paid round |
| Block other project writers permanently between batches | Expiring reservation, input-revision guard, explicit restart from changed files | Reservation-expiry and changed-input tests; concurrent writer rejection |
| Generate source or invent acceptance during mapping repair | Existing current-revision acceptance controller and source guards | 31-round regression leaves source empty, requirements accepted and implementation checked but unaccepted; stale/source-gate tests |

The saved branch's open shell failure was isolated during final verification.
Fixture selection now follows the current turn instead of old markers in
conversation/diagnostic context. Usage assertions parse the JSON object rather
than relying on object-key ordering introduced by stored receipts. Token values
and exact call counts remain asserted.

Executed validation: `make check`; `make book`; `ProviderTests.lean`; five
transactional work-state tests; the complete
`LEANFM_TEST_BROWSER=1 bash scripts/chatui_http_check.sh`, including production
Chrome, 25 multi-provider tests, four shared-project tests, restart/unlock
checks, and PDF contrast/range checks. Both compiled book variants contain the
updated implementation and continuation documentation. Browser evidence is in
`reports/chatui/reset-browser.json` and its screenshot.

The new 31-round scenario produces two real compiler failures, attempts to
finish after each, crosses eight client requests, then checks the corrected
mapping. Usage is exactly 31 provider responses, each charged once. The checked
requirements revision and its explicit acceptance remain unchanged. No source
or implementation acceptance is fabricated.

Tests use local deterministic providers and isolated accounts/projects, with no
live model inference. They verify orchestration, validation and negative
boundaries rather than predicting a live model's success rate. A provider
transport failure or uncertain in-flight result still requires explicit recovery;
it is not automatically repeated.

Commit review covers the exact source/fixtures, component exports, checked
reference example, generated PDF text and browser screenshot. No account vault,
live project, native checkpoint, runtime log or cache is a commit candidate.
Both gates remain human-owned. No unresolved material finding remains in this
integration.

Deployment: restarted the idle local service with `make stop` / `make serve`.
Live HTTP/MCP smoke passed. The served client contains work/checkpoint request
fields and the live implementation reference contains the exact checked
example. The selected project's current requirements acceptance and checked,
unaccepted implementation state were verified after restart. No live inference
or account-credential access was needed for these checks.
