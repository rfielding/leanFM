import LeanFM

open LeanFM

namespace Project.Requirements

def framing : MessageFraming :=
  { kind := .protobufMessage, dispatchField := none, note := "one protobuf message per authenticated request or server event" }

-- Reduced RequirementSpec for a basic server-only slice: rooms, game listings/challenges, and per-game chat.
def requirements : RequirementSpec := {
  id := "goserver"
  title := "GoServer basic rooms, game listings, and chat (server-only slice)"
  actors := ["Person", "Server"]
  actorPopulations := [
    { actorSpec := "Person", instancePrefix := "person", count := 100, routing := .sticky "session_id" },
    { actorSpec := "Server", instancePrefix := "server", count := 1, routing := .roundRobin }
  ]
  actorResources := [
    { actor := "Person", inboundCapacity := 64, outboundCapacity := 64, maxInFlight := 8, memoryBudgetBytes := 16777216 },
    { actor := "Server", inboundCapacity := 4096, outboundCapacity := 4096, maxInFlight := 1024, memoryBudgetBytes := 536870912 }
  ]
  actorReliability := []
  reliabilityGates := []
  actorCosts := []
  messages := [
    { name := "ListRooms", src := "Person", dst := "Server", framing := framing,
      fields := [{ number := 1, name := "session_id", scalar := .string }] },
    { name := "RoomsListed", src := "Server", dst := "Person", framing := framing,
      fields := [{ number := 1, name := "room_ids", scalar := .repeated .string }] },
    { name := "EnterRoom", src := "Person", dst := "Server", framing := framing,
      fields := [ { number := 1, name := "session_id", scalar := .string }, { number := 2, name := "room_id", scalar := .string } ] },
    { name := "RoomEntered", src := "Server", dst := "Person", framing := framing,
      fields := [ { number := 1, name := "room_id", scalar := .string }, { number := 2, name := "game_ids", scalar := .repeated .string } ] },
    { name := "ListGames", src := "Person", dst := "Server", framing := framing,
      fields := [ { number := 1, name := "room_id", scalar := .string } ] },
    { name := "GamesListed", src := "Server", dst := "Person", framing := framing,
      fields := [ { number := 1, name := "games", scalar := .repeated .string } ] },
    { name := "CreateGame", src := "Person", dst := "Server", framing := framing,
      fields := [ { number := 1, name := "session_id", scalar := .string }, { number := 2, name := "room_id", scalar := .string }, { number := 3, name := "game_name", scalar := .string } ] },
    { name := "JoinGame", src := "Person", dst := "Server", framing := framing,
      fields := [ { number := 1, name := "session_id", scalar := .string }, { number := 2, name := "game_id", scalar := .string } ] },
    { name := "GameJoined", src := "Server", dst := "Person", framing := framing,
      fields := [ { number := 1, name := "game_id", scalar := .string }, { number := 2, name := "participants", scalar := .repeated .string } ] },
    { name := "SendGameChat", src := "Person", dst := "Server", framing := framing,
      fields := [ { number := 1, name := "session_id", scalar := .string }, { number := 2, name := "game_id", scalar := .string }, { number := 3, name := "body", scalar := .string } ] },
    { name := "GameChat", src := "Server", dst := "Person", framing := framing,
      fields := [ { number := 1, name := "game_id", scalar := .string }, { number := 2, name := "sender", scalar := .string }, { number := 3, name := "body", scalar := .string }, { number := 4, name := "time_ms", scalar := .int64 } ] }
  ]

  -- Minimal task and grammar placeholders. These are intentionally small; the goal is a checked typed requirement
  -- that captures the observable server-only slice. Further temporal properties and richer task FSMs can be added
  -- after this gate is accepted.
  tasks := []
  grammars := []
  processes := []
  properties := []
  requiredProofs := []
  performance := []
  charts := []
  desiredOutputs := []
  markdown := []
}

end Project.Requirements
