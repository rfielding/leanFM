# TicTacToe with LeanFM: a walkthrough

`tictactoe-walkthrough.mp4` (about two minutes) goes once around the loop the book's Chapter 2 shows
in pictures: connect Claude Desktop to LeanFM, ask for TicTacToe and see its source, then the
diagrams LeanFM generates from it (the requirements list, the interaction diagram, simulated games),
LeanFM's viewer inline in the chat, a small TypeScript implementation played and its log checked,
and a video asked for.

What is real and what is re-enacted:

- The chat frames are drawn (re-enacted). Every tool answer in them is LeanFM's real one.
- Every screenshot of LeanFM's viewer is the real viewer, opened by `make serve`'s standalone page
  (`/view?project=LeanFM&file=examples/sessions/TicTacToe.leanfm`) in headless Chrome.
- The game is `book/examples/tictactoe.ts`, played in headless Chrome; the Referee's log is checked by
  `session_conform` against the protocol.
- The narration is a local, synthetic Piper voice.

Rebuild, with `make serve` running:

```sh
make video-tictactoe
```

`capture.py` writes `data/` and the book's `book/generated/walk-*.png`; `produce.py` draws the scenes,
narrates them and writes the video. `ONLY=<scene> python3 video/tictactoe/produce.py` renders one scene.
