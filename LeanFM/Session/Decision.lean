import LeanFM.Session.Generative
import LeanFM.Session.Diagram
import LeanFM.Artifacts

/-! Native MCP decision views. Requirement: selfhost.session.mdp.
Prefix identity preserves history and timing; all mass is exact, never normalized.
No user code, IO or markup evaluation. -/
namespace LeanFM.Session.Decision
open Lean LeanFM.Overlay Generative

def output := LeanFM.LLMGenerated.SelfHosting.sessionMdpOutput

structure Step where
  key : String
  kind : String
  label : String
  detail : String := ""
  weight : Q := Q.one
  timeMs : Nat := 0
  obligations : List Json := []
  deriving Inhabited

structure Node extends Step where
  id : Nat
  parent : Option Nat
  depth : Nat
  mass : Q
  deriving Inhabited

def clockText (ms : Nat) : String :=
  if ms > 0 && ms % 86400000 == 0 then s!"day {ms / 86400000}"
  else s!"{ms} ms"

def eventKey (e : Event String) : String :=
  (Json.mkObj [("label", e.label), ("src", e.src), ("dst", e.dst), ("time", e.time),
    ("id", e.id), ("msgId", toJson e.msgId), ("cause", toJson e.cause),
    ("prior", toJson e.prior), ("route", toJson e.route), ("status", toJson e.status),
    ("act", e.isAct)]).compress

def steps (p : Path) (s : Schedule) : Except String (List Step) := do
  let mut result := []
  let mut index := 0
  let mut now := 0
  for a in p.actions do
    match a with
    | .decision name actor branch q =>
      result := result ++ [
        { key := "choice:" ++ name, kind := "choice", label := if actor.isEmpty then "Protocol choice" else actor ++ " chooses", detail := name, timeMs := now },
        { key := s!"action:{name}:{branch}", kind := "action", label := s!"Action {branch + 1}", detail := name, weight := q, timeMs := now }]
    | .clock name refs =>
      let value := (s.events.toList.take index).foldl (fun t e =>
        if e.msgId.any refs.contains then max t e.time else t) 0
      result := result ++ [{ key := "clock:" ++ name, kind := "clock", label := "Clock " ++ name, detail := s!"trigger = {clockText value}", timeMs := now }]
    | .obligation o =>
      let start := ((s.obligations.find? (fun x => x.spec.name == o.name)).map (·.start)).getD now
      result := result ++ [{ key := "obligation:" ++ o.name, kind := "obligation", label := o.name, detail := s!"{o.actor}: due {clockText (start + o.withinMs)}", timeMs := now }]
    | .msg _ timing =>
      let some e := s.events[index]? | throw "missing scheduled event"
      index := index + 1
      now := e.time
      let q := (timing.bind fun t => t.offsets.head?.map (·.2)).getD Q.one
      result := result ++ [{ key := eventKey e, kind := "state", label := e.label, detail := s!"{e.src} → {e.dst} · {clockText e.time}", weight := q, timeMs := e.time }]
    | .act .. =>
      let some e := s.events[index]? | throw "missing scheduled action"
      index := index + 1
      now := e.time
      result := result ++ [{ key := eventKey e, kind := "state", label := e.label, detail := s!"{e.src} · {clockText e.time}", timeMs := e.time }]
  let rs := reports s s.now
  let statuses := rs.map fun r => (r.getObjValAs? String "status").toOption.getD ""
  let status := if statuses.contains "violated" then "violated"
    else if statuses.contains "pending" || statuses.contains "not-triggered" then "pending"
    else if statuses.isEmpty then "no obligations" else "fulfilled"
  let last := (s.events.back?).map (·.label) |>.getD "End"
  return result ++ [{ key := "terminal:" ++ (toJson rs).compress, kind := "terminal", label := last, detail := s!"{clockText s.now} · {status}", timeMs := s.now, obligations := rs }]

def maxNodes := 96

