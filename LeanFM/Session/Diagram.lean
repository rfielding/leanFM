import LeanFM.Session.Global

/-!
# Interaction diagrams drawn from session types (clause selfhost.session.diagram)

`Global.diagram` draws any global type as a standard UML sequence diagram. Every construct has
one notation, so a diagram is a view of the protocol, never a separate drawing:

| protocol                         | diagram                                                    |
|----------------------------------|------------------------------------------------------------|
| `x: L from A to B`               | solid arrow A → B labelled `x: L`                          |
| `... cause y` reaching a call B → A | dashed arrow: the reply to that call                    |
| `where e`                        | `[e]` under the arrow                                      |
| `route "POST /orders"`, `status 201` | `· POST /orders`, `· 201` after the label              |
| a request and its responses      | an activation bar on the callee, request to last response  |
| `L at A`                         | action box on A's lifeline                                 |
| `choice { } or { }`              | `alt` frame, `D selects` (the decider), the others offer   |
| `par { } and { }`                | `par` frame with dashed dividers                           |
| `join k of { } and { }`          | `par` frame captioned `any k of n`                         |
| `rec N { ... continue N; }`      | `loop N` frame; `continue N` drawn as `↻ continue N`              |
| `sessions { }`                   | `loop` frame captioned `sessions`, around one instance     |
| `include P ...`                  | `ref P` frame around P's steps                             |

Negative requirements: no construct is dropped (each has an element the tests look for); no arrow
is drawn that is not a message of the protocol (arrows are emitted only from `msg`); every label,
guard and role name is escaped, so protocol text cannot inject markup.
-/

namespace LeanFM.Session

structure DiagramTheme where
  bg : String
  fg : String
  line : String
  arrow : String
  frame : String
  muted : String
  actFill : String

def DiagramTheme.dark : DiagramTheme :=
  { bg := "#111111", fg := "#e5e7eb", line := "#4b5563", arrow := "#93c5fd", frame := "#fbbf24"
    muted := "#9ca3af", actFill := "#1f2937" }

def DiagramTheme.light : DiagramTheme :=
  { bg := "#ffffff", fg := "#111827", line := "#9ca3af", arrow := "#1d4ed8", frame := "#b45309"
    muted := "#4b5563", actFill := "#f3f4f6" }

def diagramEscape (s : String) : String :=
  String.join <| s.toList.map fun c =>
    if c == '&' then "&amp;" else if c == '<' then "&lt;"
    else if c == '>' then "&gt;" else if c == '"' then "&quot;" else c.toString

namespace Diagram

structure St (R : Type) where
  y     : Nat := 70
  out   : Array String := #[]
  /-- Messages drawn so far, by id: sender, receiver, cause, and whether it was a reply. -/
  sent  : List (String × R × R × Option String × Bool) := []
  /-- Activation bars: request id, callee, inset, top, bottom (the lowest response so far). -/
  bars  : List (String × R × Nat × Nat × Nat) := []
  /-- Where the branch being drawn began (the last divider). -/
  branchTop : Nat := 0
  /-- The last thing drawn was a frame's tab, so a frame opening now must start lower. -/
  fresh : Bool := false

abbrev M (R : Type) := StateM (St R)

def colW : Nat := 180
def margin : Nat := 90

def xOf [DecidableEq R] (roles : List R) (r : R) : Nat :=
  margin + colW * (roles.idxOf r)

def emit (s : String) : M R Unit := modify fun st => { st with out := st.out.push s }
def adv (n : Nat) : M R Unit := modify fun st => { st with y := st.y + n }
def getY : M R Nat := return (← get).y

def text (t : DiagramTheme) (x y : Nat) (s : String) (anchor := "middle") (color := t.fg)
    (size := 12) (style := "") : String :=
  s!"<text x=\"{x}\" y=\"{y}\" text-anchor=\"{anchor}\" fill=\"{color}\" font-size=\"{size}\"{style}>{diagramEscape s}</text>"

/-- Left and right edge of a frame at nesting depth `d`. -/
def edges (n d : Nat) : Nat × Nat :=
  (margin - 70 + 8 * d, margin + colW * (n - 1) + 70 - 8 * d)

/-- The frame's pentagon tab and caption; returns nothing, draws at the current y. -/
def frameTop (t : DiagramTheme) (n d : Nat) (op caption : String) : M R Nat := do
  if (← get).fresh then adv 22
  let y ← getY
  let (x0, _) := edges n d
  let w := 10 + 8 * op.length
  emit s!"<path d=\"M{x0} {y} h{w} v12 l-6 6 h-{w - 6} z\" fill=\"{t.bg}\" stroke=\"{t.frame}\"/>"
  emit (text t (x0 + 5) (y + 13) op "start" t.frame 11 " font-weight=\"bold\"")
  if caption != "" then
    emit (text t (x0 + w + 8) (y + 13) s!"[{caption}]" "start" t.frame 11)
  adv 8
  modify fun st => { st with fresh := true }
  return y

