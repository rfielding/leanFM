import LeanFM.LLMGenerated.Requirements

namespace LeanFM.LLMGenerated.Implementation

open LeanFM.LLMGenerated.Requirements

def actorBinding : WorkerActor -> LeanFM.ActorCodegen
  | .Client => { actor := LeanFM.requirementName WorkerActor.Client
               , typeName := "ClientActor", sourceFile := "internal/actors/client.go"
               , justifications := [{ requirementId := workerRequirement.id
                                    , reason := "implements the required Client actor specification" }] }
  | .Gateway => { actor := LeanFM.requirementName WorkerActor.Gateway
                , typeName := "GatewayActor", sourceFile := "internal/actors/gateway.go"
                , justifications := [{ requirementId := workerRequirement.id
                                     , reason := "implements the required Gateway actor specification" }] }
  | .Worker => { actor := LeanFM.requirementName WorkerActor.Worker
               , typeName := "WorkerActor", sourceFile := "internal/actors/worker.go"
               , justifications := [{ requirementId := workerRequirement.id
                                    , reason := "implements the required Worker actor specification" }] }

def messageBinding (message : LeanFM.MessageSchema) : LeanFM.MessageCodegen :=
  { message := message.name
  , wireType := "pb." ++ LeanFM.replaceChar '.' '_' message.name
  , transport :=
      match message.name with
      | "Docs.GetRequest" => .httpRequest "GET" "/docs/{path}"
      | "Docs.FetchCommand" => .httpRequest "POST" "/internal/docs/fetch"
      | "Docs.FetchResult200" => .httpResponse "Docs.FetchCommand"
      | "Docs.FetchResult404" => .httpResponse "Docs.FetchCommand"
      | "Docs.GetResponse" => .httpResponse "Docs.GetRequest"
      | "Error.Response" => .httpResponse "Docs.GetRequest"
      | "Reviews.PostRequest" => .httpRequest "POST" "/reviews"
      | "Reviews.ModerateCommand" => .httpRequest "POST" "/internal/reviews/moderate"
      | "Reviews.ModerationAccepted" => .httpResponse "Reviews.ModerateCommand"
      | "Reviews.ModerationRejected" => .httpResponse "Reviews.ModerateCommand"
      | "Reviews.PostResponse201" => .httpResponse "Reviews.PostRequest"
      | "Reviews.PostResponse400" => .httpResponse "Reviews.PostRequest"
      | _ => .custom "unassigned" ""
  , justifications :=
      [{ requirementId := "message:" ++ message.name
       , reason := "encodes and transports the required observable message" }] ++
      (if message.name == "Docs.FetchResult404" then
        [{ requirementId := "proof:Possibly get_docs fetch failure"
         , reason := "implements the declared plan for the possible fetch-failure trace" }]
       else if message.name == "Reviews.ModerationRejected" then
        [{ requirementId := "proof:Possibly post_review moderation rejection"
         , reason := "implements the declared plan for the possible moderation-rejection trace" }]
       else [])
  }

def workerImplementation : LeanFM.ImplementationSpec :=
  { requirementId := workerRequirement.id
  , target := LeanFM.TargetLanguage.go
  , moduleName := "example.com/leanfm/worker"
  , outputDirectory := "generated/worker-go"
  , actors := [WorkerActor.Client, WorkerActor.Gateway, WorkerActor.Worker].map actorBinding
  , messages := workerRequirement.messages.map messageBinding
  , channels :=
      { sendFunction := "Send"
      , receiveFunction := "Receive"
      , tryReceiveFunction := "TryReceive"
      , sendFull := LeanFM.SendFullSemantics.blockWithoutMutation
      , receiveEmpty := LeanFM.ReceiveEmptySemantics.blockWithoutMutation
      , tryReceiveEmpty := LeanFM.TryReceiveEmptySemantics.returnNoneKeepRunnable
      , justifications :=
          [ { requirementId := "resource:Client"
            , reason := "implements the Client bounded queues" }
          , { requirementId := "resource:Gateway"
            , reason := "implements the Gateway bounded queues" }
          , { requirementId := "resource:Worker"
            , reason := "implements the Worker bounded queues" }
          ]
      }
  }

def validationReport : String :=
  LeanFM.implementationValidationReport workerRequirement workerImplementation

end LeanFM.LLMGenerated.Implementation
