import LeanFM.LLMGenerated.ResumableWorkImplementation
import LeanFM.LLMGenerated.Requirements
import LeanFM.ChatUI.Implementation

namespace LeanFM.LLMGenerated.Implementation

open LeanFM.LLMGenerated.Requirements

/-- Existing product bindings are preserved separately from the example.
    This is not an implementation mapping for the proposed selfhost workflow. -/
def existingProductImplementation : LeanFM.ImplementationSpec :=
  LeanFM.ChatUI.Implementation.implementation

def selfHostingImplementationStatus : String :=
  "The read-only MCP context adapter is implemented by LeanFM/MCP.lean and Server.lean, tested by LeanFM/MCPTests.lean, and documented in the book. Remaining selfhost workflow, typed modal/probability formulas, checker evidence, revision acceptance, and demand-driven indexes still require accepted implementation mappings. Existing ChatUI mappings are not a claim of complete self-hosting conformance."

def actorBinding : WorkerActor -> LeanFM.ActorCodegen
  | .Client => { actor := LeanFM.requirementName WorkerActor.Client
               , typeName := "ClientActor", sourceFile := "internal/actors/client.go"
               , justifications := [{ requirementId := workerRequirement.id
                                    , reason := "implements the required Client actor specification" }] }
  | .Gateway => { actor := LeanFM.requirementName WorkerActor.Gateway
                , typeName := "GatewayActor", sourceFile := "internal/actors/gateway.go"
                , justifications := [{ requirementId := workerRequirement.id
                                     , reason := "implements the required Gateway actor specification" }] }
  | .Worker => { actor := LeanFM.requirementName WorkerActor.Worker
               , typeName := "WorkerActor", sourceFile := "internal/actors/worker.go"
               , justifications := [{ requirementId := workerRequirement.id
                                    , reason := "implements the required Worker actor specification" }] }

def messageBinding (message : LeanFM.MessageSchema) : LeanFM.MessageCodegen :=
  { message := message.name
  , wireType := "pb." ++ LeanFM.replaceChar '.' '_' message.name
  , transport :=
      match message.name with
      | "Docs.GetRequest" => .httpRequest "GET" "/docs/{path}"
      | "Docs.FetchCommand" => .httpRequest "POST" "/internal/docs/fetch"
      | "Docs.FetchResult200" => .httpResponse "Docs.FetchCommand"
      | "Docs.FetchResult404" => .httpResponse "Docs.FetchCommand"
      | "Docs.GetResponse" => .httpResponse "Docs.GetRequest"
      | "Error.Response" => .httpResponse "Docs.GetRequest"
      | "Reviews.PostRequest" => .httpRequest "POST" "/reviews"
      | "Reviews.ModerateCommand" => .httpRequest "POST" "/internal/reviews/moderate"
      | "Reviews.ModerationAccepted" => .httpResponse "Reviews.ModerateCommand"
      | "Reviews.ModerationRejected" => .httpResponse "Reviews.ModerateCommand"
      | "Reviews.PostResponse201" => .httpResponse "Reviews.PostRequest"
      | "Reviews.PostResponse400" => .httpResponse "Reviews.PostRequest"
      | _ => .custom "unassigned" ""
  , justifications :=
      [{ requirementId := "message:" ++ message.name
       , reason := "encodes and transports the required observable message" }] ++
      (if message.name == "Docs.FetchResult404" then
        [{ requirementId := "proof:Possibly get_docs fetch failure"
         , reason := "implements the declared plan for the possible fetch-failure trace" }]
       else if message.name == "Reviews.ModerationRejected" then
        [{ requirementId := "proof:Possibly post_review moderation rejection"
         , reason := "implements the declared plan for the possible moderation-rejection trace" }]
       else [])
  }

