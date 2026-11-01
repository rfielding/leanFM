# GoServer

A working local, in-memory N-player Go server in the spirit of KGS, with the
viewer of the stakeholder's N-Player Go Lab. Create a challenge with board size,
players, deadlines, ko rule and bot settings; plan each seat as Person or Bot and
group seats into teams; people take seats; Start fills empty seats with
server-side Monte Carlo tree search bots. During play a seated person can let a
bot play for them (autopilot) and take the seat back, and teams can merge when
every person on both accepts. Every viewer can step through the game tree; each
bot move shows its search (candidates, projected scores, outlook), the
projected-score timeline and the per-capturer bowl. Watchers can branch and run
their own local search at any time; seated players can once the game ends.
Variations never reach the server. GIF export and sounds as in the Lab.
Handicaps, ratings, persistence and SGF remain deferred. The page is dark-only.

From `source/`, use `make build`, `make run`, `make stop`, `make test`,
`make check`, `make clean`, or `make serve` (an alias for foreground `run`).
The standalone app listens on `127.0.0.1:8081`; `make run PORT=8090` selects
another port. `make stop` checks owned process identity and leaves unrelated
listeners alone. All application state resets on restart.

In LeanFM, select GoServer and use **Start app**, then **Open app**. The native
launcher verifies readiness, keeps the isolated instance running and posts the
served preview link in Chat. Use that link for remote browser access. **Stop
app** and a stale revision's **Restart app** control the owned instance.

Bot searches run outside the game lock with a time budget, a node cap and at most
min(8, CPUs/2) at once. Names are bounded to 128 Unicode characters, chat to 4,000, retained history to
100 entries per conversation, rooms to 16 and challenges to a global 64. Sessions
have a finite mutation admission budget; accepted results remain replay-safe
instead of being evicted and applied twice.

Read `book/main.pdf`, `spec/Requirements.lean`, `spec/Requirements.proto`,
`spec/Implementation.lean`, the protected gate snapshots and
`spec/ProjectMemory.md` to resume. `source/traceability.json` maps the changes
to controls and tests. Evidence is in `reports/rooms-browser-review/` and
`reports/runtime-check/`. Run `make check` in source for build/race checks and
`python3 browser_check.py` there for the real two-user Chrome flow.
