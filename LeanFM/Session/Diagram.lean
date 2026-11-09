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
| `choice { } or { }`              | `alt` frame captioned `D decides`: the role that sends the first message of every branch |
| `par { } and { }`                | `par` frame with dashed dividers                           |
| `join k of { } and { }`          | `par` frame captioned `any k of n`                         |
| `rec N { ... continue N; }`      | `loop N` frame; `continue N` drawn as `↻ continue N`              |
| `sessions { }`                   | `loop` frame captioned `one session per request`, around one instance |
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

/-- A colour by role, resolved by a theme: the SVG renderer and the MCP view each map it to their
own palette, so the same drawing reads in dark and light. -/
inductive Ink where
  | none | bg | fg | line | arrow | frame | muted | actFill
  deriving DecidableEq, Repr

def Ink.name : Ink → String
  | .none => "none" | .bg => "bg" | .fg => "fg" | .line => "line" | .arrow => "arrow"
  | .frame => "frame" | .muted => "muted" | .actFill => "actFill"

def DiagramTheme.ink (t : DiagramTheme) : Ink → String
  | .none => "none" | .bg => t.bg | .fg => t.fg | .line => t.line | .arrow => t.arrow
  | .frame => t.frame | .muted => t.muted | .actFill => t.actFill

/-- One drawn element. A diagram is a list of these, so it can be written out as SVG text or handed
to a view as data that the view turns into SVG elements itself, never as markup. -/
inductive Shape where
  | rect (cls : String) (x y w h rx : Nat) (fill stroke : Ink)
  | line (cls : String) (x1 y1 x2 y2 : Nat) (stroke : Ink) (width dash : String) (arrow : Bool)
  | path (cls : String) (d : String) (fill stroke : Ink) (dash : String) (arrow : Bool)
  | text (cls : String) (x y : Nat) (anchor : String) (fill : Ink) (size : Nat) (bold : Bool)
      (content : String)
  deriving Repr

namespace Shape

/-- Messages are drawn thicker than frames, lifelines and dividers, so an arrow stays legible
where it passes a frame's edge. -/
def arrowWidth : String := "2.5"

private def clsAttr (c : String) : String := if c == "" then "" else s!" class=\"{c}\""
private def dashAttr (d : String) : String := if d == "" then "" else s!" stroke-dasharray=\"{d}\""
private def headAttr (a : Bool) : String := if a then " marker-end=\"url(#head)\"" else ""

