# ChatUI repair commit review

Positive invariant: the committed snapshot contains tested account/session
recovery and bounded local compiler repairs, together with the independently
accepted resumable-work requirements and implementation mapping. The new
continuation runtime is explicitly pending a separate implementation commit.

| Forbidden behavior | Control and evidence |
| --- | --- |
| Commit credentials, account records, project conversations or private logs | Existing vault/project/cache/log ignores; explicit staging and staged path/content scan |
| Make logout depend on a hidden sidebar or a valid prior session | Shared application session state and persistent header controls; real Chrome clicks at narrow width with missing and expired sessions |
| Let a late response restore a logged-out credential or silently send queued work after another login | Request generations, aborts, paused polling, explicit fresh login and captured prompt identity; browser failure/queue regressions |
| Remove isolation to bypass compiler startup failure | Fixed two-thread compiler inside unchanged sandbox/resource limits; real compile, environment/write/network negatives and preserved last-good views |
| Spend another model round on an unavailable local worker | Typed fatal tool result honored by both protocols; exact fixture call counts and preserved usage |
| Run unprovided Make targets or execute discovery on the host | Bounded static target preflight; negative executable-Make-expression fixture |
| Treat approved design as shipped runtime or accept gates implicitly | Explicit acceptance hashes, pending-runtime README, separately checked typed mapping and generated requirement views |

Validated with `make check`, production Chrome/HTTP tests, focused specification
and command tests, provider tests and exact acceptance-hash verification. The
final staged snapshot receives whitespace and secret/path checks before commit.
