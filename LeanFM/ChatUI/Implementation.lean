import LeanFM.ChatUI.Requirements

namespace LeanFM.ChatUI.Implementation

open LeanFM
open LeanFM.ChatUI.Requirements

def justification (id reason : String) : RequirementJustification :=
  { requirementId := id, reason }

def actorBinding (actor : String) : ActorCodegen :=
  match actor with
  | "UserBrowser" =>
      { actor
      , typeName := "ChatUIBrowser"
      , sourceFile := "LeanFM/ChatUI/Web.lean"
      , justifications :=
          [ justification "actor:UserBrowser" "renders the root workbench and emits or consumes the browser-side protobuf messages"
          , justification "output:chatui.task-model.interaction" "presents linked task diagrams, traces, and protobuf object inspection" ] }
  | "LeanFMServer" =>
      { actor
      , typeName := "ChatUIServer"
      , sourceFile := "LeanFM/ChatUI/Server.lean"
      , justifications :=
          [ justification "actor:LeanFMServer" "owns authentication, authorization, project isolation, persistence, reducers, and HTTP dispatch"
          , justification "proof:Concurrent BYOK isolation" "keeps authenticated session, project, request, and credential identities request-local" ] }
  | "ModelProvider" =>
      { actor
      , typeName := "OpenAIProvider"
      , sourceFile := "LeanFM/ChatUI/Provider.lean"
      , justifications :=
          [ justification "actor:ModelProvider" "verifies user credentials and performs model requests through a request-scoped provider adapter"
          , justification "proof:Keyless launch cannot spend provider funds" "has no implicit platform credential fallback" ] }
  | other =>
      { actor := other, typeName := "UnknownActor", sourceFile := "LeanFM/ChatUI/Server.lean"
      , justifications := [justification spec.id "unreachable fallback for exhaustive string mapping"] }

def browserRequestTransport (name : String) : Option (String × String) :=
  match name with
  | "LoginSubmitted" => some ("POST", "/api/login")
  | "AccountCreateSubmitted" => some ("POST", "/api/accounts")
  | "ProjectListRequested" => some ("GET", "/api/projects")
  | "ProjectCreateRequested" => some ("POST", "/api/projects")
  | "ProjectOpenRequested" => some ("GET", "/api/projects/{project_id}")
  | "ProjectDeleteRequested" => some ("DELETE", "/api/projects/{project_id}")
  | "ProviderCredentialSubmitted" => some ("POST", "/api/credentials")
  | "ChatPromptSubmitted" => some ("POST", "/api/projects/{project_id}/conversations/{conversation_id}/messages")
  | "MermaidDraftSaved" => some ("POST", "/api/projects/{project_id}/markerboard/mermaid")
  | "MediaUploaded" => some ("POST", "/api/projects/{project_id}/markerboard/media")
  | "ArtifactPromoted" => some ("POST", "/api/projects/{project_id}/artifacts/{artifact_id}/promotions")
  | "ArtifactListRequested" => some ("GET", "/api/projects/{project_id}/artifacts")
  | "ArtifactOpenRequested" => some ("GET", "/api/projects/{project_id}/artifacts/{artifact_id}/revisions/{revision}")
  | "TaskModelRequested" => some ("GET", "/api/projects/{project_id}/tasks/{task_id}")
  | "MessageSequenceRequested" => some ("GET", "/api/projects/{project_id}/tasks/{task_id}/sessions/{session_id}/events")
  | "ProtobufObjectRequested" => some ("GET", "/api/projects/{project_id}/events/{event_id}")
  | "WebResearchRequested" => some ("POST", "/api/projects/{project_id}/research")
  | "MarkerboardAssistRequested" => some ("POST", "/api/projects/{project_id}/markerboard/assist")
  | "MarkerboardPatchAccepted" => some ("POST", "/api/projects/{project_id}/markerboard/assist/{artifact_id}/accept")
  | "MarkerboardPatchRejected" => some ("POST", "/api/projects/{project_id}/markerboard/assist/{artifact_id}/reject")
  | _ => none

