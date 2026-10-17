/-!
Candidate observable requirements for the LeanFM web server.

Design authority: book/main.pdf (working draft, 2026-10-15), especially
chapters 6 and 12. This file deliberately contains no runtime, language,
framework, storage-engine, or handler implementation decisions.
-/

namespace LeanFMRequirements

inductive Actor where | userBrowser | leanFMServer | modelProvider
  deriving DecidableEq, Repr

inductive Message where
  | LoginSubmitted | LoginAccepted | LoginRejected
  | AccountCreateSubmitted | ProviderKeyCheckRequested | ProviderKeyVerified
  | ProviderKeyRejected | AccountCreated | AccountCreateRejected
  | TaskModelRequested | TaskModelReturned | MessageSequenceRequested
  | MessageSequenceReturned | ProtobufObjectRequested | ProtobufObjectReturned
  | WebResearchRequested | WebResearchDispatched | WebSearchPerformed
  | WebPageOpened | WebResearchReturned | WebResearchFailed
  | MarkerboardAssistRequested | MarkerboardSyntaxHelpReturned
  | MarkerboardAssistDispatched | MarkerboardAssistReturned
  | MarkerboardPatchProposed | MarkerboardPatchAccepted
  | MarkerboardPatchRejected | MarkerboardDraftUpdated
  | ProjectListRequested | ProjectListReturned | ProjectCreateRequested
  | ProjectCreated | ProjectOpenRequested | ProjectOpened
  | ProjectDeleteRequested | ProjectDeleted
  | ProviderCredentialSubmitted | ProviderCredentialAccepted
  | ProviderCredentialRejected | ChatPromptSubmitted | ModelRequestIssued
  | ModelResponseReturned | ChatResponseRendered | ChatTurnFailed
  | MermaidDraftSaved | MermaidPreviewRendered | MediaUploaded | MediaRendered
  | ArtifactPromoted | CandidateRequirementUpdated | ArtifactListRequested
  | ArtifactListReturned | ArtifactOpenRequested | ArtifactOpened
  deriving DecidableEq, Repr

structure Step where
  src : Actor
  dst : Actor
  message : Message
  deriving DecidableEq, Repr

abbrev Trace := List Step
structure Task where
  id : String
  entry : String
  terminals : List String
  legalTraces : List Trace
  deriving Repr

def U := Actor.userBrowser
def S := Actor.leanFMServer
def P := Actor.modelProvider
def e (a b : Actor) (m : Message) : Step := ⟨a, b, m⟩

def authenticateUser : Task := ⟨"authenticate_user", "signed_out",
  ["authenticated", "rejected"],
  [[e U S .LoginSubmitted, e S U .LoginAccepted],
   [e U S .LoginSubmitted, e S U .LoginRejected]]⟩

def createAccount : Task := ⟨"create_account", "registration",
  ["created", "rejected"],
  [[e U S .AccountCreateSubmitted, e S P .ProviderKeyCheckRequested,
    e P S .ProviderKeyVerified, e S U .AccountCreated],
   [e U S .AccountCreateSubmitted, e S P .ProviderKeyCheckRequested,
    e P S .ProviderKeyRejected, e S U .AccountCreateRejected]]⟩

def manageProjects : Task := ⟨"manage_projects", "ready",
  ["listed", "created", "opened", "deleted"],
  [[e U S .ProjectListRequested, e S U .ProjectListReturned],
   [e U S .ProjectCreateRequested, e S U .ProjectCreated],
   [e U S .ProjectOpenRequested, e S U .ProjectOpened],
   [e U S .ProjectDeleteRequested, e S U .ProjectDeleted]]⟩

def configureProvider : Task := ⟨"configure_provider", "unconfigured",
  ["configured", "rejected"],
  [[e U S .ProviderCredentialSubmitted, e S U .ProviderCredentialAccepted],
   [e U S .ProviderCredentialSubmitted, e S U .ProviderCredentialRejected]]⟩

def argueRequirements : Task := ⟨"argue_requirements", "ready",
  ["rendered", "failed"],
  [[e U S .ChatPromptSubmitted, e S P .ModelRequestIssued,
    e P S .ModelResponseReturned, e S U .ChatResponseRendered],
   [e U S .ChatPromptSubmitted, e S P .ModelRequestIssued,
    e S U .ChatTurnFailed]]⟩

