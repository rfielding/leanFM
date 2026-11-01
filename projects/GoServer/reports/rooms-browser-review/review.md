# Room creation and working browser requirements review

Prompt: “Remove the fake links, put in a place to create chat rooms, and put game challenges in the chat rooms.”

Current code: the browser is an inspection harness with hard-coded lobby and demo-game buttons. There is no CreateRoom request or route; a core provisioning helper exists but is not a typed, correlated operation. No fake anchor links were found in this source. The requested replacement is a browser using real listed rooms and named challenges. The failed Anthropic request is a billing rejection, not a completed edit.

Proposed behavior: create a uniquely named public room, enter it, create/list/open its named challenges, and use separate room and challenge conversations. Local demo identities and in-memory lifetime remain explicit. The UI shows actionable errors and pending state; no unsupported gameplay destinations are offered. Room creation uses a bounded name, the existing session, and a request ID; it follows the same success/rejection and replay contract as existing mutations. Challenge names become available in creation results and listings through additive protobuf fields.

Positive invariant (AG): every visible room, challenge and conversation reflects authorized server state for the selected room/game.

| Forbidden behavior | Proposed implementation control | Required negative check |
| --- | --- | --- |
| Unauthenticated, malformed or oversized creation mutates state | Session check, UTF-8/rune limits, strict bounded JSON | Invalid token/name/body leaves room and game counts unchanged |
| Duplicate retry or racing admission creates extra objects | Existing serialized operation/replay path; capacity/duplicate check in the same critical section | Same-ID replay, conflicting reuse, concurrent name collision and capacity races |
| A substituted room/game identifier discloses chat | Membership checks before reads and writes | A second identity cannot read/post before entry; no cross-room/game delivery |
| Late browser responses replace the selected scope | Selection generation guard; clear old content on selection | Delay an old room/game response, switch scope, and assert old content stays absent |
| User text becomes executable HTML | DOM textContent and element construction | Render markup-like room/challenge names and chat literally |
| Placeholder navigation fabricates destinations | Build selectors from authoritative listings; actions use server IDs | Empty listing has an empty state; every visible action reaches an actual route |
| Session credential appears in output or leaves loopback | Keep credential internal; Host/Origin guards, no URL token | Page/log token absence; foreign-origin/Host/method requests reject |
| Creation exhausts room/game memory | 16 rooms and 64 challenges per room; existing bounded chat/replay | Exhaustion rejects without mutation |
| Outputs escape the project root | No user-controlled file paths; project-confined checks/cache | No source or artifact path is derived from room/challenge names |

No deployment, registration, persistence or playable Go board is introduced. Existing channel/protobuf conformance audit findings remain open; this review does not claim full semantic refinement. Runtime manifest currently says 8082 while make run defaults to 8081; the implementation review must reconcile that mismatch.

Acceptance: the protected earlier gates are preserved. This changed requirements revision is pending explicit acceptance. A separate checked implementation mapping will follow requirements acceptance.
