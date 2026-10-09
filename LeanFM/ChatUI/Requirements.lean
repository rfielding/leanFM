import LeanFM.Artifacts

namespace LeanFM.ChatUI.Requirements

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
  , message "ProviderCredentialSubmitted" "UserBrowser" "LeanFMServer" [field 1 "provider" .string, field 2 "api_key" .bytes, field 3 "retention" .string]
  , message "ProviderCredentialAccepted" "LeanFMServer" "UserBrowser" [field 1 "credential_ref" .string, field 2 "billing_source" .string]
  , message "ProviderCredentialRejected" "LeanFMServer" "UserBrowser" [field 1 "reason" .string]
  , message "ChatPromptSubmitted" "UserBrowser" "LeanFMServer" [field 1 "project_id" .string, field 2 "conversation_id" .string, field 3 "message_id" .string, field 4 "parts" .bytes, field 5 "attachment_ids" .string, field 6 "credential_ref" .string]
  , message "ModelRequestIssued" "LeanFMServer" "ModelProvider" [field 1 "project_id" .string, field 2 "conversation_id" .string, field 3 "request_id" .string, field 4 "model" .string, field 5 "research_mode" .string]
  , message "ModelResponseReturned" "ModelProvider" "LeanFMServer" [field 1 "request_id" .string, field 2 "parts" .bytes, field 3 "input_tokens" .uint64, field 4 "cached_input_tokens" .uint64, field 5 "output_tokens" .uint64, field 6 "context_window_tokens" .uint64]
  , message "ChatResponseRendered" "LeanFMServer" "UserBrowser" [field 1 "conversation_id" .string, field 2 "message_id" .string, field 3 "parts" .bytes, field 4 "artifact_ids" .string, field 5 "input_tokens" .uint64, field 6 "cached_input_tokens" .uint64, field 7 "output_tokens" .uint64, field 8 "context_window_tokens" .uint64, field 9 "usage_warning" .string]
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
  , where_ "project_owner_is_session_user" "manage_projects" "every project operation is authorized for the authenticated session user"
  , where_ "chat_is_project_scoped" "argue_requirements" "every turn belongs to exactly one authorized project conversation"
  , where_ "model_key_is_request_scoped" "argue_requirements" "ModelRequestIssued resolves exactly the credential_ref authorized for that turn's authenticated user and never reads or mutates a process-global API key"
  , where_ "concurrent_keys_do_not_collide" "argue_requirements" "concurrent turns with different credential_ref values cannot share credentials responses accounting retries cancellation or provider-client mutable state"
  , where_ "keyless_server_has_no_provider_spend" "argue_requirements" "without a user-owned credential_ref and without an explicitly configured platform credential no ModelRequestIssued occurs"
  , where_ "usage_is_visible_per_turn" "argue_requirements" "each successful provider turn renders input cached-input output and context-window token counts beside that response"
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
  , where_ "markerboard_ai_usage_is_visible" "assist_markerboard" "AI detail mode uses the authenticated user's credential and displays its input and output token usage with the proposal" ]

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
  , { name := "Questions and answers are symmetrically multimodal", mode := .always, task := "argue_requirements", expression := "ChatPromptSubmitted and ChatResponseRendered preserve ordered typed content parts including Markdown LaTeX Mermaid DOT image video code file and LeanFM view", probability := none }
  , { name := "No implicit platform billing", mode := .never, task := "argue_requirements", expression := "ModelRequestIssued without an authenticated user-owned credential_ref unless an administrator explicitly configured and enabled bounded platform funding", probability := none }
  , { name := "Token and context usage are visible", mode := .always, task := "argue_requirements", expression := "ChatResponseRendered exposes provider-reported input cached-input and output tokens plus used context and context-window capacity for the same request", probability := none }
  , { name := "Promotion names an exact artifact revision", mode := .always, task := "markerboard", expression := "CandidateRequirementUpdated follows ArtifactPromoted with artifact_id and revision", probability := none }
  , { name := "Artifact status is revision explicit", mode := .always, task := "inspect_artifacts", expression := "ArtifactOpened identifies revision and current accepted superseded or stale status", probability := none } ]
  ++ taskConstraints.map (fun constraint =>
      { name := constraint.id, mode := .always, task := constraint.task, expression := constraint.predicate, probability := none })

