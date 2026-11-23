import Lean.Data.Json
import Std.Data.HashMap

/-!
# Layered layout of a state machine (selfhost.session.layout)

A role's state machine laid out on the server, the way Graphviz dot lays out the book's typestate
graphs, so every MCP host draws the same picture with no layout engine of its own:

1. cycles: a depth-first search from the start sets aside the edges that close a cycle (back edges);
2. columns: every other edge goes from a column to a later one, a state's column being its longest
   forward path from the start;
3. long edges: an edge spanning several columns passes through a point in each;
4. order: barycentre sweeps (down by predecessors, up by successors) reorder each column, and an
   order is kept only when it has fewer crossings;
5. rows: each column is placed as close as possible to its neighbours' rows while keeping its boxes
   apart: the least-squares placement under minimum gaps, found by pooling adjacent violators;
6. routes: an edge runs from its source's right side through its points to its target's left side; a
   back edge runs the other way.

Everything is deterministic and bounded: at most `maxStates` states, a fixed number of sweeps.
-/

namespace LeanFM.Session.Layout
open Lean

def maxStates : Nat := 400
def sweeps : Nat := 12
def charW : Float := 7.0
def boxH : Float := 28.0
def padX : Float := 22.0
def gapCol : Float := 56.0
def gapRow : Float := 16.0
def gapDummy : Float := 8.0
def margin : Float := 16.0

structure Edge where
  src : Nat
  dst : Nat
  deriving Repr, BEq, Inhabited

structure Box where
  x : Float
  y : Float
  w : Float
  h : Float
  deriving Repr, Inhabited

structure Result where
  boxes : Array Box
  routes : Array (Array (Float × Float))
  back : Array Bool
  self : Array Bool
  width : Float
  height : Float
  deriving Repr

/-- The edges that close a cycle, by an iterative depth-first search from `start`, then from every
state not yet reached, in order. -/
def backEdges (n : Nat) (es : Array Edge) (start : Nat) : Array Bool := Id.run do
  let mut outs : Array (Array Nat) := Array.replicate n #[]
  for i in [0:es.size] do
    let e := es[i]!
    if e.src < n && e.dst < n && e.src != e.dst then outs := outs.modify e.src (·.push i)
  -- 0 unvisited, 1 on the stack, 2 done
  let mut color : Array Nat := Array.replicate n 0
  let mut back : Array Bool := Array.replicate es.size false
  let roots := #[start] ++ (Array.range n)
  for r in roots do
    if r < n && color[r]! == 0 then
      color := color.set! r 1
      let mut stack : Array (Nat × Nat) := #[(r, 0)]
      while !stack.isEmpty do
        let (v, k) := stack.back!
        if k < outs[v]!.size then
          stack := stack.pop.push (v, k + 1)
          let ei := outs[v]![k]!
          let w := es[ei]!.dst
          if color[w]! == 1 then back := back.set! ei true
          else if color[w]! == 0 then
            color := color.set! w 1
            stack := stack.push (w, 0)
        else
          color := color.set! v 2
          stack := stack.pop
  return back

/-- Each state's column: its longest forward path from a state with no forward edge into it. -/
def columns (n : Nat) (es : Array Edge) (back : Array Bool) : Array Nat := Id.run do
  let mut indeg : Array Nat := Array.replicate n 0
  let mut outs : Array (Array Nat) := Array.replicate n #[]
  for i in [0:es.size] do
    let e := es[i]!
    if e.src != e.dst && !back[i]! then
      indeg := indeg.modify e.dst (· + 1)
      outs := outs.modify e.src (·.push e.dst)
  let mut rank : Array Nat := Array.replicate n 0
  let mut queue : Array Nat := (Array.range n).filter (indeg[·]! == 0)
  let mut qi := 0
  while qi < queue.size do
    let v := queue[qi]!
    qi := qi + 1
    for w in outs[v]! do
      rank := rank.set! w (max rank[w]! (rank[v]! + 1))
      indeg := indeg.modify w (· - 1)
      if indeg[w]! == 0 then queue := queue.push w
  return rank

/-- Crossings between two adjacent columns, given each column's order. -/
def crossings (pos : Array Nat) (pairs : Array (Nat × Nat)) : Nat := Id.run do
  let mut c := 0
  for i in [0:pairs.size] do
    for j in [i+1:pairs.size] do
      let (a, b) := pairs[i]!
      let (p, q) := pairs[j]!
      let (pa, pb, pp, pq) := (pos[a]!, pos[b]!, pos[p]!, pos[q]!)
      if (pa < pp && pb > pq) || (pa > pp && pb < pq) then c := c + 1
  return c

