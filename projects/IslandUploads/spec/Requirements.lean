import LeanFM.Artifacts

open LeanFM

namespace Project.Requirements

/-!
# IslandUploads: observable requirements

People upload files on different islands. Every page shows its classification banner at the top
and the bottom, and every file its own label. Wherever people are, they see the same files, the
same latest versions and the same banners, once replication has caught up. Islands may be
partitioned for a day; every shard keeps accepting uploads and updates meanwhile, and nothing
waits for a quorum.

* A record is immutable between shards. It is identified by `(id, dt)`: `id` is the creation
  timestamp of the file's first version and `dt` the timestamp of this version, both in
  nanoseconds at the shard that wrote it (`shard`). An update is a new record with the same `id`,
  a later `dt`, and `prev_dts` naming the versions it was based on: one for an ordinary edit, more
  than one when it merges versions written concurrently on different islands.
* The latest version of a file is the record with the greatest `(dt, shard)` for its `id`. Every
  shard that holds the same records computes the same latest version, and every superseded
  version stays readable as history.
* `visible_dt` is local to a shard: the time the record became readable there, assigned when its
  write or import is committed and processed. It is not replicated; an importing shard ignores the sender's value and
  assigns its own. A browser pages through a shard's records by `visible_dt`.
* Shards replicate by anti-entropy over HTTP. A shard keeps one cursor per peer: how far up the
  peer's own `visible_dt` feed it has fully imported. It tells the peer that cursor
  (`IHaveRequest`, for example `{a: 50, b: 99}`); the peer answers how far its feed now reaches
  (`{a: 51-250, b: 99-355}`), and the caller pulls everything beyond its cursor in the peer's
  `visible_dt` order. Because the peer assigns `visible_dt` at commit through one writer, its feed
  never gains a record behind a value it has already served, so a cursor never skips one. Records
  the peer imported from a third shard come along, and no origin needs to commit in `dt` order.
  Records arrive any number of times and are stored once.
* Content moves in parts. An upload is started empty, appended to in parts, and finished; the
  file exists only once it is finished and its size and sha256 check out. A part that is lost or
  rejected is resent from the offset the shard reports, so proxies with body-size limits and
  dropped connections cost a part, not the file. Downloads and blob copies use byte ranges the
  same way, so an import cut off by a partition resumes where it stopped.
* A record from a peer is imported the way an upload is finished: the shard pulls its blob by
  ranges, and the record exists locally only once the blob is complete and verified. Imports run in
  128 lanes per shard: at most 128 imports run at once, and they finish in any order. Pulled
  records wait on disk for a lane and may lie far behind the cursor; a shard asks for more records
  only while fewer than 100000 are waiting. Large blobs (over 64 MiB) take at most 96 lanes; the
  other 32 are kept for small files, so a short file always opens a lane. An import that fails
  gives up its lane at once and waits out a backoff before it is queued again; when its turn comes
  it seeks to the offset it already holds and continues by range, so a file that keeps failing
  never monopolizes a lane. The peer's `visible_dt` and this shard's are different clocks: each
  import is given this shard's own `visible_dt` when it is committed, while the cursor is kept in
  the peer's clock, and advances only to the highest peer value below which every import is done.
  Imports finishing out of order hold it still; the one that completes the run moves it to the
  highest finished value at once;
  so a shard turned off during replication pulls again from its cursor and misses nothing, though
  a file may be sent again: delivery is at least once, and storing
  a record twice changes nothing. A visible record always has its blob, so a download never waits
  on another island.
* When a blob is created on a shard, by an upload or an update with content, that shard runs its
  jobs on it (AI labeling, text extraction, translation). Everything a job produces is an ordinary
  file: `plans.pdf-image-001.jpg`, `plans.pdf-english.txt`, `plans.pdf-celebrities.json`, each a
  new record whose parent is the source file. Job outputs replicate like any other file, so jobs
  never run on an imported blob and no island repeats another's work.