def responseRequest (name : String) : Option String :=
  match name with
  | "LoginAccepted" | "LoginRejected" => some "LoginSubmitted"
  | "AccountCreated" | "AccountCreateRejected" => some "AccountCreateSubmitted"
  | "ProjectListReturned" => some "ProjectListRequested"
  | "ProjectCreated" => some "ProjectCreateRequested"
  | "ProjectOpened" => some "ProjectOpenRequested"
  | "ProjectDeleted" => some "ProjectDeleteRequested"
  | "ProviderCredentialAccepted" | "ProviderCredentialRejected" => some "ProviderCredentialSubmitted"
  | "ChatResponseRendered" | "ChatTurnFailed" => some "ChatPromptSubmitted"
  | "MermaidPreviewRendered" => some "MermaidDraftSaved"
  | "MediaRendered" => some "MediaUploaded"
  | "CandidateRequirementUpdated" => some "ArtifactPromoted"
  | "ArtifactListReturned" => some "ArtifactListRequested"
  | "ArtifactOpened" => some "ArtifactOpenRequested"
  | "TaskModelReturned" => some "TaskModelRequested"
  | "MessageSequenceReturned" => some "MessageSequenceRequested"
  | "ProtobufObjectReturned" => some "ProtobufObjectRequested"
  | "WebResearchReturned" | "WebResearchFailed" => some "WebResearchRequested"
  | "MarkerboardSyntaxHelpReturned" | "MarkerboardPatchProposed" => some "MarkerboardAssistRequested"
  | "MarkerboardDraftUpdated" => some "MarkerboardPatchAccepted"
  | _ => none

def providerChannel (name : String) : Option String :=
  match name with
  | "ProviderKeyCheckRequested" | "ModelRequestIssued" | "WebResearchDispatched" | "MarkerboardAssistDispatched" => some "provider.requests"
  | "ProviderKeyVerified" | "ProviderKeyRejected" | "ModelResponseReturned" | "WebSearchPerformed" | "WebPageOpened" | "MarkerboardAssistReturned" => some "provider.results"
  | _ => none

def messageBinding (schema : MessageSchema) : MessageCodegen :=
  let transport :=
    match browserRequestTransport schema.name with
    | some (method, path) => TransportSpec.httpRequest method path
    | none =>
        match responseRequest schema.name with
        | some request => TransportSpec.httpResponse request
        | none =>
            match providerChannel schema.name with
            | some channel => TransportSpec.inProcessChannel channel
            | none => TransportSpec.custom "unreachable" "all accepted messages must be assigned"
  { message := schema.name
  , wireType := "leanfm.chatui." ++ schema.name
  , transport
  , justifications :=
      [ justification ("message:" ++ schema.name) "preserves this accepted protobuf event payload and its task-grammar ordering" ] }

def implementation : ImplementationSpec :=
  { requirementId := spec.id
  , target := .lean
  , moduleName := "LeanFM.ChatUI"
  , outputDirectory := "."
  , actors := spec.actors.map actorBinding
  , messages := messages.map messageBinding
  , channels :=
      { sendFunction := "BoundedMailbox.send"
      , receiveFunction := "BoundedMailbox.receive"
      , tryReceiveFunction := "BoundedMailbox.tryReceive"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , justifications :=
          [ justification "resource:UserBrowser" "bounds browser-side pending requests and content-part memory"
          , justification "resource:LeanFMServer" "bounds accepted connections, active requests, provider work, and response buffers"
          , justification "resource:ModelProvider" "bounds concurrent provider verification and model requests"
          , justification "proof:Concurrent BYOK isolation" "mail items carry immutable session, user, project, request, and credential references" ] } }

structure ImplementationDecision where
  id : String
  requirementRefs : List String
  files : List String
  decision : String
  conformanceTests : List String
deriving Repr

def decision (id : String) (refs files : List String) (body : String) (tests : List String) : ImplementationDecision :=
  { id, requirementRefs := refs, files, decision := body, conformanceTests := tests }

