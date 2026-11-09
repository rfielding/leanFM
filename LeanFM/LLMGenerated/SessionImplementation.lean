import LeanFM.LLMGenerated.SelfHosting
import LeanFM.ChatUI.Implementation

/-! Implementation mapping for the `selfhost.session.*` requirements: the session-type library in
LeanFM/Session/. These clauses were written on 2026-11-07 from the code and tests that already
existed, so the mapping records what the library does rather than a plan. Tests named here are
`#guard`s in modules built with the library (LeanFM.Session imports them), so `lake build` runs
them. -/

namespace LeanFM.LLMGenerated.SessionImplementation
open LeanFM.ChatUI.Implementation
open LeanFM.LLMGenerated.SelfHosting

def decisions : List ImplementationDecision :=
  [ decision "session-syntax"
      ["clause:selfhost.session.syntax"]
      ["LeanFM/Session/Syntax.lean", "LeanFM/Session/Global.lean"]
      "The protocol command is a Lean syntax extension in LeanFM.Session.Syntax. protocol Name (R1, ..., Rn) { statements } defines Name : R → ... → R → Global R. Each statement elaborates to one Global constructor: msg (an Interaction with id, label, src, dst, cause and guard), act, choice, par, join, loop and var (rec and continue; continue ends its branch), sessions, and andThen for include. A label is a type with a TypeName instance, so an unknown label is an elaboration error. cause, route (a string literal) and status (a numeral) fill Interaction.cause, route and status; no rule reads route or status. A where clause becomes a Guard: its source text and a function over an Env of decoded payloads (Dynamic values keyed by message id) returning Option Bool; the identifiers it mentions must be message ids bound earlier or the guarded message itself."
      ["LeanFM/Session/SessionTests.lean: Purchase elaborates with its labels in order; the where clause reads p.amount = q.price and evaluates true for 10/10 and false for 10/12"]
  , decision "session-choice"
      ["clause:selfhost.session.choice"]
      ["LeanFM/Session/Global.lean"]
      "Global.decider takes the first steps of the branches that do something (Global.first): a message's sender or an event's role; empty branches are ignored. One role starting them all is the decider; several roles give 'no single role decides a choice, so it is a race: ' naming who starts what; no branch doing anything is also an error. choiceIssues reports the decider's error, or 'C's choice: two branches start with the same event' when first events repeat, and recurses into branches, par, join, loops and sessions. classicChoiceIssues keeps the classic sender-only rule for comparison."
      ["LeanFM/Session/SessionTests.lean: TransferWithTimer reports the race between Sender's Timeout and Receiver's Ack; Transfer, where the receiver decides, has no issues"]
  , decision "session-causes"
      ["clause:selfhost.session.causes"]
      ["LeanFM/Session/Global.lean"]
      "Global.causeIssues walks every linear run (Global.runs) and reports a message whose cause names a message its sender has neither sent nor received earlier on that run."
      ["LeanFM/Session/SessionTests.lean: a Paid from the bank caused by an Order the bank never saw is reported (Paid: Bank never saw o); Purchase has no cause issues"]
  , decision "session-projection"
      ["clause:selfhost.session.projection"]
      ["LeanFM/Session/Global.lean"]
      "Global.project r runs projectFrom r started: a role not involved in what follows projects to done; a message becomes send or recv or disappears; an event becomes act at its role; a choice the role decides becomes select, and any other becomes mergeBranches. mergeBranches flattens nested offers and accepts, as an offer, branches whose first receivable messages (Local.firstReceives, which looks inside par) are non-empty and pairwise disjoint, provided the role has not started or is present in every branch; a role that has not started may be absent from branches; otherwise branches that begin with the same received label must continue alike. Anything else fails with 'R cannot tell which branch C chose' (with 'after L' when two branches share their first label). sessions projects its body with started false. Global.issues collects choice, cause and projection failures for the listed roles."
      ["LeanFM/Session/SessionTests.lean: Purchase projects for the shop as select and for the bank as an offer with an empty branch; PurchaseWithHold reports that the bank cannot tell which branch the shop chose", "LeanFM/Session/ProjectionTests.lean: a client that has paid tells branches apart when one answers inside a par or after one; a declined branch that tells the client nothing is still rejected"]
  , decision "session-composition"
      ["clause:selfhost.session.composition"]
      ["LeanFM/Session/Global.lean", "LeanFM/Session/Syntax.lean"]
      "include P roles elaborates to Global.andThen (P roles) rest, so the included protocol's done continues with the rest. par branches k and join n branches k carry their continuation k; Global.runs interleaves nothing and lists branches in order for linear checks, while projection keeps par. sessions body k serves copies of body beside k. No construct cancels a branch."
      ["LeanFM/Session/SessionTests.lean: ReplicatedOrder includes a 2-of-3 Replicate join, has no issues, and has 8 labels"]
  , decision "session-http"
      ["clause:selfhost.session.http"]
      ["LeanFM/Session/Http.lean"]
      "Global.httpCutsStreaming g isHttp mayCall streams keeps, along each run, the pending requests (id, caller, callee). A message on an HTTP channel whose cause chain reaches a pending request made by its receiver to its sender is that request's response (the request stays pending when the pair streams); otherwise it is a new request, and is a cut unless mayCall holds. A response that goes to anyone but the caller is reported as 'L answers P, which C sent to S, but goes to D'; an uncallable request as 'L is a request from S to D, which S may not call'. httpCuts is the non-streaming case."
      ["LeanFM/Session/SessionTests.lean: Purchase over HTTP reports Paid going to the shop instead of the client and Shipped as an uncallable request; PurchaseHttp has no cuts"]
  , decision "session-physics"
      ["clause:selfhost.session.physics"]
      ["LeanFM/Session/Physics.lean", "LeanFM/Session/Spec.lean"]
      "Channel has capacity, whenFull, order, sharding, loss, duplication, masked and extra; Channel.conditions derives the surfaced conditions (loss from loss or dropping, reorder from any order, duplicate, per-key order from sharding, reject from rejecting, plus extra) minus masked. Presets: reliable, udp, stream, http, kafka. Physics.channel returns reliable for an undeclared pair; Physics.used lists the channels a protocol uses with their conditions. Spec bundles the protocol, roles, physics, handled conditions per channel, CTL properties over message atoms and assumptions; Spec.issues reports the core rules' issues, unknown atoms, and every surfaced condition of a used channel that its protocol does not handle."
      ["LeanFM/Session/SessionTests.lean: TFTP over UDP reports that the Receiver to Sender channel surfaces reorder, which its protocol does not handle; with no physics declared there is nothing to handle"]
  , decision "session-topology"
      ["clause:selfhost.session.topology"]
      ["LeanFM/Session/Topology.lean"]
      "IfaceKind is a channel plus a lineage; refine adds and removes conditions and extends the lineage. Kinds: call, queue, stream, http, api, ingressHttp, ingressHttps, datagram, topic. Iface has a scope (ingress, peering, internal, local), a name and a kind. The tree's nodes are actors with interfaces and groups placed as outside, island, datacenter, machine, replicated or sharded. Placed.implicitName joins island, actor, scope and interface. Topology.reachable applies the scope rules from the common prefix of the two paths; Topology.channel adds partition across islands, hostile from or to outside, reject into a replicated group and per-key order into a shard."
      ["LeanFM/Session/SessionTests.lean: us.Shop.ingress.https is found; the bank's internal API is unreachable from the outside client and reachable from the shop; that channel surfaces duplicate, reject, close and timeout; a grpc kind refined from http has lineage stream, http"]
  , decision "session-diagram"
      ["clause:selfhost.session.diagram"]
      ["LeanFM/Session/Diagram.lean"]
      "Global.diagram g roles theme title walks g once in a state monad holding the vertical cursor, the SVG elements and the ids of messages drawn so far with their sender, receiver, cause and whether each was a reply. Arrows are emitted only from msg; isReply walks the cause chain (at most 64 links) and a message reaching a drawn non-reply message from its receiver to its sender gets class msg reply and a dashed stroke. The where clause is a separate text of class guard under the arrow. A frame opening directly under another frame's tab starts lower so the tabs do not overlap. The label adds ' · route' and ' · status'. answers returns the request a reply answers; a request with an id opens an activation bar (request id, callee, inset = the callee's bars still open, top, bottom), its first reply closes it, and a reply when that bar is already closed (another branch) adds a bar from branchTop, the y of the last divider. Bars are drawn under the arrows. act emits an action box. choice, par, join, loop, sessions and box each emit a frame (class frame alt, par, join, loop, sessions, ref) with a UML tab (alt, par, loop, ref) and a caption: the decider from Global.decider as 'R selects; others offer', or 'race: no single role selects'; 'any k of n'; the loop name; the included protocol's name. Branches are separated by dashed dividers; nested frames are inset. var emits '↻ continue N'. Every piece of protocol text passes through diagramEscape. Themes: dark (the default, a #111 background) and light."
      ["LeanFM/Session/SessionTests.lean: Purchase draws one arrow per label, two dashed replies (Quote, SoldOut) and one alt frame captioned Shop selects; others offer, with the guard after Pay; ReplicatedOrder draws a ref frame for Replicate around a join frame captioned any 2 of 3; Transfer draws a loop frame with continue Block; TransferWithTimer draws an action box and a race caption; a sessions block draws a sessions frame; PayThenCharge draws Quote, Hold and Receipt as replies and Order, Pay and Verify as calls; a guard with <, && and > is escaped and no raw < from it appears; Checkout shows · POST /orders, · 201 and · 402 in labels and draws six activation bars; a route with <, & and > is escaped"]
  , decision "session-calls"
      ["clause:selfhost.session.calls"]
      ["LeanFM/Session/Calls.lean"]
      "Global.messages lists every message once in written order (a choice copies its continuation into each branch, so a message is kept at its first appearance, keyed by id, label, roles and cause). Global.classify folds over them: a message answers the first request up its cause chain (at most 64 links) whose sender is its receiver and whose receiver is its sender. Calls.inDetail r m walks m's ancestors and is true when it meets r before any of r's responses; Calls.parent m is the nearest ancestor request whose detail holds m; Global.calls builds the tree from requests by parent; callsText prints two lines per call, 'id: Label  Src → Dst  route' then '  returns R1 status | R2 status' (or 'returns no reply'), nested calls indented four spaces. Local.typestate walks the projection in StateM, allocating S0, S1, ... in order and printing methods per state (send as sendLabel(m : Label) : Next, receive as receive() : Label × Next, events as Label() : Next, offer as one receive with alternatives, par as fork, sessions as serve, a branch that does nothing as stop() : End); Typestate.norm turns a par with one live side into that side followed by the continuation. Global.typestates projects each listed role and returns its typestate or the projection error."
      ["LeanFM/Session/SessionTests.lean: Checkout lists two calls with routes and statuses and the bank's charge nested under the payment; Purchase lists Pay and Shipped with no reply and Paid nested under Pay; the client's and the bank's typestates of Checkout and the sender's of Transfer (continue returns to S0) are exact"]
  , decision "session-events"
      ["clause:selfhost.session.events"]
      ["LeanFM/Session/Events.lean"]
      "Global.simulate runs Sim.run in StateM over threads (session, remaining protocol, loop environment, join, start step, loop fuel, last event, events to follow), joins (need, done, fired, continuation, the ends of finished branches) and the events. Sim.rand is a 64-bit linear congruential generator. Each round takes the threads whose start has come (or moves the clock to the earliest start), removes one at random and steps it: choice picks a random branch, box becomes andThen, loop pushes its environment, var unrolls while fuel lasts and otherwise ends, par and join create a join and one thread per branch, sessions creates a join and the requested number of instance threads with random start delays up to spread, msg and act emit one event and requeue the thread. emit computes prior from the last event of each involved role in the session plus the thread's pending join ends, cause from the session's message ids, and answers by walking cause events to the first request from the receiver to the sender. A finished thread passes its last event to its join, which starts its continuation once need branches have finished. Sessions are renumbered by first event. eventsJson writes one JSON object per event; jsonString escapes quotes, backslashes, newlines and control characters."
      ["LeanFM/Session/SessionTests.lean: five Serve sessions give ten events, each session Get then Page, Page answering Get; for twenty seeds Checkout's stream links only backwards and holds exactly one run's messages; the same seed gives the same JSON; Fan's par branches on different actors are not linked through prior and Done follows both; Transfer with fuel 2 sends at most three Data; jsonString escapes a quote, a backslash and a newline"]
  ]

def clauseRefs : List String := clauses.map (fun c => "clause:" ++ c.id)

def errors : List String :=
  let unknown := decisions.flatMap fun d =>
    d.requirementRefs.filterMap fun r => if clauseRefs.contains r then none else some ("unknown reference: " ++ r)
  let sessionClauses := (clauses.filter (fun c => c.id.startsWith "selfhost.session.")).map (fun c => "clause:" ++ c.id)
  let uncovered := sessionClauses.filterMap fun c =>
    if decisions.any (fun d => d.requirementRefs.contains c && !d.conformanceTests.isEmpty) then none
    else some ("session clause without decision and test: " ++ c)
  unknown ++ uncovered

end LeanFM.LLMGenerated.SessionImplementation
