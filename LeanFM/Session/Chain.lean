import LeanFM.Session.Decision

/-! Requirements selfhost.session.mdp.loops and .mdp.rewards: a sequential session with loops, under a
supplied policy, as an absorbing Markov chain with several rewards. Expected visits come from
v = start + vQ, solved exactly; an edge's expected traversals are visits(src) × probability; its
expected time is traversals × mean delay; amounts move per traversal on edges (a trade is a vector
whose two sides cancel unit by unit) and accrue per unit of time at the rate in force. The session
ends in one end state per distinct last step, and absorption probabilities from every state give
each outcome's probability and its conditional expectations. Loops are counted, never unrolled.
No user code, IO or markup evaluation. -/
namespace LeanFM.Session.Chain
open Lean LeanFM.Overlay Generative

structure State where
  id : Nat
  kind : String          -- start, state, choice, loop, rate, end
  label : String
  detail : String := ""
  deriving Inhabited

/-- One unit moved per traversal: from, to, unit, mean quantity. -/
abbrev Move := String × String × String × Rat

structure Edge where
  src : Nat
  dst : Nat
  kind : String          -- message, event, policy, loop, rate
  label : String
  prob : Q
  moves : List Move := []
  amountText : String := ""
  /-- mean delay in milliseconds before this step, after the one before it -/
  delay : Rat := 0
  delayText : String := ""
  /-- the largest delay, for checking that work fits in a gate's period -/
  maxDelay : Rat := 0
  /-- a periodic gate (at next d): the step waits for the next whole period since the start -/
  gate : Option Nat := none
  rates : List Accrual := []
  /-- the delay distribution (after), for generating walks -/
  delays : List (Nat × Q) := []
  /-- each amount's sender, receiver, unit and outcomes, for generating walks -/
  samples : List (String × String × String × List (Nat × Q)) := []
  /-- for message and event edges: the plain label, sender and receiver, for matching events -/
  step : String := ""
  sender : String := ""
  receiver : String := ""
  deriving Inhabited

structure G where
  states : Array State := #[]
  edges : Array Edge := #[]
  notes : List String := []
  absolute : Bool := false
  accrues : Bool := false

abbrev M := StateT G (Except String)

def maxStates := 96

def qRat (q : Q) : Rat := (q.num : Rat) / (q.den : Rat)

def ratText (r : Rat) : String := if r.den == 1 then toString r.num else s!"{r.num}/{r.den}"

def dayMs : Rat := 86400000

/-- A non-negative rational to two decimals, for reading alongside the exact value. -/
def approx (r : Rat) : String :=
  let n := (r * 100 + 1 / 2).floor
  let whole := n / 100
  let frac := (n % 100).toNat
  s!"{whole}.{if frac < 10 then "0" else ""}{frac}"

/-- A signed rational to two decimals. -/
def signedApprox (r : Rat) : String := if r ≥ 0 then "+" ++ approx r else "-" ++ approx (-r)

/-- A duration in the largest unit that fits (days, hours, minutes or seconds), exact, with a
decimal when it is not whole. -/
def daysText (ms : Rat) : String :=
  let (n, unit) : Rat × String :=
    if ms ≥ dayMs || ms == 0 then (ms / dayMs, "day")
    else if ms ≥ 3600000 then (ms / 3600000, "hour")
    else if ms ≥ 60000 then (ms / 60000, "minute")
    else (ms / 1000, "second")
  s!"{ratText n} {unit}{if n == 1 then "" else "s"}" ++ (if n.den == 1 || n < 0 then "" else s!" (≈ {approx n})")

def periodText (ms : Nat) : String :=
  if ms % 604800000 == 0 then (if ms == 604800000 then "week" else s!"{ms / 604800000} weeks")
  else if ms % 86400000 == 0 then (if ms == 86400000 then "day" else s!"{ms / 86400000} days")
  else if ms % 3600000 == 0 then (if ms == 3600000 then "hour" else s!"{ms / 3600000} hours")
  else s!"{ms} ms"

def addState (kind label : String) (detail : String := "") : M Nat := do
  let g ← get
  if g.states.size ≥ maxStates then throw s!"the chain exceeds {maxStates} states; simplify the session"
  let id := g.states.size
  set { g with states := g.states.push { id, kind, label, detail } }
  return id

def addEdge (e : Edge) : M Unit := modify fun g => { g with edges := g.edges.push e }

def note (n : String) : M Unit := modify fun g => if g.notes.contains n then g else { g with notes := g.notes ++ [n] }

/-- The step under its annotations, with its amounts (outermost last) and its time. -/
partial def peel : Stmt → Stmt × List Amount × Option TimeExpr
  | .timed t m => let (c, a, _) := peel m; (c, a, some t)
  | .valued a m => let (c, as, t) := peel m; (c, as ++ [a], t)
  | s => (s, [], none)

def meanAmount (a : Amount) : Rat :=
  a.outcomes.foldl (fun acc (n, q) => acc + (n : Rat) * qRat q) 0

def amountText (a : Amount) : String :=
  let sign := if a.reverse then "-" else ""
  match a.outcomes with
  | [(n, _)] => s!"{sign}{n} {a.unit}"
  | _ => s!"{sign}mean {ratText (meanAmount a)} {a.unit}"

def meanDelay (t : TimeExpr) : Rat := t.offsets.foldl (fun acc (d, q) => acc + (d : Rat) * qRat q) 0

/-- Build the statements backwards: `k` is the state that follows them; the result is their entry. -/
partial def build (loops : List (String × Nat)) (ss : List Stmt) (k : Nat) : M Nat := do
  match ss with
  | [] => return k
  | s :: rest =>
    let next ← build loops rest k
    stmt loops s next
