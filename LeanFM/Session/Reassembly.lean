import Lean.Data.Json
import Std.Data.HashMap
import Std.Data.HashSet

/-!
# Stream reassembly, as an evasion search

A defender that scans a TCP stream for a signature must put the stream back together the way the
host behind it will, or the two see different bytes. The attacker controls segmentation: it may send
any byte range of the stream, in any order, and send the same range again with different bytes.
When two segments overlap, a reassembler keeps the bytes it saw first or the bytes it saw last, and
operating systems differ in exactly this.

The model is symbolic in the bytes that matter: each position of the stream holds nothing yet, the
signature's own byte there, or some other byte. A segment is an offset and a run of such bytes. The
defender (`box`) and the host each apply every segment with their own overlap policy. A blocking
defender (an IPS) resets the stream the moment its own copy holds the signature, so nothing after
that reaches the host; a passive one (an IDS) only raises an alert. Two claims mark what happened on
a path: `alerted(sig)` when the defender's copy first holds the signature, `delivered(sig)` when the
host's does. An evasion is a path to `delivered` without `alerted`.

Once the host's copy holds the signature the application has read it, and once a blocking defender
has matched the stream is reset, so both end a path. Segments are unbounded in number but the state
is finite (three values per position, twice, and two
flags), so the search is complete for the declared signature length.
-/

namespace LeanFM.Session.Reassembly
open Lean

inductive Policy where
  /-- keep the bytes already there (the old data wins an overlap) -/
  | first
  /-- take the new bytes (the new data wins an overlap) -/
  | last
  deriving DecidableEq, Repr, Inhabited

def Policy.name : Policy → String
  | .first => "first"
  | .last => "last"

inductive Cell where
  | empty
  /-- the signature's own byte at this position -/
  | right
  /-- any other byte -/
  | wrong
  deriving DecidableEq, Repr, Inhabited, Hashable

structure Config where
  signature : String
  box : Policy := .first
  host : Policy := .last
  /-- an IPS resets the stream on a match; an IDS only alerts -/
  blocking : Bool := true
  deriving Repr, Inhabited

structure State where
  box : List Cell
  host : List Cell
  alerted : Bool := false
  delivered : Bool := false
  deriving DecidableEq, Repr, Inhabited, Hashable

/-- A segment: where it starts, and for each byte whether it is the signature's byte there. -/
abbrev Segment := Nat × List Bool

def Config.length (c : Config) : Nat := c.signature.length

/-- Every segment of the stream: every offset, every length, every choice of right or wrong bytes. -/
def Config.segments (c : Config) : List Segment :=
  let n := c.length
  (List.range n).flatMap fun off =>
    (List.range (n - off)).flatMap fun len =>
      let rec bits : Nat → List (List Bool)
        | 0 => [[]]
        | k + 1 => (bits k).flatMap fun bs => [true :: bs, false :: bs]
      (bits (len + 1)).map fun bs => (off, bs)

def Config.text (c : Config) (seg : Segment) : String :=
  let sig := c.signature.toList
  String.ofList ((seg.2.zipIdx).map fun (ok, i) => if ok then sig.getD (seg.1 + i) '?' else '.')

def apply (policy : Policy) (buf : List Cell) (seg : Segment) : List Cell :=
  buf.zipIdx.map fun (cell, i) =>
    if seg.1 ≤ i && i < seg.1 + seg.2.length then
      let byte := if seg.2.getD (i - seg.1) false then Cell.right else Cell.wrong
      match policy, cell with
      | .first, .empty => byte
      | .first, _ => cell
      | .last, _ => byte
    else cell

def whole (buf : List Cell) : Bool := buf.all (· == .right)

def Config.alertClaim (c : Config) : String := s!"alerted({c.signature})"
def Config.deliverClaim (c : Config) : String := s!"delivered({c.signature})"

/-- One segment through the defender, then (unless it reset the stream) the host; the claims it made. -/
def Config.step (c : Config) (s : State) (seg : Segment) : Option (State × List String) :=
  -- a reset stream carries nothing more, and a delivered one has been read by the application
  if (c.blocking && s.alerted) || s.delivered then none
  else
    let box := apply c.box s.box seg
    let alerted := s.alerted || whole box
    let host := if c.blocking && alerted then s.host else apply c.host s.host seg
    let delivered := s.delivered || whole host
    let claims := (if alerted && !s.alerted then [c.alertClaim] else []) ++
      (if delivered && !s.delivered then [c.deliverClaim] else [])
    some ({ box, host, alerted, delivered }, claims)

