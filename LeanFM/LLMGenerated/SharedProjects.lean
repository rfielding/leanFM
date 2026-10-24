import LeanFM.ChatUI.Requirements

/- Proposed revision, not an accepted specification or an implemented migration.
   Prompt: remove ./data; put projects directly under ./projects; projects have
   no user owner, and login exists to protect API-key confidentiality. -/
namespace LeanFM.LLMGenerated.SharedProjects

open LeanFM
open LeanFM.ChatUI.Requirements

def revision : String := "shared-projects-v1"

-- This revision changes access/storage semantics, not the protobuf vocabulary.
def protoSource : String := include_str "../ChatUI/Requirements.proto"

def projectTask : TaskRequirement :=
  { LeanFM.ChatUI.Requirements.projectTask with
    title := "Use the shared workspace independently of a credential account"
    states := LeanFM.ChatUI.Requirements.projectTask.states.map fun state =>
      if state.id == "ready" then { state with label := "shared project home", markdown := "Project identity has no account owner." }
      else if state.id == "listed" then { state with label := "shared project list visible", markdown := "All visitors resolve the same project roots." }
      else state }

def constraints : List TaskConstraint :=
  [ where_ "shared_projects_have_one_root" "manage_projects"
      "Every ordinary workspace project resolves by its manifest project_id to exactly one immediate child of projects/ below the workspace root; project identity listing opening creation and confirmed deletion never depend on username credential account login status or a data/accounts path."
  , where_ "login_protects_keys_only" "authenticate_user"
      "Confirmed access policy: the loopback workspace and its shared projects open without login; login unlocks only that caller's retained provider credentials. No login creates a project namespace or changes the shared catalog."
  , where_ "shared_project_reads_and_local_edits_are_keyless" "manage_projects"
      "Listing and opening projects reading their books diagrams source media and shared conversation and making non-provider local project edits require no provider credential; paid chat research AI assistance and provider-backed repairs require the initiating caller's unlocked credential before any provider call or paid-turn persistence."
  , where_ "shared_storage_preserves_project_identity" "manage_projects"
      "Migrating an existing project preserves its project_id canonical specification and acceptance revisions book source PDFs implementation source images artifacts conversation events logs and caches in one shared project root. Existing destination roots and projects with equal display names remain independent and cannot be overwritten or silently merged."
  , where_ "readable_project_directories_preserve_identity" "manage_projects"
      "Name new project directories after their display names using bounded safe filesystem labels and a short numeric suffix for collisions. A directory rename preserves the existing manifest project_id, URLs, canonical files, conversation, caches, and checked acceptance revisions. Resolve identity from validated root manifests rather than requiring the directory label to equal project_id. Never overwrite or merge an existing directory, adopt a symlink, choose arbitrarily among duplicate manifest identities, or reuse an identity still held by a renamed root."
  , where_ "credential_vault_is_not_a_project" "configure_provider"
      "Password verifiers and encrypted provider credentials remain outside every shared project root in a private application credential vault. The vault is excluded from project discovery project file reads model workspace tools media routes and version control; login unlocks only the caller's account keys and never another visitor's keys."
  , where_ "migration_never_overwrites_or_loses_state" "manage_projects"
      "Storage migration is explicit and restartable after project writers are quiescent. Preflight all sources destinations identifiers paths symlinks and byte inventories before mutation. A collision unsupported entry or failed check leaves existing data recoverable and reports a concrete blocker. Remove the old data directory only after every recognized project and encrypted account record has a verified durable destination; never replace it with an escaping symlink."
  , where_ "shared_project_writers_do_not_collide" "argue_requirements"
      "Concurrent visitors cannot interleave destructive writes or model tool turns against one project and silently lose a conversation source revision or snapshot. Serialize conflicting work or reject it visibly before mutation and provider spending; keep stale-book revision rejection and captured model credential cancellation and accounting identities request-local."
  , where_ "shared_project_paths_never_reach_credentials" "manage_projects"
      "Project identifiers manifests configured artifact paths source and media requests and model tool paths cannot traverse projects or follow symlinks into another project the credential vault the installation or arbitrary filesystem paths. Shared visibility never grants an arbitrary-path capability."
  , where_ "legacy_user_selector_has_no_ownership_meaning" "manage_projects"
      "For wire compatibility the existing ProjectListRequested.user_id field may remain readable but is ignored as a project ownership or namespace selector. Project URL IDs are preserved through migration; no new account owner field is introduced."
  , where_ "shared_project_mutations_reject_cross_site_requests" "manage_projects"
      "Making the loopback workspace independent of login cannot let an unrelated web page create delete or edit projects through the visitor's browser. Mutating requests must pass explicit local Host and same-origin or permitted command-client admission before dispatch; mismatched or cross-site origins DNS-rebinding hosts and ambiguous frames fail before project mutation or provider work."
  , where_ "credential_changes_never_rebill_queued_work" "argue_requirements"
      "A queued paid prompt captures its initiating credential identity as well as its model. Logout session expiry key replacement or account switching cannot silently send an earlier queued prompt using a different caller's key. Preserve shared project drafts while visibly holding or cancelling unstarted paid work until explicitly resubmitted under an unlocked identity; recheck active-session validity at each provider or mutating-tool boundary."
  , where_ "explicit_fresh_start_erases_projects_not_credentials" "manage_projects"
      "On the operator's explicit fresh-start instruction, stop project writers, enumerate and erase ordinary project roots under projects and the legacy data/accounts/*/projects trees, and start with no ordinary projects. Preserve the LeanFM repository's own book canonical specifications source and version history. Relocate password verifiers and encrypted provider credentials byte-for-byte to .leanfm/accounts outside project roots; verify digests and private permissions before removing the old data directory. The reset is an explicitly authorized discard, not a lossless project migration, and cannot silently erase credentials or follow a symlink outside an enumerated project root."
  ]

