# Autonomous work, MCP guidance and provider addition

The user requests sensible defaults, continued implementation work while checks
show useful progress, public research without routine clarification turns,
maximal use of LeanFM MCP, and adding an Anthropic key without destroying the
existing login. This repairs existing default-decision, BYOK, caller-isolation,
MCP-context and client-continuation contracts. Both human gates and current
project ownership boundaries remain enforced.

Positive invariants:

- A successful intermediate check advances the original goal. Source existence
  or self-authored tests alone do not establish requirements conformance.
- Adding a provider preserves the initiating session token, expiry, usage,
  original credentials, current model/draft and existing provider work.
- Language/workflow guidance comes from LeanFM's actual read-only MCP handler;
  project validation still checks the selected project's own canonical files.
- Public research uses the selected provider/model's supported web tool, keeps
  references across batches and exposes safe clickable source links.

The signed-in key editor calls `POST /api/provider-keys`. The handler binds the
account to the authenticated caller, verifies the account password and submitted
provider keys, and repeats session/password checks under the credential lock.
For additions, it promotes the authenticated encrypted bundle and updates only
the initiating session's credentials, retaining counters and expiry. Other
unchanged sessions remain valid. A changed existing secret retains the prior
revoke-before-promotion behavior and obtains a fresh initiating login. Invalid
password/key/account input cannot alter the bundle. No key is returned to the
browser or placed in a project.

The client distinguishes preserved-session saves from fresh login/rotation.
Queued/running work binds to its own selected model's provider fingerprint,
account and authentication generation, so adding an unrelated provider cannot
silently switch or interrupt existing work. Rotation/logout still changes the
generation and holds old work. Blank key fields preserve stored keys.

`leanfm_reference` now dispatches allowlisted MCP `resources/read` or
`tools/call` requests using the same MCP handler as the public endpoint. It
cannot request arbitrary host/project resources. The public MCP artifact
validator is explicitly not evidence for a different selected project.

Reading the full central PDF reproduced a process-ending stack overflow in
the recursive base64 encoder. Encoding now iterates over the byte array without
building byte/character lists. A real full-PDF MCP read, independent base64
decode and subsequent health request verify availability and complete bytes.
The service is launched detached from the tool session so normal conversation
boundaries do not own its lifetime.

OpenAI web research follows the official
[web-search documentation](https://developers.openai.com/api/docs/guides/tools-web-search)
and [Responses tool-call limit](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).
Eligible modern model families or explicit provider capability metadata enable
`web_search`; legacy models retain their prior local tool set. Responses include
source metadata and at most three built-in calls per request. Anthropic retains
its capability-bound three-use web tool. Neither path changes the captured model
or caller key. Safe HTTP(S) source URLs are bounded and carried with cumulative
completion/checkpoint state; book replies remain valid JSON until applied.
Rendered source links are appended to visible prose after book processing.

| Forbidden behavior | Control | Negative evidence |
| --- | --- | --- |
| Reset login, usage or active work merely by adding a provider | Preserve token/expiry/counters and original provider key; per-model client fingerprint; preserve-auth refresh | Account/API tests compare cookies, usage, unchanged account/password files and complete existing OpenAI work after addition; browser checks model, draft and no chat calls |
| Retain obsolete sessions after real key replacement | Existing revoke-before-promotion path retained | Rotation case rejects the older session; existing in-flight rotation test remains applicable |
| Corrupt or overwrite another account/key or store plaintext | Caller-bound account; password checks; encrypted merge under credential lock; atomic promotion | Wrong-password/cross-account tests; unchanged original provider remains callable; ciphertext contains neither test secret |
| Treat web evidence as instructions or expose keys in queries | Public-question/no-private-input instructions; keys remain outside model context; existing path/tool/gate/credential guards are unchanged | Both-provider fixture asserts research policy and unchanged workspace controls; existing secret/isolation tests remain applicable |
| Execute unsafe citation URLs or lose sources across batches | Bounded HTTP(S)-only URLs with escaped Markdown delimiters, persisted safe references | Injection/invalid-URL tests; both providers research/write/continue across a checkpoint with exact usage and clickable sources |
| Confuse host validation with project conformance | Allowlisted language/workflow MCP calls plus existing sandboxed project checker | Native MCP-reference equality/unknown-section tests; real project-specific compiler tests |
| Let a large MCP PDF read kill the server | Iterative encoding without recursive byte/character lists | Full central-PDF MCP regression and post-read HTTP health check |
| Continue paid work without useful progress or bypass approval/caller/spend limits | Existing checkpoint, failure, no-progress, session and source-gate controls retained | Existing 25/31-round, replay, budget, cancellation, startup-failure and gate tests |

Provider/search tests use deterministic local services and disposable accounts.
They establish dispatch, state preservation and validation boundaries, not a
guarantee of any live model's choices. Research queries are model-selected under
the public-input policy; provider support and provider spend limits still apply.
No live provider inference or actual user key was used for verification.

The generated project's last successful source model and independent source
review remain under its own `reports/source-review/`, with source hashes and a
reproducible channel-contract counterexample. Original source bytes are
preserved. This framework change does not claim that project implementation is
fully conformant or expose its private files in the LeanFM commit.

Executed verification for this checkpoint:

- `make check` and `make book` passed. Both rendered books contain the new
  behavior and retain identical text across their light/dark copies.
- The production browser flow passed, including password-only login, provider
  addition with unchanged cookie/model/draft, PDF-first specification repair,
  25 client-driven model rounds, generated grammar views, both explicit gates,
  and sandboxed Go tests. Its disposable-account evidence is in
  `reset-browser.json` and `reset-browser.png`.
- Final `lake build leanfm-server LeanFM.ChatUI.Implementation`, provider native
  tests and `LeanFM/ChatUI/Validate.lean` passed. The final review also removed
  a duplicate hosted-tool entry: unsupported models receive no hosted search
  and enabled models receive exactly one. Native tests and the provider
  fixture now enforce those boundaries.
- The final HTTP suite passed all 27 multi-provider, four shared-project and
  six HTTP tests, plus its credential/restart, PDF and durable-workspace checks.
- After confirming the live project was idle, the tested service was started
  detached. Live smoke checks passed, including byte-for-byte MCP central-PDF
  decoding, subsequent health, the deployed key editor, and exact preservation
  of the existing project's checked acceptance state.
- The exact repository-owned diff and generated browser/book artifacts were
  reviewed. No project roots, encrypted account vault, runtime caches, actual
  provider keys or session tokens enter this checkpoint.