structure Model where
  states : Array State
  /-- one edge per pair of states, labelled by the first segment found for it -/
  edges : List (Nat × Nat × Segment × List String)
  truncated : Bool := false

def Config.explore (c : Config) (limit : Nat := 4096) : Model := Id.run do
  let n := c.length
  let init : State := { box := List.replicate n .empty, host := List.replicate n .empty }
  let segs := c.segments
  let mut states : Array State := #[init]
  let mut index : Std.HashMap State Nat := ({} : Std.HashMap State Nat).insert init 0
  let mut edges : Array (Nat × Nat × Segment × List String) := #[]
  let mut seen : Std.HashSet (Nat × Nat) := {}
  let mut truncated := false
  let mut i := 0
  while i < states.size do
    for seg in segs do
      match c.step states[i]! seg with
      | none => pure ()
      | some (t, claims) =>
        let j? := match index[t]? with
          | some j => some j
          | none => if states.size < limit then some states.size else none
        match j? with
        | none => truncated := true
        | some j =>
          if j == states.size then
            states := states.push t
            index := index.insert t j
          if j != i && !seen.contains (i, j) then
            seen := seen.insert (i, j)
            edges := edges.push (i, j, seg, claims)
    i := i + 1
  return { states, edges := edges.toList, truncated }

/-- The model as a `check_ctl` draft. A segment that makes two claims at once (a passive defender
and the host completing on the same segment) is drawn as two transitions through a midpoint. Both
claims are also declared on an unreachable state, so a formula may name one that never happens. -/
def Config.draft (c : Config) (m : Model) : Json := Id.run do
  let name := fun (i : Nat) => s!"s{i}"
  let mut states : Array String := (List.range m.states.size).toArray.map name
  let mut trs : Array Json := #[]
  for (e, k) in m.edges.zipIdx do
    let (a, b, seg, claims) := e
    let label := s!"segment @{seg.1}: {c.text seg}"
    match claims with
    | [c1, c2] =>
      let mid := s!"m{k}"
      states := states.push mid
      trs := trs.push (Json.mkObj [("src", Json.str (name a)), ("dst", Json.str mid), ("message", Json.str label), ("claim", Json.str c1)])
      trs := trs.push (Json.mkObj [("src", Json.str mid), ("dst", Json.str (name b)), ("message", Json.str s!"{label} (host)"), ("claim", Json.str c2)])
    | _ =>
      trs := trs.push (Json.mkObj ([("src", Json.str (name a)), ("dst", Json.str (name b)), ("message", Json.str label)] ++
        (match claims with | [c1] => [("claim", Json.str c1)] | _ => [])))
  states := states.push "declared"
  for cl in [c.alertClaim, c.deliverClaim] do
    trs := trs.push (Json.mkObj [("src", "declared"), ("dst", "declared"), ("message", Json.str s!"possible {cl}"), ("claim", Json.str cl)])
  let outs := m.edges.map (·.1)
  let terminals := (List.range m.states.size).filter (fun i => !outs.contains i)
  return Json.mkObj
    [ ("id", Json.str s!"reassembly-{c.box.name}-{c.host.name}")
    , ("states", Json.arr (states.map Json.str))
    , ("initial", "s0")
    , ("terminals", Json.arr (terminals.map (Json.str ∘ name)).toArray)
    , ("transitions", Json.arr trs) ]

/-- The default question: in blocking mode, the host never gets the signature; in passive mode,
it never gets it without an alert. -/
def Config.defaultFormula (c : Config) : Json :=
  if c.blocking then Json.mkObj [("never", Json.mkObj [("claimed", Json.str c.deliverClaim)])]
  else Json.mkObj [("never", Json.mkObj [("and", Json.arr #[
    Json.mkObj [("claimed", Json.str c.deliverClaim)],
    Json.mkObj [("not", Json.mkObj [("claimed", Json.str c.alertClaim)])]])])]

end LeanFM.Session.Reassembly
