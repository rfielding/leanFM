import LeanFM.Artifacts

namespace LeanFM.LLMGenerated.ApplicationLaunch
open LeanFM

/-- Proposed persistent project application lifecycle. Acceptance pending. -/
def framing : MessageFraming :=
  {kind := .protobufMessage, dispatchField := none, note := "One correlated project application lifecycle event"}
def messages : List MessageSchema :=
  [ {name := "ApplicationStartRequested", src := "UserBrowser", dst := "LeanFMServer", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "request_id", scalar := .string}]}
  , {name := "ApplicationReady", src := "LeanFMServer", dst := "UserBrowser", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "instance_id", scalar := .string}, {number := 3, name := "revision", scalar := .string}, {number := 4, name := "url", scalar := .string}, {number := 5, name := "request_id", scalar := .string}]}
  , {name := "ApplicationLaunchRejected", src := "LeanFMServer", dst := "UserBrowser", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "reason", scalar := .string}, {number := 3, name := "request_id", scalar := .string}]}
  , {name := "ApplicationStatusRequested", src := "UserBrowser", dst := "LeanFMServer", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "request_id", scalar := .string}]}
  , {name := "ApplicationStatusReturned", src := "LeanFMServer", dst := "UserBrowser", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "instance_id", scalar := .string}, {number := 3, name := "revision", scalar := .string}, {number := 4, name := "state", scalar := .string}, {number := 5, name := "url", scalar := .string}, {number := 6, name := "reason", scalar := .string}, {number := 7, name := "request_id", scalar := .string}]}
  , {name := "ApplicationStopRequested", src := "UserBrowser", dst := "LeanFMServer", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "instance_id", scalar := .string}, {number := 3, name := "request_id", scalar := .string}]}
  , {name := "ApplicationStopped", src := "LeanFMServer", dst := "UserBrowser", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "instance_id", scalar := .string}, {number := 3, name := "request_id", scalar := .string}]}
  , {name := "ApplicationStopRejected", src := "LeanFMServer", dst := "UserBrowser", framing,
      fields := [{number := 1, name := "project_id", scalar := .string}, {number := 2, name := "reason", scalar := .string}, {number := 3, name := "request_id", scalar := .string}]}
  ]
def scenarios : List (String × String × String × List String) :=
  [ ("start_application", "Start the selected project and publish a verified live app link", "ApplicationStartRequested", ["ApplicationReady", "ApplicationLaunchRejected"])
  , ("inspect_application", "Inspect live application state", "ApplicationStatusRequested", ["ApplicationStatusReturned"])
  , ("stop_application", "Stop only this project's application instance", "ApplicationStopRequested", ["ApplicationStopped", "ApplicationStopRejected"]) ]
def taskFor (id title request : String) (responses : List String) : TaskRequirement :=
  {id, title, actors := ["UserBrowser", "LeanFMServer"], initialState := "ready",
   states := [{id := "ready", label := "Action available", group := "browser", markdown := "No lifecycle action in flight", terminal := false},
              {id := "checking", label := "Authorize project and check actual process state", group := "server", markdown := "No link is trusted from an old receipt", terminal := false}]
     ++ responses.map fun response => {id := response, label := response, group := "result", markdown := "One correlated lifecycle outcome", terminal := true},
   transitions := [{src := "ready", dst := "checking", message := request, probabilityNum := 1, probabilityDen := 1, dwellMs := 0}]
     ++ responses.map fun response => {src := "checking", dst := response, message := response, probabilityNum := 1, probabilityDen := 1, dwellMs := 0}}
