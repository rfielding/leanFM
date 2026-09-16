# Large File Policy Server Example

This is a worked example of a web server that accepts huge object uploads and downloads, while using JWT identity plus Open Policy Agent Rego files to decide what the current user is allowed to know, list, read, write, and delegate.

The intended standards are deliberately ordinary:

- HTTP/1.1 or HTTP/2 for transport.
- OpenAPI 3.1 for the route contract.
- Bearer JWTs for authenticated user identity.
- Object metadata plus content-addressed or object-store-backed byte bodies.
- Resumable uploads using upload sessions and ranged chunk writes.
- HTTP byte ranges for large downloads.
- OPA/Rego for policy evaluation.
- Audit events for every policy decision and transfer of control.

## Actors

```text
Browser
API Server
Identity Provider
Clearance Directory
Object Store
Policy Store
OPA Evaluator
Audit Log
```

The API server never trusts a browser-supplied clearance. The browser sends a JWT. The server verifies the JWT, extracts stable identity fields, and looks up the user's current clearance, manager, department, employment status, and delegation rights from the clearance directory.

## Core Objects

```text
FileObject
  id
  name
  owner_user_id
  manager_user_id
  classification_banner      example: SECRET//Squirrel
  content_type
  size
  sha256
  storage_uri
  policy_uri                 example: objects/{id}/policy.rego
  created_at
  updated_at
  retired_owner_user_id?

UserContext
  sub
  user_id
  groups
  clearance_labels
  manager_user_id?
  active

PolicyDecision
  can_know
  can_list
  can_read
  can_write
  can_admin
  banner
  reasons
```

The important split is:

- `can_know`: the user may know that the object exists.
- `can_list`: the object may appear in listings.
- `can_read`: the user may download bytes.
- `can_write`: the user may create or replace bytes or metadata.
- `can_admin`: the user may change ownership, delegate permissions, or replace the `.rego` policy.

This matters because a user may have permission to know that a classified object exists without being allowed to read its bytes.

## Message Flow

```text
Browser -> API Server: POST /auth/session with login result or IdP callback
API Server -> Identity Provider: verify JWT signature and claims
API Server -> Clearance Directory: lookup user clearance and manager chain
API Server -> Browser: access token / session cookie

Browser -> API Server: POST /files/upload-sessions
API Server -> OPA Evaluator: evaluate create/write permission
API Server -> Object Store: create pending object
API Server -> Browser: upload_id, chunk URL

Browser -> API Server: PUT /files/{fileId}/chunks/{part}
API Server -> OPA Evaluator: evaluate can_write
API Server -> Object Store: write bytes
API Server -> Audit Log: append write decision

Browser -> API Server: POST /files/{fileId}/complete
API Server -> Object Store: assemble chunks and verify sha256
API Server -> Policy Store: attach uploaded {file}.rego or default policy
API Server -> Audit Log: append complete event

Browser -> API Server: GET /files
API Server -> OPA Evaluator: evaluate can_know/can_list for candidates
API Server -> Browser: only visible metadata

Browser -> API Server: GET /files/{fileId}/content with Range header
API Server -> OPA Evaluator: evaluate can_read
API Server -> Object Store: stream byte range
API Server -> Browser: 206 Partial Content or 200 OK

Browser -> API Server: POST /files/{fileId}/delegate
API Server -> OPA Evaluator: evaluate can_admin
API Server -> Policy Store: update ownership/delegation metadata
API Server -> Audit Log: append delegation event
```

## Rego Policy Example

Each uploaded file may have a sibling policy file named after the data file:

```text
satellite-image.tif
satellite-image.tif.rego
```

Example `satellite-image.tif.rego`:

```rego
package leanfm.filepolicy

default can_know = false
default can_list = false
default can_read = false
default can_write = false
default can_admin = false

required_banner := "SECRET//Squirrel"

active_user {
  input.user.active == true
}

has_clearance {
  required_banner == input.file.classification_banner
  required_banner in input.user.clearance_labels
}

is_owner {
  input.user.user_id == input.file.owner_user_id
}

is_manager {
  input.user.user_id == input.file.manager_user_id
}

is_delegate {
  input.user.user_id in input.file.delegates
}

can_know {
  active_user
  has_clearance
}

can_list {
  can_know
}

can_read {
  can_know
  is_owner
}

can_read {
  can_know
  is_manager
}

can_read {
  can_know
  is_delegate
}

can_write {
  can_read
  is_owner
}

can_write {
  can_read
  is_delegate
  "write" in input.file.delegate_permissions[input.user.user_id]
}

can_admin {
  active_user
  has_clearance
  is_owner
}

can_admin {
  active_user
  has_clearance
  is_manager
}

banner := required_banner

reasons contains "inactive-user" {
  input.user.active == false
}

reasons contains "missing-clearance" {
  not has_clearance
}
```

A policy decision input for OPA should be assembled server-side:

