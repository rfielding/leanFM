import LeanFM.Artifacts

namespace LeanFM.ChatUI.Requirements

/-- A reviewable inventory entry for software needed by a named LeanFM workflow. -/
structure ToolDependency where
  id : String
  required : Bool
  workflow : String
  versionContract : String
  purpose : String
deriving Repr

def toolDependencyInventory : List ToolDependency :=
  [ { id := "lean", required := true, workflow := "build check serve", versionContract := "leanprover/lean4:v4.28.0 from lean-toolchain", purpose := "compile the LeanFM DSL validators renderers and server" }
  , { id := "lake-and-native-toolchain", required := true, workflow := "build check serve", versionContract := "Lake supplied by Lean plus a supported C compiler linker and libc development files", purpose := "resolve Lean modules and link native executables" }
  , { id := "gnu-make-bash-coreutils", required := true, workflow := "all Makefile workflows", versionContract := "GNU Make Bash and coreutils including timeout cmp cp tar gzip and sha256sum", purpose := "orchestrate bounded reproducible commands" }
  , { id := "node-npm", required := true, workflow := "ui-build chatui-check", versionContract := "Node >= 22.12 and npm ci from ui/package-lock.json", purpose := "compile and bundle the React TypeScript UI" }
  , { id := "react-ui-packages", required := true, workflow := "ui-build", versionContract := "exact transitive versions locked by ui/package-lock.json", purpose := "provide React ReactDOM TypeScript Vite and KaTeX MathML rendering" }
  , { id := "python", required := true, workflow := "check chatui-check media", versionContract := "Python >= 3.12 with scripts/chatui_requirements.txt", purpose := "run credential crypto protobuf round trips reducers and sandboxed Pillow GIF generation" }
  , { id := "protobuf-compiler", required := true, workflow := "make validate", versionContract := "protoc supporting proto3 and Python output", purpose := "generate the temporary Python binding used for byte round-trip testing" }
  , { id := "graphviz", required := true, workflow := "make diagrams and make check", versionContract := "Graphviz dot with PNG output", purpose := "rasterize generated DOT diagrams" }
  , { id := "tex-live", required := true, workflow := "make book", versionContract := "pdfLaTeX with the packages named in book/main.tex", purpose := "build book/main.pdf and book/main-dark.pdf" }
  , { id := "go", required := true, workflow := "paxos-check and Go target generation", versionContract := "Go 1.23.12 from the checked Makefile download contract", purpose := "compile and test the repository Go target" }
  , { id := "bubblewrap", required := true, workflow := "workspace_run_gif_generator", versionContract := "Linux bwrap with namespace and bind-mount support", purpose := "run project-local Pillow animation generators without network access" }
  , { id := "ffmpeg", required := true, workflow := "workspace_transcode_mp4 and narrated video", versionContract := "ffmpeg with libx264 H.264 and AAC encoders", purpose := "produce validated shareable MP4 media" }
  , { id := "headless-chrome", required := false, workflow := "ui-snapshots and screenshot-backed book", versionContract := "Google Chrome or Chromium with headless screenshot support and a pinned major version per capture manifest", purpose := "execute deterministic React UI scenarios and capture real DOM-rendered evidence" }
  , { id := "curl-ripgrep-iproute2", required := true, workflow := "http-check stop validation filters", versionContract := "curl rg and ss", purpose := "exercise HTTP routes select expected diagnostics and locate the development server" }
  , { id := "java-tla-tools", required := false, workflow := "tla-toolchain tla-check", versionContract := "Java runtime plus tla2tools 1.7.4 with the Makefile SHA-256", purpose := "run optional TLA+ examples" }
  , { id := "manim-piper", required := false, workflow := "video video-narrated kerberos-video", versionContract := "project-local video Python environment with Manim and Piper plus a selected voice model", purpose := "render optional explanatory videos and narration" }
  , { id := "target-compilers", required := false, workflow := "accepted implementation target", versionContract := "each ImplementationSpec must name and version every additional compiler generator SDK and runtime before source generation", purpose := "prevent an accepted target from depending on undeclared build machinery" }
  ]

def protoSource : String := include_str "Requirements.proto"

def framing : MessageFraming :=
  { kind := .protobufOneof
  , dispatchField := some "payload"
  , note := "Length-delimited EventEnvelope with one visible payload alternative." }

def field (number : Nat) (name : String) (scalar : ProtoScalar) : ProtoFieldSchema :=
  { number, name, scalar }

def message (name src dst : String) (fields : List ProtoFieldSchema) : MessageSchema :=
  { name, src, dst, framing, fields }

def messages : List MessageSchema :=
  [ message "LoginSubmitted" "UserBrowser" "LeanFMServer"
      [field 1 "username" .string, field 2 "credential" .bytes]
  , message "LoginAccepted" "LeanFMServer" "UserBrowser"
      [field 1 "user_id" .string, field 2 "session_id" .string]
  , message "LoginRejected" "LeanFMServer" "UserBrowser" [field 1 "reason" .string]
  , message "AccountCreateSubmitted" "UserBrowser" "LeanFMServer" [field 1 "username" .string, field 2 "login_credential" .bytes, field 3 "provider" .string, field 4 "api_key" .bytes]
  , message "ProviderKeyCheckRequested" "LeanFMServer" "ModelProvider" [field 1 "provider" .string, field 2 "verification_id" .string]
  , message "ProviderKeyVerified" "ModelProvider" "LeanFMServer" [field 1 "verification_id" .string, field 2 "provider_account" .string]
  , message "ProviderKeyRejected" "ModelProvider" "LeanFMServer" [field 1 "verification_id" .string, field 2 "reason" .string]
  , message "AccountCreated" "LeanFMServer" "UserBrowser" [field 1 "user_id" .string, field 2 "credential_ref" .string]
  , message "AccountCreateRejected" "LeanFMServer" "UserBrowser" [field 1 "reason" .string]
  , message "TaskModelRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "task_id" .string, field 3 "requirements_revision" .string]
  , message "TaskModelReturned" "LeanFMServer" "UserBrowser" [field 1 "task_id" .string, field 2 "interaction_artifact_id" .string, field 3 "state_machine_artifact_id" .string, field 4 "message_sequence_artifact_id" .string, field 5 "constraint_ids" .string]
  , message "MessageSequenceRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "task_id" .string, field 3 "session_id" .string]
  , message "MessageSequenceReturned" "LeanFMServer" "UserBrowser" [field 1 "task_id" .string, field 2 "session_id" .string, field 3 "event_ids" .string]
  , message "ProtobufObjectRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "event_id" .string]
  , message "ProtobufObjectReturned" "LeanFMServer" "UserBrowser" [field 1 "event_id" .string, field 2 "protobuf_type" .string, field 3 "encoded_object" .bytes, field 4 "redacted_json" .string]
  , message "WebResearchRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "conversation_id" .string, field 3 "request_id" .string, field 4 "question" .string, field 5 "supplied_urls" .string]
  , message "WebResearchDispatched" "LeanFMServer" "ModelProvider" [field 1 "request_id" .string, field 2 "model" .string, field 3 "research_mode" .string]
  , message "WebSearchPerformed" "ModelProvider" "LeanFMServer" [field 1 "request_id" .string, field 2 "queries" .string]
  , message "WebPageOpened" "ModelProvider" "LeanFMServer" [field 1 "request_id" .string, field 2 "url" .string, field 3 "title" .string]
  , message "WebResearchReturned" "LeanFMServer" "UserBrowser" [field 1 "request_id" .string, field 2 "parts" .bytes, field 3 "source_urls" .string]
  , message "WebResearchFailed" "LeanFMServer" "UserBrowser" [field 1 "request_id" .string, field 2 "reason" .string]
  , message "MarkerboardAssistRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "artifact_id" .string, field 3 "base_revision" .uint64, field 4 "diagram_kind" .string, field 5 "source" .string, field 6 "instruction" .string, field 7 "mode" .string, field 8 "credential_ref" .string]
  , message "MarkerboardSyntaxHelpReturned" "LeanFMServer" "UserBrowser" [field 1 "artifact_id" .string, field 2 "base_revision" .uint64, field 3 "help_markdown" .string]
  , message "MarkerboardAssistDispatched" "LeanFMServer" "ModelProvider" [field 1 "request_id" .string, field 2 "artifact_id" .string, field 3 "base_revision" .uint64, field 4 "diagram_kind" .string, field 5 "source" .string, field 6 "instruction" .string]
  , message "MarkerboardAssistReturned" "ModelProvider" "LeanFMServer" [field 1 "request_id" .string, field 2 "proposed_source" .string, field 3 "explanation" .string, field 4 "input_tokens" .uint64, field 5 "output_tokens" .uint64]
  , message "MarkerboardPatchProposed" "LeanFMServer" "UserBrowser" [field 1 "artifact_id" .string, field 2 "base_revision" .uint64, field 3 "proposed_source" .string, field 4 "explanation" .string]
  , message "MarkerboardPatchAccepted" "UserBrowser" "LeanFMServer" [field 1 "artifact_id" .string, field 2 "base_revision" .uint64, field 3 "proposed_source" .string]
  , message "MarkerboardPatchRejected" "UserBrowser" "LeanFMServer" [field 1 "artifact_id" .string, field 2 "base_revision" .uint64]
  , message "MarkerboardDraftUpdated" "LeanFMServer" "UserBrowser" [field 1 "artifact_id" .string, field 2 "revision" .uint64, field 3 "source" .string]
  , message "ProjectListRequested" "UserBrowser" "LeanFMServer" [field 1 "user_id" .string]
  , message "ProjectListReturned" "LeanFMServer" "UserBrowser" [field 1 "project_ids" .string]
  , message "ProjectCreateRequested" "UserBrowser" "LeanFMServer" [field 1 "display_name" .string]
  , message "ProjectCreated" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "display_name" .string]
  , message "ProjectOpenRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string]
  , message "ProjectOpened" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "current_requirements_revision" .string]
  , message "ProjectDeleteRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "confirmation" .string]
  , message "ProjectDeleted" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string]
  , message "ProblemInquiryPresented" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "question" .string]
  , message "ProblemStatementSubmitted" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "statement" .string]
  , message "AmbiguityQuestionPresented" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "ambiguity_id" .string, field 3 "question" .string, field 4 "affected_artifacts" .string]
  , message "ClarificationSubmitted" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "ambiguity_id" .string, field 3 "answer" .string]
  , message "ProjectBookRevised" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "book_revision" .string, field 3 "decision_ids" .string, field 4 "light_pdf" .string, field 5 "dark_pdf" .string]
  , message "RequirementsReviewPresented" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "requirements_revision" .string, field 3 "derived_artifact_ids" .string, field 4 "open_ambiguity_ids" .string]
  , message "SpecificationRequirementsAccepted" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "requirements_revision" .string]
  , message "ImplementationReviewPresented" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "requirements_revision" .string, field 3 "implementation_revision" .string, field 4 "traceability_report" .string]
  , message "SpecificationImplementationAccepted" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "requirements_revision" .string, field 3 "implementation_revision" .string]
  , message "ImplementationAuthorizationConfirmed" "LeanFMServer" "UserBrowser" [field 1 "project_id" .string, field 2 "requirements_revision" .string, field 3 "implementation_revision" .string]
  , message "ProviderCredentialSubmitted" "UserBrowser" "LeanFMServer" [field 1 "provider" .string, field 2 "api_key" .bytes, field 3 "retention" .string]
  , message "ProviderCredentialAccepted" "LeanFMServer" "UserBrowser" [field 1 "credential_ref" .string, field 2 "billing_source" .string]
  , message "ProviderCredentialRejected" "LeanFMServer" "UserBrowser" [field 1 "reason" .string]
  , message "ChatPromptSubmitted" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "conversation_id" .string, field 3 "message_id" .string, field 4 "parts" .bytes, field 5 "attachment_ids" .string, field 6 "credential_ref" .string, field 7 "model" .string]
  , message "ModelRequestIssued" "LeanFMServer" "ModelProvider" [field 1 "project_id" .string, field 2 "conversation_id" .string, field 3 "request_id" .string, field 4 "model" .string, field 5 "research_mode" .string]
  , message "ModelResponseReturned" "ModelProvider" "LeanFMServer" [field 1 "request_id" .string, field 2 "parts" .bytes, field 3 "input_tokens" .uint64, field 4 "cached_input_tokens" .uint64, field 5 "output_tokens" .uint64, field 6 "context_window_tokens" .uint64]
  , message "ChatResponseRendered" "LeanFMServer" "UserBrowser" [field 1 "conversation_id" .string, field 2 "message_id" .string, field 3 "parts" .bytes, field 4 "artifact_ids" .string, field 5 "input_tokens" .uint64, field 6 "cached_input_tokens" .uint64, field 7 "output_tokens" .uint64, field 8 "context_window_tokens" .uint64, field 9 "usage_warning" .string, field 10 "response_time_ms" .uint64]
  , message "ChatTurnFailed" "LeanFMServer" "UserBrowser" [field 1 "request_id" .string, field 2 "reason" .string]
  , message "MermaidDraftSaved" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "artifact_id" .string, field 3 "revision" .uint64, field 4 "diagram_kind" .string, field 5 "source" .string]
  , message "MermaidPreviewRendered" "LeanFMServer" "UserBrowser" [field 1 "artifact_id" .string, field 2 "revision" .uint64, field 3 "svg" .bytes]
  , message "MediaUploaded" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "artifact_id" .string, field 3 "media_type" .string, field 4 "content" .bytes]
  , message "MediaRendered" "LeanFMServer" "UserBrowser" [field 1 "artifact_id" .string, field 2 "media_type" .string, field 3 "content_url" .string]
  , message "ArtifactPromoted" "UserBrowser" "LeanFMServer" [field 1 "artifact_id" .string, field 2 "revision" .uint64, field 3 "target_status" .string]
  , message "CandidateRequirementUpdated" "LeanFMServer" "UserBrowser" [field 1 "requirements_revision" .string, field 2 "source_artifact_ids" .string]
  , message "ArtifactListRequested" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "kind_filter" .string, field 3 "scenario_filter" .string, field 4 "status_filter" .string]
  , message "ArtifactListReturned" "LeanFMServer" "UserBrowser" [field 1 "artifacts" .bytes]
  , message "ArtifactOpenRequested" "UserBrowser" "LeanFMServer" [field 1 "artifact_id" .string, field 2 "revision" .uint64]
  , message "ArtifactOpened" "LeanFMServer" "UserBrowser" [field 1 "artifact_id" .string, field 2 "revision" .uint64, field 3 "status" .string, field 4 "media_type" .string, field 5 "content" .bytes, field 6 "provenance" .string]
  ]

