import Lean.Data.Json
import LeanFM.Session.Where

/-!
# Sessions derived from the protocol (clause selfhost.session.derived-sessions)

A session in an event stream is derived, not read. Two kinds of join put events in one session:

* an equation in a where clause between fields of two messages, `a.roomId = q.roomId`, at the top
  of the condition or under `and`: the events of those messages carrying the same value in the
  equated fields are joined, transitively across equations (the (message, field) pairs an equation
  links form one class, and a class's value names the session: `roomId=r7`);
* an event's `cause` and `prior` links: it is joined to the events they name.

`group` runs a union-find over the events with both. Each group is a session with its key, count,
events and the simulated session numbers its events carry (a cross-check, never a grouping). An
event no equation and no link reaches is unattributed.

Negative requirements: an event is never in two sessions (the groups partition the attributed
events); groups merge only through an equation or a link, and when equations over different
fields merge groups the key names each field and value and `joinedBy` says which event did it; an
equation under `or` or `not` is never a join; the answer never changes an event, a check or a log.
-/

namespace LeanFM.Session.Derived
open Lean

def maxEvents : Nat := 600
def maxEquations : Nat := 64
def maxSessions : Nat := 200
/-- A key names at most this many field=value labels, and counts the rest. -/
def maxKeyLabels : Nat := 6

/-- One side of an equation: a message id and a dotted field path. -/
abbrev Side := String × String

structure Equation where
  a : Side
  b : Side
  deriving BEq, Repr

def Equation.text (e : Equation) : String := s!"{e.a.1}.{e.a.2} = {e.b.1}.{e.b.2}"

/-- The equations a condition requires: comparisons `x.f = y.g` between two paths, at its top or
under `and`. Under `or` or `not` an equation need not hold, so it is not a join. -/
def equationsOf : Where.Expr → List Equation
  | .bin "and" x y => equationsOf x ++ equationsOf y
  | .bin "=" (.path x f) (.path y g) =>
    if f.isEmpty || g.isEmpty then [] else [⟨(x, ".".intercalate f), (y, ".".intercalate g)⟩]
  | _ => []

/-- The equations of every where clause that parses, at most `maxEquations`. -/
def equations (guards : List String) : List Equation :=
  let all := guards.flatMap fun g => match Where.parse g with
    | .ok e => equationsOf e
    | .error _ => []
  (all.foldl (fun acc e => if acc.contains e then acc else acc ++ [e]) []).take maxEquations

/-- An event as far as grouping needs it. -/
structure Ev where
  id      : Nat
  msgId   : Option String
  /-- Fields flattened to dotted keys, each value as text. -/
  fields  : List (String × String)
  cause   : Option Nat
  prior   : List Nat
  session : Nat
  deriving Repr, Inhabited

/-- A JSON object's leaves as dotted keys and text values (strings unquoted). -/
partial def flatten (pre : String) (j : Json) : List (String × String) :=
  match j with
  | .obj kvs => kvs.toList.flatMap fun (k, v) => flatten (if pre.isEmpty then k else pre ++ "." ++ k) v
  | .str t => [(pre, t)]
  | .num n => [(pre, n.toString)]
  | .bool b => [(pre, toString b)]
  | _ => []

/-- An event as session_simulate writes it (id, session, msgId, cause, prior, fields). -/
def Ev.ofJson (j : Json) : Ev :=
  let nat (k : String) : Option Nat := (j.getObjValAs? Nat k).toOption
  { id := (nat "id").getD 0, msgId := (j.getObjValAs? String "msgId").toOption
    fields := match j.getObjVal? "fields" with | .ok o@(.obj _) => flatten "" o | _ => []
    cause := nat "cause"
    prior := match j.getObjVal? "prior" with
      | .ok (.arr a) => a.toList.filterMap (·.getNat?.toOption)
      | _ => []
    session := (nat "session").getD 0 }

structure Session where
  key      : String
  events   : Array Nat
  simulated : List Nat
  /-- When equations over different fields joined groups, which event did it. -/
  joinedBy : Option String
  deriving Repr, Inhabited

structure Result where
  equations    : List Equation
  sessions     : Array Session
  /-- Sessions beyond `maxSessions`, counted. -/
  omitted      : Nat
  unattributed : Array Nat
  /-- Events considered (at most `maxEvents`) and those beyond, not grouped. -/
  considered   : Nat
  beyond       : Nat
  /-- Sessions whose events are exactly those of one simulated session. -/
  matching     : Nat
  deriving Repr

/-- The root of `i`, compressing the path it walked. -/
def find (parent : Array Nat) (i : Nat) : Nat × Array Nat := Id.run do
  let mut r := i
  for _ in [0:parent.size] do
    let p := parent[r]!
    if p == r then break
    r := p
  let mut parent := parent
  let mut j := i
  for _ in [0:parent.size] do
    let p := parent[j]!
    if p == j then break
    parent := parent.set! j r
    j := p
  return (r, parent)

def union (parent : Array Nat) (a b : Nat) : Array Nat :=
  let (ra, p1) := find parent a
  let (rb, p2) := find p1 b
  if ra == rb then p2 else p2.set! (max ra rb) (min ra rb)

def pad (n : Nat) : String := "e" ++ "".pushn '0' (3 - min 3 (toString n).length) ++ toString n

/-- Group `evs` (in stream order) into sessions by the equations and the cause and prior links. -/
def group (eqs : List Equation) (input : Array Ev) : Result := Id.run do
  let evs := input.extract 0 maxEvents
  let n := evs.size
  -- equation classes over (message, field) sides
  let sides : Array Side := eqs.foldl (fun acc e =>
    let acc := if acc.contains e.a then acc else acc.push e.a
    if acc.contains e.b then acc else acc.push e.b) #[]
  let ix (s : Side) : Nat := (sides.findIdx? (· == s)).getD 0
  let mut cls := Array.range sides.size
  for e in eqs do cls := union cls (ix e.a) (ix e.b)
  let classOf (s : Side) : Nat := (find cls (ix s)).1
  -- a class's name: the distinct field names of its sides, joined by /
  let className (k : Nat) : String :=
    let names := (sides.filter (fun s => classOf s == k)).toList.map (·.2)
    "/".intercalate (names.foldl (fun acc x => if acc.contains x then acc else acc ++ [x]) [])
  let mut parent := Array.range n
  let mut first : List ((Nat × String) × Nat) := []
  let mut labels : Array (List String) := Array.replicate n []
  let mut linked : Array Bool := Array.replicate n false
  for i in [0:n] do
    let e := evs[i]!
    if let some m := e.msgId then
      for s in sides do
        if s.1 != m then continue
        let some v := e.fields.lookup s.2 | continue
        let k := classOf s
        let label := s!"{className k}={v}"
        unless labels[i]!.contains label do labels := labels.set! i (labels[i]! ++ [label])
        match first.lookup (k, v) with
        | some j => parent := union parent i j
        | none => first := ((k, v), i) :: first
    -- links name events by id (a stream may number from 1), never by position
    for ref in e.cause.toList ++ e.prior do
      let some j := evs.findIdx? (·.id == ref) | continue
      if j != i then
        parent := union parent i j
        linked := (linked.set! i true).set! j true
  let attributed (i : Nat) : Bool := !labels[i]!.isEmpty || linked[i]!
  -- roots in order of their first event
  let mut groups : Array (Nat × Array Nat) := #[]
  for i in [0:n] do
    unless attributed i do continue
    let (r, p') := find parent i
    parent := p'
    match groups.findIdx? (·.1 == r) with
    | some g => groups := groups.modify g fun (r, xs) => (r, xs.push i)
    | none => groups := groups.push (r, #[i])
  let sessionOf (xs : Array Nat) : Session :=
    let ls := xs.toList.flatMap (fun i => labels[i]!)
    let ls := ls.foldl (fun acc x => if acc.contains x then acc else acc ++ [x]) []
    let key := if ls.isEmpty then s!"chain from {pad evs[xs[0]!]!.id}"
      else ", ".intercalate (ls.take maxKeyLabels) ++ (if ls.length > maxKeyLabels then s!" (+{ls.length - maxKeyLabels} more)" else "")
    let sims := (xs.toList.map (fun i => evs[i]!.session)).foldl (fun acc s => if acc.contains s then acc else acc ++ [s]) []
    let joinedBy := if ls.length < 2 then none else
      match xs.find? (fun i => labels[i]!.length ≥ 2) with
      | some i => some s!"{pad evs[i]!.id} carries {" and ".intercalate labels[i]!}"
      | none => some "cause or prior links join them"
    { key, events := xs, simulated := sims.mergeSort, joinedBy }
  let all := groups.map (sessionOf ·.2)
  let sorted := all.qsort fun a b => a.events.size > b.events.size || (a.events.size == b.events.size && a.events[0]! < b.events[0]!)
  let attributedOf (s : Nat) : Nat := ((List.range n).filter fun i => attributed i && evs[i]!.session == s).length
  let matching := (all.filter fun g => match g.simulated with
    | [s] => attributedOf s == g.events.size
    | _ => false).size
  return { equations := eqs, sessions := sorted.extract 0 maxSessions, omitted := sorted.size - min sorted.size maxSessions, unattributed := ((Array.range n).filter fun i => !attributed i), considered := n, beyond := input.size - n, matching }

def Result.json (r : Result) : Json :=
  let beyond := r.beyond
  Json.mkObj [
    ("equations", Json.arr (r.equations.map (Json.str ·.text)).toArray),
    ("sessions", Json.arr (r.sessions.map fun s => Json.mkObj ([("key", Json.str s.key), ("count", s.events.size),
      ("events", toJson s.events), ("simulated", toJson s.simulated)] ++
      (match s.joinedBy with | some j => [("joinedBy", Json.str j)] | none => [])))),
    ("omitted", r.omitted), ("unattributed", toJson r.unattributed),
    ("considered", r.considered), ("beyond", beyond), ("matching", r.matching),
    ("reading", Json.str (s!"{r.sessions.size + r.omitted} sessions derived from {r.equations.length} where-clause equation{if r.equations.length == 1 then "" else "s"} and the cause and prior links over {r.considered} events; " ++
      s!"{r.unattributed.size} unattributed; {r.matching} match one simulated session exactly" ++
      (if beyond > 0 then s!"; {beyond} events beyond the first {maxEvents} not grouped" else "")))]

end LeanFM.Session.Derived