def proofs : List RequiredProof :=
  [ { name := "Authentication gates project access", mode := .always, task := "authenticate_user", predicate := "no project operation is accepted without an authenticated user session", probability := none }
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
     , { name := "Stale markerboard patches cannot overwrite", mode := .never, task := "assist_markerboard", predicate := "MarkerboardDraftUpdated when the current artifact revision differs from MarkerboardPatchAccepted.base_revision", probability := none } ]

def outputs : List DesiredOutput :=
  [ { id := "chatui.auth.interaction", prompt := "Provide valid user logins.", question := "How does a login become an authenticated session or a visible rejection?", kind := .interactionDiagram, eventSource := "authenticate_user events", reducer := "render the selected LoginAccepted or LoginRejected grammar branch", unit := "events" }
  , { id := "chatui.auth.state", prompt := "Provide valid user logins.", question := "Which authentication states are observable?", kind := .stateMachine, eventSource := "authenticate_user grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.signup.interaction", prompt := "Users should be able to create their own account if they supply their own API key.", question := "Did the provider verify the prospective user's key before account creation?", kind := .interactionDiagram, eventSource := "create_account events", reducer := "render registration, provider verification, and the selected created or rejected branch while redacting credentials", unit := "events" }
  , { id := "chatui.signup.state", prompt := "Users should be able to create their own account if they supply their own API key.", question := "Which registration and provider-verification states are observable?", kind := .stateMachine, eventSource := "create_account grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.projects.interaction", prompt := "Show a list of projects and keep every project in one deletable directory.", question := "How does the user list, create, open, or confirm deletion of a project?", kind := .interactionDiagram, eventSource := "manage_projects events", reducer := "render the selected project-operation branch", unit := "events" }
  , { id := "chatui.projects.state", prompt := "Show a list of projects and keep every project in one deletable directory.", question := "Which project lifecycle states are observable?", kind := .stateMachine, eventSource := "manage_projects grammar", reducer := "render grammar residuals for list create open and confirmed delete", unit := "states and transitions" }
  , { id := "chatui.provider.interaction", prompt := "Let a user bring an API key and bound use of the platform key.", question := "How is a provider credential accepted or visibly rejected without exposing the raw secret?", kind := .interactionDiagram, eventSource := "configure_provider events", reducer := "render the selected credential result branch while redacting api_key", unit := "events" }
  , { id := "chatui.provider.state", prompt := "Let a user bring an API key and bound use of the platform key.", question := "Which provider-credential states are observable?", kind := .stateMachine, eventSource := "configure_provider grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.chat.interaction", prompt := "Move this requirements argument from Codex into LeanFM chat, including image and diagram questions and answers.", question := "How does one durable multipart question reach a model and return ordered inline content parts?", kind := .interactionDiagram, eventSource := "argue_requirements events and ChatContentPart values", reducer := "render browser server and provider lifelines with content-part kinds and the visible failure alternative", unit := "events and content parts" }
  , { id := "chatui.chat.state", prompt := "Make LeanFM chat comfortable enough for permanent project use.", question := "Which state is the current chat turn in?", kind := .stateMachine, eventSource := "argue_requirements grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "chatui.markerboard.interaction", prompt := "Type simple Mermaid while markerboarding requirements.", question := "How does a scratch diagram or media attachment become a candidate requirement?", kind := .interactionDiagram, eventSource := "markerboard events", reducer := "render save preview promote and candidate-update events for the selected artifact revision", unit := "events" }
  , { id := "chatui.markerboard.state", prompt := "Type simple Mermaid while markerboarding requirements.", question := "Which scratch, preview, promotion, and candidate states are observable?", kind := .stateMachine, eventSource := "markerboard grammar", reducer := "render grammar residuals without conflating scratch and derived evidence", unit := "states and transitions" }
  , { id := "chatui.artifacts.interaction", prompt := "Add a tab or link showing current diagrams and generated artifacts in an organized view.", question := "How does the user filter, list, and open one exact artifact revision?", kind := .interactionDiagram, eventSource := "inspect_artifacts events", reducer := "render filtered list and optional exact-revision open messages", unit := "events" }
  , { id := "chatui.artifacts.state", prompt := "Add a tab showing the current generated artifacts.", question := "Can the user distinguish current accepted superseded and stale revisions without scrolling chat?", kind := .stateMachine, eventSource := "inspect_artifacts grammar and artifact metadata", reducer := "render artifact-list and artifact-open residuals labeled by revision status", unit := "artifact revisions" } ]
  ++ [ { id := "chatui.task-model.interaction", prompt := "Each task has its own interaction diagram linked to its own state machine and message sequence.", question := "How does a user traverse one task's linked views and inspect its protobuf objects?", kind := .interactionDiagram, eventSource := "inspect_task_model events", reducer := "render the selected task and revision through task view message sequence and protobuf object inspection", unit := "events" }
     , { id := "chatui.task-model.state", prompt := "There is not one shared state machine or interaction diagram.", question := "Which task-model inspection state is visible?", kind := .stateMachine, eventSource := "inspect_task_model grammar", reducer := "render grammar residuals for one task and requirements revision", unit := "states and transitions" } ]
  ++ [ { id := "chatui.usage.tokens", prompt := "Expose token usage on the page so the user can avoid a billing surprise.", question := "How many provider-reported tokens did this completed turn consume?", kind := .scalar, eventSource := "ModelResponseReturned joined to ChatResponseRendered by request_id", reducer := "show input_tokens cached_input_tokens output_tokens and their sum for exactly one completed turn", unit := "tokens per turn" }
     , { id := "chatui.usage.context", prompt := "Expose context usage on the page so the user can be warned.", question := "How much of the selected model's context window did this request occupy?", kind := .scalar, eventSource := "ModelResponseReturned joined to the selected model metadata by request_id", reducer := "show input plus output tokens over context_window_tokens beside the response with a BYOK billing notice", unit := "tokens and percent of context window per turn" } ]
  ++ [ { id := "chatui.research.interaction", prompt := "Follow HTTP URLs and do research through web searches.", question := "How does a research question become searches, opened pages, and a cited answer?", kind := .interactionDiagram, eventSource := "research_web events and provider web_search_call actions", reducer := "render the selected successful or failed research trace with search and page-open actions", unit := "events and cited URLs" }
     , { id := "chatui.research.state", prompt := "Follow HTTP URLs and do research through web searches.", question := "Which web-research residual state is visible?", kind := .stateMachine, eventSource := "research_web grammar", reducer := "render grammar residuals for the selected research request", unit := "states and transitions" } ]
  ++ [ { id := "chatui.markerboard-assist.interaction", prompt := "Provide AI assistance on the markerboard for syntax recall and tedious detail.", question := "How does local syntax help or a reviewed AI patch affect one exact markerboard revision?", kind := .interactionDiagram, eventSource := "assist_markerboard events", reducer := "render the selected syntax-help or AI propose-and-accept/reject trace", unit := "events and artifact revisions" }
     , { id := "chatui.markerboard-assist.state", prompt := "Provide AI assistance on the markerboard for syntax recall and tedious detail.", question := "Which assistance, proposal-review, and draft-update state is visible?", kind := .stateMachine, eventSource := "assist_markerboard grammar", reducer := "render grammar residuals for one artifact base revision", unit := "states and transitions" } ]

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
  , tasks := [authenticationTask, accountCreationTask, projectTask, credentialTask, chatTask, markerboardTask, artifactsTask, inspectTaskModelTask, webResearchTask, markerboardAssistTask]
  , grammars := [authenticationGrammar, accountCreationGrammar, projectGrammar, credentialGrammar, chatGrammar, markerboardGrammar, artifactsGrammar, inspectTaskModelGrammar, webResearchGrammar, markerboardAssistGrammar]
  , processes
  , properties := taskProperties
  , requiredProofs := proofs
  , performance := []
  , charts := []
  , desiredOutputs := outputs
  , markdown :=
      [ { id := "dark_mode", title := "Dark mode is an accessibility requirement", body := "Every server and client view is dark before scripts load, including login, projects, chat, markerboard, Mermaid, artifacts, errors, media surroundings, reports, and empty states. Generated views never flash a white background." }
      , { id := "root_workbench", title := "The root page is the entire ChatGPT-like product surface", body := "GET http://localhost:8080/ is the primary interface. A signed-out visitor sees login and BYOK account creation. A newly registered user with no projects can create the first project. Once a project is open, the surface is intentionally indistinguishable from the familiar ChatGPT conversation layout except for first-class task-linked LeanFM views: project and conversation navigation at the side, conversation in the main pane, a fixed multimodal composer, and direct Diagrams/Artifacts access. The user never lands on an implementation example gallery." }
      , { id := "self_registration", title := "Self-registration is BYOK-only", body := "An unauthenticated visitor may create an account only by supplying a login credential and their own model-provider API key. LeanFM verifies that key with the named provider before creating the account, stores the key as account-owned authenticated ciphertext, and returns only its credential reference. The platform API key cannot satisfy registration." }
      , { id := "project_containment", title := "One project, one directory", body := "Every project-owned input, book snapshot, conversation, artifact revision, specification, source file, test, generated view, trace, report, log, and cache remains below the exclusive project root. A global project index is reconstructible from project manifests." }
      , { id := "markerboard_modes", title := "Think and verify", body := "Scratch Mermaid supports stateDiagram-v2, sequenceDiagram, and flowchart with immediate dark preview. Promotion creates a candidate interpretation for review. Accepted diagrams are regenerated from Requirements.lean and retain provenance; scratch drawings never silently become evidence." }
      , { id := "artifact_tab", title := "Artifacts are not chat scrollback", body := "A stable Diagrams/Artifacts tab lists server-backed project artifacts grouped and filterable by scenario, diagram kind, media kind, status, and revision. It shows current, accepted, superseded, and stale labels, validation, provenance, author, time, dependencies, history, compare, open, and download actions." }
      , { id := "credentials", title := "User-funded and platform-funded model access", body := "A user may supply a provider key ephemerally or through an account credential reference. A retained key is stored outside project roots in the owning account credential store as authenticated ciphertext requiring the supplied login password. Password verifiers and credential encryption use distinct random salts. Unlocked credentials and bearer sessions exist only in server memory and expire; restart requires password login. Platform-funded access is explicit and bounded. Raw or encoded provider secrets never enter project-owned state, browser responses after submission, chat, logs, traces, errors, or generated artifacts." }
      , { id := "credential_encryption", title := "Password-derived credential protection", body := "This release must derive a distinct key-encryption key from the user's supplied login password with a salted password KDF, encrypt the provider key with authenticated encryption, and persist only the password verifier plus KDF parameters, salt, nonce, and ciphertext—not the password or derived encryption key. Successful login makes the decryption key available only for the authenticated session. There is no password recovery: resetting a password requires supplying a replacement provider key. Legacy Base64 credentials are encrypted only after successful password verification and then removed; malformed ciphertext never falls back to a legacy key." }
      , { id := "keyless_launch", title := "A keyless server cannot create a billing surprise", body := "LeanFM starts and serves login, account creation, projects, stored conversations, specifications, and artifacts without a platform API key. It issues no provider request unless the authenticated user selected their own verified credential, or an administrator separately and explicitly enabled a bounded platform-funded credential. Missing credentials produce a visible non-billable state." }
      , { id := "usage_display", title := "Token and context usage accompany every model response", body := "Beside each completed assistant response, the page displays provider-reported input, cached-input, output, and total tokens, plus used tokens and percentage of the model context window. The display and warning belong to the same request and credential accounting boundary. Token usage is not labeled as monetary cost unless an identified provider pricing schedule and effective date are also available." }
      , { id := "media", title := "Multimodal requirements argument", body := "Questions and answers are ordered lists of the same typed content parts: Markdown, LaTeX, Mermaid, Graphviz DOT, images, video, canvas animations, code, files, and generated LeanFM views. A question may contain images or diagram source; an answer may render images or diagrams inline. Content is project-scoped, revisioned, safely rendered, accessible, and subject to declared limits." }
      , { id := "task_local_views", title := "Every task owns its behavioral views", body := "There is no single shared interaction diagram or state machine. For every task and requirements revision, LeanFM derives a task-local interaction diagram and residual state machine and links them to the task's constraints and observed message sequences. Selecting an event exposes its protobuf type, safe field view, and encoded object without crossing the project boundary." }
      , { id := "constraint_growth", title := "Requirements grow as tasks and where_ constraints", body := "The requirements conversation adds observable tasks and explicit task-scoped constraints. Durable constraints are represented by Lean `where_` declarations, participate in validation and traceability, and remain linked to the diagrams and protobuf traces they restrict." }
      , { id := "clickable_links", title := "HTTP links are visible and safe to follow", body := "In user and assistant Markdown, absolute http:// and https:// URLs render as visibly clickable anchors. External links open in a new tab with opener access disabled. Other schemes remain inert text. Link labels never conceal a different destination, and rendered citations preserve both source title and full destination URL." }
      , { id := "web_research", title := "Research uses provider-hosted public-web search", body := "When the user asks to research, search, browse, or follow supplied HTTP URLs, LeanFM enables the model provider's web_search tool with live external access. Search, open-page, and find-in-page actions remain part of the project trace. Returned source citations are visible and clickable. LeanFM does not scrape Google result pages or directly fetch arbitrary URLs from the server; provider-hosted retrieval avoids turning the LeanFM host into an SSRF proxy. Research uses the user's credential and may incur provider tool charges, which are disclosed with the response." }
      , { id := "markerboard_ai_assist", title := "Markerboard assistance remembers syntax and proposes tedious detail", body := "The markerboard offers non-billable local syntax help for Mermaid state, sequence, and flow diagrams. AI detail assistance sends the exact diagram kind, source, base revision, and user instruction with the user's credential. The returned source is shown as a diffable proposal with explanation and usage; it never edits the board until explicit acceptance. Acceptance fails visibly if the base revision changed, rejection preserves the original, and acceptance creates a new revision and preview." } ] }

