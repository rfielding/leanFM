# Durable project handoff

Goal: reach a working local rooms/challenges/chat application quickly, then
refine its software specification through use. The conversation is disposable.
The accepted server-only slice still defers Go boards and gameplay.

Run from `source/` with `make run`. The local application uses loopback port
8081, independently of LeanFM on 8080; `make run PORT=8090` selects another port.
`spec/runtime.json` is the machine-readable launch contract. Validate a fresh
build, a real HTTP response and representative application requests before
claiming it runs. Record failures and verified fixes below `reports/` and `logs/`.

The typed requirements/protobuf/implementation and their protected checked gates
remain authoritative for the server core. The existing local HTTP demo is its
inspection harness; it is not a completed production account/authentication
system or evidence of protobuf byte conformance. Self-authored tests alone do
not establish full refinement. Preserve the source-review counterexamples and
close them with independent evidence when fixed.

Known earlier failures: the generated launcher used LeanFM's port 8080; its
snake-case browser fields did not decode into untagged Go structs. The accepted
channel mapping requires blocking on full, while the generated test asserted
an immediate full error. Launch repair evidence is in `reports/launch-repair/`.

For another agent or a PR: read this file, the central book and all canonical
specifications; inspect current source, run the proportional checks and runtime
check, retain exact base revisions and diffs, and report remaining conformance
gaps. Never require deleted chat to reconstruct defaults or justify changes.

## October 25 room/browser request

The user requested removal of fake links, a place to create chat rooms and game
challenges inside rooms. The pasted Anthropic HTTP 400 was a low-credit billing
failure; no successful provider edit is established by that attempt. Inspection
found a hard-coded demo UI, no CreateRoom request/route, and no fake anchors in
the current source. A legacy CreateRoom provisioning helper is insufficient for
the correlated typed contract. The proposed requirements add CreateRoom and
RoomCreated, retain challenge names in results/listings, and specify real browser
controls with isolated conversations. See reports/rooms-browser-review/review.md
for defaults, negative requirements and proposed controls/checks. Prior acceptance
records are preserved; this changed revision has not been accepted. Implementation
source is unchanged pending the explicit gates. The launch manifest port (8082)
and make run default (8081) disagree and must be reconciled in implementation.

## Implemented room/browser revision

The stakeholder explicitly accepted the changed requirements and the separate
checked implementation mapping. Protected controller records and review
acceptance evidence retain both exact revisions. The prior seven-task slice is
extended by typed CreateRoom/RoomCreated; the browser uses that correlated
operation rather than the legacy provisioning helper. Named challenge results
and listings retain their stored names.

The application now has room creation/selection, room chat, named challenge
creation/opening and separate challenge chat, using real lists and scoped
history. Plain text DOM rendering and selection-generation guards prevent
markup execution and stale responses crossing views. Strict bounded JSON,
Host/Origin checks and membership checks remain. The replay cache now rejects
new mutation admission at its bound instead of evicting accepted results.
The previously recorded blocking-channel counterexample is closed by the
preserved independent probe running against the repaired current source.

Uniform Make targets are build/run/stop/test/check/clean/serve; run is foreground
and serve aliases it. Standalone launch and spec/runtime.json both use 8081.
The runtime wrapper verifies PID start identity and exact project command before
stopping. Relative asset/API URLs and a storage fallback support LeanFM's
opaque isolated preview. App state remains in memory, with no playable board
or production account registration.

Verification: source make check passed including core/HTTP race tests and the
independent channel probe; browser_check.py passed real two-user room/challenge
creation/chat, unauthorized history, literal markup and delayed-response checks.
The project-confined startup check observed the actual launcher and page.
LeanFM's separate native launcher was verified through the real served preview,
including this app's room/challenge/chat flow, rather than a dead loopback link.
The latest evidence hashes identify the checked inputs.

Existing audit scope remains: handwritten Go message types and this inspection
adapter do not establish full deployed protobuf/event semantic refinement.
This change makes the requested application slice usable and records those
limits. Source and tests cite requirement IDs; source/traceability.json retains
the mapping. Repository base observed for this work is
b2b9756493de18b29cd3f62d7234cc6c0ac9b7a2. No commit, push or remote PR is claimed.