def decisions : List ImplementationDecision :=
  [ decision "root-chat-workbench"
      [spec.id, "task:authenticate_user", "task:create_account", "task:manage_projects", "task:argue_requirements"]
      ["Server.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Replace the current gallery at GET / with one dark, responsive ChatGPT-like shell. Signed-out mode embeds login and BYOK registration; an authenticated empty account embeds first-project creation; an open project embeds conversation navigation, transcript, fixed multipart composer, usage, Markerboard, and Diagrams/Artifacts. Server.lean becomes a thin executable entry point over ChatUI.Server."
      ["Tests/ChatUIHttp.lean", "scripts/chatui_http_check.sh"]
  , decision "account-session-persistence"
      ["task:authenticate_user", "task:create_account", "property:Self-registration requires a verified user key", "proof:No account without verified BYOK"]
      ["LeanFM/ChatUI/Auth.lean", "LeanFM/ChatUI/Store.lean"]
      "Persist accounts below data/accounts/<user-id>/. Store a PBKDF2-HMAC-SHA256 verifier with a per-user 128-bit random salt and 310000 iterations, never the password; pass password bytes to the crypto adapter over standard input, never argv. Store retained provider keys as standard padded base64 in the owning account credential directory and expose only 128-bit random credential references. Sessions use 256-bit OS-CSPRNG bearer tokens in HttpOnly SameSite=Strict cookies, are persisted below that account, and are resolved independently on each request. The deferred password-derived encryption design is not implemented."
      ["Tests/ChatUIAuth.lean", "Tests/ChatUICredentials.lean"]
  , decision "exclusive-project-root"
      ["task:manage_projects", "property:Project roots contain all project-owned state", "proof:Deleting a project requires no hunt"]
      ["LeanFM/ChatUI/Store.lean"]
      "Create every project below data/accounts/<user-id>/projects/<project-id>/ with a manifest and its book snapshot, conversations, accepted and candidate specs, source, tests, artifacts, rendered views, protobuf events, reports, logs, and cache beneath that root. Resolve and reject traversal and escaping symlinks before every project-owned access. Derive project lists by scanning manifests; confirmed deletion recursively removes only that validated project root."
      ["Tests/ChatUIProjects.lean"]
  , decision "protobuf-event-journal"
      ["task:inspect_task_model", "property:protobuf_events_follow_task_grammar", "proof:Linked task views agree"]
      ["LeanFM/ChatUI/Proto.lean", "LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Views.lean"]
      "Generate a small schema-specific protobuf codec for EventEnvelope and every accepted payload. Append length-delimited objects to the selected project event journal using an atomic temporary-file rename. Preserve event_id, repeated prior_ids, session_id, task_id, time_at_ms, src, dst, and oneof payload. Replay validates each task grammar. The event inspector shows ordered objects and redacted JSON while download returns the selected encoded object."
      ["Tests/ChatUIProtoRoundTrip.lean", "Tests/ChatUITraceReplay.lean"]
  , decision "task-local-derived-views"
      ["output:chatui.task-model.interaction", "output:chatui.task-model.state", "proof:There is no global task diagram", "proof:Linked task views agree"]
      ["LeanFM/ChatUI/Views.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js"]
      "For each (project, requirements revision, task), derive and cache a separate Mermaid interaction diagram and residual state machine from that task grammar and selected trace. Link both to the same task constraints and protobuf message sequence. Never assemble unrelated tasks into a single state machine or interaction diagram."
      ["Tests/ChatUIViews.lean"]
  , decision "multimodal-safe-rendering"
      ["task:argue_requirements", "task:markerboard", "proof:Multimodal round trip", "proof:Scratch diagrams do not masquerade as evidence"]
      ["LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Represent prompt and response bodies as ordered ChatContentPart values. Render Markdown and code as escaped text, LaTeX with a bundled renderer, Mermaid and DOT from source in sandboxed same-origin frames, images and video from project-scoped media routes, and canvas animations in isolated frames. Enforce declared byte limits, MIME allowlists, alternative text, and no executable HTML. Promotion records an exact scratch revision before candidate requirements change."
      ["Tests/ChatUIContent.lean", "Tests/ChatUIMarkerboard.lean"]
  , decision "request-scoped-provider"
      ["property:model_key_is_request_scoped", "property:concurrent_keys_do_not_collide", "proof:Concurrent BYOK isolation", "proof:Keyless launch cannot spend provider funds"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean"]
      "Resolve the authenticated user's credential_ref for each request, decode that account-owned base64 value into request-local memory, and pass it to a bounded provider worker without mutating environment variables or shared client authorization state. Verify an OpenAI credential with authenticated GET /v1/models before retaining it; create turns with POST /v1/responses. Send authorization through the provider process standard input/config channel rather than command arguments; redact subprocess diagnostics. With no selected user credential and no separately enabled platform credential, return a non-billable failure before network I/O."
      ["Tests/ChatUIConcurrentCredentials.lean", "Tests/ChatUIKeyless.lean"]
  , decision "token-context-accounting"
      ["output:chatui.usage.tokens", "output:chatui.usage.context", "property:Token and context usage are visible", "proof:Usage belongs to its response"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js"]
      "Parse usage.input_tokens, usage.input_tokens_details.cached_tokens, usage.output_tokens, and usage.total_tokens from the OpenAI Responses object and join them to the originating request_id. Resolve context-window capacity from the configured selected-model catalog, because the Responses usage object does not supply that capacity. Render per-turn counts, total tokens, used/context percentage, and a BYOK billing notice beside the matching response. Do not display currency cost without a dated price table."
      ["Tests/ChatUIUsage.lean", "Tests/ChatUIConcurrentCredentials.lean"]
  , decision "clickable-links-and-web-research"
      ["task:research_web", "property:research_uses_public_http", "property:research_citations_are_clickable", "proof:Research citations remain visible and clickable", "proof:Research cannot reach server-local networks", "output:chatui.research.interaction", "output:chatui.research.state"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean", "assets/chatui.js", "assets/chatui.css"]
      "Render only absolute http and https URLs as anchors with target=_blank and rel=noopener noreferrer, preserving a visible destination. For explicit research requests, add the hosted Responses API web_search tool with external_web_access enabled and tool_choice auto; provider search, open_page, and find_in_page actions are recorded in the project trace. Parse url_citation annotations into URL_CITATION content parts and render them visibly. Do not implement a general server-side URL fetcher or Google-results scraper, so local, private, link-local, file, and metadata targets are not reachable through LeanFM."
      ["Tests/ChatUILinks.lean", "Tests/ChatUIResearch.lean"]
  , decision "markerboard-ai-assistance"
      ["task:assist_markerboard", "property:markerboard_assist_targets_revision", "property:markerboard_ai_never_silently_overwrites", "property:markerboard_syntax_help_is_local", "property:markerboard_ai_usage_is_visible", "proof:AI assistance requires review", "proof:Stale markerboard patches cannot overwrite", "output:chatui.markerboard-assist.interaction", "output:chatui.markerboard-assist.state"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Add a markerboard assistance control with local syntax-reference mode and user-funded AI detail mode. Local help is bundled and non-billable. AI mode sends diagram kind, exact source, base revision, and instruction through the request-scoped provider adapter; it returns source-only output plus an explanation and usage. Show a side-by-side diff and preview. Accept uses optimistic revision comparison and atomically writes a new revision; reject changes nothing."
      ["Tests/ChatUIMarkerboardAssist.lean", "scripts/chatui_http_check.sh"]
  , decision "bounded-concurrent-server"
      ["resource:LeanFMServer", "resource:ModelProvider", "proof:Authentication gates project access", "proof:Concurrent BYOK isolation"]
      ["LeanFM/ChatUI/Server.lean", "LeanFM/ChatUI/Mailbox.lean"]
      "Accept connections concurrently under the requirement maxInFlight bounds. Each immutable request context contains session, user, project, conversation, request, and credential identities. Per-project mutation uses a project-keyed serial mailbox; unrelated projects and users proceed concurrently. Provider work uses bounded request/result mailboxes. Full queues block without mutation, disconnect cancellation is request-local, and responses cannot be delivered to a different session."
      ["Tests/ChatUIConcurrency.lean", "Tests/ChatUIBounds.lean"]
  , decision "artifact-revisions"
      ["task:inspect_artifacts", "proof:Latest and accepted artifacts are distinguishable"]
      ["LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Views.lean", "LeanFM/ChatUI/Web.lean"]
      "Store immutable artifact revisions beneath the project root with a manifest containing status, provenance, author, timestamp, dependencies, validation, and current/accepted pointers. The artifact tab groups and filters these server-backed manifests; compare, open, and download always name an exact revision."
      ["Tests/ChatUIArtifacts.lean"]
  , decision "traceability-and-build"
      [spec.id]
      ["LeanFM/ChatUI/Traceability.json", "Makefile", "scripts/embed_static_assets.js"]
      "Generate a traceability manifest mapping every accepted requirement reference to source symbols and tests. Embed readable JS/CSS assets at build time, preserve existing non-root diagnostic routes, and add chatui-check to Lean elaboration, protobuf compilation, deterministic trace replay, HTTP bootstrap, concurrency, isolation, traversal, and key-redaction checks."
      ["LeanFM/ChatUI/Validate.lean", "Tests/ChatUITraceability.lean"]
  ]

def validateDecisions : List String :=
  let validRefs := requirementReferenceIds spec
  decisions.foldr (fun item errors =>
    (if item.id == "" then ["implementation decision has empty id"] else []) ++
    (if item.requirementRefs.isEmpty then ["implementation decision has no requirement references: " ++ item.id] else []) ++
    item.requirementRefs.foldr (fun ref more =>
      (if validRefs.contains ref then [] else ["implementation decision references unknown requirement: " ++ item.id ++ " -> " ++ ref]) ++ more) [] ++
    (if item.files.isEmpty then ["implementation decision has no files: " ++ item.id] else []) ++
    (if item.decision == "" then ["implementation decision has no body: " ++ item.id] else []) ++
    (if item.conformanceTests.isEmpty then ["implementation decision has no tests: " ++ item.id] else []) ++ errors) []

def validationReport : String :=
  let core := implementationValidationReport spec implementation
  match validateDecisions with
  | [] => core ++ "ok: ChatUI implementation decisions are traceable\n"
  | errors => core ++ "invalid ChatUI implementation decisions\n" ++ joinWithNewline errors ++ "\n"

end LeanFM.ChatUI.Implementation
