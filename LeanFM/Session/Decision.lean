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
  /-- At a terminal: each role's net balance per unit (selfhost.session.amounts). -/
  balances : List (String × String × Int) := []
  /-- The amount moved on the edge into this state (selfhost.session.mdp.loops: amounts on edges). -/
  amountText : String := ""
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

def signed (n : Int) : String := if n ≥ 0 then s!"+{n}" else s!"{n}"

/-- Add `n` of `unit` to `role`'s balance. -/
def credit (bs : List (String × String × Int)) (role unit : String) (n : Int) : List (String × String × Int) :=
  if bs.any (fun (r,u,_) => r == role && u == unit) then
    bs.map fun (r,u,v) => if r == role && u == unit then (r,u,v+n) else (r,u,v)
  else bs ++ [(role, unit, n)]

/-- Every role listed for every unit that moved, in role order, so each unit's column sums to zero. -/
def complete (roles : List String) (bs : List (String × String × Int)) : List (String × String × Int) :=
  let units := (bs.map (·.2.1)).eraseDups
  units.flatMap fun u => roles.map fun r =>
    (r, u, ((bs.find? (fun (r',u',_) => r' == r && u' == u)).map (·.2.2)).getD 0)

def balanceText (bs : List (String × String × Int)) : String :=
  " - ".intercalate ((bs.filter (·.2.2 != 0)).map fun (r,u,v) => s!"{r} {signed v} {u}")

def eventKey (e : Event String) : String :=
  (Json.mkObj [("label", e.label), ("src", e.src), ("dst", e.dst), ("time", e.time),
    ("id", e.id), ("msgId", toJson e.msgId), ("cause", toJson e.cause),
    ("prior", toJson e.prior), ("route", toJson e.route), ("status", toJson e.status),
    ("act", e.isAct)]).compress

def steps (p : Path) (s : Schedule) (roles : List String := []) : Except String (List Step) := do
  let mut result : List Step := []
  let mut index := 0
  let mut now := 0
  let mut balances : List (String × String × Int) := []
  for a in p.actions do
    match a with
    | .transfer src dst unit n q =>
      -- the amount belongs to the state of the message just drawn; its outcome is part of that state
      let some last := result.getLast? | throw "an amount without its message"
      let priced : Step := { last with
        key := last.key ++ s!"|amount:{n}:{unit}", amountText := s!"{src} -> {dst} {n} {unit}", weight := Q.mul last.weight q }
      result := result.dropLast ++ [priced]
      balances := credit (credit balances src unit (-(n : Int))) dst unit n
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
      result := result ++ [{ key := eventKey e, kind := "state", label := e.label, detail := s!"{e.src} -> {e.dst} - {clockText e.time}", weight := q, timeMs := e.time }]
    | .act .. =>
      let some e := s.events[index]? | throw "missing scheduled action"
      index := index + 1
      now := e.time
      result := result ++ [{ key := eventKey e, kind := "state", label := e.label, detail := s!"{e.src} - {clockText e.time}", timeMs := e.time }]
  let rs := reports s s.now
  let statuses := rs.map fun r => (r.getObjValAs? String "status").toOption.getD ""
  let status := if statuses.contains "violated" then "violated"
    else if statuses.contains "pending" || statuses.contains "not-triggered" then "pending"
    else if statuses.isEmpty then "no obligations" else "fulfilled"
  -- a violated obligation's penalty moves from its actor to its payee
  for r in rs do
    if let .ok pen := r.getObjVal? "penalty" then
      if let (.ok n, .ok u, .ok f, .ok t) := (pen.getObjValAs? Nat "quantity", pen.getObjValAs? String "unit",
          pen.getObjValAs? String "from", pen.getObjValAs? String "to") then
        balances := credit (credit balances f u (-(n : Int))) t u n
  let net := complete roles balances
  let penalties := rs.filterMap fun r => match r.getObjVal? "penalty", r.getObjValAs? String "record" with
    | .ok pen, .ok record => match pen.getObjValAs? Nat "quantity", pen.getObjValAs? String "unit" with
      | .ok n, .ok u => some s!"{record}: pays {n} {u}"
      | _, _ => none
    | _, _ => none
  let terminal : Step := {
    key := "terminal:" ++ (toJson rs).compress ++ (balanceText net), kind := "terminal", label := "End",
    detail := " - ".intercalate ([clockText s.now, status] ++ penalties), timeMs := s.now, obligations := rs, balances := net }
  return result ++ [terminal]

def maxNodes := 96

def build (r : Resolved) (roles : List String) : Except String (Array Node) := do
  let paths ← compile r roles
  if paths.any (fun (p,_) => p.unknown) then throw "MDP needs a complete policy: supply probabilities for every choice"
  let mut nodes : Array Node := #[{ key := "root", kind := "start", label := "Start", id := 0, parent := none, depth := 0, mass := Q.one }]
  for (p,s) in paths do
    let mut parent := 0
    for step in ← steps p s roles do
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

/-- `a - b` of exact non-negative masses, written with a sign. -/
def signedText (a b : Q) : String :=
  if Q.le b a then (Q.norm (a.num * b.den - b.num * a.den) (a.den * b.den)).text
  else "-" ++ (Q.norm (b.num * a.den - a.num * b.den) (a.den * b.den)).text