def state (id label group : String) (terminal : Bool := false) : RequirementState :=
  { id, label, group, markdown := label, terminal }

def transition (src dst message : String) : RequirementTransition :=
  { src, dst, message, probabilityNum := 1, probabilityDen := 1, dwellMs := 0 }

def authenticationTask : TaskRequirement :=
  { id := "authenticate_user"
  , title := "Authenticate an individual user"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "signed_out"
  , states :=
      [ state "signed_out" "signed out" "identity"
      , state "checking" "credential under verification" "identity"
      , state "authenticated" "authenticated user session" "terminal" true
      , state "rejected" "login rejected without a session" "terminal" true ]
  , transitions :=
      [ transition "signed_out" "checking" "LoginSubmitted"
      , transition "checking" "authenticated" "LoginAccepted"
      , transition "checking" "rejected" "LoginRejected" ] }

def accountCreationTask : TaskRequirement :=
  { id := "create_account"
  , title := "Create an account using a user-supplied provider API key"
  , actors := ["UserBrowser", "LeanFMServer", "ModelProvider"]
  , initialState := "registration"
  , states :=
      [ state "registration" "account registration form" "identity"
      , state "submitted" "username, login credential, provider, and user API key submitted" "identity"
      , state "verifying" "user API key verification requested from its provider" "provider"
      , state "verified" "provider accepted the supplied API key" "provider"
      , state "key_rejected" "provider rejected the supplied API key" "provider"
      , state "created" "account and reference to an account-owned encrypted provider key created" "terminal" true
      , state "rejected" "account creation rejected without an account" "terminal" true ]
  , transitions :=
      [ transition "registration" "submitted" "AccountCreateSubmitted"
      , transition "submitted" "verifying" "ProviderKeyCheckRequested"
      , transition "verifying" "verified" "ProviderKeyVerified"
      , transition "verifying" "key_rejected" "ProviderKeyRejected"
      , transition "verified" "created" "AccountCreated"
      , transition "key_rejected" "rejected" "AccountCreateRejected" ] }

def projectTask : TaskRequirement :=
  { id := "manage_projects"
  , title := "List, create, open, and delete owned projects"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "ready"
  , states :=
      [ state "ready" "authenticated project home" "projects"
      , state "listing" "project list requested" "projects"
      , state "listed" "authorized project list visible" "terminal" true
      , state "creating" "new project requested" "projects"
      , state "created" "exclusive project root created" "terminal" true
      , state "opening" "project open requested" "projects"
      , state "opened" "project workbench opened" "terminal" true
      , state "deleting" "confirmed project deletion requested" "projects"
      , state "deleted" "exclusive project root deleted" "terminal" true ]
  , transitions :=
      [ transition "ready" "listing" "ProjectListRequested"
      , transition "listing" "listed" "ProjectListReturned"
      , transition "ready" "creating" "ProjectCreateRequested"
      , transition "creating" "created" "ProjectCreated"
      , transition "ready" "opening" "ProjectOpenRequested"
      , transition "opening" "opened" "ProjectOpened"
      , transition "ready" "deleting" "ProjectDeleteRequested"
      , transition "deleting" "deleted" "ProjectDeleted" ] }

def credentialTask : TaskRequirement :=
  { id := "configure_provider"
  , title := "Select user-funded or platform-funded model access"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "unconfigured"
  , states :=
      [ state "unconfigured" "no selected model credential" "provider"
      , state "checking" "provider credential under verification" "provider"
      , state "configured" "credential reference to an account-owned encrypted provider key available" "terminal" true
      , state "rejected" "credential rejected without storage" "terminal" true ]
  , transitions :=
      [ transition "unconfigured" "checking" "ProviderCredentialSubmitted"
      , transition "checking" "configured" "ProviderCredentialAccepted"
      , transition "checking" "rejected" "ProviderCredentialRejected" ] }

def specificationConversationTask : TaskRequirement :=
  { id := "develop_project_specification"
  , title := "Turn a fresh project conversation into accepted requirements and implementation"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "project_loaded"
  , states :=
      [ state "project_loaded" "project directory loaded as the complete initial context" "inquiry"
      , state "awaiting_problem" "the user is asked what problem they are trying to solve" "inquiry"
      , state "discovering" "the problem and current durable artifacts are being interrogated" "requirements"
      , state "awaiting_clarification" "one named ambiguity is awaiting a stakeholder answer" "requirements"
      , state "requirements_review" "validated requirements and derived views await explicit acceptance" "requirements gate"
      , state "requirements_accepted" "the exact requirements revision is accepted" "implementation"
      , state "implementation_review" "traceable implementation mapping awaits explicit acceptance" "implementation gate"
      , state "implementation_accepted" "the exact implementation revision is accepted" "implementation gate"
      , state "ready_to_implement" "both exact revisions are accepted for one-shot implementation" "terminal" true ]
  , transitions :=
      [ transition "project_loaded" "awaiting_problem" "ProblemInquiryPresented"
      , transition "awaiting_problem" "discovering" "ProblemStatementSubmitted"
      , transition "discovering" "discovering" "ProjectBookRevised"
      , transition "discovering" "awaiting_clarification" "AmbiguityQuestionPresented"
      , transition "awaiting_clarification" "discovering" "ClarificationSubmitted"
      , transition "awaiting_clarification" "awaiting_clarification" "ProjectBookRevised"
      , transition "discovering" "requirements_review" "RequirementsReviewPresented"
      , transition "requirements_review" "requirements_accepted" "SpecificationRequirementsAccepted"
      , transition "requirements_accepted" "implementation_review" "ImplementationReviewPresented"
      , transition "implementation_review" "implementation_accepted" "SpecificationImplementationAccepted"
      , transition "implementation_accepted" "ready_to_implement" "ImplementationAuthorizationConfirmed" ] }

def chatTask : TaskRequirement :=
  { id := "argue_requirements"
  , title := "Conduct one durable project-scoped requirements turn"
  , actors := ["UserBrowser", "LeanFMServer", "ModelProvider"]
  , initialState := "ready"
  , states :=
      [ state "ready" "project chat accepts text, mathematics, diagrams, images, video, code, and files" "chat"
      , state "submitted" "durable multipart user question submitted" "chat"
      , state "model_pending" "contextual model request pending" "provider"
      , state "model_returned" "model response received" "provider"
      , state "rendered" "multipart assistant response and artifact references rendered inline" "terminal" true
      , state "failed" "visible chat failure" "terminal" true ]
  , transitions :=
      [ transition "ready" "submitted" "ChatPromptSubmitted"
      , transition "submitted" "model_pending" "ModelRequestIssued"
      , transition "model_pending" "model_returned" "ModelResponseReturned"
      , transition "model_returned" "rendered" "ChatResponseRendered"
      , transition "model_pending" "failed" "ChatTurnFailed" ] }

def markerboardTask : TaskRequirement :=
  { id := "markerboard"
  , title := "Sketch and promote multimodal requirement artifacts"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "editing"
  , states :=
      [ state "editing" "dark-mode markerboard editing" "scratch"
      , state "diagram_saved" "versioned Mermaid source saved" "scratch"
      , state "diagram_rendered" "latest valid dark preview visible" "scratch"
      , state "media_saved" "image or video stored in project" "scratch"
      , state "media_rendered" "image or video visible" "scratch"
      , state "promoting" "specific artifact revision selected" "candidate"
      , state "candidate" "candidate requirement updated from promoted artifact" "terminal" true ]
  , transitions :=
      [ transition "editing" "diagram_saved" "MermaidDraftSaved"
      , transition "diagram_saved" "diagram_rendered" "MermaidPreviewRendered"
      , transition "editing" "media_saved" "MediaUploaded"
      , transition "media_saved" "media_rendered" "MediaRendered"
      , transition "diagram_rendered" "promoting" "ArtifactPromoted"
      , transition "media_rendered" "promoting" "ArtifactPromoted"
      , transition "promoting" "candidate" "CandidateRequirementUpdated" ] }

def artifactsTask : TaskRequirement :=
  { id := "inspect_artifacts"
  , title := "Inspect current, accepted, superseded, and stale artifacts"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "closed"
  , states :=
      [ state "closed" "artifact tab closed" "artifacts"
      , state "listing" "artifact list requested" "artifacts"
      , state "listed" "revision-aware artifact list visible" "terminal" true
      , state "opening" "specific artifact revision requested" "artifacts"
      , state "opened" "artifact content and provenance visible" "terminal" true ]
  , transitions :=
      [ transition "closed" "listing" "ArtifactListRequested"
      , transition "listing" "listed" "ArtifactListReturned"
      , transition "listed" "opening" "ArtifactOpenRequested"
      , transition "opening" "opened" "ArtifactOpened" ] }

def inspectTaskModelTask : TaskRequirement :=
  { id := "inspect_task_model"
  , title := "Inspect one task's linked interaction, state machine, constraints, and protobuf events"
  , actors := ["UserBrowser", "LeanFMServer"]
  , initialState := "closed"
  , states :=
      [ state "closed" "no task model selected" "task model"
      , state "loading" "one task and one requirements revision requested" "task model"
      , state "linked" "task-local interaction, state machine, message sequence, and constraints linked together" "task model"
      , state "sequence_loading" "one task session message sequence requested" "events"
      , state "sequence_visible" "ordered protobuf event objects visible" "events"
      , state "object_loading" "one protobuf event requested" "events"
      , state "object_visible" "protobuf type, redacted fields, and encoded object visible" "terminal" true ]
  , transitions :=
      [ transition "closed" "loading" "TaskModelRequested"
      , transition "loading" "linked" "TaskModelReturned"
      , transition "linked" "sequence_loading" "MessageSequenceRequested"
      , transition "sequence_loading" "sequence_visible" "MessageSequenceReturned"
      , transition "sequence_visible" "object_loading" "ProtobufObjectRequested"
      , transition "object_loading" "object_visible" "ProtobufObjectReturned" ] }

def webResearchTask : TaskRequirement :=
  { id := "research_web"
  , title := "Search the public web, follow supplied HTTP URLs, and return clickable citations"
  , actors := ["UserBrowser", "LeanFMServer", "ModelProvider"]
  , initialState := "ready"
  , states :=
      [ state "ready" "research question or public HTTP URLs accepted" "research"
      , state "requested" "project-scoped web research requested" "research"
      , state "dispatched" "research sent to the provider with hosted web search enabled" "provider"
      , state "searching" "provider web search performed" "provider"
      , state "opening" "provider opened a cited public page" "provider"
      , state "returned" "answer with visible clickable source citations returned" "terminal" true
      , state "failed" "research failure is visible without an uncited claim" "terminal" true ]
  , transitions :=
      [ transition "ready" "requested" "WebResearchRequested"
      , transition "requested" "dispatched" "WebResearchDispatched"
      , transition "dispatched" "searching" "WebSearchPerformed"
      , transition "searching" "opening" "WebPageOpened"
      , transition "opening" "returned" "WebResearchReturned"
      , transition "requested" "failed" "WebResearchFailed"
      , transition "dispatched" "failed" "WebResearchFailed"
      , transition "searching" "failed" "WebResearchFailed"
      , transition "opening" "failed" "WebResearchFailed" ] }

def markerboardAssistTask : TaskRequirement :=
  { id := "assist_markerboard"
  , title := "Recall diagram syntax or propose AI-generated detail for one markerboard revision"
  , actors := ["UserBrowser", "LeanFMServer", "ModelProvider"]
  , initialState := "editing"
  , states :=
      [ state "editing" "one exact markerboard draft revision is visible" "assist"
      , state "requested" "syntax or generation assistance requested against the base revision" "assist"
      , state "helped" "syntax reference returned without changing the draft" "terminal" true
      , state "dispatched" "detail-generation request sent to the provider" "provider"
      , state "returned" "provider returned proposed source and usage" "provider"
      , state "proposed" "diffable proposed source awaits a user decision" "review"
      , state "accepted" "user accepted the proposal against the unchanged base revision" "review"
      , state "updated" "new markerboard revision saved and previewed" "terminal" true
      , state "rejected" "proposal rejected and original draft retained" "terminal" true ]
  , transitions :=
      [ transition "editing" "requested" "MarkerboardAssistRequested"
      , transition "requested" "helped" "MarkerboardSyntaxHelpReturned"
      , transition "requested" "dispatched" "MarkerboardAssistDispatched"
      , transition "dispatched" "returned" "MarkerboardAssistReturned"
      , transition "returned" "proposed" "MarkerboardPatchProposed"
      , transition "proposed" "accepted" "MarkerboardPatchAccepted"
      , transition "accepted" "updated" "MarkerboardDraftUpdated"
      , transition "proposed" "rejected" "MarkerboardPatchRejected" ] }

def atom (task src dst message : String) : GrammarExpr :=
  .event { task, src, dst, message }

def authenticationGrammar : TaskGrammar :=
  { task := "authenticate_user", entry := "signed_out", terminals := ["authenticated", "rejected"]
  , body := atom "authenticate_user" "UserBrowser" "LeanFMServer" "LoginSubmitted" >>>
      GrammarExpr.alt
        [ atom "authenticate_user" "LeanFMServer" "UserBrowser" "LoginAccepted"
        , atom "authenticate_user" "LeanFMServer" "UserBrowser" "LoginRejected" ] }

def accountCreationGrammar : TaskGrammar :=
  { task := "create_account", entry := "registration", terminals := ["created", "rejected"]
  , body := GrammarExpr.seqList
      [ atom "create_account" "UserBrowser" "LeanFMServer" "AccountCreateSubmitted"
      , atom "create_account" "LeanFMServer" "ModelProvider" "ProviderKeyCheckRequested"
      , GrammarExpr.alt
          [ atom "create_account" "ModelProvider" "LeanFMServer" "ProviderKeyVerified" >>>
              atom "create_account" "LeanFMServer" "UserBrowser" "AccountCreated"
          , atom "create_account" "ModelProvider" "LeanFMServer" "ProviderKeyRejected" >>>
              atom "create_account" "LeanFMServer" "UserBrowser" "AccountCreateRejected" ] ] }