def markerboard : Task := ⟨"markerboard", "editing", ["candidate"],
  [[e U S .MermaidDraftSaved, e S U .MermaidPreviewRendered,
    e U S .ArtifactPromoted, e S U .CandidateRequirementUpdated],
   [e U S .MediaUploaded, e S U .MediaRendered,
    e U S .ArtifactPromoted, e S U .CandidateRequirementUpdated]]⟩

def inspectArtifacts : Task := ⟨"inspect_artifacts", "closed", ["listed", "opened"],
  [[e U S .ArtifactListRequested, e S U .ArtifactListReturned],
   [e U S .ArtifactListRequested, e S U .ArtifactListReturned,
    e U S .ArtifactOpenRequested, e S U .ArtifactOpened]]⟩

def inspectTaskModel : Task := ⟨"inspect_task_model", "closed",
  ["linked", "sequence_visible", "object_visible"],
  [[e U S .TaskModelRequested, e S U .TaskModelReturned],
   [e U S .TaskModelRequested, e S U .TaskModelReturned,
    e U S .MessageSequenceRequested, e S U .MessageSequenceReturned],
   [e U S .TaskModelRequested, e S U .TaskModelReturned,
    e U S .MessageSequenceRequested, e S U .MessageSequenceReturned,
    e U S .ProtobufObjectRequested, e S U .ProtobufObjectReturned]]⟩

def researchWeb : Task := ⟨"research_web", "ready", ["returned", "failed"],
  [[e U S .WebResearchRequested, e S P .WebResearchDispatched,
    e P S .WebSearchPerformed, e P S .WebPageOpened,
    e S U .WebResearchReturned],
   [e U S .WebResearchRequested, e S P .WebResearchDispatched,
    e S U .WebResearchFailed]]⟩

def assistMarkerboard : Task := ⟨"assist_markerboard", "editing",
  ["helped", "updated", "rejected"],
  [[e U S .MarkerboardAssistRequested, e S U .MarkerboardSyntaxHelpReturned],
   [e U S .MarkerboardAssistRequested, e S P .MarkerboardAssistDispatched,
    e P S .MarkerboardAssistReturned, e S U .MarkerboardPatchProposed,
    e U S .MarkerboardPatchAccepted, e S U .MarkerboardDraftUpdated],
   [e U S .MarkerboardAssistRequested, e S P .MarkerboardAssistDispatched,
    e P S .MarkerboardAssistReturned, e S U .MarkerboardPatchProposed,
    e U S .MarkerboardPatchRejected]]⟩

def tasks : List Task := [authenticateUser, createAccount, manageProjects,
  configureProvider, argueRequirements, markerboard, inspectArtifacts,
  inspectTaskModel, researchWeb, assistMarkerboard]

def messages : List Message := [
  .LoginSubmitted, .LoginAccepted, .LoginRejected,
  .AccountCreateSubmitted, .ProviderKeyCheckRequested, .ProviderKeyVerified,
  .ProviderKeyRejected, .AccountCreated, .AccountCreateRejected,
  .TaskModelRequested, .TaskModelReturned, .MessageSequenceRequested,
  .MessageSequenceReturned, .ProtobufObjectRequested, .ProtobufObjectReturned,
  .WebResearchRequested, .WebResearchDispatched, .WebSearchPerformed,
  .WebPageOpened, .WebResearchReturned, .WebResearchFailed,
  .MarkerboardAssistRequested, .MarkerboardSyntaxHelpReturned,
  .MarkerboardAssistDispatched, .MarkerboardAssistReturned,
  .MarkerboardPatchProposed, .MarkerboardPatchAccepted,
  .MarkerboardPatchRejected, .MarkerboardDraftUpdated,
  .ProjectListRequested, .ProjectListReturned, .ProjectCreateRequested,
  .ProjectCreated, .ProjectOpenRequested, .ProjectOpened,
  .ProjectDeleteRequested, .ProjectDeleted, .ProviderCredentialSubmitted,
  .ProviderCredentialAccepted, .ProviderCredentialRejected,
  .ChatPromptSubmitted, .ModelRequestIssued, .ModelResponseReturned,
  .ChatResponseRendered, .ChatTurnFailed, .MermaidDraftSaved,
  .MermaidPreviewRendered, .MediaUploaded, .MediaRendered,
  .ArtifactPromoted, .CandidateRequirementUpdated, .ArtifactListRequested,
  .ArtifactListReturned, .ArtifactOpenRequested, .ArtifactOpened]

/- Event-journal contract. The payload is represented by Message here and by
   exactly one protobuf oneof alternative in Requirements.proto. -/