def replacedConstraints : List String :=
  ["project_owner_is_session_user", "account_state_stays_local_and_unversioned",
   "checkpoint_is_project_authorized_and_secret_free"]

def properties : List RequirementProperty :=
  [ { name := "Shared roots are independent of credential accounts", task := "manage_projects",
      mode := .always, expression := "the same manifest project_id resolves to the same exclusive named projects/ directory for every visitor and account", probability := none }
  , { name := "Shared projects never disclose credential-vault material", task := "configure_provider",
      mode := .never, expression := "a project listing file media artifact conversation model workspace tool error or trace returns a password verifier encryption key provider API key session bearer or credential ciphertext from the private vault", probability := none }
  , { name := "No migration overwrites a project or drops an encrypted key", task := "manage_projects",
      mode := .never, expression := "migration replaces an existing different destination drops a source project or encrypted credential removes the old data root before verification or accepts a path or symlink escape", probability := none }
  , { name := "No shared project borrows another caller's model credential", task := "argue_requirements",
      mode := .never, expression := "a project turn or continuation selects a credential from project state or another visitor instead of the initiating caller's unlocked credential", probability := none }
  , { name := "Fresh start preserves LeanFM and encrypted accounts", task := "manage_projects",
      mode := .never, expression := "an explicitly requested project reset deletes LeanFM source book canonical specifications version history password verifiers or encrypted provider credentials, changes credential bytes, or follows an escaping project symlink", probability := none }
  ]

def outputs : List DesiredOutput :=
  [ { id := "shared-projects.projects.interaction",
      prompt := "Get rid of ./data; projects belong directly in ./projects and are not owned by users.",
      question := "How does a visitor list create open or confirm deletion of a shared project without selecting a credential-account namespace?",
      kind := .interactionDiagram, eventSource := "manage_projects task and projectGrammar in this proposed RequirementSpec",
      reducer := "render every selected project-operation grammar branch against this specification; credential login is a separate task",
      unit := "messages per shared project operation within one workspace" }
  , { id := "shared-projects.projects.state",
      prompt := "Projects are not owned by a user; login protects API-key confidentiality.",
      question := "Which shared-project lifecycle states remain independent of credential unlock?",
      kind := .stateMachine, eventSource := "manage_projects task in this proposed RequirementSpec",
      reducer := "render the shared project task's entry transitions and terminal states",
      unit := "states and transitions per shared project operation" }
  , { id := "shared-projects.keys.interaction",
      prompt := "The logon is just to keep the confidentiality of API keys.",
      question := "Which login messages unlock one caller's API keys while leaving project identity unchanged?",
      kind := .interactionDiagram, eventSource := "authenticate_user task and authenticationGrammar in this proposed RequirementSpec",
      reducer := "render LoginSubmitted then the accepted or rejected credential-unlock branch",
      unit := "messages per credential unlock" }
  , { id := "shared-projects.migration.inventory",
      prompt := "Get rid of ./data and preserve the existing projects and saved API keys.",
      question := "Which legacy project roots and encrypted account records require verified destinations before the old data directory can disappear?",
      kind := .scalar, eventSource := "read-only legacy filesystem inventory plus existing projects directory manifests",
      reducer := "enumerate project roots account-record paths sizes modes and digests without decoding credential contents; check destination collisions and symlinks",
      unit := "source roots and credential records within one workspace; preflight only" }
  , { id := "shared-projects.reset.interaction",
      prompt := "Just blast it all away; start over with a fixed LeanFM and get LeanFM itself right.",
      question := "Which ordinary project deletions make the workspace empty while preserving LeanFM and encrypted account access?",
      kind := .interactionDiagram, eventSource := "manage_projects ProjectDeleteRequested and ProjectDeleted branches plus a quiescent root inventory",
      reducer := "render the explicit reset as the confirmed deletion branch for each enumerated ordinary project; exclude the self-hosting root and credential vault",
      unit := "confirmed ordinary project deletions within this workspace; credentials and self-hosting source excluded" }
  ]

