import LeanFM.Artifacts

namespace LeanFM.GeneratedArtifacts

def aggNode (id group sub task auth label : String) (terminal : Bool) (q : Nat) : LeanFM.AggregateNode :=
  { id, group, sub, task, auth, terminal, q, label }

def aggEdge (src dst label : String) : LeanFM.AggregateEdge :=
  { src, dst, label }

def aggregateGraphData : LeanFM.AggregateGraphData :=
  { nodes :=
    [ aggNode "unauthorized" "unauthenticated" "entry" "none" "no auth" "unauthorized" false 0
    , aggNode "idle" "authenticated session" "ready" "none" "auth ok" "ready for task" false 0
    , aggNode "gd_submit" "get_docs task" "request accepted" "get_docs" "auth ok" "GET queued at Gateway" false 1
    , aggNode "gd_worker" "get_docs task" "worker running" "get_docs" "auth ok" "fetch queued at Worker" false 1
    , aggNode "gd_ok" "get_docs task" "gateway decides" "get_docs" "auth ok" "200 queued at Gateway" false 1
    , aggNode "gd_fail" "get_docs task" "gateway decides" "get_docs" "auth ok" "404 queued at Gateway" false 1
    , aggNode "gd_reply" "get_docs task" "client response" "get_docs" "auth ok" "200 queued at Client" false 1
    , aggNode "gd_reject" "get_docs task" "client response" "get_docs" "auth ok" "401 queued at Client" false 1
    , aggNode "gd_done" "get_docs task" "terminal" "get_docs" "auth ok" "get_docs done" true 0
    , aggNode "gd_failed" "get_docs task" "terminal" "get_docs" "auth ok" "get_docs failed" true 0
    , aggNode "rv_submit" "post_review task" "request accepted" "post_review" "auth ok" "review queued at Gateway" false 1
    , aggNode "rv_worker" "post_review task" "worker running" "post_review" "auth ok" "moderate queued at Worker" false 1
    , aggNode "rv_ok" "post_review task" "gateway decides" "post_review" "auth ok" "201 queued at Gateway" false 1
    , aggNode "rv_fail" "post_review task" "gateway decides" "post_review" "auth ok" "reject queued at Gateway" false 1
    , aggNode "rv_reply" "post_review task" "client response" "post_review" "auth ok" "201 queued at Client" false 1
    , aggNode "rv_reject" "post_review task" "client response" "post_review" "auth ok" "400 queued at Client" false 1
    , aggNode "rv_done" "post_review task" "terminal" "post_review" "auth ok" "post_review done" true 0
    , aggNode "rv_failed" "post_review task" "terminal" "post_review" "auth ok" "post_review failed" true 0
    ]
  , edges :=
    [ aggEdge "unauthorized" "idle" "Auth.LookupResponse ok"
    , aggEdge "idle" "gd_submit" "Docs.GetRequest"
    , aggEdge "idle" "rv_submit" "Reviews.PostRequest"
    , aggEdge "gd_submit" "gd_worker" "Docs.FetchCommand"
    , aggEdge "gd_submit" "gd_reject" "Error.Response"
    , aggEdge "gd_worker" "gd_ok" "Docs.FetchResult 200"
    , aggEdge "gd_worker" "gd_fail" "Docs.FetchResult 404"
    , aggEdge "gd_ok" "gd_reply" "Docs.GetResponse"
    , aggEdge "gd_fail" "gd_reject" "Error.Response"
    , aggEdge "gd_reply" "gd_done" "Docs.GetResponse"
    , aggEdge "gd_reject" "gd_failed" "Error.Response"
    , aggEdge "rv_submit" "rv_worker" "Reviews.ModerateCommand"
    , aggEdge "rv_submit" "rv_reject" "Reviews.PostResponse 400"
    , aggEdge "rv_worker" "rv_ok" "Reviews.ModerationResult accepted"
    , aggEdge "rv_worker" "rv_fail" "Reviews.ModerationResult rejected"
    , aggEdge "rv_ok" "rv_reply" "Reviews.PostResponse 201"
    , aggEdge "rv_fail" "rv_reject" "Reviews.PostResponse 400"
    , aggEdge "rv_reply" "rv_done" "Reviews.PostResponse 201"
    , aggEdge "rv_reject" "rv_failed" "Reviews.PostResponse 400"
    ]
  }

def aggregateGraph : LeanFM.GeneratedArtifact :=
  LeanFM.GeneratedArtifact.aggregateGraph "worker.aggregate" "Worker aggregate graph" aggregateGraphData

def all : List LeanFM.GeneratedArtifact :=
  [aggregateGraph]

def validationReport : String :=
  LeanFM.generatedArtifactValidationReport all

end LeanFM.GeneratedArtifacts