def projectGrammar : TaskGrammar :=
  { task := "manage_projects", entry := "ready", terminals := ["listed", "created", "opened", "deleted"]
  , body := .alt
      [ GrammarExpr.seqList [atom "manage_projects" "UserBrowser" "LeanFMServer" "ProjectListRequested", atom "manage_projects" "LeanFMServer" "UserBrowser" "ProjectListReturned"]
      , GrammarExpr.seqList [atom "manage_projects" "UserBrowser" "LeanFMServer" "ProjectCreateRequested", atom "manage_projects" "LeanFMServer" "UserBrowser" "ProjectCreated"]
      , GrammarExpr.seqList [atom "manage_projects" "UserBrowser" "LeanFMServer" "ProjectOpenRequested", atom "manage_projects" "LeanFMServer" "UserBrowser" "ProjectOpened"]
      , GrammarExpr.seqList [atom "manage_projects" "UserBrowser" "LeanFMServer" "ProjectDeleteRequested", atom "manage_projects" "LeanFMServer" "UserBrowser" "ProjectDeleted"] ] }

def credentialGrammar : TaskGrammar :=
  { task := "configure_provider", entry := "unconfigured", terminals := ["configured", "rejected"]
  , body := atom "configure_provider" "UserBrowser" "LeanFMServer" "ProviderCredentialSubmitted" >>>
      GrammarExpr.alt
        [ atom "configure_provider" "LeanFMServer" "UserBrowser" "ProviderCredentialAccepted"
        , atom "configure_provider" "LeanFMServer" "UserBrowser" "ProviderCredentialRejected" ] }

def specificationConversationGrammar : TaskGrammar :=
  { task := "develop_project_specification", entry := "project_loaded", terminals := ["ready_to_implement"]
  , body :=
      atom "develop_project_specification" "LeanFMServer" "UserBrowser" "ProblemInquiryPresented" >>>
      atom "develop_project_specification" "UserBrowser" "LeanFMServer" "ProblemStatementSubmitted" >>>
      GrammarExpr.repeat
        (GrammarExpr.optional (atom "develop_project_specification" "LeanFMServer" "UserBrowser" "ProjectBookRevised") >>>
         atom "develop_project_specification" "LeanFMServer" "UserBrowser" "AmbiguityQuestionPresented" >>>
         atom "develop_project_specification" "UserBrowser" "LeanFMServer" "ClarificationSubmitted") >>>
      GrammarExpr.optional (atom "develop_project_specification" "LeanFMServer" "UserBrowser" "ProjectBookRevised") >>>
      atom "develop_project_specification" "LeanFMServer" "UserBrowser" "RequirementsReviewPresented" >>>
      atom "develop_project_specification" "UserBrowser" "LeanFMServer" "SpecificationRequirementsAccepted" >>>
      atom "develop_project_specification" "LeanFMServer" "UserBrowser" "ImplementationReviewPresented" >>>
      atom "develop_project_specification" "UserBrowser" "LeanFMServer" "SpecificationImplementationAccepted" >>>
      atom "develop_project_specification" "LeanFMServer" "UserBrowser" "ImplementationAuthorizationConfirmed" }

def chatGrammar : TaskGrammar :=
  { task := "argue_requirements", entry := "ready", terminals := ["rendered", "failed"]
  , body := GrammarExpr.seqList
      [ atom "argue_requirements" "UserBrowser" "LeanFMServer" "ChatPromptSubmitted"
      , atom "argue_requirements" "LeanFMServer" "ModelProvider" "ModelRequestIssued"
      , .alt
          [ atom "argue_requirements" "ModelProvider" "LeanFMServer" "ModelResponseReturned" >>>
              atom "argue_requirements" "LeanFMServer" "UserBrowser" "ChatResponseRendered"
          , atom "argue_requirements" "LeanFMServer" "UserBrowser" "ChatTurnFailed" ] ] }

def markerboardGrammar : TaskGrammar :=
  { task := "markerboard", entry := "editing", terminals := ["candidate"]
  , body := .alt
      [ GrammarExpr.seqList
          [ atom "markerboard" "UserBrowser" "LeanFMServer" "MermaidDraftSaved"
          , atom "markerboard" "LeanFMServer" "UserBrowser" "MermaidPreviewRendered"
          , atom "markerboard" "UserBrowser" "LeanFMServer" "ArtifactPromoted"
          , atom "markerboard" "LeanFMServer" "UserBrowser" "CandidateRequirementUpdated" ]
      , GrammarExpr.seqList
          [ atom "markerboard" "UserBrowser" "LeanFMServer" "MediaUploaded"
          , atom "markerboard" "LeanFMServer" "UserBrowser" "MediaRendered"
          , atom "markerboard" "UserBrowser" "LeanFMServer" "ArtifactPromoted"
          , atom "markerboard" "LeanFMServer" "UserBrowser" "CandidateRequirementUpdated" ] ] }

def artifactsGrammar : TaskGrammar :=
  { task := "inspect_artifacts", entry := "closed", terminals := ["listed", "opened"]
  , body := GrammarExpr.seqList
      [ atom "inspect_artifacts" "UserBrowser" "LeanFMServer" "ArtifactListRequested"
      , atom "inspect_artifacts" "LeanFMServer" "UserBrowser" "ArtifactListReturned"
      , .optional <| GrammarExpr.seqList
          [ atom "inspect_artifacts" "UserBrowser" "LeanFMServer" "ArtifactOpenRequested"
          , atom "inspect_artifacts" "LeanFMServer" "UserBrowser" "ArtifactOpened" ] ] }

def inspectTaskModelGrammar : TaskGrammar :=
  { task := "inspect_task_model", entry := "closed", terminals := ["linked", "sequence_visible", "object_visible"]
  , body := GrammarExpr.seqList
      [ atom "inspect_task_model" "UserBrowser" "LeanFMServer" "TaskModelRequested"
      , atom "inspect_task_model" "LeanFMServer" "UserBrowser" "TaskModelReturned"
      , .optional <| GrammarExpr.seqList
          [ atom "inspect_task_model" "UserBrowser" "LeanFMServer" "MessageSequenceRequested"
          , atom "inspect_task_model" "LeanFMServer" "UserBrowser" "MessageSequenceReturned"
          , .optional <| GrammarExpr.seqList
              [ atom "inspect_task_model" "UserBrowser" "LeanFMServer" "ProtobufObjectRequested"
              , atom "inspect_task_model" "LeanFMServer" "UserBrowser" "ProtobufObjectReturned" ] ] ] }

def webResearchGrammar : TaskGrammar :=
  { task := "research_web", entry := "ready", terminals := ["returned", "failed"]
  , body := GrammarExpr.seqList
      [ atom "research_web" "UserBrowser" "LeanFMServer" "WebResearchRequested"
      , atom "research_web" "LeanFMServer" "ModelProvider" "WebResearchDispatched"
      , GrammarExpr.alt
        [ GrammarExpr.seqList
            [ atom "research_web" "ModelProvider" "LeanFMServer" "WebSearchPerformed"
            , atom "research_web" "ModelProvider" "LeanFMServer" "WebPageOpened"
            , atom "research_web" "LeanFMServer" "UserBrowser" "WebResearchReturned" ]
        , atom "research_web" "LeanFMServer" "UserBrowser" "WebResearchFailed" ] ] }

def markerboardAssistGrammar : TaskGrammar :=
  { task := "assist_markerboard", entry := "editing", terminals := ["helped", "updated", "rejected"]
  , body := atom "assist_markerboard" "UserBrowser" "LeanFMServer" "MarkerboardAssistRequested" >>>
      GrammarExpr.alt
        [ atom "assist_markerboard" "LeanFMServer" "UserBrowser" "MarkerboardSyntaxHelpReturned"
        , GrammarExpr.seqList
            [ atom "assist_markerboard" "LeanFMServer" "ModelProvider" "MarkerboardAssistDispatched"
            , atom "assist_markerboard" "ModelProvider" "LeanFMServer" "MarkerboardAssistReturned"
            , atom "assist_markerboard" "LeanFMServer" "UserBrowser" "MarkerboardPatchProposed"
            , GrammarExpr.alt
                [ atom "assist_markerboard" "UserBrowser" "LeanFMServer" "MarkerboardPatchAccepted" >>>
                    atom "assist_markerboard" "LeanFMServer" "UserBrowser" "MarkerboardDraftUpdated"
                , atom "assist_markerboard" "UserBrowser" "LeanFMServer" "MarkerboardPatchRejected" ] ] ] }

structure TaskConstraint where
  id : String
  task : String
  predicate : String
deriving Repr

/-- Durable task constraints use the same `where_` vocabulary shown to the user. -/
def where_ (id task predicate : String) : TaskConstraint := { id, task, predicate }

