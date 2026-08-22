import LeanFM.Artifacts

namespace LeanFM.GeneratedArtifacts

def getDocsTask : LeanFM.TaskRequirement :=
  { id := "get_docs"
  , title := "get_docs task"
  , actors := ["Client", "Gateway", "Worker"]
  , initialState := "requested"
  , states :=
      [ { id := "requested"
        , label := "GET /docs/index.html requested"
        , group := "request accepted"
        , markdown := "Client has sent an authenticated GET request to Gateway."
        , terminal := false
        }
      , { id := "worker_fetching"
        , label := "Worker fetching document"
        , group := "worker running"
        , markdown := "Gateway has queued a fetch command for Worker."
        , terminal := false
        }
      , { id := "gateway_success"
        , label := "Gateway has 200 result"
        , group := "gateway decides"
        , markdown := "Worker returned a visible 200 result to Gateway."
        , terminal := false
        }
      , { id := "gateway_failure"
        , label := "Gateway has 404 result"
        , group := "gateway decides"
        , markdown := "Worker returned a visible 404 result to Gateway."
        , terminal := false
        }
      , { id := "client_success"
        , label := "Client receives 200"
        , group := "client response"
        , markdown := "Gateway returns the successful response to Client."
        , terminal := false
        }
      , { id := "client_rejected"
        , label := "Client receives error"
        , group := "client response"
        , markdown := "Gateway returns an observable error response to Client."
        , terminal := false
        }
      , { id := "done"
        , label := "get_docs done"
        , group := "terminal"
        , markdown := "Task is complete and the active task instance is cleaned up."
        , terminal := true
        }
      , { id := "failed"
        , label := "get_docs failed"
        , group := "terminal"
        , markdown := "Task is terminal on an observable failure response."
        , terminal := true
        }
      ]
  , transitions :=
      [ { src := "requested"
        , dst := "worker_fetching"
        , message := "Docs.FetchCommand"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := "requested"
        , dst := "client_rejected"
        , message := "Error.Response"
        , probabilityNum := 1
        , probabilityDen := 100
        , dwellMs := 1
        }
      , { src := "worker_fetching"
        , dst := "gateway_success"
        , message := "Docs.FetchResult200"
        , probabilityNum := 95
        , probabilityDen := 100
        , dwellMs := 8
        }
      , { src := "worker_fetching"
        , dst := "gateway_failure"
        , message := "Docs.FetchResult404"
        , probabilityNum := 5
        , probabilityDen := 100
        , dwellMs := 8
        }
      , { src := "gateway_success"
        , dst := "client_success"
        , message := "Docs.GetResponse"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := "gateway_failure"
        , dst := "client_rejected"
        , message := "Error.Response"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := "client_success"
        , dst := "done"
        , message := "Docs.GetResponse"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := "client_rejected"
        , dst := "failed"
        , message := "Error.Response"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      ]
  }

def postReviewTask : LeanFM.TaskRequirement :=
  { id := "post_review"
  , title := "post_review task"
  , actors := ["Client", "Gateway", "Worker"]
  , initialState := "submitted"
  , states :=
      [ { id := "submitted"
        , label := "POST /reviews submitted"
        , group := "request accepted"
        , markdown := "Client has sent an authenticated review submission to Gateway."
        , terminal := false
        }
      , { id := "moderating"
        , label := "Worker moderating review"
        , group := "worker running"
        , markdown := "Gateway has queued moderation work for Worker."
        , terminal := false
        }
      , { id := "accepted"
        , label := "Gateway has accepted review"
        , group := "gateway decides"
        , markdown := "Worker accepted the submitted review."
        , terminal := false
        }
      , { id := "rejected"
        , label := "Gateway has rejected review"
        , group := "gateway decides"
        , markdown := "Worker rejected the submitted review."
        , terminal := false
        }
      , { id := "client_posted"
        , label := "Client receives 201"
        , group := "client response"
        , markdown := "Gateway returns a successful post response to Client."
        , terminal := false
        }
      , { id := "client_rejected"
        , label := "Client receives 400"
        , group := "client response"
        , markdown := "Gateway returns a visible rejection to Client."
        , terminal := false
        }
      , { id := "done"
        , label := "post_review done"
        , group := "terminal"
        , markdown := "Task is complete and the active task instance is cleaned up."
        , terminal := true
        }
      , { id := "failed"
        , label := "post_review failed"
        , group := "terminal"
        , markdown := "Task is terminal on an observable rejection."
        , terminal := true
        }
      ]
  , transitions :=
      [ { src := "submitted"
        , dst := "moderating"
        , message := "Reviews.ModerateCommand"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 3
        }
      , { src := "submitted"
        , dst := "client_rejected"
        , message := "Reviews.PostResponse400"
        , probabilityNum := 1
        , probabilityDen := 100
        , dwellMs := 1
        }
      , { src := "moderating"
        , dst := "accepted"
        , message := "Reviews.ModerationAccepted"
        , probabilityNum := 90
        , probabilityDen := 100
        , dwellMs := 10
        }
      , { src := "moderating"
        , dst := "rejected"
        , message := "Reviews.ModerationRejected"
        , probabilityNum := 10
        , probabilityDen := 100
        , dwellMs := 10
        }
      , { src := "accepted"
        , dst := "client_posted"
        , message := "Reviews.PostResponse201"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := "rejected"
        , dst := "client_rejected"
        , message := "Reviews.PostResponse400"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := "client_posted"
        , dst := "done"
        , message := "Reviews.PostResponse201"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := "client_rejected"
        , dst := "failed"
        , message := "Reviews.PostResponse400"
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      ]
  }

def workerRequirement : LeanFM.RequirementSpec :=
  { id := "worker.visible_behavior"
  , title := "Worker visible-behavior requirements"
  , actors := ["Client", "Gateway", "Worker"]
  , messages :=
      [ { name := "Docs.GetRequest"
        , src := "Client"
        , dst := "Gateway"
        , bytes := [0x01, 0x10]
        , fields := ["method", "path", "auth_proof", "return_to"]
        }
      , { name := "Docs.FetchCommand"
        , src := "Gateway"
        , dst := "Worker"
        , bytes := [0x02, 0x20]
        , fields := ["path", "cache_mode", "return_to"]
        }
      , { name := "Docs.FetchResult200"
        , src := "Worker"
        , dst := "Gateway"
        , bytes := [0x03, 0x30]
        , fields := ["status", "path", "bytes_moved", "cpu_ms"]
        }
      , { name := "Docs.FetchResult404"
        , src := "Worker"
        , dst := "Gateway"
        , bytes := [0x03, 0xff]
        , fields := ["status", "path", "cpu_ms"]
        }
      , { name := "Docs.GetResponse"
        , src := "Gateway"
        , dst := "Client"
        , bytes := [0x04, 0x40]
        , fields := ["status", "path", "bytes_moved"]
        }
      , { name := "Error.Response"
        , src := "Gateway"
        , dst := "Client"
        , bytes := [0xff]
        , fields := ["status", "reason"]
        }
      , { name := "Reviews.PostRequest"
        , src := "Client"
        , dst := "Gateway"
        , bytes := [0x11, 0x10]
        , fields := ["method", "path", "auth_proof", "body_hash", "return_to"]
        }
      , { name := "Reviews.ModerateCommand"
        , src := "Gateway"
        , dst := "Worker"
        , bytes := [0x12, 0x20]
        , fields := ["body_hash", "policy", "return_to"]
        }
      , { name := "Reviews.ModerationAccepted"
        , src := "Worker"
        , dst := "Gateway"
        , bytes := [0x13, 0x30]
        , fields := ["decision", "body_hash", "cpu_ms"]
        }
      , { name := "Reviews.ModerationRejected"
        , src := "Worker"
        , dst := "Gateway"
        , bytes := [0x13, 0xff]
        , fields := ["decision", "body_hash", "cpu_ms"]
        }
      , { name := "Reviews.PostResponse201"
        , src := "Gateway"
        , dst := "Client"
        , bytes := [0x14, 0x40]
        , fields := ["status", "path", "review_id"]
        }
      , { name := "Reviews.PostResponse400"
        , src := "Gateway"
        , dst := "Client"
        , bytes := [0x14, 0xff]
        , fields := ["status", "path", "reason"]
        }
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
