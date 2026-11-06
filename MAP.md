# Map of the LeanFM repository

Where everything lives, what produces what, and which check runs it. Surveyed at
commit `2694f18` (2026-11-05). Line counts are approximate. "Run by" names the
`make` target, CI step or script that executes a file; *nothing* means no target
does.

## The shape in one screen

```text
leanFM/
├── *.lean (22)          executables, book generators, reviews   → see "Root Lean files"
├── *.md (15)            agent instructions, guides, old notes   → see "Root documents"
├── Makefile             every workflow; `make check` is the full suite
├── lakefile.toml        one library (LeanFM) + four executables
├── LeanFM/              the Lean library: language, checkers, server, canonical specs
│   ├── Session/         session types, physics, knowledge, attacks, reassembly
│   ├── LLMGenerated/    LeanFM's own canonical requirements and implementation specs
│   ├── ChatUI/          the web workbench: server, store, provider, its own specs
│   └── ReferenceExamples/   the small request/response example the references embed
├── book/                the book: main.tex, chapters/, generated/, assets/, PDFs
├── scripts/ (56)        Python/shell/JS: ChatUI sandbox helpers, tests, data, video
├── ui/ + assets/        React bundle source; plain JS/CSS served by the server
├── projects/            three example LeanFM projects (GoServer, IslandUploads, PaxosKV)
├── reports/             review records and logs from earlier work
├── examples/            the bakery event corpus and its reduced statistics
├── evidence/            security notes for chat image attachments
├── video/               overview and Kerberos explainer videos (Manim sources, MP4s)
├── make/                a stale copy of the Makefile (see "Findings")
└── .github/ .codex/ .cursor/ .mcp.json   CI and agent configuration
```

Not tracked, created locally: `.lake/` (Lean build), `.cache/` (Go and project
caches), `.toolchains/` (Go, TLA+), `diagrams/` (output of `leanfm-diagrams`),
`logs/`, `ui/node_modules`, `ui/dist`.

## Root Lean files

The root holds 22 Lean files. They fall into four groups.

### 1. Executable entry points (Lake requires these paths)

`lakefile.toml` names each executable's root module, so these four stay at the
root unless the lakefile changes.

| File | Executable | What it does | Run by |
|---|---|---|---|
| `Main.lean` | `leanfm` | Prints `LeanFM.textReport` (per-task FSM and CTL checks) | `make run`, `make validate` |
| `Server.lean` (589) | `leanfm-server` | TCP listener and HTTP loop on 127.0.0.1:8080; hands requests to `LeanFM/ChatUI/Server.lean` | `make serve`, `make build` |
| `Diagrams.lean` | `leanfm-diagrams` | Writes Graphviz `.dot` files and an SVG gallery into `diagrams/` | `make diagrams` |
| `Validate.lean` | `leanfm-validate` | Prints the validation reports for the canonical requirements and implementation | `make validate` |

`LeanFM.lean` (20) is the library's umbrella module, which imports the core modules.

### 2. Book generators

Each one computes figures, tables or listings and writes them to
`book/generated/`. They are scripts (`lake env lean --run X.lean`), not library
modules.

| File | Lines | Writes (`book/generated/…`) | Chapter | Run by `make book`? |
|---|---|---|---|---|
| `SessionExample.lean` | 303 | `session-*.tex` (11) | Vision, Grammar, TFTP | **no** |
| `TopologyExample.lean` | 482 | `topology-*.tex` (8) | Vision | yes |
| `BakeryFlowExample.lean` | 191 | `bakery-*.tex` (10) | Bakery | yes |
| `ProbabilityOverlayExample.lean` | 135 | `overlay-*.tex` (7) | Generated examples | **no** |
| `StochasticUserMDPExample.lean` | 152 | `stochastic-user-*.tex` (4) | Authoring language | yes (also `mdp-example-check`) |
| `RuntimeReliabilityDiagram.lean` | 41 | `runtime-actor-network.tex` | Authoring language | yes |
| `NestedForkJoinExample.lean` | 75 | `nested-race.tex`, TLA+ provenance | Events | yes |
| `OAuthGrammarExample.lean` | 79 | `oauth-*.tex` (5) | Grammar, OAuth | yes |
| `MCPInteractionExample.lean` | 38 | `mcp-interaction.tex` | Web server | yes |
| `LogicInteractionExample.lean` | 71 | `mcp-logic-*.tex` | Web server | yes |
| `WebServerProtocolChapter.lean` | 136 | `web-protocol-*.tex` (7) | Web-server protocol | yes |
| `LegalDepositExample.lean` | 261 | `legal-*.tex` (6) | Legal example | **no** |
| `NeedhamSchroeder.lean` | 350 | `ns-*.tex` (12): Lowe's attack, reflection, defender, reassembly | Protocol exercises | yes |

