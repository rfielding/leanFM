import LeanFM.Session.Text
import LeanFM.Session.Diagram

/-!
# Deployments: where a protocol's roles run (selfhost.session.deployment)

`deployment Name of P { ... }` writes the deployment tree of `Session.Topology` as text after the
protocol it places. `Text.deploymentDecl` reads it; this module checks it against `P` and draws it.

A deployment adds no step to `P`. Its messages, their order and its nesting stay as written; the
deployment says where each role runs and which interface each message arrives on, and reports the
conditions that interface and placement add (partition, hostile, reject, per-key order, and the
kind's own), for the implementation to handle.

Positive invariants: every role of `P` is placed exactly once; each link (a distinct sender and
receiver of `P`'s messages) uses the first interface of its receiver, in the block's order, that the
sender can reach, and a receiver with no interfaces is unrestricted, as in the topology.

Negative requirements: no deployment is reported placed with a role unplaced or placed twice, a
placed name that is not a role, or a link whose receiver has interfaces of which the sender can
reach none; every name drawn is escaped, so text cannot inject markup.
-/

namespace LeanFM.Session
namespace Deployment
open Text

/-- One link of a protocol under a deployment: every message from `src` to `dst`. -/
structure Link where
  src : String
  dst : String
  labels : List String
  /-- the implicit name of the interface the messages arrive on; none when `dst` declares none -/
  via : Option String := none
  reachable : Bool := true
  conditions : List String := []
  /-- why the link is refused, or a note on a reply or an unrestricted link -/
  why : String := ""

/-- A placed role: its path of groups and its interfaces. -/
structure Placement where
  role : String
  path : List (String × Place)
  ifaces : List Iface

/-- What a deployment says about its protocol. -/
structure Report where
  placements : List Placement
  links : List Link
  /-- (the role an issue is about, the issue) -/
  issues : List (String × String)

/-- One message of a protocol: sender, receiver, label, its id and the id it names as cause. -/
structure Msg where
  src : String
  dst : String
  label : String
  id : Option String
  cause : Option String

/-- Every message of a protocol, includes inlined. -/
partial def messages : Global String → List Msg
  | .msg i k => ⟨i.src, i.dst, i.label, i.id, i.cause⟩ :: messages k
  | .act _ _ k => messages k
  | .choice bs => bs.flatMap messages
  | .par bs k | .join _ bs k => bs.flatMap messages ++ messages k
  | .loop _ b => messages b
  | .sessions b k | .box _ b k => messages b ++ messages k
  | .var _ | .done => []

/-- Whether a message answers its receiver: its cause chain (at most 64 links) reaches a message
from its receiver to its sender, the rule the sequence diagram dashes replies by. -/
def isReply (ms : List Msg) (m : Msg) : Bool := Id.run do
  let mut c := m.cause
  for _ in [0:64] do
    match c.bind fun x => ms.find? (·.id == some x) with
    | none => return false
    | some e =>
      if e.src == m.dst && e.dst == m.src then return true
      c := e.cause
  return false

/-- The messages grouped by sender and receiver, in the order the pairs first occur, each pair with
its labels and whether every one of its messages is a reply. -/
def pairs (g : Global String) : List (String × String × List String × Bool) :=
  let ms := messages g
  ms.foldl (fun acc m =>
    let r := isReply ms m
    match acc.find? (fun (s', d', _) => s' == m.src && d' == m.dst) with
    | some _ => acc.map fun (s', d', ls, rs) =>
        if s' == m.src && d' == m.dst then (s', d', (if ls.contains m.label then ls else ls ++ [m.label]), rs && r)
        else (s', d', ls, rs)
    | none => acc ++ [(m.src, m.dst, [m.label], r)]) []

/-- Every actor of a tree with the groups above it. -/
partial def actorsOf (above : List (String × Place)) : Node String → List Placement
  | .group n p cs => cs.flatMap (actorsOf (above ++ [(n, p)]))
  | .actor r is => [⟨r, above, is⟩]

def placeWord : Place → String
  | .world => "world" | .outside => "outside" | .island => "island" | .datacenter => "datacenter"
  | .machine => "machine" | .replicated => "replicated" | .sharded => "sharded"

/-- Why an interface's scope refuses a sender. -/
def refusal (dst : Placed String) (name : String) : String :=
  match (dst.iface.map (·.scope) : Option Scope) with
  | some .peering => s!"{name} is peering, not reachable from outside"
  | some .internal => s!"{name} is internal, reachable only from island {dst.island}"
  | some .local =>
    let m := (dst.path.find? (·.2 == .machine)).map (·.1)
    s!"{name} is local, reachable only from {(m.map (s!"machine " ++ ·)).getD "the same machine, and it is on none"}"
  | _ => s!"{name} is not reachable"

/-- Check a deployment against the roles and global type of the protocol it places. -/
def check (d : DeploymentDef) (roles : List String) (g : Global String) : Report := Id.run do
  let t : Topology String := { world := d.world }
  let ps := d.world.flatMap (actorsOf [])
  let mut issues : Array (String × String) := #[]
  for r in roles do
    match (ps.filter (·.role == r)).length with
    | 0 => issues := issues.push (r, s!"{r} is a role of {d.protocolName} and is not placed")
    | 1 => pure ()
    | n => issues := issues.push (r, s!"{r} is placed {n} times; place each role once")
  for p in ps do
    if !roles.contains p.role then
      issues := issues.push (p.role, s!"{p.role} is not a role of {d.protocolName} ({", ".intercalate roles})")
  let ps' := pairs g
  let mut links : Array Link := #[]
  -- calls first: a link that is not all replies goes to an interface of its receiver
  for (s, dst, labels, _) in ps'.filter (fun (_, _, _, r) => !r) do
    match ps.find? (·.role == s), ps.find? (·.role == dst) with
    | some _, some q =>
      if q.ifaces.isEmpty then
        let c := t.channel s ⟨dst, q.path, none⟩
        links := links.push { src := s, dst, labels, conditions := (c.conditions.map (·.name)).eraseDups,
                              why := s!"{dst} declares no interface, so it is unrestricted" }
      else
        let cands : List (Placed String) := q.ifaces.map fun i => ⟨dst, q.path, some i⟩
        match cands.find? (t.reachable s ·) with
        | some p =>
          links := links.push { src := s, dst, labels, via := some p.implicitName,
                                conditions := ((t.channel s p).conditions.map (·.name)).eraseDups }
        | none =>
          let why := "; ".intercalate (cands.map fun p => refusal p p.implicitName)
          links := links.push { src := s, dst, labels, reachable := false, why }
          issues := issues.push (dst, s!"{s} cannot send {", ".intercalate labels} to {dst}: {why}")
    | _, _ => pure ()
  -- replies travel back over the link they answer, with its interface, conditions and verdict
  let calls := links
  for (s, dst, labels, _) in ps'.filter (fun (_, _, _, r) => r) do
    match calls.find? (fun l => l.src == dst && l.dst == s) with
    | some c =>
      let note := s!"replies to {dst} over the link {dst} opened" ++ (if c.reachable then "" else s!", which is refused: {c.why}")
      links := links.push { c with src := s, dst := dst, labels := labels, why := note }
    | none => pure ()
  -- in the order the protocol first uses each pair
  let order := ps'.map fun (s, d, _, _) => (s, d)
  let ordered := order.filterMap fun (s, d) => links.find? fun l => l.src == s && l.dst == d
  return { placements := ps, links := ordered, issues := issues.toList }

/-! ## The view -/

def esc := diagramEscape
def px (x : Float) : String := toString x.round.toInt64.toInt

def ifaceText (i : Iface) : String := s!"{i.scope.name} {i.name} : {i.kind.name}"
def groupText (n : String) (p : Place) : String := if p == .outside then "outside" else s!"{placeWord p} {n}"

/-- The space between stacked boxes, room for the arrows between them. -/
def gap : Nat := 44

/-- A box's width and height. -/
partial def size : Node String → Nat × Nat
  | .actor r is =>
    let w := (is.map fun i => (ifaceText i).length * 7 + 24).foldl max (max 110 (r.length * 9 + 24))
    (w, 34 + 18 * is.length)
  | .group n p cs =>
    let ss := cs.map size
    let w := max ((groupText n p).length * 8 + 28) ((ss.foldl (fun m s => max m s.1) 0) + 28)
    (w, 30 + (ss.foldl (fun a s => a + s.2) 0) + gap * (cs.length - 1) + 14)

/-- A placed role's box: (role, x, y, w, h). -/
abbrev Box := String × Nat × Nat × Nat × Nat

/-- The elements of a node drawn with its top left at (x, y), and the roles' boxes. -/
partial def draw (th : DiagramTheme) (x y : Nat) (n : Node String) : List String × List Box :=
  let (w, h) := size n
  match n with
  | .actor r is =>
    let rect := s!"<rect class=\"role\" x=\"{x}\" y=\"{y}\" width=\"{w}\" height=\"{h}\" rx=\"6\" fill=\"{th.actFill}\" stroke=\"{th.fg}\" stroke-width=\"1.2\"/>"
    let name := s!"<text x=\"{x + w / 2}\" y=\"{y + 22}\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\" fill=\"{th.fg}\">{esc r}</text>"
    let lines := (is.zipIdx).map fun (i, k) =>
      s!"<text class=\"iface\" x=\"{x + w / 2}\" y=\"{y + 42 + 18 * k}\" text-anchor=\"middle\" font-size=\"11\" fill=\"{th.muted}\">{esc (ifaceText i)}</text>"
    (rect :: name :: lines, [(r, x, y, w, h)])
  | .group gn p cs =>
    let dashed := p == .outside || p == .replicated || p == .sharded
    let stroke := if p == .island then th.frame else th.line
    let rect := s!"<rect class=\"group {placeWord p}\" x=\"{x}\" y=\"{y}\" width=\"{w}\" height=\"{h}\" rx=\"10\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"1\"{if dashed then " stroke-dasharray=\"5 4\"" else ""}/>"
    let label := s!"<text x=\"{x + 12}\" y=\"{y + 19}\" font-size=\"12\" fill=\"{stroke}\">{esc (groupText gn p)}</text>"
    let (els, boxes, _) := cs.foldl (fun (acc : List String × List Box × Nat) c =>
      let (e, b) := draw th (x + 14) acc.2.2 c
      (acc.1 ++ e, acc.2.1 ++ b, acc.2.2 + (size c).2 + gap)) ([], [], y + 30)
    (rect :: label :: els, boxes)

/-- Where the segment from a box's centre towards (tx, ty) leaves the box. -/
def edge (b : Box) (tx ty : Float) : Float × Float :=
  let (_, x, y, w, h) := b
  let cx := x.toFloat + w.toFloat / 2
  let cy := y.toFloat + h.toFloat / 2
  let dx := tx - cx
  let dy := ty - cy
  let sx := if dx.abs < 0.001 then 1e9 else (w.toFloat / 2 + 4) / dx.abs
  let sy := if dy.abs < 0.001 then 1e9 else (h.toFloat / 2 + 4) / dy.abs
  let s := min sx sy
  (cx + dx * s, cy + dy * s)

def refusedInk (th : DiagramTheme) : String := if th.bg == DiagramTheme.light.bg then "#dc2626" else "#f87171"

/-- The legend line of a link. -/
def linkText (i : Nat) (l : Link) : String :=
  let head := s!"{i}. {l.src} → {l.dst} ({", ".intercalate l.labels})"
  if !l.reachable then s!"{head}: refused: {l.why}"
  else
    let via := l.via.getD "no interface declared"
    let via := if l.why.startsWith "replies" then s!"{via} (replies)" else via
    let adds := if l.conditions.isEmpty then "adds nothing" else s!"adds {", ".intercalate l.conditions}"
    s!"{head}: {via}; {adds}"

/-- The deployment tree with its links, numbered, and a legend line for each link. -/
def svg (d : DeploymentDef) (r : Report) (th : DiagramTheme := .dark) : String := Id.run do
  let top := 40
  let (els, boxes, right) := d.world.foldl (fun (acc : List String × List Box × Nat) n =>
    let (e, b) := draw th acc.2.2 top n
    (acc.1 ++ e, acc.2.1 ++ b, acc.2.2 + (size n).1 + 40)) ([], [], 20)
  let bottom := (d.world.map fun n => top + (size n).2).foldl max top
  let mut arrows : Array String := #[]
  for (l, k) in r.links.zipIdx do
    match boxes.find? (·.1 == l.src), boxes.find? (·.1 == l.dst) with
    | some a, some b =>
      let (_, ax, ay, aw, ah) := a
      let (_, bx, by_, bw, bh) := b
      let (acx, acy) := (ax.toFloat + aw.toFloat / 2, ay.toFloat + ah.toFloat / 2)
      let (bcx, bcy) := (bx.toFloat + bw.toFloat / 2, by_.toFloat + bh.toFloat / 2)
      -- a pair drawn both ways is drawn as two parallel arrows
      let both := r.links.any fun m => m.src == l.dst && m.dst == l.src
      let len := Float.sqrt ((bcx - acx) ^ 2 + (bcy - acy) ^ 2)
      -- the perpendicular of each arrow's own direction: the two directions of a pair land on opposite sides
      let off := if both && len > 0 then 10.0 else 0.0
      let (ox, oy) := if len > 0 then (-(bcy - acy) / len * off, (bcx - acx) / len * off) else (0.0, 0.0)
      let (x1, y1) := edge a (bcx + ox) (bcy + oy)
      let (x2, y2) := edge b (acx + ox) (acy + oy)
      let (x1, y1, x2, y2) := (x1 + ox, y1 + oy, x2 + ox, y2 + oy)
      let ink := if l.reachable then th.arrow else refusedInk th
      let cls := if l.reachable then "link" else "link refused"
      arrows := arrows.push s!"<line class=\"{cls}\" x1=\"{px x1}\" y1=\"{px y1}\" x2=\"{px x2}\" y2=\"{px y2}\" stroke=\"{ink}\" stroke-width=\"1.8\"{if l.reachable then "" else " stroke-dasharray=\"6 4\""} marker-end=\"url(#{if l.reachable then "dep-ok" else "dep-no"})\"/>"
      -- the number sits a third of the way along, so two directions of a pair do not cover each other
      let (mx, my) := (x1 + (x2 - x1) * 0.35, y1 + (y2 - y1) * 0.35)
      arrows := arrows.push s!"<circle cx=\"{px mx}\" cy=\"{px my}\" r=\"9\" fill=\"{th.bg}\" stroke=\"{ink}\" stroke-width=\"1\"/><text x=\"{px mx}\" y=\"{px (my + 4)}\" text-anchor=\"middle\" font-size=\"11\" fill=\"{ink}\">{k + 1}</text>"
    | _, _ => pure ()
  let legend := (r.links.zipIdx).map fun (l, k) =>
    let t := linkText (k + 1) l
    (t, if l.reachable then th.fg else refusedInk th)
  let ly := bottom + 30
  let legendEls := (legend.zipIdx).map fun ((t, c), k) =>
    s!"<text class=\"legend\" x=\"20\" y=\"{ly + 18 * k}\" font-size=\"12\" fill=\"{c}\">{esc t}</text>"
  let width := (legend.map fun (t, _) => t.length * 7 + 40).foldl max (max right 360)
  let height := ly + 18 * legend.length + 10
  let marker (id ink : String) :=
    s!"<marker id=\"{id}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10z\" fill=\"{ink}\"/></marker>"
  let title := s!"<text x=\"20\" y=\"24\" font-size=\"13\" fill=\"{th.muted}\">{esc s!"deployment {d.name} of {d.protocolName}"}</text>"
  return s!"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {width} {height}\" width=\"{width}\" height=\"{height}\" font-family=\"sans-serif\">" ++
    s!"<defs>{marker "dep-ok" th.arrow}{marker "dep-no" (refusedInk th)}</defs>" ++
    s!"<rect width=\"{width}\" height=\"{height}\" fill=\"{th.bg}\"/>" ++ title ++
    String.join els ++ String.join arrows.toList ++ String.join legendEls ++ "</svg>"

/-! ## From text -/

/-- The text's last deployment (or the one named), its protocol's roles and global type, built as
`Instances.systemsOf` builds an accepted protocol (its includes inlined). -/
def ofText (text : String) (name : Option String := none) :
    Except String (DeploymentDef × List String × Global String) := do
  let (defs, st) ← Text.readText text
  let d ← match name with
    | some n => match st.deployments.toList.find? (·.name == n) with
      | some d => pure d
      | none => throw s!"the text declares no deployment {n}"
    | none => match st.deployments.toList.getLast? with
      | some d => pure d
      | none => throw "the text declares no deployment; add one after the protocol it places: deployment Production of P { outside { Client; } island us { Server { ingress https : ingressHttps; } } }"
  let some i := defs.findIdx? (·.name == d.protocolName) | throw s!"deployment {d.name}: no protocol {d.protocolName}"
  let p := defs[i]!
  let ctx : Text.Ctx := { defs := defs.take i, rename := [], roles := p.roles, path := p.name, inside := [p.name] }
  let (g, _) ← (Text.build ctx p.body).run 0
  return (d, p.roles, g)

end Deployment
end LeanFM.Session
