import LeanFM.Artifacts

namespace LeanFM.LLMGenerated.Requirements

def generatedRequirementsProto : String :=
  include_str "Requirements.proto"

inductive WorkerActor where
  | Client
  | Gateway
  | Worker
deriving DecidableEq, Repr

instance : LeanFM.RequirementName WorkerActor where
  style := LeanFM.NameStyle.raw

inductive WorkerMessage where
  | Docs_GetRequest
  | Docs_FetchCommand
  | Docs_FetchResult200
  | Docs_FetchResult404
  | Docs_GetResponse
  | Error_Response
  | Reviews_PostRequest
  | Reviews_ModerateCommand
  | Reviews_ModerationAccepted
  | Reviews_ModerationRejected
  | Reviews_PostResponse201
  | Reviews_PostResponse400
deriving DecidableEq, Repr

instance : LeanFM.RequirementName WorkerMessage where
  style := LeanFM.NameStyle.dot

inductive GetDocsState where
  | requested
  | worker_fetching
  | gateway_success
  | gateway_failure
  | client_success
  | client_rejected
  | done
  | failed
deriving DecidableEq, Repr

instance : LeanFM.RequirementName GetDocsState where
  style := LeanFM.NameStyle.raw

inductive PostReviewState where
  | submitted
  | moderating
  | accepted
  | rejected
  | client_posted
  | client_rejected
  | done
  | failed
deriving DecidableEq, Repr

instance : LeanFM.RequirementName PostReviewState where
  style := LeanFM.NameStyle.raw

def workerMessages : List (LeanFM.TypedMessageSchema WorkerActor WorkerMessage) :=
  [ { name := WorkerMessage.Docs_GetRequest
    , src := WorkerActor.Client
    , dst := WorkerActor.Gateway
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x01, 0x10]
        , note := "LeanFM traffic discriminator for Docs.GetRequest; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "method", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "auth_proof", scalar := LeanFM.ProtoScalar.bytes }
        , { number := 4, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Docs_FetchCommand
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Worker
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x02, 0x20]
        , note := "LeanFM traffic discriminator for Docs.FetchCommand; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "cache_mode", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Docs_FetchResult200
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x03, 0x30]
        , note := "LeanFM traffic discriminator for successful Docs.FetchResult; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "bytes_moved", scalar := LeanFM.ProtoScalar.uint64 }
        , { number := 4, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Docs_FetchResult404
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x03, 0xff]
        , note := "LeanFM traffic discriminator for failed Docs.FetchResult; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Docs_GetResponse
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x04, 0x40]
        , note := "LeanFM traffic discriminator for Docs.GetResponse; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "bytes_moved", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Error_Response
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0xff]
        , note := "LeanFM traffic discriminator for generic observable error response; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "reason", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_PostRequest
    , src := WorkerActor.Client
    , dst := WorkerActor.Gateway
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x11, 0x10]
        , note := "LeanFM traffic discriminator for Reviews.PostRequest; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "method", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "auth_proof", scalar := LeanFM.ProtoScalar.bytes }
        , { number := 4, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 5, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_ModerateCommand
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Worker
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x12, 0x20]
        , note := "LeanFM traffic discriminator for Reviews.ModerateCommand; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "policy", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_ModerationAccepted
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x13, 0x30]
        , note := "LeanFM traffic discriminator for accepted Reviews.ModerationResult; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "decision", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Reviews_ModerationRejected
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x13, 0xff]
        , note := "LeanFM traffic discriminator for rejected Reviews.ModerationResult; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "decision", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Reviews_PostResponse201
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x14, 0x40]
        , note := "LeanFM traffic discriminator for successful Reviews.PostResponse; protobuf fields below define the payload body."
        }
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "review_id", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_PostResponse400
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , bytePattern :=
        { origin := LeanFM.ByteOrigin.literalPrefix
        , bytes := [0x14, 0xff]
        , note := "LeanFM traffic discriminator for failed Reviews.PostResponse; protobuf fields below define the payload body."
        }
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
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker]
  , initialState := GetDocsState.requested
  , states :=
      [ { id := GetDocsState.requested
        , label := "GET /docs/index.html requested"
        , group := "request accepted"
        , markdown := "Client has sent an authenticated GET request to Gateway."
        , terminal := false
        }
      , { id := GetDocsState.worker_fetching
        , label := "Worker fetching document"
        , group := "worker running"
        , markdown := "Gateway has queued a fetch command for Worker."
        , terminal := false
        }
      , { id := GetDocsState.gateway_success
        , label := "Gateway has 200 result"
        , group := "gateway decides"
        , markdown := "Worker returned a visible 200 result to Gateway."
        , terminal := false
        }
      , { id := GetDocsState.gateway_failure
        , label := "Gateway has 404 result"
        , group := "gateway decides"
        , markdown := "Worker returned a visible 404 result to Gateway."
        , terminal := false
        }
      , { id := GetDocsState.client_success
        , label := "Client receives 200"
        , group := "client response"
        , markdown := "Gateway returns the successful response to Client."
        , terminal := false
        }
      , { id := GetDocsState.client_rejected
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
        , dst := GetDocsState.worker_fetching
        , message := WorkerMessage.Docs_FetchCommand
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := GetDocsState.requested
        , dst := GetDocsState.client_rejected
        , message := WorkerMessage.Error_Response
        , probabilityNum := 1
        , probabilityDen := 100
        , dwellMs := 1
        }
      , { src := GetDocsState.worker_fetching
        , dst := GetDocsState.gateway_success
        , message := WorkerMessage.Docs_FetchResult200
        , probabilityNum := 95
        , probabilityDen := 100
        , dwellMs := 8
        }
      , { src := GetDocsState.worker_fetching
        , dst := GetDocsState.gateway_failure
        , message := WorkerMessage.Docs_FetchResult404
        , probabilityNum := 5
        , probabilityDen := 100
        , dwellMs := 8
        }
      , { src := GetDocsState.gateway_success
        , dst := GetDocsState.client_success
        , message := WorkerMessage.Docs_GetResponse
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := GetDocsState.gateway_failure
        , dst := GetDocsState.client_rejected
        , message := WorkerMessage.Error_Response
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := GetDocsState.client_success
        , dst := GetDocsState.done
        , message := WorkerMessage.Docs_GetResponse
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := GetDocsState.client_rejected
        , dst := GetDocsState.failed
        , message := WorkerMessage.Error_Response
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      ]
  }