`make diagrams` runs the same list as `make book`, minus `NeedhamSchroeder.lean`.
`SessionExample.lean` and `NeedhamSchroeder.lean` also carry `#guard` checks that
run whenever the file is elaborated.

### 3. Review generators

These derive review documents from the canonical specs.

| File | Writes | Run by |
|---|---|---|
| `ReviewSelfHosting.lean` | `SELF_HOSTING_REVIEW.md` | `make selfhost-check` |
| `ReviewResumableWork.lean` | `reports/resumable-work/*.mmd` | `make selfhost-check` |
| `ReviewSharedProjects.lean` | `reports/shared-projects/*` | **nothing** (run by hand) |

### 4. Nothing else

Every root Lean file is in one of the three groups above.

## `LeanFM/`: the library

### Session types: `LeanFM/Session/` (plus `Session.lean`, 22)

This is the newest layer, and what the book's first chapters describe.

| Module | Lines | What it is |
|---|---|---|
| `Global.lean` | 396 | Global types (`Global R`), inferred choice deciders, projection to local types, issue checks |
| `Syntax.lean` | 142 | The `protocol` notation (`choice … or …`, `par`, `join`, `rec`, `include`, `sessions`) |
| `Physics.lean` | 130 | Channel declarations and presets (`reliable`, `http`, `udp`, `stream`, `kafka`) |
| `Topology.lean` | 132 | Interfaces, scopes and the deployment tree |
| `Http.lean` | 55 | The HTTP call discipline: cut and un-cut |
| `Spec.lean` | 89 | Properties, assumptions, and what each channel handles |
| `Knowledge.lean` | 237 | Dolev–Yao terms, `Derives`, `analz`/`synth`, `knows` (proved sound) |
| `Attack.lean` | 434 | Protocols as role scripts, sessions, fresh values, the inline defender, model generation |
| `Reassembly.lean` | 187 | Stream reassembly evasion search (first-wins and last-wins overlap policies) |

`Session.lean` imports the first seven. `Attack` and `Reassembly` are imported
directly by `Logic.lean` and `NeedhamSchroeder.lean`.

### Logic and MCP: what agents call

| Module | Lines | What it is |
|---|---|---|
| `Logic.lean` | 1610 | All MCP logic tools: `explain_formula`, `check_ctl`, `check_trace`, `classify_requirement`, `knows`, `check_protocol`, `check_reassembly`; JSON formula parser; fixed-point CTL evaluator |
| `MCP.lean` | 291 | JSON-RPC dispatch at `POST /mcp`: resources, prompts, tool schemas, result wrapping |
| `Overlay.lean` | 233 | Probability and time overlays (declared and measured) over task models |
| `LogicTests.lean` | 438 | Logic tests: `make validate` |
| `MCPTests.lean` | 69 | MCP over JSON-RPC: `make validate` |
| `OverlayTests.lean` | 47 | Overlay tests: **run by nothing** |

### Requirements engine: the older core

| Module | Lines | What it is |
|---|---|---|
| `Artifacts.lean` | 1409 | `RequirementSpec`, `ImplementationSpec`, grammars (`GrammarExpr`), validation, language references, interrogation checklist, `optimalSupply?` |
| `Protocol.lean` | 1093 | Event envelope, actors, queues, task FSMs, trace semantics |
| `CTL.lean` | 142 | The small recursive CTL evaluator used by task metrics |
| `MDP.lean` | 206 | Nondeterministic and probabilistic transitions, bounded policy expansion |
| `StreamStats.lean` | 346 | Reconstructs attempts from observed events: completion, success and latency |
| `Characterization.lean` | 121 | The standard out-of-the-box derived properties and reducers |
| `Render.lean` | 1322 | Mermaid, DOT and SVG renderers, Paxos views, reports |
| `MDPDiagram.lean` | 95 | TikZ interaction diagrams and state machines for the book |
| `ReliabilityDiagram.lean` | 49 | Series, parallel and threshold topology view |
| `UiModel.lean` | 114 | JSON helpers and the aggregate-graph data the older graph view draws |
| `Assets.lean` / `StaticAssets.lean` | 88 / 48 | Static asset records; `StaticAssets` is generated by `scripts/embed_static_assets.js` |
| `Basic.lean` | 1 | Placeholder from the Lake template (`def hello`) |
| Tests | — | `ArtifactsTests`, `ProtocolTests`, `CTLTests`, `StreamStatsTests`, `PopulationTests`, `CharacterizationTests`: all run by `make validate` |

