[![Lean Action CI](https://github.com/rfielding/leanFM/actions/workflows/lean_action_ci.yml/badge.svg?branch=main)](https://github.com/rfielding/leanFM/actions/workflows/lean_action_ci.yml)

# LeanFM

**A programming language whose programs are protocols.**

[Read the book (PDF)](book/main.pdf) · [Dark PDF](book/main-dark.pdf) ·
[Videos](#watch-it-work) · [Use it from Claude Desktop](#leanfm-in-claude-desktop)

A protocol names the roles in a conversation, the messages between them and their order, who
decides at each choice, what is assumed about decisions nobody else can see, and what the system
promises. Everything else in a LeanFM project is generated from the protocol or checked against
it: the diagrams people read, the requirements and implementation mapping reviewed in git, the
interfaces, the code each role is written on, and the verdicts on what the running system logs.

Most LeanFM is written by an LLM. You say in ordinary words what the software must do; the model
writes the protocol; LeanFM checks it and shows what it means, as diagrams, obligations, witnesses
and counterexamples. You push back, the protocol changes, the pictures change with it, and only
then is code written. The model learns the language from LeanFM itself: its server speaks the
Model Context Protocol and hands any agent that connects the language reference and the tools.

![Two real GoServer games at once: four people on 11×11, three on 9×9](book/assets/readme/goserver-games.png)

*Two games of N-player Go running on one server: four people on an 11×11 board, three on a
9×9, each a real browser. LeanFM reads the traffic they make, untangles it into sessions using
nothing but the protocol, and proves what the protocol promises
([video](video/goserver/leanfm-goserver-live.mp4)).*

---

## LeanFM in Claude Desktop

LeanFM's MCP server runs as a child process of Claude Desktop, over standard input and output. It
needs no API key, no port and no account: none of its tools calls a model, and Claude's own turns
belong to your Claude subscription. Every tool is read-only: none changes a file, and none runs
submitted text as code (protocol text is read by a parser for its grammar alone).

### Set it up

```sh
git clone https://github.com/rfielding/leanFM.git && cd leanFM
lake build leanfm-mcp                       # needs elan (https://github.com/leanprover/elan)
python3 scripts/claude_desktop_config.py --root "$PWD" --install
```

Then quit and reopen Claude Desktop. The script adds one `leanfm` entry to
`claude_desktop_config.json` (keeping your other servers and writing a backup first): Claude
Desktop runs `leanfm-mcp --stdio --root <this checkout>`. Rerun `lake build leanfm-mcp` after a
`git pull`, and restart Claude Desktop so it starts the new binary.

- **LeanFM on another machine?** Build it there and install with `--ssh HOST`: Claude Desktop then
  runs the server over ssh (`scripts/claude_desktop_config.py --help`).
- **claude.ai or the mobile apps?** The same executable serves MCP over HTTP behind TLS as a custom
  connector: see [`deploy/mcp/README.md`](deploy/mcp/README.md).

### Things to ask

- *"Use LeanFM to design a library-lending service as a session type, check it, and animate a
  stream of 20 borrowers."*
- *"Browse the GoServer specification (`example: goserver`) and show me how a move is answered."*
- *"Here is a log from my server. Check it against the protocol with `session_conform` and tell me
  which sessions break it."*
- *"Is it possible that a payment is charged twice? Ask `session_ctl` and show me the path."*

Start from the `design_with_session_types` prompt: it walks from the roles to a checked protocol,
each role's typestate, code that logs its messages, and `session_conform` on those logs.

### The explorer

The session tools declare an MCP Apps view, so Claude Desktop draws their answers inline, and the
view is an explorer as well as a picture:

![The session view in Claude Desktop: a log of two logins served by one Shop thread](book/assets/readme/explorer-stream.png)

*A real `session_conform` answer as the view draws it: one lifeline per actor (each browser
instance its own), each thread in its own colour with a legend, the sessions LeanFM derived from
the log (two logins and two orders, each order a child of its login), the event log, and the
selected event as JSON.*

- **The protocol in an editor** that LeanFM rechecks after each pause, with a sketch where clicking
  two lifelines adds a message.
- **Generated sequence diagrams**: frames fold and open, an included protocol opens on its own
  diagram, and clicking an actor shows its state machine.
- **Each role's view**: its typestate API, the steps it takes part in, the OpenAPI document it serves
  and its payloads.
- **The event stream, animated**: per-actor lifelines; threads (each actor's own order, its `prev`
  chain) in colour; a highlight that lights one session or thread in the whole mashed-together
  diagram; clicking an event focuses on its thread and frames the sessions it formed, a child inside
  its parent.
- **A walk-through** of one session, one allowed step at a time (`session_next`); **CTL** with
  suggested properties built from the protocol, each decided with its path; **datasets** of up to
  10,000 sessions charted by path, message, role load, length and duration.

### The tools

| Group | Tools |
|---|---|
| Design and check | `session_check`, `session_review`, `session_diagram`, `session_explore`, `session_actor`, `session_types`, `session_openapi`, `session_skeleton`, `session_compat` |
| Behaviour | `session_simulate`, `session_next`, `session_dataset`, `session_mdp`, `session_sla`, `session_instances` |
| Real runs | `session_conform` (a log against the protocol, sessions derived when the log names none), `session_spans` |
| Questions | `session_ctl` (temporal properties, with witnesses and counterexamples), `check_ctl`, `explain_formula`, `knows` (what an actor can derive) |
| Security | `check_protocol` (attacks on a security protocol), `check_reassembly` (stream-reassembly evasions) |
| Projects | `project_view`, `requirements_interrogation`, `code_generation_prompt`, `validate_generated_artifacts`, `classify_requirement`, `server_logs` |

The full list, with every argument, is generated into the book's chapter *Asking LeanFM* from the
server's own tool list.

---

## Watch it work

Every frame in these videos is drawn from LeanFM's own answers, saved beside each video, never a
hand-drawn substitute.

### GoServer, live ([video](video/goserver/leanfm-goserver-live.mp4))

Two real games, the traffic from seven browsers, what LeanFM found when the specification first met
that traffic, and the protocol turned into CTL.

![930 API calls from seven browsers: the flat diagram](book/assets/readme/goserver-traffic.png)

*On the wire: 930 calls from seven browsers in one interleaved stream, each person's colour. This
is the flat diagram, the union of every actor and every message.*

On first contact, 7 of 58 sessions broke the protocol: every browser asks for the game list while
its previous request is still unanswered. The browser polls; the protocol said one request at a
time. The protocol was wrong, so it changed, and the same log now conforms.

![Seven people, two games, and the joins between them](book/assets/readme/goserver-untangled.png)

*Untangled with no session ids in the log: seven person sessions, two game sessions (each a child
of its creator), and 49 joins, each seat, move and game-state request belonging to its person and
its game at once.*

![GoServer's session type as CTL, each formula beside its diagram](book/assets/readme/goserver-ctl.png)

*GoServer's session type as 78 CTL formulas, every one proved over its 10,969-state graph, each
shown beside the diagram it comes from with its messages in the formula's colour.*

### Diagrams as CTL ([video](video/ctl/leanfm-diagrams-as-ctl.mp4))

What does an interaction diagram mean, exactly? Turn every diagram into CTL and let a model checker
decide it. A full diagram is one session (follow TCP stream); a flat log is many full diagrams
drawn over one another, and only `cause` and `prev` untangle it.

![PlaceOrder: forty formulas, all proved](book/assets/readme/forty-formulas.png)

*PlaceOrder's structure gives forty formulas, all proved; every deliberately broken variant fails a
named formula ([`reports/ctl-translation`](reports/ctl-translation)).*

### Session separation ([video](video/sessions/leanfm-session-separation.mp4))

A log rarely says which event belongs to which conversation. LeanFM separates them using only what
the protocol declares: a cause ties an answer to its request, `Fresh` mints a session id, `Link`
names it again, and `given`/`with` hand an included task its parent's id.

![Each order is a child of the login that ran it](book/assets/readme/child-sessions.png)

![Threads: each actor's own order, its prev chain](book/assets/readme/threads.png)

*Children (each order a child session of its login) and threads (one server thread serving two
orders in turn: a thread runs through many sessions, and a session through many threads).*

---

## The book in brief

The [book](book/main.pdf) (50 pages; [dark](book/main-dark.pdf)), *Session Types as CTL*, shows
that a multiparty session type is exactly a set of CTL formulas, one per state the conversation can
be in, and proves it. Every listing, typestate graph, rule, table and MCP answer in it is generated
by `CtlBookExample.lean` through the same functions LeanFM's tools call.

**Part I, the protocol language.**
- *Global Types*: roles, messages, causes, choices, loops, bounded loops, `par`, `sessions` and
  `include`, on a request with two answers (`GET /images`: 200 or 404) and a three-party purchase.
- *Projection and Well-Formedness*: each role's local type, and the two ways a protocol is
  unplayable (a race, a role that cannot tell).
- *Where Clauses, Identity and Logs*: conditions on data, sessions derived from causes and marks,
  GoServer's games and seats as sessions that fork and join, and where clauses as the wire form of
  `prev` and `cause`.

**Part II, from session types to CTL.**
- *The Checker Model*: the state graph, the Kripke structure, the atoms, CTL and bisimulation.
- *Faithful CTL*: typestates as bisimulation classes, a characteristic formula naming each, and the
  theorem: a system satisfies the faithful rules if and only if it is bisimilar to the protocol,
  which no CTL can improve on.
- *Construct by Construct*: what each construct costs in typestates and lookahead; hidden counters;
  `par` as a product; sessions decomposing it; deterministic typestates, `prev`, and the linear
  walk, with its proof.
- *Deciding It*: faithfulness as one bisimulation check, CTL evaluated over a hash-consed DAG in
  O(distinct subformulas x model), formulas that share, and the protocols in this repository.

**Part III, the LeanFM MCP server.**
- *Asking LeanFM*: connecting Claude Desktop, the tools, and real request/answer pairs for
  `session_check`, `session_ctl` (formulas, suggestions, faithful rules, faithfulness),
  `session_next`, `check_ctl` with shared formulas, `session_conform` and `session_openapi`.
- *Case Studies*: GoServer, IslandUploads (where the hidden state is, and how `prev` removes it),
  and LeanFM's own protocol.

## Sessions, threads and CTL

The newest work, in [`LeanFM/LLMGenerated/SelfHosting.lean`](LeanFM/LLMGenerated/SelfHosting.lean)
(`selfhost.session.identity.*`, `selfhost.session.correlation`, `selfhost.session.ctl-translation`):

- **Identity is declared in the protocol text.** `Fresh` mints a session id and `Link` names it,
  placed in a header, path, query or body; ids are unique among open sessions and freed when their
  session ends, like file descriptors. Marks can come from a `.proto` as trailing comments
  (`string session_id = 1; // fresh`), so the file stays plain proto3.
- **Nested protocols get their ids explicitly.** `protocol Order (Client, Shop) given token` and
  `include Order Client Shop with token = sid`. A task run in a `sessions` block is a child of the
  session that ran it; a task given two ids minted by two sessions is a join (a move belongs to its
  player and its game).
- **Threads and sessions are two cuts of one log.** A thread is one actor's own order (its `prev`
  chain); a session is one protocol instance across actors.
- **Where clauses implement the chain on the wire** (`p.requestId = m.requestId`), and channel
  behaviour is which implicit constraints hold: a lossy or reordering channel is the same diagram
  with fewer constraints.

## Projects in this repository

Each is a complete LeanFM project with its own book, requirements, implementation mapping and source:

- [`projects/GoServer`](projects/GoServer): N-player Go with rooms, challenges, bots, teams, claimed
  names and a ranking, a Go server and a React browser app. LeanFM's main example.
- [`projects/Maqam`](projects/Maqam): a live-coding sequencer for just-intonation maqam,
  reverse-engineered from Rust into a specification and implemented again in Zig against it.
- [`projects/PaxosKV`](projects/PaxosKV): a three-replica Paxos key/value database
  (`make paxos-check`).
- [`projects/IslandUploads`](projects/IslandUploads): file uploads across islands that may be
  partitioned for a day.

## Working on LeanFM

LeanFM is developed with the LeanFM method: a change starts in its own requirements
(`LeanFM/LLMGenerated/SelfHosting.lean`), then the implementation mapping
(`SessionImplementation.lean`, `McpLogicImplementation.lean`), then the source, each checked before
the next. Review and acceptance happen in git. See [`AGENTS.md`](AGENTS.md) and
[`SKILL.md`](SKILL.md).

```sh
make check        # build everything and run every check (needs bubblewrap; see below)
make serve        # the web server and MCP over HTTP on 127.0.0.1:8080
make book         # the LaTeX book and its dark copy
make go-toolchain # the checksum-pinned Go toolchain under .toolchains/
make http-check   # check the live server's routes after make serve
```

- **Claude Code**: `make claude` starts Claude with the project's history, memory and configuration
  under `.cache/claude/`; [`.mcp.json`](.mcp.json) connects it to `make serve`'s endpoint.
- **Cursor**: [`.cursor/mcp.json`](.cursor/mcp.json) points Cursor Agent at the same endpoint
  ([`CURSOR.md`](CURSOR.md)).
- **The chat UI sandbox**: `make check` includes `make chatui-check`, which needs Linux `bwrap`
  (the `bubblewrap` package) with working user, PID and network namespaces. A missing or denied
  sandbox is an environment failure, never a reason to skip isolation tests.

What LeanFM does not yet do is listed in [`CRITIQUE.md`](CRITIQUE.md).
