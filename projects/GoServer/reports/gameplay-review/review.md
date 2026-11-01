# N-player Go play revision — review

Status: candidate. Neither acceptance gate is implied by this report.

## Request
Complete the KGS-style server: challenge creation takes the N-Player Go Lab
board parameters; seats not taken by people are played by MCTS bots that run
in the server.

## Specification changes
- `spec/Requirements.lean`: tasks `take_seat`, `start_game`, `play_move`,
  `game_state` (12 tasks total); new messages TakeSeat/SeatTaken,
  StartGame/GameStarted, PlayMove/MovePlayed, GetGameState/GameState;
  CreateGame/GameCreated carry board_size, seats, turn_deadline_ms, ko_rule,
  bot_ms (the free-form `options` string is removed); six new positive
  properties and five new never-proofs; markdown `rules` and `params`.
- `spec/Requirements.proto`: matching declarations plus SeatView and MoveRecord
  (syntax checked with protoc).
- `spec/Implementation.lean`: bindings for the eight new messages and
  `gameplayDecisions` mapping each material requirement to a control.
- `book/main.tex`: chapter "N-player Go play revision" with the rule decisions
  and two generated state-machine figures; both PDFs rebuilt.

Check: Lean 4.28.0 elaboration of both files, `validateRequirementSpec`,
`validateRequirementProtoFile`, `validateImplementationSpec` and `tasksJson`
with the same driver as `scripts/chatui_specification.py` — 0 errors,
0 warnings, 12 task views in `spec/tasks.json`. Run without bwrap in a cloud
workspace; rerun LeanFM's own check to replace this evidence.

## Negative requirements → controls → tests
| Forbidden | Control | Test |
|---|---|---|
| move for another seat / out of turn | seat-to-move identity check, bots excluded | TestMovesAreAuthorizedOrderedAndRuleChecked |
| two transitions for one turn | turnSeq under the server lock; replay cache | same; TestBotNeverMovesForAHuman |
| move accepted after its deadline | deadline re-checked on arrival; timeout applied first | TestLateMoveLosesToTheDeadline |
| stale bot result applied | bot result bound to game ID + turnSeq | TestBotNeverMovesForAHuman, TestAllBotGamePlaysToTheEnd |
| hash collision rejects a legal move | exact situation compared behind Zobrist key | TestSituationalSuperkoUsesExactPositions |
| outsider reads/changes a game | game + room membership checks | TestSeatsStartAndBotsFillEmptySeats, TestMovesAre… |
| non-creator starts / seat changes after start | creator + status checks | TestSeatsStartAndBotsFillEmptySeats |
| unbounded bot computation | search outside lock, time budget, 200k-node cap, min(8, CPUs/2) slots | TestAllBotGamePlaysToTheEnd (race) |
| games that never end | passes, timeout round, 3·N² cap | TestPassesEndTheGame, TestDeadlineTimesOutAndAbandonmentEnds |

`go test -race ./...` passes (go-test.log). Headless browser runs: two people
and a bot on 9×9 (browser-three-seats.png); one person against a bot on 5×5
played to the end with the result announced in game chat (browser-finished.png,
browser-play.json). No page errors.

## Remaining limits
Teams/merges, handicaps, ratings, persistence, game-record export, push
updates (the page polls every 0.5 s while playing), and protobuf byte
conformance of the local JSON harness.
