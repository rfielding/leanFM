# Faithful CTL from LeanFM protocol definitions

Can a protocol definition be turned into CTL that says *exactly* what the protocol allows, nothing
more and nothing less? This experiment does it for every protocol LeanFM carries and checks the result
with LeanFM's own checker.

## The translation

`Global.stateGraph` gives one session of a protocol as a state graph; the checker's model refines it
into nodes (state, last message) with the atoms `after(L)` and `end`, and a session that has ended
stutters. `faithful.py` minimises that model by bisimulation (partition refinement over
the label and the set of successor blocks). Each block is a *typestate*. It then writes one rule per
typestate: in this typestate, each of these next typestates is possible, and nothing else is.

```
start   ¬(Ping ∨ Pong ∨ SlowPong) ∧ ¬end
block1  AG (Ping ∧ ¬end) → ( EX (Pong ∧ end) ∧ EX (SlowPong ∧ end)
                             ∧ AX ((Pong ∧ end) ∨ (SlowPong ∧ end)) )
```

`block1` is the `GET /images` rule: after the request, a 200 can come, a 404 can come, and the next
step is one of them and nothing else. The answer is certain to come because `AX` leaves no other step.
A typestate is named by a formula: the last message when that is enough, or the last message
together with what can follow, `k` steps deep, when it is not. The depth `k` is the *lookahead* in the
table below. Nested this way, the formulas of two different typestates exclude each other in every
model. So a model satisfies all the rules exactly when it is bisimilar to the protocol. That is as
faithful as any CTL can be, because CTL cannot tell two bisimilar models apart.

## Results

| protocol | checker nodes | typestates | lookahead | rules | LeanFM checker |
|---|---:|---:|---:|---:|---|
| LeanFM (its own MCP protocol) | 101 | 33 | 1 | 34 | 34 proved, 126 ms |
| Ping, Rental, Loan, WeeklyRent | 3–5 | 3–5 | 0 | 4–6 | all proved, ≤3 ms |
| PlaceOrder, OAuth, Ride, UserLookup, RentWithRepairs, LimitOrder, (Priced)DepositSettlement | 6–32 | 5–21 | 0 | 6–22 | all proved, ≤33 ms |
| Dispatch | 40 | 18 | 1 | 19 | 19 proved, 30 ms |
| BoundedRide | 45 | 23 | **6** | 24 | 24 proved, 2.3 s (139,583 formula nodes) |
| Maqam | 1,849 | 45 | 0 | 46 | 46 proved, 2.7 s |
| GoServer, one session per protocol (GameP, Challenge, ListGamesP, …) | 4–318 | 4–20 | 0 | 5–21 | all proved |
| GoServer SeatP (`par` of four `sessions`) | 941 | 412 | 1 | 413 | proved (shared-subformula check, 0.12 s) |
| GoServer, whole | 39,497 | 1,604 | 2 | 1,605 | all proved by the shared-subformula check (36 s); the 11 rules under 256 nodes proved by `session_ctl` (about 1.1 s each, compiled) |

Times are from `lean --run`, which interprets the code, except where marked. `results.json` has every row.
LeanFM's checker, interpreted, did not finish a sample of 10 GoServer rules (median 3,000 nodes as trees)
in 10 minutes.

**Mutation.** For the 15 small protocols, `mutate.py` made 1,821 broken copies of their graphs in all: a step
dropped (the 404 branch removed), a step added where the protocol has none, a step sent to the wrong
next state, or a step relabelled. LeanFM's checker found a failing rule in **all 1,523 copies that
change the behaviour**. It flagged **none of the 298 copies that are bisimilar** to the original, which
no CTL formula can distinguish. The shared-subformula evaluator `dagcheck.py` agrees with LeanFM's
checker on all 1,821.

## What this says

- **A single thread is realistic, and cheap.** For 15 of 17 protocols the last message identifies the
  typestate (lookahead 0), so every rule is the request → exactly-these-answers shape, a few dozen
  nodes. They check in milliseconds.
- **Lookahead comes from state the label does not show.** BoundedRide counts its retries, so six
  states all end in the same message and differ only in how many tries are left. The rule must look
  six steps ahead to tell them apart. Dispatch and LeanFM need one step. On the wire, the message's
  `prev` and `cause` pointers and its `where` fields carry that state. An atom that could see them
  would bring the lookahead back to 0.
- **`par` is what makes it big.** GoServer's 1,604 typestates and depth 2 come from interleaving
  independent sessions: list polling beside the lobby, and SeatP's four child sessions. In the
  product, the last message says nothing about the other branches. Checked one session at a time,
  which is how the log splitter already reads a log, every GoServer protocol is lookahead 0 except
  SeatP, the one with the `par`. With session-indexed atoms (a message's session identity, the `s0`
  of `ts=s0`), the faithful CTL of a `par` is the conjunction of each session's own rules.
