# Requirements Logic: a tour of the book

`requirements-logic-tour.mp4` follows the book by doing what it describes: a real shallow clone of
LeanFM from GitHub, Claude Desktop connected over MCP, TicTacToe from one prompt to its diagram and
proofs, the one function CTL is made of (checked by Lean, and caught when a claim is made false),
faithful rules, and the guinea pig cage with claims over measurements (`check_signal`).

It covers the book in order, in about half an hour: the protocol language construct by construct
(Images, PlaceOrder, loops, parallel, include, the OpenAPI a protocol implies, a protocol as a set of
runs), what makes a protocol unplayable (a race, a blind choice, a borrowed cause, an unrealizable
deployment), projection to each role's typestates, CTL and its one function, the faithfulness
guarantee in detail (typestates, the theorem, what hidden state costs, an unfaithful candidate, the
pair no log can tell apart, porting through the specification), where clauses and identity, GoServer
watched live, the cage, the costs, requirements lists and LeanFM checking its own MCP traffic.

What is real and what is re-enacted:

- Every terminal line was printed by the command shown (`capture.py` runs them; paths are shown
  relative to `~/code`). The first build of a fresh clone takes a few minutes and is not shown.
- The Claude Desktop chat is re-enacted (drawn), but every tool call in it is a real call to the
  running server and shows LeanFM's real answer (`fetch.py`), including the issue LeanFM notes on the
  first TicTacToe draft.
- GoServer is watched live (`live.py`): a fresh game between two server bots, its board captured in
  GoServer's own web app every 40 seconds, and each time `session_conform` reading the new lines of
  `GoServer/events` (from the previous answer's `nextLine`) against the protocol `Turn`. Other games
  on the same server may still be running, so a poll can count their open turns too.
- LeanFM's check of its own MCP traffic is shown as it is: one session in the log, written by an
  older build, breaks the protocol, and the check says so.
- Every diagram, verdict, margin and chart comes from LeanFM; the cover drawing is the book's
  hand-drawn cover.
- The narration is a local, synthetic Piper voice.

Rebuild (with `make serve` running, GoServer running (`make run` in `projects/GoServer`), and `logs/devices.log` holding the cage log, for example
`cp examples/guinea-pigs/cage.log logs/devices.log`):

```sh
make video-tour
```

`ONLY=<scene> python3 video/book-tour/produce.py` renders one scene's picture into `build/`.