def workerImplementation : LeanFM.ImplementationSpec :=
  { requirementId := workerRequirement.id
  , target := LeanFM.TargetLanguage.go
  , moduleName := "example.com/leanfm/worker"
  , outputDirectory := "generated/worker-go"
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker].map actorBinding
  , messages := workerRequirement.messages.map messageBinding
  , channels :=
      { sendFunction := "Send"
      , receiveFunction := "Receive"
      , tryReceiveFunction := "TryReceive"
      , closeFunction := "Close"
      , sendFull := LeanFM.SendFullSemantics.blockWithoutMutation
      , receiveEmpty := LeanFM.ReceiveEmptySemantics.blockWithoutMutation
      , tryReceiveEmpty := LeanFM.TryReceiveEmptySemantics.returnNoneKeepRunnable
      , sendClosed := LeanFM.SendClosedSemantics.rejectWithoutMutation
      , receiveClosed := LeanFM.ReceiveClosedSemantics.drainThenReturnClosed
      , closeSemantics := LeanFM.CloseSemantics.idempotentWakeWaiters
      , justifications :=
          [ { requirementId := "resource:Client"
            , reason := "implements the Client bounded queues" }
          , { requirementId := "resource:Gateway"
            , reason := "implements the Gateway bounded queues" }
          , { requirementId := "resource:Worker"
            , reason := "implements the Worker bounded queues" }
          ]
      }
  }

def validationReport : String :=
  LeanFM.implementationValidationReport workerRequirement workerImplementation

end LeanFM.LLMGenerated.Implementation

namespace LeanFM.LLMGenerated.Implementation

/-- Separate implementation candidate for the shared-projects revision.
    Neither acceptance gate is supplied by this definition. -/
