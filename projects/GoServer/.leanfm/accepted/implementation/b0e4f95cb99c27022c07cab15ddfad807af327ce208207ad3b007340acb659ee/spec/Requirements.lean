import LeanFM.Artifacts

open LeanFM
namespace Project.Requirements
/- Candidate reduced server-only requirements. Authorized to formalize/check;
   neither human acceptance gate is crossed by this file. -/
def framing : MessageFraming := {kind := .protobufMessage, dispatchField := none, note := "One bounded protobuf message atom; request_id correlates each terminal result with its request in the same session and task"}
def messages : List MessageSchema := [
  {name := "ListRooms", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "session_id", scalar := .string}, {number := 2, name := "request_id", scalar := .uint64}]}
, {name := "RoomsListed", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "room_ids", scalar := .repeated (.string)}, {number := 2, name := "request_id", scalar := .uint64}]}
, {name := "EnterRoom", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "session_id", scalar := .string}, {number := 2, name := "room_id", scalar := .string}, {number := 3, name := "request_id", scalar := .uint64}]}
, {name := "RoomEntered", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "room_id", scalar := .string}, {number := 2, name := "game_ids", scalar := .repeated (.string)}, {number := 3, name := "request_id", scalar := .uint64}]}
, {name := "ListGames", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "room_id", scalar := .string}, {number := 2, name := "session_id", scalar := .string}, {number := 3, name := "request_id", scalar := .uint64}]}
, {name := "GamesListed", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "games", scalar := .repeated (.message "GameListed")}, {number := 2, name := "request_id", scalar := .uint64}, {number := 3, name := "room_id", scalar := .string}]}
, {name := "CreateGame", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "session_id", scalar := .string}, {number := 2, name := "room_id", scalar := .string}, {number := 3, name := "game_name", scalar := .string}, {number := 4, name := "request_id", scalar := .uint64}]}
, {name := "GameCreated", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "game_id", scalar := .string}, {number := 2, name := "room_id", scalar := .string}, {number := 3, name := "creator", scalar := .string}, {number := 4, name := "status", scalar := .string}, {number := 5, name := "request_id", scalar := .uint64}]}
, {name := "JoinGame", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "session_id", scalar := .string}, {number := 2, name := "game_id", scalar := .string}, {number := 3, name := "request_id", scalar := .uint64}]}
, {name := "GameJoined", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "game_id", scalar := .string}, {number := 2, name := "participants", scalar := .repeated (.string)}, {number := 3, name := "request_id", scalar := .uint64}]}
, {name := "SendRoomChat", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "session_id", scalar := .string}, {number := 2, name := "room_id", scalar := .string}, {number := 3, name := "body", scalar := .string}, {number := 4, name := "request_id", scalar := .uint64}]}
, {name := "RoomChat", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "room_id", scalar := .string}, {number := 2, name := "sender", scalar := .string}, {number := 3, name := "body", scalar := .string}, {number := 4, name := "time_ms", scalar := .int64}, {number := 5, name := "request_id", scalar := .uint64}]}
, {name := "SendGameChat", src := "Person", dst := "Server", framing, fields := [{number := 1, name := "session_id", scalar := .string}, {number := 2, name := "game_id", scalar := .string}, {number := 3, name := "body", scalar := .string}, {number := 4, name := "request_id", scalar := .uint64}]}
, {name := "GameChat", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "game_id", scalar := .string}, {number := 2, name := "sender", scalar := .string}, {number := 3, name := "body", scalar := .string}, {number := 4, name := "time_ms", scalar := .int64}, {number := 5, name := "request_id", scalar := .uint64}]}
, {name := "RequestRejected", src := "Server", dst := "Person", framing, fields := [{number := 1, name := "request_id", scalar := .uint64}, {number := 2, name := "code", scalar := .string}, {number := 3, name := "task", scalar := .string}, {number := 4, name := "scope_id", scalar := .string}]}
]
def scenarios : List (String × String × String × String × String) := [
  ("list_rooms", "List the available chat rooms", "ListRooms", "RoomsListed", "A valid server-issued session returns only visible room identifiers")
, ("enter_room", "Enter a room and inspect its game list", "EnterRoom", "RoomEntered", "The caller enters an existing visible room; the response names that room and its own game identifiers")
, ("list_games", "List room games and open challenges", "ListGames", "GamesListed", "A room member receives only game/challenge metadata belonging to that room")
, ("create_game", "Create a named room game or challenge", "CreateGame", "GameCreated", "A room member creates one fresh open chat/game container with a bounded name and server-issued ID")
, ("join_game", "Watch or enter a game chat container", "JoinGame", "GameJoined", "An authorized room member enters the selected game; repeated entry is idempotent and does not grant gameplay authority")
, ("room_chat", "Send room chat", "SendRoomChat", "RoomChat", "A room member sends bounded text to that room only; sender and timestamp are assigned by the server")
, ("game_chat", "Send game chat", "SendGameChat", "GameChat", "A game member sends bounded text to that game only; no implicit copy is added to the parent room chat")
]
def taskFor (id title request response : String) : TaskRequirement :=
  { id, title, actors := ["Person", "Server"], initialState := "ready"
  , states := [{id := "ready", label := "Ready", group := "client", markdown := "Request not yet issued", terminal := false},
               {id := "checking", label := "Server checks identity, scope and bounds", group := "server", markdown := "No mutation is committed before validation", terminal := false},
               {id := "accepted", label := "Correlated result", group := "terminal", markdown := "One authoritative result", terminal := true},
               {id := "rejected", label := "Explicit rejection without mutation", group := "terminal", markdown := "No private state is echoed", terminal := true}]
  , transitions := [{src := "ready", dst := "checking", message := request, probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
                    {src := "checking", dst := "accepted", message := response, probabilityNum := 1, probabilityDen := 1, dwellMs := 0},
                    {src := "checking", dst := "rejected", message := "RequestRejected", probabilityNum := 1, probabilityDen := 1, dwellMs := 0}] }
def event (task src dst message : String) : GrammarExpr := .event {task, src, dst, message}
def requirements : RequirementSpec :=
  { id := "goserver", title := "GoServer: rooms, challenges, game navigation and isolated chat"
  , actors := ["Person", "Server"]
  , actorPopulations := [{actorSpec := "Person", instancePrefix := "person", count := 100, routing := .sticky "session_id"},
                        {actorSpec := "Server", instancePrefix := "server", count := 1, routing := .roundRobin}]
  , actorResources := [{actor := "Person", inboundCapacity := 64, outboundCapacity := 64, maxInFlight := 8, memoryBudgetBytes := 16777216},
                       {actor := "Server", inboundCapacity := 4096, outboundCapacity := 4096, maxInFlight := 1024, memoryBudgetBytes := 536870912}]
  , actorReliability := [], reliabilityGates := [], actorCosts := [], messages
  , tasks := scenarios.map fun (id, title, request, response, _) => taskFor id title request response
  , grammars := scenarios.map fun (id, _, request, response, _) =>
      {task := id, entry := "ready", terminals := ["accepted", "rejected"], body := .seq (event id "Person" "Server" request)
        (.choice [event id "Server" "Person" response, event id "Server" "Person" "RequestRejected"])}
  , processes := scenarios.flatMap fun (id, _, request, response, _) =>
      [{actor := "Person", task := id, states := ["ready", "checking", "accepted", "rejected"], sends := [request], receives := [response, "RequestRejected"]},
       {actor := "Server", task := id, states := ["ready", "checking", "accepted", "rejected"], sends := [response, "RequestRejected"], receives := [request]}]
  , properties := scenarios.map fun (id, _, _, _, behavior) =>
      {name := id ++ " authorized correlated result", task := id, mode := .always, probability := none,
       expression := behavior ++ "; every result retains its request_id and task/session boundary; duplicate mutation request IDs return the original result without applying the action twice"}
  , requiredProofs := scenarios.map fun (id, _, _, _, _) =>
      {name := id ++ " never crosses authority or scope", task := id, mode := .never, probability := none,
       predicate := "an invalid or expired session, foreign room/game ID, malformed or oversized input, replay or concurrent admission leaks credentials, borrows another identity, mutates rejected state, duplicates a created game/chat entry or delivers chat outside its authorized scope"}
  , performance := [], charts := []
  , desiredOutputs := scenarios.flatMap fun (id, title, _, _, _) =>
      [{id := id ++ ".interaction", prompt := "Formalize and check the reduced rooms/challenges/chat server before requirements acceptance", question := "Which request and accepted/rejected result realize: " ++ title ++ "?", kind := .interactionDiagram, eventSource := id ++ " grammar in the current Project.Requirements.requirements", reducer := "render this current task grammar, preserving both correlated outcomes", unit := "messages in one scoped request/result scenario"},
       {id := id ++ ".state", prompt := "Show interaction diagrams and state machines for the reduced server-only scope", question := "Which states distinguish accepted and rejected actions for: " ++ title ++ "?", kind := .stateMachine, eventSource := id ++ " task in the current Project.Requirements.requirements", reducer := "render the same specification's task states and message transitions", unit := "states/transitions in one scoped request/result scenario"}]
  , markdown := [
      {id := "scope", title := "Current reduced slice", body := "Chat rooms, room game/challenge listings, named open challenge creation, watch/join navigation, room chat and isolated game chat. A game is a navigable chat container. Go boards, moves, seats, bots, clocks, captures, scoring, teams, ratings and moderation administration are deferred; existing larger-book discussion is roadmap material."},
      {id := "identity", title := "Identity and navigation boundaries", body := "Use an existing server-issued authenticated session; this slice does not add account registration or provider API credentials. EnterRoom authorizes room membership; JoinGame authorizes game chat membership within that room. Creator and sender are server-derived identities, never trusted request fields. Watch/join both enter a chat container and grant no gameplay authority."},
      {id := "bounds", title := "Bounded observable inputs and overload", body := "Proposed reversible defaults: names are nonempty UTF-8 up to 128 characters; chat bodies are nonempty UTF-8 up to 4000 characters; each room/game retains its latest 100 chat entries. The 100 Person instances are a first-slice capacity forecast, not measured throughput. Full queues reject with a busy result without mutation; the separate implementation mapping must bound connections and enforce the actor resource contracts."},
      {id := "correlation", title := "Correlation, replay and failure", body := "Request IDs are unique per authenticated session and task. Each request produces exactly one success or RequestRejected with the same request_id. Duplicate mutation IDs return the prior result, and conflicting reuse with another body is rejected. Structured game listings retain their GameListed record fields. Scenario trace envelopes must retain event identity, session/task and cause_id independently of prior ordering; HTTP conversion, runtime and storage choices await the separate mapping."},
      {id := "validation", title := "Meaning of this check", body := "The checker establishes Lean elaboration, protobuf agreement, structural completeness and current-spec diagram provenance. It does not prove that a future deployed server satisfies semantic isolation, concurrency, resource or security obligations. The explicit requirements gate and separate implementation gate remain pending."} ] }
end Project.Requirements