- **Size is a checker matter.** As trees, the GoServer rules total 8.8 million formula nodes; as a
  DAG, 41,382 distinct subformulas. LeanFM's `Model.sat` evaluates the tree and caps a formula at 256
  nodes. Even with raised bounds, `parseBounded` checks size against the global default rather than
  the bounds it is given. Evaluating each distinct subformula once, which `dagcheck.py` does with
  numpy, checks all of GoServer in 36 s. Nearly all of that is one `AG` fixpoint per rule; over a fully
  reachable model, `AG ψ` at the start is just "ψ at every node".

## IslandUploads

IslandUploads stores and serves uploads on islands that keep accepting writes while partitioned
from each other, and replicates between them once healed. It has two kinds of model, and they come
out very differently.

**Its ten protocols**, taken from `spec/Session.lean` into `islanduploads.leanfm`, are all
request/response sessions: Upload, Update, Feed, Download, Replicate, PullPage, ImportRange, Derive,
Forward and Socket. Nine of them have lookahead 0, with 3–9 typestates each. Socket has 38 typestates
and lookahead 1, purely from its `par`: frames up and frames down are independent. Atoms naming the
sender and receiver as well as the label (`send(A,B,L)`) change nothing. Every rule is proved by
LeanFM's checker (≤99 ms per protocol). Its broken copies: **all 792 that change behaviour caught,
none of the 400 equivalent ones flagged**.

**Its fourteen architecture models** (`reports/mcp/*.task.json`, written by `spec/Islands.lean`)
are the whole system: two islands, partition and heal, feed order, import lanes, conflict policy,
retry and scheduling.

| model | checker nodes | typestates | lookahead | formula tree | distinct subformulas |
|---|---:|---:|---:|---:|---:|
| retry-hold / retry-yield | 20 / 41 | 16 / 41 | 1 / 2 | 2.4k / 21k | 218 / 686 |
| sched-reserved / sched-shared | 66 / 105 | 66 / 105 | 2 | 18k / 40k | 887 / 1,484 |
| lanes-contiguous / lanes-max | 59 / 57 | 59 / 55 | 2 / 3 | 38k / 129k | 1,018 / 1,202 |
| feed-byDt / visibleAtCommit / visibleAtBegin | 286 / 76 / 286 | 86 / 54 / 122 | 2 / 2 / 4 | 46k / 24k / 561k | 1,472 / 891 / 3,001 |
| policy-allHeads / latestWins | 137 | 111 / 129 | 3 | 10 M / 11 M | 3,834 / 4,418 |
| repl-ordered / repl-unordered / repl-cursor | 291 / 380 / 1,108 | 237 / 316 / 276 | 5 / 6 / 5 | 575 M / **6.0 G** / 705 M | 9,877 / 14,757 / 11,610 |

- **Proved:** all 1,687 rules of the 14 models, each model in at most 0.2 s, with `dagcheck.py`
  (shared subformulas). LeanFM's checker proves every rule of the seven smallest (retry, sched,
  lanes-contiguous, feed-visibleAtCommit, feed-byDt) in 23 ms to 3.8 s each. The replication rules,
  billions of nodes as trees, are beyond it.
- **Mutation:** all 4,330 broken copies that change behaviour are caught; none of the 90 equivalent
  ones is flagged.

Replication needs lookahead 5–6 because its messages (`PullAtoB`, `CommitA1`, `Synced`, …) do not
say what they carry. After `PullAtoB`, which records B now holds depends on everything before, so
the rule has to read it off what can still happen. That is the architecture's real state: which
writes each island has, and how far each cursor has reached. On the wire, the pull carries its
cursor and the records their `dt`. With atoms over those fields (the `where` values, and the
`prev`/`cause` pointers), the typestate would be visible in the message again.

Found on the way: the protocol text reader refuses `Update` (`r.prevDts = u.prevDts`, a list
compared in a `where` clause; "a condition or log reads single values"), while the Lean form of the
same protocol passes its `#guard issues == []`. So the MCP tools cannot read IslandUploads' protocols
as written. `islanduploads.leanfm` types `prevDts` as a String to get past this.

## Making it feasible: messages that carry their place

Each change below was measured with the same construction (`repl.py` ports `Islands.lean`'s
replication model exactly: 104 states, 316 typestates).