def spec : RequirementSpec :=
  { LeanFM.ChatUI.Requirements.spec with
    id := "leanfm.chatui.shared-projects.proposal"
    title := "Shared project roots and private caller-owned API keys — proposed revision"
    tasks := LeanFM.ChatUI.Requirements.spec.tasks.map fun task =>
      if task.id == "manage_projects" then projectTask else task
    properties := (LeanFM.ChatUI.Requirements.spec.properties.filter fun property =>
      property.name != "Only authenticated users receive project lists" &&
      !replacedConstraints.contains property.name) ++
      properties ++ constraints.map (fun constraint =>
        { name := constraint.id, task := constraint.task, mode := .always,
          expression := constraint.predicate, probability := none })
    requiredProofs := (LeanFM.ChatUI.Requirements.spec.requiredProofs.filter fun obligation =>
      obligation.name != "Authentication gates project access" &&
      obligation.name != "No cross-project or secret live trace" &&
      obligation.name != "Browser diagnostics cannot leak or recurse" &&
      obligation.name != "Concurrent BYOK isolation") ++
      [ { name := "Credential unlock gates provider access only", task := "authenticate_user", mode := .always,
          predicate := "shared project access never unlocks credentials and every provider request names the initiating caller's valid unlocked session", probability := none }
      , { name := "No credential exposure through shared roots", task := "configure_provider", mode := .never,
          predicate := "a shared-project capability resolves any file under the private credential vault or reads another caller's decrypted credentials", probability := none }
      , { name := "No lost migration or overlapping shared writer", task := "manage_projects", mode := .never,
          predicate := "a migrated project or encrypted credential is lost overwritten silently merged or written concurrently with relocation", probability := none }
      , { name := "Concurrent BYOK isolation", task := "argue_requirements", mode := .always,
          predicate := "each simultaneous caller's provider requests use only that caller's unlocked key and private accounting; a result may enter the shared project conversation but never carries another caller's key session bearer or private billing state", probability := none }
      , { name := "No cross-site shared-project mutation", task := "manage_projects", mode := .never,
          predicate := "a foreign browser origin or unapproved Host causes a shared project write deletion provider request or credential change", probability := none } ]
    desiredOutputs := LeanFM.ChatUI.Requirements.spec.desiredOutputs ++ outputs
    markdown :=
      [ { id := "proposal_status", title := "Acceptance is pending",
          body := "The stakeholder requested shared projects under ./projects with login protecting only API keys. This candidate revises the old account-owned project contract. Neither a successful structural check nor these generated views accepts either gate. The stakeholder separately confirmed opening projects before login, with login required for LLM calls and key management; acceptance of this complete requirements revision and its implementation mapping remains pending." }
      , { id := "shared_roots", title := "Projects have no user owner",
          body := "Ordinary project roots are workspace/projects/<readable-project-name>, with manifest project_id preserved independently of the directory label. Project contents include shared conversation state, while credentials remain outside project roots. Discover actual manifest-bearing project directories and preserve existing projects; do not merge projects merely because their titles match." }
      , { id := "credential_separation", title := "Login is credential unlock",
          body := "Credential accounts retain their password-protected encrypted API keys. A shared project cannot choose a credential account. Model requests keep their initiating caller's model credential cancellation and accounting identities, even when another visitor opens the same project." } ] }

def errors : List String :=
  validateRequirementSpec spec ++ validateRequirementProtoFile spec protoSource

end LeanFM.LLMGenerated.SharedProjects