## October 26 N-player Go play revision

The stakeholder asked (in a Claude session) to complete the KGS-style server:
challenge creation takes the N-Player Go Lab board parameters, and seats not
taken by people are played by MCTS bots that run in the server. The candidate
adds take_seat, start_game, play_move and game_state, changes CreateGame
parameters (options string replaced by bot_ms; ko_rule 0 Auto / 1 Off / 2 On),
and records rule decisions in the book chapter "N-player Go play revision".
The earlier chat "accept" answers for the board-parameter revision were never
recorded by the controller; that revision is superseded by this one.

Source: engine.go (rules + max^n UCT search ported from the Lab), game.go
(seats, start, moves, deadlines, bots, state), cmd/demo routes and a dark-only
canvas board. Situational superko compares exact positions behind Zobrist keys.
A late move loses to its deadline. Verification: go test -race ./... passes
(engine, gameplay, HTTP wire tests); a headless two-person-plus-bot browser
game is recorded in reports/gameplay-review/. The specification check ran in a
cloud workspace with the same Lean driver but without bwrap; rerun LeanFM's
own check to replace that evidence. Both gates for this revision are pending
until the stakeholder accepts them in LeanFM.

## October 26 Lab parity revision (seats, teams, history, search)

Request: make the server game behave like the N-Player Go Lab — choose bot vs
person per seat, teams that people merge, navigate history and play out
alternatives, see MCTS estimations — and exercise book -> grammar/tasks -> gates
-> one-shot implementation so this chat can be deleted.

Stakeholder decisions (all four recommended options): creator plans seats
bot/open and owners can switch autopilot; preset teams plus consensual permanent
merges (bots follow their team's people; all-bot teams cannot merge); watchers
analyse anytime, seated players after the game ends; bot search summaries
published with each bot move. Recorded in book chapter "Lab parity revision"
and spec markdown sections seats/teams/analysis/params.

Spec: 21 tasks including composed game_lifecycle (refs create_game, seat ops,
start_game, turn, set_autopilot, team_merge, chat, state), turn, bot_turn (late
result discarded), team_merge; actor Bot (population 8). Checked with LeanFM's
driver in a cloud workspace (no bwrap): 0 errors. Both gates accepted by the
stakeholder in chat; hashes in reports/lab-parity-review/acceptance-evidence.json.
Record them with LeanFM's acceptance controls (the controller file was not edited).

Code: engine.go (Search returns Lab summary; Rewards with modes and teams;
cleanup respects teams), bot.go (BotPool), game.go (seat plan, autopilot, merges,
bowl, incremental GameState), static/engine.js + search-worker.js (Lab engine,
unchanged) and gameview.js (Lab viewer against server state). CSP adds
worker-src 'self' and img-src blob: data:. go test -race ./... passes; headless
three-person browser run recorded in reports/lab-parity-review/.

Known limits: analysis gating is a browser convention; historical team changes
are shown with current teams in the viewer; polling every 0.5 s while playing.
Next idea from the stakeholder: CTL witnesses for possibly/E and counterexamples
for never/A as checker output (LeanFM selfhost.checker).

## Book usage tour (October 26)

source/book_tour.py (make book-tour in source/) drives the real app with alice
(creator), bob (player) and carol (watcher) in headless Chrome over DevTools,
captures eight named screenshots into book/assets/tour/ with manifest.json
(steps, viewer, image and source hashes, browser), and writes book/tour.tex,
which book/main.tex includes as the chapter "Usage scenarios". CHROME selects the
browser binary; TOUR_PORT (default 8095) keeps it off 8080/8081.

The first tour exposed a real bug: with people passing, a far-ahead bot filled its
own territory because the soft-margin reward saturates near 1. Fixed by breaking
near-ties on projected score (engine.go pickMove; test
TestWinningBotPassesInsteadOfFillingItsTerritory) and recorded as an
implementation decision; the implementation gate needs re-acceptance for the
new hashes in reports/lab-parity-review/acceptance-evidence.json. The browser's
local analysis still uses the unchanged Lab engine, which has the same saturation.
