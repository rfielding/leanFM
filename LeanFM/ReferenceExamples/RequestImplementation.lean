import LeanFM.ReferenceExamples.Request

namespace LeanFM.ReferenceExamples.Request
open LeanFM

/-- Complete typed realization of the companion request/response example.
    These are candidate choices, never evidence of stakeholder acceptance. -/
def implementation : ImplementationSpec :=
  { requirementId := spec.id
  , target := .go
  , moduleName := "example.com/request"
  , outputDirectory := "source"
  , actors := spec.actors.map fun actor =>
      { actor, typeName := actor ++ "Actor", sourceFile := "source/main.go"
      , justifications := [{requirementId := spec.id, reason := "Realize this actor's required behavior"}] }
  , messages := spec.messages.map fun message =>
      { message := message.name
      , wireType := message.name -- String naming the generated protobuf type
      , transport := .inProcessChannel "requests"
      , justifications := [{requirementId := "message:" ++ message.name, reason := "Preserve the declared payload"}] }
  , channels := -- One ChannelCodegen record, not a list of named channels
      { sendFunction := "Send", receiveFunction := "Receive"
      , tryReceiveFunction := "TryReceive", closeFunction := "Close"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
      , justifications := [{requirementId := spec.id, reason := "Implement bounded actor resources and closed-channel behavior"}] } }

end LeanFM.ReferenceExamples.Request
