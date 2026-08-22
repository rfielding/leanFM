import LeanFM.Artifacts

namespace LeanFM.GeneratedArtifacts

inductive WorkerActor where
  | client
  | gateway
  | worker
deriving DecidableEq, Repr

def WorkerActor.name : WorkerActor -> String
  | .client => "Client"
  | .gateway => "Gateway"
  | .worker => "Worker"

inductive WorkerMessage where
  | docsGetRequest
  | docsFetchCommand
  | docsFetchResult200
  | docsFetchResult404
  | docsGetResponse
  | errorResponse
  | reviewsPostRequest
  | reviewsModerateCommand
  | reviewsModerationAccepted
  | reviewsModerationRejected
  | reviewsPostResponse201
  | reviewsPostResponse400
deriving DecidableEq, Repr

def WorkerMessage.name : WorkerMessage -> String
  | .docsGetRequest => "Docs.GetRequest"
  | .docsFetchCommand => "Docs.FetchCommand"
  | .docsFetchResult200 => "Docs.FetchResult200"
  | .docsFetchResult404 => "Docs.FetchResult404"
  | .docsGetResponse => "Docs.GetResponse"
  | .errorResponse => "Error.Response"
  | .reviewsPostRequest => "Reviews.PostRequest"
  | .reviewsModerateCommand => "Reviews.ModerateCommand"
  | .reviewsModerationAccepted => "Reviews.ModerationAccepted"
  | .reviewsModerationRejected => "Reviews.ModerationRejected"
  | .reviewsPostResponse201 => "Reviews.PostResponse201"
  | .reviewsPostResponse400 => "Reviews.PostResponse400"

inductive GetDocsState where
  | requested
  | workerFetching
  | gatewaySuccess
  | gatewayFailure
  | clientSuccess
  | clientRejected
  | done
  | failed
deriving DecidableEq, Repr

def GetDocsState.name : GetDocsState -> String
  | .requested => "requested"
  | .workerFetching => "worker_fetching"
  | .gatewaySuccess => "gateway_success"
  | .gatewayFailure => "gateway_failure"
  | .clientSuccess => "client_success"
  | .clientRejected => "client_rejected"
  | .done => "done"
  | .failed => "failed"

inductive PostReviewState where
  | submitted
  | moderating
  | accepted
  | rejected
  | clientPosted
  | clientRejected
  | done
  | failed
deriving DecidableEq, Repr

def PostReviewState.name : PostReviewState -> String
  | .submitted => "submitted"
  | .moderating => "moderating"
  | .accepted => "accepted"
  | .rejected => "rejected"
  | .clientPosted => "client_posted"
  | .clientRejected => "client_rejected"
  | .done => "done"
  | .failed => "failed"

