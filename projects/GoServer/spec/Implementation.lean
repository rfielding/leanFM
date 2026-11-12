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
    , { message := "IssueSession", wireType := "IssueSession", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:sign_in honours claims", reason := "POST /api/issue_session carries the name and, for a claimed name, its password." }] }
    , { message := "SessionIssued", wireType := "SessionIssued", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:sign_in honours claims", reason := "The new session token, the name and whether it is claimed." }] }
    , { message := "ClaimName", wireType := "ClaimName", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:claim_name binds a password to an unclaimed name", reason := "POST /api/claim_name from the sign-in form; never routed through the replay cache." }] }
    , { message := "NameClaimed", wireType := "NameClaimed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:claim_name binds a password to an unclaimed name", reason := "Sent only after the claim record is flushed to the data file; carries the new session." }] }
    , { message := "ChangePassword", wireType := "ChangePassword", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:change_password needs the current password", reason := "POST /api/change_password from the sign-in form; never routed through the replay cache." }] }
    , { message := "PasswordChanged", wireType := "PasswordChanged", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:change_password needs the current password", reason := "Sent only after the password record is flushed; carries the new session." }] }
    , { message := "SignOut", wireType := "SignOut", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:sign_out ends the session", reason := "POST /api/sign_out from the top bar." }] }
    , { message := "SignedOut", wireType := "SignedOut", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:sign_out ends the session", reason := "Confirms the session ended." }] }
    , { message := "AddReviewMove", wireType := "AddReviewMove", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:post-game review is shared and remembered", reason := "POST /api/review_move through the replay cache." }] }
    , { message := "ReviewMoveAdded", wireType := "ReviewMoveAdded", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:post-game review is shared and remembered", reason := "The kept node; others receive it through GameState.review." }] }
    , { message := "ReleaseName", wireType := "ReleaseName", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:release_name frees the name", reason := "POST /api/release_name from the closed-by-default panel of the sign-in form; never routed through the replay cache." }] }
    , { message := "NameReleased", wireType := "NameReleased", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:release_name frees the name", reason := "Sent only after the release record is flushed." }] }
    , { message := "GetRanking", wireType := "GetRanking", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:ranking is computed from rated games", reason := "POST /api/ranking; read-only." }] }
    , { message := "RankingListed", wireType := "RankingListed", transport := .inProcessChannel "inprocess",
        justifications := [{ requirementId := "property:ranking is computed from rated games", reason := "Claimed names and bots ordered by the fitted rating." }] }
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
  , {requirementId := "property:turns always end", reason := "Each turn start records turnSeq and starts time.AfterFunc when the seat's byo-yomi clock runs out (main time left plus periods left, for people and bots alike). The callback applies a timeout only if turnSeq is unchanged, so a late timer never ends a later turn."}
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
  , {requirementId := "property:byo-yomi clocks", reason := "game.clock (main time, periods, period) from CreateGame replaces turn_deadline_ms and bot_ms; seat.mainLeft and seat.periodsLeft per seat. beginTurnLocked sets the turn's limit to mainLeft + periodsLeft * period from turnBegan and arms one timer at that instant for every controller. chargeLocked(seat, elapsed) on each move: within main time it subtracts; beyond it, it sets main to zero and uses up floor((elapsed - main) / period) periods, so a move within a period keeps it. A timeout sets main to zero and leaves one period. Autopilot switches never touch the clock or the timer instant. GameState reports MainLeftMS and PeriodsLeft per seat and RemainingMS for the current stage."}
  , {requirementId := "property:bots spend time where it matters", reason := "planBot(seat, elapsedThisTurn, empty points, seats) gives a planned and a hard limit: in main time planned = mainLeft / max(8, empty/seats) and hard = min(mainLeft, 4 * planned) + 0.8 * period; in byo-yomi planned = 0.5 * period and hard = 0.8 * period; both less the time already spent this turn and a 150 ms safety margin, so a period is never used up on purpose. engine.Search checks every 64 playouts: stop at hard; stop as settled when the best child's visit lead exceeds the playouts still possible at the measured rate before hard (after at least 50 playouts); stop at planned unless the second child has at least 70 percent of the best child's visits. A single legal candidate returns at once. SearchSummary gains Stop and PlannedMS. The bot rating key becomes the clock with the search settings."}
  , {requirementId := "property:session type panel", reason := "spec/SessionPanel.lean, run from the LeanFM root, reads spec/Session.lean, keeps the --@begin/--@end regions verbatim, strips doc comments for the parser, and writes source/cmd/demo/static/session/{goserver.leanfm, goserver.svg, provenance.json} with LeanFM's own parseProtocol, annotatedModel and dark theme. The Go demo embeds and serves them under /session/. web/src/ui/SessionType.tsx is a details element under the board, closed by default; opening it first fetches the text and provenance and lets the lazy image load."}
  , {requirementId := "property:session type panel", reason := "spec/Requirements.proto is the source of truth for the messages. spec/SessionTypes.lean, run from the LeanFM root, reads it with LeanFM's proto reader (fields named by their protobuf JSON names, as the Go server sends them: request_id is requestId) and writes the --@begin Types region of spec/Session.lean: one structure deriving TypeName per message any protocol of the file uses, and the messages they contain, and an empty structure for each local event the proto does not declare. Every where condition is typed against whole messages, by Lean when Session.lean is elaborated and by LeanFM's parser when it reads the regions. It also writes spec/generated/Payload.lean: the payload types, the event envelope and the states of each sequential role (Bot); Person and Server run branches in parallel and are named there with the reason."}
  , {requirementId := "property:session type panel", reason := "Beside the session type, the panel shows spec/Implementation.lean (the choices that realize it) in a closed section and links the GoServer book as a dark-mode PDF. spec/SessionPanel.lean copies both into source/cmd/demo/static/session (implementation.lean verbatim, goserver-dark.pdf byte for byte from book/main-dark.pdf); the demo embeds and serves them as text/plain and application/pdf; TestSessionPanelMatchesTheSpec fails when either copy is stale."}
  , {requirementId := "proof:the session type panel never misleads", reason := "TestSessionPanelMatchesTheSpec recomputes the regions from spec/Session.lean and fails when the embedded text differs, checks the routes and content types, that the SVG names the current events (ClockRanOut, PlayMove) and carries no script, and that the provenance names its protocol, reducer and boundary. The SVG is shown through img, where scripts never run."}
  , {requirementId := "property:post-game review is shared and remembered", reason := "game.review holds nodes {id r<n>, parent, kind, x, y, seat, author, time} in memory with the game, at most MaxReviewNodes = 2000. ServerCore.addReviewMove (cached) requires a finished game and membership, resolves the parent (m<k> for k up to the moves played, or an existing r<n>), replays the actual moves and the review chain from a fresh State with the engine, checks the move with Geom.IsLegal (and that the point is empty and the position not terminal), returns an existing node for the same parent and move, and appends otherwise. GetGameState.since_review returns review[since:] and review_count. The browser posts every variation move made after the finish (and any unposted ancestors first), maps m<k> to its actual-move nodes and r<n> to review nodes, and merges others' review nodes into its tree on every poll."}
  , {requirementId := "property:chat follows the tree", reason := "SendGameChat.node is resolved under the game lock: an m<k> with k up to the moves played, or after the finish an existing r<n>; anything else (or nothing) pins to the latest actual position m<len(moves)>. GameChat.node is retained and returned by game_history. The browser sends the reference of the viewed node (the nearest posted ancestor for a local variation during play) and the Chat panel shows the messages whose node is on the current node's path, ordered by depth along the line and then by time, with a tag saying the move each was written at. Game chat keeps its latest 500 entries."}
  , {requirementId := "proof:review never changes the game", reason := "Tests: review before the finish, by an outsider, after an unknown or future parent, on an occupied point, at a terminal position and past the cap are rejected; a duplicate returns the same node; the game's moves, winners and ranking are unchanged after review moves."}
  , {requirementId := "proof:chat never pins to a position that does not exist", reason := "Tests: a chat sent with a future m<k>, an unknown r<n>, or an r<n> during play is pinned to the latest actual position; the Chat panel filter is exercised in the browser check."}
  , {requirementId := "proof:clocks never cheat", reason := "Tests: a move within a period keeps it; a move two periods over uses up two; the last period run out times out and leaves one; a move after the limit loses to the timeout; autopilot on and off leaves the remaining time unchanged; a bot never searches past its hard limit and stops early on a forced move; the timer instant equals the reported remaining time."}
  , {requirementId := "proof:turns never end twice", reason := "Every turn-ending path (playMove, runBot apply, timeout, autopilot-off rearm, auto-pass) runs under ServerCore.mu and checks turnSeq; tests race a person move, a bot result and a timer on one turn and assert exactly one record per move number."}
  ]

/-- Realization choices for claimed names, durable results and the ranking; each cites its requirement. -/
def claimsRankingDecisions : List RequirementJustification :=
  [ {requirementId := "property:claim_name binds a password to an unclaimed name", reason := "source/accounts.go: Accounts holds claims keyed by nameKey (lower case, trimmed) with the display name, claim time and a PHC-style hash pbkdf2-sha256$600000$salt$key (16-byte random salt, 32-byte key, PBKDF2 written over crypto/hmac). ServerCore.ClaimName refuses bot- names, invalid passwords, claimed names and any name a live session holds under any case variant, hashes outside ServerCore.mu, appends the claim record, inserts it, and only then issues the session. MaxClaims = 1000. The browser compares the two typed passwords before sending one."}
  , {requirementId := "property:change_password needs the current password", reason := "ServerCore.ChangePassword: Accounts.Authenticate (same throttle and per-name single flight as sign-in), then Accounts.SetPassword validates the new password, refuses a change within a minute of the last one for the name and beyond MaxAccountRecords = 20,000 account records, hashes, appends a password record and swaps the hash; then every session token for the name is deleted and a new one issued. Replay applies password records after their claim."}
  , {requirementId := "property:release_name frees the name", reason := "Each claim carries a random claim id, and every rated person seat records the claim id current when the game finished. The fit keys persons by name and claim id, so a released claim's games keep counting for everyone else while a later claim of the same name is a different player; Accounts.Ranking lists only persons whose claim id is current. ServerCore.ReleaseName authenticates (sign-in throttle), Accounts.Release appends a release record and deletes the claim, then every session for the name ends. The browser requires a confirmation checkbox, never a dialog. Claims, password changes and releases together are capped at MaxAccountRecords = 20,000."}
  , {requirementId := "property:sign_out ends the session", reason := "ServerCore.SignOut deletes the caller's token and its replay cache; the browser clears its stored session and shows the sign-in form prefilled with the name."}
  , {requirementId := "property:sign_in honours claims", reason := "ServerCore.SignIn(identity, password): bot- names (any case) are refused; an unclaimed name behaves as IssueSession did (refused while a live session holds it); a claimed name verifies the password with subtle.ConstantTimeCompare and, on success, deletes every session token for that identity before issuing the new one. Seats, rooms and games are keyed by identity, so the person keeps them."}
  , {requirementId := "proof:sign_in never lets anyone borrow a claimed name", reason := "Failures per lower-cased name: after 5 consecutive failures an attempt within 2^(k-5) seconds (capped at 15 minutes) of the last failure is refused before hashing; success resets the count. A two-slot semaphore bounds PBKDF2 work. The password never enters the replay cache, logs or responses; errors are generic (wrong password, try again later). Tests: wrong password, case variants, bot- names, throttle, takeover ends the old token, hash absent from responses."}
  , {requirementId := "property:ranking is computed from rated games", reason := "finishLocked builds a ResultRecord (game id, finish time, per seat: rated player key or empty, team, placement) and appends it through Accounts.RecordResult outside the lock path for the HTTP reply; person seats are rated only if the name's claim time precedes the game start and seat.everAutopilot is false; bots get the key bot:<bot_ms>ms/<explore_milli>/<reward_mode>/<softness>. source/ranking.go fits Bradley-Terry by Hunter's MM iteration over the comparisons with the anchor fixed at 1, iterating until the largest relative change is below 1e-12 or 10,000 rounds, with players and comparisons sorted so the result is order-independent; rating = 1500 + 400*log10(gamma). The fit is cached and invalidated by each new result."}
  , {requirementId := "property:claims and results are durable", reason := "Data file data/goserver.jsonl under the project root (GOSERVER_DATA_DIR overrides; default ../data from the source directory, used only when ../spec/runtime.json exists). Each record is one JSON line written with O_APPEND and fsync before acknowledgement; on start the file is replayed; a torn final line (no newline) is truncated away, any other damaged line stops the start with its line number. Results are keyed by game id, so a replayed duplicate is ignored."}
  , {requirementId := "proof:the data file never escapes or corrupts", reason := "The directory is created 0700 and the file 0600; Lstat refuses a symlinked directory or file; the defaulted path is checked to stay inside the project root after filepath.Clean; MaxResults = 100,000 and MaxClaims = 1000 refuse further records (a refused result is noted in the game chat). No HTTP route reads the data directory. Tests cover torn tails, damaged middles, symlinks, duplicates and caps."}
  , {requirementId := "property:Browser navigation reflects server state", reason := "The sign-in form has the name, a password and a repeat field; a Manage a claimed name panel, closed until opened, holds Change password (current password once, new one twice) and Release name (password and a confirmation checkbox). The form picks the action from what is filled: name only, one password, two matching passwords, or change. Passwords are sent only to issue_session, claim_name or change_password and never kept in the page or sessionStorage. A Sign out button in the top bar returns to the form. A Ranking tab lists RankingListed. All text stays light on dark."}
  ]

end Project.Implementation