### `LeanFM/LLMGenerated/`: LeanFM's own canonical specifications

AGENTS.md calls these the self-hosting specs, kept here at a stable path.

| Module | Lines | Role |
|---|---|---|
| `Requirements.lean` | 786 | Canonical requirements entry point; composes ChatUI with the self-hosting workflow |
| `SelfHosting.lean` | 232 | The self-hosting clauses (25), including all `selfhost.mcp.logic.*` |
| `Implementation.lean` | 152 | Canonical implementation mapping |
| `McpLogicImplementation.lean` | 91 | Implementation decisions for the logic tools (`logic-protocol`, `logic-reassembly`, …) |
| `SharedProjects.lean` | 142 | Shared-project workspace component |
| `ResumableWork.lean` + `…Implementation` | 88 + 35 | Bounded provider batches with checkpoints |
| `ApplicationLaunch.lean` + `…Implementation` | 81 + 60 | Persistent app start, status and stop |
| `*.proto` | — | `Requirements.proto`, `SelfHosting.proto`, `ApplicationLaunch.proto` |
| Tests | — | `SelfHostingTests` (`make selfhost-check`); `ApplicationLaunchTests` (`make chatui-check`) |

### `LeanFM/ChatUI/`: the web workbench

| Module | Lines | What it is |
|---|---|---|
| `Server.lean` | 2396 | Every HTTP route, chat turns, tools, book builds, application launch |
| `Store.lean` | 605 | Projects on disk, accounts, encrypted credential envelopes |
| `Provider.lean` | 629 | OpenAI and Anthropic calls, tool loops, usage accounting |
| `HttpRequest.lean` | 59 | Strict HTTP framing (one Content-Length, size and time limits) |
| `Web.lean` | 39 | Embeds `assets/chatui.css`, `chatui.js` and the vendored Mermaid |
| `Requirements.lean` + `.proto` | 930 | ChatUI's own requirements, including the tool-dependency inventory |
| `Implementation.lean` | 389 | ChatUI's implementation mapping |
| `Traceability.json` | — | Decision-to-file traceability |
| `Validate.lean` | 37 | Traceability check (`make chatui-check`) |
| Tests | — | `ProviderTests`, `HttpRequestTests` (`chatui-check`); `CredentialTests` (`scripts/chatui_http_check.sh`) |

### `LeanFM/ReferenceExamples/`

`Request.lean` and `RequestImplementation.lean` are a complete small example. The
language references embed it with `include_str`, so their listings always compile.
Its tests run under `make validate`.

## `book/`

| Path | What |
|---|---|
| `main.tex` | Preamble, title page, preface, chapter order |
| `chapters/` (20) | One file per chapter. Parts: Session types (16 chapters), Security exercises (`csp-exercises`), Machine reference (`web-protocol`, `bootstrap-contract`), plus `referenced-books` |
| `generated/` (87) | Everything the generators write; never edited by hand. Each generator also leaves a `*-provenance.txt` |
| `assets/ui-tour/` | Chat UI screenshots, accessibility and keyboard traces, `manifest.json`; checked by `scripts/check_ui_tour.py` |
| `examples/` | Files the book includes: `oauth.proto`, `oauth-granted.bytes`, `bakery-generated.go`, `tla/` (the TLA+ comparison) |
| `logic.lean` | Unchecked side experiment ($1+2+3+\cdots$); needs Mathlib; not built |
| `references.bib` | Bibliography |
| `Makefile` | `light` and `dark` builds: pdflatex, bibtex, makeindex, pdflatex ×2 |
| `main.pdf`, `main-dark.pdf` | The built book; both tracked |
| `update` | Copies both PDFs into `../../rfielding.github.com` and pushes them |

## `scripts/` (56 files)

