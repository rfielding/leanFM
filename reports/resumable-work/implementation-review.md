# Client-driven continuation implementation

This separately realizes the accepted resumable-work requirements. The fixed
sixteen-round terminal failure becomes an internal four-round batch boundary.
The four-round size bounds one request; it never limits the complete task.

`Provider.lean` returns a structured checkpoint after executing a completed
provider round's tools. It saves the OpenAI response frontier and tool results,
or the equivalent Anthropic message frontier. Each subsequent client request
continues that frontier. Actual tool receipts, failed-operation history,
validation state and cumulative usage survive. Oversized context is compacted
from the original task, current durable files and verified receipts so a long
task does not depend on unbounded chat history.

`chatui_work_state.py`, through the existing fixed command whitelist, stores
atomic job/checkpoint/receipt records under the selected project's protected
`.leanfm/work/`. No bearer or API key is stored. Full one-way session and
credential tags bind the job to its original account, credential, project and
model. A new login needs explicit resume; changed keys cannot reuse the old
provider frontier. A checkpoint is consumed before another paid request.
Duplicates return an already stored receipt or a visible non-billable conflict.
An uncertain in-flight response cannot be replayed automatically.

The existing project writer lock protects each batch. A thirty-second
inter-batch reservation prevents another writer from interleaving edits while
the client immediately continues. Closing the client leaves a paused checkpoint;
expiry releases the reservation so the project cannot remain locked forever.
Intervening project edits invalidate the old frontier and require an explicit
restart from current durable files. All work state disappears with the project.

The existing chat POST gains optional stable work/request and checkpoint IDs;
successful partial responses add server-owned continuation/progress metadata.
A read-only owner-authorized work-status route reconciles an interrupted client
response. The React client keeps the original queued prompt active in a loop of
bounded requests, refreshing real progress and artifacts between batches. It
adds one original user message, keeps later queued prompts waiting, and keeps
Cancel available across all phases. It trusts server response metadata rather
than assistant text. Legacy ordinary completed responses remain compatible.

Completion remains tied to the requested artifacts and their checks. Separate
human questions and acceptance gates pause work. Unavailable compilers,
unchanged failures, repeated work without useful progress, ambiguous provider
failures, cancellation, ended credentials and the existing cumulative session
budget stop further automatic calls. A batch never resets those controls.

| Forbidden behavior | Implementation control | Required negative evidence |
| --- | --- | --- |
| Repeat an already executed batch or tool | Atomic checkpoint consumption and cached receipts | Concurrent replay and interrupted-response tests count exact provider calls and file writes |
| Resume with another project, account, session, key or model | Server authorization against the protected work record; explicit re-login resume | Cross-caller/project/model/key tests fail before spending |
| Forget spend, cancellation, source gates or failed-tool history | Carry task state between batches; retain per-round session charging | Both provider fixtures preserve cumulative usage and stop immediately on exhaustion/cancel/repeated failure |
| Forge a continuation through model prose or file writes | Server-issued metadata; reserve work paths from model writes, patches and served routes | Injection, symlink, reserved-path and forged-checkpoint tests |
| Make tasks fail merely for exceeding sixteen steps | Four-round resumable batches with no total step cap | Both-provider and real-browser tasks exceed the old cap and finish verified artifacts |
| Continue forever without new work or after the client closes | Verified progress receipts, persistent failure brakes and client-owned scheduling | No-progress and stopped-client tests issue no additional batch |
| Leave the project permanently busy | Expiring inter-batch reservation with retained paused state | Expiry and changed-revision tests preserve work while permitting future writers |
| Hide a compiler fault behind unrelated checks or billable retries | Two-thread compiler and typed fatal worker outcome | Real compiler/isolation and both-provider startup-failure regressions |

Typed mapping: `LeanFM/LLMGenerated/ResumableWorkImplementation.lean`; references
resolve against the accepted candidate requirement IDs. Planned tests are
`scripts/chatui_work_state_test.py`, `scripts/chatui_multi_provider_test.py` and
the production `scripts/chatui_browser_reset.py`, plus existing checks.

Implementation acceptance: pending. No continuation runtime has been implemented
merely by authoring this mapping.
