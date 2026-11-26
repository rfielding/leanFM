import Lean.Data.Json
import LeanFM.Session.Global

/-! The protocol as a tree to browse (clause selfhost.session.explorer): the main protocol's
structure (included protocols, choices, parallel branches, loops, independent sessions, messages and
events), every protocol the text defines, and the roles, each node with the lines of the text it
comes from. The view lists the tree like a file explorer, folded at the start, and shows a node's source and,
on request, LeanFM's diagram of a protocol or a role.

Only LeanFM computes the tree and the line ranges; the view lays them out and shows the text lines it
was given. -/

namespace LeanFM.Session.Outline
open Lean

/-- Nodes in one answer; a larger tree is cut and the answer says how many were left out. -/
def maxNodes : Nat := 1500

/-- A protocol definition: its name and its first and last line (1-based, inclusive). -/
structure Def where
  name : String
  first : Nat
  last : Nat
  deriving Repr, BEq, Inhabited

/-- The name after `protocol` on a line that starts a definition. -/
def defName? (line : String) : Option String :=
  let t := line.trimAscii.toString
  if !t.startsWith "protocol " then none else
  let rest := (t.drop 9).toString.trimAscii.toString
  let name := String.ofList (rest.toList.takeWhile fun c => c.isAlphanum || c == '_' || c == '.')
  if name.isEmpty then none else some name

/-- Braces opened minus closed on a line, outside string literals and comments, and whether it
opened any; `inBlock` says whether the line starts inside a `/- ... -/` comment, and the result
says whether it ends in one. -/
def braces (line : String) (inBlock : Bool) : Int × Bool × Bool := Id.run do
  let cs := line.toList.toArray
  let mut d : Int := 0
  let mut opened := false
  let mut block := inBlock
  let mut str := false
  let mut i := 0
  while i < cs.size do
    let c := cs[i]!
    let n := cs[i + 1]?.getD ' '
    if block then
      if c == '-' && n == '/' then block := false; i := i + 2 else i := i + 1
    else if str then
      if c == '\\' then i := i + 2
      else
        if c == '"' then str := false
        i := i + 1
    else if c == '-' && n == '-' then break
    else if c == '/' && n == '-' then block := true; i := i + 2
    else
      if c == '"' then str := true
      else if c == '{' then d := d + 1; opened := true
      else if c == '}' then d := d - 1
      i := i + 1
  return (d, opened, block)

/-- Every protocol definition in the text with its lines: from the `protocol` line to the line where
its braces, having opened, come back to the depth it started at. A later definition of a name (a
newer version) replaces an earlier one, as a plain reference means the newest. -/
def defs (text : String) : List Def := Id.run do
  let lines := (text.splitOn "\n").toArray
  let mut out : List Def := []
  let mut block := false
  let mut cur : Option (String × Nat × Int × Bool) := none
  let mut depth : Int := 0
  for i in [0:lines.size] do
    let line := lines[i]!
    if cur.isNone && !block then
      if let some n := defName? line then cur := some (n, i + 1, depth, false)
    let (d, sawOpen, b) := braces line block
    block := b
    depth := depth + d
    if let some (n, first, start, opened) := cur then
      let opened := opened || sawOpen
      if opened && depth <= start then
        out := (out.filter (·.name != n)) ++ [{ name := n, first, last := i + 1 }]
        cur := none
      else cur := some (n, first, start, opened)
  return out

/-- The first line in `[first, last]` that contains `needle`, if any. -/
def lineOf (lines : Array String) (first last : Nat) (needle : String) : Option Nat := Id.run do
  for i in [first:last + 1] do
    if let some l := lines[i - 1]? then
      if (l.splitOn needle).length > 1 then return some i
  return none

