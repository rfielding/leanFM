import LeanFM.Session.Actors

/-!
# Spans, timelines and critical paths (clauses selfhost.session.timelines, selfhost.session.critical-path)

Every duration is a difference between two readings of one clock, so clock skew between machines
cannot affect it. A call is a request and the reply that names it as its cause. It has two views:

* the caller's: from sending the request to receiving the reply, both on the caller's clock;
* the callee's own: from receiving the request to sending the reply, both on the callee's clock.

The caller's view is at least the callee's; the difference is the network and queueing time of
both directions together, which no log can split without synchronized clocks, so it is not split.

The calls a callee makes while handling a call are its sub-calls: sent by the callee after it
received the request, before it replied, and after the request in happens-before. Sub-calls whose
intervals overlap on the callee's clock ran concurrently. A span is at least its critical path:
along a chain of sub-calls one after another the durations add, across concurrent ones the longest
counts. Measured with each sub-call's own durations (each on its own clock), that bound must not
exceed the span; the chain that sets the span, by the callee's own waits, is its critical path.

A call tree is laid on its root caller's timeline: the callee's events are anchored at the moment
the request was sent and laid out by the callee's own durations, recursively, comparing no two
clocks. Negative requirements: a callee whose own duration exceeds its caller's wait, and sub-calls
whose own durations along a chain exceed the span that contains them, are reported with both
numbers; a sub-call reply that arrives after its parent replied is listed as not awaited.
-/

namespace LeanFM.Session
namespace Spans
open Actors

/-- A call: a request, its reply, and what the clocks say about it. -/
structure Span where
  request : LogEvent
  reply : LogEvent
  /-- reply received minus request sent, on the caller's clock -/
  callerView : Option Nat
  /-- reply sent minus request received, on the callee's clock -/
  calleeView : Option Nat
  deriving Inhabited

def caller (s : Span) : String := src s.request
def callee (s : Span) : String := dst s.request

def diff (a b : Option Nat) : Option Nat :=
  match a, b with
  | some x, some y => if x ≥ y then some (x - y) else none
  | _, _ => none

/-- Every call in the log: each request with the first reply that names it as cause. -/
def spans (evs : List LogEvent) : List Span :=
  evs.filterMap fun r =>
    if r.isAct then none else
    match evs.find? (fun p => !p.isAct && p.cause == some r.id && src p == dst r && dst p == src r) with
    | none => none
    | some p =>
      let callerView := diff p.receivedAt r.sentAt
      let calleeView := diff p.sentAt r.receivedAt
      some ({ request := r, reply := p, callerView, calleeView } : Span)

/-- Whether `a` happens before `b`: a chain of prev and cause links leads from b back to a. -/
partial def before (byId : List (String × LogEvent)) (a b : String) (fuel : Nat := 4096) : Bool :=
  go [b] [] fuel
where
  go (todo seen : List String) : Nat → Bool
    | 0 => false
    | f + 1 => match todo with
      | [] => false
      | x :: rest =>
        if seen.contains x then go rest seen f else
        match byId.lookup x with
        | none => go rest (x :: seen) f
        | some e =>
          let ls := [e.prev, e.cause].filterMap id
          if ls.contains a then true else go (ls ++ rest) (x :: seen) f

/-- The sub-calls of a span: calls its callee made after receiving the request and before replying,
in happens-before after the request. -/
def subcalls (byId : List (String × LogEvent)) (all : List Span) (s : Span) : List Span :=
  match s.request.receivedAt, s.reply.sentAt with
  | some t0, some t1 =>
    all.filter fun c => caller c == callee s && c.request.id != s.request.id &&
      (c.request.sentAt.map fun t => t0 ≤ t && t ≤ t1).getD false &&
      before byId s.request.id c.request.id
  | _, _ => []

/-- Whether a sub-call's reply came back before the parent replied (on the callee's clock). -/
def awaited (s c : Span) : Bool :=
  match c.reply.receivedAt, s.reply.sentAt with
  | some a, some b => a ≤ b
  | _, _ => false

