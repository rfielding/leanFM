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
      [ { actorSpec := "Client", instancePrefix := "client-", count := 20 }
      , { actorSpec := "Gateway", instancePrefix := "gateway-", count := 2 }
      , { actorSpec := "Worker", instancePrefix := "worker-", count := 2 }
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
      , { name := "client-experienced USL observations", kind := LeanFM.ChartKind.xy, source := "completed work", groupBy := some "client_count", value := "sum(bytes_moved)/sum(observation_ms)" }
      , { name := "server aggregate USL observations", kind := LeanFM.ChartKind.xy, source := "completed work", groupBy := some "client_count", value := "sum(bytes_moved)/(max(end.timeAt)-min(start.timeAt))" }
      , { name := "observed outage percentage", kind := LeanFM.ChartKind.xy, source := "reliability events", groupBy := some "actor_spec", value := "sum(outage_ms)/(replicas*observation_ms)" }
      , { name := "observed MTTR", kind := LeanFM.ChartKind.xy, source := "reliability events", groupBy := some "actor_spec", value := "sum(repair_ms)/incident_count" }
      , { name := "bytes by actor", kind := LeanFM.ChartKind.pie, source := "messages", groupBy := some "src", value := "sum(bytes_moved)" }
      , { name := "queue pressure", kind := LeanFM.ChartKind.xy, source := "messages", groupBy := some "dst", value := "queue_length" }
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
