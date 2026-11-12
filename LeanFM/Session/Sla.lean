import LeanFM.Session.Chain
import Std.Data.HashMap

/-! Requirements selfhost.session.sla and selfhost.session.execution.

A protocol states assumptions (the probabilities on choices: peers' hidden internal choices as seen
from outside) and requirements (`require per q { ... }`: what each entry q must reach, by when, and
how often). `design` checks every requirement against the assumptions on the chain view, with exact
rationals; `observe` checks it on an event stream, where all state is the stream itself: events keyed
by unique timestamp, linked by prev and cause, with rewards as a sparse map from timestamp to vector.
No user code, IO or markup evaluation. -/
namespace LeanFM.Session.Sla
open Lean LeanFM.Overlay Generative LeanFM.Session.Chain

/-! ## Design time: requirements against the assumptions -/

def maxExpansions : Nat := 20000

/-- One entry's outcome: exact masses of hitting a target, missing it, and not yet resolved, with the
most probable path that misses (or, for at most, hits). -/
structure EntryOutcome where
  edge : Nat
  hits : Rat
  misses : Rat
  unresolved : Rat
  missPath : List String
  missMass : Rat
  hitPath : List String
  hitMass : Rat
  deriving Inhabited

structure DesignVerdict where
  req : Requirement
  /-- met, violated or undecided -/
  verdict : String
  /-- the worst entry's interval for the probability of reaching a target -/
  lo : Rat
  hi : Rat
  entries : List EntryOutcome
  /-- the path behind the verdict: a miss for every and at least, a hit for at most -/
  path : List String
  /-- the stated choices (assumptions) the path passes through -/
  assumptions : List String
  /-- entries a window must hold to decide the bound at its confidence, when statistical -/
  need : Option Nat
  /-- whether the declared window will hold them: some true or false, none when unknown -/
  windowOk : Option Bool
  note : String
  deriving Inhabited

/-- The first message or event of the branch a policy edge selects: what the other roles see first,
so how they tell the branches apart. Follows single non-choice edges (at most 24); none when the
branch starts with another choice. -/
def branchFirst (c : Chain) (s : Nat) : Option String := Id.run do
  let mut cur := s
  for _ in [0:24] do
    let outs := c.edges.filter (·.src == cur)
    match outs.toList with
    | [e] =>
      if e.kind == "message" || e.kind == "event" then return some e.step
      else if e.kind == "policy" then return none
      else cur := e.dst
    | _ => return none
  return none

/-- A path step: a message or event by its label; a stated choice as [name → first message of the
branch taken: probability], so the assumption names the outcome as well as the question. -/
def stepName (c : Chain) (e : Edge) : String :=
  if e.kind == "message" || e.kind == "event" then e.step
  else if e.kind == "policy" then
    let name := (c.states[e.src]?.map (·.detail)).getD "choice"
    match branchFirst c e.dst with
    | some first => s!"[{name} -> {first}: {e.prob.text}]"
    | none => s!"[{name}: {e.prob.text}]"
  else e.label

/-- Milliseconds as written in requirements: whole seconds as seconds, otherwise ms. -/
def durationText (ms : Nat) : String :=
  if ms ≥ 1000 && ms % 1000 == 0 then
    let s := ms / 1000
    s!"{s} second{if s == 1 then "" else "s"}"
  else s!"{ms} ms"