def taskConstraints : List TaskConstraint :=
  [ where_ "signup_requires_verified_byok" "create_account" "AccountCreated has a same-flow ProviderKeyVerified for AccountCreateSubmitted.api_key"
  , where_ "stored_provider_keys_are_encrypted" "create_account" "a retained provider API key is stored as authenticated ciphertext under a separate password-derived key; passwords are salted KDF verifiers; neither decrypted keys nor sessions are persisted; AccountCreated returns only its credential_ref"
  , where_ "account_state_stays_local_and_unversioned" "create_account" "by default account records salted password verifiers encrypted provider credentials session state and private conversations remain only beneath the operator-selected local data root; the repository ignores that root and continuous integration fails if any account-state path becomes tracked, while checked-in example projects contain no login or credential material"
  , where_ "project_owner_is_session_user" "manage_projects" "every project operation is authorized for the authenticated session user"
  , where_ "project_navigation_scroll_is_independent" "manage_projects" "the left project list owns a bounded vertical scroll region independent of the selected right-hand Chat Book Grammar Tasks or Source pane; the brand project-creation controls font zoom and authenticated account footer remain fixed while either side scrolls"
  , where_ "fresh_session_needs_only_project_root" "develop_project_specification" "the initial agent input is the project root; the server loads its manifest book canonical specifications accepted revisions source and evidence without requiring a copied transcript or handcrafted bootstrap prompt"
  , where_ "web_ui_replaces_external_coding_session" "develop_project_specification" "after account and project creation an ordinary user can perform the complete project workflow in the authenticated web UI using the user's own provider credential: edit and preview the book and derived diagrams, generate validate review and accept requirements, generate review and accept implementation mappings and issues, inspect and edit only the selected project repository, review proposed diffs, run bounded builds and tests, and inspect their logs without requiring Codex or another external coding interface"
  , where_ "chat_layers_mutate_only_their_artifacts" "develop_project_specification" "the server infers Book Requirements Implementation specification or Implementation work from ordinary chat without requiring a mode selector; every turn loads the selected project revision and may propose or perform only phase-authorized project-root changes, with generated diffs validation and logs visible before an acceptance gate or repository mutation is finalized"
  , where_ "fresh_project_begins_with_problem_inquiry" "develop_project_specification" "before accepting an ordinary solution prompt a new project visibly asks what problem the stakeholder is trying to solve"
  , where_ "questions_reduce_named_ambiguities" "develop_project_specification" "each follow-up question names an unresolved ambiguity and the durable artifacts or acceptance decision affected by its answer; it does not divert into unrelated assistance"
  , where_ "answered_questions_are_closed" "develop_project_specification" "a submitted structured answer retains its stable question ID and selected values; that ID and the same semantic question cannot be asked again, and the next assistant turn produces a material result before any new clarification"
  , where_ "reversible_defaults_prevent_interrogation_loops" "develop_project_specification" "an identifiable reversible request proceeds with stated conventional defaults; a requested result gets at most one clarification turn, while acceptance gates destructive actions and expensive irreversible choices remain explicit"
  , where_ "one_shot_readiness_requests_trigger_questions" "develop_project_specification" "when the stakeholder asks whether there is enough detail to one-shot the software the agent inspects the durable book requirements implementation mapping acceptance revisions and source, then presents at most the two highest-impact unresolved decisions whose absence prevents a conforming one-pass implementation; this explicit readiness request is not treated as a concrete artifact command"
  , where_ "security_critique_precedes_source_generation" "develop_project_specification" "before any implementation source is generated the agent critiques the accepted design across trust boundaries protected assets attacker capabilities abuse cases authorization tenant and project isolation secret handling injection path and symlink escape executable media resource exhaustion replay request confusion privilege expansion and fail-open behavior; every applicable risk becomes a durable MUST NOT constraint mapped to an implementation control and negative test or proof obligation, and an unmitigated material threat returns to the implementation-specification gate"
  , where_ "security_review_precedes_commit" "develop_project_specification" "before recommending or performing any commit the agent inspects the actual candidate diff and generated artifacts for secrets authorization and isolation failures injection path or symlink escape executable content unbounded resources unsafe generated artifacts replay request confusion privilege expansion and fail-open behavior; it states the intended positive invariant and maps each material forbidden behavior to an implementation control and negative test or proof, while any unresolved material threat blocks commit readiness"
  , where_ "feature_completion_pairs_positive_and_negative_invariants" "develop_project_specification" "before a feature is declared complete its intended positive always invariant and every applicable negative never invariant are recorded with proportional stability regression failure concurrency resource and security analysis; each material forbidden behavior maps to an implementation control and negative test or proof and an unmitigated material risk prevents completion"
  , where_ "implementation_request_produces_source_or_questions" "develop_project_specification" "an explicit implementation request either writes a checked implementation beneath the selected project source directory after both acceptance gates and the security critique or returns focused structured questions for the missing gate or material decision; it never reports successful implementation while the source directory remains empty"
  , where_ "implementation_source_is_an_artifact_not_chat" "develop_project_specification" "implementation source build files generated bindings and implementation tests are persisted as project-confined files beneath source and appear in the Source phase; chat contains only a concise artifact and validation summary and never substitutes pasted source code for those files"
  , where_ "selected_project_context_drives_chat" "develop_project_specification" "every model request receives the selected project's complete editable book plus its canonical requirements and implementation specification in addition to bounded recent conversation; it never substitutes the LeanFM self-hosting book or a previously selected project's state"
  , where_ "phase_navigation_preserves_local_state" "manage_projects" "switching among projects or among Chat Project memory Book Grammar Tasks and Source preserves every mounted project's independent draft selection scroll queue timer preview and fetched state; no project's state appears in another project's view"
  , where_ "book_revision_is_validated_or_rolled_back" "develop_project_specification" "when a substantive chat turn returns a complete revised book the server atomically stages it under the selected project root and rebuilds the project PDF; a failed build restores the exact previous source and runs at most three compile-guided syntax repairs, rolling back after every failed candidate; repair replies never replace the originally requested chat result, and only exhaustion exposes a warning rather than silently retaining invalid source"
  , where_ "book_update_status_is_truthful" "develop_project_specification" "a chat response reports book_updated exactly when that turn committed a complete project-confined book source whose PDF build succeeded; prose about an update, invalid JSON, an oversized revision, a failed build, or a rolled-back repair can never report book_updated"
  , where_ "canvas_source_never_becomes_chat_noise" "argue_requirements" "a requested interactive animation renders inline as an isolated network-disabled canvas with forward backward play pause restart and current-step detail as applicable; a narrowly recognizable provider mistake that spells out the leanfm-canvas marker around exactly one canvas and script is recovered into that sandbox instead of dumping source text, while arbitrary HTML remains escaped text"
  , where_ "book_prefers_reproducible_ui_examples" "develop_project_specification" "when a deterministic UI scenario can demonstrate a workflow more directly than procedural prose the book uses project-owned screenshots captured from the real React DOM at named scenario event boundaries, preserves prompt event-prefix viewport theme browser-version reducer and artifact-digest provenance plus meaningful alt text, and retains only the surrounding explanation needed to interpret the example"
  , where_ "conversation_advances_the_two_gates" "develop_project_specification" "each assistant turn either records a durable decision updates a derived view asks a blocking ambiguity question reports validation or advances the explicit requirements or implementation acceptance gate"
  , where_ "book_grows_with_durable_decisions" "develop_project_specification" "accepted or provisionally retained design reasoning updates editable book source and regenerates book/main.pdf and book/main-dark.pdf under the project root with links to the requirement implementation and evidence revisions it explains"
  , where_ "acceptance_names_exact_revisions" "develop_project_specification" "SpecificationRequirementsAccepted and SpecificationImplementationAccepted name the exact validated revisions; later changes invalidate the affected acceptance instead of silently inheriting it"
  , where_ "chat_is_project_scoped" "argue_requirements" "every turn belongs to exactly one authorized project conversation"
  , where_ "model_key_is_request_scoped" "argue_requirements" "ModelRequestIssued resolves exactly the credential_ref authorized for that turn's authenticated user and never reads or mutates a process-global API key"
  , where_ "model_selection_is_request_scoped" "argue_requirements" "the Chat composer lists only server-configured model IDs; Send Resend and structured answers capture the visible selection into that queued ChatPromptSubmitted, ModelRequestIssued uses exactly that model, and the assistant response durably displays the model that incurred usage"
  , where_ "composer_commits_before_model_selection" "argue_requirements" "in Chat composer keyboard and visual order the enabled Send button immediately follows the prompt editor and precedes the model selector, so Tab then Enter from a typed prompt submits it using the already visible model without opening or changing model selection"
  , where_ "unconfigured_models_are_rejected" "argue_requirements" "a model ID absent from the server allowlist is rejected before conversation persistence provider billing or workspace mutation"
  , where_ "cursor_subscription_uses_agent_protocol" "argue_requirements" "a Cursor subscription is used through an authenticated Cursor Agent client and project MCP or through an isolated Cursor ACP session; LeanFM never requests stores or treats Cursor login state as a reusable model-provider API key"
  , where_ "concurrent_keys_do_not_collide" "argue_requirements" "concurrent turns with different credential_ref values cannot share credentials responses accounting retries cancellation or provider-client mutable state"
  , where_ "keyless_server_has_no_provider_spend" "argue_requirements" "without a user-owned credential_ref and without an explicitly configured platform credential no ModelRequestIssued occurs"
  , where_ "usage_is_visible_per_turn" "argue_requirements" "each successful provider turn renders input cached-input output and context-window token counts beside that response"
  , where_ "active_billing_identity_is_persistent" "argue_requirements" "throughout authenticated project use a persistent non-secret status identifies the provider model credential reference and one-way key fingerprint that will be billed; it never exposes the raw key and it cannot ambiguously say only your API key"
  , where_ "local_token_budget_is_visible_and_enforced" "argue_requirements" "the page continuously shows provider-reported cumulative tokens used and tokens remaining in the finite local login-session safety budget; requests stop when that budget is exhausted; the display explicitly distinguishes this token budget from provider dollar credits and directs the user to enforce the authoritative provider-project spend cap"
  , where_ "response_time_is_visible_per_turn" "argue_requirements" "while a turn runs the composer shows one incrementing elapsed timer without a synthetic assistant message; after completion the measured response_time_ms is durably displayed on that exact assistant response"
  , where_ "long_running_turn_status_is_truthful" "argue_requirements" "a project-wide active-turn indicator remains visible from every phase and always shows its captured model timer cancellation control and the latest real project-scoped stage transition among model wait allowlisted tool validation book compile and bounded book repair; the authenticated client polls every two seconds, preserves the last successful status across transient read failures, and falls back only to explicitly time-based still-working copy rather than fabricating provider progress; real intermediate project file changes remain visible through the polling Project memory and Source lists and the user may navigate any project or phase without waiting in Chat"
  , where_ "book_compile_failure_is_reported_while_repair_runs" "develop_project_specification" "when a proposed book does not compile the active-turn status exposes the first bounded compiler diagnostic before requesting repair; it then identifies each of at most three repair and rebuild attempts, uses the model selected for that chat turn, gives each repair request a short bounded deadline, and restores the exact last valid book unless a candidate builds successfully"
  , where_ "recoverable_failures_are_fixed_before_return" "argue_requirements" "when an authorized reversible workspace operation fails the agent inspects the concrete diagnostic, changes strategy, exhausts safe local alternatives, validates the repaired artifact, and continues the original requested task without asking the user to retry; repeated identical candidates or diagnostics stop immediately, and only a failure requiring new authority destructive choice or unavailable dependency returns an actionable error"
  , where_ "equivalent_project_paths_do_not_false_escape" "argue_requirements" "a workspace tool accepts a project-relative path or its canonical absolute equivalent when and only when canonicalization remains beneath the selected project root; relative server configuration cannot cause an authorized absolute path to be rejected as an escape"
  , where_ "book_worker_uses_canonical_project_identity" "develop_project_specification" "book worker confinement and explicitly test-only worker selection use the canonical selected-project book path, so an equivalent relative data-root configuration neither changes the worker policy nor produces a false pre-compiler failure"
  , where_ "book_repair_cost_is_strictly_bounded" "develop_project_specification" "automatic book repair sends only the compiler diagnostic and a numbered nine-line source excerpt, requests one replacement line with at most 2000 output tokens, rejects edits to another line, and stops on an unchanged candidate; it never sends the complete book for each repair attempt"
  , where_ "provider_deadline_is_visible_and_nonduplicating" "argue_requirements" "a provider request has a bounded configurable deadline whose default permits long tool-assisted turns; timeout is reported explicitly with elapsed time and completed tool-step count, and LeanFM never automatically retries a timed-out paid request because the provider may still have consumed tokens or applied an earlier tool mutation"
  , where_ "every_chat_message_has_a_visible_timestamp" "argue_requirements" "every persisted user and assistant message records its own server-observed wall-clock send time and renders that instant visibly in the browser's local timezone; the exact UTC instant remains inspectable, optimistic pending messages show their client-observed submission time, and legacy records without a stored instant are labeled unavailable rather than assigned a fabricated time"
  , where_ "prompts_stack_in_project_order" "argue_requirements" "while one turn is active the composer remains enabled and Send Resend and structured answers append to a visible removable per-project FIFO; each queued prompt begins only after its predecessor completes or fails so it observes all preceding conversation and workspace mutations, and the live timer measures only the active prompt"
  , where_ "active_turn_is_cooperatively_cancellable" "argue_requirements" "while Agent running is visible the user can request cancellation exactly once; the active provider or tool boundary observes that project-scoped request before starting another tool or provider step, queued prompts remain blocked until cancellation terminates visibly, and durable edits completed before cancellation remain truthful project state"
  , where_ "intermediate_project_lists_retry" "argue_requirements" "while a project agent turn runs the Project memory and Source file lists periodically refresh; a transient read failure preserves the last successful list and retries without requiring tab navigation or waiting for the final response"
  , where_ "operational_trace_is_live" "argue_requirements" "each completed started failed or rejected allowlisted workspace action is appended to a bounded authenticated project-scoped Operational trace before the agent starts its next step; before a write is validated the trace names its normalized project-relative destination content kind and character count, and a rejection repeats that destination; the trace is inspectable from every phase while Agent running remains active, highlights a latest failure in the collapsed summary, preserves its last successful value across transient poll failures, and lets the user cancel after observing evidence without waiting for the terminal assistant message"
  , where_ "diagnostic_memory_survives_chat_loss" "argue_requirements" "each project retains a bounded private diagnostic journal beneath its root containing sanitized stage transitions, tool destinations, compiler diagnostics, terminal failures, and correlation details; every later agent turn receives recent unresolved entries before choosing a recovery strategy, so navigation restart or discarded conversation cannot cause the same known SVG LaTeX path or tool failure to be rediscovered through paid retries and the user need not copy diagnostics back into chat"
  , where_ "every_project_error_is_durably_diagnosable" "argue_requirements" "before any project-scoped HTTP error tool rejection compiler failure provider failure failed required artifact or warning result is returned or displayed, LeanFM appends a bounded sanitized diagnostic with operation path status category and concrete cause beneath that project root so LeanFM and Codex can inspect fix and continue without asking the user to reproduce or paste the error"
  , where_ "browser_errors_reach_project_diagnostics" "argue_requirements" "every uncaught JavaScript exception unhandled promise rejection failed browser API operation and caught renderer failure posts its operation description error type message sanitized stack page time and active project identity to an authenticated server endpoint which appends it beneath the authorized project root before normal browser error handling continues"
  , where_ "resolved_diagnostics_are_compacted" "argue_requirements" "a successful write or book build removes superseded matching failure entries from private diagnostic memory and records one compact resolution, while unrelated unresolved evidence remains available to later agent turns"
  , where_ "every_visible_error_is_actionable" "argue_requirements" "every server browser transport validation provider and unexpected HTTP failure shown to the user includes a plain-language description, a concrete next action, a stable error code, and an immediately copyable bounded diagnostic labeled safe to paste to Codex; an unknown proxy status such as 527 is never reduced to Something went wrong, while diagnostics omit prompts credentials and cross-project content"
  , where_ "new_messages_reveal_conversation_bottom" "argue_requirements" "when the conversation initially loads or a new user assistant or failure message is rendered the chat scrolls its own message pane to the bottom so the newest turn and composer remain visible"
  , where_ "diagram_is_task_local" "inspect_task_model" "each interaction diagram and state machine names exactly one task and requirements revision"
  , where_ "linked_views_share_task" "inspect_task_model" "interaction state-machine message-sequence and constraint links share task_id and requirements_revision"
  , where_ "protobuf_events_follow_task_grammar" "inspect_task_model" "the ordered EventEnvelope payloads are accepted by the selected task grammar"
  , where_ "protobuf_secrets_are_redacted" "inspect_task_model" "redacted_json and rendered views contain no login credential or provider API key"
  , where_ "research_uses_public_http" "research_web" "search and page-open sources use only public http or https URLs and never local private link-local loopback file or metadata addresses"
  , where_ "research_citations_are_clickable" "research_web" "each cited web claim retains a URL_CITATION part with http or https URL title and visible clickable anchor"
  , where_ "research_is_user_funded" "research_web" "web search and page-open tool calls use the authenticated user's selected credential and expose their token and tool usage"
  , where_ "markerboard_assist_targets_revision" "assist_markerboard" "syntax help and AI proposals name the exact artifact_id base_revision diagram_kind source and instruction they answer"
  , where_ "markerboard_ai_never_silently_overwrites" "assist_markerboard" "provider output remains a proposal until MarkerboardPatchAccepted and a changed base revision makes acceptance fail rather than overwrite"
  , where_ "markerboard_syntax_help_is_local" "assist_markerboard" "syntax-reference mode changes no draft and issues no billable provider request"
  , where_ "markerboard_ai_usage_is_visible" "assist_markerboard" "AI detail mode uses the authenticated user's credential and displays its input and output token usage with the proposal"
  , where_ "canvas_animation_can_be_frozen_for_stakeholders" "markerboard" "an interactive canvas animation used during requirements argument can be promoted at an exact revision into a portable animated GIF with a stable figure label prompt provenance task or scenario binding frame timing and loop boundary so a stakeholder can share and later identify the behavior they approved without LeanFM or executable JavaScript"
  , where_ "requested_mp4_is_a_real_inline_artifact" "markerboard" "when a remote stakeholder asks for MP4 the completed response contains an actual validated project-owned MP4 served inline by authenticated chat; WebM GIF canvas HTML conversion instructions helper scripts and server-local file paths are not substitutes for the requested artifact"
  , where_ "chat_context_is_bounded_and_excludes_traces" "argue_requirements" "each provider request includes only the eight most recent conversation turns, truncates each contextual turn to 3500 characters, and excludes prior operational traces; durable project artifacts remain available through workspace tools, while the full conversation remains visible and deletable in the browser"
  , where_ "third_party_commands_cross_one_whitelist" "argue_requirements" "every third-party executable started for a workspace-agent operation is selected by one repository-owned Bash dispatcher with named fixed operations bounded arguments explicit timeouts sanitized dynamic-library environment captured stdout stderr and exit status; arbitrary model-supplied shell text is never executed"
  , where_ "missing_requested_artifact_is_not_success" "argue_requirements" "an explicit MP4 request deterministically selects the most recently referenced project GIF or WebM and invokes the MP4 transcoder even when the model does not; ffmpeg runs without inherited Lean or Elan LD_LIBRARY_PATH and LD_PRELOAD values; the turn cannot display SUCCESS unless it generated and validated an actual MP4, while no source failure to start ffmpeg or a nonzero ffmpeg diagnostic is shown verbatim as FAIL instead of continuing an interrogation loop"
  , where_ "large_media_supports_http_ranges" "markerboard" "authenticated project MP4 WebM PDF GIF PNG and JPEG responses advertise byte ranges; a valid single closed open-ended or suffix Range returns exactly 206 with Content-Range and the requested bytes, an unsatisfiable or multi-range request returns 416 with the complete representation length, and authorization plus project-root confinement is identical for full and partial responses"
  , where_ "chat_rendering_uses_available_width" "markerboard" "the chat response workspace uses nearly all horizontal space remaining beside project navigation, up to a generous large-screen bound, so interaction diagrams state machines images video canvas animations traces and question forms are not confined to a narrow prose column; compact user message bubbles remain visually distinct"
  , where_ "logic_and_mathematics_render_as_latex" "argue_requirements" "when symbolic notation makes logic mathematics probability or temporal logic clearer, assistant responses use explicit inline or display LaTeX delimiters and the browser renders them as accessible mathematics; fenced code remains literal and invalid formulas remain visibly recoverable rather than disappearing"
  , where_ "tool_dependencies_are_complete_and_scoped" "develop_project_specification" "the durable toolDependencyInventory and dependency chapter enumerate every executable language package compiler generator and document or media tool invoked by a checked repository workflow, distinguish default requirements from optional workflows, state version contracts and purposes, and require every accepted implementation target to add its compiler SDK generator runtime and system-library dependencies before source generation"
  , where_ "dependency_reconciliation_is_actionable" "develop_project_specification" "an agent can compare the declared inventory with executable and package versions on the current host, report satisfied missing incompatible and optional items by workflow, and offer explicit bounded installation or upgrade commands without silently mutating the host or treating an optional target dependency as globally required"
  , where_ "all_queues_are_finite_and_blocking" "inspect_task_model" "every actor instance has declared positive inbound and outbound capacities; sending to a full queue sleeps without mutation until capacity is available; blocking receive from an empty queue sleeps until a message exists"
  , where_ "closed_queues_drain_to_completion" "inspect_task_model" "close is idempotent and forbids every later push; already-buffered messages remain readable in order; blocked senders wake with rejection; receivers report closed only after the buffer is empty; queue iteration terminates exactly at closed and empty"
  , where_ "terminal_events_backpoint_to_start" "inspect_task_model" "each duration or byte-delta measurement names a start event and terminal event in the same session and task; the terminal event prior_ids contains the start event_id; reducers subtract the paired timestamps or encoded byte counts rather than relying on adjacency"
  , where_ "cause_id_is_general_causal_containment" "inspect_task_model" "any root intermediate or terminal event may set cause_id to one existing direct causal event; cause_id is acyclic and separate from prior_ids, may cross a nested task boundary within the same authorized session, and its transitive children define nested boxes in interaction and event views without changing which prior_id interleavings are legal"
  , where_ "parameters_cascade_through_grammar" "inspect_task_model" "each exposed grammar parameter has one typed definition and dependency edges to every affected production queue bound population reducer proof and rendering; changing a parameter invalidates and regenerates all transitive dependents"
  , where_ "http_productions_are_byte_exact" "inspect_task_model" "each production selected for HTTP names its method path request and response protobuf types status mapping content type byte encoder and byte decoder; decoding emitted bytes recovers the same value and illegal bytes or grammar order are visibly rejected"
  , where_ "http_response_backpoints_to_request" "inspect_task_model" "every response event projected into an HTTP response has cause_id equal to the corresponding request event_id within the same session task and correlation boundary; prior_ids remains exclusively the predecessor relation governing legal interleavings and the adapter never substitutes adjacency arrival order or a process-global current request for cause_id"
  , where_ "http_exchange_is_causally_closed" "inspect_task_model" "every event selected for HTTP request projection is the cause_id target of exactly one grammar-permitted terminal HTTP response event and every event selected for HTTP response projection points to exactly one compatible request event; orphan requests dangling responses cross-session causes duplicate terminal responses and missing error responses are validation failures rather than unchecked calls"
  , where_ "default_http_projection_is_deterministic" "inspect_task_model" "when implementation does not override an HTTP binding the generator pairs request and response atoms from the task grammar, uses the protobuf JSON mapping with application/json as the default body encoder, publishes the resolved contract at GET /openapi.yaml, uses URL parameters only for explicitly bounded URL-safe scalar selectors, and otherwise uses POST with the encoded protobuf request in the body; bytes repeated nested secret or unbounded fields never become URL parameters"
     , where_ "grammar_canvas_is_progressively_disclosed" "inspect_task_model" "the complete grammar is rendered as one navigable canvas whose task and production nodes can be opened or closed without changing the underlying typed grammar or hiding validation failures"
     , where_ "grammar_canvas_is_literal_ast" "inspect_task_model" "the Grammar page starts at one named LeanFM production whose alternatives reference every task or scenario production and recursively renders the accepted GrammarExpr constructors empty event sequence choice parallel threshold join guard nonterminal reference and repetition without reconstructing grammar structure from flattened state transitions"
     , where_ "grammar_canvas_actors_are_edge_derived" "inspect_task_model" "each expanded scenario shows exactly the distinct source and destination actors of that scenario's message productions; there is no global actor roster and actors from other scenarios or with no interaction in the scenario are omitted"
     , where_ "task_page_selects_behavioral_views" "inspect_task_model" "the Tasks page is the default authenticated project view and presents tasks as one flat selection list beside a larger stage; Productions renders the task-local interaction diagram, States renders the residual state machine, Properties renders each requirement property as an explicit CTL formula, and where_ renders each context-sensitive requirement predicate under its explicit CTL invariant operator, independently of navigation in the nested Grammar page"
     , where_ "property_origin_is_explicit" "inspect_task_model" "every displayed CTL formula identifies whether it originates in Requirements.lean as an observable property or where_ constraint; Implementation.lean supplies traced controls and mappings and never silently becomes the source of an observable requirement property" ]

