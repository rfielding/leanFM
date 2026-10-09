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
  | start
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
  | start
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

def protobufAtomFraming : LeanFM.MessageFraming :=
  { kind := LeanFM.FramingKind.protobufMessage
  , dispatchField := none
  , note := "The wire bytes are exactly the protobuf encoding of this atom as defined in Requirements.proto; the typed message constructor selects the concrete atom after decode."
  }

def workerMessages : List (LeanFM.TypedMessageSchema WorkerActor WorkerMessage) :=
  [ { name := WorkerMessage.Docs_GetRequest
    , src := WorkerActor.Client
    , dst := WorkerActor.Gateway
    , framing := protobufAtomFraming
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
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "cache_mode", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Docs_FetchResult200
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , framing := protobufAtomFraming
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
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Docs_GetResponse
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "bytes_moved", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Error_Response
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "reason", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_PostRequest
    , src := WorkerActor.Client
    , dst := WorkerActor.Gateway
    , framing := protobufAtomFraming
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
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "policy", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "return_to", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_ModerationAccepted
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "decision", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Reviews_ModerationRejected
    , src := WorkerActor.Worker
    , dst := WorkerActor.Gateway
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "decision", scalar := LeanFM.ProtoScalar.string }
        , { number := 2, name := "body_hash", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "cpu_ms", scalar := LeanFM.ProtoScalar.uint64 }
        ]
    }
  , { name := WorkerMessage.Reviews_PostResponse201
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , framing := protobufAtomFraming
    , fields :=
        [ { number := 1, name := "status", scalar := LeanFM.ProtoScalar.uint32 }
        , { number := 2, name := "path", scalar := LeanFM.ProtoScalar.string }
        , { number := 3, name := "review_id", scalar := LeanFM.ProtoScalar.string }
        ]
    }
  , { name := WorkerMessage.Reviews_PostResponse400
    , src := WorkerActor.Gateway
    , dst := WorkerActor.Client
    , framing := protobufAtomFraming
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
  , initialState := GetDocsState.start
  , states :=
      [ { id := GetDocsState.start
        , label := "Client ready to request document"
        , group := "entry"
        , markdown := "The task instance exists before the first visible client request is consumed."
        , terminal := false
        }
      , { id := GetDocsState.requested
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
      [ { src := GetDocsState.start
        , dst := GetDocsState.requested
        , message := WorkerMessage.Docs_GetRequest
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := GetDocsState.requested
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

def getDocsProcesses : List (LeanFM.RequirementProcess) :=
  [ LeanFM.typedRequirementProcessToProcess
      { actor := WorkerActor.Client
      , task := "get_docs"
      , states := [GetDocsState.start, GetDocsState.requested, GetDocsState.client_success, GetDocsState.client_rejected, GetDocsState.done, GetDocsState.failed]
      , sends := [WorkerMessage.Docs_GetRequest]
      , receives := [WorkerMessage.Docs_GetResponse, WorkerMessage.Error_Response]
      }
  , LeanFM.typedRequirementProcessToProcess
      { actor := WorkerActor.Gateway
      , task := "get_docs"
      , states := [GetDocsState.requested, GetDocsState.gateway_success, GetDocsState.gateway_failure, GetDocsState.client_success, GetDocsState.client_rejected]
      , sends := [WorkerMessage.Docs_FetchCommand, WorkerMessage.Docs_GetResponse, WorkerMessage.Error_Response]
      , receives := [WorkerMessage.Docs_GetRequest, WorkerMessage.Docs_FetchResult200, WorkerMessage.Docs_FetchResult404]
      }
  , LeanFM.typedRequirementProcessToProcess
      { actor := WorkerActor.Worker
      , task := "get_docs"
      , states := [GetDocsState.worker_fetching, GetDocsState.gateway_success, GetDocsState.gateway_failure]
      , sends := [WorkerMessage.Docs_FetchResult200, WorkerMessage.Docs_FetchResult404]
      , receives := [WorkerMessage.Docs_FetchCommand]
      }
  ]

def postReviewTaskTyped : LeanFM.TypedTaskRequirement WorkerActor PostReviewState WorkerMessage :=
  { id := "post_review"
  , title := "post_review task"
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker]
  , initialState := PostReviewState.start
  , states :=
      [ { id := PostReviewState.start
        , label := "Client ready to submit review"
        , group := "entry"
        , markdown := "The task instance exists before the first visible review submission is consumed."
        , terminal := false
        }
      , { id := PostReviewState.submitted
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
      [ { src := PostReviewState.start
        , dst := PostReviewState.submitted
        , message := WorkerMessage.Reviews_PostRequest
        , probabilityNum := 1
        , probabilityDen := 1
        , dwellMs := 1
        }
      , { src := PostReviewState.submitted
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

def postReviewProcesses : List (LeanFM.RequirementProcess) :=
  [ LeanFM.typedRequirementProcessToProcess
      { actor := WorkerActor.Client
      , task := "post_review"
      , states := [PostReviewState.start, PostReviewState.submitted, PostReviewState.client_posted, PostReviewState.client_rejected, PostReviewState.done, PostReviewState.failed]
      , sends := [WorkerMessage.Reviews_PostRequest]
      , receives := [WorkerMessage.Reviews_PostResponse201, WorkerMessage.Reviews_PostResponse400]
      }
  , LeanFM.typedRequirementProcessToProcess
      { actor := WorkerActor.Gateway
      , task := "post_review"
      , states := [PostReviewState.submitted, PostReviewState.accepted, PostReviewState.rejected, PostReviewState.client_posted, PostReviewState.client_rejected]
      , sends := [WorkerMessage.Reviews_ModerateCommand, WorkerMessage.Reviews_PostResponse201, WorkerMessage.Reviews_PostResponse400]
      , receives := [WorkerMessage.Reviews_PostRequest, WorkerMessage.Reviews_ModerationAccepted, WorkerMessage.Reviews_ModerationRejected]
      }
  , LeanFM.typedRequirementProcessToProcess
      { actor := WorkerActor.Worker
      , task := "post_review"
      , states := [PostReviewState.moderating, PostReviewState.accepted, PostReviewState.rejected]
      , sends := [WorkerMessage.Reviews_ModerationAccepted, WorkerMessage.Reviews_ModerationRejected]
      , receives := [WorkerMessage.Reviews_ModerateCommand]
      }
  ]

def atom (task : String) (src dst : WorkerActor) (message : WorkerMessage) : LeanFM.GrammarAtom :=
  { task := task
  , src := LeanFM.requirementName src
  , dst := LeanFM.requirementName dst
  , message := LeanFM.requirementName message
  }

def event (task : String) (src dst : WorkerActor) (message : WorkerMessage) : LeanFM.GrammarExpr :=
  LeanFM.GrammarExpr.event (atom task src dst message)

def seq := LeanFM.GrammarExpr.seqList
def alt := LeanFM.GrammarExpr.alt

def getDocsGrammar : LeanFM.TaskGrammar :=
  { task := "get_docs"
  , entry := "start"
  , terminals := ["done", "failed"]
  , body :=
      seq
        [ event "get_docs" WorkerActor.Client WorkerActor.Gateway WorkerMessage.Docs_GetRequest
        , alt
            [ event "get_docs" WorkerActor.Gateway WorkerActor.Client WorkerMessage.Error_Response
            , seq
                [ event "get_docs" WorkerActor.Gateway WorkerActor.Worker WorkerMessage.Docs_FetchCommand
                , alt
                    [ seq
                        [ event "get_docs" WorkerActor.Worker WorkerActor.Gateway WorkerMessage.Docs_FetchResult200
                        , event "get_docs" WorkerActor.Gateway WorkerActor.Client WorkerMessage.Docs_GetResponse
                        ]
                    , seq
                        [ event "get_docs" WorkerActor.Worker WorkerActor.Gateway WorkerMessage.Docs_FetchResult404
                        , event "get_docs" WorkerActor.Gateway WorkerActor.Client WorkerMessage.Error_Response
                        ]
                    ]
                ]
            ]
        ]
  }

def postReviewGrammar : LeanFM.TaskGrammar :=
  { task := "post_review"
  , entry := "start"
  , terminals := ["done", "failed"]
  , body :=
      seq
        [ event "post_review" WorkerActor.Client WorkerActor.Gateway WorkerMessage.Reviews_PostRequest
        , alt
            [ event "post_review" WorkerActor.Gateway WorkerActor.Client WorkerMessage.Reviews_PostResponse400
            , seq
                [ event "post_review" WorkerActor.Gateway WorkerActor.Worker WorkerMessage.Reviews_ModerateCommand
                , alt
                    [ seq
                        [ event "post_review" WorkerActor.Worker WorkerActor.Gateway WorkerMessage.Reviews_ModerationAccepted
                        , event "post_review" WorkerActor.Gateway WorkerActor.Client WorkerMessage.Reviews_PostResponse201
                        ]
                    , seq
                        [ event "post_review" WorkerActor.Worker WorkerActor.Gateway WorkerMessage.Reviews_ModerationRejected
                        , event "post_review" WorkerActor.Gateway WorkerActor.Client WorkerMessage.Reviews_PostResponse400
                        ]
                    ]
                ]
            ]
        ]
  }

def requiredProofs : List LeanFM.RequiredProof :=
  [ { name := "Never get_docs success without auth proof"
    , mode := LeanFM.RequiredProofMode.never
    , task := "get_docs"
    , predicate := "success && missing(auth_proof)"
    , probability := some { numerator := 0, denominator := 1 }
    }
  , { name := "Always get_docs messages use declared src/dst"
    , mode := LeanFM.RequiredProofMode.always
    , task := "get_docs"
    , predicate := "grammar atom src/dst equals protobuf-backed message schema src/dst"
    , probability := some { numerator := 1, denominator := 1 }
    }
  , { name := "Eventually get_docs terminal"
    , mode := LeanFM.RequiredProofMode.eventually
    , task := "get_docs"
    , predicate := "terminal"
    , probability := some { numerator := 1, denominator := 1 }
    }
  , { name := "Possibly get_docs fetch failure"
    , mode := LeanFM.RequiredProofMode.possibly
    , task := "get_docs"
    , predicate := "Docs.FetchResult404"
    , probability := some { numerator := 5, denominator := 100 }
    , handlingPlan := some "Decode Docs.FetchResult404 and return the declared client-visible error response."
    }
  , { name := "Never post_review success without auth proof"
    , mode := LeanFM.RequiredProofMode.never
    , task := "post_review"
    , predicate := "success && missing(auth_proof)"
    , probability := some { numerator := 0, denominator := 1 }
    }
  , { name := "Always post_review messages use declared src/dst"
    , mode := LeanFM.RequiredProofMode.always
    , task := "post_review"
    , predicate := "grammar atom src/dst equals protobuf-backed message schema src/dst"
    , probability := some { numerator := 1, denominator := 1 }
    }
  , { name := "Eventually post_review terminal"
    , mode := LeanFM.RequiredProofMode.eventually
    , task := "post_review"
    , predicate := "terminal"
    , probability := some { numerator := 1, denominator := 1 }
    }
  , { name := "Possibly post_review moderation rejection"
    , mode := LeanFM.RequiredProofMode.possibly
    , task := "post_review"
    , predicate := "Reviews.ModerationRejected"
    , probability := some { numerator := 10, denominator := 100 }
    , handlingPlan := some "Decode Reviews.ModerationRejected and return Reviews.PostResponse400."
    }
  ]

def workerRequirement : LeanFM.RequirementSpec :=
  { id := "worker.visible_behavior"
  , title := "Worker visible-behavior requirements"
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker].map LeanFM.requirementName
  , actorPopulations :=
      [ { actorSpec := "Client", instancePrefix := "client-", count := 20
        , routing := .sticky "session" }
      , { actorSpec := "Gateway", instancePrefix := "gateway-", count := 2
        , routing := .roundRobin }
      , { actorSpec := "Worker", instancePrefix := "worker-", count := 2
        , routing := .shardHash "task" }
      ]
  , actorResources :=
      [ { actor := LeanFM.requirementName WorkerActor.Client
        , inboundCapacity := 1, outboundCapacity := 1
        , maxInFlight := 2, memoryBudgetBytes := 4096 }
      , { actor := LeanFM.requirementName WorkerActor.Gateway
        , inboundCapacity := 2, outboundCapacity := 2
        , maxInFlight := 4, memoryBudgetBytes := 16384 }
      , { actor := LeanFM.requirementName WorkerActor.Worker
        , inboundCapacity := 1, outboundCapacity := 1
        , maxInFlight := 2, memoryBudgetBytes := 8192 }
      ]
  , actorReliability :=
      [ { actor := "Client"
        , outageProbability := { numerator := 0, denominator := 10000 }
        , meanTimeToRepairMs := 0 }
      , { actor := "Gateway"
        , outageProbability := { numerator := 10, denominator := 10000 }
        , meanTimeToRepairMs := 30000 }
      , { actor := "Worker"
        , outageProbability := { numerator := 20, denominator := 10000 }
        , meanTimeToRepairMs := 45000 }
      ]
  , reliabilityGates :=
      [ { id := "gateway_pool", members := ["gateway-1", "gateway-2"], requiredCount := 1
        , affectedTasks := ["get_docs", "post_review"] }
      , { id := "worker_pool", members := ["worker-1", "worker-2"], requiredCount := 1
        , affectedTasks := ["get_docs", "post_review"] }
      , { id := "worker_request_path", members := ["gateway_pool", "worker_pool"], requiredCount := 2
        , affectedTasks := ["get_docs", "post_review"] }
      ]
  , actorCosts :=
      [ { actor := "Gateway", hardwarePool := "general-purpose", currency := "USD-cent"
        , hardwareCostPerProvisionedHour := 12, serviceCostPerAvailableHour := 3
        , capacityWorkPerHour := 3600000 }
      , { actor := "Worker", hardwarePool := "compute", currency := "USD-cent"
        , hardwareCostPerProvisionedHour := 20, serviceCostPerAvailableHour := 4
        , capacityWorkPerHour := 1800000 }
      ]
  , messages := workerMessages.map LeanFM.typedMessageSchemaToSchema
  , tasks := [getDocsTask, postReviewTask]
  , grammars := [getDocsGrammar, postReviewGrammar]
  , processes := getDocsProcesses ++ postReviewProcesses
  , properties :=
      [ { name := "AF get_docs terminal", mode := LeanFM.PropertyMode.eventually, task := "get_docs", expression := "terminal", probability := some { numerator := 1, denominator := 1 } }
      , { name := "AG no get_docs success without auth_proof", mode := LeanFM.PropertyMode.never, task := "get_docs", expression := "success && missing(auth_proof)", probability := some { numerator := 0, denominator := 1 } }
      , { name := "EF get_docs failure", mode := LeanFM.PropertyMode.eventually, task := "get_docs", expression := "failed", probability := some { numerator := 6, denominator := 100 } }
      , { name := "AF post_review terminal", mode := LeanFM.PropertyMode.eventually, task := "post_review", expression := "terminal", probability := some { numerator := 1, denominator := 1 } }
      , { name := "AG no post_review success without auth_proof", mode := LeanFM.PropertyMode.never, task := "post_review", expression := "success && missing(auth_proof)", probability := some { numerator := 0, denominator := 1 } }
      , { name := "EF post_review moderation rejection", mode := LeanFM.PropertyMode.eventually, task := "post_review", expression := "decision=rejected", probability := some { numerator := 10, denominator := 100 } }
      ]
  , requiredProofs := requiredProofs
  , performance :=
      [ { name := "client-experienced byte rate"
        , task := "get_docs"
        , metric := LeanFM.PerformanceMetric.clientExperiencedRate
        , workField := "bytes_moved", minimumWork := 1, perMilliseconds := 1 }
      , { name := "server aggregate byte throughput"
        , task := "get_docs"
        , metric := LeanFM.PerformanceMetric.serverAggregateRate
        , workField := "bytes_moved", minimumWork := 1, perMilliseconds := 1 }
      ]
  , charts :=
      [ { name := "latency by task", kind := LeanFM.ChartKind.xy, source := "messages", groupBy := some "task", value := "sum(dwellMs)" }
      , { name := "client-experienced USL observations", kind := LeanFM.ChartKind.xy, source := "offered, admitted, completed, rejected, and outstanding work with paired task boundaries", groupBy := some "client_count", value := "offered_rate, admitted_rate, completed_bytes/sum(observation_ms), latency, and backlog" }
      , { name := "server aggregate USL observations", kind := LeanFM.ChartKind.xy, source := "offered, admitted, and completed work by server instance", groupBy := some "client_count and server_count", value := "offered_rate, admitted_rate, sum(completed_bytes)/(max(end.timeAt)-min(start.timeAt)), per-server imbalance, and latency" }
      , { name := "observed outage percentage", kind := LeanFM.ChartKind.xy, source := "reliability events", groupBy := some "actor_spec", value := "sum(outage_ms)/(replicas*observation_ms)" }
      , { name := "observed MTTR", kind := LeanFM.ChartKind.xy, source := "reliability events", groupBy := some "actor_spec", value := "sum(repair_ms)/incident_count" }
      , { name := "bytes by actor", kind := LeanFM.ChartKind.pie, source := "messages", groupBy := some "src", value := "sum(bytes_moved)" }
      , { name := "queue pressure", kind := LeanFM.ChartKind.xy, source := "messages", groupBy := some "dst", value := "queue_length" }
      , { name := "queue length against latency", kind := LeanFM.ChartKind.xy, source := "explicitly paired task events", groupBy := some "queue_length_at_start", value := "end.timeAt-start.timeAt" }
      , { name := "memory headroom", kind := LeanFM.ChartKind.xy, source := "actor resource observations", groupBy := some "actor_instance", value := "memory_budget_bytes-resident_bytes" }
      , { name := "network outage impact", kind := LeanFM.ChartKind.xy, source := "reliability and task events", groupBy := some "actor_dependency", value := "affected_task_count" }
      , { name := "series and parallel service uptime", kind := LeanFM.ChartKind.xy, source := "synchronized reliability intervals and declared dependency gates", groupBy := some "dependency_gate", value := "time-weighted series/parallel/threshold availability" }
      , { name := "failure cascade impact", kind := LeanFM.ChartKind.xy, source := "named failure scenarios, dependency gates, and task outcomes", groupBy := some "initiating_failure_set", value := "derived unavailable services and affected tasks" }
      , { name := "denial-of-service criticality", kind := LeanFM.ChartKind.xy, source := "dependency gates, message traffic, task value, and cascade simulations", groupBy := some "actor_instance", value := "PageRank-like centrality, cut-set membership, and cascade loss" }
      , { name := "load and cost by replica count", kind := LeanFM.ChartKind.xy, source := "demand, completed work, and actor cost contracts", groupBy := some "actor_spec", value := "nominal demand/replicas, observed per-instance work/hour, sustainable supply, and hourly cost" }
      ]
  , desiredOutputs :=
      [ { id := "scenario.interaction", prompt := "Show how each scenario unfolds between actors.", question := "Which actor sent each partially ordered message to whom?", kind := .interactionDiagram, eventSource := "scenario events", reducer := "partition by (session,scenario), render src/dst lifelines and a prior-pointer order graph; show task-start/task-complete pairs inside fork/join branches and permit incomparable events to commute", unit := "events" }
      , { id := "scenario.state_machine", prompt := "Show the state machines in addition to interaction diagrams.", question := "Which observable states and message-labeled transitions are reachable?", kind := .stateMachine, eventSource := "scenario events", reducer := "project observed state/message/state triples per (session,scenario)", unit := "states and transitions" }
      , { id := "task.success_probability", prompt := "Measure whether each task succeeds.", question := "What fraction of terminal event mass is successful?", kind := .scalar, eventSource := "terminal task events", reducer := "successful terminal mass / total terminal mass", unit := "ratio" }
      , { id := "task.expected_latency", prompt := "Measure task latency.", question := "What is the expected elapsed time between explicitly paired start and terminal events?", kind := .scalar, eventSource := "task start and terminal events paired by prior ID", reducer := "probability-weighted sum(end.timeAt-start.timeAt) / terminal mass", unit := "milliseconds" }
      , { id := "task.throughput", prompt := "Measure task throughput.", question := "How much successful work completes per unit time?", kind := .scalar, eventSource := "completed task events", reducer := "success probability / expected latency", unit := "successes per millisecond" }
      , { id := "task.latency_by_task", prompt := "Compare latency by task.", question := "How does elapsed time vary by task?", kind := .function2d, eventSource := "task events paired by prior ID", reducer := "x=task; y=sum(dwellMs)", unit := "milliseconds" }
      , { id := "actor.bytes", prompt := "Show which actors move the bytes.", question := "How are encoded bytes distributed by sending actor?", kind := .function2d, eventSource := "message events", reducer := "x=src; y=sum(bytes_moved)", unit := "bytes" }
      , { id := "actor.queue_pressure", prompt := "Show queue pressure.", question := "How does queue length vary for each destination actor?", kind := .function2d, eventSource := "message and queue observations", reducer := "x=timeAt grouped by dst; y=queue_length", unit := "messages" }
      , { id := "load.usl", prompt := "Answer questions about behavior under load without confusing offered work with handled work.", question := "At each active-client population and server count, what work was offered, admitted, completed within the declared latency boundary, rejected, or left outstanding; and what USL curve fits completed throughput?", kind := .function2d, eventSource := "offer, admission, paired completion, terminal-outcome, queue/backlog, latency, routing, and server-population observations from comparable finite load runs", reducer := "derive offered rate lambda_o, admitted rate lambda_a, and completed throughput X separately by active-client population n and server count; fit X(n)=gamma*n/(1+alpha*(n-1)+beta*n*(n-1)) for 1 <= n <= declared population limit N; report parameters, fit error, latency, backlog, rejection, outstanding work, per-server offered and completed work, and imbalance", unit := "bytes per millisecond, clients, servers, milliseconds, bytes, and ratio" }
      , { id := "load.queue_latency", prompt := "Show whether big queues mean increasing latency.", question := "How does completion latency vary with queue length at task admission?", kind := .function2d, eventSource := "queue observations and task events paired by prior ID", reducer := "x=queue_length_at_start; y=end.timeAt-start.timeAt, grouped by actor and task", unit := "milliseconds by queued messages" }
      , { id := "resource.memory_headroom", prompt := "Treat running out of memory as fatal.", question := "How close does each actor instance come to its memory budget, and did exhaustion terminate it?", kind := .function2d, eventSource := "actor memory observations and fatal outcomes", reducer := "x=timeAt; y=memoryBudgetBytes-residentBytes, with exhaustion events at zero", unit := "bytes" }
      , { id := "reliability.network_outages", prompt := "Include outages in reports for networks of actors.", question := "Which inferred actor outages affected which dependent tasks, for how long, and with what outcome?", kind := .function2d, eventSource := "missed-heartbeat, stalled-inbound-queue, or absent-outbound-progress evidence; derived availability boundaries; actor message edges; and task outcomes", reducer := "apply the declared detector and boundary policy, join derived outage intervals to actor dependency edges, and aggregate affected, failed, and delayed tasks while retaining timing uncertainty", unit := "milliseconds, tasks, and ratio" }
      , { id := "reliability.composed_uptime", prompt := "Measure uptimes in series and in parallel.", question := "For each declared series, parallel, or k-of-n dependency gate, when was the composed service available?", kind := .function2d, eventSource := "synchronized detector-derived availability intervals, their evidence and boundary policies, and declared dependency gates", reducer := "sweep derived interval boundaries and integrate all-up for series gates, any-up for parallel gates, and surviving providers >= k for threshold gates; preserve correlated outages and detection uncertainty", unit := "availability ratio over milliseconds" }
      , { id := "reliability.failure_cascades", prompt := "Show what happens when particular interdependent services go down.", question := "Which inferred initial service failures cascade through which dependency edges; which progress stops; and which services, tasks, protocol obligations, and client outcomes are affected?", kind := .function2d, eventSource := "named service-down scenarios, dependency gates, heartbeat/queue/message-progress observations, derived availability boundaries, attempted work, and task outcomes", reducer := "compute the unavailable-service fixed point at every derived boundary; suppress modeled progress for inferred-unavailable instances; retain evidence, boundary policy, initiating failures, propagation edges, stalled/rejected/timed-out/cancelled work, safety and liveness verdicts, and restoration order", unit := "services, tasks, messages, milliseconds, and ratio" }
      , { id := "reliability.dos_criticality", prompt := "If an attacker tries to deny service, locate the most important nodes with something like PageRank.", question := "Which actor instances are the highest-value denial-of-service targets, and does disabling them actually cut off important tasks?", kind := .function2d, eventSource := "reliability dependency gates, observed message traffic, declared task value, and named attacker failure sets", reducer := "compute declared PageRank-like dependency centrality; enumerate permitted single/multi-node failures; report minimal cut sets, cascade fixed points, lost capacity, violated progress obligations, and client outcomes", unit := "centrality score, services, tasks, work/time, and ratio" }
      , { id := "capacity.optimal_supply", prompt := "Find an economical server supply that actually handles demand within its latency boundary.", question := "As more servers split offered demand, which permitted replica count completes the required work within the declared latency and availability targets at the lowest hardware plus service-uptime cost?", kind := .function2d, eventSource := "actor cost contracts, routing policy, offered/admitted/completed/rejected/outstanding work, paired latency observations, availability observations, and per-instance routing", reducer := "for each permitted replica count plot total and per-instance offered rate, admitted rate, completed throughput, latency, backlog, rejection, imbalance, availability-adjusted sustainable supply, and hourly cost; discard points that fail demand, outcome, latency, finite-window, or availability constraints and select the minimum-cost feasible point", unit := "replicas, bytes per hour per server, milliseconds, ratio, and USD-cent per hour" }
      ]
  , markdown :=
      [ { id := "overview", title := "Overview", body := "This generated requirement describes only visible messages, visible states, and properties over message fields." }
      , { id := "auth", title := "Authentication proof", body := "Both tasks require `auth_proof` on the initiating client message. Security properties forbid success traces where that field is absent." }
      , { id := "resources", title := "Resource bounds", body := "Queue, concurrent-work, and byte budgets are example requirement bounds. They are inputs to implementation and trace checks, not measurements of the Lean runtime." }
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
