import LeanFM.Artifacts
namespace LeanFM.ReferenceExamples.Request
open LeanFM
def task : TaskRequirement :=
  { id := "example_request", title := "Project-specific request", actors := ["Client", "FixtureServer"]
  , initialState := "ready"
  , states := [ {id := "ready", label := "Ready", group := "client", markdown := "Ready", terminal := false}
              , {id := "waiting", label := "Waiting", group := "server", markdown := "Waiting", terminal := false}
              , {id := "done", label := "Done", group := "terminal", markdown := "Done", terminal := true} ]
  , transitions := [ {src := "ready", dst := "waiting", message := "FixtureRequest", probabilityNum := 1, probabilityDen := 1, dwellMs := 0}
                   , {src := "waiting", dst := "done", message := "FixtureResponse", probabilityNum := 1, probabilityDen := 1, dwellMs := 0} ] }
def spec : RequirementSpec :=
  { id := "example.request", title := "Minimal complete request and response", actors := ["Client", "FixtureServer"]
  , actorPopulations := ["Client", "FixtureServer"].map fun actor => {actorSpec := actor, instancePrefix := actor, count := 1, routing := .sticky "session"}
  , actorResources := ["Client", "FixtureServer"].map fun actor => {actor, inboundCapacity := 4, outboundCapacity := 4, maxInFlight := 1, memoryBudgetBytes := 1000000}
  , actorReliability := [], reliabilityGates := [], actorCosts := []
  , messages := [ {name := "FixtureRequest", src := "Client", dst := "FixtureServer", framing := {kind := .protobufMessage, dispatchField := none, note := "One request"}, fields := [{number := 1, name := "request_id", scalar := .uint64}]}
                , {name := "FixtureResponse", src := "FixtureServer", dst := "Client", framing := {kind := .protobufMessage, dispatchField := none, note := "One response"}, fields := [{number := 1, name := "request_id", scalar := .uint64}]} ]
  , tasks := [task]
  , grammars := [{task := task.id, entry := "ready", terminals := ["done"], body := .seq (.event {task := task.id, src := "Client", dst := "FixtureServer", message := "FixtureRequest"}) (.event {task := task.id, src := "FixtureServer", dst := "Client", message := "FixtureResponse"})}]
  , processes := [ {actor := "Client", task := task.id, states := ["ready", "waiting", "done"], sends := ["FixtureRequest"], receives := ["FixtureResponse"]}
                 , {actor := "FixtureServer", task := task.id, states := ["ready", "waiting", "done"], sends := ["FixtureResponse"], receives := ["FixtureRequest"]} ]
  , properties := [{name := "Correlated completion", task := task.id, expression := "response retains request_id", mode := .always, probability := none}]
  , requiredProofs := [{name := "No foreign response", task := task.id, predicate := "a response has a different request_id", mode := .never, probability := none}]
  , performance := [], charts := []
  , desiredOutputs := [{id := "example.interaction", prompt := "Specify a simple server", question := "Which messages complete the request?", kind := .interactionDiagram, eventSource := "example_request grammar", reducer := "render this project's grammar", unit := "messages per scenario"},
                       {id := "example.states", prompt := "Specify a simple server", question := "Which states lead to completion?", kind := .stateMachine, eventSource := "example_request task", reducer := "render this project's task states and transitions", unit := "states per scenario"}]
  , markdown := [{id := "scope", title := "Reduced scope is complete behavior", body := "A small candidate still defines tasks, grammars, processes, properties, negative proof obligations and justified views before stakeholder acceptance."}] }
def protoSource : String := "syntax = \"proto3\";\nmessage FixtureRequest { uint64 request_id = 1; }\nmessage FixtureResponse { uint64 request_id = 1; }\n"
end LeanFM.ReferenceExamples.Request
