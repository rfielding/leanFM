# Generated residual state machines

## authenticate_user

```mermaid
stateDiagram-v2
    [*] --> signed_out
    signed_out --> submitted: LoginSubmitted
    submitted --> authenticated: LoginAccepted
    submitted --> rejected: LoginRejected
    authenticated --> [*]
    rejected --> [*]
```

## create_account

```mermaid
stateDiagram-v2
    [*] --> registration
    registration --> checking: AccountCreateSubmitted
    checking --> verifying: ProviderKeyCheckRequested
    verifying --> verified: ProviderKeyVerified
    verified --> created: AccountCreated
    verifying --> key_rejected: ProviderKeyRejected
    key_rejected --> rejected: AccountCreateRejected
    created --> [*]
    rejected --> [*]
```

## manage_projects

```mermaid
stateDiagram-v2
    [*] --> ready
    ready --> listed: ProjectListRequested
    listed --> listed: ProjectListReturned
    ready --> created: ProjectCreateRequested
    created --> created: ProjectCreated
    ready --> opened: ProjectOpenRequested
    opened --> opened: ProjectOpened
    ready --> deleted: ProjectDeleteRequested
    deleted --> deleted: ProjectDeleted
    listed --> [*]
    created --> [*]
    opened --> [*]
    deleted --> [*]
```

## configure_provider

```mermaid
stateDiagram-v2
    [*] --> unconfigured
    unconfigured --> submitted: ProviderCredentialSubmitted
    submitted --> configured: ProviderCredentialAccepted
    submitted --> rejected: ProviderCredentialRejected
    configured --> [*]
    rejected --> [*]
```

## argue_requirements

```mermaid
stateDiagram-v2
    [*] --> ready
    ready --> requested: ChatPromptSubmitted
    requested --> waiting: ModelRequestIssued
    waiting --> returned: ModelResponseReturned
    returned --> rendered: ChatResponseRendered
    waiting --> failed: ChatTurnFailed
    rendered --> [*]
    failed --> [*]
```

## markerboard

```mermaid
stateDiagram-v2
    [*] --> editing
    editing --> preview: MermaidDraftSaved
    preview --> promote: MermaidPreviewRendered
    editing --> media: MediaUploaded
    media --> promote: MediaRendered
    promote --> updating: ArtifactPromoted
    updating --> candidate: CandidateRequirementUpdated
    candidate --> [*]
```

## inspect_artifacts

```mermaid
stateDiagram-v2
    [*] --> closed
    closed --> listed: ArtifactListRequested
    listed --> listed: ArtifactListReturned
    listed --> opening: ArtifactOpenRequested
    opening --> opened: ArtifactOpened
    listed --> [*]
    opened --> [*]
```

## inspect_task_model

```mermaid
stateDiagram-v2
    [*] --> closed
    closed --> linking: TaskModelRequested
    linking --> linked: TaskModelReturned
    linked --> sequence_request: MessageSequenceRequested
    sequence_request --> sequence_visible: MessageSequenceReturned
    sequence_visible --> object_request: ProtobufObjectRequested
    object_request --> object_visible: ProtobufObjectReturned
    linked --> [*]
    sequence_visible --> [*]
    object_visible --> [*]
```

## research_web

```mermaid
stateDiagram-v2
    [*] --> ready
    ready --> dispatch: WebResearchRequested
    dispatch --> provider: WebResearchDispatched
    provider --> searched: WebSearchPerformed
    searched --> opened: WebPageOpened
    opened --> returned: WebResearchReturned
    provider --> failed: WebResearchFailed
    returned --> [*]
    failed --> [*]
```

## assist_markerboard

```mermaid
stateDiagram-v2
    [*] --> editing
    editing --> helped: MarkerboardAssistRequested
    helped --> helped: MarkerboardSyntaxHelpReturned
    helped --> dispatch: MarkerboardAssistDispatched
    dispatch --> returned: MarkerboardAssistReturned
    returned --> proposed: MarkerboardPatchProposed
    proposed --> accepted: MarkerboardPatchAccepted
    accepted --> updated: MarkerboardDraftUpdated
    proposed --> rejected: MarkerboardPatchRejected
    helped --> [*]
    updated --> [*]
    rejected --> [*]
```