where
  stmt (loops : List (String × Nat)) (s : Stmt) (k : Nat) : M Nat := do
    match s with
    | .msg .. | .timed .. | .valued .. | .event .. =>
      let (core, amounts, time) := peel s
      let (label, src, dst, kind, text) ← match core with
        | .msg _ label src dst .. => pure (label, src, dst, "message", s!"{label}: {src} → {dst}")
        | .event label role => pure (label, role, role, "event", s!"{label} at {role}")
        | _ => throw "an annotation must belong to a message or an event"
      let (delay, delayText) ← match time with
        | none => pure (0, "")
        | some t =>
          if let some d := t.period then pure (0, s!"at next {periodText d}")
          else if t.relative then
            let m := meanDelay t
            pure (m, if t.offsets.length == 1 then s!"after {daysText m}" else s!"after mean {daysText m}")
          else do
            modify fun g => { g with absolute := true }
            note "Absolute times (at a clock or at time(id)) are not used in the chain view; write after d for a delay after the previous step."
            pure (0, "")
      let n ← addState "state" "" s!"next: {label}"
      -- a positive entry moves from sender to receiver, a negative one the other way
      let moves : List Move := amounts.map fun a =>
        if a.reverse then (dst, src, a.unit, meanAmount a) else (src, dst, a.unit, meanAmount a)
      let gate := time.bind (·.period)
      let maxDelay : Rat := match time with
        | some t => if t.relative then (t.offsets.foldl (fun m (d, _) => max m d) 0 : Nat) else 0
        | none => 0
      let delays := match time with | some t => if t.relative then t.offsets else [] | none => []
      let samples := amounts.map fun a =>
        if a.reverse then (dst, src, a.unit, a.outcomes) else (src, dst, a.unit, a.outcomes)
      let e : Edge := { src := n, dst := k, kind, label := text, prob := Q.one, moves,
                        amountText := ", ".intercalate (amounts.map amountText), delay, delayText,
                        step := label, sender := src, receiver := dst, maxDelay, gate, delays, samples }
      addEdge e
      return n
    | .accrue as =>
      modify fun g => { g with accrues := true }
      let some a := as.head? | return k
      let entry (x : Accrual) : String :=
        s!"{if x.payer == a.payer then "" else "-"}{x.quantity} {x.unit}/{periodText x.periodMs}"
      let text := "accrue " ++ (if as.length == 1 then entry a else "{ " ++ ", ".intercalate (as.map entry) ++ " }")
      let n ← addState "rate" text s!"{a.payer} → {a.payee}"
      let e : Edge := { src := n, dst := k, kind := "rate", label := text ++ s!" from {a.payer} to {a.payee}", prob := Q.one, rates := as }
      addEdge e
      return n
    | .clock .. => return k
    | .obligation o =>
      throw s!"obligation {o.name}: deadlines depend on a path's history, so the chain view does not evaluate them; use the tree view (a session without rec or accrue)"
    | .weighted name actor qs bs =>
      if qs.isEmpty then throw s!"choice {name} needs probabilities for the chain view (probability n/d per branch)"
      let c ← addState "choice" (if actor.isEmpty then "Choice" else actor ++ " chooses") name
      for (b, i) in bs.zipIdx do
        let entry ← build loops b k
        let e : Edge := { src := c, dst := entry, kind := "policy", label := s!"Action {i + 1}", prob := (qs[i]?).getD Q.zero }
        addEdge e
      return c
    | .choice _ => throw "every choice needs probabilities for the chain view: choice at Role using declared(name) { probability n/d: ... }"
    | .loop name body =>
      let l ← addState "loop" s!"loop {name}" ""
      let entry ← build ((name, l) :: loops) body k
      addEdge { src := l, dst := entry, kind := "loop", label := s!"rec {name}", prob := Q.one }
      return l
    | .cont name =>
      match loops.lookup name with
      | some l => return l
      | none => throw s!"continue {name} is not inside rec {name}"
    | _ => throw "the chain view supports sequential sessions with choices and loops; par, join, sessions and include need scheduling semantics"

/-- The accruals in force: canonical (a zero rate is no rate), keyed by payer, payee and unit. -/
abbrev Regime := List Accrual

def Regime.set (r : Regime) (a : Accrual) : Regime :=
  -- a new rate between the same two roles in the same unit replaces the old one, whichever way it flows
  let same (x : Accrual) := x.unit == a.unit &&
    ((x.payer == a.payer && x.payee == a.payee) || (x.payer == a.payee && x.payee == a.payer))
  let kept := r.filter fun x => !(same x)
  let all := if a.quantity == 0 then kept else kept ++ [a]
  let key (x : Accrual) : String := x.payer ++ "\u0000" ++ x.payee ++ "\u0000" ++ x.unit
  all.mergeSort fun x y => decide (key x ≤ key y)

structure Chain where
  states : Array State
  edges : Array Edge
  start : Nat
  ends : List Nat
  visits : Array Rat
  /-- for each end, the probability of ending there from each state -/
  absorb : List (Nat × Array Rat)
  regime : Array Regime
  notes : List String
  deriving Inhabited

/-- Gauss-Jordan elimination on an augmented m × (m+1) matrix with exact rationals. -/
def gauss (m : Nat) (a0 : Array (Array Rat)) : Except String (Array Rat) := do
  let mut a := a0
  for col in [0:m] do
    let some p := (List.range m).find? (fun r => r ≥ col && a[r]![col]! != 0)
      | throw "the session can loop forever: some state can never reach an end, so expected visits are infinite"
    let tmp := a[col]!; a := (a.set! col a[p]!).set! p tmp
    let pivot := a[col]![col]!
    a := a.set! col ((a[col]!).map (· / pivot))
    for r in [0:m] do
      if r != col then
        let f := a[r]![col]!
        if f != 0 then
          let rowc := a[col]!
          a := a.set! r ((List.range (m + 1)).toArray.map fun c => a[r]![c]! - f * rowc[c]!)
  return (List.range m).toArray.map fun r => a[r]![m]!