| change | repl-cursor lookahead | formula tree |
|---|---:|---:|
| as written | 5 | 705 M |
| the timeout says which direction | 5 | 1.35 G |
| the pull names the records it delivered | 2 | 1.7 M |
| … and the cursor after it | 2 | 1.7 M |
| per-actor atoms ("last message at shard a / at b / on the network", `peractor.py`) | 2–7 | larger |
| **each message carries `prev`, so its typestate is known by walking the chain** | **0** | 59,502 (linear) |

Payload fields shorten the lookahead but cannot remove it: one message on a shared timeline cannot
say what the other island has done. Per-actor atoms make it worse, because they split the state further.
`prev` removes the lookahead entirely. An event's typestate is its predecessor's typestate after one
step, so it is found by walking the chain forward once, not inferred from what can happen next. With
it, every protocol here has lookahead 0, and the total rule size is linear in the graph's edges
(GoServer: 39,498 rules).

Then the check is a walk too (`walk.py`). A lookahead-0 rule ("at typestate b, the next typestates
are exactly C") speaks only about the nodes at b and their out-edges. So all the rules together are
one pass over the edges:

| check of GoServer's faithful rules | time | peak memory |
|---|---:|---:|
| without `prev`, one truth array per subformula, never freed (`dagcheck.py`) | 36 s | several GB once `prev` labels multiply the subformulas (the run that ran out of memory) |
| with `prev`, hash-consed subformulas freed per rule (`hashcheck.py`, 3 GB cap) | 243 s | 232 MB |
| with `prev`, the forward walk (`walk.py`) | **17 ms** | 79 MB |

The walk caught 40 of 40 broken GoServer copies: a branch removed, a step allowed where it is not,
a step to the wrong next state, a wrong message. The checker evaluates truth sets over every node, so
as a formula the walk would cost O(rules × nodes). Seen as rules indexed by the typestate they speak
about, it costs O(edges). That is what replaying a log against the protocol already does.

Also observed: the checker's model drops the outgoing steps of a terminal state, keeping only the
stutter. No protocol here has a terminal state with next steps, so nothing is affected today. But a
session that "may end or carry on" would be checked as if it ended.

## Running it

With the LeanFM build done (`lake build`):

```sh
lake env lean --run reports/ctl-translation/faithful/Faithful.lean dump P.leanfm g-P.json
python3 -I reports/ctl-translation/faithful/faithful.py g-P.json          # sizes
python3 -I -c 'import sys; sys.path.insert(0,"reports/ctl-translation/faithful"); import faithful; faithful.emit("g-P.json","f-P.json")'
lake env lean --run reports/ctl-translation/faithful/Faithful.lean checkdraft g-P.json f-P.json r-P.json
python3 -I reports/ctl-translation/faithful/mutate.py g-P.json m-P.json k-P.json
lake env lean --run reports/ctl-translation/faithful/Faithful.lean mutants m-P.json f-P.json mr-P.json
python3 -I reports/ctl-translation/faithful/dagcheck.py g-P.json
```

## Implemented in LeanFM

The findings above are now LeanFM requirements (`selfhost.session.faithful`, `.ctl-scale`, `.ctl-sexpr`
in `SelfHosting.lean`), mapped in `SessionImplementation.lean` and implemented:

- **One evaluator for all CTL** (`Logic.Model.satE`): the formula is hash-consed into a DAG, then
  evaluated once with packed bitsets. `EX` and `AX` are one pass over the steps; `EU`, `AU` and `EG` are
  one backward worklist pass each, where the old fixpoints could take n passes. Each truth set is freed
  when its readers are done, under a byte bound. It gives the old evaluation's answer on every operator
  (tested), and `check_ctl`, `session_ctl`, `Spec.check`, systems and evidence paths all use it.
- **S-expression formulas** everywhere a formula is read, such as `(and #1=(EF (on a)) (AG #1#))`,
  with labels for shared parts and no read-time evaluation.
- **`session_ctl` with `faithful`**: `"rules"` gives the typestates, the lookahead and the rules;
  `{task}` or `{lean}` decides faithfulness by the walk (O(m)) when the typestates are deterministic
  and by refinement otherwise, with the shortest path to where the two differ. Refinement is signature
  refinement, at most n rounds; Paige–Tarjan is not used.

Measured through the MCP service on GoServer (39,497 checker nodes):

| request | time |
|---|---:|
| `faithful: "rules"` (1,604 typestates, lookahead 2, 1,605 rules) | 0.73 s |
| `faithful: {lean}`, the protocol against itself (refinement) | 1.42 s |
| the same against a copy whose refused sign-in ends: unfaithful, "after IssueSession -> SignInRefused, the protocol allows IssueSession and the candidate EnterRoom" | 1.42 s |
| one faithful rule (38–178 distinct subformulas) as an s-expression through `session_ctl` | 0.84 s each, all proved |
