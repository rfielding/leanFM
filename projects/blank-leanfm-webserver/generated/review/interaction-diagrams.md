# Generated interaction diagrams

## authenticate_user

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    UserBrowser->>LeanFMServer: LoginSubmitted
    LeanFMServer->>UserBrowser: LoginAccepted
    LeanFMServer->>UserBrowser: LoginRejected
```

## create_account

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    participant ModelProvider
    UserBrowser->>LeanFMServer: AccountCreateSubmitted
    LeanFMServer->>ModelProvider: ProviderKeyCheckRequested
    ModelProvider->>LeanFMServer: ProviderKeyVerified
    LeanFMServer->>UserBrowser: AccountCreated
    ModelProvider->>LeanFMServer: ProviderKeyRejected
    LeanFMServer->>UserBrowser: AccountCreateRejected
```

## manage_projects

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    UserBrowser->>LeanFMServer: ProjectListRequested
    LeanFMServer->>UserBrowser: ProjectListReturned
    UserBrowser->>LeanFMServer: ProjectCreateRequested
    LeanFMServer->>UserBrowser: ProjectCreated
    UserBrowser->>LeanFMServer: ProjectOpenRequested
    LeanFMServer->>UserBrowser: ProjectOpened
    UserBrowser->>LeanFMServer: ProjectDeleteRequested
    LeanFMServer->>UserBrowser: ProjectDeleted
```

## configure_provider

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    UserBrowser->>LeanFMServer: ProviderCredentialSubmitted
    LeanFMServer->>UserBrowser: ProviderCredentialAccepted
    LeanFMServer->>UserBrowser: ProviderCredentialRejected
```

## argue_requirements

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    participant ModelProvider
    UserBrowser->>LeanFMServer: ChatPromptSubmitted
    LeanFMServer->>ModelProvider: ModelRequestIssued
    ModelProvider->>LeanFMServer: ModelResponseReturned
    LeanFMServer->>UserBrowser: ChatResponseRendered
    LeanFMServer->>UserBrowser: ChatTurnFailed
```

## markerboard

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    UserBrowser->>LeanFMServer: MermaidDraftSaved
    LeanFMServer->>UserBrowser: MermaidPreviewRendered
    UserBrowser->>LeanFMServer: MediaUploaded
    LeanFMServer->>UserBrowser: MediaRendered
    UserBrowser->>LeanFMServer: ArtifactPromoted
    LeanFMServer->>UserBrowser: CandidateRequirementUpdated
```

## inspect_artifacts

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    UserBrowser->>LeanFMServer: ArtifactListRequested
    LeanFMServer->>UserBrowser: ArtifactListReturned
    UserBrowser->>LeanFMServer: ArtifactOpenRequested
    LeanFMServer->>UserBrowser: ArtifactOpened
```

## inspect_task_model

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    UserBrowser->>LeanFMServer: TaskModelRequested
    LeanFMServer->>UserBrowser: TaskModelReturned
    UserBrowser->>LeanFMServer: MessageSequenceRequested
    LeanFMServer->>UserBrowser: MessageSequenceReturned
    UserBrowser->>LeanFMServer: ProtobufObjectRequested
    LeanFMServer->>UserBrowser: ProtobufObjectReturned
```

## research_web

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    participant ModelProvider
    UserBrowser->>LeanFMServer: WebResearchRequested
    LeanFMServer->>ModelProvider: WebResearchDispatched
    ModelProvider->>LeanFMServer: WebSearchPerformed
    ModelProvider->>LeanFMServer: WebPageOpened
    LeanFMServer->>UserBrowser: WebResearchReturned
    LeanFMServer->>UserBrowser: WebResearchFailed
```

## assist_markerboard

```mermaid
sequenceDiagram
    participant UserBrowser
    participant LeanFMServer
    participant ModelProvider
    UserBrowser->>LeanFMServer: MarkerboardAssistRequested
    LeanFMServer->>UserBrowser: MarkerboardSyntaxHelpReturned
    LeanFMServer->>ModelProvider: MarkerboardAssistDispatched
    ModelProvider->>LeanFMServer: MarkerboardAssistReturned
    LeanFMServer->>UserBrowser: MarkerboardPatchProposed
    UserBrowser->>LeanFMServer: MarkerboardPatchAccepted
    LeanFMServer->>UserBrowser: MarkerboardDraftUpdated
    UserBrowser->>LeanFMServer: MarkerboardPatchRejected
```