def taskStates (task : TaskRequirement) : List String := task.states.map (fun s => s.id)

def process (actor : String) (task : TaskRequirement) (sends receives : List String) : RequirementProcess :=
  { actor, task := task.id, states := taskStates task, sends, receives }

def processes : List RequirementProcess :=
  [ process "UserBrowser" authenticationTask ["LoginSubmitted"] ["LoginAccepted", "LoginRejected"]
  , process "LeanFMServer" authenticationTask ["LoginAccepted", "LoginRejected"] ["LoginSubmitted"]
  , process "UserBrowser" accountCreationTask ["AccountCreateSubmitted"] ["AccountCreated", "AccountCreateRejected"]
  , process "LeanFMServer" accountCreationTask ["ProviderKeyCheckRequested", "AccountCreated", "AccountCreateRejected"] ["AccountCreateSubmitted", "ProviderKeyVerified", "ProviderKeyRejected"]
  , process "ModelProvider" accountCreationTask ["ProviderKeyVerified", "ProviderKeyRejected"] ["ProviderKeyCheckRequested"]
  , process "UserBrowser" projectTask ["ProjectListRequested", "ProjectCreateRequested", "ProjectOpenRequested", "ProjectDeleteRequested"] ["ProjectListReturned", "ProjectCreated", "ProjectOpened", "ProjectDeleted"]
  , process "LeanFMServer" projectTask ["ProjectListReturned", "ProjectCreated", "ProjectOpened", "ProjectDeleted"] ["ProjectListRequested", "ProjectCreateRequested", "ProjectOpenRequested", "ProjectDeleteRequested"]
  , process "UserBrowser" specificationConversationTask ["ProblemStatementSubmitted", "ClarificationSubmitted", "SpecificationRequirementsAccepted", "SpecificationImplementationAccepted"] ["ProblemInquiryPresented", "AmbiguityQuestionPresented", "ProjectBookRevised", "RequirementsReviewPresented", "ImplementationReviewPresented", "ImplementationAuthorizationConfirmed"]
  , process "LeanFMServer" specificationConversationTask ["ProblemInquiryPresented", "AmbiguityQuestionPresented", "ProjectBookRevised", "RequirementsReviewPresented", "ImplementationReviewPresented", "ImplementationAuthorizationConfirmed"] ["ProblemStatementSubmitted", "ClarificationSubmitted", "SpecificationRequirementsAccepted", "SpecificationImplementationAccepted"]
  , process "UserBrowser" credentialTask ["ProviderCredentialSubmitted"] ["ProviderCredentialAccepted", "ProviderCredentialRejected"]
  , process "LeanFMServer" credentialTask ["ProviderCredentialAccepted", "ProviderCredentialRejected"] ["ProviderCredentialSubmitted"]
  , process "UserBrowser" chatTask ["ChatPromptSubmitted"] ["ChatResponseRendered", "ChatTurnFailed"]
  , process "LeanFMServer" chatTask ["ModelRequestIssued", "ChatResponseRendered", "ChatTurnFailed"] ["ChatPromptSubmitted", "ModelResponseReturned"]
  , process "ModelProvider" chatTask ["ModelResponseReturned"] ["ModelRequestIssued"]
  , process "UserBrowser" markerboardTask ["MermaidDraftSaved", "MediaUploaded", "ArtifactPromoted"] ["MermaidPreviewRendered", "MediaRendered", "CandidateRequirementUpdated"]
  , process "LeanFMServer" markerboardTask ["MermaidPreviewRendered", "MediaRendered", "CandidateRequirementUpdated"] ["MermaidDraftSaved", "MediaUploaded", "ArtifactPromoted"]
  , process "UserBrowser" artifactsTask ["ArtifactListRequested", "ArtifactOpenRequested"] ["ArtifactListReturned", "ArtifactOpened"]
  , process "LeanFMServer" artifactsTask ["ArtifactListReturned", "ArtifactOpened"] ["ArtifactListRequested", "ArtifactOpenRequested"]
  , process "UserBrowser" inspectTaskModelTask ["TaskModelRequested", "MessageSequenceRequested", "ProtobufObjectRequested"] ["TaskModelReturned", "MessageSequenceReturned", "ProtobufObjectReturned"]
  , process "LeanFMServer" inspectTaskModelTask ["TaskModelReturned", "MessageSequenceReturned", "ProtobufObjectReturned"] ["TaskModelRequested", "MessageSequenceRequested", "ProtobufObjectRequested"]
  , process "UserBrowser" webResearchTask ["WebResearchRequested"] ["WebResearchReturned", "WebResearchFailed"]
  , process "LeanFMServer" webResearchTask ["WebResearchDispatched", "WebResearchReturned", "WebResearchFailed"] ["WebResearchRequested", "WebSearchPerformed", "WebPageOpened"]
  , process "ModelProvider" webResearchTask ["WebSearchPerformed", "WebPageOpened"] ["WebResearchDispatched"] ]
  ++ [ process "UserBrowser" markerboardAssistTask ["MarkerboardAssistRequested", "MarkerboardPatchAccepted", "MarkerboardPatchRejected"] ["MarkerboardSyntaxHelpReturned", "MarkerboardPatchProposed", "MarkerboardDraftUpdated"]
     , process "LeanFMServer" markerboardAssistTask ["MarkerboardSyntaxHelpReturned", "MarkerboardAssistDispatched", "MarkerboardPatchProposed", "MarkerboardDraftUpdated"] ["MarkerboardAssistRequested", "MarkerboardAssistReturned", "MarkerboardPatchAccepted", "MarkerboardPatchRejected"]
     , process "ModelProvider" markerboardAssistTask ["MarkerboardAssistReturned"] ["MarkerboardAssistDispatched"] ]

def taskProperties : List RequirementProperty :=
  [ { name := "Only authenticated users receive project lists", mode := .always, task := "authenticate_user", expression := "LoginAccepted precedes every ProjectListReturned for the session", probability := none }
  , { name := "Self-registration requires a verified user key", mode := .always, task := "create_account", expression := "AccountCreated requires prior ProviderKeyVerified for the API key supplied by the same AccountCreateSubmitted flow", probability := none }
  , { name := "Platform funding cannot authorize registration", mode := .never, task := "create_account", expression := "AccountCreated using the platform API key or without AccountCreateSubmitted.api_key", probability := none }
  , { name := "Project roots contain all project-owned state", mode := .always, task := "manage_projects", expression := "ProjectCreated establishes one exclusive root and ProjectDeleted removes that complete root", probability := none }
  , { name := "Rejected credentials are not retained", mode := .never, task := "configure_provider", expression := "ProviderCredentialRejected followed by a stored credential reference", probability := none }
  , { name := "Retained keys are not plaintext on disk", mode := .always, task := "configure_provider", expression := "each retained provider API key is authenticated ciphertext requiring the owning user password and is referenced externally only by credential_ref", probability := none }
  , { name := "Every submitted chat turn visibly terminates", mode := .eventually, task := "argue_requirements", expression := "ChatPromptSubmitted eventually reaches ChatResponseRendered or ChatTurnFailed", probability := none }
  , { name := "Committed chat book edits are buildable", mode := .always, task := "develop_project_specification", expression := "ProjectBookRevised implies the selected project book source was committed atomically and its PDF build succeeded", probability := none }
  , { name := "Questions and answers are symmetrically multimodal", mode := .always, task := "argue_requirements", expression := "ChatPromptSubmitted and ChatResponseRendered preserve ordered typed content parts including Markdown LaTeX Mermaid DOT image video code file and LeanFM view", probability := none }
  , { name := "No implicit platform billing", mode := .never, task := "argue_requirements", expression := "ModelRequestIssued without an authenticated user-owned credential_ref unless an administrator explicitly configured and enabled bounded platform funding", probability := none }
  , { name := "Token and context usage are visible", mode := .always, task := "argue_requirements", expression := "ChatResponseRendered exposes provider-reported input cached-input and output tokens plus used context and context-window capacity for the same request", probability := none }
  , { name := "Promotion names an exact artifact revision", mode := .always, task := "markerboard", expression := "CandidateRequirementUpdated follows ArtifactPromoted with artifact_id and revision", probability := none }
  , { name := "Artifact status is revision explicit", mode := .always, task := "inspect_artifacts", expression := "ArtifactOpened identifies revision and current accepted superseded or stale status", probability := none } ]
  ++ [ { name := "Feature completion retains its positive invariant", mode := .always, task := "develop_project_specification", expression := "each completed feature names and validates the intended observable behavior plus proportional stability regression and failure boundaries", probability := none }
     , { name := "Features never complete with an unmitigated material risk", mode := .never, task := "develop_project_specification", expression := "a feature is declared complete while an applicable material forbidden behavior lacks an implementation control and negative test or proof obligation", probability := none } ]
  ++ [ { name := "Commit readiness follows security review", mode := .always, task := "develop_project_specification", expression := "each recommendation or action to commit follows a security review of the exact candidate diff and generated artifacts", probability := none }
     , { name := "Material threats block commits", mode := .never, task := "develop_project_specification", expression := "a commit is recommended or performed while a material security finding remains unresolved", probability := none } ]
  ++ taskConstraints.map (fun constraint =>
      { name := constraint.id, mode := .always, task := constraint.task, expression := constraint.predicate, probability := none })

