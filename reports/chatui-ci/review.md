# Required ChatUI CI sandbox dependency

Reported failure: CI invokes make chatui-check, but seven specification tests fail before their assertions because bwrap is absent from the Ubuntu 24.04 runner. The workflow installed ripgrep, TeX and protoc but omitted bubblewrap. The aggregate make check also omitted chatui-check.

Positive invariant: required CI and local aggregate checks execute the real ChatUI isolation suite with a working namespace sandbox. Forbidden behavior: executable Lean must never run unsandboxed, a missing worker must not overwrite last-good views, and aggregate checks must not silently omit ChatUI.

Controls: install bubblewrap in CI, run a real namespace preflight, include chatui-check in make check, serialize suites sharing cleaned build products, and classify a missing bwrap as local_checker_unavailable (exit 78). The negative missing-worker test preserves the prior catalog and source; existing tests continue to check host-network and filesystem/environment isolation. No skip or unsandboxed fallback was added.

Ubuntu 24.04 can additionally mediate unprivileged namespaces with AppArmor; the preflight reports a denied namespace directly. OS-wide restrictions are not disabled. Primary reference: https://documentation.ubuntu.com/release-notes/24.04/#unprivileged-user-namespace-restrictions