```json
{
  "action": "read",
  "user": {
    "sub": "idp|alice",
    "user_id": "alice",
    "groups": ["engineering"],
    "clearance_labels": ["SECRET//Squirrel"],
    "manager_user_id": "morgan",
    "active": true
  },
  "file": {
    "id": "file_01",
    "owner_user_id": "alice",
    "manager_user_id": "morgan",
    "classification_banner": "SECRET//Squirrel",
    "delegates": ["newhire"],
    "delegate_permissions": {
      "newhire": ["read", "write"]
    }
  }
}
```

## Manager Handoff Rule

When a user rotates out, the server should not depend on that user's future cooperation. A directory event changes the user to inactive, and the handoff workflow grants the manager admin control:

```text
Clearance Directory -> API Server: user alice inactive; manager is morgan
API Server -> Policy Store: mark alice as retired_owner_user_id
API Server -> Policy Store: set manager_user_id = morgan
API Server -> Audit Log: owner_rotated_out(file_id, alice, morgan)
```

After that, `morgan` can call:

```text
POST /files/{fileId}/delegate
```

to grant a new user `read`, `write`, or `admin` permissions, subject to the same Rego policy and clearance checks.

## OpenAPI 3.1 Sketch

```yaml
openapi: 3.1.0
info:
  title: LeanFM Large File Policy Server
  version: 0.1.0
security:
  - bearerJwt: []
components:
  securitySchemes:
    bearerJwt:
      type: http
      scheme: bearer
      bearerFormat: JWT
  schemas:
    UploadSessionRequest:
      type: object
      required: [name, size, sha256, classificationBanner]
      properties:
        name: { type: string }
        size: { type: integer, format: int64, minimum: 0 }
        sha256: { type: string }
        contentType: { type: string }
        classificationBanner:
          type: string
          examples: ["SECRET//Squirrel"]
        policyFileName:
          type: string
          description: Optional sibling Rego policy file, for example report.pdf.rego.
    UploadSession:
      type: object
      required: [uploadId, fileId, chunkSize]
      properties:
        uploadId: { type: string }
        fileId: { type: string }
        chunkSize: { type: integer, format: int64 }
    FileSummary:
      type: object
      required: [id, name, classificationBanner, size]
      properties:
        id: { type: string }
        name: { type: string }
        classificationBanner: { type: string }
        size: { type: integer, format: int64 }
        ownerUserId: { type: string }
        managerUserId: { type: string }
    DelegateRequest:
      type: object
      required: [userId, permissions]
      properties:
        userId: { type: string }
        permissions:
          type: array
          items:
            type: string
            enum: [read, write, admin]
    PolicyDecision:
      type: object
      required: [canKnow, canList, canRead, canWrite, canAdmin, banner]
      properties:
        canKnow: { type: boolean }
        canList: { type: boolean }
        canRead: { type: boolean }
        canWrite: { type: boolean }
        canAdmin: { type: boolean }
        banner: { type: string }
        reasons:
          type: array
          items: { type: string }
paths:
  /auth/session:
    post:
      summary: Exchange an identity-provider login result for a server session.
      responses:
        "200":
          description: Session established.
  /files:
    get:
      summary: List only files the current user may know about and list.
      responses:
        "200":
          description: Visible file summaries.
          content:
            application/json:
              schema:
                type: array
                items: { $ref: "#/components/schemas/FileSummary" }
  /files/upload-sessions:
    post:
      summary: Start a resumable upload for a large file.
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/UploadSessionRequest" }
      responses:
        "201":
          description: Upload session created.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/UploadSession" }
  /files/{fileId}/chunks/{partNumber}:
    put:
      summary: Upload one chunk of a large file.
      parameters:
        - name: fileId
          in: path
          required: true
          schema: { type: string }
        - name: partNumber
          in: path
          required: true
          schema: { type: integer, minimum: 1 }
      requestBody:
        required: true
        content:
          application/octet-stream:
            schema:
              type: string
              format: binary
      responses:
        "204":
          description: Chunk accepted.
  /files/{fileId}/policy:
    put:
      summary: Upload or replace the Rego policy attached to a file.
      requestBody:
        required: true
        content:
          text/x-rego:
            schema:
              type: string
      responses:
        "204":
          description: Policy accepted.
  /files/{fileId}/complete:
    post:
      summary: Complete an upload and verify object hash.
      responses:
        "200":
          description: Object finalized.
  /files/{fileId}/content:
    get:
      summary: Download file content, supporting HTTP Range for huge files.
      parameters:
        - name: fileId
          in: path
          required: true
          schema: { type: string }
        - name: Range
          in: header
          required: false
          schema: { type: string }
          example: bytes=0-1048575
      responses:
        "200":
          description: Complete object bytes.
          content:
            application/octet-stream:
              schema:
                type: string
                format: binary
        "206":
          description: Partial object bytes.
          headers:
            Content-Range:
              schema: { type: string }
  /files/{fileId}/decision:
    get:
      summary: Explain the current user's policy decision for a file.
      responses:
        "200":
          description: OPA decision summary.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/PolicyDecision" }
  /files/{fileId}/delegate:
    post:
      summary: Grant permissions to a replacement user or delegate.
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/DelegateRequest" }
      responses:
        "204":
          description: Delegation updated.
```