/-- Expected visits: (I - Q)^T v = e_start over the transient states; an end's visits are the
traversals of the edges into it. Absorption: (I - Q) h = r_k for each end k. -/
def solve (n start : Nat) (ends : List Nat) (edges : Array Edge) : Except String (Array Rat × List (Nat × Array Rat)) := do
  let idx := (List.range n).filter (!ends.contains ·)
  let pos (i : Nat) : Nat := (idx.findIdx? (· == i)).getD 0
  let m := idx.length
  let identity : Array (Array Rat) := (List.range m).toArray.map fun j =>
    (List.range (m + 1)).toArray.map fun c => if c == j then 1 else 0
  let mut at_ := identity
  let mut a := identity
  for e in edges do
    if !ends.contains e.src && !ends.contains e.dst then
      let r := pos e.dst; let c := pos e.src
      at_ := at_.set! r ((at_[r]!).set! c (at_[r]![c]! - qRat e.prob))
      a := a.set! c ((a[c]!).set! r (a[c]![r]! - qRat e.prob))
  let s := pos start
  let vt ← gauss m (at_.set! s ((at_[s]!).set! m 1))
  let mut v : Array Rat := Array.replicate n 0
  for (i, j) in idx.zipIdx do v := v.set! i vt[j]!
  for k in ends do
    let into := edges.foldl (fun acc e => if e.dst == k && !ends.contains e.src then acc + v[e.src]! * qRat e.prob else acc) 0
    v := v.set! k into
  let mut absorb := []
  for k in ends do
    let mut b := a
    for e in edges do
      if e.dst == k && !ends.contains e.src then
        let r := pos e.src
        b := b.set! r ((b[r]!).set! m (b[r]![m]! + qRat e.prob))
    let h ← gauss m b
    let mut full : Array Rat := Array.replicate n 0
    for (i, j) in idx.zipIdx do full := full.set! i h[j]!
    full := full.set! k 1
    absorb := absorb ++ [(k, full)]
  return (v, absorb)

/-- The accruals in force at every state, from the start along the edges; a state reached with two
different sets is refused, since the chain would have to remember the path. -/
def regimes (states : Array State) (edges : Array Edge) (start : Nat) (ends : List Nat) : Except String (Array Regime) := do
  let mut r : Array (Option Regime) := Array.replicate states.size none
  r := r.set! start (some [])
  let mut queue := [start]
  let mut guard := 0
  while !queue.isEmpty do
    guard := guard + 1
    if guard > 100000 then throw "rate propagation did not settle"
    let s := queue.head!; queue := queue.tail
    let here := (r[s]!).getD []
    for e in edges do
      if e.src == s then
        let there := e.rates.foldl Regime.set here
        match r[e.dst]! with
        | none => r := r.set! e.dst (some there); queue := queue ++ [e.dst]
        | some old =>
          if old != there && !ends.contains e.dst then
            let st := states[e.dst]!
            let name := if st.kind == "state" then s!"S{st.id} ({st.detail})" else st.label
            throw s!"the rate in force at {name} differs between paths that reach it; declare the rate after the paths meet"
  return r.map (·.getD [])

def analyse (r : Resolved) (solveAll : Bool := true) : Except String Chain := do
  let run : M (Nat × Nat) := do
    let finish ← addState "end" "End" ""
    let entry ← build [] r.body finish
    let start ← addState "start" "Start" ""
    addEdge { src := start, dst := entry, kind := "loop", label := "begin", prob := Q.one }
    return (start, finish)
  let ((start, finish), g0) ← run.run {}
  if g0.absolute && g0.accrues then
    throw "an accrual needs delays after the previous step (after d); absolute times (at a clock or at time(id)) cannot be used with it"
  -- one end per distinct last step: the shared end takes the first outcome, new ends the others
  let mut g := g0
  let mut ends : List (String × Nat) := []
  let shortLabel (e : Edge) : String := ((e.label.splitOn ":").headD e.label)
  for (e, i) in g0.edges.zipIdx do
    if e.dst == finish then
      let name := "End after " ++ shortLabel e
      match ends.lookup name with
      | some k => g := { g with edges := g.edges.set! i { e with dst := k } }
      | none =>
        if ends.isEmpty then
          g := { g with states := g.states.set! finish { g.states[finish]! with label := name }, }
          ends := [(name, finish)]
        else
          if g.states.size ≥ maxStates then throw s!"the chain exceeds {maxStates} states; simplify the session"
          let k := g.states.size
          g := { g with states := g.states.push { id := k, kind := "end", label := name },
                        edges := g.edges.set! i { e with dst := k } }
          ends := ends ++ [(name, k)]
  let endIds := if ends.isEmpty then [finish] else ends.map (·.2)
  for st in g.states do
    if !endIds.contains st.id then
      let out := g.edges.filter (·.src == st.id)
      if out.foldl (fun q e => Q.add q e.prob) Q.zero != Q.one then
        throw s!"outgoing probabilities of state {st.id} do not sum to 1"
  if solveAll && g.edges.any (·.gate.isSome) then
    throw "a periodic gate (at next d) needs a horizon: pass horizon, such as 52 weeks, to count whole periods"
  let (visits, absorb) ← if solveAll then solve g.states.size start endIds g.edges
    else pure (Array.replicate g.states.size 0, [])
  let regime ← regimes g.states g.edges start endIds
  return { states := g.states, edges := g.edges, start, ends := endIds, visits, absorb, regime, notes := g.notes }

def traversals (c : Chain) (e : Edge) : Rat := c.visits[e.src]! * qRat e.prob