def proofs : List RequiredProof :=
  [ { name := "Authentication gates project access", mode := .always, task := "authenticate_user", predicate := "no project operation is accepted without an authenticated user session", probability := none }
  , { name := "Feature claims are paired with safety claims", mode := .always, task := "develop_project_specification", predicate := "every completed feature has a positive invariant and all applicable forbidden behaviors are represented as negative requirements with controls and negative evidence", probability := none }
  , { name := "No commit without exact-diff security evidence", mode := .never, task := "develop_project_specification", predicate := "commit readiness or commit action without review of the exact candidate diff and generated artifacts, or with an unresolved material threat", probability := none }
  , { name := "No false durable-artifact success", mode := .never, task := "develop_project_specification", predicate := "book_updated without a successfully built committed selected-project book revision, or implementation success while the selected project's source directory is empty", probability := none }
  , { name := "No hidden or unbounded book recovery", mode := .never, task := "develop_project_specification", predicate := "book repair begins before the compile failure is observable, exceeds three model requests, uses a model other than the turn's selected model, waits longer than the configured bounded repair deadline, exposes another project's status, or leaves a noncompiling candidate in place", probability := none }
  , { name := "No cross-project or secret live trace", mode := .never, task := "argue_requirements", predicate := "an unauthenticated or differently authorized user reads a live Operational trace, a trace entry exposes provider credentials or arbitrary provider response bodies, or trace storage grows without its configured entry and text bounds", probability := none }
  , { name := "No unsafe or unbounded private diagnostic memory", mode := .never, task := "argue_requirements", predicate := "private diagnostic memory escapes its project root grows beyond its configured bound crosses project authorization or retains prompts credentials cookies session tokens workspace write contents arbitrary provider bodies or a failure superseded by a verified matching success", probability := none }
  , { name := "Browser diagnostics cannot leak or recurse", mode := .never, task := "argue_requirements", predicate := "a browser diagnostic contains a prompt form body credential cookie response payload URL query or cross-project content, is accepted into an unauthorized project, recursively reports failure of its own reporting request, or exceeds twenty reports per browser minute and the declared field bounds", probability := none }
  , { name := "No mysterious or unsafe error report", mode := .never, task := "argue_requirements", predicate := "a visible error lacks a recommended next action and copyable diagnostic, or a diagnostic includes the submitted prompt API credentials arbitrary provider response bodies or another project's content", probability := none }
  , { name := "No wasteful identical recovery", mode := .never, task := "develop_project_specification", predicate := "automatic recovery resends a complete book, repeats an unchanged candidate or diagnostic, exceeds three line repairs, or continues after a safe deterministic repair has succeeded", probability := none }
  , { name := "No repeated identical failed tool call", mode := .never, task := "argue_requirements", predicate := "the agent executes the same tool name and exact arguments again after that call returned ERROR during the active turn", probability := none }
  , { name := "Model selection does not intercept prompt commit", mode := .never, task := "argue_requirements", predicate := "the first Tab from the Chat prompt editor focuses the model selector or any control other than Send", probability := none }
  , { name := "No account without verified BYOK", mode := .always, task := "create_account", predicate := "each AccountCreated has one same-flow ProviderKeyVerified reached using the prospective user's supplied API key", probability := none }
  , { name := "Rejected signup keys create no account", mode := .never, task := "create_account", predicate := "ProviderKeyRejected followed by AccountCreated for the registration", probability := none }
  , { name := "Deleting a project requires no hunt", mode := .always, task := "manage_projects", predicate := "deleting the exclusive project root deletes all project-owned inputs conversations artifacts specifications source tests generated views traces reports logs and caches", probability := none }
  , { name := "Provider secrets never become project artifacts", mode := .never, task := "configure_provider", predicate := "API key appears in project files chat history logs traces errors generated artifacts or source", probability := none }
  , { name := "Credential ciphertext requires password login", mode := .always, task := "configure_provider", predicate := "wrong passwords, tampering, account swaps and persisted bearer files cannot unlock or authorize use of retained keys", probability := none }
  , { name := "Chat context is durable", mode := .always, task := "argue_requirements", predicate := "the rendered response is linked to the project conversation revision and referenced artifact revisions", probability := none }
  , { name := "Multimodal round trip", mode := .always, task := "argue_requirements", predicate := "ordered question and answer content parts retain kind text artifact revision media type inline bytes and accessible alternative text across persistence and rendering", probability := none }
  , { name := "Scratch diagrams do not masquerade as evidence", mode := .always, task := "markerboard", predicate := "a manually edited Mermaid or media artifact remains scratch or candidate until explicit promotion and derived evidence retains specification provenance", probability := none }
  , { name := "Latest and accepted artifacts are distinguishable", mode := .always, task := "inspect_artifacts", predicate := "the artifact tab labels current candidate accepted superseded and stale revisions without relying on chat scrollback", probability := none } ]
  ++ [ { name := "There is no global task diagram", mode := .never, task := "inspect_task_model", predicate := "one interaction diagram or one state machine combines transitions from different task_id values", probability := none }
     , { name := "Linked task views agree", mode := .always, task := "inspect_task_model", predicate := "the interaction diagram state machine constraint list message sequence and protobuf object viewer retain one task_id and requirements_revision", probability := none }
     , { name := "Concurrent BYOK isolation", mode := .always, task := "argue_requirements", predicate := "two simultaneous authenticated sessions using different credential_ref values issue provider requests with only their own secret and receive only their own response and accounting", probability := none } ]
  ++ [ { name := "Keyless launch cannot spend provider funds", mode := .never, task := "argue_requirements", predicate := "a server launched without a platform API key issues a model-provider request that is not authorized by the authenticated user's own verified key", probability := none }
     , { name := "Usage belongs to its response", mode := .always, task := "argue_requirements", predicate := "displayed token and context usage comes from the same request_id as the rendered assistant response and is never borrowed from another concurrent turn", probability := none }
     , { name := "Research citations remain visible and clickable", mode := .always, task := "research_web", predicate := "every URL citation returned by the provider is visibly rendered as an http or https anchor associated with the same research response", probability := none }
     , { name := "Research cannot reach server-local networks", mode := .never, task := "research_web", predicate := "a research request causes LeanFM to fetch file localhost loopback RFC1918 link-local or cloud metadata URLs", probability := none } ]
  ++ [ { name := "AI assistance requires review", mode := .never, task := "assist_markerboard", predicate := "MarkerboardAssistReturned changes saved markerboard source without a same-base-revision MarkerboardPatchAccepted", probability := none }
     , { name := "Stale markerboard patches cannot overwrite", mode := .never, task := "assist_markerboard", predicate := "MarkerboardDraftUpdated when the current artifact revision differs from MarkerboardPatchAccepted.base_revision", probability := none }
     , { name := "Full queues make no progress", mode := .always, task := "inspect_task_model", predicate := "a send to an actor queue at its declared capacity sleeps without enqueueing dropping reordering duplicating or mutating the message until a receive creates space", probability := none }
     , { name := "Closed queues are finite streams", mode := .always, task := "inspect_task_model", predicate := "after close no push succeeds; every value accepted before close remains drainable exactly once in order; iteration ends exactly when closed and empty", probability := none }
     , { name := "Measured deltas use explicit pairs", mode := .always, task := "inspect_task_model", predicate := "every elapsed-time or byte-delta result follows a terminal prior_id to its declared start event and subtracts like units inside one correlation boundary", probability := none }
     , { name := "Causal containment is independent of event order", mode := .always, task := "inspect_task_model", predicate := "cause_id forms an acyclic direct-cause forest over root intermediate and terminal events whose nested rendering boundaries do not add remove or infer prior_id interleavings", probability := none }
     , { name := "HTTP responses retain their request identity", mode := .always, task := "inspect_task_model", predicate := "HTTP projection is a causally closed one-request one-terminal-response relation: each response cause_id names its exact request and each request is named by one compatible response while prior_ids independently constrains interleavings", probability := none }
     , { name := "HTTP codecs round trip", mode := .always, task := "inspect_task_model", predicate := "for every HTTP-bound production decode(encode(value)) equals value and the decoded protobuf atom is admitted by the selected residual grammar", probability := none } ]

