# Sorting LeanFM's own requirement clauses

Source: `LeanFM/LLMGenerated/SelfHosting.lean` (131 clauses). Formulas over LeanFMMcp were checked with `session_ctl` on `LeanFM/LLMGenerated/LeanFM.leanfm` (101 reachable states); draft models with `check_ctl`, over the running server at 127.0.0.1:8080.

## Summary

| Pile | Count |
|---|---|
| A1. CTL over LeanFMMcp | 6 |
| A2. CTL over another model | 16 |
| B. Tests only (no temporal content) | 98 |
| C. Obsolete, superseded or duplicate | 11 |
| Total | 131 |

Five A entries to add first:

1. **A file the project does not list is never read** (selfhost.mcp.session.project-files): `(always (implies (on FileText) (allNext (on Checked))))`. **Disproved**, and the clause is right: LeanFMMcp reads the file before refusing it. Fix the protocol (refuse before ReadFile), then add the entry.
2. **The view has one call in flight at a time** (selfhost.mcp.session.view): the Page/Load `allUntil` pair below. Proved.
3. **Every request to the server is answered** (selfhost.mcp.transport): the conjunction below. Proved.
4. **An answer over its bound is refused, never shown** (selfhost.mcp.limits): `(and (always (implies (on OverBound) (allNext (on Refused)))) (always (implies (on TooLarge) (allNext (on Failed)))))`. Proved.
5. **Every open returns to the agent before the conversation can stop** (selfhost.mcp.session.view): `(always (implies (on Open) (allUnless (not stop) (or (on Done) (on Failed)))))`. **Proved.** Nothing runs forever: actors run until shutdown, so the requirement uses the weak form (`allUnless`), which asks nothing of a run that never ends. The strong form with `inevitably` is disproved only by paging forever, which is not a real run.

A2 drafts were written by hand from each clause's text. A proof there only shows the draft has the property, not that the code does. Each draft is a model the code would have to conform to (through `session_conform` or a test).

`after` and `terminal` are not used anywhere. `(never (on Write))` is rejected because LeanFMMcp has no such message.

## All clauses, by clause id

Pile B holds what a tool returns, a file or text format, a value, or a checker feature over *user* protocols: nothing about LeanFM's own message order. Its tests come from the decisions in SessionImplementation.lean, McpLogicImplementation.lean and Implementation.lean that list the clause. In A cells, each line is: entry sentence: `formula`, then the verdict.

