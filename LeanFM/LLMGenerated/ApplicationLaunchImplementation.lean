import LeanFM.LLMGenerated.ApplicationLaunch

namespace LeanFM.LLMGenerated.ApplicationLaunchImplementation
open LeanFM
open LeanFM.LLMGenerated.ApplicationLaunch

def justification (requirementId reason : String) : RequirementJustification := {requirementId, reason}
def transport (name : String) : TransportSpec :=
  match name with
  | "ApplicationStartRequested" => .httpRequest "POST" "/api/projects/{project_id}/application/start"
  | "ApplicationReady" | "ApplicationLaunchRejected" => .httpResponse "ApplicationStartRequested"
  | "ApplicationStatusRequested" => .httpRequest "GET" "/api/projects/{project_id}/application"
  | "ApplicationStatusReturned" => .httpResponse "ApplicationStatusRequested"
  | "ApplicationStopRequested" => .httpRequest "POST" "/api/projects/{project_id}/application/stop"
  | "ApplicationStopped" | "ApplicationStopRejected" => .httpResponse "ApplicationStopRequested"
  | _ => .inProcessChannel "application-lifecycle"

/-- Proposed realization of the accepted launcher requirements; implementation gate pending. -/
def implementation : ImplementationSpec :=
  {requirementId := requirements.id, target := .lean, moduleName := "LeanFM.ApplicationLaunch", outputDirectory := ".",
   actors :=
     [{actor := "UserBrowser", typeName := "ApplicationControls", sourceFile := "ui/src/main.tsx",
       justifications := [justification "property:Every app link names a ready owned live instance" "Display native Start/Restart/Stop/Open controls and actual project-owned lifecycle status without a model request."]},
      {actor := "LeanFMServer", typeName := "ApplicationSupervisor", sourceFile := "LeanFM/ChatUI/Server.lean",
       justifications := [justification requirements.id "Authorize lifecycle routes and delegate fixed commands to the isolated project runtime supervisor."]}],
   messages := requirements.messages.map fun message =>
     {message := message.name, wireType := message.name, transport := transport message.name,
      justifications := [justification ("message:" ++ message.name) "Preserve the accepted project/request/instance/revision fields and response cause_id within the same lifecycle task."]},
   channels :=
     { sendFunction := "enqueueApplicationCommand"
     , receiveFunction := "receiveApplicationCommand"
     , tryReceiveFunction := "tryReceiveApplicationCommand"
     , closeFunction := "closeApplicationCommands"
     , sendFull := .blockWithoutMutation
     , receiveEmpty := .blockWithoutMutation
     , tryReceiveEmpty := .returnNoneKeepRunnable
     , sendClosed := .rejectWithoutMutation
     , receiveClosed := .drainThenReturnClosed
     , closeSemantics := .idempotentWakeWaiters
     , justifications := [justification requirements.id "Serialize each project lifecycle with finite admission and wake pending operations on shutdown."] } }

def decisions : List RequirementJustification :=
  [ justification "property:Every application supports the same Make targets"
      "Extend the generated-app contract and hosted agent instructions with source/Makefile build/run/stop/test/check/clean/serve. run stays foreground, serve aliases it, and stop is project-owned. Validate target support in the existing network-disabled worker; never execute Make parsing or arbitrary manifest commands in the host. Preserve fixed spec/runtime.json source/ make run with no shell command parameter."
  , justification "property:Every app link names a ready owned live instance"
      "Add scripts/chatui_application.py and a trusted worker. The authenticated Lean server accepts native lifecycle actions and a workspace_launch tool through named chatui_command.sh operations. Start verifies current project gates and launch contract, serializes admission, and launches one owned isolated instance. Check readiness and the page against that exact source revision before returning a link. Persist the actual launch result in chat without paid inference; keep workspace_check run as its existing terminating smoke test."
  , justification "proof:Preview cannot borrow engineering authority"
      "Run make build/run in bubblewrap with private user/PID/network namespaces, dropped capabilities, a cleared environment, read-only source and launch profile, and a project-owned per-instance cache as the only application write mount. Do not mount credentials, conversations, gate records or another project. Use a mapped non-root namespace UID and finite process/file/virtual-memory limits. A trusted bridge in that private namespace forwards bounded HTTP over an owned Unix socket; no application port is exposed on the host network."
  , justification "proof:Preview cannot borrow engineering authority"
      "The public Open app URL is an authenticated LeanFM wrapper. It embeds generated content in an opaque sandbox with scripts/forms but without same-origin or top-navigation authority. Use a random, instance-scoped preview capability for the content and its relative asset/API subtree; deny requests outside that instance. Strip engineering cookies/authorization and upstream Set-Cookie, enforce a preview-only connect policy, and prevent the app from reading engineering-origin storage or calling authenticated LeanFM APIs. Never put the preview capability in the chat URL or diagnostics. Honor an explicit app base path for relative assets/API requests; reject unsupported absolute-root routing explicitly rather than claim it works."
  , justification "proof:Launch never fabricates readiness"
      "Status checks the owned supervisor's process identity, Unix control endpoint, readiness and exact source/spec hash rather than a PID or old receipt. Source changes mark the instance stale. Return a served preview URL relative to the browser's LeanFM origin; never advertise a private namespace loopback address as a remote preview. UI polls at a bounded cadence and clears links on failed/stopped/stale states."
  , justification "proof:Runtime cleanup never stops unrelated work"
      "Use one lock and owned supervisor per project, one random instance ID per run, and a four-instance global admission limit computed from project roots plus live supervisors. Store all runtime records, sockets and bounded logs below that root. Stop uses the owned supervisor and instance ID, never an arbitrary supplied PID or port scan. Process start identities and a private control nonce prevent PID reuse. Supervisor parent-death/shutdown and project-delete cleanup terminate only their own children; source writes cannot forge controller records."
  , justification "property:Lifecycle remains explicit and project scoped"
      "Use Python 3.12 standard-library IPC/HTTP/subprocess support, existing bubblewrap, Lean 4.35.0 and the current React/TypeScript toolchain. Set a 90-second start deadline, bounded request/response sizes and 10-second preview exchanges, maximum 32 concurrent exchanges per instance, bounded logs, a finite process count and build/runtime address-space limits. Report setup/admission/readiness failures concretely without a provider call or retry."
  , justification requirements.id
      "Add deterministic lifecycle and HTTP tests for unauthenticated/foreign project access, same-project concurrent starts/stops, forged instance/PID/receipt, missing uniform targets, stale source, readiness failure, occupied endpoint and admission exhaustion. Add malicious-app isolation probes for outside files, host network, engineering cookies/storage/API authority, and cross-instance preview access. Exercise the production UI and GoServer from a remote-style browser origin through the served preview URL; verify its relative assets, room creation and challenge chat. No material negative requirement may remain without its passing control test before completion."
  ]
end LeanFM.LLMGenerated.ApplicationLaunchImplementation
