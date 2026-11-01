import LeanFM.Artifacts

open LeanFM

namespace Project.Implementation

/- Implementation mapping for the "goserver" RequirementSpec: an in-memory Go
   server (source/) for rooms, room challenges, watch/join, isolated room and game
   chat, and N-player Go with server-side bots, autopilot, teams and merges, plus
   the Lab-style browser. Each mapping entry cites the requirement ID it realizes;
   source/traceability.json maps the same requirements to symbols and tests.
   Checked by `make spec-check`; review happens in git.
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
    , { actor := "Bot"
      , typeName := "BotPool"
      , sourceFile := "source/bot.go"
      , justifications := [{ requirementId := "proof:bots never exhaust the server", reason := "A fixed pool of search slots (the Bot population) runs max-n UCT searches on private position copies with a time budget and node cap; results return to ServerCore bound to game, seat and turn revision." }]
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
    , { message := "TakeSeat", wireType := "TakeSeat", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Client asks for one seat of an open game." }] }
    , { message := "SeatTaken", wireType := "SeatTaken", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms the seat number." }] }
    , { message := "StartGame", wireType := "StartGame", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Creator starts the game; empty seats become server-side bots." }] }
    , { message := "GameStarted", wireType := "GameStarted", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server returns the seat roster including bots." }] }
    , { message := "PlayMove", wireType := "PlayMove", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Seated person plays a stone, pass or resignation at the current move number." }] }
    , { message := "MovePlayed", wireType := "MovePlayed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms the applied move and its captures." }] }
    , { message := "GetGameState", wireType := "GetGameState", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Game member asks for the authoritative board, clock and scores." }] }
    , { message := "GameState", wireType := "GameState", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server returns the board, territory, scores, clock, move record and result." }] }
    , { message := "SetSeatPlan", wireType := "SetSeatPlan", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Creator plans one seat as bot or open with a team." }] }
    , { message := "SeatPlanSet", wireType := "SeatPlanSet", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms the seat plan." }] }
    , { message := "LeaveSeat", wireType := "LeaveSeat", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Seated person leaves before the start." }] }
    , { message := "SeatLeft", wireType := "SeatLeft", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms the seat is open again." }] }
    , { message := "SetAutopilot", wireType := "SetAutopilot", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Seated person switches autopilot on or off." }] }
    , { message := "AutopilotSet", wireType := "AutopilotSet", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server confirms the seat's controller." }] }
    , { message := "ProposeMerge", wireType := "ProposeMerge", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Seated person proposes merging two teams." }] }
    , { message := "MergeProposed", wireType := "MergeProposed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server records the proposal." }] }
    , { message := "RespondMerge", wireType := "RespondMerge", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Seated person in either team accepts or declines." }] }
    , { message := "MergeResponded", wireType := "MergeResponded", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server reports pending, merged or withdrawn." }] }
    , { message := "BotTurn", wireType := "BotTurn", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Server hands a position copy, history keys, team array and budget to a bot slot." }] }
    , { message := "BotMoveChosen", wireType := "BotMoveChosen", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Bot slot returns the move and its search summary." }] }
    , { message := "BotMovePlayed", wireType := "BotMovePlayed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Bot move published as a MoveRecord with its search summary in GameState." }] }
    , { message := "TurnTimedOut", wireType := "TurnTimedOut", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Timeout published as a MoveRecord in GameState." }] }
    , { message := "AutoPassed", wireType := "AutoPassed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Automatic pass of a resigned seat published as a MoveRecord in GameState." }] }
    , { message := "TeamsMerged", wireType := "TeamsMerged", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Merged teams published in GameState teams and seats." }] }
    , { message := "MergeWithdrawn", wireType := "MergeWithdrawn", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Withdrawn proposal removed from GameState proposals with a game chat notice." }] }
    , { message := "GameFinished", wireType := "GameFinished", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "goserver", reason := "Finished status, winners and end reason in GameState, announced in game chat." }] }
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


/-- Realization choices for rooms, challenges and the browser; each cites its requirement. -/
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

/-- Realization choices for N-player Go play; each cites its requirement. -/
def gameplayDecisions : List RequirementJustification :=
  [ {requirementId := "property:play_move rules", reason := "source/engine.go ports the stakeholder's N-Player Go Lab engine: a (N+2)^2 cell array with a Wall border, flood-fill liberties, capture into the owner's losses, legal suicide into the mover's losses, territory by single-colour bordered empty regions, simple ko plus situational superko (board plus seat to move) indexed by 64-bit Zobrist keys and confirmed by exact position comparison, timeouts, resignation, abandonment and the 3*N*N cap."}
  , {requirementId := "grammar:play_move", reason := "ServerCore.playMove authenticates through the existing cached replay wrapper, checks game membership, that the caller holds the seat to move and is not a bot, that move_no equals the current move number, then that the human deadline has not passed (if it has, the timeout is applied and the move rejected), then legality and superko against the game's exact position history, under the server lock."}
  , {requirementId := "property:turns always end", reason := "Each turn start records turnSeq and starts time.AfterFunc at the human deadline (or twice the bot budget plus one second for bots). The callback applies a timeout only if turnSeq is unchanged, so a late timer never ends a later turn."}
  , {requirementId := "proof:bots never exhaust the server", reason := "Bot turns clone the position and history under the lock, release it, wait for one of min(8, max(1, NumCPU/2)) search slots, run max^n UCT with the per-game time budget and a 200,000-node cap, and reacquire the lock only to apply the move when turnSeq is unchanged; an illegal or stale choice becomes a pass. Close stops timers and waits for searches."}
  , {requirementId := "grammar:start_game", reason := "Only the creator may start; empty seats become bot-<seat>; the ko flag resolves Auto by seat count; the initial position key seeds the superko history."}
  , {requirementId := "grammar:game_state", reason := "GetGameState is read-only (not recorded in the replay cache), requires game membership, and serializes row-major cells and territory owners, seat views, the move record (bounded at 3*19*19), remaining time and winners."}
  , {requirementId := "property:Browser navigation reflects server state", reason := "The embedded dark-only page draws the board on a canvas from GameState (Wall band with coordinates, stones, territory squares, last-move marker), sends PlayMove with the displayed move number on click, polls state every 0.5 s while playing, and offers seat, start, pass and two-step resign controls. HTTP routes /api/take_seat, /api/start_game, /api/play_move and /api/game_state reuse the strict JSON, loopback Host and Origin guards."}
  , {requirementId := "proof:play_move never crosses authority or scope", reason := "Race-enabled tests cover out-of-turn, outsider, stale, off-board, occupied, replayed and post-finish moves, seat and start authority, deadline timeouts and abandonment, an all-bot game to completion, and a bot never moving for a person; a headless-browser run exercises two people and a bot in one game."}
  ]

/-- Realization choices for seats, teams, history and search; each cites its requirement. -/
def labParityDecisions : List RequirementJustification :=
  [ {requirementId := "property:set_seat_plan creator controls the plan", reason := "game.seatPlan holds controller (bot|open) and team per seat; SetSeatPlan, TakeSeat and LeaveSeat mutate it only in status open under the server lock via the cached replay wrapper. CreateGame validates an optional seat_plan (seat 1..N once each, controller bot|open, team 1..N)."}
  , {requirementId := "property:set_autopilot keeps the seat", reason := "seat.autopilot flag; beginTurnLocked dispatches a bot for bot seats and autopilot seats. Turning autopilot off during the seat's own turn increments turnSeq (discarding the pending result) and rearms the human timer with the deadline measured from turnStart; turning it on during the seat's own turn dispatches a bot immediately."}
  , {requirementId := "property:merges need every person's consent", reason := "game.teams []int per seat and proposals map[id]*proposal{teamA, teamB, proposer, accepted set}. Persons seated in either team are recomputed at each response; merge when all accepted; any team change withdraws other proposals touching those teams; finishLocked withdraws all. A merged team takes min(teamA, teamB). Teams with no person are rejected (no_person_on_team)."}
  , {requirementId := "property:bot results are bound to their turn", reason := "engine.Search returns SearchSummary: playouts, ms, top 8 children by visits with move, visits, mover reward, per-seat outlook (W/n) and projected final score (mean playout score through that child), plus root outlook and root projection, and guard. Rewards use the Lab's margin/win/rank modes, exploration C and softness, with team arrays. Integers in milli or permille units on the wire."}
  , {requirementId := "proof:bots never exhaust the server", reason := "BotPool owns a semaphore of min(8, max(1, NumCPU/2)) slots matching the Bot population bound; searches run outside ServerCore.mu on cloned state; budget = bot_ms; node cap 200,000; Close cancels waits and waits for running searches."}
  , {requirementId := "property:game_state reflects the authoritative game", reason := "GetGameState since_move returns only move records with move_no >= since_move; each MoveRecord carries victims per seat (index 0 = seat 1), suicide and an optional SearchSummary. SeatView adds controller (open|person|bot|autopilot), team and losses_by (bowl). TeamView totals and MergeView (accepted_by, waiting_for) are computed under the read lock."}
  , {requirementId := "property:Lab-style viewer", reason := "source/cmd/demo/static gains engine.js (the Lab engine: geometry, play, score, rewards, cleanup) and search-worker.js (importScripts engine.js; max-n UCT with live progress), both served same-origin. The React app's GameCtl (web/src/game/game.ts) keeps a client game tree whose main line mirrors the server record; local branches hang off any node. Viewer panels, timeline, tree, chips, heat, bowls, sounds and GIF export are ported from the Lab as React components (web/src/ui) with server colours and dark theme. CSP adds worker-src 'self' and img-src 'self' blob: data:."}
  , {requirementId := "proof:pointer preview never misleads", reason := "The game controller (source/web/src/game/game.ts) and board component (ui/Board.tsx) draw the translucent mover-coloured stone only when canPlaceAt holds: the point is empty, the position is not terminal, and either it is the viewer's own live turn as a person or analysis is open to them, with the engine's isLegal (ko) check; the same predicates gate tryPlay. The preview is drawn on the canvas from pointermove and makes no request. Player swatches are stones on a wood tile drawn on a canvas, which dark-mode extensions leave alone. The side panel is a tab strip (Scores, Search, Seats, Chat, GIF) under a play bar holding status, clock, Pass, Resign and autopilot; badges flag unread chat and a merge awaiting the viewer. Tests: TestRoomAndGameTabsAndPointerPreview; book_tour.py hovers an empty and an occupied point in Chrome and compares canvas pixels and cursor."}
  , {requirementId := "property:Browser navigation reflects server state", reason := "The browser is a React + TypeScript app in source/web, built by Vite into cmd/demo/static/app (app.js, app.css) and embedded by the Go demo; engine.js, the Lab rules engine, loads first as a classic script and stays the rules reference. App.tsx keeps one tab per open room plus a + Rooms tab (room list and creation); Room.tsx keeps a Lobby tab (room chat, challenge list, new challenge) and one tab per open game, each game with its own GameCtl. Components stay mounted while their tab is open (hidden otherwise), poll faster when shown, and apply a result only when its roomId or gameId is their own, so a late response cannot reach another tab. Open rooms and games are kept in sessionStorage per person and rejoined after a reload. Badges: unread room chat counted from the moment a room opens; a game tab marks the viewer's move or a merge awaiting them. Test: TestRoomAndGameTabsAndPointerPreview; browser_check.py holds a study-room response, switches to the lobby tab, releases it and checks it lands only in the study room."}
  , {requirementId := "property:Browser navigation reflects server state", reason := "web/src/api.ts api(): a RequestRejected with code unauthorized while a session is held calls sessionLost, which clears the stored session, keeps the name and a notice in sessionStorage, and reloads; the reloaded page prefills the name form and shows the notice. style.css draws highlighted controls (submit buttons, primary and on buttons, tags, badges, the game-over banner) as accent text and border on a dark accent background; index.html declares color-scheme dark and darkreader-lock. Test: TestSessionRecoveryAndLightOnDark."}
  , {requirementId := "property:Analysis is local", reason := "The browser computes seatedInLive = viewer holds a seat and status is playing; while true, clicks on the board send PlayMove only at the live position on the viewer's turn, and branching, local Computer move, autoplay and analysis controls are disabled. Local nodes are flagged local and never serialized to the server."}
  , {requirementId := "proof:merges never happen without consent", reason := "Tests: outsider propose/respond, all-bot team, partial acceptance, decline withdraws, team change withdraws, finish withdraws, merge irreversible, bot cannot respond."}
  , {requirementId := "property:bot results are bound to their turn", reason := "Move choice breaks near-ties by projected score: among root children with at least half the top visit count and mean mover reward within 0.02 of the most visited child, the bot plays the one with the highest projected final score for its team, preferring a pass on ties. The Lab's soft-margin reward saturates near 1 when a seat is far ahead, which otherwise makes filling its own territory look as good as passing (observed in the book tour: a winning bot filled the board while people passed). The browser's local analysis keeps the Lab engine unchanged. Test: TestWinningBotPassesInsteadOfFillingItsTerritory."}
  , {requirementId := "proof:turns never end twice", reason := "Every turn-ending path (playMove, runBot apply, timeout, autopilot-off rearm, auto-pass) runs under ServerCore.mu and checks turnSeq; tests race a person move, a bot result and a timer on one turn and assert exactly one record per move number."}
  ]

end Project.Implementation
