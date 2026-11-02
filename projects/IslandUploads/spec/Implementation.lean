import LeanFM.Artifacts
import spec.Requirements

/-!
# IslandUploads: implementation mapping

Choices that realize the requirements without changing what can be observed.

* One Go binary, `islandd`, runs one shard. Two shards (`shard-a` in island `us`, `shard-b` in
  island `eu`) run as two processes with their own data directories.
* Records live in one SQLite table (pure-Go `modernc.org/sqlite`) with the indexes the original
  MongoDB collection had: `(dt)`, `(parent_id, id, dt)`, `(id, dt)`, `(shard, dt)` and
  `(visible_dt)`. Inserts are `INSERT OR IGNORE` on the primary key `(id, dt)`, which is what makes
  anti-entropy idempotent.
* Each shard has one writer goroutine. Every local write and every import goes through it, and it
  assigns `visible_dt` and commits in the same step, so records become readable in `visible_dt`
  order and a peer's cursor into this feed can never be passed by a later commit (proofs: No feed
  skips; Cursors are prefixes).
* Timestamps come from one per-process clock that returns strictly increasing nanoseconds.
* Blobs are files named by sha256 under the data directory, written before their record. Uploads
  and copies append to part files under `uploads/` and are renamed into place only when complete
  and verified. Encryption at rest is the volume's (LUKS or the cloud disk's), not the
  application's: ranges stay plain file reads.
* Anti-entropy runs every 5 s per peer, and again at once after a page with `more`, but only
  while fewer than 100000 pulled records wait for a lane.
* Pulled records wait in a `pending` table (not visible) and are imported by 128 lane goroutines.
  A lane for a blob over 64 MiB also takes one of 96 large-blob tokens, so 32 lanes are always
  open to small files. A failed attempt releases its lane and its token at once; the record's
  `pending` row keeps the offset held and a `retry_at` time (1 s doubling to 10 min), and the
  scheduler takes only rows whose `retry_at` has passed. Up to 100000 rows wait on disk. A lane pulls the blob by ranges into a part file, verifies sha256, renames
  it into place, and submits the record to the writer, which gives it this shard's own `visible_dt`.
* The peer's `visible_dt` and this shard's are different clocks, so the cursor is never derived
  from local records. Each `pending` row keeps `peer_visible_dt`, the value the peer served it
  with, and a `done` flag. An import's commit sets `done` instead of deleting the row. In the
  same transaction the writer moves the peer's row in the `cursors` table to the greatest
  `peer_visible_dt` of that peer below which every row is done, and deletes the done rows at or
  below it. Imports that finish out of order therefore leave the cursor where it is, and the one
  that completes the run moves it at once to the highest finished value: if a page's imports
  finish in reverse order, the cursor stays put until the lowest finishes, then jumps to the
  top of the page. When no row of a peer is pending, the cursor is the `last_visible_dt` of the
  last page served. A restart re-pulls from the cursor; a resent record already held locally
  (its `(id, dt)` exists) is dropped without pulling its blob again, so at worst a record and a
  blob in flight are sent twice.
