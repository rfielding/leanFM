import spec.Requirements
namespace GoServer.Implementation
open LeanFM GoServer.Requirements
def why (id text : String) : List RequirementJustification := [{requirementId:=id,reason:=text}]
def binding (m : MessageSchema) : MessageCodegen :=
  { message := m.name
  , wireType := "Requirements.proto/" ++ m.name
  , transport := match httpContracts.find? (fun c => c.requests.contains m.name) with
      | some c => .httpRequest c.method c.path
      | none => .custom "requirements-owned-json-or-gif" "Exact contract is in Requirements.httpContracts."
  , justifications := why ("message:" ++ m.name) "Realize the requirements-owned HTTP contract." }
def implementation : ImplementationSpec :=
  {requirementId:=spec.id,target:=.go,moduleName:="leanfm/goserver",outputDirectory:="source",
   actors:=[{actor:="Client",typeName:="Browser canvas and MCTS worker",sourceFile:="source/server/web/app.mjs",justifications:=why "actor:Client" "Keyboard-first local analysis and ordinary authenticated proposals."},
            {actor:="GoServer",typeName:="server.Server",sourceFile:="source/server/server.go",justifications:=why "actor:GoServer" "Revalidates moves, atomically persists snapshots, serves the embedded UI and replayed exports."}],
   messages:=GoServer.Requirements.messages.map binding,
   channels :=
     { sendFunction := "fetch/JSON and Worker.postMessage"
     , receiveFunction := "net/http and worker onmessage"
     , tryReceiveFunction := "versioned state poll"
     , closeFunction := "Worker.terminate and http.Server.Shutdown"
     , sendFull := .blockWithoutMutation
     , receiveEmpty := .blockWithoutMutation
     , tryReceiveEmpty := .returnNoneKeepRunnable
     , sendClosed := .rejectWithoutMutation
     , receiveClosed := .drainThenReturnClosed
     , closeSemantics := .idempotentWakeWaiters
     , justifications :=
         (why "resource:Client" "One active search; stale results cancelled before mutation.") ++
         (why "resource:GoServer" "Serialized bounded mutation/export, HTTP byte/time limits and persistent room caps.") } }

-- R1/R2: pure Go rules plus a differential-tested JS projection. R3: random
-- seat capabilities, only SHA-256 verifiers on disk, exact revisions and a mutex.
-- R4: immutable local tree; network history is read-only. R5: Go replay and real
-- image/gif; generated random output names, never user paths. R6: strict JSON,
-- loopback-only bind and Host, same-origin mutations, fixed resource limits, deadlines,
-- project-local state and failure rollback. Negative tests are in
-- source/game/game_test.go, source/server/server_test.go, tests/startup_check.py
-- and tests/browser_check.py. MCTS has at most 1024 tree nodes, 100000 iterations
-- and 48 rollout steps per iteration; local analysis has at most 2048 nodes.
-- R1/R3/R6 conformance repair: all browser move entry points share the current
-- seat/latest/live-game admission check, including canvas and keyboard clicks.
-- A completed room returns 409 before turn comparison; turn/revision conflicts
-- include only the public authoritative snapshot. The browser retains the exact
-- HTTP status and request ID, refreshes history once, and never resends the move.
-- Older history responses cannot replace a newer revision. Controls are tested
-- by TestCompletedRoomReportsStateBeforeTurnAndDoesNotMutate and the real
-- two-browser second-turn, stale-proposal and blocked-input regression checks.
def errors := validateImplementationSpec spec implementation
example : errors = [] := by native_decide
end GoServer.Implementation
