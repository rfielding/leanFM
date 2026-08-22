import LeanFM.Artifacts

namespace LeanFM.GeneratedArtifacts

def msg (name src dst : String) (bytes : List Nat) (fields : List String) : LeanFM.MessageSchema :=
  { name, src, dst, bytes, fields }

def state (id label group markdown : String) (terminal : Bool := false) : LeanFM.RequirementState :=
  { id, label, group, markdown, terminal }

def tr (src dst message : String) (probabilityNum probabilityDen dwellMs : Nat) : LeanFM.RequirementTransition :=
  { src, dst, message, probabilityNum, probabilityDen, dwellMs }

def getDocsTask : LeanFM.TaskRequirement :=
  { id := "get_docs"
  , title := "get_docs task"
  , actors := ["Client", "Gateway", "Worker"]
  , initialState := "requested"
  , states :=
      [ state "requested" "GET /docs/index.html requested" "request accepted"
          "Client has sent an authenticated GET request to Gateway."
      , state "worker_fetching" "Worker fetching document" "worker running"
          "Gateway has queued a fetch command for Worker."
      , state "gateway_success" "Gateway has 200 result" "gateway decides"
          "Worker returned a visible 200 result to Gateway."
      , state "gateway_failure" "Gateway has 404 result" "gateway decides"
          "Worker returned a visible 404 result to Gateway."
      , state "client_success" "Client receives 200" "client response"
          "Gateway returns the successful response to Client."
      , state "client_rejected" "Client receives error" "client response"
          "Gateway returns an observable error response to Client."
      , state "done" "get_docs done" "terminal"
          "Task is complete and the active task instance is cleaned up." true
      , state "failed" "get_docs failed" "terminal"
          "Task is terminal on an observable failure response." true
      ]
  , transitions :=
      [ tr "requested" "worker_fetching" "Docs.FetchCommand" 1 1 2
      , tr "requested" "client_rejected" "Error.Response" 1 100 1
      , tr "worker_fetching" "gateway_success" "Docs.FetchResult200" 95 100 8
      , tr "worker_fetching" "gateway_failure" "Docs.FetchResult404" 5 100 8
      , tr "gateway_success" "client_success" "Docs.GetResponse" 1 1 2
      , tr "gateway_failure" "client_rejected" "Error.Response" 1 1 2
      , tr "client_success" "done" "Docs.GetResponse" 1 1 1
      , tr "client_rejected" "failed" "Error.Response" 1 1 1
      ]
  }

def postReviewTask : LeanFM.TaskRequirement :=
  { id := "post_review"
  , title := "post_review task"
  , actors := ["Client", "Gateway", "Worker"]
  , initialState := "submitted"
  , states :=
      [ state "submitted" "POST /reviews submitted" "request accepted"
          "Client has sent an authenticated review submission to Gateway."
      , state "moderating" "Worker moderating review" "worker running"
          "Gateway has queued moderation work for Worker."
      , state "accepted" "Gateway has accepted review" "gateway decides"
          "Worker accepted the submitted review."
      , state "rejected" "Gateway has rejected review" "gateway decides"
          "Worker rejected the submitted review."
      , state "client_posted" "Client receives 201" "client response"
          "Gateway returns a successful post response to Client."
      , state "client_rejected" "Client receives 400" "client response"
          "Gateway returns a visible rejection to Client."
      , state "done" "post_review done" "terminal"
          "Task is complete and the active task instance is cleaned up." true
      , state "failed" "post_review failed" "terminal"
          "Task is terminal on an observable rejection." true
      ]
  , transitions :=
      [ tr "submitted" "moderating" "Reviews.ModerateCommand" 1 1 3
      , tr "submitted" "client_rejected" "Reviews.PostResponse400" 1 100 1
      , tr "moderating" "accepted" "Reviews.ModerationAccepted" 90 100 10
      , tr "moderating" "rejected" "Reviews.ModerationRejected" 10 100 10
      , tr "accepted" "client_posted" "Reviews.PostResponse201" 1 1 2
      , tr "rejected" "client_rejected" "Reviews.PostResponse400" 1 1 2
      , tr "client_posted" "done" "Reviews.PostResponse201" 1 1 1
      , tr "client_rejected" "failed" "Reviews.PostResponse400" 1 1 1
      ]
  }