def validationReport : String :=
  match validateRequirementSpec spec with
  | [] => "ok: LeanFM ChatUI requirements are well formed\n"
  | errors => "invalid LeanFM ChatUI requirements\n" ++ joinWithNewline errors ++ "\n"

def stateMachineMermaid (task : TaskRequirement) : String :=
  joinWithNewline <| ["stateDiagram-v2", "    [*] --> " ++ task.initialState] ++
    task.transitions.map (fun tr => "    " ++ tr.src ++ " --> " ++ tr.dst ++ ": " ++ tr.message) ++
    task.states.filterMap (fun s => if s.terminal then some ("    " ++ s.id ++ " --> [*]") else none)

def interactionMermaid (task : TaskRequirement) : String :=
  joinWithNewline <| ["sequenceDiagram"] ++
    task.actors.map (fun actor => "    participant " ++ actor) ++
    task.transitions.filterMap (fun tr =>
      match messages.find? (fun msg => msg.name == tr.message) with
      | none => none
      | some msg => some ("    " ++ msg.src ++ "->>" ++ msg.dst ++ ": " ++ msg.name))

def interactionTraceMermaid (task : TaskRequirement) (trace : List String) : String :=
  joinWithNewline <| ["sequenceDiagram"] ++
    task.actors.map (fun actor => "    participant " ++ actor) ++
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
