import LeanFM.Artifacts

open LeanFM

namespace Project.Implementation

/- Implementation mapping for the reduced server-only "goserver" RequirementSpec.
   This mapping targets a Go implementation that will generate initial in-memory
   server code for rooms, room-associated games/challenges, watch/join navigation,
   and isolated per-room/per-game chat. Each mapping entry cites the requirement
   ID for traceability. This file is authored after the requirements gate was
   accepted by the stakeholder and is intended for the leanfm_check validator.
-/

def implementation : ImplementationSpec :=
  { requirementId := "goserver"
  , target := .go
  , moduleName := "github.com/leanfm/goserver"
  , outputDirectory := "source/"

  -- Actor codegen: bind each requirement actor to a Go-side type and file.
  , actors := [
      { actor := "Person"
      , typeName := "PersonHandler"
      , sourceFile := "source/person.go"
      , justifications := [{ requirementId := "goserver", reason := "Person instances are client-side callers that drive the reduced server-only chat and navigation slice." }]
      }
    , { actor := "Server"
      , typeName := "ServerCore"
      , sourceFile := "source/server.go"
      , justifications := [{ requirementId := "goserver", reason := "ServerCore provides authoritative room, game, membership and chat state and enforces authorization and bounds." }]
      }
    ]

  -- Message bindings: use protobuf wire format and an in-process channel for the
  -- initial server-only implementation. This channel is conservative and
  -- isolates the runtime mapping from any particular transport (HTTP/gRPC)
  -- decision until later. Each message maps back to the requirement ID.
  , messages := [
      { message := "ListRooms", wireType := "ListRooms", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client ListRooms requests are delivered to the server for room discovery." }] }
    , { message := "RoomsListed", wireType := "RoomsListed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server responds with visible room identifiers." }] }
    , { message := "EnterRoom", wireType := "EnterRoom", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client requests room entry; server authorizes and returns membership and game list." }] }
    , { message := "RoomEntered", wireType := "RoomEntered", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms room entry and lists its games." }] }
    , { message := "ListGames", wireType := "ListGames", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client asks for games/challenges inside a room." }] }
    , { message := "GamesListed", wireType := "GamesListed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server returns the games/challenges that belong to a room." }] }
    , { message := "CreateGame", wireType := "CreateGame", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client creates a named open game/challenge inside a room." }] }
    , { message := "GameCreated", wireType := "GameCreated", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server returns a created game/chat container with server-issued ID and metadata." }] }
    , { message := "JoinGame", wireType := "JoinGame", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client requests to watch/join a game's chat container." }] }
    , { message := "GameJoined", wireType := "GameJoined", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms join/watch and enumerates participants." }] }
    , { message := "SendRoomChat", wireType := "SendRoomChat", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client sends bounded text to a room conversation; server stamps sender/time and enforces bounds." }] }
    , { message := "RoomChat", wireType := "RoomChat", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server emits room chat messages to authorized members with server-assigned sender/time." }] }
    , { message := "SendGameChat", wireType := "SendGameChat", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client sends bounded text to a game conversation; server stamps sender/time and enforces bounds." }] }
    , { message := "GameChat", wireType := "GameChat", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server emits game chat messages to authorized game viewers with server-assigned sender/time." }] }
    , { message := "RequestRejected", wireType := "RequestRejected", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server may reply to any request with an explicit RequestRejected event describing the error without mutating protected state." }] }
    ]

  -- Channels: a single conservative in-process channel for both directions for
  -- the initial in-memory runtime mapping.
  , channels :=
      { sendFunction := "SendInprocess"
      , receiveFunction := "ReceiveInprocess"
      , tryReceiveFunction := "TryReceiveInprocess"
      , closeFunction := "CloseInprocess"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
      , justifications := [{ requirementId := "goserver", reason := "Preserve bounded actor resources, backpressure, drain and close semantics for the selected in-process adapter." }]
      }
  }

end Project.Implementation