/-- The least-squares rows under minimum gaps: minimise the squared distance of each `y` to its
`want`, keeping `y[i+1] - y[i] ≥ gap[i]` (pool adjacent violators over the shifted problem). -/
def placeRows (want : Array Float) (gap : Array Float) : Array Float := Id.run do
  let n := want.size
  if n == 0 then return #[]
  let mut off : Array Float := #[0.0]
  for i in [1:n] do off := off.push (off[i-1]! + gap[i-1]!)
  -- blocks of (mean, count)
  let mut blocks : Array (Float × Nat) := #[]
  for i in [0:n] do
    blocks := blocks.push (want[i]! - off[i]!, 1)
    let mut go := true
    while go && blocks.size ≥ 2 do
      let (m2, c2) := blocks.back!
      let (m1, c1) := blocks[blocks.size - 2]!
      if m1 > m2 then
        let c := c1 + c2
        let m := (m1 * c1.toFloat + m2 * c2.toFloat) / c.toFloat
        blocks := (blocks.pop.pop).push (m, c)
      else go := false
  let mut out : Array Float := #[]
  for (m, c) in blocks do
    for _ in [0:c] do
      out := out.push (m + off[out.size]!)
  return out

/-- Lay out `n` states with labels `labels` and the given edges, from `start`. -/
def layout (labels : Array String) (es : Array Edge) (start : Nat) : Result := Id.run do
  let n := labels.size
  let back := backEdges n es start
  let rank := columns n es back
  -- the graph with points on long edges: real states 0..n-1, points after them
  let mut col : Array Nat := rank
  let mut chains : Array (Array Nat) := Array.replicate es.size #[]
  let mut vedges : Array (Nat × Nat) := #[]
  for i in [0:es.size] do
    let e := es[i]!
    if e.src == e.dst || e.src ≥ n || e.dst ≥ n then continue
    let (a, b) := if back[i]! then (e.dst, e.src) else (e.src, e.dst)
    let (ra, rb) := (rank[a]!, rank[b]!)
    if rb ≤ ra then continue
    let mut prev := a
    let mut chain : Array Nat := #[]
    for r in [ra+1:rb] do
      let d := col.size
      col := col.push r
      chain := chain.push d
      vedges := vedges.push (prev, d)
      prev := d
    vedges := vedges.push (prev, b)
    chains := chains.set! i (if back[i]! then chain.reverse else chain)
  let total := col.size
  let ncols := (col.foldl max 0) + 1
  -- first order: breadth first from the start, then the rest in order
  let mut succ : Array (Array Nat) := Array.replicate total #[]
  let mut pred : Array (Array Nat) := Array.replicate total #[]
  for (a, b) in vedges do
    succ := succ.modify a (·.push b)
    pred := pred.modify b (·.push a)
  let mut seen : Array Bool := Array.replicate total false
  let mut order : Array Nat := #[]
  for r in #[start] ++ Array.range total do
    if r < total && !seen[r]! then
      seen := seen.set! r true
      order := order.push r
      let mut qi := order.size - 1
      while qi < order.size do
        let v := order[qi]!
        qi := qi + 1
        for w in succ[v]! do
          if !seen[w]! then
            seen := seen.set! w true
            order := order.push w
  let mut layers : Array (Array Nat) := Array.replicate ncols #[]
  for v in order do layers := layers.modify col[v]! (·.push v)
  let posOf := fun (ls : Array (Array Nat)) => Id.run do
    let mut p : Array Nat := Array.replicate total 0
    for l in ls do
      for i in [0:l.size] do p := p.set! l[i]! i
    return p
  let pairsBetween := fun (r : Nat) => vedges.filter fun (a, _) => col[a]! == r
  let countAll := fun (ls : Array (Array Nat)) =>
    let p := posOf ls
    (List.range ncols).foldl (fun acc r => acc + crossings p (pairsBetween r)) 0
  let mut best := layers
  let mut bestC := countAll layers
  for it in [0:sweeps] do
    let down := it % 2 == 0
    let rs : List Nat := if down then (List.range ncols).drop 1 else ((List.range ncols).reverse.drop 1)
    for r in rs do
      let p := posOf layers
      let l := layers[r]!
      let keyed := (Array.range l.size).map fun i =>
        let v := l[i]!
        let ns := if down then pred[v]! else succ[v]!
        let k := if ns.isEmpty then i.toFloat else (ns.foldl (fun s u => s + (p[u]!).toFloat) 0.0) / ns.size.toFloat
        (k, i, v)
      let sorted := keyed.qsort fun (k1, i1, _) (k2, i2, _) => k1 < k2 || (k1 == k2 && i1 < i2)
      layers := layers.set! r (sorted.map (·.2.2))
    let c := countAll layers
    if c < bestC then
      best := layers
      bestC := c
  layers := best
  -- columns: each as wide as its widest box
  let width := fun (v : Nat) => if v < n then labels[v]!.length.toFloat * charW + 2 * padX else 0.0
  let height := fun (v : Nat) => if v < n then boxH else 0.0
  let mut colX : Array Float := #[]
  let mut x := margin
  for r in [0:ncols] do
    let w := layers[r]!.foldl (fun m v => max m (width v)) 0.0
    colX := colX.push (x + w / 2)
    x := x + w + gapCol
  -- rows: start stacked, then pulled towards their neighbours in alternating sweeps
  let gapOf := fun (a b : Nat) => (height a + height b) / 2 + (if a < n && b < n then gapRow else gapDummy)
  let mut y : Array Float := Array.replicate total 0.0
  for l in layers do
    for i in [1:l.size] do
      y := y.set! l[i]! (y[l[i-1]!]! + gapOf l[i-1]! l[i]!)
  for it in [0:2 * sweeps] do
    let down := it % 2 == 0
    let rs : List Nat := if down then (List.range ncols).drop 1 else ((List.range ncols).reverse.drop 1)
    for r in rs do
      let l := layers[r]!
      if l.isEmpty then continue
      let want := l.map fun v =>
        let ns := if down then pred[v]! else succ[v]!
        if ns.isEmpty then y[v]! else (ns.foldl (fun s u => s + y[u]!) 0.0) / ns.size.toFloat
      let gaps := (Array.range (l.size - 1)).map fun i => gapOf l[i]! l[i+1]!
      let placed := placeRows want gaps
      for i in [0:l.size] do y := y.set! l[i]! placed[i]!
  -- normalise: the topmost box edge at the margin
  let top := (Array.range total).foldl (fun m v => min m (y[v]! - height v / 2)) 1.0e18
  let shift := if total == 0 then 0.0 else margin - top
  let boxes := (Array.range n).map fun v => { x := colX[col[v]!]!, y := y[v]! + shift, w := width v, h := boxH : Box }
  let pt := fun (v : Nat) => (colX[col[v]!]!, y[v]! + shift)
  let routes := (Array.range es.size).map fun i => Id.run do
    let e := es[i]!
    if e.src == e.dst || e.src ≥ n || e.dst ≥ n then return #[]
    let (sx, sy) := pt e.src
    let (tx, ty) := pt e.dst
    let mids := chains[i]!.map pt
    if back[i]! then
      return #[(sx - width e.src / 2, sy)] ++ mids ++ #[(tx + width e.dst / 2, ty)]
    else
      return #[(sx + width e.src / 2, sy)] ++ mids ++ #[(tx - width e.dst / 2, ty)]
  let bottom := (Array.range total).foldl (fun m v => max m (y[v]! + shift + height v / 2)) 0.0
  return { boxes, routes, back, self := es.map (fun e => e.src == e.dst), width := x - gapCol + margin, height := bottom + margin }