def svg (t : DiagramTheme) : Shape → String
  | .rect c x y w h rx fill stroke =>
      s!"<rect{clsAttr c} x=\"{x}\" y=\"{y}\" width=\"{w}\" height=\"{h}\"" ++
      (if rx == 0 then "" else s!" rx=\"{rx}\"") ++ s!" fill=\"{t.ink fill}\" stroke=\"{t.ink stroke}\"/>"
  | .line c x1 y1 x2 y2 stroke width dash arrow =>
      s!"<line{clsAttr c} x1=\"{x1}\" y1=\"{y1}\" x2=\"{x2}\" y2=\"{y2}\" stroke=\"{t.ink stroke}\"" ++
      (if width == "" then "" else s!" stroke-width=\"{width}\"") ++ dashAttr dash ++ headAttr arrow ++ "/>"
  | .path c d fill stroke dash arrow =>
      s!"<path{clsAttr c} d=\"{d}\" fill=\"{t.ink fill}\" stroke=\"{t.ink stroke}\"" ++
      (if arrow then s!" stroke-width=\"{arrowWidth}\"" else "") ++ dashAttr dash ++ headAttr arrow ++ "/>"
  | .text c x y anchor fill size bold content =>
      -- a halo in the background colour, so a lifeline or frame edge never cuts through letters
      -- (text inside a filled box, a role's name or an action, needs none)
      s!"<text x=\"{x}\" y=\"{y}\" text-anchor=\"{anchor}\" fill=\"{t.ink fill}\" font-size=\"{size}\"" ++
      (if c == "boxed" then "" else s!" stroke=\"{t.bg}\" stroke-width=\"4\" stroke-linejoin=\"round\" paint-order=\"stroke\"") ++
      (if bold then " font-weight=\"bold\"" else "") ++ clsAttr c ++ s!">{diagramEscape content}</text>"

end Shape

namespace Diagram

structure St (R : Type) where
  y     : Nat := 70
  out   : Array Shape := #[]
  /-- Messages drawn so far, by id: sender, receiver, cause, and whether it was a reply. -/
  sent  : List (String × R × R × Option String × Bool) := []
  /-- Activation bars: request id, callee, inset, top, bottom (the lowest response so far). -/
  bars  : List (String × R × Nat × Nat × Nat) := []
  /-- Where the branch being drawn began (the last divider). -/
  branchTop : Nat := 0
  /-- The last thing drawn was a frame's tab, so a frame opening now must start lower. -/
  fresh : Bool := false
  /-- Distance between lifelines: wide enough for the widest message label. -/
  colW : Nat := 180

abbrev M (R : Type) := StateM (St R)

def minColW : Nat := 180
def maxColW : Nat := 420
def margin : Nat := 90

def xAt [DecidableEq R] (cw : Nat) (roles : List R) (r : R) : Nat :=
  margin + cw * (roles.idxOf r)

def xOf [DecidableEq R] (roles : List R) (r : R) : M R Nat := do
  return xAt (← get).colW roles r

def emit (s : Shape) : M R Unit := modify fun st => { st with out := st.out.push s }
def adv (n : Nat) : M R Unit := modify fun st => { st with y := st.y + n }
def getY : M R Nat := return (← get).y

def text (x y : Nat) (s : String) (anchor := "middle") (color := Ink.fg) (size := 12)
    (bold := false) (cls := "") : Shape :=
  .text cls x y anchor color size bold s

/-- Left and right edge of a frame at nesting depth `d`. -/
def edgesAt (cw n d : Nat) : Nat × Nat :=
  (margin - 70 + 8 * d, margin + cw * (n - 1) + 70 - 8 * d)

def edges (n d : Nat) : M R (Nat × Nat) := do
  return edgesAt (← get).colW n d

/-- The frame's pentagon tab and caption; returns nothing, draws at the current y. -/
def frameTop (n d : Nat) (op caption : String) : M R Nat := do
  -- below a frame's tab, room for the next tab; below an arrow, room so the frame's top edge
  -- never runs along the arrow
  if (← get).fresh then adv 22 else adv 14
  let y ← getY
  let (x0, _) ← edges n d
  let w := 10 + 8 * op.length
  emit (.path "" s!"M{x0} {y} h{w} v12 l-6 6 h-{w - 6} z" .bg .frame "" false)
  emit (text (x0 + 5) (y + 13) op "start" .frame 11 (bold := true))
  if caption != "" then
    emit (text (x0 + w + 8) (y + 13) s!"[{caption}]" "start" .frame 11)
  adv 8
  modify fun st => { st with fresh := true }
  return y

def frameBottom (n d top : Nat) (kind : String) : M R Unit := do
  adv 12
  let y ← getY
  let (x0, x1) ← edges n d
  emit (.rect s!"frame {kind}" x0 top (x1 - x0) (y - top) 0 .none .frame)
  adv 10

def divider (n d : Nat) (caption : String) : M R Unit := do
  adv 12
  let y ← getY
  let (x0, x1) ← edges n d
  emit (.line "" x0 y x1 y .frame "" "6 4" false)
  modify fun st => { st with branchTop := y }
  if caption != "" then emit (text (x0 + 6) (y + 13) s!"[{caption}]" "start" .frame 11)
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

def arrow [DecidableEq R] (roles : List R) (i : Interaction R) : M R Unit := do
  adv 30
  modify fun st => { st with fresh := false }
  let st ← get
  let y := st.y
  let answered := answers st i
  let reply := answered.isSome
  let x1 ← xOf roles i.src
  let x2 ← xOf roles i.dst
  let label := (match i.id with | some x => s!"{x}: " | none => "") ++ i.label ++
    (match i.route with | some r => s!" · {r}" | none => "") ++
    (match i.status with | some s => s!" · {s}" | none => "")
  let dash := if reply then "6 4" else ""
  let cls := if reply then "msg reply" else "msg"
  if x1 == x2 then
    emit (.path cls s!"M{x1} {y - 8} h40 v16 h-40" .none .arrow dash true)
    emit (text (x1 + 46) (y + 4) label "start")
  else
    emit (.line cls x1 y x2 y .arrow Shape.arrowWidth dash true)
    emit (text ((x1 + x2) / 2) (y - 6) label)
  -- a where clause goes under the arrow, so a long one cannot push the label off its arrow
  if let some g := i.guard then
    let gx := if x1 == x2 then x1 + 46 else (x1 + x2) / 2
    let anchor := if x1 == x2 then "start" else "middle"
    emit (text gx (y + (if x1 == x2 then 18 else 14)) s!"[{g.text}]" anchor .muted 11 (cls := "guard"))
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
      | none => match st.bars.reverse.find? (·.1 == r) with
        | some (_, callee, inset, top, bot) =>
            if st.branchTop ≤ bot then
              -- Several replies may answer one request in the same branch.
              { st with bars := st.bars.map fun b =>
                  if b.1 == r && b.2.2.2.1 == top && b.2.2.2.2 == bot
                  then (r, callee, inset, top, y) else b }
            else
              { st with bars := st.bars ++ [(r, callee, inset, max st.branchTop top, y)] }
        | none => st
  | none => if let some id := i.id then
      modify fun st =>
        let busy := (st.bars.filter fun b => b.2.1 == i.dst && b.2.2.2.1 == b.2.2.2.2).length
        { st with bars := st.bars ++ [(id, i.dst, busy, y, y)] }

def act [DecidableEq R] (roles : List R) (r : R) (label : String) : M R Unit := do
  adv 12
  modify fun st => { st with fresh := false }
  let y ← getY
  let x ← xOf roles r
  let w := 16 + 7 * label.length
  emit (.rect "act" (x - w / 2) y w 24 10 .actFill .arrow)
  emit (text x (y + 16) label (cls := "boxed"))
  adv 26

partial def draw [DecidableEq R] [ToString R] (roles : List R) (d : Nat) :
    Global R → M R Unit
  | .done => pure ()
  | .msg i k => do arrow roles i; draw roles d k
  | .act r l k => do act roles r l; draw roles d k
  | .var name => do
      adv 22
      let y ← getY
      let (x0, _) ← edges roles.length d
      emit (text (x0 + 8) y s!"↻ continue {name}" "start" .frame 11 (cls := "continue"))
      adv 6
  | .choice bs => do
      -- the role that sends the first message of every branch decides; the others learn the
      -- branch from what reaches them, so the caption names only the decider
      let caption := match Global.decider bs with
        | .ok r => s!"{r} decides"
        | .error _ => "race: no single role decides"
      let top ← frameTop roles.length d "alt" caption
      branches roles d bs ""
      frameBottom roles.length d top "alt"
  | .par bs k => do
      let top ← frameTop roles.length d "par" ""
      branches roles d bs ""
      frameBottom roles.length d top "par"
      draw roles d k
  | .join need bs k => do
      let top ← frameTop roles.length d "par" s!"any {need} of {bs.length}"
      branches roles d bs ""
      frameBottom roles.length d top "join"
      draw roles d k
  | .loop name body => do
      let top ← frameTop roles.length d "loop" name
      draw roles (d + 1) body
      frameBottom roles.length d top "loop"
  | .sessions body k => do
      let top ← frameTop roles.length d "loop" "one session per request"
      draw roles (d + 1) body
      frameBottom roles.length d top "sessions"
      draw roles d k
  | .box name body k => do
      let top ← frameTop roles.length d "ref" name
      draw roles (d + 1) body
      frameBottom roles.length d top "ref"
      draw roles d k
where
  branches (roles : List R) (d : Nat) (bs : List (Global R)) (cap : String) :
      M R Unit := do
    let mut firstB := true
    for b in bs do
      if !firstB then divider roles.length (d) cap
      firstB := false
      draw roles (d + 1) b

end Diagram

namespace Diagram

/-- A message's label as drawn: `id: Label · route · status`. -/
def labelText {R : Type} (i : Interaction R) : String :=
  (match i.id with | some x => s!"{x}: " | none => "") ++ i.label ++
    (match i.route with | some r => s!" · {r}" | none => "") ++
    (match i.status with | some s => s!" · {s}" | none => "")

/-- The messages of a protocol, for sizing the drawing. -/
partial def messagesOf {R : Type} : Global R → List (Interaction R)
  | .msg i k => i :: messagesOf k
  | .act _ _ k => messagesOf k
  | .choice bs => bs.flatMap messagesOf
  | .par bs k | .join _ bs k => bs.flatMap messagesOf ++ messagesOf k
  | .loop _ b => messagesOf b
  | .var _ | .done => []
  | .sessions b k | .box _ b k => messagesOf b ++ messagesOf k

/-- Lifelines far enough apart that the widest label (about 7 pixels a character at 12 pixels)
fits between neighbours, within `minColW` and `maxColW`. -/
def columnWidth {R : Type} (g : Global R) : Nat :=
  let widest := (messagesOf g).foldl (fun m i => max m (labelText i).length) 0
  max minColW (min maxColW (7 * widest + 36))

end Diagram

/-- A drawn diagram: its size and its shapes, in drawing order. -/
structure DiagramModel where
  width  : Nat
  height : Nat
  shapes : Array Shape
  deriving Repr

/-- The shapes of a sequence diagram of `g` with one lifeline per role in `roles`, in that order. -/
def Global.diagramModel [DecidableEq R] [ToString R] (g : Global R) (roles : List R)
    (title : String := "") : DiagramModel :=
  let cw := Diagram.columnWidth g
  let ((), st) := (Diagram.draw roles 0 g).run { colW := cw }
  let bottom := st.y + 30
  let width := Diagram.margin * 2 + cw * (roles.length - 1)
  let height := bottom + 40
  let heads := roles.flatMap fun r =>
    let x := Diagram.xAt cw roles r
    let name := toString r
    let w := 24 + 8 * name.length
    [ Shape.rect "role" (x - w / 2) 20 w 28 4 .actFill .fg, Diagram.text x 39 name (cls := "boxed")
    , Shape.rect "role" (x - w / 2) bottom w 28 4 .actFill .fg, Diagram.text x (bottom + 19) name (cls := "boxed")
    , Shape.line "lifeline" x 48 x bottom .line "" "4 4" false ]
  let bars := st.bars.filterMap fun (_, r, inset, top, bot) =>
    if bot ≤ top then none else
    some (Shape.rect "activation" (Diagram.xAt cw roles r - 5 + 7 * inset) top 10 (bot - top) 0 .actFill .arrow)
  let titleEl := if title == "" then [] else [Diagram.text 10 14 title "start" .muted 11]
  { width, height, shapes := (titleEl ++ heads ++ bars).toArray ++ st.out }

/-- The model written out as SVG text in a theme. -/
def DiagramModel.svg (m : DiagramModel) (t : DiagramTheme := .dark) : String :=
  s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{m.width}\" height=\"{m.height}\" viewBox=\"0 0 {m.width} {m.height}\" font-family=\"ui-sans-serif, system-ui, sans-serif\">" ++
  s!"<defs><marker id=\"head\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerUnits=\"userSpaceOnUse\" markerWidth=\"12\" markerHeight=\"12\" orient=\"auto-start-reverse\"><path d=\"M0 0 L10 5 L0 10 z\" fill=\"{t.arrow}\"/></marker></defs>" ++
  s!"<rect width=\"100%\" height=\"100%\" fill=\"{t.bg}\"/>" ++
  String.join (m.shapes.toList.map (Shape.svg t)) ++ "</svg>"

/-- An SVG sequence diagram of `g` with one lifeline per role in `roles`, in that order. -/
def Global.diagram [DecidableEq R] [ToString R] (g : Global R) (roles : List R)
    (theme : DiagramTheme := .dark) (title : String := "") : String :=
  (g.diagramModel roles title).svg theme

end LeanFM.Session
