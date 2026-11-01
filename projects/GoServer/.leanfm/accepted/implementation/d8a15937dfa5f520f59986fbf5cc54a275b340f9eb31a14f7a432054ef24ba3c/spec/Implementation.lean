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
      { message := "CreateRoom", wireType := "CreateRoom", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client requests creation of a bounded named room." }] }
    , { message := "RoomCreated", wireType := "RoomCreated", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server returns the created room identifier with request correlation." }] }
    , { message := "ListRooms", wireType := "ListRooms", transport := .inProcessChannel "inprocess",
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


/-- Candidate realization choices; each is traceable and does not accept a gate. -/
def roomsBrowserDecisions : List RequirementJustification :=
  [ {requirementId := "grammar:create_room", reason := "source/server.go adds CreateRoom/RoomCreated to Handle; trim the supplied name, validate UTF-8 and the rune limit, authenticate, check duplicate names and MaxRooms atomically inside the existing cached operation. Keep the old provisioning helper for compatibility but route browser mutations only through the typed operation."}
  , {requirementId := "property:create_room authorized correlated result", reason := "Retain every accepted mutation result for a session; once its finite 128-result admission budget is exhausted, reject new mutations as busy without eviction or mutation. Existing duplicates still return their original result. This closes the old sliding-window replay hole while keeping 100 sessions, 16 rooms and a global 64-challenge bound."}
  , {requirementId := "grammar:create_game", reason := "Add gameName JSON fields corresponding to additive game_name protobuf fields in GameCreated and GameListed; list and render the stored challenge name, creator and open status."}
  , {requirementId := "property:Browser navigation reflects server state", reason := "Keep the local HTTP inspection adapter in source/cmd/demo. Embed static HTML, CSS and JavaScript assets; use real room/challenge selectors and forms. POST /api/create_room projects CreateRoom to the in-process core. Existing /api routes remain. Membership-checked /api/room_history and /api/game_history expose retained existing chat events for the inspection UI; they do not claim a released production protobuf/HTTP protocol."}
  , {requirementId := "proof:Browser never fabricates destinations or crosses scopes", reason := "Use textContent for all user strings, no placeholder anchors or unsupported gameplay controls, generation guards on every asynchronous room/game result, visible pending and failure states, finite periodic history polling, strict bounded JSON, loopback Host and Origin guards, POST-only API methods, no token display and no logging of requests. Keep the session in the existing tab-local storage boundary."}
  , {requirementId := "goserver", reason := "Align spec/runtime.json with make run on 127.0.0.1:8081. source/Makefile supports the uniform build, run, stop, test, check, clean and serve targets, with run foreground, serve aliasing run, and stop checking owned process identity rather than scanning ports. Use only the standard Go library and existing project compiler, Go 1.23.12; no external packages or paid provider retry. Cache, logs, review evidence and browser profiles remain in this project root."}
  , {requirementId := "goserver", reason := "Repair the existing accepted bounded-channel backpressure counterexample with mutex/condition-variable queue semantics; blocked sends and receives wake on close, sends never mutate after close, and receivers drain before closed. Update the contradictory test and rerun the preserved independent contract probe."}
  , {requirementId := "proof:create_room never crosses authority or scope", reason := "Add race-enabled core and HTTP tests for unauthorized/empty/oversized names, duplicate/concurrent rooms, request conflicts, replay after admission exhaustion, room/game membership and retained history isolation. Exercise the actual browser, including markup text and delayed old-scope responses. Retain a requirement-to-symbol/test manifest and actual startup evidence."}
  ]

end Project.Implementation