/-- From each entry edge, the exact probability of reaching a target before the deadline, before the
next entry and before the session ends. Continuations are enumerated breadth first over (state,
elapsed ms) with masses merged, each edge's delay outcomes branching. -/
def entryOutcome (c : Chain) (r : Requirement) (entryLabel : String) (ei : Nat) : EntryOutcome := Id.run do
  let isEntry (e : Edge) := e.kind == "message" && e.step == entryLabel
  let isTarget (e : Edge) := (e.kind == "message" || e.kind == "event") && r.targets.contains e.step
  let out := c.edges.toList.zipIdx.foldl (fun acc (e, i) => (acc.modify e.src (·.push i))) (Array.replicate c.states.size (#[] : Array Nat))
  let e0 := c.edges[ei]!
  -- frontier: (state, elapsed) ↦ (mass, path)
  let mut frontier : Std.HashMap (Nat × Nat) (Rat × List String) := ({} : Std.HashMap (Nat × Nat) (Rat × List String)).insert (e0.dst, 0) (1, [e0.step])
  let mut hits : Rat := 0
  let mut misses : Rat := 0
  let mut missPath : List String := []
  let mut missMass : Rat := 0
  let mut hitPath : List String := []
  let mut hitMass : Rat := 0
  let mut steps := 0
  while !frontier.isEmpty && steps < maxExpansions do
    let mut next : Std.HashMap (Nat × Nat) (Rat × List String) := {}
    for ((s, t), (m, path)) in frontier.toList do
      steps := steps + 1
      if c.ends.contains s then
        misses := misses + m
        if m > missMass then missMass := m; missPath := path ++ ["(the session ends)"]
        continue
      for i in out[s]! do
        let e := c.edges[i]!
        let p := qRat e.prob
        if p == 0 then continue
        let delays := if e.delays.isEmpty then [(0, Q.one)] else e.delays
        for (d, q) in delays do
          let m' := m * p * qRat q
          let t' := t + d
          let path' := if path.length < 60 then path ++ [stepName c e] else path
          let late := match r.withinMs with | some w => t' > w | none => false
          if isTarget e && !late then
            hits := hits + m'
            if m' > hitMass then hitMass := m'; hitPath := path'
          else if late || isEntry e then
            misses := misses + m'
            let why := if late then s!"(at {durationText t'}, past the {durationText (r.withinMs.getD 0)} deadline)" else "(the next entry comes first)"
            if m' > missMass then missMass := m'; missPath := path' ++ [why]
          else
            let (old, op) := (next.get? (e.dst, t')).getD (0, path')
            next := next.insert (e.dst, t') (old + m', if old == 0 then path' else op)
    frontier := next
  let unresolved := frontier.toList.foldl (fun acc (_, (m, _)) => acc + m) 0
  return { edge := ei, hits, misses, unresolved, missPath, missMass, hitPath, hitMass }

/-- Entries a window must hold to decide a probability bound at confidence c with no counter-examples:
ln(1/(1-c)) / margin, the rule of three at 95/100 (margin 1 - p for at least, p for at most). -/
def windowNeed (r : Requirement) : Option Nat :=
  let c := (r.confidence.num.toFloat) / (r.confidence.den.toFloat)
  let margin : Option Float := match r.bound with
    | .every => none
    | .atLeast p => some (1 - p.num.toFloat / p.den.toFloat)
    | .atMost p => some (p.num.toFloat / p.den.toFloat)
  margin.bind fun m => if m <= 0 then none else some (Float.ceil (Float.log (1 / (1 - c)) / m)).toUInt64.toNat

partial def entryLabelOf (body : List Text.Stmt) (id : String) : Option String :=
  let rec go : List Text.Stmt → Option String
    | [] => none
    | s :: rest => (match s with
      | .msg (some x) label .. => if x == id then some label else none
      | .timed _ m | .valued _ m => go [m]
      | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.findSome? go
      | .loop _ b | .sessions b => go b
      | .bounded _ _ b o => go b <|> go o
      | _ => none) <|> go rest
  go body

def design (c : Chain) (body : List Text.Stmt) (r : Requirement) : Except String DesignVerdict := do
  if c.edges.any (·.gate.isSome) then
    throw "requirements cannot be analysed with a periodic gate (at next d): its waits depend on absolute time"
  let some label := entryLabelOf body r.entry | throw s!"{r.entry} is not a message id"
  let entries := c.edges.toList.zipIdx.filter (fun (e, _) => e.kind == "message" && e.step == label) |>.map (·.2)
  if entries.isEmpty then throw s!"{r.entry} ({label}) never happens in the chain view"
  let outs := entries.map (entryOutcome c r label)
  -- the worst entry decides: lowest chance for every and at least, highest for at most
  let worst : EntryOutcome := match r.bound with
    | .atMost _ => outs.foldl (fun (b o : EntryOutcome) => if o.hits + o.unresolved > b.hits + b.unresolved then o else b) outs.head!
    | _ => outs.foldl (fun (b o : EntryOutcome) => if o.hits < b.hits then o else b) outs.head!
  let lo := worst.hits
  let hi := worst.hits + worst.unresolved
  let verdict := match r.bound with
    | .every => if worst.misses > 0 then "violated" else if worst.unresolved > 0 then "undecided" else "met"
    | .atLeast p => if lo >= qRat p then "met" else if hi < qRat p then "violated" else "undecided"
    | .atMost p => if hi <= qRat p then "met" else if lo > qRat p then "violated" else "undecided"
  let path := match r.bound with
    | .atMost _ => worst.hitPath
    | _ => worst.missPath
  let assumptions := (path.filter (·.startsWith "[")).eraseDups
  let need := windowNeed r
  let windowOk : Option Bool := match need, r.window with
    | some n, some (.entries k) => some (k ≥ n)
    | some n, some (.time w) => r.rate.map fun (k, per) => k * w ≥ n * per
    | _, _ => none
  let note := match r.bound, verdict with
    | .every, "violated" => "an entry can miss: add a branch that answers in time (a timeout), or make it a probability bound"
    | .atLeast _, "violated" | .atMost _, "violated" =>
      "the assumptions cannot meet this bound: change the protocol (a retry, a fallback) or the stated probabilities on the path shown"
    | _, "undecided" => s!"the enumeration stopped after {maxExpansions} continuations; the interval does not decide the bound"
    | _, _ => ""
  return { req := r, verdict, lo, hi, entries := outs, path, assumptions, need, windowOk, note }

/-! ## Run time: the execution is the event stream -/

/-- One observed event. Its timestamp is its identity. -/
structure Ev where
  ts : Nat
  label : String
  src : String := ""
  dst : String := ""
  prev : Option Nat := none
  cause : Option Nat := none
  deriving Inhabited

/-- The state of a protocol execution: events keyed by unique timestamp, their causal links, and a
sparse reward map from timestamp to the whole reward vector (role, unit, amount), written only at
the events where the vector changes. Actors hold no state; their view is a query. -/
structure Execution where
  events : Std.HashMap Nat Ev
  order : Array Nat
  children : Std.HashMap Nat (Array Nat)
  reward : Std.HashMap Nat (List (String × String × Rat))
  deriving Inhabited

def maxEvents : Nat := 20000

/-- The reward vector at an event: walk the prev links backwards from it to the first event that
has a reward vector, and take that vector; none on the way back means the zero vector. -/
partial def Execution.rewardAt (x : Execution) (ts : Nat) : List (String × String × Rat) :=
  match x.reward.get? ts with
  | some v => v
  | none => match x.events.get? ts with
    | some e => match e.prev with
      | some p => x.rewardAt p
      | none => []
    | none => []

/-- Two reward vectors are the same when every role and unit has the same amount (missing = 0). -/
def sameVector (a b : List (String × String × Rat)) : Bool :=
  let amt (v : List (String × String × Rat)) (r u : String) : Rat :=
    v.foldl (fun acc (r', u', x) => if r' == r && u' == u then acc + x else acc) 0
  (a ++ b).all fun (r, u, _) => amt a r u == amt b r u

def Execution.make (evs : List Ev) (rewards : List (Nat × List (String × String × Rat))) : Except String Execution := do
  if evs.length > maxEvents then throw s!"at most {maxEvents} events"
  let mut events : Std.HashMap Nat Ev := {}
  for e in evs do
    if events.contains e.ts then throw s!"two events have timestamp {e.ts}: timestamps are event identities and must be unique"
    events := events.insert e.ts e
  let mut children : Std.HashMap Nat (Array Nat) := {}
  for e in evs do
    for (what, l) in [("prev", e.prev), ("cause", e.cause)] do
      if let some p := l then
        if !events.contains p then throw s!"event {e.ts} names {what} {p}, which is not an event of the stream"
        if p >= e.ts then throw s!"event {e.ts} names {what} {p}, which is not earlier"
        children := children.insert p (((children.get? p).getD #[]).push e.ts)
  let mut reward : Std.HashMap Nat (List (String × String × Rat)) := {}
  for (ts, rs) in rewards do
    if !events.contains ts then throw s!"a reward names timestamp {ts}, which is not an event"
    if reward.contains ts then throw s!"two reward vectors for timestamp {ts}"
    reward := reward.insert ts rs
  let order := (evs.map (·.ts)).toArray.qsort (· < ·)
  let x : Execution := { events, order, children, reward }
  -- a new reward vector is written only where it changes
  for (ts, rs) in rewards do
    let inherited := match (events.get! ts).prev with
      | some p => x.rewardAt p
      | none => []
    if sameVector inherited rs then
      throw s!"the reward vector at {ts} equals the one it inherits through prev: a new reward vector is recorded only when it changes"
  return x

/-- Everything an event happened after: itself and, through prev and cause, its causal past. -/
partial def Execution.causalPast (x : Execution) (ts : Nat) : List Nat := Id.run do
  let mut seen : Std.HashMap Nat Unit := {}
  let mut stack := [ts]
  while !stack.isEmpty do
    let t := stack.head!
    stack := stack.tail!
    if seen.contains t then continue
    seen := seen.insert t ()
    if let some e := x.events.get? t then
      for l in [e.prev, e.cause] do
        if let some p := l then stack := p :: stack
  return (seen.toList.map (·.1)).toArray.qsort (· < ·) |>.toList

/-- An actor's state is only this: the events it took part in, with their causal past. -/
def Execution.view (x : Execution) (role : String) : List Nat := Id.run do
  let mut seen : Std.HashMap Nat Unit := {}
  for t in x.order do
    let e := x.events.get! t
    if e.src == role || e.dst == role then
      for p in x.causalPast t do seen := seen.insert p ()
  return (seen.toList.map (·.1)).toArray.qsort (· < ·) |>.toList



/-- The events in an event's causal future (those that name it, directly or not), up to a timestamp. -/
partial def Execution.future (x : Execution) (ts : Nat) (upTo : Nat) : List Nat := Id.run do
  let mut seen : Std.HashMap Nat Unit := {}
  let mut stack := ((x.children.get? ts).getD #[]).toList
  while !stack.isEmpty do
    let t := stack.head!
    stack := stack.tail!
    if seen.contains t || t > upTo then continue
    seen := seen.insert t ()
    stack := ((x.children.get? t).getD #[]).toList ++ stack
  return (seen.toList.map (·.1)).toArray.qsort (· < ·) |>.toList

/-- hit, miss or pending (the deadline has not passed by the end of the stream). -/
structure Trial where
  entry : Nat
  outcome : String
  /-- the target event, when hit -/
  target : Option Nat := none
  deriving Inhabited

def trials (x : Execution) (r : Requirement) (label : String) : List Trial := Id.run do
  let last := x.order.back?.getD 0
  let mut out := #[]
  for t in x.order do
    let e := x.events.get! t
    if e.label != label then continue
    let upTo := match r.withinMs with | some w => t + w | none => last
    let hit := (x.future t upTo).find? fun u => r.targets.contains (x.events.get! u).label
    match hit with
    | some u => out := out.push { entry := t, outcome := "hit", target := some u }
    | none =>
      let decided : Bool := match r.withinMs with | some w => decide (t + w < last) | none => false
      out := out.push { entry := t, outcome := if decided then "miss" else "pending" }
  return out.toList

/-- log of n choose k, for the binomial tails. -/
def logChoose (n k : Nat) : Float := Id.run do
  let mut s : Float := 0
  for i in [0:k] do s := s + Float.log ((n - i).toFloat) - Float.log ((i + 1).toFloat)
  return s

/-- P(X ≥ k) and P(X ≤ k) for X ~ Binomial(n, p), summed in log space. -/
def binomialTails (n k : Nat) (p : Float) : Float × Float := Id.run do
  if p <= 0 then return (if k == 0 then 1 else 0, 1)
  if p >= 1 then return (1, if k == n then 1 else 0)
  let lp := Float.log p
  let lq := Float.log (1 - p)
  let mut ge : Float := 0
  let mut le : Float := 0
  let mut lc : Float := 0
  for i in [0:n+1] do
    if i > 0 then lc := lc + Float.log ((n - i + 1).toFloat) - Float.log i.toFloat
    let term := Float.exp (lc + i.toFloat * lp + (n - i).toFloat * lq)
    if i >= k then ge := ge + term
    if i <= k then le := le + term
  return (min 1 ge, min 1 le)

structure WindowVerdict where
  start : Nat
  entries : Nat
  hits : Nat
  /-- whether the observation period is over: only a closed window gets met, violated or undecided -/
  closed : Bool
  /-- open (the period is still running), met, violated or undecided -/
  verdict : String
  /-- the probability behind the verdict (the tail compared with 1 - confidence) -/
  pValue : Float
  deriving Inhabited

/-- A probability bound decided per tumbling window by an exact one-sided binomial test: met when
the observed hits (for at least) or misses (for at most) would be improbable if the bound were only
just met, violated when the opposite would be, undecided otherwise. -/
def judge (r : Requirement) (n k : Nat) : String × Float :=
  let alpha := 1 - r.confidence.num.toFloat / r.confidence.den.toFloat
  match r.bound with
  | .every => (if k == n then "met" else "violated", 0)
  | .atLeast p =>
    let (ge, le) := binomialTails n k (p.num.toFloat / p.den.toFloat)
    if n == 0 then ("undecided", 1) else if ge <= alpha then ("met", ge) else if le <= alpha then ("violated", le) else ("undecided", min ge le)
  | .atMost p =>
    let (ge, le) := binomialTails n k (p.num.toFloat / p.den.toFloat)
    if n == 0 then ("undecided", 1) else if le <= alpha then ("met", le) else if ge <= alpha then ("violated", ge) else ("undecided", min ge le)

/-- Tumbling windows over the entries. A window is judged only when its observation period is over:
a time window once the stream has passed its end plus the deadline (so all its entries are decided),
an entry window once it holds its N decided entries. Before that it is open, whatever it has seen,
so an early miss never breaks an agreement that needs the whole period to decide. -/
def windows (r : Requirement) (ts : List Trial) (last : Nat) : List WindowVerdict := Id.run do
  let decided := ts.filter (·.outcome != "pending")
  let groups : List (Nat × List Trial × Bool) := match r.window with
    | some (.time w) =>
      let keys := (ts.map (·.entry / w)).eraseDups
      keys.map fun k => (k * w, decided.filter (·.entry / w == k), decide (last ≥ k * w + w + r.withinMs.getD 0))
    | some (.entries n) =>
      (List.range ((decided.length + n - 1) / n)).map fun i =>
        let g := (decided.drop (i * n)).take n
        ((g.head?.map (·.entry)).getD 0, g, g.length == n)
    | none => [((decided.head?.map (·.entry)).getD 0, decided, false)]
  return groups.map fun (start, g, closed) =>
    let hits := (g.filter (·.outcome == "hit")).length
    let (v, pv) := judge r g.length hits
    { start, entries := g.length, hits, closed, verdict := if closed then v else "open", pValue := pv }

end LeanFM.Session.Sla
