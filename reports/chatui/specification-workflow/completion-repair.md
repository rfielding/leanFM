# Requirements completion repair

The reported turn wrote invalid `RequirementMarkdown`, then replaced it with a
candidate missing task FSMs, grammars, communicating processes, properties,
negative obligations and generated outputs. Each canonical rejection reached
the provider as a tool result, but its final prose ended the turn. ChatUI then
replaced that prose with a generic unchecked-specification error.

The runtime now rejects premature completion inside the same provider
conversation. It returns the bounded concrete diagnostic, allows correction and
another canonical check, and reports success only for current validated bytes.
An unchanged candidate and diagnostic stop further provider work. A fatal tool
result returns before the runner records a successful check. Terminal failures
retain the concrete cause instead of only advising the user to run the compiler.

The requirements reference embeds `LeanFM/ReferenceExamples/Request.lean`, a
complete example checked with its matching protobuf. Its tests also check that
the live reference includes that exact source. The guided prompt explains that
small scope does not remove mandatory behavior collections and that compiler
repair is already-authorized work. Existing requirement
`recoverable_failures_are_fixed_before_return` and the implementation decision
`guided-specification-artifact-tools` justify the repair; neither project
acceptance gate is inferred.

The Responses protocol preserves `previous_response_id` with an additional
input message, following the official
[conversation-state documentation](https://developers.openai.com/api/docs/guides/conversation-state).
Anthropic retains its native assistant/user history. The continuation consumes
the original request's remaining rounds, preserves cancellation and session
checks, and accounts for each response once. Main still has its original
16-round budget; the separately paused resumable-work runtime is not merged.

Executed checks:

- `make check`, including the checked reference module and its protobuf tests.
- `make book`; both compiled PDFs contain the updated workflow documentation.
- `lake env lean LeanFM/ChatUI/ProviderTests.lean`.
- `LEANFM_TEST_BROWSER=1 bash scripts/chatui_http_check.sh`: production Chrome,
  23 multi-provider tests, shared-project authorization/gate checks, and
  password-unlocked sessions across restart.
- `python3 scripts/http_smoke.py http://127.0.0.1:8080` after loading the new
  local runtime: health, production UI, live language references and read-only
  MCP validation.

The new provider regression reproduces both reported failures and two attempts
to finish. Each provider repairs them in eleven rounds within one user turn,
produces real checked interaction views, charges usage once, retains one real
user message, leaves both gates unaccepted, and creates no source. The unchanged
invalid-candidate regression stops after seven rounds with the exact compiler
diagnostic and unchanged last-good views. Unavailable-worker tests still stop
after five rounds without another provider request.

The production browser test now builds a PDF from chat before requirements,
recovers the two bad candidates, renders Grammar/interaction/state/CTL views,
performs independent human acceptance actions, then writes and runs the small
server's Go tests. `reports/chatui/reset-browser.json` and its screenshot record
that disposable fixture. Tests use local deterministic providers, not live
model inference or real accounts. They establish orchestration and artifact
checks rather than a guarantee of live-model behavior.

Commit review: inspected the exact source, fixtures, checked example, generated
PDF text and browser image. The positive invariant is current project-owned
validation before successful completion. Material forbidden behaviors, controls
and negative evidence are mapped in `security-review.md`. No credential files,
private projects, logs or caches are commit candidates. No new path/command
surface, network permission, acceptance authority or credential selection is
introduced. Hashes in completion feedback only stop spending; they do not
authorize acceptance. No material finding remains unresolved in this change.
