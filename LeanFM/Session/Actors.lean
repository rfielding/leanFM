import LeanFM.Session.Conform

/-!
# Actors and happens-before (clause selfhost.session.actor-conformance)

A log of many instances interleaves, and the interleaving carries no information: what matters is
the order in which each actor processed its messages. An actor is named `Role/instance` in an
event's `from` and `to`; an event that names only the role is that role's actor in its session.

Three things order a log: `prev`, the previous event the same actor sent; `cause`, the event a
message answers; and each actor's own clock, whose readings (when it sent, when it received) order
that actor's events, compared only with each other. Together they are the happens-before order. Conformance replays each
session in an order consistent with happens-before (ties keep the log's order), so the verdict is
the same for every interleaving of the actors' streams: a log listing a reply before its request is
read in the order the links give.

Negative requirements: a `prev` or `cause` that names no event of the log, a `prev` that is not an
earlier send of the same actor, an actor whose own order forks (two events after one), a cause its
sender never sent or received, and links that form a cycle are problems, not guesses.
-/

namespace LeanFM.Session
namespace Actors

/-- The actor that sent an event. -/
def src (e : LogEvent) : String := if e.srcActor.isEmpty then s!"{e.src}@{e.session}" else e.srcActor

/-- The actor that received it (an event at one role is its own receiver). -/
def dst (e : LogEvent) : String :=
  if e.isAct then src e else if e.dstActor.isEmpty then s!"{e.dst}@{e.session}" else e.dstActor

def involves (e : LogEvent) (a : String) : Bool := src e == a || dst e == a

/-- A logged participant: `Role` or `Role/instance`, as its role and the actor name to keep. -/
def parse (s : String) : Except String (String × String) :=
  match s.splitOn "/" with
  | [r] => pure (r, "")
  | [r, i] => if r.isEmpty || i.isEmpty then throw s!"{s}: an actor is Role/instance, both non-empty" else pure (r, s)
  | _ => throw s!"{s}: an actor is Role/instance, with one /"

/-- An actor's reading of its own clock at an event: when it sent it, or when it received it. -/
def reading (a : String) (e : LogEvent) : Option Nat :=
  if src e == a then e.sentAt else if dst e == a then e.receivedAt else none

/-- The event each event follows in an actor's own order, from that actor's clock: for every actor,
its events sorted by its own readings, each after the last one with a smaller reading. Readings are
compared only with readings of the same clock. -/
def clockOrder (evs : List LogEvent) : List (String × String) := Id.run do
  let actors := (evs.flatMap fun e => [src e, dst e]).eraseDups
  let mut out : List (String × String) := []
  for a in actors do
    let mine := evs.filterMap fun e => (reading a e).map fun t => (t, e.id)
    for (t, id) in mine do
      -- the latest earlier reading of this clock
      let earlier := mine.filter (·.1 < t)
      if let some (_, p) := earlier.foldl (fun acc x => match acc with
          | some y => if x.1 > y.1 then some x else acc
          | none => some x) none then
        out := out ++ [(id, p)]
  return out

/-- The links of an event: its prev, its cause, and the events before it on its actors' clocks,
where they name events of the list. -/
def links (byId : List (String × LogEvent)) (clock : List (String × String)) (e : LogEvent) : List LogEvent :=
  ([e.prev, e.cause].filterMap id ++ (clock.filter (·.1 == e.id)).map (·.2)).filterMap (byId.lookup ·)

/-- Problems with the links of a log, each with the event it is about. -/
def check (evs : List LogEvent) : List (String × String) := Id.run do
  let byId := evs.map fun e => (e.id, e)
  let clock := clockOrder evs
  let mut out : List (String × String) := []
  let mut seen : List String := []
  for e in evs do
    if seen.contains e.id then out := out ++ [(e.id, s!"event id {e.id} appears twice")]
    seen := e.id :: seen
    if let some p := e.prev then
      match byId.lookup p with
      | none => out := out ++ [(e.id, s!"prev {p} is not an event of the log")]
      | some q =>
        if p == e.id then out := out ++ [(e.id, "an event cannot be its own prev")]
        else if src q != src e then
          out := out ++ [(e.id, s!"prev {p} was sent by {src q}, not by {src e}; prev names the previous event its sender sent")]
    if let some c := e.cause then
      if let some q := byId.lookup c then
        if !involves q (src e) then
          out := out ++ [(e.id, s!"{e.label}'s cause {c} ({q.label} from {src q} to {dst q}) is an event its sender {src e} never sent or received")]
  -- each actor's own order is one chain: no event is the prev of two events of its actor
  for e in evs do
    if let some p := e.prev then
      let after := evs.filter fun x => x.prev == some p && src x == src e
      if after.length > 1 && after.head?.map (·.id) == some e.id then
        out := out ++ [(e.id, s!"{src e}'s own order forks: {", ".intercalate (after.map (·.id))} all name {p} as prev")]
  -- happens-before has no cycle: every event is placed after its links
  let mut placed : List String := []
  let mut left := evs.filter fun e => (links byId clock e).all fun q => q.id != e.id
  let mut progress := true
  while progress && !left.isEmpty do
    progress := false
    let ready := left.filter fun e => (links byId clock e).all fun q => placed.contains q.id
    if !ready.isEmpty then
      progress := true
      placed := placed ++ ready.map (·.id)
      left := left.filter fun e => !ready.any (·.id == e.id)
  if !left.isEmpty then
    out := out ++ [((left.head?.map (·.id)).getD "", s!"the links and the actors' own clocks form a cycle through {", ".intercalate ((left.take 6).map (·.id))}: an event cannot follow itself")]
  return out

/-- The events in an order consistent with happens-before within them, keeping the log's order
where the links leave it open (links to events outside the list are ignored). -/
def linearize (evs : List LogEvent) : List LogEvent := Id.run do
  let ids := evs.map (·.id)
  let byId := evs.map fun e => (e.id, e)
  let clock := clockOrder evs
  let mut out : List LogEvent := []
  let mut left := evs
  while !left.isEmpty do
    let placed := out.map (·.id)
    match left.find? (fun e => (links byId clock e).all fun q => !ids.contains q.id || q.id == e.id || placed.contains q.id) with
    | some e =>
      out := out ++ [e]
      left := left.filter (·.id != e.id)
    | none =>
      -- a cycle (reported by check): keep the log's order for the rest
      out := out ++ left
      left := []
  return out

/-- Whether the log uses links that order it: any prev, or any cause. -/
def linked (evs : List LogEvent) : Bool := evs.any fun e => e.prev.isSome || e.cause.isSome

end Actors
end LeanFM.Session