structure Event where
  eventId : String
  priorIds : List String
  sessionId : String
  taskId : String
  logicalTime : Nat
  src : Actor
  dst : Actor
  payload : Message
  deriving Repr

def endpoint : Message → Actor × Actor
  | .LoginSubmitted | .AccountCreateSubmitted | .TaskModelRequested
  | .MessageSequenceRequested | .ProtobufObjectRequested | .WebResearchRequested
  | .MarkerboardAssistRequested | .MarkerboardPatchAccepted
  | .MarkerboardPatchRejected | .ProjectListRequested | .ProjectCreateRequested
  | .ProjectOpenRequested | .ProjectDeleteRequested
  | .ProviderCredentialSubmitted | .ChatPromptSubmitted | .MermaidDraftSaved
  | .MediaUploaded | .ArtifactPromoted | .ArtifactListRequested
  | .ArtifactOpenRequested => (U, S)
  | .ProviderKeyVerified | .ProviderKeyRejected | .WebSearchPerformed
  | .WebPageOpened | .MarkerboardAssistReturned | .ModelResponseReturned => (P, S)
  | .ProviderKeyCheckRequested | .WebResearchDispatched
  | .MarkerboardAssistDispatched | .ModelRequestIssued => (S, P)
  | _ => (S, U)

def endpointsAgree (x : Event) : Prop := (x.src, x.dst) = endpoint x.payload
def idsPresent (x : Event) : Prop :=
  x.eventId ≠ "" ∧ x.sessionId ≠ "" ∧ x.taskId ≠ ""
def predecessorImmutable (_before _after : Event) : Prop :=
  _before.eventId = _after.eventId → _before.priorIds = _after.priorIds

/- Observable requirements and unresolved proof obligations. -/
structure Requirement where
  id : String
  statement : String
  source : String

def requirements : List Requirement := [
  ⟨"REQ-001", "Only a trace admitted by the event's selected task residual grammar is legal.", "12.6"⟩,
  ⟨"REQ-002", "Every accepted event has a unique immutable id, immutable predecessor ids, session/task correlation, logical time, matching endpoints, and exactly one payload.", "12.1, 12.5"⟩,
  ⟨"REQ-003", "The binary journal is a sequence of length-delimited EventEnvelope values; successor indexes are derived, never mutable serialized truth.", "12.1, 12.5"⟩,
  ⟨"REQ-004", "Credentials never occur in URLs, traces, diagnostics, or returned objects; bytes are explicitly encoded and response secrets are redacted.", "12.2"⟩,
  ⟨"REQ-005", "All API routes except account creation and login require an authenticated session; missing session is 401.", "12.3"⟩,
  ⟨"REQ-006", "Project access is owner-scoped; unknown and unauthorized projects are indistinguishable 404 responses.", "12.3"⟩,
  ⟨"REQ-007", "The service binds to loopback by default; network exposure requires an authenticating boundary.", "6.4, 12.3"⟩,
  ⟨"REQ-008", "All mutable project-owned state remains under one validated project root; paths and symlinks may not escape it.", "6.5"⟩,
  ⟨"REQ-009", "Temporary project files are created and atomically renamed inside the root; deletion refuses root/escaping targets and removes only the exact project root.", "6.5"⟩,
  ⟨"REQ-010", "Provider key, user, session, project, conversation, and request identity are request-local, not process-global.", "12.4"⟩,
  ⟨"REQ-011", "Every actor has finite inbound/outbound queues; full queues block sends, empty queues block receives, and concurrent session/task pairs remain correlated.", "6.6"⟩,
  ⟨"REQ-012", "Queued encoded-envelope bytes plus declared in-flight footprint never exceed each actor byte budget.", "6.6, 6.8"⟩,
  ⟨"REQ-013", "Generated views are reductions of this typed model and retain question, source, reducer, unit, and boundary provenance.", "1.3, 6.7"⟩,
  ⟨"REQ-014", "Model predictions, assumptions, bounded checks, and event-stream measurements are visibly distinguished.", "6.7, 6.9"⟩,
  ⟨"REQ-015", "AI may propose edits, but deterministic validation decides validity and no tool accepts a requirements gate.", "6.2, 6.4"⟩
]

theorem task_count : tasks.length = 10 := by decide
theorem message_count : messages.length = 55 := by decide
theorem authenticate_alternatives : authenticateUser.legalTraces.length = 2 := by decide
theorem endpoint_example : endpoint .ModelRequestIssued = (S, P) := by decide

end LeanFMRequirements