/-- The heaviest chain of sub-calls one after another (each sent after the previous reply came
back, on the caller's clock), by `weight`: its total and the chain. -/
def heaviestChain (cs : List Span) (weight : Span → Nat) : Nat × List Span := Id.run do
  let sorted := cs.toArray.qsort (fun a b => (a.reply.receivedAt.getD 0) < (b.reply.receivedAt.getD 0)) |>.toList
  -- best i: the heaviest chain ending with sorted[i]
  let mut best : Array (Nat × List Span) := #[]
  for c in sorted do
    let start := c.request.sentAt.getD 0
    let mut top : Nat × List Span := (0, [])
    for i in [0:best.size] do
      let prev := sorted[i]!
      if (prev.reply.receivedAt.getD 0) ≤ start && best[i]!.1 > top.1 then top := best[i]!
    best := best.push (top.1 + weight c, top.2 ++ [c])
  return best.foldl (fun acc b => if b.1 > acc.1 then b else acc) (0, [])

/-- One span's report. -/
structure Report where
  span : Span
  network : Option Nat
  subs : List Span
  notAwaited : List Span
  critical : List Span
  criticalNs : Nat
  /-- the sub-calls' own durations along the heaviest chain: a lower bound on the span -/
  boundNs : Nat
  issues : List String

def label (s : Span) : String := s!"{s.request.label} {s.request.id} from {caller s} to {callee s}"

def report (byId : List (String × LogEvent)) (all : List Span) (s : Span) : Report := Id.run do
  let subs := subcalls byId all s
  let waited := subs.filter (awaited s)
  let lateOnes := subs.filter (!awaited s ·)
  let (criticalNs, critical) := heaviestChain waited (fun c => c.callerView.getD 0)
  let (boundNs, boundChain) := heaviestChain waited (fun c => c.calleeView.getD 0)
  let mut issues : List String := []
  if let (some cv, some own) := (s.callerView, s.calleeView) then
    if own > cv then
      issues := issues ++ [s!"{label s}: {callee s} took {own} ns by its own clock, longer than {caller s} waited for it ({cv} ns by its clock); an event is attributed to the wrong call, a cause is missing, or a clock jumped"]
  if let some own := s.calleeView then
    if boundNs > own then
      issues := issues ++ [s!"{label s}: its sub-calls {", ".intercalate (boundChain.map (·.request.id))}, one after another, took at least {boundNs} ns by their own clocks, but {callee s} answered in {own} ns by its clock"]
  return { span := s, network := diff s.callerView s.calleeView, subs, notAwaited := lateOnes, critical, criticalNs,
           boundNs, issues }

/-- Positions on the root caller's timeline: each call tree is laid out from its root, a callee's
clock offset so that it received the request at the moment the request was sent. -/
partial def place (byId : List (String × LogEvent)) (all : List Span) (s : Span) (offset : Int) :
    List (String × String × Int) :=
  -- offset maps the caller's clock onto the root timeline
  match s.request.sentAt, s.request.receivedAt with
  | some sent, some recv =>
    let calleeOffset : Int := offset + sent - recv
    let mine : List (String × String × Int) :=
      [(s.request.id, caller s, offset + sent)] ++
      (s.reply.sentAt.map fun t => [(s.reply.id, callee s, calleeOffset + t)]).getD [] ++
      (s.reply.receivedAt.map fun t => [(s.reply.id ++ " received", caller s, offset + t)]).getD []
    mine ++ (subcalls byId all s).flatMap fun c => place byId all c calleeOffset
  | _, _ => []

/-- The roots: calls that are no other call's sub-call. -/
def roots (byId : List (String × LogEvent)) (all : List Span) : List Span :=
  all.filter fun s => !all.any fun t => (subcalls byId all t).any (·.request.id == s.request.id)

end Spans
end LeanFM.Session
