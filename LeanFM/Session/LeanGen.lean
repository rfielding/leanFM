import LeanFM.Session.Calls
import LeanFM.Session.Types

/-!
# The session as a Lean module (clause selfhost.session.lean)

`Global.leanModule` writes, for one global session type, the Lean module an implementation or a
proof works with: the message structures (from the protocol's `.proto` or its structures), the
roles as an inductive type, the payload as an inductive type with one constructor per message and
per event, the event envelope, and for each role its states as an inductive type with `start`,
`step : State -> Event -> Option State`, `final` and `accepts`. The states are the role's
typestate states; a step exists exactly where the projection allows the event, so the module is
the protocol's transition system over typed events.

Negative requirements: a role whose projection fails, a projection with `par`, `join` or
`sessions` (whose states are not single machines; they are refused with that reason), two
transitions from one state on one event to different states, and names that collide after being
made Lean identifiers are errors, not guesses. Labels and roles reach the code only as Lean
identifiers (quoted with « » where they are keywords).
-/

namespace LeanFM.Session
namespace LeanGen
open Typestate

/-- Lean words a generated name may not be without quoting. -/
def keywords : List String :=
  [ "at", "by", "class", "def", "deriving", "do", "else", "end", "example", "false", "for", "from",
    "fun", "have", "if", "import", "in", "inductive", "instance", "let", "match", "mut", "namespace",
    "open", "Prop", "return", "show", "Sort", "structure", "then", "theorem", "true", "Type",
    "universe", "variable", "where", "with", "final", "start", "step", "accepts", "involves" ]

/-- A name as a Lean identifier starting lower case: `CreateOrder` is `createOrder`. -/
def lower (s : String) : String :=
  let cs := s.toList.map fun c => if (c.isAlphanum || c == '_') && c.toNat < 128 then c else '_'
  let t := match cs with
    | c :: rest => String.ofList (c.toLower :: rest)
    | [] => "_"
  let t := if (t.toList.head?.map Char.isDigit).getD false then "_" ++ t else t
  if keywords.contains t then "«" ++ t ++ "»" else t

/-- A name as a Lean type name: `PlaceOrder`, or quoted. -/
def upper (s : String) : String :=
  if Types.isAsciiIdent s && !keywords.contains s then s else "«" ++ s.replace "»" "" ++ "»"

def stateName (s : String) : Except String String :=
  if s == "End" then pure "done"
  else if s.startsWith "S" then pure ("s" ++ (s.drop 1).toString)
  else throw s!"state {s} is not resolved"

/-- A transition of one role's machine: the event that takes it (sender, receiver, label) and where. -/
structure Edge where
  src : String
  dst : String
  label : String
  next : String

/-- The transitions and finality of every state, with steps that take no event followed through. -/
partial def closure (ms : List (Nat × Method String)) (role : String) (s : String) (seen : List String := []) :
    Except String (List Edge × Bool) := do
  if s == "End" then return ([], true)
  if seen.contains s then return ([], false)
  let here := ms.filter (fun (i, _) => nm i == s) |>.map (·.2)
  let mut edges : List Edge := []
  let mut final := false
  for m in here do
    match m with
    | .send to l k => edges := edges ++ [{ src := role, dst := to, label := l, next := k }]
    | .recv fr l k => edges := edges ++ [{ src := fr, dst := role, label := l, next := k }]
    | .act l k => edges := edges ++ [{ src := role, dst := role, label := l, next := k }]
    | .offer alts =>
      for a in alts do
        match a with
        | .recv fr l k => edges := edges ++ [{ src := fr, dst := role, label := l, next := k }]
        | .nothing => final := true
        | .other k =>
          let (es, f) ← closure ms role k (s :: seen)
          edges := edges ++ es; final := final || f
    | .cont k =>
      let (es, f) ← closure ms role k (s :: seen)
      edges := edges ++ es; final := final || f
    | .stop => final := true
    | .fork .. => throw s!"{role}: its projection runs branches in parallel (par or join), whose states are not one machine; Lean states are generated for sequential roles"
    | .serve .. => throw s!"{role}: its projection serves sessions, whose states are not one machine; Lean states are generated for sequential roles"
  return (edges, final)

end LeanGen

open LeanGen in
/-- The protocol as a Lean module: message structures, roles, payload, event envelope, and each
role's states with its step function. -/
def Global.leanModule (g : Global String) (name : String) (roles : List String) (types : Types.Env) : Except String String := do
  let labels := (g.messages.map (·.label)).eraseDups
  let acts := g.labels.eraseDups.filter (!labels.contains ·)
  let ms ← Types.complete types labels
  let structs := ms.map fun m =>
    let doc := if m.doc.isEmpty then [] else [s!"/-- {m.doc} -/"]
    "\n".intercalate (doc ++ (if m.fields.isEmpty then [s!"structure {upper m.name}"]
      else [s!"structure {upper m.name} where"] ++ m.fields.map (fun f => s!"  {f.name} : {f.ty.render}")) ++
      ["  deriving Repr, BEq, Lean.ToJson, Lean.FromJson"])
  let ctors := labels.map lower ++ acts.map lower
  if ctors.eraseDups.length != ctors.length then throw "two labels have the same Lean constructor name"
  let roleNames := roles.map lower
  if roleNames.eraseDups.length != roleNames.length then throw "two roles have the same Lean name"
  let role (r : String) : String := "." ++ lower r
  let payload := ["/-- What an event carries: one message of the protocol, or an event a role performs alone. -/",
    "inductive Payload where"] ++ labels.map (fun l => s!"  | {lower l} (m : {upper l})") ++
    acts.map (fun a => s!"  | {lower a}") ++ ["  deriving Repr, BEq"]
  let mut machines : List String := []
  for r in roles do
    let l ← match g.project r with
      | .ok l => pure l
      | .error e => throw s!"{r} has no projection: {e}"
    let (start, ms') := l.machine
    let states := ((ms'.map fun (p : Nat × Method String) => Typestate.nm p.1) ++ [start]).eraseDups
    let mut cases : List String := []
    let mut finals : List String := []
    for s in states do
      let (edges, final) ← closure ms' r s
      let sn ← stateName s
      if final then finals := finals ++ [sn]
      for e in edges do
        if edges.any (fun e' => e'.src == e.src && e'.dst == e.dst && e'.label == e.label && e'.next != e.next) then
          throw s!"{r}: in {s}, {e.label} from {e.src} to {e.dst} leads to two states"
      for e in (edges.foldl (fun acc e => if acc.any (fun x => x.src == e.src && x.dst == e.dst && x.label == e.label) then acc else acc ++ [e]) []) do
        let arg := if labels.contains e.label then " _" else ""
        cases := cases ++ [s!"  | .{sn}, \{ src := {role e.src}, dst := {role e.dst}, payload := .{lower e.label}{arg}, .. } => some .{← stateName e.next}"]
    let stateCtors := ((states.filterMap fun st => (stateName st).toOption) ++ ["done"]).eraseDups
    let finalCtors := (finals ++ ["done"]).eraseDups
    machines := machines ++ ["\n".intercalate ([
      s!"/-! {r}: its states, the typestate states of its projection. -/",
      s!"namespace {upper r}", "",
      "inductive State where"] ++ stateCtors.map (fun c => s!"  | {c}") ++ ["  deriving Repr, BEq, DecidableEq", "",
      s!"def start : State := .{← stateName start}", "",
      s!"/-- The step an event takes {r} from a state, where the protocol allows it. -/",
      "def step : State → Event → Option State"] ++ cases ++ ["  | _, _ => none", "",
      "/-- Whether the session may end here. -/",
      "def final : State → Bool"] ++ finalCtors.map (fun f => s!"  | .{f} => true") ++ ["  | _ => false", "",
      s!"/-- The events {r} takes part in. -/",
      s!"def involves (e : Event) : Bool := e.src == {role r} || e.dst == {role r}", "",
      s!"/-- Whether one session's events, in order, are a complete run of {r}. -/",
      "def accepts (evs : List Event) : Bool :=",
      "  match (evs.filter involves).foldlM step start with",
      "  | some s => final s",
      "  | none => false", "",
      s!"end {upper r}"])]
  let ns := upper name
  return "\n".intercalate ([
    "import Lean.Data.Json", "",
    s!"/-! Generated by LeanFM from protocol {name} and its message types; regenerate it rather than editing.",
    "The message structures are the payload types; each role's states and `step` are the protocol's transition",
    "system over typed events (selfhost.session.lean). -/", "", s!"namespace {ns}", "", "\n\n".intercalate structs, "",
    "/-- The roles. -/", "inductive Role where"] ++ roleNames.map (fun r => s!"  | {r}") ++
    ["  deriving Repr, BEq, DecidableEq", ""] ++ payload ++ ["",
    "/-- The event envelope (selfhost.session.envelope): ts in nanoseconds, unique in its stream. -/",
    "structure Event where", "  ts : Nat", "  session : String", "  src : Role", "  dst : Role",
    "  cause : Option Nat := none", "  prev : Option Nat := none", "  payload : Payload", "  deriving Repr, BEq", "",
    "\n\n".intercalate machines, "", s!"end {ns}", ""])

end LeanFM.Session
