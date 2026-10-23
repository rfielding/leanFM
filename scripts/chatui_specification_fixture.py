"""Small independent project for ChatUI specification regression scenarios."""

PROTO = 'syntax = "proto3";\nmessage FixtureRequest { uint64 request_id = 1; }\nmessage FixtureResponse { uint64 request_id = 1; }\n'
REQUIREMENTS = '''import LeanFM.Artifacts
namespace Fixture
open LeanFM
def task : TaskRequirement :=
  { id := "fixture_request", title := "Project-specific request", actors := ["Client", "FixtureServer"]
  , initialState := "ready"
  , states := [ {id := "ready", label := "Ready", group := "client", markdown := "Ready", terminal := false}
              , {id := "waiting", label := "Waiting", group := "server", markdown := "Waiting", terminal := false}
              , {id := "done", label := "Done", group := "terminal", markdown := "Done", terminal := true} ]
  , transitions := [ {src := "ready", dst := "waiting", message := "FixtureRequest", probabilityNum := 1, probabilityDen := 1, dwellMs := 0}
                   , {src := "waiting", dst := "done", message := "FixtureResponse", probabilityNum := 1, probabilityDen := 1, dwellMs := 0} ] }
def spec : RequirementSpec :=
  { id := "fixture.specification", title := "Independent project", actors := ["Client", "FixtureServer"]
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
  , desiredOutputs := [{id := "fixture.interaction", prompt := "Specify a simple server", question := "Which messages complete the request?", kind := .interactionDiagram, eventSource := "fixture_request grammar", reducer := "render this project's grammar", unit := "messages per scenario"}]
  , markdown := [] }
end Fixture
'''

IMPLEMENTATION = '''import spec.Requirements
import LeanFM.ChatUI.Implementation
namespace Fixture
open LeanFM
def implementation : ImplementationSpec :=
  { requirementId := spec.id, target := .go, moduleName := "example.com/fixture", outputDirectory := "source"
  , actors := spec.actors.map fun actor => {actor, typeName := actor, sourceFile := "source/main.go", justifications := [{requirementId := spec.id, reason := "Realize this project's actor"}]}
  , messages := spec.messages.map fun message => {message := message.name, wireType := message.name, transport := if message.name == "FixtureRequest" then .httpRequest "POST" "/fixture" else .httpResponse "FixtureRequest", justifications := [{requirementId := "message:" ++ message.name, reason := "Preserve this project's message"}]}
  , channels := {LeanFM.ChatUI.Implementation.implementation.channels with justifications := [{requirementId := spec.id, reason := "Realize bounded fixture channels"}]} }
end Fixture
'''

SERVER_SOURCE = '''package main

// Requirement refs: fixture.specification; property:Correlated completion;
// proof:No foreign response. Echo the decoded identity and reject invalid input.

import (
    "encoding/json"
    "io"
    "log"
    "net/http"
    "strconv"
    "time"
)

type payload struct { RequestID string `json:"requestId"` }
var inFlight = make(chan struct{}, 1)

func fixture(w http.ResponseWriter, r *http.Request) {
    select { case inFlight <- struct{}{}: defer func() { <-inFlight }(); default: http.Error(w, "busy", http.StatusServiceUnavailable); return }
    if r.Method != http.MethodPost { http.Error(w, "POST required", http.StatusMethodNotAllowed); return }
    r.Body = http.MaxBytesReader(w, r.Body, 1024)
    decoder := json.NewDecoder(r.Body)
    decoder.DisallowUnknownFields()
    var request payload
    if decoder.Decode(&request) != nil { http.Error(w, "invalid request", http.StatusBadRequest); return }
    if _, err := strconv.ParseUint(request.RequestID, 10, 64); err != nil { http.Error(w, "invalid requestId", http.StatusBadRequest); return }
    if decoder.Decode(new(any)) != io.EOF { http.Error(w, "one request required", http.StatusBadRequest); return }
    w.Header().Set("Content-Type", "application/json")
    _ = json.NewEncoder(w).Encode(request)
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/fixture", fixture)
    server := &http.Server{Addr: "127.0.0.1:8080", Handler: mux, ReadHeaderTimeout: 5*time.Second, ReadTimeout: 10*time.Second, WriteTimeout: 10*time.Second, IdleTimeout: 30*time.Second, MaxHeaderBytes: 8192}
    log.Fatal(server.ListenAndServe())
}
'''

SERVER_TEST = '''package main

// Requirement refs: property:Correlated completion; proof:No foreign response.

import (
    "net/http/httptest"
    "strings"
    "testing"
)

func TestCorrelatedResponseAndRejectedRequests(t *testing.T) {
    for _, test := range []struct{ body string; status int }{
        {`{"requestId":"42"}`, 200},
        {`{"requestId":"42","unknown":true}`, 400},
        {`{"requestId":"-1"}`, 400},
        {`{"requestId":"18446744073709551616"}`, 400},
        {`{"requestId":"42"} {}`, 400},
    } {
        response := httptest.NewRecorder()
        fixture(response, httptest.NewRequest("POST", "/fixture", strings.NewReader(test.body)))
        if response.Code != test.status { t.Fatalf("%s: got %d", test.body, response.Code) }
        if test.status == 200 && !strings.Contains(response.Body.String(), `"requestId":"42"`) { t.Fatal("response changed the request identity") }
    }
}
'''
