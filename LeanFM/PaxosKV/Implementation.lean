import LeanFM.PaxosKV.Requirements

namespace LeanFM.PaxosKV.Implementation

open LeanFM

def why (id reason : String) : List RequirementJustification := [{ requirementId := id, reason }]
def actor (name typeName file id : String) : ActorCodegen := { actor := name, typeName, sourceFile := file, justifications := why id "Implements the accepted actor role." }
def tcp (name wire id : String) : MessageCodegen := { message := name, wireType := wire, transport := .tcp "configured three-replica mesh", justifications := why id "Carries the accepted observable message without changing its protobuf value." }

def spec : ImplementationSpec :=
  { requirementId := Requirements.spec.id
  , target := .go
  , moduleName := "leanfm/paxoskv"
  , outputDirectory := "."
  , actors :=
      [ actor "Browser" "HTTP browser session" "internal/web/app.go" "actor:Browser"
      , actor "WebApp" "web.App" "internal/web/app.go" "actor:WebApp"
      , actor "KVReplica" "paxos.Node" "internal/paxos/node.go" "actor:KVReplica" ]
  , messages :=
      [ { message := "PutRequest", wireType := "protocol.Envelope", transport := .httpRequest "POST" "/put", justifications := why "message:PutRequest" "The form submits one bounded key/value request." }
      , tcp "Propose" "protocol.Envelope" "message:Propose"
      , tcp "Prepare" "protocol.Envelope" "message:Prepare"
      , tcp "Promise" "protocol.Envelope" "message:Promise"
      , tcp "Accept" "protocol.Envelope" "message:Accept"
      , tcp "DurableAccepted" "protocol.Envelope" "message:DurableAccepted"
      , tcp "Commit" "protocol.Envelope" "message:Commit"
      , tcp "PutResult" "protocol.Envelope" "message:PutResult"
      , { message := "PutResponse", wireType := "HTML response", transport := .httpResponse "PutRequest", justifications := why "message:PutResponse" "A successful response includes a listing at least as new as its commit." }
      , { message := "ListRequest", wireType := "HTTP request", transport := .httpRequest "GET" "/", justifications := why "message:ListRequest" "The page requests one linearizable listing." }
      , tcp "ReadBarrier" "protocol.Envelope" "message:ReadBarrier"
      , tcp "ReadBarrierAck" "protocol.Envelope" "message:ReadBarrierAck"
      , tcp "Snapshot" "protocol.Envelope" "message:Snapshot"
      , { message := "ListResponse", wireType := "HTML response", transport := .httpResponse "ListRequest", justifications := why "message:ListResponse" "The table renders one committed prefix." }
      , { message := "Unavailable", wireType := "trace.Event", transport := .tcp "configured three-replica mesh"
        , justifications := why "message:Unavailable" "Records the outage atom." ++ why "proof:Possibly one replica unavailable" "Continues with a two-replica quorum and initiates catch-up after restart." }
      , tcp "Restarted" "trace.Event" "message:Restarted"
      , tcp "RecoverAcceptedLog" "protocol.Envelope" "message:RecoverAcceptedLog"
      , tcp "Available" "trace.Event" "message:Available" ]
  , channels :=
      { sendFunction := "protocol.WriteFrame"
      , receiveFunction := "protocol.ReadFrame"
      , tryReceiveFunction := "bounded nonblocking queue select"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , justifications := why "resource:KVReplica" "Bounded queues preserve accepted resource limits and leave state unchanged on failed admission." } }

def validationReport : String := implementationValidationReport Requirements.spec spec

end LeanFM.PaxosKV.Implementation