def event (task src dst message : String) : GrammarExpr := .event {task, src, dst, message}
def requirements : RequirementSpec :=
  {id := "leanfm.application_launch", title := "Persistent project applications and working preview links",
   actors := ["UserBrowser", "LeanFMServer"],
   actorPopulations := [{actorSpec := "UserBrowser", instancePrefix := "browser", count := 8, routing := .sticky "session"},
                        {actorSpec := "LeanFMServer", instancePrefix := "server", count := 1, routing := .sticky "project_id"}],
   actorResources := [{actor := "UserBrowser", inboundCapacity := 32, outboundCapacity := 32, maxInFlight := 4, memoryBudgetBytes := 67108864},
                      {actor := "LeanFMServer", inboundCapacity := 256, outboundCapacity := 256, maxInFlight := 32, memoryBudgetBytes := 536870912}],
   actorReliability := [], reliabilityGates := [], actorCosts := [], messages,
   tasks := scenarios.map fun (id, title, request, responses) => taskFor id title request responses,
   grammars := scenarios.map fun (id, _, request, responses) =>
     {task := id, entry := "ready", terminals := responses,
      body := .seq (event id "UserBrowser" "LeanFMServer" request) (.choice (responses.map fun response => event id "LeanFMServer" "UserBrowser" response))},
   processes := scenarios.flatMap fun (id, title, request, responses) =>
     [{actor := "UserBrowser", task := id, states := (taskFor id title request responses).states.map (fun s => s.id), sends := [request], receives := responses},
      {actor := "LeanFMServer", task := id, states := (taskFor id title request responses).states.map (fun s => s.id), sends := responses, receives := [request]}],
   properties :=
     [{name := "Every app link names a ready owned live instance", task := "start_application", mode := .always, probability := none,
       expression := "An authenticated project owner may launch a project with both current accepted gates and a valid source/ make run contract; only actual readiness and page success for its live source revision publish an Open app link and a chat launch result; the app remains running after the launch request completes"},
      {name := "Lifecycle remains explicit and project scoped", task := "inspect_application", mode := .always, probability := none,
       expression := "The UI reports stopped, starting, running, stale or failed from actual owned-process state; repeated Start returns the existing current instance; a changed source revision is visibly stale and requires restart; browser and chat can request start without a paid model call for the launch itself"},
      {name := "Stopping is scoped and idempotent", task := "stop_application", mode := .always, probability := none,
       expression := "Stop closes the named owned instance and removes its ready link; repeated Stop is harmless; project deletion and LeanFM shutdown clean up owned runtime children; one instance exists per project and at most four instances exist per server"}]
     ++ [{name := "Every application supports the same Make targets", task := "start_application", mode := .always, probability := none,
          expression := "Every generated HTTP app provides source/Makefile with build, run, stop, test, check, clean and serve targets. run is foreground; serve aliases run; stop affects only the project-owned app. LeanFM invokes these fixed targets rather than per-app shell commands and reports missing targets as actionable unsupported-contract failures. make check runs the app's actual proportional verification; no unsupported target is claimed successful."}],
   requiredProofs :=
     [{name := "Preview cannot borrow engineering authority", task := "start_application", mode := .never, probability := none,
       predicate := "an unauthenticated or foreign-project caller launches controls or accesses a preview; generated application code reads LeanFM credentials, session cookies, engineering-origin storage, another project's files or the host network; a preview response obtains the authority of the LeanFM engineering UI"},
      {name := "Launch never fabricates readiness", task := "inspect_application", mode := .never, probability := none,
       predicate := "an old verification receipt, dead or unrelated process, source revision mismatch, occupied endpoint or failed readiness produces a working/current app claim; a remote user receives a server-local loopback URL presented as browser reachable"},
      {name := "Runtime cleanup never stops unrelated work", task := "stop_application", mode := .never, probability := none,
       predicate := "stale PIDs, concurrent starts/stops, forged instance IDs or one project removal terminate another instance or an unrelated host process; generated source selects an arbitrary host command, unbounded process or resource admission, or output path outside its project root"}],
   performance := [], charts := [],
   desiredOutputs := scenarios.flatMap fun (id, title, _, _) =>
     [{id := id ++ ".interaction", prompt := "I want LeanFM to launch the app being built and post a link to it", question := "Which correlated messages realize: " ++ title ++ "?", kind := .interactionDiagram, eventSource := id ++ " grammar in LeanFM.LLMGenerated.ApplicationLaunch.requirements", reducer := "render the current lifecycle grammar including failure alternatives", unit := "messages per owned project lifecycle action"},
      {id := id ++ ".state", prompt := "Keep the app running and expose Start, Stop and Open app", question := "Which request/result states realize: " ++ title ++ "?", kind := .stateMachine, eventSource := id ++ " task in LeanFM.LLMGenerated.ApplicationLaunch.requirements", reducer := "render the same typed task states and message transitions", unit := "states and transitions per lifecycle action"}],
   markdown :=
     [{id := "scope", title := "Persistent launch is separate from verification", body := "All generated applications share the Make targets build, run, stop, test, check, clean and serve under source/. run stays foreground for supervision, serve aliases run, and stop affects only the owned app. Missing targets fail explicitly rather than being guessed or skipped. The existing workspace_check run starts a private smoke test and stops it. This candidate adds persistent user-accessible applications, Start/Restart/Stop and Open app in the selected project, plus a concise chat result containing the verified preview link. It preserves both project acceptance gates and does not require or retry a paid provider request to launch."},
      {id := "http", title := "Project-owned lifecycle and preview contract", body := "GET /api/projects/{project_id}/application reports status; POST /api/projects/{project_id}/application/start starts or reuses the current revision; POST /api/projects/{project_id}/application/stop stops the named instance. Authenticated, bounded requests and responses use application/json, retain request_id, project_id, instance_id and revision, and return explicit authorization, busy, invalid-contract, stale or launch-failure outcomes. A verified preview link is browser reachable from the served LeanFM UI, including remote access; preview routing and assets/API requests preserve the app boundary. A local loopback port alone is not a remote preview. Generated code must execute outside the engineering origin's authority."},
      {id := "bounds", title := "Finite runtime and failure behavior", body := "At most one live application exists per project and four per LeanFM instance. Start has a 90-second readiness deadline and each preview request has a bounded timeout and body. App processes remain confined to their project, with finite memory/process/connection limits selected in the separate implementation mapping. Source changes mark a running build stale rather than silently replacing it; occupied listeners remain untouched. Application logs and runtime records stay below that project's root; indexes are reconstructible and no global mutable project state is required."},
      {id := "acceptance", title := "Candidate requirements", body := "This proposed component requires explicit observable-requirements acceptance and a separate checked implementation mapping. It does not change the accepted GoServer rooms/challenges requirements. Its security controls and negative checks are reviewed before source implementation."}]}

def protoSource : String := include_str "ApplicationLaunch.proto"
end LeanFM.LLMGenerated.ApplicationLaunch