## LeanFM Message Atoms

A LeanFM model for this service would use atoms like:

```text
Browser -> API        Auth.SessionRequest(jwt)
API -> IdP            Auth.VerifyJwt(jwt)
IdP -> API            Auth.JwtVerified(sub, issuer, groups)
API -> Directory      Clearance.Lookup(user_id)
Directory -> API      Clearance.UserContext(clearances, active, manager)
Browser -> API        File.StartUpload(name, size, sha256, banner)
API -> OPA            Policy.Evaluate(action=create, user, file)
OPA -> API            Policy.Decision(can_write, banner, reasons)
Browser -> API        File.PutChunk(file_id, part, bytes)
API -> ObjectStore    Object.PutPart(file_id, part, bytes)
Browser -> API        File.GetContent(file_id, range)
API -> OPA            Policy.Evaluate(action=read, user, file)
API -> ObjectStore    Object.GetRange(file_id, range)
Directory -> API      User.RotatedOut(user_id, manager_user_id)
API -> PolicyStore    Policy.AssignManager(file_id, manager_user_id)
Manager -> API        File.Delegate(file_id, new_user, permissions)
```

Required proofs should include:

```text
Never: bytes are returned unless can_read is true.
Never: listings reveal objects unless can_list is true.
Never: a policy replacement occurs unless can_admin is true.
Always: every policy decision input contains server-looked-up clearance, not browser-supplied clearance.
Always: every file response carries the policy banner returned by OPA.
Eventually: every completed chunk upload is either finalized or garbage-collected.
Eventually: every user rotation event grants the manager admin control or emits an audited failure.
Possibly: a manager delegates read/write permissions to a replacement user.
Until: pending uploaded chunks remain non-readable until hash verification and policy attachment complete.
```

## Safety Properties

The main point of writing the server as a message grammar is that a conforming implementation should rule out the obvious bad traces.

The model should make these states explicit:

```text
NoObject
PendingUpload
PolicyPending
Quarantined
Readable
RetiredOwner
Delegated
Deleted
GarbageCollected
```

Then the legal lifecycle is narrow:

```text
NoObject
  -> PendingUpload
  -> PolicyPending
  -> Readable
  -> RetiredOwner
  -> Delegated
  -> Deleted
  -> GarbageCollected
```

Failure paths go to `Quarantined` or `GarbageCollected`, not to `Readable`:

```text
PendingUpload -> Quarantined          if hash verification fails
PolicyPending -> Quarantined          if Rego validation fails
PendingUpload -> GarbageCollected     if upload session expires
Quarantined -> GarbageCollected       after retention/audit window
```

Useful proof obligations:

```text
Never spill bytes:
  No trace contains File.ContentResponse(bytes) unless the immediately preceding
  policy decision for the same file, user, token, and action has can_read = true.

Never spill existence:
  No listing or metadata response names a file unless can_know and can_list are true.

Never read pending bytes:
  File bytes are not readable until hash verification succeeds and a valid policy
  is attached.

Never use caller-provided clearance:
  Policy input clearance_labels always comes from Clearance.Directory, never from
  Browser request fields.

Never orphan an object:
  Every non-deleted readable object has at least one active admin principal:
  owner, manager, or delegate with admin.

Never strand retired ownership:
  If owner_user_id becomes inactive, the object eventually enters RetiredOwner
  with manager_user_id assigned, or Quarantined with an audited failure.

Always preserve admin handoff:
  From RetiredOwner, the manager can delegate admin/read/write to a replacement
  user who satisfies the same clearance policy.

Always audit authority-changing events:
  Policy replacement, manager reassignment, delegation, quarantine, delete, and
  garbage collection all append Audit.Event before returning success.

Until finalized:
  PendingUpload chunks remain invisible until CompleteUpload verifies sha256 and
  AttachPolicy validates the Rego module.
```

In CTL-style terms, the first sketch is:

```text
AG(content_response -> last_decision.can_read)
AG(listing_mentions_file -> last_decision.can_list)
AG(readable -> valid_hash && valid_policy)
AG(readable && !deleted -> exists_active_admin)
AG(owner_inactive -> AF(manager_admin || quarantined_with_audit))
A[pending_upload U (readable || quarantined || garbage_collected)]
```

The OpenAPI document tells clients how to speak to the server. The LeanFM grammar is stricter: it says which causally dependent messages must exist before a response is legal. That is where we can prove that a server following the spec does not produce the obvious spill and orphan traces.
