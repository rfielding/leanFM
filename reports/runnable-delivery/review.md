# Runnable delivery and account updates

User requirements: source/ make run must launch the generated application on a
port separate from LeanFM; reach running software quickly, then refine the
specification through use. Retain goals, failures, decisions and PR context
outside disposable conversation history. Existing usernames with a matching
password update their keys; support password changes at login and secure key
addition/rotation for the authenticated account.

Positive invariant: an application completion has current evidence that its
actual make run process answered readiness and a page on its declared loopback
port. Durable goal/launch/verification records survive deleted chat. Password
changes atomically retain every provider key while invalidating old passwords
and old sessions, including another process sharing the credential vault.

`spec/runtime.json` is a bounded fixed-command launch profile, not shell text.
The existing read-only filesystem/process worker gains a private-loopback probe.
It runs make run from source/, requires HTTP 200 readiness and a bounded page,
rejects extra or non-loopback listeners, and terminates only its own child group.
Only project cache is writable. Trusted host code writes protected runtime
receipts bound to source, book and canonical specifications. Completion checks
current receipts, feeds launch failures back into the same bounded client task,
and retains caller, cancellation, spend, unchanged-failure and both human gates.
MCP generation guidance and durable ChatUI context carry the same contract.
Libraries remain library targets. Bounded startup checks do not prove complete
application conformance; known counterexamples must remain explicit.

Account updates verify the existing password before provider verification.
Optional matching new passwords at login/settings re-encrypt all retained keys
and publish their verifier together in one atomic version-2 envelope. Legacy
accounts still unlock normally. The old verifier file is only a mirror once an
envelope exists. Key updates preserve that authoritative verifier. A credential
revision changes for real key/password replacement and remains stable for an
additive provider save. Login snapshots bind to that revision; session and tool
checks reject a revision changed by another process. No password or key is
returned, logged, passed as an argument, or written outside the private vault.
A direct `/?keys=1` link opens the existing editor without saving or logging in.

| Forbidden behavior | Control | Evidence |
| --- | --- | --- |
| Claim a runnable app from source files, old checks or prose | Actual launch, current source/specification digest, protected receipts and completion feedback | Runtime, native request-classification and both-provider recovery/reset tests |
| Collide with or kill LeanFM/another process | Explicit non-LeanFM port, private network, fixed command and own-child-group cleanup | Reserved-port, bind-all and real application launch tests |
| Leak keys/host files/network or forge gates from project code | Existing clear environment and filesystem/process/network isolation; only project cache writes | Runtime fixture probes host path, secret environment, writable gates and receipt protection |
| Lose decisions or PR accuracy when chat is deleted | Durable project memory, launch profile, current receipt status and PR context | Both providers resume an actual verified app after conversation erasure |
| Update another account with an incorrect password | Caller-bound settings and password verification before provider I/O | Existing-account, wrong-password and cross-account API tests |
| Split new verifier from old ciphertext after interruption | One atomic encrypted envelope; authoritative verifier read by all authentication paths | Stale-mirror native regression, retained-key and restart tests |
| Revive old keys/password/sessions or discard another provider | Credential revision on replacement, fresh login and encrypted merge | Native rotation, API login/settings changes, existing-session and both-provider tests |

All provider fixtures are local, with disposable credentials. The actual
Anthropic environment key is available, but adding it to rob's password-bound
vault requires the user's secure form submission; no plaintext key or password
was requested in chat. GoServer launch-repair inputs and results remain below
its own root, outside this repository's ordinary-project ignore boundary.

Final verification: make check and make book passed. All 29 local-provider,
five shared-project and six HTTP tests passed, including real browser password
rotation and a runnable-app repair that crosses client batches. Both providers
resumed the launch goal and current evidence after conversation erasure. Three
runtime boundary tests passed. Native credential checks additionally simulate
a stale password-verifier mirror and a different service changing the session
revision. Optional missing handoff files remain ordinary gaps and do not push
real failures out of the bounded diagnostic journal.

The nine original referenced-book cover assets were restored from repository
history, retaining the current annotations, original source attribution and
accessible figure descriptions. Both light/dark PDFs rebuilt successfully;
PDF image inspection confirms all nine images on physical pages 132–133 and
the gallery layout was visually reviewed. No new downloaded artwork or
independently drawn diagram replaced a specification-derived view.

GoServer's actual make run process passed current launch verification on 8081;
its HTTP/core race tests passed. It remains stopped for the operator to launch.
The complete app/specification/handoff snapshot is committed in its own project
repository. LeanFM's parent repository continues to exclude ordinary projects,
account vaults, runtime logs and caches.