def sharedProjectsProposal : List LeanFM.ChatUI.Implementation.ImplementationDecision :=
  [ LeanFM.ChatUI.Implementation.decision "shared-workspace-paths"
      ["property:shared_projects_have_one_root", "property:readable_project_directories_preserve_identity", "property:credential_vault_is_not_a_project"]
      ["LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Server.lean", "scripts/chatui_workspace.py", "scripts/chatui_command.sh", "Server.lean", ".gitignore"]
      "Use one explicit workspace root (default current repository root; LEANFM_WORKSPACE_ROOT for isolated installations). Its ordinary projects live only under projects/<readable-project-name>; its account vault lives only under .leanfm/accounts/<account_id>. Remove username arguments from project-root lookup creation listing and deletion. Discover both manifest.json runtime projects and project.json portable projects, validate each manifest identity and resolve it independently of the directory label, reject ambiguous duplicate identities, symlink roots and escaping manifest paths, and preserve existing project IDs. Reserve a bounded ASCII label derived from the display name with atomic mkdir and short numeric collision suffixes; never reuse a live manifest identity or overwrite an occupied directory. Deletion resolves the manifest identity to its current immediate-child root and still requires the exact display-name confirmation. Do not hard-code a second account-owned namespace or put credentials in a project. The parent LeanFM repository remains the construction project's canonical self-hosting input; ordinary workspace discovery scans ./projects."
      ["scripts/chatui_workspace_test.py checks readable concurrent reservations, safe labels, moved runtime and portable roots, duplicate identity refusal, collision preservation and symlink/path rejection; scripts/chatui_shared_projects_test.py checks readable creation, renamed-root access for all callers, retained specification state and confirmed deletion of only the resolved root"]
  , LeanFM.ChatUI.Implementation.decision "shared-workspace-access-and-key-unlock"
      ["property:login_protects_keys_only", "property:shared_project_reads_and_local_edits_are_keyless", "property:shared_project_mutations_reject_cross_site_requests", "proof:Concurrent BYOK isolation"]
      ["LeanFM/ChatUI/Server.lean", "Server.lean", "ui/src/main.tsx", "ui/src/api.ts", "ui/src/types.ts"]
      "The stakeholder confirmed public workspace access before login. Mount the shared project workspace before credential login. Keep login/account/key dialogs as credential controls, and require an initiating caller's valid unlocked session only for provider-backed operations and account-secret changes. Login expiry must not erase mounted project drafts or turn shared projects into another namespace. Resolve the captured model only against that caller's credential catalog. Add central Host/Origin/Sec-Fetch-Site admission for unsafe requests before either shared-project or credential dispatch; permit only the explicit local origin or an approved operator origin, while preserving intentional loopback command clients without a browser Origin. Preserve existing byte framing body media path SVG and request deadline controls."
      ["Proposed: scripts/chatui_shared_projects_test.py checks unsigned project operations, keyless paid-call refusal, private account APIs, foreign-origin and Host rejection with zero mutation or provider calls", "Update scripts/chatui_browser_reset.py for shared workspace and credential unlock rather than an initial project-login wall"]
  , LeanFM.ChatUI.Implementation.decision "lossless-shared-storage-migration"
      ["property:shared_storage_preserves_project_identity", "property:migration_never_overwrites_or_loses_state", "property:No migration overwrites a project or drops an encrypted key"]
      ["scripts/migrate_chatui_storage.py", "LeanFM/ChatUI/Store.lean", "README.md"]
      "Provide a separate operator migration with dry-run preflight, not an implicit startup deletion. Quiesce project writers, inventory all old data entries and destination roots and compare per-file digests/modes without decoding secrets. Move each whole legacy account project into projects/<unchanged-id>; move account metadata password verifiers and encrypted credential records into .leanfm/accounts/<same-account-id> without re-encryption. Reject collisions unsupported entries escaping symlinks and inconsistent roots before mutation. Record project migration provenance beneath the destination project's reports and credential migration state beneath its private vault; no external project-owned cache or symlink alias. Keep historical evidence immutable, repair only active helpers that hard-code the old absolute project prefix, and regenerate affected views from canonical specifications. Verify all destination trees and unchanged ciphertext/password bytes before removing empty source ancestors and ./data. Classify the discovered empty orphan project scaffold as empty-directory cleanup only: recheck it after quiescence and use rmdir on empty leaves so any new file blocks removal; never recursively delete an unknown nonempty root. Resume a partially completed move from verified destination records; never merge conflicting copies or discard unknown state."
      ["Proposed: scripts/chatui_storage_migration_test.py covers byte/permission identity, encrypted-key password login after restart, multiple accounts and projects, preserved IDs/views, collisions, unknown files, symlink escape, interrupted/repeated migration and absence of ./data after verified success"]
  , LeanFM.ChatUI.Implementation.decision "shared-project-write-coordination"
      ["property:shared_project_writers_do_not_collide", "property:shared_project_paths_never_reach_credentials", "property:No shared project borrows another caller's model credential", "property:credential_changes_never_rebill_queued_work"]
      ["LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Server.lean", "ui/src/main.tsx"]
      "Coordinate conflicting mutations by canonical project identity, independently of account identity. Bound active model work to one mutating turn per shared project, with a visible pre-mutation busy rejection or bounded serialization; recheck the initiating session before paid work after any wait. Coordinate migration and confirmed deletion with project writers and retain source-revision checks for book editors. Capture the initiating credential account/fingerprint and browser authentication generation with every queued model selection. Keep shared project drafts mounted through login changes but visibly hold unstarted paid prompts on logout expiry key replacement or account switching; never dequeue them under a new key without resubmission. Keep credential references model selections cancellation and token accounting request-local; project files cannot contain decrypted keys or choose a different caller. Continue to confine every model file read/write and media operation to its selected project even though all project roots are shared."
      ["Proposed: scripts/chatui_shared_projects_test.py runs two accounts against one project, detects overlapping writes and lost updates, verifies no billed rejected turn and no credential/header/accounting substitution", "Retain existing media symlink MIME resource and provider-outcome negative tests"]
  , LeanFM.ChatUI.Implementation.decision "checked-project-gates-and-execution"
      ["property:shared_projects_have_one_root", "property:shared_project_writers_do_not_collide", "property:shared_project_paths_never_reach_credentials", "property:explicit_fresh_start_erases_projects_not_credentials"]
      ["scripts/chatui_project_state.py", "scripts/chatui_command.sh", "scripts/chatui_patch.py", "LeanFM/ChatUI/Server.lean", "ui/src/main.tsx", "ui/src/types.ts"]
      "Add a deterministic project-state controller: the current checked requirements revision hashes canonical book requirements protobuf and generated task views; the separately checked implementation revision also hashes its typed mapping and requirements revision. Expose review status through the project specification route and explicit human acceptance through the existing requirements/<revision>/accept and implementation/<revision>/accept HTTP bindings. Persist acceptance beneath the project root in a reserved .leanfm path; model workspace writes and patches cannot modify acceptance or checker evidence. Reject stale or unchecked acceptance without mutation; implementation acceptance requires current requirements acceptance. Show both acceptance actions and concrete stale/missing-check reasons in Project memory. Before source writes or patches, enforce both current gates in the server rather than relying on model prose; the read-only MCP surface cannot accept them. Route allowlisted build/test execution through a network-disabled filesystem sandbox with clean environment project-local caches finite time/output/memory limits and read-only toolchains, so project-authored Makefiles and tests cannot read the credential vault or other projects. Keep one writer per canonical project root across chat local edits deletion and acceptance; reject a conflicting operation before mutation or provider billing."
      ["scripts/chatui_project_state_test.py: stale/unchecked/duplicate gate operations, independent gates, reserved path rejection and source-write refusal before both gates", "scripts/chatui_shared_projects_test.py: concurrent writer and source-gate HTTP rejection before provider work", "scripts/chatui_browser_reset.py: human review/acceptance controls with generated task views and fresh-project completion", "scripts/chatui_command_test.py: project tests cannot read outside roots inherit secrets or reach host network"]
  , LeanFM.ChatUI.Implementation.decision "explicit-fresh-start"
      ["property:explicit_fresh_start_erases_projects_not_credentials", "property:Fresh start preserves LeanFM and encrypted accounts", "property:shared_project_paths_never_reach_credentials"]
      ["scripts/reset_leanfm_workspace.py", "LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Server.lean", "ui/src/main.tsx"]
      "Replace migration of disposable projects with an explicit operator reset when requested. Quiesce the service; inventory immediate ordinary manifest-bearing project roots plus legacy account project roots; reject an unknown non-project entry or an escaping root rather than recursively deleting the repository. Move account records into the private .leanfm/accounts vault with unchanged digests and permissions, verify the destination, and only then erase the enumerated project roots and empty legacy ancestors. Preserve the self-hosting LeanFM root. Start the repaired runtime with workspace/projects discovery independent of credential accounts and a mounted signed-out workspace; require a valid initiating credential session only for provider-backed operations. Create fresh projects from built-in templates with complete canonical manifest paths, an editable book and absent acceptance records. Keep both stakeholder gates explicit and ensure the deterministic provider/browser scenario can generate and validate a simple server specification in a newly created project without examples or historical chat."
      ["scripts/chatui_workspace_reset_test.py: temporary fixture reset deletes ordinary projects, preserves account ciphertext/password bytes and rejects root/vault/symlink escape", "scripts/chatui_shared_projects_test.py: signed-out and cross-account project identity, keyless local operations, provider login guard, origin admission and conflicting writer rejection", "scripts/chatui_browser_reset.py: empty workspace creation to checked server specification through the production UI"]
  ]

def sharedProjectsProposalErrors : List String :=
  let valid := LeanFM.requirementReferenceIds LeanFM.LLMGenerated.SharedProjects.spec
  sharedProjectsProposal.flatMap fun decision =>
    decision.requirementRefs.filterMap fun reference =>
      if valid.contains reference then none
      else some ("unknown proposed requirement reference: " ++ reference)

end LeanFM.LLMGenerated.Implementation

/-- Separately accepted resumable-work mappings, preserved at the canonical entry point. -/
def LeanFM.LLMGenerated.Implementation.resumableWorkDecisions :=
  LeanFM.LLMGenerated.ResumableWorkImplementation.decisions