| Group | Files |
|---|---|
| ChatUI sandbox and runtime helpers, called by the server | `chatui_command.sh` (dispatcher), `chatui_command_runner.py`, `chatui_specification.py`, `chatui_runtime.py`, `chatui_application.py`, `chatui_workspace.py`, `chatui_work_state.py`, `chatui_project_state.py`, `chatui_media.py`, `chatui_gif.py`, `chatui_mp4.py`, `chatui_patch.py`, `chatui_crypto.py` |
| ChatUI tests (`make chatui-check`) | 11 `chatui_*_test.py` files, `check_ui_tour.py`, `chatui_http_check.sh`, `chatui_sandbox_check.py` |
| Other tests | `chatui_application_test.py` (`make application-check`); `chatui_pdf_test.py`, `chatui_session_test.py`, `chatui_shared_projects_test.py`, `chatui_reset_test.py`, `chatui_multi_provider_test.py`, `chatui_provider_outcome_test.py` (run from `chatui_http_check.sh`) |
| Test fixtures | `chatui_provider_stub.py` (fake model provider), `chatui_prepare_test_project.py` |
| UI snapshots | `chatui_ui_snapshots.sh` (`make ui-snapshots`) |
| Bakery data | `generate_bakery_events.py` (`make bakery-data`), `reduce_bakery_events.py` (`make bakery-stats`, `make validate`) |
| Build helpers | `embed_static_assets.js`, `format_assets.js` (`make scripts`), `invalidate_include_str.py` (`make build`) |
| Checks | `roundtrip_generated_scenario.py`, `http_smoke.py`, `check_tla_example.py`, `validate_video_overview.py` |
| Video | `prepare_video_narration.py`, `render_video_narration.py` |
| Session launcher | `claude.sh` (`make claude`) |
| Python packages | `chatui_requirements.txt` |
| **Referenced by nothing** | `chatui_browser_reset.py`, `chatui_specification_fixture.py`, `chatui_ui_tour.py`, `check_listing_unicode.py`, `reset_leanfm_workspace.py` |

## `ui/` and `assets/`

- `ui/src/` holds `main.tsx` (718), `api.ts`, `types.ts`. Vite builds it into
  `ui/dist/react-app.js`. This is the React workbench, built by `make ui-build`.
- `assets/` holds plain JavaScript and CSS that the server embeds with
  `include_str`: `chatui.js` and `chatui.css` for the chat, and
  `subjectGraph.js`, `aggregateGraph.js` and `assistant.js` for the older graph
  views. It also holds `vendor/` (Mermaid, with its version, license and digest).

## `projects/`: example LeanFM projects

Each project is a self-contained root with `manifest.json`, `AGENTS.md`,
`book/`, `spec/` and `reports/`.

| Project | Files | What |
|---|---|---|
| `GoServer/` | 104 | Multiplayer Go game server: `spec/` with `Session.lean`; `source/` with Go and a React app; a screenshot book tour |
| `PaxosKV/` | 65 | Paxos key-value store over UDP: `spec/PaxosUdp.lean` and `Views.lean`; Go source; `make paxos-check` runs its checks |
| `IslandUploads/` | 77 | File uploads replicated across partitionable islands: spec plus MCP-checked models in `reports/mcp/`; no source yet |

## `reports/`, `examples/`, `evidence/`, `video/`

- **`reports/`**: review records from finished work, not inputs to any build.
  - `application-launch-review/` holds its own `Review.lean` files and logs.
  - `shared-projects/` is written by `ReviewSharedProjects.lean`.
  - `resumable-work/` is written by `ReviewResumableWork.lean`.
  - `chatui/`, `chatui-ci/`, `named-projects/`, `runnable-delivery/` and `ui-tour/` are logs and reviews.
- **`examples/`**: `bakery-events.jsonl` (the corpus) and `bakery-stats.json`. `make validate` checks that the statistics still match the corpus.
- **`evidence/chat-images/`**: the negative-test mapping for image attachments.
- **`video/`**:
  - `manim_overview.py`, with narration and timing JSON and the rendered overview MP4s (`make video`, `make video-narrated`);
  - `kerberos/`, the Kerberos explainer (`make kerberos-video`).

## Root documents