/-- Each role's expected net balance per unit: the sum of terminal mass times balance, exact. -/
def expected (nodes : Array Node) : List (String × String × String) :=
  let terminals := nodes.filter (·.kind == "terminal")
  let keys := (terminals.toList.flatMap fun n => n.balances.map fun (r,u,_) => (r,u)).eraseDups
  keys.map fun (r,u) =>
    let (plus, minus) := terminals.foldl (fun (pl, mi) n =>
      match n.balances.find? (fun (r',u',_) => r' == r && u' == u) with
      | some (_,_,v) => if v ≥ 0 then (Q.add pl (Q.mul n.mass (Q.norm v.toNat 1)), mi)
                        else (pl, Q.add mi (Q.mul n.mass (Q.norm (-v).toNat 1)))
      | none => (pl, mi)) (Q.zero, Q.zero)
    (r, u, signedText plus minus)

/-- Expected penalty paid, per payer and unit: violated terminals only, each counted once. -/
def expectedPenalties (nodes : Array Node) : List (String × String × String) :=
  let paid := (nodes.filter (·.kind == "terminal")).toList.flatMap fun n =>
    n.obligations.filterMap fun o => match o.getObjVal? "penalty" with
      | .ok pen => match pen.getObjValAs? String "from", pen.getObjValAs? String "unit", pen.getObjValAs? Nat "quantity" with
        | .ok f, .ok u, .ok q => some (f, u, Q.mul n.mass (Q.norm q 1))
        | _, _, _ => none
      | .error _ => none
  let keys := (paid.map fun (f,u,_) => (f,u)).eraseDups
  keys.map fun (f,u) => (f, u, (paid.foldl (fun acc (f',u',q) => if f' == f && u' == u then Q.add acc q else acc) Q.zero).text)

def balancesJson (bs : List (String × String × Int)) : Json :=
  toJson (bs.map fun (r,u,v) => Json.mkObj [("role", r), ("unit", u), ("net", v)])

def nodeJson (n : Node) : Json := Json.mkObj [
  ("id", n.id), ("parent", toJson n.parent), ("kind", n.kind), ("label", n.label),
  ("detail", n.detail), ("timeMs", n.timeMs), ("probability", n.mass.text),
  ("edgeProbability", n.weight.text), ("edgeKind", if n.kind == "action" then "policy" else "transition"),
  ("expectedVisits", n.mass.text), ("edgeAmount", n.amountText),
  ("obligations", toJson n.obligations), ("balances", balancesJson n.balances)]

/-- Leaf slots keep siblings disjoint; ancestors sit over the span of their children. -/
def drawing (nodes : Array Node) : Except String DiagramModel := do
  let terminalCount := (nodes.filter (·.kind == "terminal")).size
  let boxWidth := nodes.foldl (fun w n =>
    let content := max n.label.length n.detail.length
    let content := if n.kind == "terminal" then max (max content (22 + n.mass.text.length)) (balanceText n.balances).length else content
    max w (content * 7 + 32)) 240
  let edgeWidth := nodes.foldl (fun w n => max w ((14 + n.weight.text.length + n.amountText.length) * 7 + 30)) 0
  let slot := max (boxWidth + 40) edgeWidth
  -- the expected results under the policy, under the tree
  let exp := (expected nodes).filter (·.2.2 != "0")
  let footer := (if exp.isEmpty then [] else ["Expected: " ++ " - ".intercalate (exp.map fun (r,u,v) =>
      s!"{r} {if v.startsWith "-" then v else "+" ++ v} {u}")]) ++
    [s!"P(any violation) = {(violationMass nodes).text}"]
  let width := max (max 1 terminalCount * slot) (footer.foldl (fun w l => max w (l.length * 8 + 40)) 0)
  let height := (nodes.foldl (fun d n => max d n.depth) 0 + 1) * 150 + 60
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
      let edgeLabel := (if n.kind == "action" then "policy " else "p = ") ++ n.weight.text ++
        (if n.amountText.isEmpty then "" else " - " ++ n.amountText)
      let lw := edgeLabel.length * 7 + 10
      shapes := shapes.push (.rect "label" ((x1+x2)/2 - lw/2) ((y1+y2)/2 - 13) lw 18 4 .bg .bg)
      shapes := shapes.push (.text "boxed" ((x1+x2)/2) ((y1+y2)/2) "middle" .fg 12 false edgeLabel)
  for n in nodes do
    let x := xs[n.id]!; let y := n.depth * 150 + 70
    let stroke : Ink := if n.kind == "terminal" then .frame else .arrow
    let money := balanceText n.balances
    let tall := n.kind == "terminal" && !money.isEmpty
    shapes := shapes.push (.rect n.kind (x-boxWidth/2) (y-35) boxWidth (if tall then 88 else 70)
      (if n.kind == "action" then 30 else 8) .actFill stroke)
    shapes := shapes.push (.text "boxed" x (y-12) "middle" .fg 13 true n.label)
    shapes := shapes.push (.text "boxed" x (y+8) "middle" .fg 12 false n.detail)
    if n.kind != "terminal" && n.kind != "start" then
      -- in a tree each state is visited at most once, so its expected visits are its probability of being reached
      shapes := shapes.push (.text "boxed" x (y+26) "middle" .muted 12 false s!"expected visits {n.mass.text}")
    if n.kind == "terminal" then
      shapes := shapes.push (.text "boxed" x (y+26) "middle" .frame 12 true s!"Terminal probability: {n.mass.text}")
      if tall then shapes := shapes.push (.text "boxed" x (y+44) "middle" .fg 12 false money)
  for (line, i) in footer.zipIdx do
    shapes := shapes.push (.text "" (width / 2) (height - 30 + i * 18) "middle" .frame 13 true line)
  return { width, height := height + footer.length * 18, shapes }

end LeanFM.Session.Decision
