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
  | "ProblemStatementSubmitted" => some ("POST", "/api/projects/{project_id}/specification/problem")
  | "ClarificationSubmitted" => some ("POST", "/api/projects/{project_id}/specification/ambiguities/{ambiguity_id}")
  | "SpecificationRequirementsAccepted" => some ("POST", "/api/projects/{project_id}/specification/requirements/{requirements_revision}/accept")
  | "SpecificationImplementationAccepted" => some ("POST", "/api/projects/{project_id}/specification/implementation/{implementation_revision}/accept")
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
  | "ProblemInquiryPresented" => some "ProjectOpenRequested"
  | "AmbiguityQuestionPresented" | "RequirementsReviewPresented" => some "ProblemStatementSubmitted"
  | "ProjectBookRevised" => some "ClarificationSubmitted"
  | "ImplementationReviewPresented" => some "SpecificationRequirementsAccepted"
  | "ImplementationAuthorizationConfirmed" => some "SpecificationImplementationAccepted"
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
      , closeFunction := "BoundedMailbox.close"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
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
      "Replace the current gallery at GET / with one dark, responsive project engineering environment that does not require Codex for ordinary work. Signed-out mode embeds login and BYOK registration; an authenticated empty account embeds first-project creation. Navigation mirrors software phases: a persistent left vertical project tab set owns a horizontal Early/Chat-then-Book, Intermediate/Grammar-or-Tasks, and Late/Source phase navigator, with Chat selected by default. Guided chat loads a bounded context of the eight newest conversation turns, at most 3500 characters each and without prior operational traces; full durable state remains available through project workspace reads and the complete conversation remains a UI record. It cannot cross either explicit acceptance gate. Structured answers retain stable question IDs and selected option values. The client closes answered IDs, while the agent must produce a material result after an answer and use reversible defaults after at most one clarification turn; acceptance gates and destructive or expensive irreversible choices remain explicit. Keep the composer enabled during provider work and append Send Resend and structured answers to a visible removable project-scoped FIFO. Execute exactly one prompt at a time in order, continuing after a failure, so every later prompt receives all earlier conversation and workspace mutations; reset the live timer for each dequeued prompt. Its Responses API agent loop offers bounded list, read, literal-search, atomic full-file write, and named-check tools rooted at the canonical directory from which the server process was launched. Each relative path is lexically checked and real-path checked against that root; writes resolve an existing parent and reject symlink escapes. The browser receives a concise answer plus the ordered operational trace. Tasks owns a left vertical task tab set and horizontal interaction, state, property, and guard view tabs. Book builds light and dark PDFs in a filesystem-isolated worker. Grammar serializes the accepted GrammarExpr AST without flattening. Server.lean remains a thin executable entry point over ChatUI.Server."
      ["Tests/ChatUIHttp.lean", "scripts/chatui_http_check.sh"]
  , decision "account-session-persistence"
      ["task:authenticate_user", "task:create_account", "property:Self-registration requires a verified user key", "proof:No account without verified BYOK"]
      ["LeanFM/ChatUI/Auth.lean", "LeanFM/ChatUI/Store.lean"]
      "Persist accounts below data/accounts/<user-id>/. Store a PBKDF2-HMAC-SHA256 verifier with a per-user 128-bit random salt and 310000 iterations, never the password; pass password bytes to the crypto adapter over standard input, never argv. Store provider keys with AES-256-GCM in credentials/default.json, using PBKDF2-HMAC-SHA256 with a distinct random 128-bit salt, 310000 iterations, a fresh 96-bit nonce, and versioned username-bound associated data. Authenticate the password before decrypting or migrating legacy default.b64; atomically write ciphertext before removing legacy storage. Persist no encryption key or session bearer. Sessions use 256-bit OS-CSPRNG tokens in HttpOnly SameSite=Strict cookies; an in-memory session holds its owning user key for at most eight hours, with at most 256 sessions. Restart invalidates all sessions. Password recovery is unavailable; a reset must replace the provider key. Exclude all data/ state from Git."
      ["Tests/ChatUIAuth.lean", "Tests/ChatUICredentials.lean"]
  , decision "exclusive-project-root"
      ["task:manage_projects", "property:Project roots contain all project-owned state", "proof:Deleting a project requires no hunt"]
      ["LeanFM/ChatUI/Store.lean"]
      "Create every project below data/accounts/<user-id>/projects/<project-id>/ with a manifest and its book snapshot, conversations, accepted and candidate specs, source, tests, artifacts, rendered views, protobuf events, reports, logs, and cache beneath that root. Resolve and reject traversal and escaping symlinks before every project-owned access. Derive project lists by scanning manifests; confirmed deletion recursively removes only that validated project root."
      ["Tests/ChatUIProjects.lean"]
  , decision "project-keyed-react-workspace"
      ["task:manage_projects", "proof:Deleting a project requires no hunt"]
      ["ui/src/App.tsx", "ui/src/projects/ProjectWorkspace.tsx", "ui/src/api/projectQueries.ts", "LeanFM/ChatUI/Server.lean"]
      "Replace the growing imperative DOM client with a typed React workspace while retaining the Lean server and project-root API. Key the complete ProjectWorkspace component by authenticated user ID plus project_id so a switch unmounts the previous conversation, book frame, grammar, tasks, artifacts, and source widgets. Key every query/cache entry by the same identity and cancel outstanding project queries on unmount. Components receive project identity explicitly rather than reading a mutable global. Until that migration lands, the legacy client enforces the same boundary with a monotonically increasing selection epoch and synchronous widget clearing. Server routes continue to require authenticated user plus explicit project_id and never fall back to self-hosting content."
      ["ui/src/projects/ProjectWorkspace.test.tsx", "Tests/ChatUIProjects.lean", "scripts/chatui_http_check.sh"]
  , decision "protobuf-event-journal"
      ["task:inspect_task_model", "property:protobuf_events_follow_task_grammar", "property:cause_id_is_general_causal_containment", "proof:Causal containment is independent of event order", "proof:Linked task views agree"]
      ["LeanFM/ChatUI/Proto.lean", "LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Views.lean"]
      "Generate a small schema-specific protobuf codec for EventEnvelope and every accepted payload. Append length-delimited objects to the selected project event journal using an atomic temporary-file rename. Preserve event_id, repeated prior_ids, optional cause_id, session_id, task_id, time_at_ms, src, dst, and oneof payload. prior_ids governs predecessor order and legal interleavings; cause_id independently identifies the direct causal event for roots, intermediate events, and terminals. Validate causal existence and acyclicity, derive the reverse child index, and expose causal subtrees to renderers as nested interaction boxes without adding order edges. Replay validates each task grammar. The event inspector shows ordered objects and redacted JSON while download returns the selected encoded object."
      ["Tests/ChatUIProtoRoundTrip.lean", "Tests/ChatUITraceReplay.lean"]
  , decision "task-local-derived-views"
      ["output:chatui.task-model.interaction", "output:chatui.task-model.state", "proof:There is no global task diagram", "proof:Linked task views agree"]
      ["LeanFM/ChatUI/Views.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js"]
      "For each (project, requirements revision, task), derive and cache a separate Mermaid interaction diagram and residual state machine from that task grammar and selected trace. Link both to the same task constraints and protobuf message sequence. Never assemble unrelated tasks into a single state machine or interaction diagram."
      ["Tests/ChatUIViews.lean"]
  , decision "multimodal-safe-rendering"
      ["task:argue_requirements", "task:markerboard", "proof:Multimodal round trip", "proof:Scratch diagrams do not masquerade as evidence"]
      ["LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Represent prompt and response bodies as ordered ChatContentPart values. Render Markdown and code as escaped text, LaTeX with a bundled renderer, Mermaid and DOT from source in sandboxed same-origin frames, images and video from project-scoped media routes, and canvas animations in isolated frames. Give assistant responses and embedded visual artifacts a responsive workspace up to 1600 CSS pixels wide while retaining compact right-aligned user bubbles. Store JPEG, PNG, GIF, and SVG originals beneath the project root with immutable artifact IDs and revisions plus optional task/scenario bindings. A stakeholder may promote an exact interactive canvas revision into a project-local animated GIF or MP4 that freezes frame timing loop boundaries prompt provenance task/scenario binding; serve it inline so it remains shareable without LeanFM or JavaScript. The bounded workspace_transcode_mp4 tool accepts only project-local GIF or WebM input, invokes ffmpeg with H.264 high profile yuv420p even dimensions and fast-start metadata, validates the ISO base media signature and a 512 MB bound, and returns the project-relative MP4 path for inline rendering. For an explicit MP4 prompt, server postprocessing invokes that tool itself if the model did not, choosing the newest conversation reference that matches a project GIF or WebM and falling back to an available project animation. The response is FAIL unless that turn's trace contains a successfully generated MP4; prose alternatives and follow-up questions can never be labeled SUCCESS, and missing-source process-start or ffmpeg failures expose their actual diagnostic. Authenticated MP4 WebM PDF GIF PNG and JPEG routes implement RFC single byte ranges with Accept-Ranges bytes, 206 Content-Range for closed open-ended and suffix requests, and 416 Content-Range for malformed unsatisfiable or multi-range requests; range handling occurs only after the same authorization and canonical project-root checks as full responses. Allocate monotonically increasing visible Figure N labels from project state and map each label to an exact artifact revision; resolve explicit figure references into provider context even after the originating turn leaves the conversation window. Never infer MIME from a filename alone. Sanitize SVG for display and rasterize it for model vision; retain an animated GIF as the source artifact while sending explicitly selected representative frames to providers that do not accept animation. Resolve named-task discussion to the task model and its bound artifact revisions, and transmit supported images as Responses API input_image content parts. Enforce declared byte and pixel limits, MIME allowlists, alternative text, and no executable HTML. Promotion records an exact scratch revision before candidate requirements change."
      ["Tests/ChatUIContent.lean", "Tests/ChatUIMarkerboard.lean"]
  , decision "request-scoped-provider"
      ["property:model_key_is_request_scoped", "property:concurrent_keys_do_not_collide", "proof:Concurrent BYOK isolation", "proof:Keyless launch cannot spend provider funds"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean"]
      "Resolve the authenticated user's credential_ref for each request, resolve that password-unlocked account-owned key from the authenticated in-memory session into request-local memory, and pass it to a bounded provider worker without mutating environment variables or shared client authorization state. Verify an OpenAI credential with authenticated GET /v1/models before retaining it; create turns with POST /v1/responses. Send authorization through the provider process standard input/config channel rather than command arguments; redact subprocess diagnostics. With no selected user credential and no separately enabled platform credential, return a non-billable failure before network I/O."
      ["Tests/ChatUIConcurrentCredentials.lean", "Tests/ChatUIKeyless.lean"]
  , decision "token-context-accounting"
      ["output:chatui.usage.tokens", "output:chatui.usage.context", "property:Token and context usage are visible", "proof:Usage belongs to its response"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js"]
      "Parse usage.input_tokens, usage.input_tokens_details.cached_tokens, usage.output_tokens, and usage.total_tokens from the OpenAI Responses object and join them to the originating request_id. Resolve context-window capacity from the configured selected-model catalog, because the Responses usage object does not supply that capacity. Measure response_time_ms with the server monotonic clock from accepted chat request through completed response, persist it on the same assistant message, and render it after completion; while pending render only the live timer and no synthetic assistant prose. Render per-turn counts, total tokens, used/context percentage, and a BYOK billing notice beside the matching response. Do not display currency cost without a dated price table."
      ["Tests/ChatUIUsage.lean", "Tests/ChatUIConcurrentCredentials.lean"]
  , decision "clickable-links-and-web-research"
      ["task:research_web", "property:research_uses_public_http", "property:research_citations_are_clickable", "proof:Research citations remain visible and clickable", "proof:Research cannot reach server-local networks", "output:chatui.research.interaction", "output:chatui.research.state"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean", "assets/chatui.js", "assets/chatui.css"]
      "Render only absolute http and https URLs as anchors with target=_blank and rel=noopener noreferrer, preserving a visible destination. For explicit research requests, add the hosted Responses API web_search tool with external_web_access enabled and tool_choice auto; provider search, open_page, and find_in_page actions are recorded in the project trace. Parse url_citation annotations into URL_CITATION content parts and render them visibly. Do not implement a general server-side URL fetcher or Google-results scraper, so local, private, link-local, file, and metadata targets are not reachable through LeanFM."
      ["Tests/ChatUILinks.lean", "Tests/ChatUIResearch.lean"]
  , decision "markerboard-ai-assistance"
      ["task:assist_markerboard", "property:markerboard_assist_targets_revision", "property:markerboard_ai_never_silently_overwrites", "property:markerboard_syntax_help_is_local", "property:markerboard_ai_usage_is_visible", "proof:AI assistance requires review", "proof:Stale markerboard patches cannot overwrite", "output:chatui.markerboard-assist.interaction", "output:chatui.markerboard-assist.state"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Make ordinary project chat the primary diagram authoring surface. Accept prose, simplified interaction pseudocode, Mermaid, PlantUML, attached sketches, and public-web research requests. Send the original material to the model with task/scenario context; require a corrected renderable Mermaid result for supported behavioral diagrams, validate it in the strict renderer, render it inline, and store its source as a project artifact linked to the originating message and attachments. Keep the original input as provenance. The markerboard remains an optional exact-source editor with local syntax help and reviewed AI patches; accepting a stale patch fails rather than overwriting a newer revision."
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
  , decision "default-http-codec-and-openapi"
      ["property:default_http_projection_is_deterministic", "property:http_response_backpoints_to_request", "property:http_exchange_is_causally_closed", "proof:HTTP responses retain their request identity"]
      ["LeanFM/ChatUI/Server.lean", "LeanFM/Render.lean"]
      "For an HTTP production without an explicit codec binding, encode and decode bodies using the protobuf JSON mapping with application/json. Generate OpenAPI from the resolved protobuf request-response pairs and transport bindings, and serve the resulting YAML at GET /openapi.yaml. Validate a causally closed exchange relation before projection: each terminal response EventEnvelope.cause_id equals one compatible request event_id in the same session and task, and each projected request is named by exactly one terminal success or error response. Reject orphan requests, dangling responses, incompatible or cross-session causes, and duplicate terminal responses as unchecked HTTP calls. Do not alter or infer prior_ids, which separately governs legal interleavings. Explicit bindings override the default codec, method, path, and content type while remaining subject to correlation and byte round-trip validation."
      ["scripts/chatui_http_check.sh"]
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