| File | Words | What it is | Status |
|---|---|---|---|
| `AGENTS.md` | 486 | Rules for every agent in this repo | current, authoritative |
| `CLAUDE.md` | 133 | Claude Code wrapper around AGENTS.md | current |
| `SKILL.md` | 2168 | The requirements-to-code workflow skill | current |
| `SELF_HOSTING.md` | 400 | Where to start without conversation history | current |
| `SELF_HOSTING_REVIEW.md` | 2209 | Generated by `ReviewSelfHosting.lean`; do not edit | generated |
| `CRITIQUE.md` | 1060 | Open gaps between book and implementation | current |
| `README.md` | 3484 | Overview, commands, PaxosKV walkthrough | current |
| `CURSOR.md` | 266 | Using Cursor as an agent client | current |
| `CODE.md` | 5160 | Code walkthrough of the older core (MDP, Protocol, Render) | dated 2026-10-26; predates `Session/`, `Logic` and `MCP` |
| `BAKERY_SCENARIO.md` | 266 | How the bakery corpus is generated | dated 2026-10-20 |
| `BROWSER_SERVER_OAUTH.md` | 649 | Early sketch of the OAuth actor model | dated 2026-10-20; superseded by the OAuth chapter |
| `MULTIPARTY_GRAMMAR_EXAMPLE.md` | 1569 | Early multiparty grammar example | dated 2026-10-20; superseded by the Grammar chapter |
| `MULTIMODAL_LOGIC.md` | 703 | Knowledge, policy and obligation as modelling techniques | dated 2026-10-20; says knowledge checking is deferred, which is no longer true |
| `LARGE_FILE_POLICY_SERVER.md` | 1912 | Worked example: uploads with JWT and OPA policy | dated 2026-10-20; standalone note |
| `PROJECT_CHAT_EXAMPLE.md` | 895 | Example project-creation conversation | dated 2026-10-20 |

## Agent and CI configuration

- `.mcp.json` (Claude Code), `.codex/config.toml` (Codex) and
  `.cursor/mcp.json` (Cursor) all point at `http://127.0.0.1:8080/mcp`.
- `.github/workflows/lean_action_ci.yml` installs packages and enables user
  namespaces, then runs, in order:
  1. the sandbox check;
  2. `lake build`;
  3. `make go-toolchain`;
  4. `make chatui-check`;
  5. `make validate`;
  6. `make selfhost-check`;
  7. a check that the Needham–Schroeder outputs and the self-hosting review are current.

## Which target runs what

| Target | Runs |
|---|---|
| `make` | `build`, `lean`, `book` |
| `make build` | UI bundle, then `lake build leanfm-server` |
| `make serve` / `make stop` | Start or stop the server on port 8080 |
| `make validate` | The four executables' reports, every core test, `LogicTests`, `MCPTests`, protobuf round trip, bakery statistics |
| `make selfhost-check` | `SelfHostingTests`, `ReviewSelfHosting`, `ReviewResumableWork`, two work-state tests |
| `make chatui-check` | All ChatUI Python tests, the Lean ChatUI tests, the HTTP check, the traceability check |
| `make book` | Ten generators, then `book/Makefile` (both PDFs) |
| `make check` | Sandbox check, `build`, `validate`, `diagrams`, the MDP example, `paxos-check`, `video-check`, `selfhost-check`, `chatui-check` |

## Findings

These are things that look wrong or stale. None of them has been changed.

1. **Three book generators are not run by `make book`.** `SessionExample.lean`,
   `ProbabilityOverlayExample.lean` and `LegalDepositExample.lean` write
   `session-*`, `overlay-*` and `legal-*` into `book/generated/`. A change to
   `LeanFM.Session`, `Overlay` or `Logic` can leave those chapters showing old
   output while the book still builds. Neither `make book` nor CI notices.
2. **`OverlayTests.lean` is run by nothing.**
3. **Five scripts are referenced by nothing**; they are listed above.
4. **`make/leanfm.mk`** is a near-copy of the `Makefile` (it adds a `paxos-run`
   target). Nothing includes it.
5. **Generated book files nothing reads:** `book/generated/cover-preview.png`,
   `night-handoff.md`, `ui-guide-page.png` and `ui-tour-book-build.log`. The
   `*-provenance.txt` files are not read either, but they are meant to be.
6. **`book/main.pdf` is listed in `.gitignore` but tracked.** Git still tracks it
   because it was added before the rule, so the rule only confuses.
7. **Several root documents predate the current design**; see "Root documents".
   `MULTIMODAL_LOGIC.md` now contradicts the code, since knowledge is decided.
8. **The root mixes four kinds of file.** Only the four executable roots must be
   there. A possible layout:

   ```text
   Main.lean Server.lean Diagrams.lean Validate.lean LeanFM.lean   (stay)
   examples/book/   SessionExample, TopologyExample, … NeedhamSchroeder   (13 generators)
   reviews/         ReviewSelfHosting, ReviewResumableWork, ReviewSharedProjects
   notes/           BROWSER_SERVER_OAUTH.md, MULTIPARTY_GRAMMAR_EXAMPLE.md, … (old notes)
   ```

   Moving them touches every `lake env lean --run` line in the `Makefile` and
   CI, the book's mentions of file names, `AGENTS.md`/`SKILL.md` references, and
   the `#guard` paths. `docs/` is git-ignored, so old notes should not go there.