/-- A state's name in the drawing (selfhost.session.layout): what just happened. The start is
"start" and End is "end"; a state reached by one labelled message or event is named by it, by two
by both, by none or more by its own name. A message edge's label is "send L to R" or "receive L
from R", named "L → R" and "L ← R". -/
def stateLabel (state start : String) (incoming : List (String × String)) : String :=
  if state == start then "start" else if state == "End" then "end" else
  let named := (incoming.filterMap fun (kind, label) =>
    match kind with
    | "send" => match (label.drop 5).toString.splitOn " to " with
      | [l, r] => some s!"{l} → {r}" | _ => some label
    | "receive" => match (label.drop 8).toString.splitOn " from " with
      | [l, r] => some s!"{l} ← {r}" | _ => some label
    | "event" => some label
    | _ => none).eraseDups
  match named with
  | [a] => a
  | [a, b] => s!"{a} | {b}"
  | _ => state

def r1 (f : Float) : Json := toJson ((f * 10).round / 10)

/-- The layout of a state machine as session_explore answers it: each state's label and box, and
each edge's route in the order of `edges`. More than `maxStates` states get none. -/
def machineJson (states : List String) (start : String) (finals : List String)
    (edges : List (String × String × String × String)) : Option Json := Id.run do
  if states.length > maxStates || states.isEmpty then return none
  let idx : Std.HashMap String Nat := (states.zipIdx).foldl (fun m (s, i) => m.insert s i) {}
  let some s0 := idx.get? start | return none
  let es := (edges.filterMap fun (a, b, _, _) => match idx.get? a, idx.get? b with
    | some i, some j => some { src := i, dst := j : Edge } | _, _ => none).toArray
  if es.size != edges.length then return none
  let labels := states.toArray.map fun s =>
    stateLabel s start (edges.filterMap fun (_, b, label, kind) => if b == s then some (kind, label) else none)
  let r := layout labels es s0
  let nodes := (Array.range states.length).map fun i =>
    let b := r.boxes[i]!
    Json.mkObj [("id", Json.str states[i]!), ("label", Json.str labels[i]!), ("x", r1 b.x), ("y", r1 b.y),
      ("w", r1 b.w), ("h", r1 b.h), ("ends", Json.bool (finals.contains states[i]!))]
  let routes := (Array.range es.size).map fun i =>
    Json.mkObj [("points", Json.arr (r.routes[i]!.map fun (x, y) => Json.arr #[r1 x, r1 y])),
      ("back", Json.bool r.back[i]!), ("self", Json.bool r.self[i]!)]
  return some (Json.mkObj [("width", r1 r.width), ("height", r1 r.height), ("nodes", Json.arr nodes), ("edges", Json.arr routes)])

end LeanFM.Session.Layout