/-- A node of the tree. -/
structure Node where
  id : Nat
  parent : Option Nat
  /-- protocol, definitions, definition, include, choice, branch, parallel, join, rec, continue,
  sessions, message, event, roles, role -/
  kind : String
  label : String
  detail : String := ""
  /-- the definition the node's text is in -/
  protocol : String := ""
  first : Option Nat := none
  last : Option Nat := none
  /-- for a message node, its label alone, to ask for its payload -/
  message : String := ""
  deriving Repr, Inhabited

structure St where
  nodes : Array Node := #[]
  omitted : Nat := 0

abbrev M := StateM St

def add (n : Node) : M (Option Nat) := do
  let s ← get
  if s.nodes.size ≥ maxNodes then
    set { s with omitted := s.omitted + 1 }
    return none
  let id := s.nodes.size
  set { s with nodes := s.nodes.push { n with id } }
  return some id

/-- The nodes of a global type under `parent`, in order, with the lines they come from in `inDef`. -/
partial def walk (ds : List Def) (lines : Array String) (parent : Nat) (inDef : String) : Global String → M Unit
  | .done => pure ()
  | .msg i k => do
    let d := (ds.find? (·.name == inDef))
    let line := d.bind fun d => lineOf lines d.first d.last s!"{i.label} from"
    let detail := ([i.route.map (s!"route " ++ ·), i.status.map (s!"status " ++ toString ·), i.cause.map (s!"cause " ++ ·)].filterMap id) |> ", ".intercalate
    let _ ← add { id := 0, parent := some parent, kind := "message", label := s!"{i.label}: {i.src} -> {i.dst}", detail,
                  protocol := inDef, first := line, last := line, message := i.label }
    walk ds lines parent inDef k
  | .act r l k => do
    let d := (ds.find? (·.name == inDef))
    let line := d.bind fun d => lineOf lines d.first d.last s!"{l} at"
    let _ ← add { id := 0, parent := some parent, kind := "event", label := s!"{l} at {r}", protocol := inDef, first := line, last := line }
    walk ds lines parent inDef k
  | .choice bs => do
    -- the role that decides, as the diagram's alt frame names it
    let who := match Global.decider bs with | .ok r => s!"{r} decides: " | .error _ => ""
    let some c ← add { id := 0, parent := some parent, kind := "choice", label := s!"{who}choice of {bs.length}", protocol := inDef } | pure ()
    for (b, j) in bs.zipIdx do
      let some bn ← add { id := 0, parent := some c, kind := "branch", label := s!"branch {j + 1}", protocol := inDef } | pure ()
      walk ds lines bn inDef b
  | .par bs k => do
    if let some c ← add { id := 0, parent := some parent, kind := "par", label := s!"in parallel: {bs.length} branches", protocol := inDef } then
      for (b, j) in bs.zipIdx do
        if let some bn ← add { id := 0, parent := some c, kind := "branch", label := s!"branch {j + 1}", protocol := inDef } then
          walk ds lines bn inDef b
    walk ds lines parent inDef k
  | .join n bs k => do
    if let some c ← add { id := 0, parent := some parent, kind := "join", label := s!"first {n} of {bs.length} branches", protocol := inDef } then
      for (b, j) in bs.zipIdx do
        if let some bn ← add { id := 0, parent := some c, kind := "branch", label := s!"branch {j + 1}", protocol := inDef } then
          walk ds lines bn inDef b
    walk ds lines parent inDef k
  | .loop n b => do
    let d := (ds.find? (·.name == inDef))
    let line := d.bind fun d => lineOf lines d.first d.last s!"loop {n}"
    let some c ← add { id := 0, parent := some parent, kind := "rec", label := s!"loop {n}", protocol := inDef, first := line, last := line } | pure ()
    walk ds lines c inDef b
  | .var n => do
    let _ ← add { id := 0, parent := some parent, kind := "continue", label := s!"continue {n}", protocol := inDef }
  | .sessions b k => do
    if let some c ← add { id := 0, parent := some parent, kind := "sessions", label := "sessions: any number at once", protocol := inDef } then
      walk ds lines c inDef b
    walk ds lines parent inDef k
  | .box bn b k => match Global.groupOf? bn with
   | some g => do
    -- a group (selfhost.session.group): a node in its own protocol, its steps under it
    let d := (ds.find? (·.name == inDef))
    let line := d.bind fun d => lineOf lines d.first d.last s!"group {g}"
    if let some c ← add { id := 0, parent := some parent, kind := "group", label := s!"group {g}", protocol := inDef, first := line, last := line } then
      walk ds lines c inDef b
    walk ds lines parent inDef k
   | none => do
    -- an included protocol: its own definition's lines, and its steps under it; the box's name
    -- carries the include's bindings (Order with token), the protocol is its first word
    let n := Global.boxProtocol bn
    let d := ds.find? (·.name == n)
    if let some c ← add { id := 0, parent := some parent, kind := "include", label := s!"include {bn}", protocol := n,
                          first := d.map (·.first), last := d.map (·.last) } then
      walk ds lines c n b
    walk ds lines parent inDef k