def build (r : Resolved) (roles : List String) : Except String (Array Node) := do
  let paths ← compile r roles
  if paths.any (fun (p,_) => p.unknown) then throw "MDP needs a complete policy: supply probabilities for every choice"
  let mut nodes : Array Node := #[{ key := "root", kind := "start", label := "Start", id := 0, parent := none, depth := 0, mass := Q.one }]
  for (p,s) in paths do
    let mut parent := 0
    for step in ← steps p s do
      let mass := Q.mul nodes[parent]!.mass step.weight
      match nodes.find? (fun n => n.parent == some parent && n.key == step.key && n.kind == step.kind) with
      | some n =>
        if n.weight != step.weight || n.mass != mass then throw "inconsistent shared-prefix probability"
        parent := n.id
      | none =>
        if nodes.size ≥ maxNodes then throw "MDP diagram exceeds 96 nodes; simplify the session"
        let id := nodes.size
        nodes := nodes.push { step with id, parent := some parent, depth := nodes[parent]!.depth + 1, mass }
        parent := id
    if nodes[parent]!.mass != p.probability then throw "terminal mass disagrees with compiled path"
  let terminals := nodes.filter (·.kind == "terminal")
  let total := terminals.foldl (fun q n => Q.add q n.mass) Q.zero
  if total != Q.one then throw s!"terminal probabilities sum to {total.text}, not 1"
  for n in nodes do
    let children := nodes.filter (·.parent == some n.id)
    if n.kind != "terminal" then
      let sum := children.foldl (fun q c => Q.add q c.weight) Q.zero
      if sum != Q.one then throw "outgoing probabilities do not sum to 1"
  return nodes

def violationMass (nodes : Array Node) : Q :=
  nodes.foldl (fun q n =>
    if n.kind == "terminal" && n.obligations.any (fun o => (o.getObjValAs? String "status").toOption == some "violated")
    then Q.add q n.mass else q) Q.zero

def nodeJson (n : Node) : Json := Json.mkObj [
  ("id", n.id), ("parent", toJson n.parent), ("kind", n.kind), ("label", n.label),
  ("detail", n.detail), ("timeMs", n.timeMs), ("probability", n.mass.text),
  ("edgeProbability", n.weight.text), ("edgeKind", if n.kind == "action" then "policy" else "transition"),
  ("obligations", toJson n.obligations)]

/-- Leaf slots keep siblings disjoint; ancestors sit over the span of their children. -/
def drawing (nodes : Array Node) : Except String DiagramModel := do
  let terminalCount := (nodes.filter (·.kind == "terminal")).size
  let boxWidth := nodes.foldl (fun w n =>
    let content := max n.label.length n.detail.length
    let content := if n.kind == "terminal" then max content (22 + n.mass.text.length) else content
    max w (content * 7 + 32)) 240
  let slot := boxWidth + 40
  let width := max 1 terminalCount * slot
  let height := (nodes.foldl (fun d n => max d n.depth) 0 + 1) * 150 + 40
  if width > 20000 || height > 20000 then throw "MDP drawing exceeds dimension limit; simplify the session"
  let mut xs : Array Nat := Array.replicate nodes.size 0
  let mut leaf := 0
  for n in nodes do
    if n.kind == "terminal" then
      xs := xs.set! n.id (leaf * slot + slot / 2)
      leaf := leaf + 1
  for id in (List.range nodes.size).reverse do
    let children := nodes.filter (·.parent == some id)
    if !children.isEmpty then
      xs := xs.set! id ((xs[children[0]!.id]! + xs[children.back!.id]!) / 2)
  let mut shapes := #[]
  for n in nodes do
    if let some parent := n.parent then
      let x1 := xs[parent]!; let y1 := nodes[parent]!.depth * 150 + 105
      let x2 := xs[n.id]!; let y2 := n.depth * 150 + 35
      shapes := shapes.push (.line "" x1 y1 x2 y2 .arrow "2" "" true)
      let edgeLabel := (if n.kind == "action" then "policy " else "p = ") ++ n.weight.text
      shapes := shapes.push (.text "" ((x1+x2)/2) ((y1+y2)/2) "middle" .fg 12 false edgeLabel)
  for n in nodes do
    let x := xs[n.id]!; let y := n.depth * 150 + 70
    let stroke : Ink := if n.kind == "terminal" then .frame else .arrow
    shapes := shapes.push (.rect n.kind (x-boxWidth/2) (y-35) boxWidth 70
      (if n.kind == "action" then 30 else 8) .actFill stroke)
    shapes := shapes.push (.text "boxed" x (y-12) "middle" .fg 13 true n.label)
    shapes := shapes.push (.text "boxed" x (y+8) "middle" .fg 12 false n.detail)
    if n.kind == "terminal" then
      shapes := shapes.push (.text "boxed" x (y+26) "middle" .frame 12 true s!"Terminal probability: {n.mass.text}")
  return { width, height, shapes }

end LeanFM.Session.Decision
