# GoServer

A local, in-memory N-player Go server in the spirit of KGS, with the viewer of
the N-Player Go Lab. Rooms and chat; challenges with board size, seat count,
clocks, ko rule and bot settings; the creator plans each seat as person or bot
and groups seats into teams; Start fills empty seats with server-side Monte
Carlo tree search bots. During play a person can hand their seat to a bot
(autopilot) and take it back, and teams merge when every person on both
accepts. Every viewer steps through the game tree and sees each bot move's
search; watchers can branch and run their own local search, which never reaches
the server. The page is dark-only; all state resets on restart.

```sh
make run            # http://127.0.0.1:8081  (make run PORT=8090; never LeanFM's 8080)
make stop           # stops only the process make run started
make check          # spec-check (LeanFM canonical check) + app-check (go test -race)
make browser-check  # two users in headless Chrome (CHROME=... to override)
make tour           # replay the usage scenarios, refresh the book's screenshots
make views          # task state machines from spec/tasks.json into renders/
make book           # book/main.pdf and book/main-dark.pdf
```

`make spec-check` needs the LeanFM installation two directories up to be built
(`make build` there) and `bwrap`.

The record of the project is `book/main.pdf` (or the dark copy) with
`spec/Requirements.lean`, `spec/Requirements.proto`, `spec/Implementation.lean`
and `source/`. `source/traceability.json` maps requirements to code and tests.
The book's "Known gaps" chapter is the work queue. Review happens in git.

In LeanFM's chat UI, select GoServer and use **Start app**, then **Open app**;
`spec/runtime.json` is the launch contract.
