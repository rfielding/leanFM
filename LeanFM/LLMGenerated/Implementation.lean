import LeanFM.LLMGenerated.Requirements

namespace LeanFM.LLMGenerated.Implementation

open LeanFM.LLMGenerated.Requirements

def actorBinding : WorkerActor -> LeanFM.ActorCodegen
  | .Client => { actor := LeanFM.requirementName WorkerActor.Client
               , typeName := "ClientActor", sourceFile := "internal/actors/client.go" }
  | .Gateway => { actor := LeanFM.requirementName WorkerActor.Gateway
                , typeName := "GatewayActor", sourceFile := "internal/actors/gateway.go" }
  | .Worker => { actor := LeanFM.requirementName WorkerActor.Worker
               , typeName := "WorkerActor", sourceFile := "internal/actors/worker.go" }

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
      }
  }

def validationReport : String :=
  LeanFM.implementationValidationReport workerRequirement workerImplementation

end LeanFM.LLMGenerated.Implementation
