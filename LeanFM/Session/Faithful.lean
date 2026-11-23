import LeanFM.Logic
import LeanFM.Session.SpecCheck

/-!
# Faithful CTL (selfhost.session.faithful)

A protocol's faithful CTL says exactly what it allows: in each typestate, each next typestate is
possible and nothing else is. The typestates are the classes of the protocol's checker model
(`Logic.buildModel`: a node is a state with its last message; an ended session stutters) under
bisimulation. Whether a candidate is faithful is decided as one bisimulation check, never by
evaluating one formula per typestate: by a lockstep walk when the typestates are deterministic, and
by one signature refinement over both models otherwise. The rules themselves are written only to be
read, with their typestate formulas shared.
-/

namespace LeanFM.Session.Faithful
open Lean LeanFM.Logic

/-- A checker model as a graph whose nodes carry their last message and whether the session may end
there. -/
structure LGraph where
  label : Array (Option String × Bool)
  succ : Array (Array Nat)
deriving Inhabited

def LGraph.size (g : LGraph) : Nat := g.label.size

def LGraph.ofModel (m : Model) : LGraph :=
  let ends : Std.HashSet String := m.task.terminals.foldl (·.insert ·) {}
  { label := m.nodes.map fun nd => (nd.message, ends.contains nd.state), succ := m.succ }

/-- Two graphs side by side; the second's nodes come after the first's. -/
def LGraph.union (g h : LGraph) : LGraph :=
  { label := g.label ++ h.label, succ := g.succ ++ h.succ.map (·.map (· + g.size)) }

def dedupSorted (a : Array Nat) : Array Nat := Id.run do
  let mut out : Array Nat := #[]
  for x in a do
    if out.back? != some x then out := out.push x
  return out

/-- Signature refinement: round 0 groups nodes by label; each later round splits a class by the set
of classes its successors reach. One pass over the steps per round, until no class splits. The
result lists the class of every node after each round; the last is bisimilarity. -/
def refine (g : LGraph) : Array (Array Nat) := Id.run do
  let mut ids : Std.HashMap (Option String × Bool) Nat := {}
  let mut p : Array Nat := #[]
  for l in g.label do
    match ids.get? l with
    | some i => p := p.push i
    | none => p := p.push ids.size; ids := ids.insert l ids.size
  let mut rounds := #[p]
  let mut count := ids.size
  for _ in [0:g.size + 1] do
    let mut sig : Std.HashMap (Nat × Array Nat) Nat := {}
    let mut q : Array Nat := Array.mkEmpty p.size
    for v in [0:p.size] do
      let key := (p[v]!, dedupSorted (((g.succ[v]!).map (p[·]!)).qsort (· < ·)))
      match sig.get? key with
      | some i => q := q.push i
      | none => q := q.push sig.size; sig := sig.insert key sig.size
    if sig.size == count then break
    count := sig.size
    p := q
    rounds := rounds.push q
  return rounds

/-- A protocol's typestates: the classes, a representative node of each, the classes that may
follow each, and the lookahead (rounds past the first). -/
structure Typestates where
  graph : LGraph
  rounds : Array (Array Nat)
  rep : Array Nat
  next : Array (Array Nat)
deriving Inhabited

def Typestates.final (t : Typestates) : Array Nat := t.rounds.back?.getD #[]
def Typestates.count (t : Typestates) : Nat := t.rep.size
def Typestates.lookahead (t : Typestates) : Nat := t.rounds.size - 1
def Typestates.labelOf (t : Typestates) (c : Nat) : Option String × Bool := t.graph.label[t.rep[c]!]!

def typestates (g : LGraph) : Typestates := Id.run do
  let rounds := refine g
  let fin := rounds.back?.getD #[]
  let k := (fin.foldl max 0) + (if fin.isEmpty then 0 else 1)
  let mut rep : Array (Option Nat) := Array.replicate k none
  for v in [0:fin.size] do
    if rep[fin[v]!]!.isNone then rep := rep.set! (fin[v]!) (some v)
  let reps := rep.map (·.getD 0)
  let next := reps.map fun v => dedupSorted (((g.succ[v]!).map (fin[·]!)).qsort (· < ·))
  return { graph := g, rounds, rep := reps, next }

