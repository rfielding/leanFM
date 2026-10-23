# Model picker recovery

Prompt: "the list of openai models is empty. so i cannot chat."

This is a conformance repair of the accepted keyless workspace and password
unlock behavior, not a new credential policy or wire protocol. References:
`property:keyless_server_has_no_provider_spend`,
`property:one_password_unlocks_all_provider_keys`,
`property:selected_model_determines_provider_credential`,
`property:model_key_is_request_scoped`, the `keyless_launch` requirement prose,
and the accepted `multiple-password-unlocked-providers` implementation decision.

Positive invariant: the composer shows models belonging to the current unlocked
session, or explains why chat is unavailable and provides the corresponding
unlock or retry action. Password unlock refreshes mounted project composers
immediately, preserving drafts and project context.

Follow-up prompt: "Unlock API keys is the only thing in the dropdown, and I
cannot force a logout to re-login."

The first repair left logout conditional on the sidebar's independent username
state. Narrow windows hide that sidebar entirely. The completed repair uses one
application session snapshot for the account controls and all model pickers,
exposes Sign in and Log out in each project header (including narrow layouts)
and makes Log out available even with a missing or expired session. Logout opens
a fresh editable login form and preserves project state and drafts. The key
dialog also has an explicit logout action. The selector's placeholder says
"Sign in to load models"; it does not represent an action hidden in a dropdown.

Additional invariant: a user can reach a fresh login form from the locked
composer without relying on a sidebar or a valid prior login. A valid logout
revokes the server session; an existing 401 means the session is already locked.
No HTTP route, status contract, credential policy or accepted gate changes.

The old UI converted every failed `/api/me` request into an unexplained empty
picker. Login also left the authentication revision unchanged, so mounted
composers waited for their next poll and queued prompts could retain the same
browser identity across another unlock of the same key.

| Forbidden behavior | Implementation control | Negative evidence |
| --- | --- | --- |
| Empty selector silently blocks chat | Explicit loading, locked, failed and empty-catalog messages, placeholder and inline unlock/retry controls | Production-browser checks for signed-out, invalid-session, unavailable-catalog and network failure states |
| A failed or expired session borrows a different key or invented model | Clear unavailable catalog; keep server-owned model validation and password-only key unlock | Browser requires unlock after session invalidation; existing multi-provider unknown-model and missing-key rejection tests |
| A late discovery reply restores the old session's catalog | Abort and ignore old effect requests; increment authentication revision after every unlock | Browser holds a prior catalog response across a lock and verifies it cannot repopulate the picker |
| An old queued prompt silently bills a newly unlocked session | Authentication revision participates in captured prompt identity | Browser holds a queued prompt across lock/unlock of the same saved key |
| Polls accumulate or account controls disagree with the model picker | One application-owned session snapshot and one in-flight refresh; abort on authentication change | Browser delays model discovery, checks only one poll across mounted projects and rejects overlapping refresh |
| A narrow window or stale username makes logout unreachable | Always-visible header Sign in/Log out controls and a logout action inside the key dialog | Real mouse clicks on the header at a 700-pixel viewport with the sidebar hidden; missing and expired sessions still open an editable login form |
| A failed logout silently restores the old key or claims server revocation | Lock browser state immediately, invalidate pending replies, pause discovery until a new explicit login, surface transport failures and permit logout retry | Browser injects a failed logout, verifies no catalog restoration and retries against the real server; server `/api/me` is 401 after successful logout |
| Login or catalog recovery erases a draft or sends it automatically | Keep mounted project and Chat state; retry only metadata requests | Browser preserves draft across unlock, catalog failure, retry and expired-session recovery; provider request counters remain unchanged until explicit send |
| Raw credentials leak into UI or evidence | Reuse password dialog and sanitized `/api/me` metadata; use disposable local provider fixtures | Existing ciphertext/credential tests; browser evidence contains no live account keys |

Provider contract checked against the official OpenAI
[List models reference](https://developers.openai.com/api/reference/resources/models/methods/list):
API-key model discovery uses authenticated `GET /v1/models` and its `data` list.
The provider parser already follows that contract; this repair addresses UI
authentication/catalog state and does not send inference requests for discovery.

Validation passed:

- `make check`, including the production UI build, Lean validation and generated
  scenario protobuf round-trip.
- `LEANFM_TEST_BROWSER=1 bash scripts/chatui_http_check.sh`: Chrome exercises all
  recovery cases above, then completes the fresh-project specification and
  implementation flow. The same run passes 22 multi-provider tests, four shared
  project tests, credential restart/port isolation and PDF checks.
- `lake env lean LeanFM/ChatUI/Validate.lean`: implementation mappings are
  traceable.
- After the idle local service was restarted, `/health` and the live generated
  artifact validator pass. The served JavaScript exactly matches the checked
  production bundle, SHA-256
  `92cefb03469e3f683cbb0f6d77198d57949d27f164c6ba480782ab4d5c3ab234`.
- `git diff --check`: passed.

Browser evidence: [reset-browser.json](reset-browser.json) and
[reset-browser.png](reset-browser.png). These are deterministic local-provider
tests using the real production UI, provider adapters and compilers. No live
account was unlocked, no paid inference request was sent, and no real account's
model entitlements are claimed. The user must unlock their saved keys through
the password dialog after refreshing the restarted service.