def frameBottom (t : DiagramTheme) (n d top : Nat) (kind : String) : M R Unit := do
  adv 8
  let y ← getY
  let (x0, x1) := edges n d
  emit s!"<rect class=\"frame {kind}\" x=\"{x0}\" y=\"{top}\" width=\"{x1 - x0}\" height=\"{y - top}\" fill=\"none\" stroke=\"{t.frame}\"/>"
  adv 10

def divider (t : DiagramTheme) (n d : Nat) (caption : String) : M R Unit := do
  adv 4
  let y ← getY
  let (x0, x1) := edges n d
  emit s!"<line x1=\"{x0}\" y1=\"{y}\" x2=\"{x1}\" y2=\"{y}\" stroke=\"{t.frame}\" stroke-dasharray=\"6 4\"/>"
  modify fun st => { st with branchTop := y }
  if caption != "" then emit (text t (x0 + 6) (y + 13) s!"[{caption}]" "start" t.frame 11)
  adv 6

/-- A message is a reply when its cause chain reaches a request (a message that was not itself a
reply) from its receiver to its sender: the same rule as the HTTP discipline, so a response that
follows other calls (a Receipt after the bank's Charged) is still drawn as the answer to the call
that asked for it, and a new call made after a reply (paying after a Quote) is not. -/
partial def answers [DecidableEq R] (st : St R) (i : Interaction R) : Option String :=
  go i.cause 64
where
  go : Option String → Nat → Option String
    | _, 0 | none, _ => none
    | some c, fuel + 1 => match st.sent.lookup c with
      | some (s, d, cause, wasReply) =>
          if !wasReply && s == i.dst && d == i.src then some c else go cause fuel
      | none => none

def isReply [DecidableEq R] (st : St R) (i : Interaction R) : Bool := (answers st i).isSome

def arrow [DecidableEq R] (t : DiagramTheme) (roles : List R) (i : Interaction R) : M R Unit := do
  adv 30
  modify fun st => { st with fresh := false }
  let st ← get
  let y := st.y
  let answered := answers st i
  let reply := answered.isSome
  let x1 := xOf roles i.src
  let x2 := xOf roles i.dst
  let label := (match i.id with | some x => s!"{x}: " | none => "") ++ i.label ++
    (match i.route with | some r => s!" · {r}" | none => "") ++
    (match i.status with | some s => s!" · {s}" | none => "")
  let dash := if reply then " stroke-dasharray=\"6 4\"" else ""
  let cls := if reply then "msg reply" else "msg"
  if x1 == x2 then
    emit s!"<path class=\"{cls}\" d=\"M{x1} {y - 8} h40 v16 h-40\" fill=\"none\" stroke=\"{t.arrow}\"{dash} marker-end=\"url(#head)\"/>"
    emit (text t (x1 + 46) (y + 4) label "start")
  else
    emit s!"<line class=\"{cls}\" x1=\"{x1}\" y1=\"{y}\" x2=\"{x2}\" y2=\"{y}\" stroke=\"{t.arrow}\" stroke-width=\"1.5\"{dash} marker-end=\"url(#head)\"/>"
    emit (text t ((x1 + x2) / 2) (y - 6) label)
  -- a where clause goes under the arrow, so a long one cannot push the label off its arrow
  if let some g := i.guard then
    let gx := if x1 == x2 then x1 + 46 else (x1 + x2) / 2
    let anchor := if x1 == x2 then "start" else "middle"
    emit (text t gx (y + (if x1 == x2 then 18 else 14)) s!"[{g.text}]" anchor t.muted 11 " class=\"guard\"")
    adv 18
  if let some id := i.id then
    modify fun st => { st with sent := (id, i.src, i.dst, i.cause, reply) :: st.sent }
  -- a call is an activation bar on the callee, from its request down to its response; a
  -- response in another branch of a choice gets a bar from where its branch began, so a bar
  -- never runs through a branch the call is not in. A call made while the callee is still busy
  -- with another sits inset beside it.
  match answered with
  | some r => modify fun st =>
      match st.bars.find? (fun b => b.1 == r && b.2.2.2.1 == b.2.2.2.2) with
      | some _ => { st with bars := st.bars.map fun b =>
          if b.1 == r && b.2.2.2.1 == b.2.2.2.2 then (b.1, b.2.1, b.2.2.1, b.2.2.2.1, y) else b }
      | none => match st.bars.find? (·.1 == r) with
        | some (_, callee, inset, _, _) =>
            { st with bars := st.bars ++ [(r, callee, inset, min st.branchTop y, y)] }
        | none => st
  | none => if let some id := i.id then
      modify fun st =>
        let busy := (st.bars.filter fun b => b.2.1 == i.dst && b.2.2.2.1 == b.2.2.2.2).length
        { st with bars := st.bars ++ [(id, i.dst, busy, y, y)] }

def act [DecidableEq R] (t : DiagramTheme) (roles : List R) (r : R) (label : String) : M R Unit := do
  adv 12
  modify fun st => { st with fresh := false }
  let y ← getY
  let x := xOf roles r
  let w := 16 + 7 * label.length
  emit s!"<rect class=\"act\" x=\"{x - w / 2}\" y=\"{y}\" width=\"{w}\" height=\"24\" rx=\"10\" fill=\"{t.actFill}\" stroke=\"{t.arrow}\"/>"
  emit (text t x (y + 16) label)
  adv 26

partial def draw [DecidableEq R] [ToString R] (t : DiagramTheme) (roles : List R) (d : Nat) :
    Global R → M R Unit
  | .done => pure ()
  | .msg i k => do arrow t roles i; draw t roles d k
  | .act r l k => do act t roles r l; draw t roles d k
  | .var name => do
      adv 22
      let y ← getY
      let (x0, _) := edges roles.length d
      emit (text t (x0 + 8) y s!"↻ continue {name}" "start" t.frame 11 " class=\"continue\"")
      adv 6
  | .choice bs => do
      let caption := match Global.decider bs with
        | .ok r => s!"{r} selects; others offer"
        | .error _ => "race: no single role selects"
      let top ← frameTop t roles.length d "alt" caption
      branches t roles d bs ""
      frameBottom t roles.length d top "alt"
  | .par bs k => do
      let top ← frameTop t roles.length d "par" ""
      branches t roles d bs ""
      frameBottom t roles.length d top "par"
      draw t roles d k
  | .join need bs k => do
      let top ← frameTop t roles.length d "par" s!"any {need} of {bs.length}"
      branches t roles d bs ""
      frameBottom t roles.length d top "join"
      draw t roles d k
  | .loop name body => do
      let top ← frameTop t roles.length d "loop" name
      draw t roles (d + 1) body
      frameBottom t roles.length d top "loop"
  | .sessions body k => do
      let top ← frameTop t roles.length d "loop" "sessions: one instance per request, concurrently"
      draw t roles (d + 1) body
      frameBottom t roles.length d top "sessions"
      draw t roles d k
  | .box name body k => do
      let top ← frameTop t roles.length d "ref" name
      draw t roles (d + 1) body
      frameBottom t roles.length d top "ref"
      draw t roles d k
where
  branches (t : DiagramTheme) (roles : List R) (d : Nat) (bs : List (Global R)) (cap : String) :
      M R Unit := do
    let mut firstB := true
    for b in bs do
      if !firstB then divider t roles.length (d) cap
      firstB := false
      draw t roles (d + 1) b

end Diagram

/-- An SVG sequence diagram of `g` with one lifeline per role in `roles`, in that order. -/
def Global.diagram [DecidableEq R] [ToString R] (g : Global R) (roles : List R)
    (theme : DiagramTheme := .dark) (title : String := "") : String :=
  let t := theme
  let ((), st) := (Diagram.draw t roles 0 g).run {}
  let bottom := st.y + 30
  let width := Diagram.margin * 2 + Diagram.colW * (roles.length - 1)
  let height := bottom + 40
  let heads := roles.map fun r =>
    let x := Diagram.xOf roles r
    let name := toString r
    let w := 24 + 8 * name.length
    s!"<g class=\"role\"><rect x=\"{x - w / 2}\" y=\"20\" width=\"{w}\" height=\"28\" rx=\"4\" fill=\"{t.actFill}\" stroke=\"{t.fg}\"/>{Diagram.text t x 39 name}" ++
    s!"<rect x=\"{x - w / 2}\" y=\"{bottom}\" width=\"{w}\" height=\"28\" rx=\"4\" fill=\"{t.actFill}\" stroke=\"{t.fg}\"/>{Diagram.text t x (bottom + 19) name}" ++
    s!"<line x1=\"{x}\" y1=\"48\" x2=\"{x}\" y2=\"{bottom}\" stroke=\"{t.line}\" stroke-dasharray=\"4 4\"/></g>"
  let bars := st.bars.filterMap fun (_, r, inset, top, bot) =>
    if bot ≤ top then none else
    some s!"<rect class=\"activation\" x=\"{Diagram.xOf roles r - 5 + 7 * inset}\" y=\"{top}\" width=\"10\" height=\"{bot - top}\" fill=\"{t.actFill}\" stroke=\"{t.arrow}\"/>"
  let titleEl := if title == "" then "" else Diagram.text t 10 14 title "start" t.muted 11
  s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\" font-family=\"ui-sans-serif, system-ui, sans-serif\">" ++
  s!"<defs><marker id=\"head\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"8\" markerHeight=\"8\" orient=\"auto-start-reverse\"><path d=\"M0 0 L10 5 L0 10 z\" fill=\"{t.arrow}\"/></marker></defs>" ++
  s!"<rect width=\"100%\" height=\"100%\" fill=\"{t.bg}\"/>" ++ titleEl ++
  String.join heads ++ String.join bars ++ String.join st.out.toList ++ "</svg>"

end LeanFM.Session