/-- What one traversal of `e` moves, per role and unit: its trade vector, and every accrual in force
at its source over its mean delay. -/
def rewards (c : Chain) (e : Edge) : List (String × String × Rat) :=
  let moved := e.moves.flatMap fun (f, t, u, q) => [(f, u, -q), (t, u, q)]
  let accrued := (c.regime[e.src]!).flatMap fun a =>
    let x := e.delay * (a.quantity : Rat) / (a.periodMs : Rat)
    [(a.payer, a.unit, -x), (a.payee, a.unit, x)]
  moved ++ accrued

/-- Where each role's expected balance comes from: role, unit, source (a message's label, or the rate
that accrued) and traversals × amount, exact. -/
def contributions (c : Chain) : List (String × String × String × Rat) := Id.run do
  let mut out : List (String × String × String × Rat) := []
  let add (bs : List (String × String × String × Rat)) (r u src : String) (x : Rat) :=
    if bs.any (fun (r', u', s', _) => r' == r && u' == u && s' == src) then
      bs.map fun (r', u', s', v) => if r' == r && u' == u && s' == src then (r', u', s', v + x) else (r', u', s', v)
    else bs ++ [(r, u, src, x)]
  -- the protocol's order is the reverse of the edges'
  for e in c.edges.toList.reverse do
    let t := c.visits[e.src]! * qRat e.prob
    for (f, to, u, q) in e.moves do
      out := add (add out f u e.step (-(t * q))) to u e.step (t * q)
    for a in c.regime[e.src]! do
      let x := t * e.delay * (a.quantity : Rat) / (a.periodMs : Rat)
      if x != 0 then
        let src := s!"accrue {a.quantity} {a.unit}/{periodText a.periodMs}"
        out := add (add out a.payer a.unit src (-x)) a.payee a.unit src x
  return out

def addTo (bs : List (String × String × Rat)) (role unit : String) (x : Rat) : List (String × String × Rat) :=
  if bs.any (fun (r,u,_) => r == role && u == unit) then
    bs.map fun (r,u,v) => if r == role && u == unit then (r,u,v+x) else (r,u,v)
  else bs ++ [(role, unit, x)]

/-- Units in the order the protocol first moves or accrues them, and within each unit every listed
role in order (zero where it moves nothing), as the tree reports them. -/
def ordered (c : Chain) (roles : List String) (raw : List (String × String × Rat)) : List (String × String × Rat) :=
  -- the chain is built backwards, so the protocol's order is the reverse of the edges'
  let units := (c.edges.toList.reverse.flatMap fun e =>
    e.moves.map (·.2.2.1) ++ e.rates.map (·.unit)).eraseDups
  let listed := roles ++ ((raw.map (·.1)).eraseDups.filter (!roles.contains ·))
  units.flatMap fun u => listed.map fun r =>
    (r, u, ((raw.find? fun (r', u', _) => r' == r && u' == u).map (·.2.2)).getD 0)

/-- Each role's expected net balance per unit over a whole session. -/
def expected (c : Chain) (roles : List String) : List (String × String × Rat) :=
  ordered c roles <| c.edges.foldl (fun acc e =>
    (rewards c e).foldl (fun acc (r, u, x) => addTo acc r u (traversals c e * x)) acc) []

def expectedMessages (c : Chain) : Rat :=
  c.edges.foldl (fun acc e => if e.kind == "message" then acc + traversals c e else acc) 0

def expectedDuration (c : Chain) : Rat :=
  c.edges.foldl (fun acc e => acc + traversals c e * e.delay) 0

/-- Expected time spent in a state: the expected times of the edges that leave it. -/
def residence (c : Chain) (s : Nat) : Rat :=
  c.edges.foldl (fun acc e => if e.src == s then acc + traversals c e * e.delay else acc) 0

/-- Given that the session ends at `k`: its probability, and the expected balances and duration on
the paths that end there (the joint expectation divided by the probability). -/
def outcome (c : Chain) (roles : List String) (k : Nat) : Rat × Option (List (String × String × Rat) × Rat) :=
  let p := c.visits[k]!
  let h := ((c.absorb.lookup k).getD #[])
  let joint (e : Edge) : Rat := c.visits[e.src]! * qRat e.prob * h.getD e.dst 0
  if p == 0 then (0, none) else
  let bal := c.edges.foldl (fun acc e =>
    (rewards c e).foldl (fun acc (r, u, x) => addTo acc r u (joint e * x / p)) acc) []
  let dur := c.edges.foldl (fun acc e => acc + joint e * e.delay / p) 0
  (p, some (ordered c roles bal, dur))

/-- A map keyed by role, then by unit (as `USD` or `USD/week`), of exact signed values. -/
def byRole (bs : List (String × String × Rat)) : Json :=
  let roles := (bs.map (·.1)).eraseDups
  Json.mkObj (roles.map fun r => (r, Json.mkObj ((bs.filter (·.1 == r)).map fun (_, u, v) => (u, Json.str (ratText v)))))

/-- The flows in force at a state, per role and per unit of time: each rate keyed as UNIT/PERIOD. -/
def flows (c : Chain) (s : Nat) : List (String × String × Rat) :=
  (c.regime[s]!).foldl (fun acc a =>
    let key := s!"{a.unit}/{periodText a.periodMs}"
    addTo (addTo acc a.payer key (-(a.quantity : Rat))) a.payee key (a.quantity : Rat)) []

def stateJson (c : Chain) (s : State) : Json := Json.mkObj
  [("id", s.id), ("kind", s.kind), ("label", s.label), ("detail", s.detail), ("expectedVisits", ratText c.visits[s.id]!),
   ("expectedResidenceMs", ratText (residence c s.id)),
   ("flows", byRole (flows c s.id)),
   ("ratesInForce", toJson ((c.regime[s.id]!).map fun a => Json.mkObj [("payer", a.payer), ("payee", a.payee),
     ("unit", a.unit), ("quantity", a.quantity), ("periodMs", a.periodMs)]))]

def edgeJson (c : Chain) (e : Edge) : Json := Json.mkObj
  [("src", e.src), ("dst", e.dst), ("kind", e.kind), ("label", e.label), ("probability", e.prob.text),
   ("expectedTraversals", ratText (traversals c e)), ("meanDelayMs", ratText e.delay),
   ("moves", toJson (e.moves.map fun (f, t, u, q) => Json.mkObj [("from", f), ("to", t), ("unit", u), ("mean", ratText q)]))]

def balancesText (bs : List (String × String × Rat)) : String :=
  " · ".intercalate ((bs.filter (·.2.2 != 0)).map fun (r,u,v) => s!"{r} {if v ≥ 0 then "+" else ""}{ratText v} {u}")

/-! ## Whole periods behind a gate (selfhost.session.mdp.horizon) -/

structure Horizon where
  chain : Chain
  periods : Nat
  periodMs : Nat
  gate : Nat
  stillRunning : Rat
  passages : Rat

/-- The longest time from `a` to `b` over the edges other than `skip`, with each delay at its
largest; a cycle among those edges is refused, since every loop has to pass the gate. -/
partial def longest (c : Chain) (skip a b : Nat) : Except String (Option Rat) := do
  let mut memo : Array (Option (Option Rat)) := Array.replicate c.states.size none
  let rec go (s : Nat) (onPath : List Nat) (memo : Array (Option (Option Rat))) : Except String (Option Rat × Array (Option (Option Rat))) := do
    if s == b then return (some 0, memo)
    if let some v := memo[s]! then return (v, memo)
    if onPath.contains s then throw "a loop does not pass the gate; with a horizon every loop has to wait for the next period"
    let mut best : Option Rat := none
    let mut m := memo
    for (e, i) in c.edges.zipIdx do
      if e.src == s && i != skip then
        let (r, m') ← go e.dst (s :: onPath) m
        m := m'
        if let some t := r then best := some (max (best.getD 0) (t + e.maxDelay))
    return (best, m.set! s (some best))
  let (r, _) ← go a [] memo
  return r

def geometric (q : Rat) (m : Nat) : Rat := Id.run do
  let mut acc : Rat := 0
  let mut pow : Rat := 1
  for _ in [0:m] do
    acc := acc + pow; pow := pow * q
  return acc

def horizon (c0 : Chain) (horizonMs : Nat) : Except String Horizon := do
  let gates := (List.range c0.edges.size).filter fun i => c0.edges[i]!.gate.isSome
  let gi ← match gates with
    | [i] => pure i
    | [] => throw "a horizon needs exactly one periodic gate (at next d), such as a weekly payment at next 1 week"
    | _ => throw "a horizon supports one periodic gate; this session has several"
  let g := c0.edges[gi]!
  let P := g.gate.getD 1
  if horizonMs < P then throw s!"the horizon is shorter than one period ({periodText P})"
  let N := horizonMs / P
  if N > 10000 then throw "a horizon has at most 10000 periods"
  let sg := g.src
  -- every path to the gate has to fit in its period
  for (from_, what) in [(c0.start, "before the first gate"), (g.dst, "between gates")] do
    if let some t ← longest c0 gi from_ sg then
      if t > (P : Rat) then throw s!"the work {what} can take {daysText t}, longer than the period ({periodText P})"
  let ends := c0.ends ++ [sg]
  let n := c0.states.size
  -- the start's segment and the cycle, each as an absorbing chain that stops at the gate or an end
  let others := c0.edges.toList.zipIdx.filter (·.2 != gi) |>.map (·.1) |>.toArray
  let (vInit, aInit) ← solve n c0.start ends others
  let (vCyc, aCyc) ← if g.dst == sg then pure (Array.replicate n 0, [(sg, Array.replicate n 0)])
    else solve n g.dst ends others
  let q0 := vInit[sg]!
  let q := if g.dst == sg then 1 else vCyc[sg]!
  let passages := q0 * geometric q N
  let cycles := if N == 0 then 0 else q0 * geometric q (N - 1)
  let hInit := (aInit.lookup sg).getD #[]
  let hCyc := (aCyc.lookup sg).getD #[]
  let jointTime (v h : Array Rat) : Rat := others.foldl (fun acc e =>
    if ends.contains e.src then acc else acc + v[e.src]! * qRat e.prob * e.delay * h.getD e.dst 0) 0
  let wait := (P : Rat) * passages - (jointTime vInit hInit + cycles * jointTime vCyc hCyc)
  let visits := (List.range n).toArray.map fun s =>
    if s == sg then passages else vInit[s]! + cycles * vCyc[s]!
  let meanWait := if passages == 0 then 0 else wait / passages
  let edges := c0.edges.set! gi { g with delay := meanWait, delayText := s!"at next {periodText P}" }
  let stillRunning := q0 * geometric q N - q0 * geometric q (N - 1)
  return { chain := { c0 with visits, edges }, periods := N, periodMs := P, gate := gi, stillRunning, passages }

/-! ## One walk (selfhost.session.mdp.walk): the same rewards on actual counts and times -/

structure Step where
  label : String
  sender : Option String := none
  receiver : Option String := none
  /-- the time since the previous step, in milliseconds; none takes the edge's mean delay -/
  afterMs : Option Rat := none
  /-- the amounts actually moved; none takes the edge's means -/
  amounts : Option (List Move) := none
  deriving Inhabited

structure Walked where
  counts : Array Nat
  visits : Array Nat
  time : Array Rat
  duration : Rat
  probability : Rat
  balances : List (String × String × Rat)
  ended : Bool
  steps : Nat

def silent (e : Edge) : Bool := e.kind == "policy" || e.kind == "loop" || e.kind == "rate"

def stepMatches (e : Edge) (st : Step) : Bool :=
  (e.kind == "message" || e.kind == "event") && e.step == st.label &&
  st.sender.all (· == e.sender) && st.receiver.all (· == e.receiver)

/-- From `cur`, the edges matching `want` reachable through silent edges, each with the silent edges
taken to reach it (breadth-first, each state once). -/
def reach (c : Chain) (cur : Nat) (want : Edge → Bool) : List (List Nat × Nat) := Id.run do
  let ids := (List.range c.edges.size)
  let mut seen := [cur]
  let mut frontier : List (Nat × List Nat) := [(cur, [])]
  let mut found : List (List Nat × Nat) := []
  let mut guard := 0
  while !frontier.isEmpty && guard < c.states.size + 1 do
    guard := guard + 1
    let mut next := []
    for (s, path) in frontier do
      for i in ids do
        let e := c.edges[i]!
        if e.src == s then
          if want e then found := found ++ [(path, i)]
          else if silent e && !seen.contains e.dst then
            seen := e.dst :: seen
            next := next ++ [(e.dst, path ++ [i])]
    frontier := next
  return found

def walk (c : Chain) (steps : List Step) : Except String Walked := do
  if steps.length > 512 then throw "a walk has at most 512 steps"
  let mut counts := Array.replicate c.edges.size 0
  let mut visits := Array.replicate c.states.size 0
  let mut time : Array Rat := Array.replicate c.states.size 0
  let mut prob : Rat := 1
  let mut bal : List (String × String × Rat) := []
  let mut cur := c.start
  visits := visits.set! cur 1
  for (st, n) in steps.zipIdx do
    let found := reach c cur (stepMatches · st)
    let distinct := (found.map (·.2)).eraseDups
    match distinct with
    | [i] =>
      let some (path, _) := found.find? (·.2 == i) | throw "walk lost its path"
      for j in path do
        let e := c.edges[j]!
        counts := counts.set! j (counts[j]! + 1); visits := visits.set! e.dst (visits[e.dst]! + 1)
        prob := prob * qRat e.prob
      let e := c.edges[i]!
      let d := st.afterMs.getD e.delay
      -- amounts actually moved replace the means, each matching one of the edge's moves
      let moves ← match st.amounts with
        | none => pure e.moves
        | some ms => do
          for (f, t, u, _) in ms do
            if !e.moves.any (fun (f', t', u', _) => f' == f && t' == t && u' == u) then
              throw (s!"step {n + 1} ({st.label}) moves {u} from {f} to {t}, which the protocol's {e.step} does not" : String)
          pure ms
      counts := counts.set! i (counts[i]! + 1); visits := visits.set! e.dst (visits[e.dst]! + 1)
      time := time.set! e.src (time[e.src]! + d)
      for (r, u, x) in rewards c { e with delay := d, moves } do bal := addTo bal r u x
      cur := e.dst
    | [] =>
      let describe (i : Nat) : String :=
        let e := c.edges[i]!
        if e.kind == "event" then s!"{e.step} at {e.sender}" else s!"{e.step} from {e.sender} to {e.receiver}"
      let next : List String := (reach c cur (fun e => e.kind == "message" || e.kind == "event")).map (describe ·.2)
      let options : String := if next.isEmpty then "nothing (the session has ended)" else ", ".intercalate next.eraseDups
      throw (s!"step {n + 1} ({st.label}) does not fit the protocol here; what could come next: " ++ options : String)
    | _ => throw (s!"step {n + 1} ({st.label}) matches more than one step of the protocol here; give its sender and receiver" : String)
  -- a walk that stops where only silent edges lead to one end has ended there
  let mut ended := c.ends.contains cur
  if !ended then
    match ((reach c cur (fun e => c.ends.contains e.dst && silent e)).map (·.2)).eraseDups with
    | [i] =>
      let some (path, _) := (reach c cur (fun e => c.ends.contains e.dst && silent e)).find? (·.2 == i) | pure ()
      for j in path ++ [i] do
        let e := c.edges[j]!
        counts := counts.set! j (counts[j]! + 1); visits := visits.set! e.dst (visits[e.dst]! + 1)
        prob := prob * qRat e.prob
      ended := true
    | _ => pure ()
  let duration := time.foldl (· + ·) 0
  return { counts, visits, time, duration, probability := prob, balances := bal, ended, steps := steps.length }

/-! ## Generating walks (selfhost.session.generate.chain) -/

structure Generated where
  events : Array (Event String)
  amounts : Array (List Move)
  ended : List (Nat × Bool)
  deriving Inhabited

def generate (c : Chain) (seed sessions : Nat) (maxEvents : Nat := 512) : Except String Generated := do
  let mut rng := seed
  let mut events : Array (Event String) := #[]
  let mut amounts : Array (List Move) := #[]
  let mut ended : List (Nat × Bool) := []
  for sid in [1:sessions + 1] do
    let mut cur := c.start
    let mut now := 0
    let mut last : Option Nat := none
    let mut count := 0
    let mut guard := 0
    while !c.ends.contains cur && count < maxEvents && guard < maxEvents * (c.states.size + 1) do
      guard := guard + 1
      let outs := c.edges.toList.filter (·.src == cur)
      let e ← match outs with
        | [] => break
        | [e] => pure e
        | es => do
          let (i, r) ← Generative.choose (es.map (·.prob)) rng
          rng := r
          pure (es.getD i es.head!)
      if e.kind == "message" || e.kind == "event" then
        -- the delay: drawn, or the wait for the next whole period of a gate
        match e.gate with
        | some p => now := (now / p + 1) * p
        | none =>
          if !e.delays.isEmpty then
            let (i, r) ← Generative.choose (e.delays.map (·.2)) rng
            rng := r
            now := now + ((e.delays[i]?).map (·.1)).getD 0
        let mut moved : List Move := []
        for (f, t, u, os) in e.samples do
          let (i, r) ← Generative.choose (os.map (·.2)) rng
          rng := r
          let q : Nat := ((os[i]?).map (·.1)).getD 0
          let m : Move := (f, t, u, (q : Rat))
          moved := moved ++ [m]
        let id := events.size + 1
        let ev : Event String := { id, session := sid, prior := last.toList, cause := none, answers := none, src := e.sender, dst := e.receiver, label := e.step, msgId := none, route := none, status := none, isAct := e.kind == "event", time := now }
        events := events.push ev
        amounts := amounts.push moved
        last := some id
        count := count + 1
      cur := e.dst
    ended := ended ++ [(sid, c.ends.contains cur)]
  return { events, amounts, ended }

/-- The legend's lines: per role, each unit's expected balance with where it came from, and the
effective price when the role trades exactly two units against each other. Decimals for reading;
the exact values are in the result. -/
def legend (c : Chain) (roles : List String) : List String :=
  let exp := (expected c roles).filter (·.2.2 != 0)
  let parts := contributions c
  let listed := (exp.map (·.1)).eraseDups
  if listed.isEmpty then [] else
  ["Expected per role (≈, exact values in the result):"] ++ listed.map fun r =>
    let mine := exp.filter (·.1 == r)
    let unitText (u : String) (v : Rat) : String :=
      let srcs := (parts.filter fun (r', u', _, x) => r' == r && u' == u && x != 0).map fun (_, _, src, x) => s!"{src} {signedApprox x}"
      s!"{signedApprox v} {u}" ++ (if srcs.length > 1 then " (" ++ ", ".intercalate srcs ++ ")" else
        match srcs with | [x] => s!" ({x})" | _ => "")
    let price := match mine with
      | [(_, u1, v1), (_, u2, v2)] =>
        if (v1 > 0) != (v2 > 0) then
          let (a, ua, b, ub) := if v1.abs ≥ v2.abs then (v1.abs, u1, v2.abs, u2) else (v2.abs, u2, v1.abs, u1)
          s!" · {approx (a / b)} {ua} per {ub}"
        else ""
      | _ => ""
    s!"{r}: " ++ " · ".intercalate (mine.map fun (_, u, v) => unitText u v) ++ price

/-- Per role, unit and source, the exact contribution, as a nested map. -/
def breakdownJson (c : Chain) : Json :=
  let parts := (contributions c).filter (·.2.2.2 != 0)
  let roles := (parts.map (·.1)).eraseDups
  Json.mkObj (roles.map fun r =>
    let units := ((parts.filter (·.1 == r)).map (·.2.1)).eraseDups
    (r, Json.mkObj (units.map fun u =>
      (u, Json.mkObj ((parts.filter fun (r', u', _, _) => r' == r && u' == u).map fun (_, _, src, x) => (src, Json.str (ratText x)))))))

/-- States in levels by breadth-first depth from the start; back edges curve to the right. -/
def drawing (c : Chain) (roles : List String := []) : Except String DiagramModel := do
  let n := c.states.size
  let mut depth : Array (Option Nat) := Array.replicate n none
  depth := depth.set! c.start (some 0)
  let mut frontier := [c.start]
  let mut order := [c.start]
  while !frontier.isEmpty do
    let mut next := []
    for s in frontier do
      for e in c.edges do
        if e.src == s && (depth[e.dst]!).isNone then
          depth := depth.set! e.dst (some ((depth[s]!).getD 0 + 1))
          next := next ++ [e.dst]; order := order ++ [e.dst]
    frontier := next
  -- the ends go last, on their own level; an end no path reaches is not drawn
  let deepest := order.foldl (fun d s => if c.ends.contains s then d else max d ((depth[s]!).getD 0)) 0
  for k in c.ends do
    if (depth[k]!).isSome then depth := depth.set! k (some (deepest + 1))
  let levels := (List.range (deepest + 2)).map fun d => order.filter fun s => (depth[s]!).getD 0 == d
  let label (s : State) : String := if s.kind == "state" then s!"S{s.id}" else s.label
  let outcomeText (k : Nat) : String :=
    match outcome c roles k with
    | (p, some (bal, _)) => s!"probability {ratText p}" ++ (if balancesText bal == "" then "" else " · " ++ balancesText bal)
    | (_, none) => "probability 0"
  let visitsText (s : State) : String :=
    let stay := residence c s.id
    s!"expected visits {ratText c.visits[s.id]!}" ++ (if stay == 0 then "" else s!" · time here {daysText stay}")
  let boxW := c.states.foldl (fun w s => max w ((max (label s).length (max s.detail.length
    (if s.kind == "end" then (outcomeText s.id).length else (visitsText s).length))) * 7 + 40)) 160
  let edgeText (e : Edge) : String :=
    (if e.kind == "message" || e.kind == "event" || e.kind == "rate" then e.label ++ " · " else
        if e.kind == "policy" then "policy " ++ e.prob.text ++ " · " else "") ++
      s!"×{ratText (traversals c e)}" ++ (if e.amountText.isEmpty then "" else " · " ++ e.amountText) ++
      (if e.delayText.isEmpty then "" else " · " ++ e.delayText)
  let edgeW := c.edges.foldl (fun w e => max w ((edgeText e).length * 7 + 20)) 0
  let slot := max (boxW + 60) (edgeW + 40)
  let widest := levels.foldl (fun w l => max w l.length) 1
  let width := widest * slot + 260 + (c.edges.filter fun e => ((depth[e.dst]!).getD 0) > ((depth[e.src]!).getD 0) + 1).size * 36 + 40 +
    (c.edges.foldl (fun w e => max w ((edgeText e).length * 7 + 20)) 0)
  let rowH := 150
  let height := levels.length * rowH + 140
  if width > 20000 || height > 20000 then throw "chain drawing exceeds dimension limit; simplify the session"
  -- forward edges that skip a level run down the left margin, so they never cross a state
  let level (s : Nat) : Nat := (depth[s]!).getD 0
  let longs := c.edges.filter fun e => level e.dst > level e.src + 1
  let longLabel := longs.foldl (fun w e => max w ((edgeText e).length * 7 + 20)) 0
  let margin := if longs.isEmpty then 0 else longs.size * 36 + 40 + longLabel
  let mut xs : Array Nat := Array.replicate n 0
  for l in levels do
    let span := l.length * slot
    let left := (widest * slot - span) / 2
    for (s, i) in l.zipIdx do
      xs := xs.set! s (margin + left + i * slot + slot / 2)
  let y (s : Nat) := ((depth[s]!).getD 0) * rowH + 60
  let rightmost := xs.foldl max 0 + boxW / 2
  let backs := c.edges.filter fun e => !((depth[e.dst]!).getD 0 > (depth[e.src]!).getD 0)
  let backLabel := backs.foldl (fun w e => max w ((edgeText e).length * 7 + 30)) 0
  let width := max width (rightmost + 60 + backs.size * 36 + backLabel)
  let mut shapes : Array Shape := #[]
  let mut bend := 0
  let mut lane := 0
  for e in c.edges do
    let forward := (depth[e.dst]!).getD 0 > (depth[e.src]!).getD 0
    let text := edgeText e
    if forward && level e.dst > level e.src + 1 then
      lane := lane + 1
      let x0 := xs[e.src]!; let y0 := y e.src + 35; let low := y e.src + 35 + 12 * lane
      let lm := margin - lane * 36
      let x2 := xs[e.dst]! - boxW / 2; let y2 := y e.dst
      shapes := shapes.push (.path "skip" s!"M {x0} {y0} L {x0} {low} L {lm + 16} {low} Q {lm} {low} {lm} {low + 16} L {lm} {y2 - 16} Q {lm} {y2} {lm + 16} {y2} L {x2} {y2}" .none .arrow "" true)
      let lw := text.length * 7 + 10
      let my := (low + y2) / 2
      shapes := shapes.push (.rect "label" (lm - lw - 6) (my - 13) lw 18 4 .bg .bg)
      shapes := shapes.push (.text "boxed" (lm - 11) my "end" .fg 12 false text)
    else if forward then
      let x1 := xs[e.src]!; let y1 := y e.src + 35; let x2 := xs[e.dst]!; let y2 := y e.dst - 35
      shapes := shapes.push (.line "" x1 y1 x2 y2 .arrow "2" "" true)
      let lw := text.length * 7 + 10
      -- labels go where sibling edges are furthest apart: toward the target when edges fan out from
      -- their source, toward the source when they converge on their target
      let fanOut := (c.edges.filter (·.src == e.src)).size > 1
      let fanIn := (c.edges.filter (·.dst == e.dst)).size > 1
      let (a, b) := if fanOut then (1, 2) else if fanIn then (2, 1) else (1, 1)
      let mx := (a * x1 + b * x2) / (a + b); let my := (a * y1 + b * y2) / (a + b)
      shapes := shapes.push (.rect "label" (mx - lw / 2) (my - 13) lw 18 4 .bg .bg)
      shapes := shapes.push (.text "boxed" mx my "middle" .fg 12 false text)
    else
      bend := bend + 1
      -- back edges leave from the bottom into the gap under the source's row, then run up the right
      -- margin, clear of every state
      let x0 := xs[e.src]!; let y0 := y e.src + 35; let low := y e.src + 35 + 12 * bend
      let x2 := xs[e.dst]! + boxW / 2; let y2 := y e.dst
      let out := rightmost + 40 + bend * 36
      shapes := shapes.push (.path "back" s!"M {x0} {y0} L {x0} {low} L {out - 16} {low} Q {out} {low} {out} {low - 16} L {out} {y2 + 16} Q {out} {y2} {out - 16} {y2} L {x2} {y2}" .none .arrow "6 4" true)
      let lw := text.length * 7 + 10
      let my := (low + y2) / 2
      shapes := shapes.push (.rect "label" (out + 6) (my - 13) lw 18 4 .bg .bg)
      shapes := shapes.push (.text "boxed" (out + 11) my "start" .fg 12 false text)
  for s in c.states do
    if (depth[s.id]!).isSome then
    let x := xs[s.id]!; let yy := y s.id
    let stroke : Ink := if s.kind == "end" then .frame else .arrow
    shapes := shapes.push (.rect s.kind (x - boxW / 2) (yy - 35) boxW 70 (if s.kind == "choice" then 30 else 8) .actFill stroke)
    shapes := shapes.push (.text "boxed" x (yy - 12) "middle" .fg 13 true (label s))
    if s.kind == "end" then
      shapes := shapes.push (.text "boxed" x (yy + 8) "middle" .frame 12 true (outcomeText s.id))
    else
      if !s.detail.isEmpty then shapes := shapes.push (.text "boxed" x (yy + 6) "middle" .fg 12 false s.detail)
      shapes := shapes.push (.text "boxed" x (yy + 24) "middle" .frame 12 true (visitsText s))
  let footer := legend c roles ++
    [s!"Expected messages: {ratText (expectedMessages c)}" ++
      (if expectedDuration c == 0 then "" else s!" · expected duration {daysText (expectedDuration c)}")]
  let width := max width (footer.foldl (fun w l => max w (l.length * 8 + 40)) 0)
  for (line, i) in footer.zipIdx do
    shapes := shapes.push (.text "" (width / 2) (height - 60 + i * 20) "middle" .frame 13 true line)
  return { width, height := height + footer.length * 20, shapes }

end LeanFM.Session.Chain