def workerRequirement : LeanFM.RequirementSpec :=
  { id := "worker.visible_behavior"
  , title := "Worker visible-behavior requirements"
  , actors := ["Client", "Gateway", "Worker"]
  , messages :=
      [ msg "Docs.GetRequest" "Client" "Gateway" [0x01, 0x10]
          ["method", "path", "auth_proof", "return_to"]
      , msg "Docs.FetchCommand" "Gateway" "Worker" [0x02, 0x20]
          ["path", "cache_mode", "return_to"]
      , msg "Docs.FetchResult200" "Worker" "Gateway" [0x03, 0x30]
          ["status", "path", "bytes_moved", "cpu_ms"]
      , msg "Docs.FetchResult404" "Worker" "Gateway" [0x03, 0xff]
          ["status", "path", "cpu_ms"]
      , msg "Docs.GetResponse" "Gateway" "Client" [0x04, 0x40]
          ["status", "path", "bytes_moved"]
      , msg "Error.Response" "Gateway" "Client" [0xff]
          ["status", "reason"]
      , msg "Reviews.PostRequest" "Client" "Gateway" [0x11, 0x10]
          ["method", "path", "auth_proof", "body_hash", "return_to"]
      , msg "Reviews.ModerateCommand" "Gateway" "Worker" [0x12, 0x20]
          ["body_hash", "policy", "return_to"]
      , msg "Reviews.ModerationAccepted" "Worker" "Gateway" [0x13, 0x30]
          ["decision", "body_hash", "cpu_ms"]
      , msg "Reviews.ModerationRejected" "Worker" "Gateway" [0x13, 0xff]
          ["decision", "body_hash", "cpu_ms"]
      , msg "Reviews.PostResponse201" "Gateway" "Client" [0x14, 0x40]
          ["status", "path", "review_id"]
      , msg "Reviews.PostResponse400" "Gateway" "Client" [0x14, 0xff]
          ["status", "path", "reason"]
      ]
  , tasks := [getDocsTask, postReviewTask]
  , properties :=
      [ { name := "AF get_docs terminal", mode := LeanFM.PropertyMode.eventually, task := "get_docs", expression := "terminal" }
      , { name := "AG no get_docs success without auth_proof", mode := LeanFM.PropertyMode.never, task := "get_docs", expression := "success && missing(auth_proof)" }
      , { name := "EF get_docs failure", mode := LeanFM.PropertyMode.eventually, task := "get_docs", expression := "failed" }
      , { name := "AF post_review terminal", mode := LeanFM.PropertyMode.eventually, task := "post_review", expression := "terminal" }
      , { name := "AG no post_review success without auth_proof", mode := LeanFM.PropertyMode.never, task := "post_review", expression := "success && missing(auth_proof)" }
      , { name := "EF post_review moderation rejection", mode := LeanFM.PropertyMode.eventually, task := "post_review", expression := "decision=rejected" }
      ]
  , charts :=
      [ { name := "latency by task", kind := LeanFM.ChartKind.xy, source := "messages", groupBy := some "task", value := "sum(dwellMs)" }
      , { name := "bytes by actor", kind := LeanFM.ChartKind.pie, source := "messages", groupBy := some "src", value := "sum(bytes_moved)" }
      , { name := "queue pressure", kind := LeanFM.ChartKind.xy, source := "messages", groupBy := some "dst", value := "queue_length" }
      ]
  , markdown :=
      [ { id := "overview", title := "Overview", body := "This generated requirement describes only visible messages, visible states, and properties over message fields." }
      , { id := "auth", title := "Authentication proof", body := "Both tasks require `auth_proof` on the initiating client message. Security properties forbid success traces where that field is absent." }
      ]
  }

def aggregateGraphData : LeanFM.AggregateGraphData :=
  LeanFM.requirementAggregateGraphData workerRequirement

def workerArtifact : LeanFM.GeneratedArtifact :=
  LeanFM.GeneratedArtifact.requirement workerRequirement

def all : List LeanFM.GeneratedArtifact :=
  [workerArtifact]

def validationReport : String :=
  LeanFM.generatedArtifactValidationReport all

end LeanFM.GeneratedArtifacts