| clause id | pile | status | plain reading | formula and verdict | model to write | tests that hold it | covered by / reason |
|---|---|---|---|---|---|---|---|
| selfhost.book.listings | B | implemented | Every input listing in the book passes the checker. |  |  | `BookListingsCheck.lean` |  |
| selfhost.bounds | C | proposed | Exploration bounds are declared; running out is never "proved". |  |  |  | covered by selfhost.mcp.logic.safety and selfhost.mcp.limits |
| selfhost.checker | C | proposed | Check answers use five verdicts and carry their evidence. |  |  |  | covered by selfhost.mcp.logic.reference (five verdicts, witness conventions) and selfhost.mcp.logic.ctl |
| selfhost.coverage | B | proposed | Every book claim links to a requirement or is marked pending. |  |  | none found |  |
| selfhost.env.chatui | A2 | proposed | Chat service env vars checked at startup too. | Nothing is served before the environment is checked: `(precedes (on EnvOk) (or (on Listen) (on Serve)))`, model not written (reuse `envstartup`; would prove the same, but the code does not do it yet) | Same model as env.startup, for the chat service's variables. |  |  |
| selfhost.env.startup | A2 | implemented | Env vars checked once at startup. | Nothing is served before the environment is checked: `(precedes (on EnvOk) (or (on Listen) (on Serve)))`, proved<br>A bad environment never serves: `(always (implies (on EnvBad) (never (on Serve))))`, proved | Draft `envstartup`: boot -EnvOk-> checked -Listen-> serving -Serve-> serving; boot -EnvBad-> exited. |  |  |
| selfhost.formulas | C | proposed | Requirements use nested CTL with typed path conditions. |  |  |  | covered by selfhost.mcp.logic.ctl, selfhost.mcp.logic.words and selfhost.mcp.logic.reference |
| selfhost.gates | A2 | implemented | Acceptance is a git commit; code generation waits for passing checks. | Code is generated only after the checks pass: `(always (implies (on Check) (allUnless (not (on Generate)) (on Pass))))`, proved<br>No generation before a pass: `(precedes (on Pass) (on Generate))`, proved | Draft `gates` (workflow): editing -Check-> checking -Pass-> passed / -Fail-> editing; passed -Generate/Edit-> editing. |  |  |
| selfhost.handoff | C | proposed | A fresh session starts from the book and specs, not chat history. |  |  |  | covered by selfhost.mcp.context and AGENTS.md/CLAUDE.md; ProjectMemory.md and runtime.json are not used elsewhere |
| selfhost.history | C | proposed | Events link to predecessors; past monitors say which order they use. |  |  |  | covered by selfhost.session.execution (causal DAG) and selfhost.mcp.logic.trace |
| selfhost.implementations.map | B | implemented | Implementation maps against requirements. |  |  | `LeanFM/Session/TypesTests.lean` |  |
| selfhost.lazy | B | proposed | Per-modality indexes kept only while formulas need them. |  |  | none found |  |
| selfhost.logic.overlay | B | implemented | Probability and delay overlays beside the task. |  |  | none found |  |
| selfhost.mcp.context | B | implemented | Fixed resources expose book and specs. |  |  | none found |  |
| selfhost.mcp.forward | A2 | implemented | stdio relay to the running HTTP server. | A posted line is answered, acknowledged, or gets an error (never dropped): `(always (implies (on Line) (allNext (or (on Answer200) (or (on Ack202) (on ErrorReply))))))`, proved<br>The relay keeps running after an error: `(always (implies (on ErrorReply) (possibly (on Line))))`, proved | Draft `forward`: idle -Line-> posted; posted -Answer200/Ack202/ErrorReply-> idle; idle -Eof-> end. |  |  |
| selfhost.mcp.hosting | A2 | implemented | leanfm-mcp: MCP-only host with CORS, auth, limits. | A rejected request is never dispatched: `(always (implies (on Reject) (allUnless (not (on Dispatch)) (on Request))))`, proved<br>Every request is rejected or dispatched: `(always (implies (on Request) (inevitably (or (on Reject) (on Dispatch)))))`, proved | Draft `hosting` (one request): idle -Request-> got; got -Reject-> idle (any of 403/415/406/400/413/401/429/503); got -Admit-> ok -Dispatch-> idle. |  |  |
| selfhost.mcp.keepalive | A2 | implemented | HTTP keep-alive connection lifecycle. | No keep-alive answer after the connection was told it closes: `(always (implies (on RespondClose) (never (on RespondKeep))))`, proved<br>Every request is answered: `(always (implies (on Request) (allNext (or (on RespondKeep) (or (on RespondClose) (on Malformed400))))))`, proved<br>A connection over the cap gets 503 and nothing more: `(always (implies (on Busy503) (always stop)))`, proved | Draft `keepalive`: listen -Accept-> idle, listen -Busy503-> closed; idle -Request-> reading -RespondKeep-> idle; reading -RespondClose/Malformed400-> closing -Closed-> closed; idle -IdleTimeout-> closed. |  |  |
| selfhost.mcp.limits | A1 | implemented | Named, per-call overridable limits. | An answer over its bound is refused, never shown: `(and (always (implies (on OverBound) (allNext (on Refused)))) (always (implies (on TooLarge) (allNext (on Failed)))))`, proved |  |  |  |
| selfhost.mcp.limits.everywhere | B | proposed | Remaining bounds become named limits. |  |  | none found |  |
| selfhost.mcp.logic.ctl | B | implemented | check_ctl over tasks and drafts. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.logic.explain | B | implemented | explain_formula readings and duals. |  |  | `LeanFM/LogicTests.lean` |  |
| selfhost.mcp.logic.functions | B | implemented | Pattern functions (outcomes, follows...) in every form. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.mcp.logic.knows | B | implemented | knows derives terms from the causal past. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.logic.observability | B | implemented | classify_requirement sorts atoms. |  |  | `LeanFM/LogicTests.lean` |  |
| selfhost.mcp.logic.on | B | implemented | Meaning of the on and stop atoms. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.mcp.logic.protocol | B | implemented | check_protocol for security protocols. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/MCPTests.lean`, `LeanFM/SecretsTests.lean` |  |
| selfhost.mcp.logic.reassembly | B | implemented | check_reassembly for stream evasion. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.logic.reference | B | implemented | The logic reference resource. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.logic.safety | A2 | implemented | Logic input is data, bounded; limits never prove. | A run that hit a bound never answers proved: `(always (implies (on Exhausted) (never (on Proved))))`, proved | Draft `checker` (one check): exploring -Step-> exploring; -Exhausted-> exhausted -ResourceLimit-> done; -Complete-> complete -Proved/Disproved-> done. |  |  |
| selfhost.mcp.logic.secrets | B | implemented | Secrets marked by name and asked about. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/SecretsTests.lean` |  |
| selfhost.mcp.logic.state | B | implemented | state terms name conversation states. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.mcp.logic.trace | B | implemented | check_trace over event envelopes. |  |  | `LeanFM/LogicTests.lean` |  |
| selfhost.mcp.logic.view | B | implemented | The logic tools' MCP Apps view. |  |  | `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.logic.words | B | implemented | English words for CTL operators. |  |  | `LeanFM/LogicTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.mcp.metrics | B | implemented | /metrics reports per-tool cost. |  |  | `LeanFM/CheckMetricsTests.lean`, `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.model-token | A2 | implemented | session_ctl model token and cache. | No hit before the entry was built by a miss: `(precedes (on Miss) (on Hit))`, proved | Draft `modeltoken`: empty -Miss-> held; held -Hit/Miss-> held; held -Evict-> empty. |  |  |
| selfhost.mcp.proxy | A2 | implemented | Go reverse proxy in front of leanfm-mcp. | A body over the cap never reaches the upstream: `(always (implies (on TooBig) (allUnless (not (on Upstream)) (on Request))))`, model not written | Same shape as `hosting`: Request, then TooBig413 / Busy503 / NotFound404, or Upstream then Answer. |  |  |
| selfhost.mcp.readonly | A1 | implemented | The MCP endpoint never writes or reads arbitrary paths. | A (needs protocol change): the server never writes to Disk: `(never (on Write))`, rejected: LeanFMMcp declares no Write message, so the forbidden step cannot be named. Today only the protocol entry itself says Disk receives only ReadRoot/ReadPage/ReadFile. Add a Write (or Mutate) message in a branch the server must never take, or accept the faithful entry as the evidence.<br>Every disk read is answered with its text: `(always (implies (on ReadFile) (allNext (on FileText))))`, proved |  |  |  |
| selfhost.mcp.server-info | B | implemented | server_info names the running build. |  |  | `LeanFM/MCPTests.lean` |  |
| selfhost.mcp.session.navigator | A1 | implemented | The navigator bar: stages, pages, bounds. | A page request goes straight to project_view: `(always (implies (on Page) (allNext (on ProjectView))))`, proved<br>The view asks for pages or files only after it is rendered: `(precedes (on Render) (or (on Page) (on Load)))`, proved<br>Closing the view returns control to the agent: `(always (implies (on Close) (allNext (on Done))))`, proved |  |  |  |
| selfhost.mcp.session.project-files | A1 | implemented | Tools load project protocols by project and file. | A protocol file is read only for a session tool call: `(always (implies (on SessionTool) (allNext (on ReadFile))))`, proved<br>A file the project does not list is never read: `(always (implies (on FileText) (allNext (on Checked))))`, **disproved**: Initialize, Initialized, ListTools, Tools, Open, ProjectView, ReadRoot, Listing, Shown, Render, Load, SessionTool, ReadFile, FileText, NotListed. REAL GAP: the protocol reads the file from Disk before refusing it; the clause says an unlisted file is never read. The NotListed branch should come before ReadFile (check against Listing first). |  |  |  |
| selfhost.mcp.session.standalone | A2 | implemented | The view in a full browser window. | project_view is delivered only after the view is initialized: `(precedes (on UiInitialized) (on ProjectViewResult))`, proved<br>project_view is the first tool result: `(precedes (on ProjectViewResult) (on ToolsCall))`, proved<br>Each forwarded call is answered or refused: `(always (implies (on ToolsCall) (allNext (or (on ForwardedAnswer) (on RefusedTool)))))`, proved | Draft `standalone` (host page and frame): start -UiInitialize-> init -UiInitialized-> ready -ProjectViewResult-> shown; shown -ToolsCall-> fwd -ForwardedAnswer/RefusedTool-> shown. |  |  |
| selfhost.mcp.session.tools | B | implemented | The nineteen session tools and their inputs. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/SessionToolsTests.lean`, `projects/GoServer/source/cmd/demo/main_test.go` |  |
| selfhost.mcp.session.view | A1 | implemented | The MCP Apps session view and its behaviour. | The view has one call in flight at a time: `(and (always (implies (on Page) (allNext (allUntil (not (or (on Page) (on Load))) (or (on Paged) (on Refused)))))) (always (implies (on Load) (allNext (allUntil (not (or (on Page) (on Load))) (or (on Drawn) (on Refused)))))))`, proved<br>Every open returns to the agent before the conversation can stop: `(always (implies (on Open) (allUnless (not stop) (or (on Done) (on Failed)))))`, **proved** (nothing runs forever; actors run until shutdown, so the weak form is the requirement). |  |  |  |
| selfhost.mcp.stdio | A2 | implemented | Same MCP surface over stdin/stdout. | A request gets exactly one reply: `(always (implies (on Request) (allNext (on Reply))))`, proved<br>A notification or blank line gets nothing: `(always (implies (or (on Notification) (on Blank)) (not (someNext (or (on Reply) (on ErrorReply))))))`, proved<br>Input end ends the process: `(always (implies (on Eof) (always stop)))`, proved | Draft `stdio`: idle -Request-> busy -Reply-> idle; idle -Notification/Blank-> idle; idle -BadLine-> err -ErrorReply-> idle; idle -Eof-> end (terminal). |  |  |
| selfhost.mcp.transport | A1 | implemented | POST /mcp speaks MCP 2025-06-18. | Nothing (tool list, open, quit) before initialization: `(precedes (on Initialized) (or (on ListTools) (or (on Open) (on Quit))))`, proved<br>Every request to the server is answered: `(and (always (implies (on Initialize) (inevitably (on Initialized)))) (and (always (implies (on ListTools) (inevitably (on Tools)))) (and (always (implies (on ProjectView) (inevitably (or (or (on Shown) (on TooLarge)) (or (on PageShown) (on OverBound)))))) (and (always (implies (on SessionTool) (inevitably (or (on Checked) (on NotListed))))) (always (implies (on Bye) (inevitably (on ByeDone))))))))`, proved |  |  |  |
| selfhost.modal | B | proposed | Knowledge, obligation and permission quantify over the right futures. |  |  | none found |  |
| selfhost.pr | C | proposed | A PR needs a patch, mappings and check results. |  |  |  | contradicts selfhost.gates and AGENTS.md (the agent never commits or pushes; the user reviews diffs in git) |
| selfhost.probability | C | proposed | Probabilities are optional and say where they came from. |  |  |  | covered by selfhost.logic.overlay (declared vs measured, named) and selfhost.session.sla (assumptions vs requirements) |
| selfhost.project.implementations | B | implemented | A project may have several implementations, listed in its manifest. |  |  | none found (decision lists only proof names) |  |
| selfhost.requirements.list | B | implemented | Requirement lists are things that convert to CTL. |  |  | `LeanFM/Session/TypesTests.lean` |  |
| selfhost.requirements.map | B | implemented | Requirements block syntax and its checking. |  |  | `LeanFM/Session/TypesTests.lean` |  |
| selfhost.revision | C | proposed | Checks are tied to exact revisions; stale requests fail. |  |  |  | superseded by selfhost.gates (git holds revisions) and selfhost.mcp.server-info (build identity); the MCP side is stateless, so no stale writes exist |
| selfhost.session.actor | B | implemented | One role's view with its interface files. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/ExploreTests.lean` |  |
| selfhost.session.actor-conformance | B | implemented | Per-actor processing order, not log interleaving. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/ActorTests.lean` |  |
| selfhost.session.amounts | B | implemented | Messages can move amounts; obligations can carry penalties. |  |  | `LeanFM/Session/DecisionTests.lean` |  |
| selfhost.session.bits | B | implemented | Hidden state measured in bits per message. |  |  | `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.buffers | B | implemented | Inbox sizes and what a deployment can enforce. |  |  | `LeanFM/Session/RealizableTests.lean` |  |
| selfhost.session.calls | B | implemented | Calls and typestate APIs derived from causes. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.causes | B | implemented | A cause must be something its sender has seen. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.choice | B | implemented | Each choice has exactly one deciding role. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.composition | B | implemented | include, parallel and join compose protocols. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.conform | B | implemented | Logs checked against the protocol. |  |  | `LeanFM/Session/EnvelopeTests.lean`, `LeanFM/Session/SessionTests.lean`, `LeanFM/Session/SlaTests.lean`, `LeanFM/Session/TypesTests.lean`, `LeanFM/Session/WhereTests.lean`, `examples/vibecode/lending/test_lending.py` |  |
| selfhost.session.correlation | C | proposed | Messages carry typestate via prev/cause or wire fields. |  |  |  | covered by selfhost.session.log-sessions, selfhost.session.identity.marks and selfhost.session.where |
| selfhost.session.critical-path | B | implemented | A call lasts at least its critical path. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/ActorTests.lean` |  |
| selfhost.session.ctl-scale | B | implemented | CTL checked in linear time with bounded memory. |  |  | `LeanFM/Session/CtlScaleTests.lean` |  |
| selfhost.session.ctl-sexpr | B | implemented | Formulas as s-expressions with shared subformulas. |  |  | `LeanFM/Session/CtlScaleTests.lean` |  |
| selfhost.session.ctl-store | B | proposed | Content-addressed store of formulas and truth sets. |  |  | none found |  |
| selfhost.session.ctl-translation | C | proposed | A diagram as a set of CTL formulas with past operators. |  |  |  | covered by selfhost.session.faithful; also contradicts selfhost.mcp.logic.on (uses arrive/send atoms and past operators LeanFM does not have) |
| selfhost.session.dataset | B | implemented | Large generated datasets summarised. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/ExploreTests.lean` |  |
| selfhost.session.deployment | B | implemented | The deployment tree written as text and checked. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/DeploymentTests.lean`, `LeanFM/Session/LeanSyntaxTests.lean` |  |
| selfhost.session.derived-sessions | B | implemented | Sessions in a stream come from the protocol, not the events. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/DerivedTests.lean` |  |
| selfhost.session.diagram | B | implemented | Sequence diagrams are generated, never hand-drawn. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.diagram.annotations | B | implemented | Diagrams show probabilities, amounts and delays. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.diagram.folds | B | implemented | Request/response pairs fold in every diagram. |  |  | `LeanFM/Session/SessionTests.lean`, `scripts/session_view_smoke.js` |  |
| selfhost.session.envelope | B | implemented | Every crossing event has a declared protobuf shape. |  |  | `LeanFM/Session/EnvelopeTests.lean`, `LeanFM/Session/SlaTests.lean`, `LeanFM/Session/TypesTests.lean`, `examples/vibecode/lending/test_lending.py` |  |
| selfhost.session.events | B | implemented | Event streams generated from a global type. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.evolution | B | implemented | Which roles can upgrade on their own schedule. |  |  | `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.execution | B | implemented | An execution is its causal event stream. |  |  | `LeanFM/Session/EnvelopeTests.lean`, `LeanFM/Session/SlaTests.lean`, `LeanFM/Session/TypesTests.lean`, `examples/vibecode/lending/test_lending.py` |  |
| selfhost.session.explorer | B | implemented | Browse a specification as a folded tree. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/ExploreTests.lean`, `scripts/session_view_smoke.js` |  |
| selfhost.session.faithful | B | implemented | Faithful CTL decided as one bisimulation check. |  |  | `LeanFM/Session/FaithfulTests.lean` |  |
| selfhost.session.files | B | implemented | One directory per session type with generated files. |  |  | `LeanFM/Session/OAuthTests.lean`, `LeanFM/Session/ProtoTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.generate.chain | B | implemented | Event streams generated from the chain. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.generative | B | implemented | Clocks, obligations and probabilities as annotations. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/GenerativeTests.lean` |  |
| selfhost.session.generative.execution | B | implemented | Seeded timed simulation with deadline reports. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/GenerativeTests.lean` |  |
| selfhost.session.generative.monitor | A2 | implemented | Conformance reports obligations fulfilled, pending or violated. | A triggered obligation ends fulfilled or violated: `(always (implies (on Trigger) (inevitably (or (on Fulfil) (on Breach)))))`, model not written | One obligation's lifecycle: Trigger -> pending; Fulfil -> fulfilled; Deadline -> violated. |  |  |
| selfhost.session.group | B | implemented | Uncaused message runs bracketed as groups. |  |  | `LeanFM/Session/GroupTests.lean` |  |
| selfhost.session.http | B | implemented | Optional HTTP call discipline on declared channels. |  |  | `LeanFM/Session/SessionTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.identity.calls | B | proposed | Independent calls linked only by copied ids. |  |  | none found |  |
| selfhost.session.identity.checks | A2 | implemented | A session id is unique while open and freed at the end. | An id is not minted again while its session is open: `(always (implies (on Mint) (allNext (allUnless (not (on Mint)) (on End)))))`, proved<br>An open session can always be freed: `(always (implies (on Mint) (possibly (on End))))`, proved | Draft `identity` (one id value): free -Mint-> live -Use-> live -End-> free. |  |  |
| selfhost.session.identity.children | B | implemented | Child sessions come from the text binding an id. |  |  | `LeanFM/Session/IdentityTests.lean` |  |
| selfhost.session.identity.graph | B | proposed | Sessions form a graph; per-session residual states. |  |  | none found |  |
| selfhost.session.identity.joins | B | implemented | A task may belong to two sessions at once. |  |  | `LeanFM/Session/IdentityTests.lean` |  |
| selfhost.session.identity.marks | B | implemented | Fresh and Link field marks start or continue sessions. |  |  | `LeanFM/Session/IdentityTests.lean` |  |
| selfhost.session.identity.quantified | B | proposed | One formula quantified over every value of a marked field. |  |  | none found |  |
| selfhost.session.identity.recursion | A2 | proposed | Ids scoped to their minting block; recursive includes. | An id is freed before the next iteration mints it: `(always (implies (on Mint) (allNext (allUnless (not (on Mint)) (on Free)))))`, model not written | Like `identity`, with a loop body that mints and frees per iteration and a recursive child. |  |  |
| selfhost.session.identity.scopes | B | implemented | Each composition operator has one identity rule. |  |  | `LeanFM/Session/IdentityTests.lean` |  |
| selfhost.session.instance-data | B | proposed | Instances own data; races on it are found. |  |  | none found |  |
| selfhost.session.instance-deadlines | C | proposed | Deadlines judged on the caller's clock only. |  |  |  | covered by selfhost.session.timelines (durations from one clock only) |
| selfhost.session.instances | B | implemented | Instances declared in a system block. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/InstanceTests.lean` |  |
| selfhost.session.interruptible | A2 | proposed | Interrupt blocks with crossing messages handled. | No role is stuck after an interrupt crosses a message: `(always (possibly stop))`, model not written | A Buyer/Seller protocol with an interruptible block and asynchronous channels (needs the interruptible language feature first). |  |  |
| selfhost.session.keywords | B | implemented | Keywords are the words the book uses. |  |  | `LeanFM/Session/LeanSyntaxTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.layout | B | implemented | State machines drawn like the book's typestates. |  |  | `LeanFM/Session/LayoutTests.lean`, `scripts/session_view_smoke.js` |  |
| selfhost.session.lean | B | implemented | session_types writes one Lean module. |  |  | `LeanFM/Generated/PlaceOrder.lean`, `LeanFM/Session/OAuthTests.lean`, `LeanFM/Session/ProtoTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.lean-syntax | B | implemented | Session files are Lean files. |  |  | `LeanFM/Session/LeanSyntaxTests.lean`, `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.local-instances | B | proposed | Named local protocols as per-thread instances. |  |  | none found |  |
| selfhost.session.log-sessions | B | implemented | Interleaved logs split into sessions by declared identity. |  |  | `LeanFM/Session/IdentityTests.lean`, `LeanFM/Session/LogSessionsTests.lean` |  |
| selfhost.session.mdp | B | implemented | session_mdp draws a decision tree with policy weights. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/DecisionTests.lean` |  |
| selfhost.session.mdp.distribution | B | implemented | Full balance distributions, not just means. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.mdp.horizon | B | implemented | Periodic gates analysed over a horizon. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.mdp.loops | B | implemented | Looping sessions analysed as absorbing Markov chains. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.mdp.optimize | B | implemented | Optimal stationary policy for open choices. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.mdp.rewards | B | implemented | Chain view carries amounts, time and rates as rewards. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.mdp.walk | B | implemented | Rewards of one specific walk. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.openapi | B | implemented | OpenAPI generated per role. |  |  | `LeanFM/Generated/PlaceOrder.lean`, `LeanFM/Session/OAuthTests.lean`, `LeanFM/Session/ProtoTests.lean`, `LeanFM/Session/TypesTests.lean`, `LeanFM/Session/WhereTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.physics | B | implemented | Channels declare capacity, loss, ordering and presets. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.projection | B | implemented | Projection gives each role its local type. |  |  | `LeanFM/Session/ProjectionTests.lean`, `LeanFM/Session/SessionTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.properties | B | implemented | Temporal properties of a protocol, via MCP or Lean. |  |  | `LeanFM/Session/SpecCheckTests.lean`, `LeanFM/SessionToolsTests.lean`, `SessionExample.lean` |  |
| selfhost.session.proto | B | implemented | .proto, Lean module and OpenAPI generated from the type. |  |  | `LeanFM/Generated/PlaceOrder.lean`, `LeanFM/Session/ProtoTests.lean` |  |
| selfhost.session.rec.bounded | B | implemented | Bounded loops with an otherwise block. |  |  | `LeanFM/Session/ChainTests.lean` |  |
| selfhost.session.review | B | implemented | One-answer design review with fixes. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.skeleton | B | implemented | Typed skeletons in Python, TypeScript, Go. |  |  | `LeanFM/Session/EnvelopeTests.lean`, `LeanFM/Session/SlaTests.lean`, `LeanFM/Session/TypesTests.lean`, `LeanFM/Session/WhereTests.lean`, `LeanFM/SessionToolsTests.lean`, `examples/vibecode/lending/test_lending.py` |  |
| selfhost.session.skeleton-versions | A2 | proposed | Skeletons tag events with version and refuse others. | A wrong-version event is refused at once: `(always (implies (on VersionBad) (allNext (on Refuse))))`, model not written | Skeleton receive loop: Receive, then VersionOk -> Apply or VersionBad -> Refuse. |  |  |
| selfhost.session.sla | B | implemented | Assumed probabilities vs required SLAs. |  |  | `LeanFM/Session/SlaTests.lean` |  |
| selfhost.session.syntax | B | implemented | Protocols are written in Lean notation and elaborate to a global type. |  |  | `LeanFM/Session/LeanSyntaxTests.lean`, `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.timelines | B | implemented | Durations from one clock only. |  |  | `LeanFM/MCPTests.lean`, `LeanFM/Session/ActorTests.lean` |  |
| selfhost.session.topology | B | implemented | A deployment tree places actors and their interfaces. |  |  | `LeanFM/Session/SessionTests.lean` |  |
| selfhost.session.types | B | implemented | Every message has a type; media types carry bytes. |  |  | `LeanFM/Session/LeanSyntaxTests.lean`, `LeanFM/Session/SessionTests.lean`, `LeanFM/Session/TypesTests.lean`, `LeanFM/Session/WhereTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.versions | B | implemented | Protocol versions; no clean upgrade is a compile error. |  |  | `LeanFM/Session/EnvelopeTests.lean`, `LeanFM/Session/VersionTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.where | B | implemented | where conditions evaluated over payloads. |  |  | `LeanFM/Session/TypesTests.lean`, `LeanFM/Session/WhereTests.lean`, `LeanFM/SessionToolsTests.lean` |  |
| selfhost.session.wire-constraints | B | implemented | Headers and constraints reach generated interfaces. |  |  | `LeanFM/SessionToolsTests.lean` |  |
