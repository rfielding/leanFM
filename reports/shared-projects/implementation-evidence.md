# Fresh-start implementation evidence

The requirements and separate implementation mapping were explicitly accepted
in this conversation and recorded with their artifact hashes in
`acceptance.json`. The approved reset completed; `reset-result.json` identifies
the discarded roots. `data/` is absent, `projects/` is empty, and the preserved
encrypted account records are in `.leanfm/accounts/` with their original bytes
and private permissions.

Positive invariant: a fresh ordinary project is independent of credential
accounts, contains all its own durable state, and can progress through checked
requirements, a separately checked implementation mapping, explicit human
acceptance and actual checked source in the production ChatUI.

## Implemented controls and negative evidence

| Forbidden behavior | Control and verification |
| --- | --- |
| Read the credential vault through a project or self-hosting alias | Manifest/path validation, private-vault exclusion and a server-enforced read-only self-hosting API; shared-project and media isolation tests pass |
| Mutate a shared project through a foreign site or rebinding Host | Central Host/Origin/Sec-Fetch-Site admission precedes dispatch; rejected requests change no project and issue no provider call |
| Use a different caller's key or cancellation authority | Request-local sessions, captured queued credential identity, per-step session checks and writer ownership; both provider protocols, rotation, port isolation and cancellation tests pass |
| Lose edits through competing writers | Canonical-root writer registry with synchronized acquisition, ownership and release; conflicting requests are rejected before mutation or billing |
| Forge acceptance or write source before both gates | Reserved gate/checker paths, checked input hashes, independent explicit acceptance endpoints, immutable accepted snapshots and server/tool source guards; stale, duplicate and premature operations are tested |
| Run project code with host secrets or outside write access | Network-disabled Bubblewrap, clean environment, read-only project/toolchain inputs, bounded execution and writable project-local cache or scratch only; real build, GIF and MP4 isolation tests pass |
| Claim specification completion from a PDF build or stale views | Real canonical Lean elaboration, protobuf declaration checks, structural validation, same-spec task rendering and final-byte checks. A combined book/specification turn is locally rechecked after the book commits without an extra provider request |
| Lose keys or delete an unknown external tree during reset | Whole-input preflight, ciphertext/password byte-and-mode verification, explicit enumerated project deletion, no-follow boundaries and empty-leaf scaffold cleanup; reset and negative boundary tests pass |

## Executed verification

- `make check`: passed, including Lean elaboration, artifact validation, generated
  scenario protobuf round-trip, self-hosting composition and repository checks.
- `make book`: passed; both same-source PDF variants rebuilt.
- `LEANFM_TEST_BROWSER=1 bash scripts/chatui_http_check.sh`: passed with local
  deterministic OpenAI and Anthropic protocol fixtures, shared-project checks,
  encrypted credential restart/rotation tests and the actual production React
  bundle in Chrome.
- `chatui_specification_test.py`, `chatui_project_state_test.py`,
  `chatui_workspace_reset_test.py`, `chatui_command_test.py`, credential, patch,
  media and HTTP-frame checks: passed.
- The production-browser scenario creates a fresh project, generates and
  compiles its typed requirements, renders its grammar/interaction/state/CTL
  views, accepts requirements, generates/checks/accepts its typed implementation
  mapping, writes an HTTP server and negative request tests under `source/`, and
  runs the Go tests in the execution sandbox. It uses no old project, examples,
  prior conversation or real provider bill.

Browser evidence is in `../chatui/reset-browser.json` and
`../chatui/reset-browser.png`. Its provenance identifies the fixture boundary;
it is a regression test of the engineering workflow, not a claim that a live
model's judgment or all generated applications are correct. Structural Lean
validation is not a deployed-code refinement proof.
