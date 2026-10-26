# Persistent applications and usable launch links

Prompt: “I want LeanFM to be able to launch the app being built, and post a link to it.”

Finding: scripts/chatui_runtime.py probe launches make run, probes readiness/page in a private network and always stops its process group in finally. The saved url names that stopped private endpoint. This is valid verification evidence, not a persistent browser preview.

Uniform application contract: every source/Makefile supports build, run, stop, test, check, clean and serve. run stays foreground; serve aliases run; stop targets only that project-owned instance. LeanFM uses the same named targets for every app, with explicit errors for missing targets and real verification from check/test. No arbitrary per-app shell command is accepted.

Candidate: LeanFM/LLMGenerated/ApplicationLaunch.lean and ApplicationLaunch.proto, exposed by the canonical Requirements.lean as applicationLaunchProposal. Three complete tasks cover start, live status and stop. The selected project gains Start/Restart/Stop and Open app; a launch requested from chat publishes the same verified link. Repeated start reuses its current live instance. Failures are concrete; stopped or stale instances never claim a current working link. The link must work for the user's served browser, including remote LeanFM access.

Positive invariant (AG): a published app link identifies a ready, live, owned instance of the selected project's current source revision.

| Forbidden outcome | Required control in the separate implementation mapping | Negative test obligation |
| --- | --- | --- |
| A preview runs with engineering authority | Separate the preview execution origin/authority from the LeanFM UI and strip host credentials | Malicious app cannot read engineering cookies/storage or call authenticated project/provider APIs |
| Generated code reaches credentials, host network or other roots | Filesystem, process and network isolation with finite resources | App probes outside files, host services and another project and is denied |
| An unauthorized caller starts/stops or reads an app | Authenticate and check project ownership on lifecycle and preview access | Foreign user/project/instance identifiers and cross-site mutations reject |
| A smoke-test receipt becomes a dead or remote-inaccessible link | Live readiness, source revision and process identity checks; browser-reachable preview routing | Dead/stale process, failed page and remote-client checks never claim ready |
| Concurrent launches duplicate instances or stop unrelated work | Serialized per-project lifecycle; unforgeable instance identities; owned-child cleanup | Concurrent start/start, start/stop, stale PID and wrong instance tests |
| Unlimited apps, requests, logs or outputs exhaust the server | One app per project; four per server; bounded startup, bodies and runtime resources; project-owned records | Capacity/deadline/output exhaustion rejects or fails without collateral termination |
| Project deletion leaves runtime state elsewhere | All per-project state under its root; runtime cleanup before deletion | Delete the project and observe its instance and state disappear |

The smoke-test validator remains separate. This request does not accept GoServer's pending implementation mapping or the new launch requirements. No launch implementation has been written.
