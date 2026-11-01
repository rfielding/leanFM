# Reduced server-only candidate requirements

Status: checked candidate; requirements acceptance and implementation acceptance remain pending.

Scope authority: the project conversation question basic_server_requirements_gate was answered formalize_basic_server. This authorizes preparation and checking, not either formal gate.

Positive invariant: each accepted request acts for its authenticated caller in one explicit room/game scope and returns one correlated authoritative result. Gameplay is deferred.

The current project book chapter records this reduced scope; earlier gameplay chapters are roadmap material. Implementation and source have not been changed.

## Derived task views

- List the available chat rooms: [list_rooms interaction](list_rooms.interaction.mmd), [state machine](list_rooms.state.mmd).
- Enter a room and inspect its game list: [enter_room interaction](enter_room.interaction.mmd), [state machine](enter_room.state.mmd).
- List room games and open challenges: [list_games interaction](list_games.interaction.mmd), [state machine](list_games.state.mmd).
- Create a named room game or challenge: [create_game interaction](create_game.interaction.mmd), [state machine](create_game.state.mmd).
- Watch or enter a game chat container: [join_game interaction](join_game.interaction.mmd), [state machine](join_game.state.mmd).
- Send room chat: [room_chat interaction](room_chat.interaction.mmd), [state machine](room_chat.state.mmd).
- Send game chat: [game_chat interaction](game_chat.interaction.mmd), [state machine](game_chat.state.mmd).

## Reviewable defaults and bounds

Existing server sessions identify callers. A game/challenge is a navigable chat container; watch/join grants chat membership, not Go move authority. Proposed bounds are names up to 128 characters, chat up to 4000 characters, and 100 retained entries per room/game conversation. The 100-person population is a capacity forecast, not measured throughput.

Rejected authentication, scope, input, overload or conflicting replay requests cannot mutate state or disclose private data. Duplicate mutation request IDs return the prior result without creating duplicate games or chat entries. Sender identity and timestamps are server-derived; room and game chat remain separate.

## Validation boundary

Real Lean elaboration, protobuf agreement, seven task FSMs/grammars, communicating processes, positive properties, negative proof obligations, and fourteen prompt-derived output requests passed. These checks establish structural specification validity, not a proof of deployed software correctness. Realization controls and negative implementation tests require the separate implementation mapping after requirements acceptance.

See ../specification-check/validation.json for exact source/book hashes and output provenance.
