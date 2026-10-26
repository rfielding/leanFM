# Persistent launcher implementation review

The stakeholder explicitly accepted the launcher requirements, including uniform Make targets. The exact requirements/protobuf hashes and answer are recorded in requirements-acceptance.json.

The candidate typed mapping is LeanFM/LLMGenerated/ApplicationLaunchImplementation.lean, exposed through the canonical Implementation.lean. Retain the current terminating smoke-test worker and add a separate persistent per-project supervisor. The native UI and chat launch operation call the same fixed lifecycle adapter; the launch itself needs no paid model request.

Every app uses source/Makefile build/run/stop/test/check/clean/serve. Start builds/runs in a private bubblewrap network/process/filesystem boundary, mounts only that app's source/profile and writable per-instance cache, and reaches it through a bounded trusted Unix-socket bridge. Readiness, live process identity and source revision precede a ready link. One app is allowed per project, four per server. Source changes are visibly stale; Stop and deletion clean up only owned children.

The user opens an authenticated served wrapper URL. Generated preview content runs in an opaque sandbox with no engineering-origin storage or session authority. Its scoped preview capability reaches only that instance's relative assets/API subtree; host cookies and authorization are stripped and the connect policy cannot reach engineering APIs or external hosts. A remote browser uses the served link, never a private loopback address. Existing apps need relative/prefix-compatible asset/API routing; unsupported routing fails explicitly.

The typed decisions map each negative requirement to controls and concrete tests. Required checks include real GoServer navigation through the preview, lifecycle races, stale or forged process/receipt/instance identity, admission/timeout/missing-target failures, foreign-project authorization, and malicious-app attempts against credentials, host services and engineering browser authority. This is a concrete design for review, not implemented source or a claim of existing isolation.

Implementation acceptance: pending explicit stakeholder approval. Requirements acceptance is preserved.
