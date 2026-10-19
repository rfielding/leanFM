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
      [spec.id, "task:authenticate_user", "task:create_account", "task:manage_projects", "task:argue_requirements", "constraint:selected_project_context_drives_chat", "constraint:book_revision_is_validated_or_rolled_back", "constraint:book_update_status_is_truthful", "proof:No false durable-artifact success"]
      ["Server.lean", "LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Replace the current gallery at GET / with one dark, responsive project engineering environment that does not require Codex for ordinary work. Signed-out mode embeds login and BYOK registration; an authenticated empty account embeds first-project creation. Navigation mirrors software phases: a persistent left vertical project tab set owns a horizontal Early/Chat-then-Book, Intermediate/Grammar-or-Tasks, and Late/Source phase navigator, with Chat selected by default. The full-height sidebar hides outer overflow and gives only its flexing project-list region vertical overflow with contained overscroll, keeping brand creation controls zoom and account footer fixed; the right ProjectWorkspace independently hides outer overflow and delegates scrolling to its selected pane. Guided chat loads the selected project's complete editable book and canonical requirements and implementation specifications plus a bounded context of the eight newest conversation turns, at most 3500 characters each and without prior operational traces; the complete conversation remains a UI record. The model infers the working phase from ordinary chat without a mode selector. The composer obtains an ordered model allowlist from the authenticated server session, captures its current selection into each queued prompt, rejects all other model strings before persistence or provider work, passes that exact ID to the Responses API, and persists the actual model beside response usage. A structured reply containing a complete book_source is size-checked, atomically staged in the selected project, and built in the filesystem-isolated book worker. Only a successful build commits the source and sets book_updated; failure restores the exact previous source after each candidate and permits at most three compile-guided single-line LaTeX repair attempts using the chat turn's selected model. A repair request contains the bounded diagnostic and numbered nine-line excerpt rather than the complete book, caps output at 2000 tokens, accepts exactly the reported line, and stops immediately on an unchanged candidate. The server writes authenticated project-local model tool validation compile and repair status transitions atomically; the first bounded compiler diagnostic is visible before repair begins. Each repair call defaults to a 30-second deadline configurable only from 10 through 60 seconds. Repair completions contribute usage but never replace the original requested reply; only repair exhaustion produces a visible warning. When the conversation initially loads or gains a user assistant or failure message, scroll only the chat message pane to its bottom so the newest turn and composer remain visible. Chat cannot cross either explicit acceptance gate. Structured answers retain stable question IDs and selected option values. The client closes answered IDs, while the agent must produce a material result after an answer and use reversible defaults after at most one clarification turn; acceptance gates and destructive or expensive irreversible choices remain explicit. An explicit one-shot-readiness prompt reverses the ordinary action-first default: the agent reads the durable book specifications acceptance revisions and source then emits no more than two structured questions for the highest-impact decisions that still block conforming one-pass implementation. Immediately before source generation it writes a security critique into the durable project specification: trust boundaries assets attackers abuse cases and applicable MUST NOT behavior, with each prohibition traced to one implementation control and negative test or proof; any material unmitigated threat returns the conversation to the implementation-specification gate. Keep the composer enabled during provider work and append Send Resend and structured answers to a visible removable project-scoped FIFO. Execute exactly one prompt at a time in order, continuing after a failure, so every later prompt receives all earlier conversation and workspace mutations; reset the live timer for each dequeued prompt. The active status names the captured model, timer, cooperative Cancel control, and the latest real project-scoped stage; its two-second poll retains the last successful stage through transient errors and falls back only to explicitly time-based copy. Its Responses API agent loop offers bounded list, read, literal-search, atomic full-file write, and named-check tools rooted at the selected project's canonical root. Before interpreting a supplied tool path, resolve the configured project root to its canonical absolute form and normalize only the exact root or descendants back to project-relative form; all other absolute traversal and symlink paths remain rejected. Retain exact failed tool name-plus-arguments fingerprints for the active turn. A second identical failed call is not executed and returns a fatal repeated-call result that ends the provider loop with an actionable diagnostic, preventing a third paid attempt. On a reversible tool failure the agent otherwise inspects the diagnostic, changes strategy, exhausts safe local alternatives, validates the artifact, and resumes the original request; it asks only for new authority or a material choice. Provider calls use a 300-second default deadline configurable from 30 through 900 seconds; timeout responses name the deadline and completed tool-step count and are never automatically retried because doing so could duplicate billed inference or already-applied workspace mutations. Every third-party workspace-agent process is dispatched through scripts/chatui_command.sh using a named allowlisted operation; the script fixes executable semantics unsets LD_LIBRARY_PATH and LD_PRELOAD applies operation-specific timeouts and preserves stdout stderr and exit status, while accepting no arbitrary shell program. Each relative path is lexically checked and real-path checked against that root; writes resolve an existing parent and reject symlink escapes. The browser receives a concise answer plus the ordered operational trace. Tasks owns a left vertical task tab set and horizontal interaction, state, property, and guard view tabs. Grammar serializes the accepted GrammarExpr AST without flattening. Server.lean remains a thin executable entry point over ChatUI.Server."
      ["Tests/ChatUIHttp.lean", "scripts/chatui_http_check.sh verifies a successful durable book build and project-rooted source write"]
  , decision "feature-stability-security-review"
      ["constraint:feature_completion_pairs_positive_and_negative_invariants", "constraint:security_review_precedes_commit", "proof:Feature claims are paired with safety claims", "proof:No commit without exact-diff security evidence"]
      ["AGENTS.md", "SKILL.md", "LeanFM/Artifacts.lean", "LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean", "LeanFM/ChatUI/Requirements.lean", "LeanFM/ChatUI/Implementation.lean", "tests and proof artifacts affected by each feature"]
      "Before implementing any feature, record its positive always invariant and perform a proportional stability and security review. Convert applicable forbidden outcomes into never or always-not requirements covering regression failure concurrency resources authorization isolation secrets injection and path boundaries. Map each material negative requirement to a concrete control and negative test or proof. Before recommending or performing a commit, review the exact candidate diff and generated artifacts for those risks plus executable content, unsafe generated artifacts, replay, request confusion, privilege expansion, and fail-open behavior. A feature cannot be reported complete, commit-ready, or committed with an unmitigated material risk."
      ["Lean elaboration validates paired always and never obligations", "each material control has a negative regression test or proof", "prompt contract tests require exact-diff and generated-artifact review before commit readiness"]
  , decision "source-workspace"
      ["task:develop_project_specification", "constraint:implementation_request_produces_source_or_questions", "constraint:implementation_source_is_an_artifact_not_chat", "constraint:widget_project_isolation", "proof:No false durable-artifact success"]
      ["LeanFM/ChatUI/Server.lean", "ui/src/main.tsx", "assets/chatui.css"]
      "Serve a project-confined recursive source file list and bounded UTF-8 file reads. The React Source phase owns its file selection and content state inside the project-keyed workspace. Root every model workspace tool at the selected project's canonical root, never the LeanFM server launch directory, and require final implementation code build files generated bindings and implementation tests beneath source/. An explicit implementation request writes and checks those source artifacts only after both acceptance gates and the security critique; otherwise the response is a focused structured question form naming the missing gate or material decision. If an implementation request returns prose or pasted code while source/ remains empty, replace it with an explicit FAIL instead of claiming success. Chat reports only a concise artifact and validation summary; the Source phase is the implementation browser."
      ["scripts/chatui_http_check.sh", "ui TypeScript build"]
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
      "Replace the growing imperative DOM client with a typed React workspace while retaining the Lean server and project-root API. Key one complete mounted ProjectWorkspace component by authenticated user ID plus project_id and switch project visibility without destroying inactive workspaces. Within each ProjectWorkspace mount every phase widget once and switch visibility without conditionally destroying it, preserving each project's independent phase draft, selection, scroll, queue, timer, preview, and fetched state. An active turn continues when its project or Chat phase is hidden. While an agent turn is active, poll the project-confined Project memory Source list stage status and live Operational trace every two seconds; retain each last successful value and retry transient failures. Each allowlisted workspace-tool start completion failure or rejection appends its bounded server-created entry atomically beneath the project root before the next agent step. The active banner exposes the newest entry from every phase, visually highlights failures, and expands to the trace accumulated so far so cancellation can be evidence-driven rather than delayed until the terminal chat response. Limit the live trace to 100 entries of 1000 characters, never include credentials or arbitrary provider bodies, and authorize its route by authenticated project ownership. Every application error JSON includes error action and stable code fields. The browser adds request ID timestamps duration method path status connectivity project and selected model, enriches network non-JSON and unexpected proxy statuses with a concrete remediation, and renders an expanded one-click Codex diagnostic. It deliberately excludes the prompt credentials and unrelated project data. A project-wide Agent running indicator remains above every phase, names the captured model and elapsed time, explicitly permits navigation, issues a project-authorized cooperative cancellation request, disables duplicate cancellation, holds the FIFO until the active request returns, and checks cancellation before every subsequent provider or workspace-tool step so no new mutation begins after cancellation. Key every query/cache entry by immutable project identity and cancel outstanding project queries only when that project is deleted or the authenticated account workspace unmounts. Components receive project identity explicitly rather than reading a mutable global. Server routes continue to require authenticated user plus explicit project_id and never fall back to self-hosting content."
      ["ui/src/projects/ProjectWorkspace.test.tsx", "Tests/ChatUIProjects.lean", "scripts/chatui_http_check.sh"]
  , decision "private-project-diagnostic-memory"
      ["property:diagnostic_memory_survives_chat_loss", "property:every_project_error_is_durably_diagnosable", "property:browser_errors_reach_project_diagnostics", "property:resolved_diagnostics_are_compacted", "proof:No unsafe or unbounded private diagnostic memory", "proof:Browser diagnostics cannot leak or recurse"]
      ["LeanFM/ChatUI/Server.lean", "Server.lean", "ui/src/api.ts", "ui/src/main.tsx"]
      "Mirror sanitized stages tool destinations compiler failures terminal agent errors every authorized project HTTP response with status at least 400 failed required artifacts warning results correlated unhandled HTTP failures and authenticated browser diagnostics into a 1.5 MB project-root logs/runtime-diagnostics.jsonl journal before returning them. Install browser error and unhandled-rejection listeners; explicitly report API and caught LaTeX or Mermaid failures with operation description error type message sanitized stack page time and active project. Send no prompt request body response body credential cookie or URL query. Bound fields and browser emission to twenty reports per minute, use raw fetch with a recursion guard for the reporting endpoint, and reject cross-project persistence through ordinary project authorization. Inject the twenty most recent unresolved bounded entries into each later agent request so a restart or lost chat cannot repeat a known failed strategy. On a verified matching workspace write or book build, delete the superseded failure cluster and append one compact resolution. Keep the journal private to the project filesystem for LeanFM and Codex rather than exposing it as a browser route."
      ["scripts/chatui_http_check.sh"]
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
  , decision "requirement-ctl-projection"
      ["property:task_page_selects_behavioral_views", "property:property_origin_is_explicit"]
      ["LeanFM/ChatUI/Server.lean", "ui/src/types.ts", "ui/src/main.tsx"]
      "Project each RequirementProperty into explicit CTL syntax: always becomes AG atom, eventually becomes AF atom, never becomes AG not-atom, and preparedFor becomes EF atom. Project each requirements where_ constraint as an AG atom and retain its stable constraint ID. The task API and UI label every formula as originating from Requirements.lean; Implementation.lean only traces controls and mappings back to those formulas and cannot silently introduce an observable property."
      ["scripts/chatui_http_check.sh"]
  , decision "composer-keyboard-commit-order"
      ["property:composer_commits_before_model_selection", "proof:Model selection does not intercept prompt commit"]
      ["ui/src/main.tsx"]
      "Render the Chat composer focusable controls in DOM order as prompt textarea then submit button then model select. Keep Send as the form submit control and retain the currently visible allowlisted model value, so Tab Enter from the editor submits without opening or changing the model selector."
      ["scripts/chatui_http_check.sh"]
  , decision "multimodal-safe-rendering"
      ["task:argue_requirements", "task:markerboard", "proof:Multimodal round trip", "proof:Scratch diagrams do not masquerade as evidence"]
      ["LeanFM/ChatUI/Web.lean", "assets/chatui.js", "assets/chatui.css"]
      "Represent prompt and response bodies as ordered ChatContentPart values. Render Markdown and code as escaped text. Parse explicit \\( ... \\), \\[ ... \\], $ ... $, and $$ ... $$ delimiters outside fenced code, then render LaTeX through bundled KaTeX with trust disabled and native accessible MathML output; a parse failure visibly preserves the original formula. Render Mermaid and DOT from source in sandboxed same-origin frames, images and video from project-scoped media routes, and canvas animations in isolated frames. Require an actual leanfm-canvas fence, but recover the bounded provider error consisting of a spelled-out marker followed by exactly one canvas element and one script element; remove that source from chat prose and execute it only in the existing sandboxed network-disabled iframe with restrictive CSP. Arbitrary HTML remains escaped and cannot trigger recovery. For MCP animation requests, prompt for the Model Context Protocol JSON-RPC lifecycle rather than MQTT broker traffic. Give assistant responses and embedded visual artifacts a responsive workspace up to 1600 CSS pixels wide while retaining compact right-aligned user bubbles. Store JPEG, PNG, GIF, and SVG originals beneath the project root with immutable artifact IDs and revisions plus optional task/scenario bindings. A stakeholder may promote an exact interactive canvas revision into a project-local animated GIF or MP4 that freezes frame timing loop boundaries prompt provenance task/scenario binding; serve it inline so it remains shareable without LeanFM or JavaScript. The bounded workspace_transcode_mp4 tool accepts only project-local GIF or WebM input, removes inherited LD_LIBRARY_PATH and LD_PRELOAD so system ffmpeg cannot load Lean or Elan runtime libraries, invokes ffmpeg with H.264 high profile yuv420p even dimensions and fast-start metadata, validates the ISO base media signature and a 512 MB bound, and returns the project-relative MP4 path for inline rendering. For an explicit MP4 prompt, server postprocessing invokes that tool itself if the model did not, choosing the newest conversation reference that matches a project GIF or WebM and falling back to an available project animation. The response is FAIL unless that turn's trace contains a successfully generated MP4; prose alternatives and follow-up questions can never be labeled SUCCESS, and missing-source process-start or ffmpeg failures expose their actual diagnostic. Authenticated MP4 WebM PDF GIF PNG and JPEG routes implement RFC single byte ranges with Accept-Ranges bytes, 206 Content-Range for closed open-ended and suffix requests, and 416 Content-Range for malformed unsatisfiable or multi-range requests; range handling occurs only after the same authorization and canonical project-root checks as full responses. Allocate monotonically increasing visible Figure N labels from project state and map each label to an exact artifact revision; resolve explicit figure references into provider context even after the originating turn leaves the conversation window. Never infer MIME from a filename alone. Sanitize SVG for display and rasterize it for model vision; retain an animated GIF as the source artifact while sending explicitly selected representative frames to providers that do not accept animation. Resolve named-task discussion to the task model and its bound artifact revisions, and transmit supported images as Responses API input_image content parts. Enforce declared byte and pixel limits, MIME allowlists, alternative text, and no executable HTML. Promotion records an exact scratch revision before candidate requirements change."
      ["Tests/ChatUIContent.lean", "Tests/ChatUIMarkerboard.lean"]
  , decision "deterministic-ui-snapshots"
      ["constraint:book_prefers_reproducible_ui_examples", "constraint:widget_project_isolation", "proof:Provider secrets never become project artifacts"]
      ["scripts/chatui_ui_snapshots.sh", "ui/scenarios/", "book/assets/ui-tour/", "book/chapters/web-server.tex"]
      "Run named scenarios against the actual production React bundle with a deterministic provider and disposable account/project fixture. Select each capture by scenario ID and exact event-prefix boundary; fix viewport font scale theme and clock; wait for an explicit DOM-ready condition; then invoke an allowlisted headless Chrome operation to capture the named element or viewport. Store PNGs and a manifest below the project or checked-in book asset root with originating prompt task scenario visible event IDs requirements revision reducer viewport theme browser version capture timestamp and content digest. The capture worker has no provider credential arbitrary URL input external network or access to another project. A book chapter replaces procedural walls of text with these verified examples plus short interpretation, but never treats a screenshot as accepted requirement evidence without its trace and provenance."
      ["deterministic scenario rerun reproduces the expected capture set", "capture manifest names every visible event prefix", "fixture secret and cross-project scans remain empty", "make book fails when a referenced required screenshot is missing"]
  , decision "request-scoped-provider"
      ["property:model_key_is_request_scoped", "property:concurrent_keys_do_not_collide", "proof:Concurrent BYOK isolation", "proof:Keyless launch cannot spend provider funds"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean"]
      "Resolve the authenticated user's credential_ref for each request, resolve that password-unlocked account-owned key from the authenticated in-memory session into request-local memory, and pass it to a bounded provider worker without mutating environment variables or shared client authorization state. Verify an OpenAI credential with authenticated GET /v1/models before retaining it; create turns with POST /v1/responses. Send authorization through the provider process standard input/config channel rather than command arguments; redact subprocess diagnostics. With no selected user credential and no separately enabled platform credential, return a non-billable failure before network I/O."
      ["Tests/ChatUIConcurrentCredentials.lean", "Tests/ChatUIKeyless.lean"]
  , decision "token-context-accounting"
      ["output:chatui.usage.tokens", "output:chatui.usage.context", "property:Token and context usage are visible", "property:active_billing_identity_is_persistent", "property:local_token_budget_is_visible_and_enforced", "proof:Usage belongs to its response"]
      ["LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean", "ui/src/main.tsx", "assets/chatui.css"]
      "Parse usage.input_tokens, usage.input_tokens_details.cached_tokens, usage.output_tokens, and usage.total_tokens from the OpenAI Responses object and join them to the originating request_id. Resolve context-window capacity from the configured selected-model catalog, because the Responses usage object does not supply that capacity. Measure response_time_ms with the server monotonic clock from accepted chat request through completed response, persist it on the same assistant message, and render it after completion; while pending render only the live timer and no synthetic assistant prose. At persistence, record a separate server wall-clock Unix-epoch millisecond sent_at_ms on every user and assistant message. Render it as a semantic time element in the browser's local timezone with its exact UTC ISO instant available for inspection; do not trust model text as timestamp metadata, and label pre-migration records without a timestamp as legacy rather than fabricating history. Render per-turn counts beside the matching response. In the persistent project header identify the active provider model credential reference and a one-way SHA-256 key fingerprint, never the key. Accumulate successful provider-reported tokens in the password-unlocked login session, default its finite LEANFM_SESSION_TOKEN_BUDGET to one million, display used and remaining values, and reject another provider call once exhausted. State that this local token limit is not a dollar balance and that the provider-project spend cap remains authoritative; do not display currency cost without a dated price table or fabricate provider credit remaining when the API does not expose it."
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