def workerMessages : List (LeanFM.TypedMessageSchema WorkerActor WorkerMessage) :=
  [ { name := WorkerMessage.docsGetRequest
    , src := WorkerActor.client
    , dst := WorkerActor.gateway
    , bytes := [0x01, 0x10]
    , fields :=
        [ { number := 1, name := "method", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "auth_proof", scalar := LeanFM.ProtoScalar.bytes }
        , { number := 4, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.docsFetchCommand
    , src := WorkerActor.gateway
    , dst := WorkerActor.worker
    , bytes := [0x02, 0x20]
    , fields :=
        [ { number := 1, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "cache_mode", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.docsFetchResult200
    , src := WorkerActor.worker
    , dst := WorkerActor.gateway
    , bytes := [0x03, 0x30]
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "bytes_moved", scalar := LeanFM.ProtoScalar.uint64 }
        , { number := 4, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.docsFetchResult404
    , src := WorkerActor.worker
    , dst := WorkerActor.gateway
    , bytes := [0x03, 0xff]
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.docsGetResponse
    , src := WorkerActor.gateway
    , dst := WorkerActor.client
    , bytes := [0x04, 0x40]
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "bytes_moved", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.errorResponse
    , src := WorkerActor.gateway
    , dst := WorkerActor.client
    , bytes := [0xff]
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "reason", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.reviewsPostRequest
    , src := WorkerActor.client
    , dst := WorkerActor.gateway
    , bytes := [0x11, 0x10]
    , fields :=
        [ { number := 1, name := "method", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "auth_proof", scalar := LeanFM.ProtoScalar.bytes }
        , { number := 4, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 5, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.reviewsModerateCommand
    , src := WorkerActor.gateway
    , dst := WorkerActor.worker
    , bytes := [0x12, 0x20]
    , fields :=
        [ { number := 1, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "policy", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.reviewsModerationAccepted
    , src := WorkerActor.worker
    , dst := WorkerActor.gateway
    , bytes := [0x13, 0x30]
    , fields :=
        [ { number := 1, name := "decision", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.reviewsModerationRejected
    , src := WorkerActor.worker
    , dst := WorkerActor.gateway
    , bytes := [0x13, 0xff]
    , fields :=
        [ { number := 1, name := "decision", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.reviewsPostResponse201
    , src := WorkerActor.gateway
    , dst := WorkerActor.client
    , bytes := [0x14, 0x40]
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "review_id", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.reviewsPostResponse400
    , src := WorkerActor.gateway
    , dst := WorkerActor.client
    , bytes := [0x14, 0xff]
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "reason", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  ]

def getDocsTaskTyped : LeanFM.TypedTaskRequirement WorkerActor GetDocsState WorkerMessage :=
  { id := "get_docs"
  , title := "get_docs task"
  , actors := [WorkerActor.client, WorkerActor.gateway, WorkerActor.worker]
  , initialState := GetDocsState.requested
  , states :=
      [ { id := GetDocsState.requested
        , label := "GET /docs/index.html requested"
        , group := "request accepted"
        , markdown := "Client has sent an authenticated GET request to Gateway."
        , terminal := false
        }
      , { id := GetDocsState.workerFetching
        , label := "Worker fetching document"
        , group := "worker running"
        , markdown := "Gateway has queued a fetch command for Worker."
        , terminal := false
        }
      , { id := GetDocsState.gatewaySuccess
        , label := "Gateway has 200 result"
        , group := "gateway decides"
        , markdown := "Worker returned a visible 200 result to Gateway."
        , terminal := false
        }
      , { id := GetDocsState.gatewayFailure
        , label := "Gateway has 404 result"
        , group := "gateway decides"
        , markdown := "Worker returned a visible 404 result to Gateway."
        , terminal := false
        }
      , { id := GetDocsState.clientSuccess
        , label := "Client receives 200"
        , group := "client response"
        , markdown := "Gateway returns the successful response to Client."
        , terminal := false
        }
      , { id := GetDocsState.clientRejected
        , label := "Client receives error"
        , group := "client response"
        , markdown := "Gateway returns an observable error response to Client."
        , terminal := false
        }
      , { id := GetDocsState.done
        , label := "get_docs done"
        , group := "terminal"
        , markdown := "Task is complete and the active task instance is cleaned up."
        , terminal := true
        }
      , { id := GetDocsState.failed
        , label := "get_docs failed"
        , group := "terminal"
        , markdown := "Task is terminal on an observable failure response."
        , terminal := true
        }
      ]
  , transitions :=
      [ { src := GetDocsState.requested
        , dst := GetDocsState.workerFetching
        , message := WorkerMessage.docsFetchCommand
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := GetDocsState.requested
        , dst := GetDocsState.clientRejected
        , message := WorkerMessage.errorResponse
        , probabilityNum := 1
        , probabilityDen := 100
        , dwellMs := 1
        }
      , { src := GetDocsState.workerFetching
        , dst := GetDocsState.gatewaySuccess
        , message := WorkerMessage.docsFetchResult200
        , probabilityNum := 95
        , probabilityDen := 100
        , dwellMs := 8
        }
      , { src := GetDocsState.workerFetching
        , dst := GetDocsState.gatewayFailure
        , message := WorkerMessage.docsFetchResult404
        , probabilityNum := 5
        , probabilityDen := 100
        , dwellMs := 8
        }
      , { src := GetDocsState.gatewaySuccess
        , dst := GetDocsState.clientSuccess
        , message := WorkerMessage.docsGetResponse
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := GetDocsState.gatewayFailure
        , dst := GetDocsState.clientRejected
        , message := WorkerMessage.errorResponse
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := GetDocsState.clientSuccess
        , dst := GetDocsState.done
        , message := WorkerMessage.docsGetResponse
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := GetDocsState.clientRejected
        , dst := GetDocsState.failed
        , message := WorkerMessage.errorResponse
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      ]
  }

def getDocsTask : LeanFM.TaskRequirement :=
  LeanFM.typedTaskRequirementToTask WorkerActor.name GetDocsState.name WorkerMessage.name getDocsTaskTyped

def postReviewTaskTyped : LeanFM.TypedTaskRequirement WorkerActor PostReviewState WorkerMessage :=
  { id := "post_review"
  , title := "post_review task"
  , actors := [WorkerActor.client, WorkerActor.gateway, WorkerActor.worker]
  , initialState := PostReviewState.submitted
  , states :=
      [ { id := PostReviewState.submitted
        , label := "POST /reviews submitted"
        , group := "request accepted"
        , markdown := "Client has sent an authenticated review submission to Gateway."
        , terminal := false
        }
      , { id := PostReviewState.moderating
        , label := "Worker moderating review"
        , group := "worker running"
        , markdown := "Gateway has queued moderation work for Worker."
        , terminal := false
        }
      , { id := PostReviewState.accepted
        , label := "Gateway has accepted review"
        , group := "gateway decides"
        , markdown := "Worker accepted the submitted review."
        , terminal := false
        }
      , { id := PostReviewState.rejected
        , label := "Gateway has rejected review"
        , group := "gateway decides"
        , markdown := "Worker rejected the submitted review."
        , terminal := false
        }
      , { id := PostReviewState.clientPosted
        , label := "Client receives 201"
        , group := "client response"
        , markdown := "Gateway returns a successful post response to Client."
        , terminal := false
        }
      , { id := PostReviewState.clientRejected
        , label := "Client receives 400"
        , group := "client response"
        , markdown := "Gateway returns a visible rejection to Client."
        , terminal := false
        }
      , { id := PostReviewState.done
        , label := "post_review done"
        , group := "terminal"
        , markdown := "Task is complete and the active task instance is cleaned up."
        , terminal := true
        }
      , { id := PostReviewState.failed
        , label := "post_review failed"
        , group := "terminal"
        , markdown := "Task is terminal on an observable rejection."
        , terminal := true
        }
      ]
  , transitions :=
      [ { src := PostReviewState.submitted
        , dst := PostReviewState.moderating
        , message := WorkerMessage.reviewsModerateCommand
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 3
        }
      , { src := PostReviewState.submitted
        , dst := PostReviewState.clientRejected
        , message := WorkerMessage.reviewsPostResponse400
        , probabilityNum := 1
        , probabilityDen := 100
        , dwellMs := 1
        }
      , { src := PostReviewState.moderating
        , dst := PostReviewState.accepted
        , message := WorkerMessage.reviewsModerationAccepted
        , probabilityNum := 90
        , probabilityDen := 100
        , dwellMs := 10
        }
      , { src := PostReviewState.moderating
        , dst := PostReviewState.rejected
        , message := WorkerMessage.reviewsModerationRejected
        , probabilityNum := 10
        , probabilityDen := 100
        , dwellMs := 10
        }
      , { src := PostReviewState.accepted
        , dst := PostReviewState.clientPosted
        , message := WorkerMessage.reviewsPostResponse201
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := PostReviewState.rejected
        , dst := PostReviewState.clientRejected
        , message := WorkerMessage.reviewsPostResponse400
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := PostReviewState.clientPosted
        , dst := PostReviewState.done
        , message := WorkerMessage.reviewsPostResponse201
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := PostReviewState.clientRejected
        , dst := PostReviewState.failed
        , message := WorkerMessage.reviewsPostResponse400
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      ]
  }

def postReviewTask : LeanFM.TaskRequirement :=
  LeanFM.typedTaskRequirementToTask WorkerActor.name PostReviewState.name WorkerMessage.name postReviewTaskTyped

def workerRequirement : LeanFM.RequirementSpec :=
  { id := "worker.visible_behavior"
  , title := "Worker visible-behavior requirements"
  , actors := [WorkerActor.client, WorkerActor.gateway, WorkerActor.worker].map WorkerActor.name
  , messages := workerMessages.map (LeanFM.typedMessageSchemaToSchema WorkerActor.name WorkerMessage.name)
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

def workerProtoFile : String :=
  LeanFM.requirementProtoFile workerRequirement

def workerArtifact : LeanFM.GeneratedArtifact :=
  LeanFM.GeneratedArtifact.requirement workerRequirement

def all : List LeanFM.GeneratedArtifact :=
  [workerArtifact]

def validationReport : String :=
  LeanFM.generatedArtifactValidationReport all

end LeanFM.GeneratedArtifacts