def outputs : List DesiredOutput :=
  [ { id := "chatui.auth.interaction", prompt := "Provide valid user logins.", question := "How does a login become an authenticated session or a visible rejection?", kind := .interactionDiagram, eventSource := "authenticate_user events", reducer := "render the selected LoginAccepted or LoginRejected grammar branch", unit := "events" }
  , { id := "chatui.auth.state", prompt := "Provide valid user logins.", question := "Which authentication states are observable?", kind := .stateMachine, eventSource := "authenticate_user grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.signup.interaction", prompt := "Users should be able to create their own account if they supply their own API key.", question := "Did the provider verify the prospective user's key before account creation?", kind := .interactionDiagram, eventSource := "create_account events", reducer := "render registration, provider verification, and the selected created or rejected branch while redacting credentials", unit := "events" }
  , { id := "chatui.signup.state", prompt := "Users should be able to create their own account if they supply their own API key.", question := "Which registration and provider-verification states are observable?", kind := .stateMachine, eventSource := "create_account grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.projects.interaction", prompt := "Show a list of projects and keep every project in one deletable directory.", question := "How does the user list, create, open, or confirm deletion of a project?", kind := .interactionDiagram, eventSource := "manage_projects events", reducer := "render the selected project-operation branch", unit := "events" }
  , { id := "chatui.projects.state", prompt := "Show a list of projects and keep every project in one deletable directory.", question := "Which project lifecycle states are observable?", kind := .stateMachine, eventSource := "manage_projects grammar", reducer := "render grammar residuals for list create open and confirmed delete", unit := "states and transitions" }
  , { id := "chatui.specification-conversation.interaction", prompt := "A fresh LeanFM session should begin by asking what problem the user is trying to solve, resolve ambiguities, and remain focused on accepted requirements and implementation.", question := "How does a project directory become an inquiry, clarified requirements, two accepted revisions, and authorization for implementation?", kind := .interactionDiagram, eventSource := "develop_project_specification events", reducer := "render problem inquiry, repeated named clarification loop, book revisions, and both acceptance gates", unit := "events and artifact revisions" }
  , { id := "chatui.specification-conversation.state", prompt := "A totally fresh prompt should need only the project directory as input.", question := "Which discovery or acceptance state is the project conversation in?", kind := .stateMachine, eventSource := "develop_project_specification grammar", reducer := "render the residual grammar with the current named ambiguity and exact artifact revisions", unit := "states, ambiguities, and revisions" }
  , { id := "chatui.provider.interaction", prompt := "Let a user bring an API key and bound use of the platform key.", question := "How is a provider credential accepted or visibly rejected without exposing the raw secret?", kind := .interactionDiagram, eventSource := "configure_provider events", reducer := "render the selected credential result branch while redacting api_key", unit := "events" }
  , { id := "chatui.provider.state", prompt := "Let a user bring an API key and bound use of the platform key.", question := "Which provider-credential states are observable?", kind := .stateMachine, eventSource := "configure_provider grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.chat.interaction", prompt := "Move this requirements argument from Codex into LeanFM chat, including image and diagram questions and answers.", question := "How does one durable multipart question reach a model and return ordered inline content parts?", kind := .interactionDiagram, eventSource := "argue_requirements events and ChatContentPart values", reducer := "render browser server and provider lifelines with content-part kinds and the visible failure alternative", unit := "events and content parts" }
  , { id := "chatui.chat.state", prompt := "Make LeanFM chat comfortable enough for permanent project use.", question := "Which state is the current chat turn in?", kind := .stateMachine, eventSource := "argue_requirements grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.markerboard.interaction", prompt := "Type simple Mermaid while markerboarding requirements.", question := "How does a scratch diagram or media attachment become a candidate requirement?", kind := .interactionDiagram, eventSource := "markerboard events", reducer := "render save preview promote and candidate-update events for the selected artifact revision", unit := "events" }
  , { id := "chatui.markerboard.state", prompt := "Type simple Mermaid while markerboarding requirements.", question := "Which scratch, preview, promotion, and candidate states are observable?", kind := .stateMachine, eventSource := "markerboard grammar", reducer := "render grammar residuals without conflating scratch and derived evidence", unit := "states and transitions" }
  , { id := "chatui.artifacts.interaction", prompt := "Add a tab or link showing current diagrams and generated artifacts in an organized view.", question := "How does the user filter, list, and open one exact artifact revision?", kind := .interactionDiagram, eventSource := "inspect_artifacts events", reducer := "render filtered list and optional exact-revision open messages", unit := "events" }
  , { id := "chatui.artifacts.state", prompt := "Add a tab showing the current generated artifacts.", question := "Can the user distinguish current accepted superseded and stale revisions without scrolling chat?", kind := .stateMachine, eventSource := "inspect_artifacts grammar and artifact metadata", reducer := "render artifact-list and artifact-open residuals labeled by revision status", unit := "artifact revisions" } ]
  ++ [ { id := "chatui.task-model.interaction", prompt := "Each task has its own interaction diagram linked to its own state machine and message sequence.", question := "How does a user traverse one task's linked views and inspect its protobuf objects?", kind := .interactionDiagram, eventSource := "inspect_task_model EventEnvelope values with prior_ids and cause_id", reducer := "render the selected task and revision through task view message sequence and protobuf object inspection; recursively enclose cause_id descendants in nested boxes while deriving message interleavings only from prior_ids", unit := "events and causal nesting depth" }
     , { id := "chatui.task-model.state", prompt := "There is not one shared state machine or interaction diagram.", question := "Which task-model inspection state is visible?", kind := .stateMachine, eventSource := "inspect_task_model grammar", reducer := "render grammar residuals for one task and requirements revision", unit := "states and transitions" } ]
  ++ [ { id := "chatui.usage.tokens", prompt := "Expose token usage on the page so the user can avoid a billing surprise.", question := "How many provider-reported tokens did this completed turn consume?", kind := .scalar, eventSource := "ModelResponseReturned joined to ChatResponseRendered by request_id", reducer := "show input_tokens cached_input_tokens output_tokens and their sum for exactly one completed turn", unit := "tokens per turn" }
     , { id := "chatui.usage.context", prompt := "Expose context usage on the page so the user can be warned.", question := "How much of the selected model's context window did this request occupy?", kind := .scalar, eventSource := "ModelResponseReturned joined to the selected model metadata by request_id", reducer := "show input plus output tokens over context_window_tokens beside the response with a BYOK billing notice", unit := "tokens and percent of context window per turn" } ]
  ++ [ { id := "chatui.response-time", prompt := "Keep the animated clock while a request runs and leave the time to respond on the response.", question := "How long did this exact completed chat turn take?", kind := .scalar, eventSource := "ChatPromptSubmitted paired with ChatResponseRendered in one request", reducer := "subtract the server monotonic start from the completed response time and retain the result on that assistant message", unit := "milliseconds per turn" } ]
  ++ [ { id := "chatui.research.interaction", prompt := "Follow HTTP URLs and do research through web searches.", question := "How does a research question become searches, opened pages, and a cited answer?", kind := .interactionDiagram, eventSource := "research_web events and provider web_search_call actions", reducer := "render the selected successful or failed research trace with search and page-open actions", unit := "events and cited URLs" }
     , { id := "chatui.research.state", prompt := "Follow HTTP URLs and do research through web searches.", question := "Which web-research residual state is visible?", kind := .stateMachine, eventSource := "research_web grammar", reducer := "render grammar residuals for the selected research request", unit := "states and transitions" } ]
  ++ [ { id := "chatui.markerboard-assist.interaction", prompt := "Provide AI assistance on the markerboard for syntax recall and tedious detail.", question := "How does local syntax help or a reviewed AI patch affect one exact markerboard revision?", kind := .interactionDiagram, eventSource := "assist_markerboard events", reducer := "render the selected syntax-help or AI propose-and-accept/reject trace", unit := "events and artifact revisions" }
     , { id := "chatui.markerboard-assist.state", prompt := "Provide AI assistance on the markerboard for syntax recall and tedious detail.", question := "Which assistance, proposal-review, and draft-update state is visible?", kind := .stateMachine, eventSource := "assist_markerboard grammar", reducer := "render grammar residuals for one artifact base revision", unit := "states and transitions" } ]
  ++ [ { id := "chatui.web-protocol.adapter", prompt := "Fully document the LeanFM web-server protocol in LeanFM grammar and explain protobuf-to-HTTP conversion.", question := "Where does an HTTP exchange enter the typed message grammar and become a journaled protobuf event?", kind := .interactionDiagram, eventSource := "ChatUI task grammars, MessageSchema values, EventEnvelope cause_id values, implementation HTTP bindings, and running server routes", reducer := "project HTTP request decoding, typed grammar transition, EventEnvelope append, causal nested boxes for intermediate work, and terminal response projection by following cause_id back to the request", unit := "messages and causal nesting depth per HTTP exchange" } ]
  ++ [ { id := "chatui.grammar.canvas", prompt := "Show the whole grammar as a canvas that can open and close productions and cascade changed parameters.", question := "What is the complete grammar, which details are currently expanded, and what changes when a parameter is edited?", kind := .interactionDiagram, eventSource := "RequirementSpec grammars, task references, parameter definitions, dependency edges, queue contracts, codecs, proofs, and generated outputs", reducer := "render the complete grammar hierarchy; collapse closed nodes to typed summaries; expand selected nodes to productions and byte bindings; highlight every transitive dependent of edited parameters", unit := "grammar productions and dependency edges" }
     , { id := "chatui.measurement.pairs", prompt := "Use event id, priorId, and calculated differences to elide detail in a principled way.", question := "Which explicit start/terminal pairs justify each displayed duration and byte delta?", kind := .function2d, eventSource := "EventEnvelope values whose terminal prior_ids name their start event_id", reducer := "join terminal events to declared starts by prior_id within session and task; subtract timestamps or encoded byte counts; group by selected grammar production and parameter assignment", unit := "milliseconds or bytes per paired production" } ]

def spec : RequirementSpec :=
  { id := "leanfm.chatui"
  , title := "Project-scoped multimodal LeanFM requirements chat"
  , actors := ["UserBrowser", "LeanFMServer", "ModelProvider"]
  , actorPopulations :=
      [ { actorSpec := "UserBrowser", instancePrefix := "browser-", count := 8, routing := .sticky "session_id" }
      , { actorSpec := "LeanFMServer", instancePrefix := "server-", count := 1, routing := .sticky "project_id" }
      , { actorSpec := "ModelProvider", instancePrefix := "provider-", count := 2, routing := .sticky "credential_ref" } ]
  , actorResources :=
      [ { actor := "UserBrowser", inboundCapacity := 32, outboundCapacity := 32, maxInFlight := 4, memoryBudgetBytes := 67108864 }
      , { actor := "LeanFMServer", inboundCapacity := 256, outboundCapacity := 256, maxInFlight := 32, memoryBudgetBytes := 536870912 }
      , { actor := "ModelProvider", inboundCapacity := 64, outboundCapacity := 64, maxInFlight := 16, memoryBudgetBytes := 268435456 } ]
  , actorReliability :=
      [ { actor := "UserBrowser", outageProbability := { numerator := 0, denominator := 1 }, meanTimeToRepairMs := 0 }
      , { actor := "LeanFMServer", outageProbability := { numerator := 0, denominator := 1 }, meanTimeToRepairMs := 0 }
      , { actor := "ModelProvider", outageProbability := { numerator := 0, denominator := 1 }, meanTimeToRepairMs := 0 } ]
  , reliabilityGates := []
  , actorCosts := []
  , messages
  , tasks := [authenticationTask, accountCreationTask, projectTask, specificationConversationTask, credentialTask, chatTask, markerboardTask, artifactsTask, inspectTaskModelTask, webResearchTask, markerboardAssistTask]
  , grammars := [authenticationGrammar, accountCreationGrammar, projectGrammar, specificationConversationGrammar, credentialGrammar, chatGrammar, markerboardGrammar, artifactsGrammar, inspectTaskModelGrammar, webResearchGrammar, markerboardAssistGrammar]
  , processes
  , properties := taskProperties
  , requiredProofs := proofs
  , performance := []
  , charts := []
  , desiredOutputs := outputs
  , markdown :=
      [ { id := "dark_mode", title := "Dark mode is an accessibility requirement", body := "Every server and client view is dark before scripts load, including login, projects, chat, markerboard, Mermaid, artifacts, errors, media surroundings, reports, and empty states. Generated views never flash a white background." }
      , { id := "root_workbench", title := "The authenticated web UI is the complete project engineering environment", body := "GET http://localhost:8080/ is the primary interface. A signed-out visitor sees login and BYOK account creation. After opening a project conversation, an ordinary user completes engineering work without a separate coding UI. Chat is one contextual conversation: the model infers whether each turn revises the working book, develops candidate observable requirements, resolves implementation mappings, or requests implementation work. The user never selects a conversational mode before speaking. Candidate edits remain reversible, while requirements and implementation acceptance remain separate explicit user gates. The Book workspace edits source and previews regenerated light and dark PDFs with derived diagrams. Authenticated chat may inspect, search, create, and replace text files only beneath the selected project's canonical root; it rejects absolute paths, traversal, and symlink escapes, records a visible operational trace, and runs only named bounded checks. Every model turn receives that project's complete editable book and canonical specifications in addition to bounded recent conversation. A returned complete book revision is committed only after its project PDF builds; a failed revision is restored and cannot set book_updated. The first-class Grammar page follows the checked specification directly. It starts at the named LeanFM production, resolves to named task and scenario productions, and recursively renders the literal accepted GrammarExpr structure used for forward parsing. Tasks remains a separate flat task browser with large derived behavioral views." }
      , { id := "nested_tab_hierarchy", title := "Navigation mirrors software phases", body := "The persistent left vertical tab set selects exactly one project. The selected project's horizontal phase navigator is Early: Chat then Book; Intermediate: Grammar and Tasks; Late: Source. Chat is the default earliest phase because conversation grows the initial book sketch before formal requirements exist. Tasks contains its own left vertical task tab set and a horizontal derived-view tab set for interaction productions, states, properties, and guards. Selection styling, keyboard semantics, headings, and empty states make each containment boundary explicit while the selected phase retains the large work surface." }
      , { id := "guided_phase_progression", title := "Conversation advances by evidence and explicit gates", body := "A new project defaults to guided chat and begins with an informal description that immediately revises the simple project book. The model does not front-load an exhaustive questionnaire. As actors, scenarios, messages, outcomes, failures, and requested measurements become identifiable, it asks only the remaining focused questions needed to propose observable requirements and their derived views. It requests explicit requirements acceptance and never supplies that acceptance itself. Near implementation, and only after requirements acceptance, it asks unresolved implementation questions such as language, process and deployment model, HTTP or another transport, persistence, concurrency, reliability, and tests, then requests separate implementation-specification acceptance before source changes." }
      , { id := "self_registration", title := "Self-registration is BYOK-only", body := "An unauthenticated visitor may create an account only by supplying a login credential and their own model-provider API key. LeanFM verifies that key with the named provider before creating the account, stores the key as account-owned authenticated ciphertext, and returns only its credential reference. The platform API key cannot satisfy registration." }
      , { id := "project_containment", title := "One project, one directory", body := "Every project-owned input, book snapshot, conversation, artifact revision, specification, source file, test, generated view, trace, report, log, and cache remains below the exclusive project root. A global project index is reconstructible from project manifests." }
      , { id := "widget_project_isolation", title := "A widget cannot display a previous project's state", body := "Selecting a project synchronously invalidates and clears every project-owned widget: conversation, book source and PDF frame, grammar, selected task, diagrams, artifacts, source tree, diffs, logs, and pending status. Every asynchronous browser request and renderer captures the selected project_id and a monotonically increasing selection epoch; its result may mutate the UI only while both still match. Project switches and deletion increment the epoch. No global fallback specification, book, task, figure, or source value may populate an editable project. A late response from LeanFM or another project is discarded rather than appearing in the selected project." }
      , { id := "conversation_bootstrap", title := "The project directory is the complete fresh-session prompt", body := "Starting or resuming an agent conversation requires only the project root. LeanFM reads the manifest, editable and rendered book, canonical requirements and protobuf, canonical implementation mapping, acceptance revisions, source tree, generated views, and evidence from stable paths beneath that root. A new empty project first generates its minimal book shell and asks: What problem are you trying to solve? It then asks focused questions tied to named ambiguities. Durable decisions revise the book as the conversation proceeds. The goal is always validated requirements, explicit requirements acceptance, a separately traceable implementation specification, explicit implementation acceptance, and only then implementation." }
      , { id := "markerboard_modes", title := "Chat is the primary diagram sketch surface", body := "A user may sketch a drawing in ordinary chat as prose, simplified interaction pseudocode, Mermaid, PlantUML, an uploaded image, or a request to research a public image. The model interprets and repairs the sketch into a validated renderable artifact, normally Mermaid for supported behavioral diagrams, while retaining the original prompt and attachments as provenance. Corrected diagrams render inline and become project artifacts. The separate markerboard is an optional precise source editor, not a prerequisite. Promotion creates a candidate interpretation for review; accepted diagrams are regenerated from Requirements.lean, and scratch drawings never silently become evidence." }
      , { id := "artifact_tab", title := "Artifacts are not chat scrollback", body := "A stable Diagrams/Artifacts tab lists server-backed project artifacts grouped and filterable by scenario, diagram kind, media kind, status, and revision. It shows current, accepted, superseded, and stale labels, validation, provenance, author, time, dependencies, history, compare, open, and download actions." }
      , { id := "credentials", title := "User-funded and platform-funded model access", body := "A user may supply a provider key ephemerally or through an account credential reference. A retained key is stored outside project roots in the owning account credential store as authenticated ciphertext requiring the supplied login password. Password verifiers and credential encryption use distinct random salts. Unlocked credentials and bearer sessions exist only in server memory and expire; restart requires password login. Platform-funded access is explicit and bounded. Raw or encoded provider secrets never enter project-owned state, browser responses after submission, chat, logs, traces, errors, or generated artifacts." }
      , { id := "billing_identity", title := "The billed credential and safety boundary stay visible", body := "Every authenticated project header identifies the active provider, selected model, credential reference, and a one-way fingerprint of the exact key used for requests. It continuously shows provider-reported tokens consumed during the unlocked login session and tokens remaining in a finite local safety budget; the server refuses another provider request after exhaustion. The UI states that this is not the provider's dollar credit balance and that an OpenAI project spend cap remains the authoritative monetary limit. Account records, salted password verifiers, encrypted keys, sessions, and private conversations remain local runtime state and never enter checked-in example projects." }
      , { id := "cursor_agent", title := "Cursor subscriptions connect as agents, not provider keys", body := "The immediate integration is Cursor Agent opened at the project root with the committed .cursor/mcp.json pointing to LeanFM's read-only MCP endpoint; Cursor reads AGENTS.md and uses its own authenticated subscription. A browser-hosted integration uses a local Cursor ACP process over stdio, with one isolated ACP session per LeanFM project conversation. Cursor retains authentication and billing responsibility. LeanFM does not collect or persist Cursor login tokens, cannot accept either gate through MCP, and applies the same project, queue, permission, traceability, and acceptance boundaries to ACP-driven edits." }
      , { id := "credential_encryption", title := "Password-derived credential protection", body := "This release must derive a distinct key-encryption key from the user's supplied login password with a salted password KDF, encrypt the provider key with authenticated encryption, and persist only the password verifier plus KDF parameters, salt, nonce, and ciphertext—not the password or derived encryption key. Successful login makes the decryption key available only for the authenticated session. There is no password recovery: resetting a password requires supplying a replacement provider key. Legacy Base64 credentials are encrypted only after successful password verification and then removed; malformed ciphertext never falls back to a legacy key." }
      , { id := "keyless_launch", title := "A keyless server cannot create a billing surprise", body := "LeanFM starts and serves login, account creation, projects, stored conversations, specifications, and artifacts without a platform API key. It issues no provider request unless the authenticated user selected their own verified credential, or an administrator separately and explicitly enabled a bounded platform-funded credential. Missing credentials produce a visible non-billable state." }
      , { id := "usage_display", title := "Token and context usage accompany every model response", body := "Beside each completed assistant response, the page displays provider-reported input, cached-input, output, and total tokens, plus used tokens and percentage of the model context window. The display and warning belong to the same request and credential accounting boundary. Token usage is not labeled as monetary cost unless an identified provider pricing schedule and effective date are also available." }
      , { id := "media", title := "Multimodal requirements argument", body := "Questions and answers are ordered lists of the same typed content parts: Markdown, LaTeX, Mermaid, Graphviz DOT, images, video, canvas animations, code, files, and generated LeanFM views. JPEG, PNG, GIF, and SVG uploads are durable project-local artifacts with stable IDs and revisions. Each attachment may bind to exact task and scenario IDs, so a later phrase such as 'with regard to the getProduct task' resolves the named task together with its bound artifact revisions rather than relying on chat adjacency. The UI preserves and safely renders the original; provider input normalizes unsupported or executable forms, including sanitized SVG rasterization and selected GIF frames. Content is accessible and subject to declared limits." }
      , { id := "figure_backreferences", title := "Media have durable conversational names", body := "Inline Markdown media, uploaded sketches, researched images, model-corrected diagrams, and generated views receive visible project-stable labels such as Figure 1. The label resolves to an exact artifact ID and revision in later turns, after restart, and outside chat scrollback. A request such as 'reduce the states in Figure 1 and add errors when client-to-server communication fails' supplies that exact figure, its provenance, its task/scenario binding, and the named task model to the provider. The model may transform the material into Mermaid, PlantUML, TLA+, LeanFM, prose, or another requested representation; it makes a best effort when intent is identifiable and asks a focused clarification only when alternatives would materially differ." }
      , { id := "task_local_views", title := "Every task owns its behavioral views", body := "There is no single shared interaction diagram or state machine. For every task and requirements revision, LeanFM derives a task-local interaction diagram and residual state machine and links them to the task's constraints and observed message sequences. Selecting an event exposes its protobuf type, safe field view, and encoded object without crossing the project boundary." }
      , { id := "constraint_growth", title := "Requirements grow as tasks and where_ constraints", body := "The requirements conversation adds observable tasks and explicit task-scoped constraints. Durable constraints are represented by Lean `where_` declarations, participate in validation and traceability, and remain linked to the diagrams and protobuf traces they restrict." }
      , { id := "clickable_links", title := "HTTP links are visible and safe to follow", body := "In user and assistant Markdown, absolute http:// and https:// URLs render as visibly clickable anchors. External links open in a new tab with opener access disabled. Other schemes remain inert text. Link labels never conceal a different destination, and rendered citations preserve both source title and full destination URL." }
      , { id := "web_research", title := "Research uses provider-hosted public-web search", body := "When the user asks to research, search, browse, or follow supplied HTTP URLs, LeanFM enables the model provider's web_search tool with live external access. Search, open-page, and find-in-page actions remain part of the project trace. Returned source citations are visible and clickable. LeanFM does not scrape Google result pages or directly fetch arbitrary URLs from the server; provider-hosted retrieval avoids turning the LeanFM host into an SSRF proxy. Research uses the user's credential and may incur provider tool charges, which are disclosed with the response." }
      , { id := "markerboard_ai_assist", title := "Markerboard assistance remembers syntax and proposes tedious detail", body := "The markerboard offers non-billable local syntax help for Mermaid state, sequence, and flow diagrams. AI detail assistance sends the exact diagram kind, source, base revision, and user instruction with the user's credential. The returned source is shown as a diffable proposal with explanation and usage; it never edits the board until explicit acceptance. Acceptance fails visibly if the base revision changed, rejection preserves the original, and acceptance creates a new revision and preview." } ]
      ++ [ { id := "bounded_queues", title := "Every queue has a declared finite capacity", body := "Every actor instance declares positive inbound and outbound queue capacities. A send to a full queue sleeps without mutation until a receive creates space. A blocking receive from an empty queue sleeps until a message exists. Capacity is a typed requirement parameter, not an unbounded implementation default; changing it invalidates dependent resource proofs and views." }
         , { id := "queue_close", title := "Closing turns a queue into a finite drainable stream", body := "Queue close is idempotent. After close, no push is accepted. Blocked senders wake and receive a closed rejection without mutation. Values accepted before close remain readable exactly once in order. A receiver reports closed only after the buffer is drained; iteration is complete exactly when the queue is both closed and empty. Closing an empty queue wakes blocked receivers immediately." }
         , { id := "paired_measurements", title := "Ordering and causal containment are separate event relations", body := "Work is generally observed as a start/terminal pair. The terminal event names the start event_id in prior_ids. Within the same session and task, elapsed time is terminal.time_at minus start.time_at; encoded-byte growth or reduction is the corresponding terminal byte count minus start byte count. Independently, any root, intermediate, or terminal event may set cause_id to its direct cause. The acyclic cause tree lets a renderer place all causal descendants inside nested boxes, including nested tasks, without inventing ordering between concurrent children. Reducers follow identity and backpointers, never adjacency, so intermediate detail may be collapsed without losing the evidence for a displayed result." }
         , { id := "grammar_canvas", title := "The whole grammar is a parameterized canvas", body := "The UI renders the complete typed grammar as one navigable canvas. Tasks and productions may be opened or closed; collapsed nodes preserve identity, validation state, parameters, and aggregate measurements. Editing a typed parameter shows and regenerates every transitive dependent production, queue bound, population, reducer, proof, codec, and view." }
         , { id := "byte_exact_http", title := "HTTP-bound productions are executable byte contracts", body := "A production known to cross HTTP may attach its transport renderer at that production: method, path template, request and response protobuf types, status alternatives, content type, encoder, and decoder. The underlying events remain independently framed and multiplexable: every response event sets cause_id to its request event_id, and every projected request is the cause of exactly one grammar-permitted terminal response, including an error response. The HTTP adapter follows that causal edge to pair the exchange. An orphan request, dangling response, incompatible cause, cross-session cause, or duplicate terminal response is an unchecked HTTP call and fails validation. The adapter never overloads prior_ids, which only constrains legal interleavings, and never assumes adjacency or one global request in flight. Generated fixtures emit exact bytes and read them back. Round-trip equality and residual-grammar acceptance are conformance checks; transport detail does not silently redefine the message value." } ]
      ++ [ { id := "default_http_projection", title := "HTTP has a default encoder and OpenAPI endpoint", body := "The generator pairs request and response message atoms using the task grammar and correlation identity. An explicit Implementation.lean binding wins. Otherwise, request and response bodies use the protobuf JSON mapping with Content-Type application/json, and GET /openapi.yaml returns the OpenAPI description of the resolved operations and schemas. Only explicitly bounded URL-safe scalar selectors may enter path or query parameters. Bytes, repeated fields, nested messages, secrets, large or unbounded strings, and requests whose parameter encoding would be unnatural use POST with the encoded protobuf value in the request body. Response alternatives and status mappings come from the paired grammar branches. Generated codecs must round-trip the protobuf value." } ]
      ++ [ { id := "web_protocol_reference", title := "The web protocol is generated from LeanFM artifacts", body := "Part III is a machine-oriented reference derived from the complete accepted ChatUI grammar, protobuf payload vocabulary, and intended HTTP mappings in Requirements.lean, Requirements.proto, and Implementation.lean. It separately enumerates the routes dispatched by the running adapter, so an intended binding is never presented as an implemented handler." } ] }