def getDocsTask : LeanFM.TaskRequirement :=
  LeanFM.typedTaskRequirementToTask getDocsTaskTyped

def postReviewTaskTyped : LeanFM.TypedTaskRequirement WorkerActor PostReviewState WorkerMessage :=
  { id := "post_review"
  , title := "post_review task"
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker]
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
      , { id := PostReviewState.client_posted
        , label := "Client receives 201"
        , group := "client response"
        , markdown := "Gateway returns a successful post response to Client."
        , terminal := false
        }
      , { id := PostReviewState.client_rejected
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
        , message := WorkerMessage.Reviews_ModerateCommand
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 3
        }
      , { src := PostReviewState.submitted
        , dst := PostReviewState.client_rejected
        , message := WorkerMessage.Reviews_PostResponse400
        , probabilityNum := 1
        , probabilityDen := 100
        , dwellMs := 1
        }
      , { src := PostReviewState.moderating
        , dst := PostReviewState.accepted
        , message := WorkerMessage.Reviews_ModerationAccepted
        , probabilityNum := 90
        , probabilityDen := 100
        , dwellMs := 10
        }
      , { src := PostReviewState.moderating
        , dst := PostReviewState.rejected
        , message := WorkerMessage.Reviews_ModerationRejected
        , probabilityNum := 10
        , probabilityDen := 100
        , dwellMs := 10
        }
      , { src := PostReviewState.accepted
        , dst := PostReviewState.client_posted
        , message := WorkerMessage.Reviews_PostResponse201
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := PostReviewState.rejected
        , dst := PostReviewState.client_rejected
        , message := WorkerMessage.Reviews_PostResponse400
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 2
        }
      , { src := PostReviewState.client_posted
        , dst := PostReviewState.done
        , message := WorkerMessage.Reviews_PostResponse201
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := PostReviewState.client_rejected
        , dst := PostReviewState.failed
        , message := WorkerMessage.Reviews_PostResponse400
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      ]
  }

def postReviewTask : LeanFM.TaskRequirement :=
  LeanFM.typedTaskRequirementToTask postReviewTaskTyped

def workerRequirement : LeanFM.RequirementSpec :=
  { id := "worker.visible_behavior"
  , title := "Worker visible-behavior requirements"
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker].map LeanFM.requirementName
  , messages := workerMessages.map LeanFM.typedMessageSchemaToSchema
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
  generatedRequirementsProto

def workerGeneratedRequirement : LeanFM.GeneratedRequirement :=
  LeanFM.GeneratedRequirement.requirement workerRequirement

def all : List LeanFM.GeneratedRequirement :=
  [workerGeneratedRequirement]

def validationReport : String :=
  let errors :=
    LeanFM.validateGeneratedRequirements all ++
    LeanFM.validateRequirementProtoFile workerRequirement generatedRequirementsProto
  match errors with
  | [] => "ok: all generated requirements are well-formed typed Lean values\n"
  | errors => "invalid generated requirements\n" ++ LeanFM.joinWithNewline errors ++ "\n"

end LeanFM.LLMGenerated.Requirements