* Every read is governed by policy. A file `plans.pdf` is governed by the latest `plans.pdf.rego`
  in the same folder; a job output by its source's policy; a file with neither by the nearest
  folder's `.rego`. `Eval(jwt, rego)` over the caller's verified claims yields a decision such as
  `{read: true, write: false, banner: "SECRET//SQUIRREL", bg: "red", fg: "white"}`. `read` decides
  whether the caller can even tell the file exists: a file it may not read is answered exactly as
  a file that does not exist. `write` decides whether the caller may write a new version (for a
  new file, the folder's policy decides). The banner and colours are what the browser shows. No
  policy, an unverifiable token, or an evaluation error denies both. When a policy has concurrent versions (written on two islands, neither
  based on the other), access requires every concurrent version to allow it until a version based
  on all of them is written.
-/

def protoSource : String := include_str "Requirements.proto"

def framing (note : String) : MessageFraming := { kind := .protobufMessage, dispatchField := none, note }
def field (n : Nat) (name : String) (scalar : ProtoScalar) : ProtoFieldSchema := { number := n, name, scalar }
def message (name src dst note : String) (fields : List ProtoFieldSchema) : MessageSchema :=
  { name, src, dst, framing := framing note, fields }

def record (n : Nat) (name : String) : ProtoFieldSchema := field n name (.message "Record")
def records (n : Nat) : ProtoFieldSchema := field n "records" (.repeated (.message "Record"))

def messages : List MessageSchema :=
  [ message "UploadStart" "Browser" "Shard" "start an empty upload: a new file (id 0) or new content for id, based on prev_dts; request_id makes a retried start idempotent"
      [field 1 "request_id" .string, field 2 "parent_id" .uint64, field 3 "name" .string, field 4 "size" .uint64,
       field 5 "blob_sha256" .bytes, field 6 "id" .uint64, field 7 "prev_dts" (.repeated .uint64)]
  , message "UploadStarted" "Shard" "Browser" "the upload exists, empty, and expires if not finished within 24 hours"
      [field 1 "request_id" .string, field 2 "upload_id" .string, field 3 "offset" .uint64]
  , message "UploadPart" "Browser" "Shard" "append content at offset; a part fits under a proxy's body limit"
      [field 1 "upload_id" .string, field 2 "offset" .uint64, field 3 "content" .bytes]
  , message "UploadPartAck" "Shard" "Browser" "the part is durable; offset is where the next part starts"
      [field 1 "upload_id" .string, field 2 "offset" .uint64]
  , message "UploadFinish" "Browser" "Shard" "every part is sent; check size and sha256 and create the version"
      [field 1 "upload_id" .string]
  , message "UploadResponse" "Shard" "Browser" "the created record: version one of a new id, or a new version of id"
      [field 1 "request_id" .string, record 2 "record"]
  , message "UploadRejected" "Shard" "Browser" "409 with the offset the shard holds when a part does not start there; 422 when size or sha256 do not match at finish; 413, 400, or the policy denies write"
      [field 1 "upload_id" .string, field 2 "status" .uint32, field 3 "offset" .uint64, field 4 "reason" .string]
  , message "UpdateRequest" "Browser" "Shard" "a new version of id without new content (rename, delete), based on the versions in prev_dts (more than one merges concurrent versions)"
      [field 1 "request_id" .string, field 2 "id" .uint64, field 3 "prev_dts" (.repeated .uint64), field 4 "name" .string,
       field 5 "deleted" .bool]
  , message "UpdateResponse" "Shard" "Browser" "the new version; never refused because a prev_dts entry is not the latest"
      [field 1 "request_id" .string, record 2 "record"]
  , message "UpdateRejected" "Shard" "Browser" "404 when some (id, d) in prev_dts is not held here or the caller may not read the file; 403 when it may read but not write"
      [field 1 "request_id" .string, field 2 "reason" .string]
  , message "FeedRequest" "Browser" "Shard" "the next page after the last visible_dt the browser rendered"
      [field 1 "after_visible_dt" .uint64, field 2 "limit" .uint32]
  , message "FeedResponse" "Shard" "Browser" "records the caller may read, in visible_dt order, each with its decision; the cursor advances past records it may not"
      [records 1, field 2 "last_visible_dt" .uint64, field 3 "more" .bool, field 4 "decisions" (.repeated (.message "Decision")),
       field 5 "page_banner" (.message "Decision")]
  , message "RangeNotSatisfiable" "Shard" "Browser" "416 with the total size, for a range outside the blob"
      [field 1 "id" .uint64, field 2 "dt" .uint64, field 3 "total_size" .uint64]
  , message "AccessDenied" "Shard" "Browser" "401 for an unverifiable token; 404, identical to a missing file, when the governing policy denies read"
      [field 1 "status" .uint32, field 2 "reason" .string]
  , message "HistoryRequest" "Browser" "Shard" "every version of one file held by this shard"
      [field 1 "id" .uint64]
  , message "HistoryResponse" "Shard" "Browser" "versions in (dt, shard) order; the last is the latest"
      [field 1 "id" .uint64, records 2, field 3 "decision" (.message "Decision")]
  , message "DownloadRequest" "Browser" "Shard" "content of one version, whole or a byte range; browsers send ranges on their own (a video element seeking)"
      [field 1 "id" .uint64, field 2 "dt" .uint64, field 3 "range_start" .uint64, field 4 "range_end" .uint64]
  , message "DownloadResponse" "Shard" "Browser" "200 with the whole blob when no range is asked, 206 with exactly the requested range and the total size when one is; Accept-Ranges: bytes on both"
      [field 1 "id" .uint64, field 2 "dt" .uint64, field 3 "content" .bytes, field 4 "decision" (.message "Decision"),
       field 5 "range_start" .uint64, field 6 "total_size" .uint64]
  , message "IHaveRequest" "Shard" "Peer" "the caller's cursor into the peer's feed: the peer's visible_dt up to which every record is imported"
      [field 1 "shard" .string, field 2 "marks" (.repeated (.message "Mark"))]
  , message "IHaveResponse" "Peer" "Shard" "how far the peer's feed reaches beyond the caller's cursor"
      [field 1 "shard" .string, field 2 "marks" (.repeated (.message "Mark"))]
  , message "RecordsRequest" "Shard" "Peer" "the peer's records with visible_dt > after_visible_dt, in the peer's visible_dt order, leaving out records whose origin is the caller"
      [field 1 "shard" .string, field 2 "after_visible_dt" .uint64, field 3 "limit" .uint32]
  , message "RecordsResponse" "Peer" "Shard" "a page of the peer's feed; each record's visible_dt is the peer's, used only as the caller's cursor and never stored as the caller's own"
      [field 1 "shard" .string, records 2, field 3 "last_visible_dt" .uint64, field 4 "more" .bool]
  , message "BlobRequest" "Shard" "Peer" "a byte range of content by hash, to import a record; an import resumes at the offset already held"
      [field 1 "blob_sha256" .bytes, field 2 "urgent" .bool, field 3 "offset" .uint64, field 4 "length" .uint64]
  , message "BlobResponse" "Peer" "Shard" "the requested range; the import is verified against blob_sha256 when complete"
      [field 1 "blob_sha256" .bytes, field 2 "content" .bytes, field 3 "offset" .uint64, field 4 "total_size" .uint64]
  , message "BlobMissing" "Peer" "Shard" "the peer does not hold this blob"
      [field 1 "blob_sha256" .bytes]
  , message "PeerTimedOut" "Shard" "Shard" "derived at the caller: a peer call passed its deadline (partition or overload)"
      [field 1 "peer" .string, field 2 "call" .string]
  , message "JobRequest" "Shard" "Worker" "run one job on a blob just created on this shard"
      [field 1 "id" .uint64, field 2 "dt" .uint64, field 3 "job" .string, field 4 "blob_sha256" .bytes]
  , message "JobResult" "Worker" "Shard" "output files; the shard stores each as a new file whose parent is the source"
      [field 1 "id" .uint64, field 2 "dt" .uint64, field 3 "job" .string, field 4 "outputs" (.repeated (.message "Output"))]
  , message "JobFailed" "Worker" "Shard" "the job could not run; it is retried with backoff"
      [field 1 "id" .uint64, field 2 "dt" .uint64, field 3 "job" .string, field 4 "reason" .string] ]

/-! ## Tasks -/

def st (id label group : String) (terminal : Bool := false) : RequirementState :=
  { id, label, group, markdown := label, terminal }
def tr (src dst msg : String) (num den : Nat := 1) (ms : Nat := 1) : RequirementTransition :=
  { src, dst, message := msg, probabilityNum := num, probabilityDen := den, dwellMs := ms }

def uploadTask : TaskRequirement :=
  { id := "upload", title := "Upload content in parts", actors := ["Browser", "Shard"], initialState := "ready"
  , states := [st "ready" "file chosen" "browser", st "requested" "upload start received" "shard",
               st "open" "upload open at an offset" "browser", st "sending" "part in flight" "shard",
               st "finishing" "finish received; checking size and sha256" "shard",
               st "stored" "record and blob stored" "terminal" true, st "rejected" "upload refused" "terminal" true]
  , transitions := [tr "ready" "requested" "UploadStart",
                    tr "requested" "open" "UploadStarted" 99 100 5, tr "requested" "rejected" "UploadRejected" 1 100 1,
                    tr "open" "sending" "UploadPart" 1 2 1,
                    tr "sending" "open" "UploadPartAck" 98 100 50, tr "sending" "open" "UploadRejected" 2 100 1,
                    tr "open" "finishing" "UploadFinish" 1 2 1,
                    tr "finishing" "stored" "UploadResponse" 99 100 50, tr "finishing" "rejected" "UploadRejected" 1 100 1] }

def updateTask : TaskRequirement :=
  { id := "update", title := "Write a new version", actors := ["Browser", "Shard"], initialState := "ready"
  , states := [st "ready" "editing a version" "browser", st "requested" "update received" "shard",
               st "stored" "new version stored" "terminal" true, st "rejected" "unknown base version" "terminal" true]
  , transitions := [tr "ready" "requested" "UpdateRequest", tr "requested" "stored" "UpdateResponse" 99 100 10,
                    tr "requested" "rejected" "UpdateRejected" 1 100 1] }

def feedTask : TaskRequirement :=
  { id := "feed", title := "Page through what this shard can show", actors := ["Browser", "Shard"], initialState := "ready"
  , states := [st "ready" "cursor at last visible_dt" "browser", st "requested" "page requested" "shard",
               st "rendered" "page rendered, cursor advanced" "terminal" true]
               ++ [st "denied" "token rejected" "terminal" true]
  , transitions := [tr "ready" "requested" "FeedRequest", tr "requested" "rendered" "FeedResponse" 99 100 5,
                    tr "requested" "denied" "AccessDenied" 1 100 1] }

def historyTask : TaskRequirement :=
  { id := "history", title := "Read every version of a file", actors := ["Browser", "Shard"], initialState := "ready"
  , states := [st "ready" "file selected" "browser", st "requested" "history requested" "shard",
               st "rendered" "versions rendered" "terminal" true]
               ++ [st "denied" "token rejected or policy denies" "terminal" true]
  , transitions := [tr "ready" "requested" "HistoryRequest", tr "requested" "rendered" "HistoryResponse" 98 100 5,
                    tr "requested" "denied" "AccessDenied" 2 100 1] }

def downloadTask : TaskRequirement :=
  { id := "download", title := "Download one version", actors := ["Browser", "Shard"], initialState := "ready"
  , states := [st "ready" "version selected" "browser", st "requested" "download requested" "shard",
               st "served" "content or range served" "terminal" true,
               st "unsatisfiable" "range outside the blob" "terminal" true,
               st "denied" "token rejected, or the file is hidden or absent" "terminal" true]
  , transitions := [tr "ready" "requested" "DownloadRequest",
                    tr "requested" "served" "DownloadResponse" 98 100 10,
                    tr "requested" "unsatisfiable" "RangeNotSatisfiable" 1 100 1,
                    tr "requested" "denied" "AccessDenied" 1 100 1] }

def replicateTask : TaskRequirement :=
  { id := "replicate", title := "Record anti-entropy with one peer", actors := ["Shard", "Peer"], initialState := "idle"
  , states := [st "idle" "timer fired" "shard", st "asked" "cursor sent" "peer",
               st "known" "peer's holdings known" "shard", st "pulling" "page requested" "peer",
               st "done" "caught up on records" "terminal" true,
               st "unreachable" "peer did not answer; retry on the next timer" "terminal" true]
  , transitions := [tr "idle" "asked" "IHaveRequest", tr "asked" "known" "IHaveResponse" 9 10 50,
                    tr "asked" "unreachable" "PeerTimedOut" 1 10 2000,
                    tr "known" "pulling" "RecordsRequest" 1 2,
                    tr "pulling" "known" "RecordsResponse" 9 10 50, tr "pulling" "unreachable" "PeerTimedOut" 1 10 2000,
                    tr "known" "done" "IHaveRequest" 1 2 1] }

def importTask : TaskRequirement :=
  { id := "import", title := "Import one record with its blob", actors := ["Shard", "Peer"], initialState := "queued"
  , states := [st "queued" "record pulled, waiting for a lane" "shard",
               st "fetching" "range requested" "peer",
               st "imported" "blob verified; record visible here" "terminal" true,
               st "deferred" "peer missing or unreachable; back in the queue at the offset held" "terminal" true]
  , transitions := [tr "queued" "fetching" "BlobRequest" 1 1 10,
                    tr "fetching" "fetching" "BlobResponse" 1 2 200,
                    tr "fetching" "imported" "BlobResponse" 4 10 200,
                    tr "fetching" "deferred" "BlobMissing" 1 20 50,
                    tr "fetching" "deferred" "PeerTimedOut" 1 20 2000] }

def deriveTask : TaskRequirement :=
  { id := "derive", title := "Run jobs on a blob created here", actors := ["Shard", "Worker"], initialState := "created"
  , states := [st "created" "blob created on this shard" "shard", st "running" "job running" "worker",
               st "derived" "output files stored" "terminal" true,
               st "failed" "job failed; retried with backoff" "terminal" true]
  , transitions := [tr "created" "running" "JobRequest", tr "running" "derived" "JobResult" 95 100 5000,
                    tr "running" "failed" "JobFailed" 5 100 1000] }

def tasks : List TaskRequirement := [uploadTask, updateTask, feedTask, historyTask, downloadTask, replicateTask, importTask, deriveTask]

/-! ## Grammars -/

def ev (task src dst msg : String) : GrammarExpr := .event { task, src, dst, message := msg }
def bs (task req res : String) : GrammarExpr := ev task "Browser" "Shard" req >>> ev task "Shard" "Browser" res
def sp (task msg : String) : GrammarExpr := ev task "Shard" "Peer" msg
def ps (task msg : String) : GrammarExpr := ev task "Peer" "Shard" msg
def timedOut (task : String) : GrammarExpr := ev task "Shard" "Shard" "PeerTimedOut"

def grammars : List TaskGrammar :=
  [ { task := "upload", entry := "ready", terminals := ["stored", "rejected"]
    , body := ev "upload" "Browser" "Shard" "UploadStart" >>>
        GrammarExpr.alt
          [ ev "upload" "Shard" "Browser" "UploadRejected"
          , ev "upload" "Shard" "Browser" "UploadStarted" >>>
              GrammarExpr.star (ev "upload" "Browser" "Shard" "UploadPart" >>>
                GrammarExpr.alt [ev "upload" "Shard" "Browser" "UploadPartAck", ev "upload" "Shard" "Browser" "UploadRejected"]) >>>
              ev "upload" "Browser" "Shard" "UploadFinish" >>>
              GrammarExpr.alt [ev "upload" "Shard" "Browser" "UploadResponse", ev "upload" "Shard" "Browser" "UploadRejected"] ] }
  , { task := "update", entry := "ready", terminals := ["stored", "rejected"]
    , body := ev "update" "Browser" "Shard" "UpdateRequest" >>>
        GrammarExpr.alt [ev "update" "Shard" "Browser" "UpdateResponse", ev "update" "Shard" "Browser" "UpdateRejected"] }
  , { task := "feed", entry := "ready", terminals := ["rendered", "denied"]
    , body := ev "feed" "Browser" "Shard" "FeedRequest" >>>
        GrammarExpr.alt [ev "feed" "Shard" "Browser" "FeedResponse", ev "feed" "Shard" "Browser" "AccessDenied"] }
  , { task := "history", entry := "ready", terminals := ["rendered", "denied"]
    , body := ev "history" "Browser" "Shard" "HistoryRequest" >>>
        GrammarExpr.alt [ev "history" "Shard" "Browser" "HistoryResponse", ev "history" "Shard" "Browser" "AccessDenied"] }
  , { task := "download", entry := "ready", terminals := ["served", "unsatisfiable", "denied"]
    , body := ev "download" "Browser" "Shard" "DownloadRequest" >>>
        GrammarExpr.alt [ev "download" "Shard" "Browser" "DownloadResponse", ev "download" "Shard" "Browser" "RangeNotSatisfiable",
                         ev "download" "Shard" "Browser" "AccessDenied"] }
  , { task := "replicate", entry := "idle", terminals := ["done", "unreachable"]
    , body := sp "replicate" "IHaveRequest" >>>
        GrammarExpr.alt
          [ timedOut "replicate"
          , ps "replicate" "IHaveResponse" >>>
              GrammarExpr.star (sp "replicate" "RecordsRequest" >>>
                GrammarExpr.alt [ps "replicate" "RecordsResponse", timedOut "replicate"]) ] }
  , { task := "import", entry := "queued", terminals := ["imported", "deferred"]
    , body := GrammarExpr.plus (sp "import" "BlobRequest" >>> GrammarExpr.alt [ps "import" "BlobResponse", ps "import" "BlobMissing", timedOut "import"]) }
  , { task := "derive", entry := "created", terminals := ["derived", "failed"]
    , body := ev "derive" "Shard" "Worker" "JobRequest" >>>
        GrammarExpr.alt [ev "derive" "Worker" "Shard" "JobResult", ev "derive" "Worker" "Shard" "JobFailed"] } ]

/-! ## Actor projections -/

def statesOf (t : TaskRequirement) : List String := t.states.map (·.id)
def proc (actor : String) (t : TaskRequirement) (sends receives : List String) : RequirementProcess :=
  { actor, task := t.id, states := statesOf t, sends, receives }

def processes : List RequirementProcess :=
  [ proc "Browser" uploadTask ["UploadStart", "UploadPart", "UploadFinish"] ["UploadStarted", "UploadPartAck", "UploadResponse", "UploadRejected"]
  , proc "Shard" uploadTask ["UploadStarted", "UploadPartAck", "UploadResponse", "UploadRejected"] ["UploadStart", "UploadPart", "UploadFinish"]
  , proc "Browser" updateTask ["UpdateRequest"] ["UpdateResponse", "UpdateRejected"]
  , proc "Shard" updateTask ["UpdateResponse", "UpdateRejected"] ["UpdateRequest"]
  , proc "Browser" feedTask ["FeedRequest"] ["FeedResponse", "AccessDenied"]
  , proc "Shard" feedTask ["FeedResponse", "AccessDenied"] ["FeedRequest"]
  , proc "Browser" historyTask ["HistoryRequest"] ["HistoryResponse", "AccessDenied"]
  , proc "Shard" historyTask ["HistoryResponse", "AccessDenied"] ["HistoryRequest"]
  , proc "Browser" downloadTask ["DownloadRequest"] ["DownloadResponse", "RangeNotSatisfiable", "AccessDenied"]
  , proc "Shard" downloadTask ["DownloadResponse", "RangeNotSatisfiable", "AccessDenied"] ["DownloadRequest"]
  , proc "Shard" replicateTask ["IHaveRequest", "RecordsRequest", "PeerTimedOut"] ["IHaveResponse", "RecordsResponse", "PeerTimedOut"]
  , proc "Peer" replicateTask ["IHaveResponse", "RecordsResponse"] ["IHaveRequest", "RecordsRequest"]
  , proc "Shard" importTask ["BlobRequest", "PeerTimedOut"] ["BlobResponse", "BlobMissing", "PeerTimedOut"]
  , proc "Peer" importTask ["BlobResponse", "BlobMissing"] ["BlobRequest"]
  , proc "Shard" deriveTask ["JobRequest"] ["JobResult", "JobFailed"]
  , proc "Worker" deriveTask ["JobResult", "JobFailed"] ["JobRequest"] ]

/-! ## Properties and proof obligations -/

def one : Probability := { numerator := 1, denominator := 1 }
def zero : Probability := { numerator := 0, denominator := 1 }

def properties : List RequirementProperty :=
  [ { name := "Writes never wait for another island", mode := .always, task := "upload"
    , expression := "every UploadStart, UploadPart and UploadFinish is answered by this shard with no Shard-to-Peer message caused by it", probability := some one }
  , { name := "Parts resume", mode := .always, task := "upload"
    , expression := "an UploadRejected for a part names the offset the shard holds, and parts sent from that offset complete the upload", probability := some one }
  , { name := "Ranges are exact", mode := .always, task := "download"
    , expression := "a DownloadResponse for a range carries exactly bytes [range_start, range_end) of the blob and its total_size", probability := some one }
  , { name := "Ranges are always honoured", mode := .always, task := "download"
    , expression := "a DownloadRequest with a satisfiable range, asked for or not by the user, is answered 206; one without a range 200; both say Accept-Ranges: bytes; HEAD answers the same headers without a body", probability := some one }
  , { name := "Updates are never refused for being stale", mode := .never, task := "update"
    , expression := "UpdateRejected when this shard holds every (id, d) in prev_dts", probability := some zero }
  , { name := "Latest is a function of the records", mode := .always, task := "history"
    , expression := "the last version in HistoryResponse has the greatest (dt, shard) among the records returned", probability := some one }
  , { name := "Feed pages are complete", mode := .always, task := "feed"
    , expression := "a browser that starts at after_visible_dt = 0 and follows last_visible_dt receives every record this shard holds that its token may read, each at least once", probability := some one }
  , { name := "Every shown file carries its label", mode := .always, task := "feed"
    , expression := "every record in FeedResponse has the decision Eval(jwt, governing rego) for this caller, with read = true", probability := some one }
  , { name := "The page banner is the most restrictive shown", mode := .always, task := "feed"
    , expression := "page_banner is the decision of greatest rank in the same FeedResponse, and the page shows it at the top and the bottom", probability := some one }
  , { name := "Writes need write", mode := .always, task := "update"
    , expression := "an UpdateResponse or an UploadResponse for an existing id follows only a request whose caller the file's governing policy gives write = true; an UploadResponse for a new file only one the folder's policy gives write = true", probability := some one }
  , { name := "Same view everywhere after replication", mode := .always, task := "feed"
    , expression := "two shards holding the same records answer the same token with the same readable files, the same latest version of each, and the same decisions", probability := some one }
  , { name := "Anti-entropy is idempotent", mode := .always, task := "replicate"
    , expression := "a RecordsResponse delivered twice, or in any order, leaves the same records on the receiving shard", probability := some one }
  , { name := "Converge after repair", mode := .eventually, task := "replicate"
    , expression := "once peers answer each other, every record held by any shard is held by every shard", probability := some one }
  , { name := "Imports resume", mode := .always, task := "import"
    , expression := "after a PeerTimedOut, the next BlobRequest for that blob starts at the offset already held", probability := some one }
  , { name := "Imports are bounded", mode := .always, task := "import"
    , expression := "at most 128 imports from one shard are in flight, at most 96 of them for blobs over 64 MiB, and a RecordsRequest is sent only while fewer than 100000 pulled records wait for a lane", probability := some one }
  , { name := "A failing import yields its lane", mode := .always, task := "import"
    , expression := "after a PeerTimedOut, BlobMissing or failed verification, the import releases its lane and is queued again only after a backoff of 1 s doubling to 10 min; it resumes at the offset already held", probability := some one }
  , { name := "Other imports progress while one fails", mode := .eventually, task := "import"
    , expression := "while some imports keep failing, every queued import that can succeed starts and finishes", probability := some one }
  , { name := "Short files always open a lane", mode := .always, task := "import"
    , expression := "a queued import of a blob of at most 64 MiB starts before any running import of a larger blob finishes", probability := some one }
  , { name := "The cursor jumps when the run completes", mode := .always, task := "import"
    , expression := "when the import of the lowest unfinished record of a peer's feed commits, the cursor for that peer moves in the same commit to the highest peer visible_dt below which every pulled record is imported; no other commit moves it", probability := some one }
  , { name := "Delivery is at least once", mode := .always, task := "replicate"
    , expression := "a record may be delivered to a shard more than once, after a restart or a lost response; storing it again changes nothing visible", probability := some one }
  , { name := "Every record is eventually imported", mode := .eventually, task := "import"
    , expression := "once peers answer each other, every record held by any shard is imported, with its blob, by every shard", probability := some one }
  , { name := "Jobs run where the blob was created", mode := .always, task := "derive"
    , expression := "every JobRequest follows an UploadResponse or UpdateResponse with content on the same shard, for that record", probability := some one } ]

def requiredProofs : List RequiredProof :=
  [ { name := "A file exists only when complete", mode := .never, task := "upload"
    , predicate := "a record for an upload is visible (feed, history, replication) before UploadFinish found its size and sha256 correct", probability := some zero }
  , { name := "Records are immutable between shards", mode := .never, task := "replicate"
    , predicate := "two messages carry a Record with the same (id, dt) and different replicated fields", probability := some zero }
  , { name := "Cursors are prefixes", mode := .always, task := "replicate"
    , predicate := "for every shard S and peer P, S holds every record of P's feed with P's visible_dt at most S's cursor for P", probability := some one }
  , { name := "History is never lost", mode := .never, task := "history"
    , predicate := "a version once returned by UploadResponse, UpdateResponse or RecordsResponse is missing from a later HistoryResponse of a shard that held it", probability := some zero }
  , { name := "No feed skips", mode := .never, task := "feed"
    , predicate := "a record becomes visible on a shard with visible_dt at most a last_visible_dt that shard already returned", probability := some zero }
  , { name := "A visible record has its blob", mode := .never, task := "import"
    , predicate := "a record is visible on a shard (feed, history, download, replication to others) before its blob is complete and verified there", probability := some zero }
  , { name := "Cursors advance over finished prefixes", mode := .never, task := "import"
    , predicate := "a shard's cursor for a peer passes a record of that peer's feed it has not finished importing", probability := some zero }
  , { name := "Jobs never run on imports", mode := .never, task := "derive"
    , predicate := "JobRequest on a shard for a record whose origin shard is another shard", probability := some zero }
  , { name := "Nothing is shown that policy denies", mode := .never, task := "download"
    , predicate := "a record, its blob, or a job output reaches a caller whose verified token the governing policy denies", probability := some zero }
  , { name := "Hidden files do not exist", mode := .never, task := "download"
    , predicate := "a caller with read = false can tell the file exists: a status, body or header different from a missing file's", probability := some zero }
  , { name := "Job outputs are governed by their source", mode := .never, task := "feed"
    , predicate := "a job output is readable by a token that its source's policy denies", probability := some zero }
  , { name := "Unverifiable tokens are denied", mode := .always, task := "feed"
    , predicate := "a request whose JWT signature, issuer, audience or expiry does not verify is answered by AccessDenied with status 401", probability := some one }
  , { name := "Concurrent policies are combined, not overwritten", mode := .never, task := "feed"
    , predicate := "a shard lets a caller read a file while it holds a concurrent version of the governing policy that denies that caller", probability := some zero }
  , { name := "Islands may be partitioned for a day", mode := .possibly, task := "replicate"
    , predicate := "PeerTimedOut on every call between two islands for 24 hours", probability := some { numerator := 1, denominator := 365 }
    , handlingPlan := some "Keep accepting uploads and updates on both sides and running jobs on blobs created there. Retry anti-entropy on its timer. On repair import records with their blobs in 128 lanes, asking for more records only while fewer than 100000 wait for a lane; the latest version per id is the greatest (dt, shard), and every superseded version stays in history." } ]

/-! ## Populations, resources, performance and views -/

def actors : List String := ["Browser", "Shard", "Peer", "Worker"]

def requirements : RequirementSpec :=
  { id := "island_uploads.visible_behavior", title := "File uploads across partitionable islands", actors
  , actorPopulations :=
      [ { actorSpec := "Browser", instancePrefix := "browser-", count := 2, routing := .sticky "session" }
      , { actorSpec := "Shard", instancePrefix := "shard-", count := 2, routing := .sticky "island" }
      , { actorSpec := "Peer", instancePrefix := "peer-", count := 2, routing := .sticky "peer" }
      , { actorSpec := "Worker", instancePrefix := "worker-", count := 2, routing := .sticky "shard" } ]
  , actorResources :=
      [ { actor := "Browser", inboundCapacity := 8, outboundCapacity := 8, maxInFlight := 4, memoryBudgetBytes := 16777216 }
      , { actor := "Shard", inboundCapacity := 256, outboundCapacity := 256, maxInFlight := 64, memoryBudgetBytes := 268435456 }
      , { actor := "Peer", inboundCapacity := 64, outboundCapacity := 64, maxInFlight := 8, memoryBudgetBytes := 134217728 }
      , { actor := "Worker", inboundCapacity := 32, outboundCapacity := 32, maxInFlight := 2, memoryBudgetBytes := 1073741824 } ]
  , actorReliability :=
      [ { actor := "Browser", outageProbability := zero, meanTimeToRepairMs := 0 }
      , { actor := "Shard", outageProbability := { numerator := 1, denominator := 1000 }, meanTimeToRepairMs := 60000 }
      , { actor := "Peer", outageProbability := { numerator := 1, denominator := 365 }, meanTimeToRepairMs := 86400000 }
      , { actor := "Worker", outageProbability := { numerator := 1, denominator := 100 }, meanTimeToRepairMs := 600000 } ]
  , reliabilityGates :=
      [ { id := "own_shard", members := ["shard-1"], requiredCount := 1, affectedTasks := ["upload", "update", "feed", "history"] } ]
  , actorCosts := [], messages, tasks, grammars, processes, properties, requiredProofs
  , performance :=
      [ { name := "uploads accepted per shard", task := "upload", metric := .serverAggregateRate, workField := "records", minimumWork := 50, perMilliseconds := 1000 } ]
  , charts :=
      [ { name := "replication lag by peer", kind := .xy, source := "IHaveResponse feed reach against the local cursor", groupBy := some "peer", value := "lag_ms" }
      , { name := "import backlog", kind := .xy, source := "import task BlobRequest and BlobResponse events", groupBy := some "peer", value := "queued_imports" } ]
  , desiredOutputs :=
      [ { id := "uploads.interaction", prompt := "Model the file uploads server across islands.", question := "Which messages carry an upload, an update, a feed page and one anti-entropy round?", kind := .interactionDiagram, eventSource := "upload, update, feed and replicate grammars", reducer := "render each task's grammar", unit := "messages per task" }
      , { id := "uploads.replicate.states", prompt := "You tell me how far up you are on replication, and I give you everything you have not seen.", question := "Which states can one anti-entropy round reach, including an unreachable peer?", kind := .stateMachine, eventSource := "replicate task", reducer := "render the task states and transitions", unit := "states per round" }
      , { id := "uploads.lag", prompt := "We did not need strong consistency across islands.", question := "How far behind each peer's feed is each shard, over time, through a partition and its repair?", kind := .function2d, eventSource := "IHaveRequest cursors and IHaveResponse feed reach per peer", reducer := "peer feed reach minus local cursor per peer, as visible_dt nanoseconds converted to ms", unit := "milliseconds behind, per peer, over time" }
      , { id := "uploads.import.backlog", prompt := "Pull the blob in a task that makes the record exist; bounded concurrency, say 128 lanes, handles incredible bursts.", question := "How long is each shard's import queue, and how many lanes are busy, over time through a partition and its repair?", kind := .function2d, eventSource := "import task events and RecordsResponse records", reducer := "records pulled but not yet imported, and BlobRequests in flight, per peer, sampled each second", unit := "records and lanes over time" }
      , { id := "uploads.partition.verdicts", prompt := "When there is a partition, just allow everyone to keep writing.", question := "Do the shards converge after repair, does the feed skip records, and which commit orders break it?", kind := .scalar, eventSource := "the MCP-checked models in spec/Islands.lean", reducer := "check_ctl verdicts with evidence", unit := "verdicts" } ]
  , markdown :=
      [ { id := "identity", title := "Identity and latest", body := "A record is identified by (id, dt), nanoseconds at its origin shard; it never changes after it is written. The latest version of id is the record with the greatest (dt, shard). Updates carry prev_dts; a superseded version is history, never deleted. Versions of one id are concurrent when neither is reachable from the other through prev_dts." }
      , { id := "visible", title := "Local visibility", body := "visible_dt is the time a record became readable on one shard. It is assigned by that shard when a write or an import is committed and processed, strictly increasing in the order records become readable, and is never replicated." }
      , { id := "derived", title := "Job outputs are files", body := "A job's outputs are new files named after the source (plans.pdf-image-001.jpg, plans.pdf-english.txt, plans.pdf-celebrities.json) whose parent is the source file. They are created on the shard that created the source blob and replicate like any other file." }
      , { id := "partition", title := "Partitions", body := "Islands may be cut off from each other for a day. Both sides keep accepting writes and running jobs; anti-entropy retries on a timer, and on repair records are imported with their blobs in bounded lanes." }
      , { id := "view", title := "What people see", body := "A page lists the files the caller may read, each with its banner, under a page banner at the top and the bottom: the decision of greatest rank on the page. Decisions are computed from the records and the caller's token alone, so two shards that hold the same records show the same page." }
      , { id := "policy", title := "Policy and labels", body := "plans.pdf is governed by the latest plans.pdf.rego in its folder, a job output by its source's policy, otherwise by the nearest folder .rego. Eval(jwt, rego) returns {read, write, banner, bg, fg, rank}. read = false hides the file entirely: it is answered as missing. write gates new versions; a new file needs write from its folder's policy, and a .rego is written under the policy that governs it. Missing policy, unverifiable token, or evaluation error: deny both. Concurrent policy versions (neither in the other's prev chain) must all allow until a version based on all of them is written." }
      , { id := "roles", title := "Roles and processes", body := "Shard and Peer are two roles of one process: shard-N calls its peers as Shard and answers them as peer-N. Worker-N runs the jobs of shard-N." }
      , { id := "bounds", title := "Bounds", body := "Uploads are at most 64 GiB, sent in parts of at most 8 MiB; an upload not finished within 24 hours is deleted. Names are 1..255 UTF-8 bytes. Feed and record pages hold at most 500 records. Imports run in 128 lanes per shard, at most 96 for blobs over 64 MiB, with up to 100000 pulled records waiting on disk." } ] }

def validationReport : String :=
  match validateRequirementSpec requirements with
  | [] => "ok: IslandUploads requirements are well formed\n"
  | es => "invalid IslandUploads requirements\n" ++ joinWithNewline es ++ "\n"

end Project.Requirements