def validationReport : String :=
  match validateRequirementSpec spec with
  | [] => "ok: LeanFM ChatUI requirements are well formed\n"
  | errors => "invalid LeanFM ChatUI requirements\n" ++ joinWithNewline errors ++ "\n"

def stateMachineMermaid (task : TaskRequirement) : String :=
  joinWithNewline <| ["stateDiagram-v2", "    [*] --> " ++ task.initialState] ++
    task.transitions.map (fun tr => "    " ++ tr.src ++ " --> " ++ tr.dst ++ ": " ++ tr.message) ++
    task.states.filterMap (fun s => if s.terminal then some ("    " ++ s.id ++ " --> [*]") else none)

def interactionActors (task : TaskRequirement) (messageNames : List String) : List String :=
  task.actors.filter fun actor =>
    messageNames.any fun messageName =>
      match messages.find? (fun msg => msg.name == messageName) with
      | none => false
      | some msg => msg.src == actor || msg.dst == actor

def interactionSpan (actors : List String) : String :=
  match actors with
  | [] => "LeanFM"
  | [actor] => actor
  | first :: rest => first ++ "," ++ rest.getLast!

partial def grammarInteractionLines (span : String) : GrammarExpr -> List String
  | .empty => ["    Note over " ++ span ++ ": ε (empty production)"]
  | .event atom => ["    " ++ atom.src ++ "->>" ++ atom.dst ++ ": " ++ atom.message]
  | .seq left right => grammarInteractionLines span left ++ grammarInteractionLines span right
  | .choice [] => ["    Note over " ++ span ++ ": empty choice"]
  | .choice (first :: rest) =>
      ["    alt choice 1"] ++ grammarInteractionLines span first ++
      (rest.flatMap fun branch =>
        ["    else alternative"] ++ grammarInteractionLines span branch) ++
      ["    end"]
  | .parallel left right =>
      ["    par parallel branch 1"] ++ grammarInteractionLines span left ++
      ["    and parallel branch 2"] ++ grammarInteractionLines span right ++ ["    end"]
  | .thresholdJoin required [] =>
      ["    Note over " ++ span ++ ": invalid empty " ++ toString required ++ "-of-0 join"]
  | .thresholdJoin required (first :: rest) =>
      ["    par threshold branch 1 (continue after " ++ toString required ++ " of " ++ toString (rest.length + 1) ++ ")"] ++
      grammarInteractionLines span first ++
      (rest.flatMap fun branch =>
        ["    and threshold branch"] ++ grammarInteractionLines span branch) ++
      ["    end"]
  | .guard predicate body =>
      ["    opt where_ " ++ predicate] ++ grammarInteractionLines span body ++ ["    end"]
  | .ref production =>
      ["    Note over " ++ span ++ ": production " ++ production]
  | .repeat body =>
      ["    loop repeat"] ++ grammarInteractionLines span body ++ ["    end"]

def interactionMermaid (task : TaskRequirement) : String :=
  let grammar? := spec.grammars.find? (·.task == task.id)
  let messageNames := grammar?.map (fun grammar => (grammarAtoms grammar.body).map (·.message)) |>.getD []
  let actors := interactionActors task messageNames
  joinWithNewline <| ["sequenceDiagram"] ++
    actors.map (fun actor => "    participant " ++ actor) ++
    (grammar?.map (fun grammar => grammarInteractionLines (interactionSpan actors) grammar.body)
      |>.getD ["    Note over " ++ interactionSpan actors ++ ": missing task grammar"])

def interactionTraceMermaid (task : TaskRequirement) (trace : List String) : String :=
  joinWithNewline <| ["sequenceDiagram"] ++
    (interactionActors task trace).map (fun actor => "    participant " ++ actor) ++
    trace.filterMap (fun messageName =>
      if task.transitions.any (fun tr => tr.message == messageName) then
        match messages.find? (fun msg => msg.name == messageName) with
        | none => none
        | some msg => some ("    " ++ msg.src ++ "->>" ++ msg.dst ++ ": " ++ msg.name)
      else none)

def chatStateMachineMermaid : String := stateMachineMermaid chatTask
def chatInteractionMermaid : String := interactionMermaid chatTask
def signupStateMachineMermaid : String := stateMachineMermaid accountCreationTask
def signupAcceptedInteractionMermaid : String := interactionTraceMermaid accountCreationTask
  ["AccountCreateSubmitted", "ProviderKeyCheckRequested", "ProviderKeyVerified", "AccountCreated"]
def signupRejectedInteractionMermaid : String := interactionTraceMermaid accountCreationTask
  ["AccountCreateSubmitted", "ProviderKeyCheckRequested", "ProviderKeyRejected", "AccountCreateRejected"]
def markerboardInteractionMermaid : String := interactionMermaid markerboardTask
def artifactsStateMachineMermaid : String := stateMachineMermaid artifactsTask
def inspectTaskModelInteractionMermaid : String := interactionMermaid inspectTaskModelTask
def inspectTaskModelStateMachineMermaid : String := stateMachineMermaid inspectTaskModelTask
def webResearchInteractionMermaid : String := interactionTraceMermaid webResearchTask
  ["WebResearchRequested", "WebResearchDispatched", "WebSearchPerformed", "WebPageOpened", "WebResearchReturned"]
def webResearchStateMachineMermaid : String := stateMachineMermaid webResearchTask
def markerboardAssistInteractionMermaid : String := interactionTraceMermaid markerboardAssistTask
  ["MarkerboardAssistRequested", "MarkerboardAssistDispatched", "MarkerboardAssistReturned", "MarkerboardPatchProposed", "MarkerboardPatchAccepted", "MarkerboardDraftUpdated"]
def markerboardAssistStateMachineMermaid : String := stateMachineMermaid markerboardAssistTask

def all : List GeneratedRequirement := [.requirement spec]

end LeanFM.ChatUI.Requirements