/-- The body of the first box named `n` in `g`: what `include n` put there. -/
partial def findBox (n : String) : Global String → Option (Global String)
  | .done => none
  | .var _ => none
  | .msg _ k => findBox n k
  | .act _ _ k => findBox n k
  | .choice bs => bs.findSome? (findBox n)
  | .par bs k => (bs.findSome? (findBox n)).orElse fun _ => findBox n k
  | .join _ bs k => (bs.findSome? (findBox n)).orElse fun _ => findBox n k
  | .loop _ b => findBox n b
  | .sessions b k => (findBox n b).orElse fun _ => findBox n k
  | .box m b k => if m == n || Global.boxProtocol m == n then some b else (findBox n b).orElse fun _ => findBox n k

/-- The whole tree: the main protocol (its structure), every protocol the text defines, and the
roles with their typestate. `typestates` gives each role's typestate text or why it has none. -/
def tree (text : String) (main : String) (g : Global String) (typestates : List (String × String)) : Array Node × Nat × List Def :=
  let ds := defs text
  let lines := (text.splitOn "\n").toArray
  let m : M Unit := do
    let d := ds.find? (·.name == main)
    let some root ← add { id := 0, parent := none, kind := "protocol", label := main, detail := "the main protocol",
                          protocol := main, first := d.map (·.first), last := d.map (·.last) } | pure ()
    walk ds lines root main g
    if let some rs ← add { id := 0, parent := some root, kind := "roles", label := s!"roles: {typestates.length}", protocol := main } then
      for (r, ts) in typestates do
        let _ ← add { id := 0, parent := some rs, kind := "role", label := r, detail := ts, protocol := main }
    if let some dn ← add { id := 0, parent := some root, kind := "definitions", label := s!"protocols defined: {ds.length}", protocol := main } then
      for x in ds do
        -- a defined protocol opens to its own steps, as an include of it does; one the main
        -- protocol never includes (the main one itself, or one unused) stays a leaf
        if let some dnode ← add { id := 0, parent := some dn, kind := "definition", label := x.name, protocol := x.name, first := some x.first, last := some x.last } then
          if let some b := findBox x.name g then walk ds lines dnode x.name b
  let ((), s) := m.run {}
  (s.nodes, s.omitted, ds)

def nodeJson (n : Node) : Json :=
  Json.mkObj ([("id", toJson n.id), ("kind", Json.str n.kind), ("label", Json.str n.label)] ++
    (match n.parent with | some p => [("parent", toJson p)] | none => []) ++
    (if n.detail.isEmpty then [] else [("detail", Json.str n.detail)]) ++
    (if n.protocol.isEmpty then [] else [("protocol", Json.str n.protocol)]) ++
    (match n.first with | some f => [("first", toJson f)] | none => []) ++
    (match n.last with | some l => [("last", toJson l)] | none => []) ++
    (if n.message.isEmpty then [] else [("message", Json.str n.message)]))

end LeanFM.Session.Outline