* Tokens are JWTs verified against the configured issuer keys (RS256 or ES256) before any read or
  write; the claims are the policy input. Policies are evaluated with the embedded OPA Go library
  with `http.send` and every other network or file builtin disabled, a 50 ms budget, and a cache
  keyed by (policy versions, claims digest). The policy's result is `{read, write, banner, bg,
  fg, rank}`; evaluation errors deny both. A file with read = false is answered by the same code
  path as a missing file, so status, body and headers are identical.
* Jobs are configured commands (`label`, `text`, `translate:<lang>`) run by a worker pool with
  2 workers per shard, only on blobs created on that shard. Each command writes its outputs into a
  scratch directory; every file it leaves there becomes a new file record.
-/

namespace Project.Implementation

open LeanFM

def why (id reason : String) : List RequirementJustification := [{ requirementId := id, reason }]

def http (name method path id reason : String) : MessageCodegen :=
  { message := name, wireType := "islanduploads." ++ name, transport := .httpRequest method path, justifications := why id reason }
def resp (name request id reason : String) : MessageCodegen :=
  { message := name, wireType := "islanduploads." ++ name, transport := .httpResponse request, justifications := why id reason }

def implementation : ImplementationSpec :=
  { requirementId := Project.Requirements.requirements.id
  , target := .go
  , moduleName := "leanfm/islanduploads"
  , outputDirectory := "source/"
  , actors :=
      [ { actor := "Browser", typeName := "web page served by islandd", sourceFile := "source/internal/web/page.go"
        , justifications := why "actor:Browser" "The page uploads, pages the feed by visible_dt and renders history." }
      , { actor := "Shard", typeName := "shard.Shard", sourceFile := "source/internal/shard/shard.go"
        , justifications := why "actor:Shard" "One shard per island; accepts writes without contacting peers." }
      , { actor := "Peer", typeName := "shard.PeerHandlers", sourceFile := "source/internal/shard/peer.go"
        , justifications := why "actor:Peer" "The same shard process, answering another shard's anti-entropy and blob calls." }
      , { actor := "Worker", typeName := "jobs.Worker", sourceFile := "source/internal/jobs/worker.go"
        , justifications := why "actor:Worker" "Runs configured jobs (label, text, translate) as external commands on blobs created on its shard." } ]
  , messages :=
      [ http "UploadStart" "POST" "/uploads" "message:UploadStart" "JSON body; request_id is remembered for 24 h per shard"
      , resp "UploadStarted" "UploadStart" "message:UploadStarted" "201 with upload_id; a part file is created empty under the data directory"
      , http "UploadPart" "PUT" "/uploads/{upload_id}" "property:Parts resume"
          "raw body appended at the offset in the Upload-Offset header, then fsynced; at most 8 MiB per part"
      , resp "UploadPartAck" "UploadPart" "message:UploadPartAck" "204 with the new offset in Upload-Offset"
      , http "UploadFinish" "POST" "/uploads/{upload_id}/finish" "proof:A file exists only when complete"
          "size and sha256 are checked, the part file is renamed to the blob path, then the writer creates the record"
      , resp "UploadResponse" "UploadFinish" "message:UploadResponse" "201 with the created record"
      , resp "UploadRejected" "UploadPart" "message:UploadRejected" "409 with Upload-Offset, 422, 413 or 400; the same response type answers UploadStart and UploadFinish"
      , http "UpdateRequest" "POST" "/files/{id}/versions" "message:UpdateRequest" "JSON body naming prev_dts"
      , resp "UpdateResponse" "UpdateRequest" "message:UpdateResponse" "201 with the new version"
      , resp "UpdateRejected" "UpdateRequest" "message:UpdateRejected" "404 when some (id, d) in prev_dts is not held here"
      , http "FeedRequest" "GET" "/feed" "message:FeedRequest" "after and limit are bounded unsigned query parameters"
      , resp "FeedResponse" "FeedRequest" "message:FeedResponse" "JSON page read from the (visible_dt) index"
      , http "HistoryRequest" "GET" "/files/{id}/history" "message:HistoryRequest" "id is an unsigned path parameter"
      , resp "AccessDenied" "FeedRequest" "proof:Nothing is shown that policy denies"
          "401, or 404 with the missing-file body when read = false; the same response type answers HistoryRequest and DownloadRequest"
      , resp "HistoryResponse" "HistoryRequest" "message:HistoryResponse" "read from the (id, dt) index"
      , http "DownloadRequest" "GET" "/files/{id}/{dt}/content" "property:Ranges are exact" "id and dt are unsigned path parameters; a Range header selects bytes"
      , resp "DownloadResponse" "DownloadRequest" "property:Ranges are always honoured" "net/http ServeContent on the blob file: 200, or 206 with Content-Range, Accept-Ranges, If-Range and HEAD, with the stored content type so a video element can seek"
      , resp "RangeNotSatisfiable" "DownloadRequest" "message:RangeNotSatisfiable" "416 with Content-Range: bytes */size, from ServeContent"
      , http "IHaveRequest" "POST" "/peer/ihave" "message:IHaveRequest" "the caller's cursor per peer as protobuf JSON"
      , resp "IHaveResponse" "IHaveRequest" "message:IHaveResponse" "the greatest visible_dt in the peer's feed, from the (visible_dt) index"
      , http "RecordsRequest" "GET" "/peer/records" "message:RecordsRequest" "shard, after and limit are bounded unsigned query parameters"
      , resp "RecordsResponse" "RecordsRequest" "proof:Records are immutable between shards"
          "page from the (visible_dt) index past after, leaving out records whose shard is the caller; each record carries this shard's visible_dt, which the receiver uses only as its cursor"
      , http "BlobRequest" "GET" "/peer/blobs/{sha256}" "property:Imports resume" "sha256 is a hex path parameter; Range selects the bytes still missing"
      , resp "BlobResponse" "BlobRequest" "proof:A visible record has its blob" "206 with Content-Range; the lane appends to a part file, verifies sha256 when complete, then hands the record to the writer"
      , resp "BlobMissing" "BlobRequest" "message:BlobMissing" "404"
      , { message := "JobRequest", wireType := "islanduploads.JobRequest", transport := .inProcessChannel "jobs"
        , justifications := why "property:Jobs run where the blob was created" "Enqueued by the writer only after a local upload or update stores its blob; imports never enqueue." }
      , { message := "JobResult", wireType := "islanduploads.JobResult", transport := .inProcessChannel "job-results"
        , justifications := why "message:JobResult" "The writer stores each output as a new file, parent = source id, name = source name + \"-\" + output name." }
      , { message := "JobFailed", wireType := "islanduploads.JobFailed", transport := .inProcessChannel "job-results"
        , justifications := why "message:JobFailed" "Retried with exponential backoff up to one hour." }
      , { message := "PeerTimedOut", wireType := "trace.Event", transport := .custom "derived" "emitted by the caller when a peer call passes its 2 s deadline"
        , justifications := why "proof:Islands may be partitioned for a day" "A partition is observed as deadlines passing; writes continue and the timer retries." } ]
  , channels :=
      { sendFunction := "shard.Writer.Submit"
      , receiveFunction := "shard.Writer.next"
      , tryReceiveFunction := "select with default on the writer queue"
      , closeFunction := "shard.Writer.Close"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
      , justifications := why "proof:No feed skips" "One writer queue orders every commit, so visible_dt is assigned in commit order." } }

def validationReport : String := implementationValidationReport Project.Requirements.requirements implementation

end Project.Implementation