/-- Deterministic: no typestate has two next typestates with the same message and ending, so the
typestate of a node follows from its predecessor's and its own label (what prev gives). -/
def Typestates.deterministic (t : Typestates) : Bool :=
  t.next.all fun ns => (ns.map t.labelOf).toList.eraseDups.length == ns.size

def labelText (l : Option String × Bool) : String :=
  (l.1.getD "(start)") ++ (if l.2 then " (may end)" else "")

/-- What a faithfulness check answers. -/
structure Verdict where
  faithful : Bool
  method : String
  /-- the messages from the start to the point where the two differ -/
  path : List String := []
  protocolNext : List String := []
  candidateNext : List String := []
  note : String := ""
deriving Inhabited

/-- The messages along parent pointers from the start to `v`. -/
def pathTo (g : LGraph) (parent : Array (Option Nat)) (v : Nat) : List String := Id.run do
  let mut out : List String := []
  let mut cur := v
  for _ in [0:g.size + 1] do
    match g.label[cur]!.1 with
    | some msg => out := msg :: out
    | none => pure ()
    match parent[cur]! with
    | some p => cur := p
    | none => break
  return out

/-- The lockstep walk: each candidate node is paired with the one typestate it must be, from the
start; one pass over the candidate's steps. Only for deterministic typestates. -/
def walk (t : Typestates) (c : LGraph) : Verdict := Id.run do
  let mut assign : Array (Option Nat) := Array.replicate c.size none
  let mut parent : Array (Option Nat) := Array.replicate c.size none
  if c.size == 0 then return { faithful := false, method := "walk", note := "the candidate has no start" }
  let start := t.final[0]!
  assign := assign.set! 0 (some start)
  let mut queue : Array Nat := #[0]
  let mut head := 0
  while head < queue.size do
    let v := queue[head]!
    head := head + 1
    let ts := assign[v]!.getD 0
    let want := (t.next[ts]!).map t.labelOf
    let got := ((c.succ[v]!).map (c.label[·]!)).toList.eraseDups
    if c.label[v]! != t.labelOf ts || !(want.toList.all got.contains && got.all want.contains) then
      return { faithful := false, method := "walk", path := pathTo c parent v,
               protocolNext := (want.map labelText).toList, candidateNext := got.map labelText,
               note := if c.label[v]! != t.labelOf ts then s!"here the protocol has {labelText (t.labelOf ts)} and the candidate {labelText c.label[v]!}" else "" }
    for w in c.succ[v]! do
      let ts' := ((t.next[ts]!).find? (fun x => t.labelOf x == c.label[w]!)).getD 0
      match assign[w]! with
      | none =>
        assign := assign.set! w (some ts')
        parent := parent.set! w (some v)
        queue := queue.push w
      | some x =>
        if x != ts' then
          return { faithful := false, method := "walk", path := pathTo c parent v ++ (c.label[w]!.1.toList),
                   note := "the candidate reaches one point by two paths that end in different typestates of the protocol" }
  return { faithful := true, method := "walk" }

/-- One refinement over both graphs, and for an unfaithful candidate the shortest path through pairs
the refinement keeps apart to a point where the next messages or the ending differ. -/
def byRefinement (spec c : LGraph) (maxPairs : Nat := 200000) : Verdict := Id.run do
  let u := spec.union c
  let fin := (refine u).back?.getD #[]
  let off := spec.size
  if c.size == 0 then return { faithful := false, method := "refinement", note := "the candidate has no start" }
  if fin[0]! == fin[off]! then return { faithful := true, method := "refinement" }
  let mut seen : Std.HashSet (Nat × Nat) := ({} : Std.HashSet (Nat × Nat)).insert (0, 0)
  let mut queue : Array (Nat × Nat) := #[(0, 0)]
  let mut parent : Std.HashMap (Nat × Nat) (Nat × Nat) := {}
  let mut head := 0
  while head < queue.size && seen.size < maxPairs do
    let (s, v) := queue[head]!
    head := head + 1
    let sl := (spec.succ[s]!).toList.map (spec.label[·]!) |>.eraseDups
    let cl := (c.succ[v]!).toList.map (c.label[·]!) |>.eraseDups
    if spec.label[s]! != c.label[v]! || !(sl.all cl.contains && cl.all sl.contains) then
      let mut msgs : List String := []
      let mut cur := (s, v)
      for _ in [0:queue.size + 1] do
        match spec.label[cur.1]!.1 with
        | some msg => msgs := msg :: msgs
        | none => pure ()
        match parent.get? cur with
        | some p => cur := p
        | none => break
      return { faithful := false, method := "refinement", path := msgs, protocolNext := sl.map labelText, candidateNext := cl.map labelText,
               note := if spec.label[s]! != c.label[v]! then s!"here the protocol has {labelText spec.label[s]!} and the candidate {labelText c.label[v]!}" else "" }
    for s' in spec.succ[s]! do
      for v' in c.succ[v]! do
        if spec.label[s']! == c.label[v']! && fin[s']! != fin[off + v']! && !seen.contains (s', v') then
          seen := seen.insert (s', v')
          parent := parent.insert (s', v') (s, v)
          queue := queue.push (s', v')
  return { faithful := false, method := "refinement",
           note := "the same next messages at every point, but different choices after them: a branch one makes early the other makes late" }

/-- Is the candidate faithful to the protocol: one walk or one refinement. -/
def compare (spec c : LGraph) : Verdict :=
  let t := typestates spec
  if t.deterministic then walk t c else byRefinement spec c

/-! ## The rules, written to be read -/

/-- The atom for a label: its message (or no message yet, at the start) and whether it may end. -/
def labelFormula (allMsgs : List String) (l : Option String × Bool) : Formula :=
  .and [ (match l.1 with
          | some msg => .after msg
          | none => .not (.or (allMsgs.map Formula.after)))
       , if l.2 then .terminal else .not .terminal ]

/-- One formula per typestate naming it: its label, and for a typestate that needs lookahead k, which
typestates of round k-1 may follow. Each round's formulas are built from the round before, so they
are shared in memory and their DAG stays small. -/
def names (t : Typestates) : Array Formula := Id.run do
  let g := t.graph
  let allMsgs := (g.label.toList.filterMap (·.1)).eraseDups
  let r0 := t.rounds[0]!
  let mut by0 : Std.HashMap Nat Formula := {}
  for v in [0:g.size] do
    if !by0.contains r0[v]! then by0 := by0.insert (r0[v]!) (labelFormula allMsgs g.label[v]!)
  let mut cur := by0
  for k in [1:t.rounds.size] do
    let rk := t.rounds[k]!
    let prev := t.rounds[k-1]!
    let mut nxt : Std.HashMap Nat Formula := {}
    for v in [0:g.size] do
      if !nxt.contains rk[v]! then
        let cs := dedupSorted (((g.succ[v]!).map (prev[·]!)).qsort (· < ·))
        let fs := cs.toList.map (cur.getD · .tt)
        nxt := nxt.insert (rk[v]!) (.and ([by0.getD (r0[v]!) .tt] ++ fs.map .ex ++ [.ax (.or fs)]))
    cur := nxt
  let fin := t.final
  return t.rep.map fun v => cur.getD (fin[v]!) .tt

/-- The start rule and one rule per typestate: AG (typestate -> EX each next and AX one of them). -/
def rules (t : Typestates) : List (String × Formula) :=
  let ns := names t
  ("start", ns[t.final[0]!]!) :: (List.range t.count).map fun c =>
    let nexts := (t.next[c]!).toList.map (ns[·]!)
    (s!"typestate {c}: {labelText (t.labelOf c)}", .ag (.implies ns[c]! (.and (nexts.map .ex ++ [.ax (.or nexts)]))))

/-- The checker model of a draft (the logic tools' inline task form). -/
def modelOfDraft (draft : Json) (b : Bounds := LeanFM.Session.sessionBounds) : Except String LGraph := do
  let t ← parseDraft draft b
  match buildModel t b with
  | some m => return LGraph.ofModel m
  | none => throw s!"the model exceeds {b.maxModelNodes} nodes; nothing was decided"

end LeanFM.Session.Faithful
