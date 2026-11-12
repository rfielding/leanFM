import Lean.Data.Json
import LeanFM.Session.Global
import LeanFM.Session.Http
import LeanFM.Session.Diagram
import LeanFM.Session.Calls
import LeanFM.Session.Events
import LeanFM.Session.Text
import LeanFM.Session.Generative
import LeanFM.Session.Decision
import LeanFM.Session.Chain
import LeanFM.Session.Conform
import LeanFM.Session.Skeleton
import LeanFM.Session.SkeletonTs
import LeanFM.Session.Evolution
import LeanFM.Session.OpenApi
import LeanFM.Session.Review
import LeanFM.Logic

/-!
# Session-type tools for MCP agents (clauses selfhost.mcp.session.tools, selfhost.mcp.session.view)

`session_check`, `session_diagram` and `session_simulate` take a protocol in a closed JSON form,
build the same `Global String` the `protocol` command builds, and answer with the session library:
issues, projections, calls, typestate, the diagram as shapes and SVG, and seeded event streams.

A protocol is data: no field carries code, a guard's `where` text is shown but never evaluated,
and every size is bounded. Errors name the step that caused them.
-/

namespace LeanFM.SessionTools
open Lean
open LeanFM.Session

/-! ## Bounds -/

structure Limits where
  maxSteps     : Nat := 200
  maxDepth     : Nat := 24
  maxRoles     : Nat := 12
  maxBranches  : Nat := 16
  maxString    : Nat := 200
  maxInstances : Nat := 200
  maxEvents    : Nat := 600
  maxLoops     : Nat := 8
  maxSpread    : Nat := 5000
  maxArgumentBytes : Nat := 65536
  /-- results are kept under this many characters (the host's limit is 100,000) -/
  maxResult    : Nat := 90000
  deriving Repr

def limits : Limits := {}

def limitsJson : Json :=
  Json.mkObj [("maxSteps", toJson limits.maxSteps), ("maxDepth", toJson limits.maxDepth),
    ("maxRoles", toJson limits.maxRoles), ("maxBranches", toJson limits.maxBranches),
    ("maxString", toJson limits.maxString), ("maxInstances", toJson limits.maxInstances),
    ("maxEvents", toJson limits.maxEvents), ("maxLoops", toJson limits.maxLoops),
    ("maxSpread", toJson limits.maxSpread)]

/-! ## The JSON form -/

def stepKinds : List String := ["msg", "event", "choice", "par", "join", "rec", "continue", "sessions", "include"]

def allowedKeys : String → List String
  | "msg" => ["msg", "from", "to", "id", "cause", "route", "status", "where"]
  | "event" => ["event", "at"]
  | "choice" => ["choice"]
  | "par" => ["par"]
  | "join" => ["join", "of"]
  | "rec" => ["rec", "steps"]
  | "continue" => ["continue"]
  | "sessions" => ["sessions"]
  | "include" => ["include", "steps"]
  | _ => []

structure Ctx where
  roles : List String
  loops : List String := []
  depth : Nat := 0
  path  : String := "steps"

abbrev P := StateT Nat (Except String)

def fail (c : Ctx) (msg : String) : P α := throw s!"{c.path}: {msg}"

def keysOf (j : Json) : List String :=
  match j with
  | .obj kvs => kvs.toList.map (·.1)
  | _ => []

def checkString (c : Ctx) (what s : String) : P String := do
  if s.isEmpty then fail c s!"{what} is empty"
  if s.length > limits.maxString then fail c s!"{what} is longer than {limits.maxString} characters"
  if s.toList.any (fun (ch : Char) => ch.toNat < 32) then fail c s!"{what} contains a control character"
  return s

def reqString (c : Ctx) (j : Json) (key : String) : P String := do
  match j.getObjValAs? String key with
  | .ok s => checkString c key s
  | .error _ => fail c s!"{key} must be a string"

def optString (c : Ctx) (j : Json) (key : String) : P (Option String) := do
  match j.getObjVal? key with
  | .error _ => return none
  | .ok v => match v.getStr? with
    | .ok s => return some (← checkString c key s)
    | .error _ => fail c s!"{key} must be a string"

def role (c : Ctx) (j : Json) (key : String) : P String := do
  let r ← reqString c j key
  if !c.roles.contains r then fail c s!"{key} names {r}, which is not one of the roles {c.roles}"
  return r

def tick (c : Ctx) : P Unit := do
  let n ← get
  if n + 1 > limits.maxSteps then fail c s!"the protocol has more than {limits.maxSteps} steps"
  set (n + 1)

def branchLists (c : Ctx) (j : Json) (key : String) : P (List (List Json)) := do
  let arr ← match j.getObjVal? key with
    | .ok (.arr a) => pure a.toList
    | _ => fail c s!"{key} must be an array of branches, each an array of steps"
  if arr.isEmpty then fail c s!"{key} has no branches"
  if arr.length > limits.maxBranches then fail c s!"{key} has more than {limits.maxBranches} branches"
  arr.mapM fun b => match b with
    | .arr steps => pure steps.toList
    | _ => fail c s!"each branch of {key} must be an array of steps"

def stepList (c : Ctx) (j : Json) (key : String) : P (List Json) := do
  match j.getObjVal? key with
  | .ok (.arr a) => pure a.toList
  | _ => fail c s!"{key} must be an array of steps"

mutual
partial def steps (c : Ctx) (js : List Json) (index : Nat := 0) : P (Global String) := do
  match js with
  | [] => return .done
  | j :: rest =>
    let list := c
    let c := { c with path := s!"{c.path}[{index}]" }
    tick c
    let keys := keysOf j
    if keys.isEmpty then fail c "a step must be an object with one of the keys msg, event, choice, par, join, rec, continue, sessions, include"
    let kinds := keys.filter stepKinds.contains
    let kind ← match kinds with
      | [k] => pure k
      | [] => fail c s!"unknown step with keys {keys}; a step has exactly one of {stepKinds}"
      | ks => fail c s!"a step has exactly one kind, not {ks}"
    let extra := keys.filter (!(allowedKeys kind).contains ·)
    if !extra.isEmpty then fail c s!"{kind} step has unknown keys {extra}; allowed: {allowedKeys kind}"
    let next := fun () => steps list rest (index + 1)
    match kind with
    | "msg" =>
        let label ← reqString c j "msg"
        let src ← role c j "from"
        let dst ← role c j "to"
        let id ← optString c j "id"
        let cause ← optString c j "cause"
        let route ← optString c j "route"
        let status ← match j.getObjVal? "status" with
          | .error _ => pure none
          | .ok v => match v.getNat? with
            | .ok n => if n ≤ 999999 then pure (some n) else fail c "status is too large"
            | .error _ => fail c "status must be a natural number"
        let guardText ← optString c j "where"
        -- a where clause in the JSON form is text only: it is shown, never evaluated
        let guard := guardText.map fun t => ({ text := t, eval := fun _ => none } : Guard)
        let i : Interaction String := { id, label, src, dst, cause, status, route, guard }
        return .msg i (← next ())
    | "event" =>
        let label ← reqString c j "event"
        let r ← role c j "at"
        return .act r label (← next ())
    | "choice" =>
        let bs ← branches c j "choice"
        return Global.andThen (.choice bs) (← next ())
    | "par" =>
        let bs ← branches c j "par"
        return .par bs (← next ())
    | "join" =>
        let n ← match j.getObjVal? "join" with
          | .ok v => match v.getNat? with | .ok n => pure n | .error _ => fail c "join must be a number"
          | .error _ => fail c "join must be a number"
        let bs ← branches c j "of"
        if n == 0 || n > bs.length then fail c s!"join {n} of {bs.length} branches is out of range"
        return .join n bs (← next ())
    | "rec" =>
        let name ← reqString c j "rec"
        let body ← nested { c with loops := name :: c.loops } (← stepList c j "steps") "steps"
        return Global.andThen (.loop name body) (← next ())
    | "continue" =>
        let name ← reqString c j "continue"
        if !c.loops.contains name then fail c s!"continue {name} is not inside rec {name}"
        if !rest.isEmpty then fail c s!"continue {name} must be the last step of its branch"
        return .var name
    | "sessions" =>
        let body ← nested c (← stepList c j "sessions") "sessions"
        return .sessions body (← next ())
    | "include" =>
        let name ← reqString c j "include"
        let body ← nested c (← stepList c j "steps") "steps"
        return .box name body (← next ())
    | k => fail c s!"unknown step kind {k}"

partial def nested (c : Ctx) (js : List Json) (key : String) : P (Global String) := do
  if c.depth + 1 > limits.maxDepth then fail c s!"steps are nested more than {limits.maxDepth} deep"
  steps { c with depth := c.depth + 1, path := s!"{c.path}.{key}" } js

partial def branches (c : Ctx) (j : Json) (key : String) : P (List (Global String)) := do
  let bs ← branchLists c j key
  let mut out := []
  let mut i := 0
  for b in bs do
    out := out ++ [← nested { c with path := s!"{c.path}.{key}[{i}]" } b "steps"]
    i := i + 1
  return out
end

/-- A protocol: its name, roles in lifeline order, and the global type. -/
structure Protocol where
  name  : String
  roles : List String
  global : Global String
  steps : Nat
  /-- the protocol as LeanFM protocol text: the text sent, or the JSON form written out -/
  lean  : String
  generative : Option Generative.Resolved := none

/-! ## The JSON form written as protocol text -/

namespace ToText
open LeanFM.Session.Text

abbrev W := StateM (List Def)

def str (j : Json) (k : String) : Option String := (j.getObjValAs? String k).toOption

mutual
partial def stmts (roles : List String) (js : List Json) : W (List Stmt) := js.mapM (stmt roles)

partial def branchesOf (roles : List String) (j : Json) (k : String) : W (List (List Stmt)) :=
  match j.getObjVal? k with
  | .ok (.arr a) => a.toList.mapM fun b => match b with
    | .arr steps => stmts roles steps.toList
    | _ => pure []
  | _ => pure []

partial def listOf (roles : List String) (j : Json) (k : String) : W (List Stmt) :=
  match j.getObjVal? k with
  | .ok (.arr a) => stmts roles a.toList
  | _ => pure []

partial def stmt (roles : List String) (j : Json) : W Stmt := do
  if let some l := str j "msg" then
    return .msg (str j "id") l ((str j "from").getD "") ((str j "to").getD "") (str j "cause") (str j "route")
      ((j.getObjVal? "status").toOption.bind (·.getNat?.toOption)) (str j "where")
  if let some l := str j "event" then return .event l ((str j "at").getD "")
  if (j.getObjVal? "choice").isOk then return .choice (← branchesOf roles j "choice")
  if (j.getObjVal? "par").isOk then return .par (← branchesOf roles j "par")
  if let .ok v := j.getObjVal? "join" then
    return .join (v.getNat?.toOption.getD 1) (← branchesOf roles j "of")
  if let some n := str j "rec" then return .loop n (← listOf roles j "steps")
  if let some n := str j "continue" then return .cont n
  if (j.getObjVal? "sessions").isOk then return .sessions (← listOf roles j "sessions")
  if let some n := str j "include" then
    -- an included protocol becomes a protocol of its own over the same roles, written before
    let body ← listOf roles j "steps"
    modify fun ds => if ds.any (·.name == n) then ds else ds ++ [{ name := n, roles, body }]
    return .incl n roles
  return .event "?" ""
end

def write (name : String) (roles : List String) (steps : List Json) : String :=
  let (body, defs) := (stmts roles steps).run []
  LeanFM.Session.Text.write (defs ++ [{ name, roles, body }])

end ToText

def generativeLayer (body : List Text.Stmt) (roles : List String) (args : Json) : Except String (Option Generative.Resolved) := do
  let r ← Generative.resolve body ((args.getObjVal? "overlay").toOption.filter (· != Json.null))
  if !r.active then return none
  match Generative.compile r roles with
  | .ok _ => return some r
  | .error e =>
    -- constructs the tree and the simulator cannot run, but the chain can: keep the layer, say why
    if e.startsWith "timed generation/monitoring supports" || e.startsWith "accrue needs the chain view" ||
       e.startsWith "after on an event" then
      return some { r with metadata := Json.mkObj [("layer", r.metadata), ("executionUnsupported", e)] }
    throw e

def generativeJson (p : Protocol) : Json := (p.generative.map (·.metadata)).getD Json.null

def parseProtocol (args : Json) : Except String Protocol := do
  if args.compress.length > limits.maxArgumentBytes then
    throw s!"arguments exceed {limits.maxArgumentBytes} bytes"
  if let .ok v := args.getObjVal? "lean" then
    let text ← match v.getStr? with
      | .ok t => pure t
      | .error _ => throw "lean must be a string of LeanFM protocol text"
    let r ← LeanFM.Session.Text.parse text
    return { name := r.name, roles := r.roles, global := r.global, steps := r.steps, lean := text, generative := ← generativeLayer r.body r.roles args }
  let p ← match args.getObjVal? "protocol" with
    | .ok p => pure p
    | .error _ => throw "lean is required: LeanFM protocol text such as protocol Ping (A, B) { p: Ping from A to B; Pong from B to A cause p; }; read leanfm://language/session-reference"
  if p.getStr?.isOk then
    throw "protocol is the JSON form {name?, roles, steps}; put LeanFM protocol text in lean instead"
  let extra := (keysOf p).filter (!["name", "roles", "steps"].contains ·)
  if !extra.isEmpty then throw s!"protocol has unknown keys {extra}; allowed: name, roles, steps"
  let name := (p.getObjValAs? String "name").toOption.getD "Protocol"
  if name.length > limits.maxString then throw "protocol name is too long"
  let roles ← match p.getObjVal? "roles" with
    | .ok (.arr a) => a.toList.mapM fun r => match r.getStr? with
      | .ok s => if s.isEmpty || s.length > limits.maxString || s.toList.any (fun (ch : Char) => ch.toNat < 32)
                 then .error s!"role name {s.quote} is empty, too long or has a control character"
                 else .ok s
      | .error _ => .error "every role must be a string"
    | _ => throw "roles must be an array of role names"
  if roles.isEmpty then throw "a protocol needs at least one role"
  if roles.length > limits.maxRoles then throw s!"a protocol has at most {limits.maxRoles} roles"
  if roles.eraseDups.length != roles.length then throw "role names must be distinct"
  let js ← match p.getObjVal? "steps" with
    | .ok (.arr a) => pure a.toList
    | _ => throw "steps must be an array of steps"
  let (global, count) ← (steps { roles } js).run 0
  let text := ToText.write name roles js
  let parsed ← Text.parse text
  return { name, roles, global, steps := count, lean := text, generative := ← generativeLayer parsed.body roles args }

/-! ## Results -/

partial def callJson : Call String → Json
  | ⟨r, responses, nested⟩ =>
    Json.mkObj
      [ ("id", toJson r.id), ("label", r.label), ("from", r.src), ("to", r.dst)
      , ("route", toJson r.route)
      , ("responses", Json.arr (responses.map fun x => Json.mkObj
          [("label", x.label), ("status", toJson x.status)]).toArray)
      , ("nested", Json.arr (nested.map callJson).toArray) ]

def shapeJson : Shape → Json
  | .rect c x y w h rx fill stroke => Json.mkObj [("k", "rect"), ("cls", c), ("x", x), ("y", y),
      ("w", w), ("h", h), ("rx", rx), ("fill", fill.name), ("stroke", stroke.name)]
  | .line c x1 y1 x2 y2 stroke width dash arrow => Json.mkObj [("k", "line"), ("cls", c), ("x1", x1),
      ("y1", y1), ("x2", x2), ("y2", y2), ("stroke", stroke.name), ("width", width), ("dash", dash),
      ("arrow", arrow)]
  | .path c d fill stroke dash arrow => Json.mkObj [("k", "path"), ("cls", c), ("d", d),
      ("fill", fill.name), ("stroke", stroke.name), ("dash", dash), ("arrow", arrow)]
  | .text c x y anchor fill size bold content => Json.mkObj [("k", "text"), ("cls", c), ("x", x),
      ("y", y), ("anchor", anchor), ("fill", fill.name), ("size", size), ("bold", bold),
      ("text", content)]

/-! ## Annotations on the sequence diagram: probabilities, amounts, delays, expected counts -/

namespace Annotate
open LeanFM.Session.Text

def tag : String := "\u0001"

def timeNote (t : Generative.TimeExpr) : String :=
  match t.period with
  | some d => s!"at next {Chain.periodText d}"
  | none =>
    if t.relative then
      match t.offsets with
      | [(d, _)] => s!"after {Chain.daysText (d : Nat)}"
      | os => "after " ++ " or ".intercalate (os.map fun (d, q) => s!"{Chain.daysText (d : Nat)} ({q.text})")
    else ((Text.timeText t).drop 1).toString

def amountNote (a : Generative.Amount) : String :=
  let sign := if a.reverse then "-" else ""
  match a.outcomes with
  | [(n, _)] => s!"{sign}{n} {a.unit}"
  | os => sign ++ " or ".intercalate (os.map fun (n, q) => s!"{n} ({q.text})") ++ s!" {a.unit}"

abbrev TagM := StateM (Array String)

/-- `orig`'s time and amount wrappers around `inner`. -/
partial def rewrap (orig inner : Text.Stmt) : Text.Stmt :=
  match orig with
  | .timed t m => .timed t (rewrap m inner)
  | .valued a m => .valued a (rewrap m inner)
  | _ => inner

/-- Tag each message and event with its position (label ++ tag ++ index) and record its annotation;
`pending` is a branch's probability, written on the branch's first step. -/
partial def tagStmts (pending : Option String) : List Text.Stmt → TagM (List Text.Stmt)
  | [] => pure []
  | s :: rest => do
    let (s', used) ← tagStmt pending s
    let rest' ← tagStmts (if used then none else pending) rest
    return s' :: rest'
where
  tagStmt (pending : Option String) (s : Text.Stmt) : TagM (Text.Stmt × Bool) := do
    let (core, amounts, time) := Chain.peel s
    match core with
    | .msg .. | .event .. =>
      let k := (← get).size
      let note := " · ".intercalate (pending.toList ++ amounts.map amountNote ++ (time.map timeNote).toList)
      modify (·.push note)
      let tagged := match core with
        | .msg id label src dst cause route status guard => Text.Stmt.msg id (label ++ tag ++ toString k) src dst cause route status guard
        | .event label role => .event (label ++ tag ++ toString k) role
        | other => other
      -- the annotations wrap the tagged step again, in the order the parser wrote them
      return (rewrap s tagged, true)
    | _ => match s with
      | .weighted name actor qs bs => do
        let bs' ← (bs.zipIdx).mapM fun (b, i) => tagStmts ((qs[i]?).map (s!"p {·.text}")) b
        return (.weighted name actor qs bs', false)
      | .choice bs => return (.choice (← bs.mapM (tagStmts none)), false)
      | .par bs => return (.par (← bs.mapM (tagStmts none)), false)
      | .join n bs => return (.join n (← bs.mapM (tagStmts none)), false)
      | .loop name body => do
        let b ← tagStmts pending body
        return (.loop name b, pending.isSome)
      | .sessions body => return (.sessions (← tagStmts none body), false)
      | other => return (other, false)

def untag (label : String) : String × Option Nat :=
  match label.splitOn tag with
  | [base, k] => (base, k.toNat?)
  | _ => (label, none)

/-- The tags in drawing order (the order Diagram.draw visits messages and events), and the global
type with the tags removed. -/
partial def strip : Global String → List Nat × Global String
  | .msg i k => let (base, t) := untag i.label; let (ts, k') := strip k; (t.toList ++ ts, .msg { i with label := base } k')
  | .act r l k => let (base, t) := untag l; let (ts, k') := strip k; (t.toList ++ ts, .act r base k')
  | .choice bs => let rs := bs.map strip; (rs.flatMap (·.1), .choice (rs.map (·.2)))
  | .par bs k => let rs := bs.map strip; let (ts, k') := strip k; (rs.flatMap (·.1) ++ ts, .par (rs.map (·.2)) k')
  | .join n bs k => let rs := bs.map strip; let (ts, k') := strip k; (rs.flatMap (·.1) ++ ts, .join n (rs.map (·.2)) k')
  | .loop name b => let (ts, b') := strip b; (ts, .loop name b')
  | .sessions b k => let (ts, b') := strip b; let (ts2, k') := strip k; (ts ++ ts2, .sessions b' k')
  | .box name b k => let (ts, b') := strip b; let (ts2, k') := strip k; (ts ++ ts2, .box name b' k')
  | g => ([], g)

end Annotate

/-- The sequence diagram, annotated when the protocol carries probabilities, amounts or times:
under each arrow its branch's probability, its amounts, its delay and, when the session's chain can
be solved, its expected count per session. Without annotations, the plain diagram. -/
def annotatedModel (p : Protocol) : DiagramModel := Id.run do
  let some layer := p.generative | return p.global.diagramModel p.roles p.name
  let (tagged, notes) := (Annotate.tagStmts none layer.body).run #[]
  if notes.all (· == "") then return p.global.diagramModel p.roles p.name
  let .ok g := Text.buildWith p.lean tagged | return p.global.diagramModel p.roles p.name
  -- expected counts and totals from the chain, when it can be solved without a horizon
  let chain := (Chain.analyse { layer with body := tagged }).toOption
  let counts : Array String := match chain with
    | some c => (List.range notes.size).toArray.map fun k =>
        let t := c.edges.foldl (fun acc e => if (Annotate.untag e.step).2 == some k then acc + Chain.traversals c e else acc) 0
        s!"×{Chain.ratText t}"
    | none => #[]
  -- the legend comes from the untagged chain, so no position tag reaches the reader
  let footer : List String := match (Chain.analyse layer).toOption with
    | some c =>
      let d := Chain.expectedDuration c
      Chain.legend c p.roles ++ (if d == 0 then [] else [s!"Expected duration per session: {Chain.daysText d}"])
    | none => []
  let full := (List.range notes.size).toArray.map fun k =>
    " · ".intercalate (([notes[k]!] ++ (counts[k]?).toList).filter (· != ""))
  let (order, plain) := Annotate.strip g
  return plain.diagramModel p.roles p.name (order.toArray.map fun k => (full[k]?).getD "") footer

def diagramJson (p : Protocol) : Json :=
  let m := annotatedModel p
  Json.mkObj [("width", m.width), ("height", m.height),
    ("shapes", Json.arr (m.shapes.map shapeJson))]

def themeOf (args : Json) : DiagramTheme :=
  match (args.getObjValAs? String "theme").toOption with
  | some "light" => .light
  | _ => .dark

def eventJson (e : Event String) : Json :=
  Json.mkObj [("id", e.id), ("session", e.session), ("time", e.time),
    ("prior", Json.arr (e.prior.map toJson).toArray), ("cause", toJson e.cause),
    ("answers", toJson e.answers), ("src", e.src), ("dst", e.dst), ("label", e.label),
    ("msgId", toJson e.msgId), ("route", toJson e.route), ("status", toJson e.status),
    ("act", e.isAct)]

def messageCount (g : Global String) : Nat := g.messages.length

/-- Channels that are not HTTP (a text message, a queue): `notHttp: [[a, b], ...]`. -/
def notHttpPairs (args : Json) : Except String (List (String × String)) := do
  match args.getObjVal? "notHttp" with
  | .error _ | .ok .null => pure []
  | .ok (.arr a) => a.toList.mapM fun p => match p with
      | .arr #[.str x, .str y] => pure (x, y)
      | _ => throw "notHttp must be an array of [role, role] pairs"
  | .ok _ => throw "notHttp must be an array of [role, role] pairs"

def mayCallPairs (args : Json) : Except String (Option (List (String × String))) := do
  match args.getObjVal? "mayCall" with
  | .error _ => return none
  | .ok (.arr a) =>
      let pairs ← a.toList.mapM fun p => match p with
        | .arr #[.str x, .str y] => .ok (x, y)
        | _ => .error "mayCall must be an array of [caller, callee] pairs"
      return some pairs
  | .ok _ => throw "mayCall must be an array of [caller, callee] pairs"

/-- The answer kept under the result limit: the SVG goes first, then the shapes, then events from
the end, each omission said in `omitted`. -/
def fit (body : Json) : Json := Id.run do
  let mut b := body
  let mut omitted : List String := []
  for key in ["svg", "diagram"] do
    if b.compress.length > limits.maxResult then
      b := b.setObjVal! key Json.null
      omitted := omitted ++ [key]
  if b.compress.length > limits.maxResult then
    if let .ok (.arr evs) := b.getObjVal? "events" then
      let mut n := evs.size
      while n > 0 && (b.setObjVal! "events" (Json.arr (evs.extract 0 n))).compress.length > limits.maxResult do
        n := n / 2
      b := b.setObjVal! "events" (Json.arr (evs.extract 0 n))
      omitted := omitted ++ [s!"events after the first {n}"]
  if omitted.isEmpty then b else b.setObjVal! "omitted" (Json.arr (omitted.map Json.str).toArray)

def check (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let g := p.global
  let issues := g.issues p.roles
  let calls ← mayCallPairs args
  let plain ← notHttpPairs args
  -- every channel is HTTP except those between the roles of a notHttp pair (either direction)
  let isHttp (a b : String) : Bool := !(plain.contains (a, b) || plain.contains (b, a))
  let cuts := match calls with
    | some pairs => g.httpCuts isHttp (fun a b => pairs.contains (a, b))
    | none => []
  let projections := p.roles.map fun r => (r, match g.project r with
    | .ok l => Json.mkObj [("local", l.render), ("typestate", l.typestate)]
    | .error e => Json.mkObj [("error", e)])
  let problems := issues ++ cuts
  let verdict := if problems.isEmpty then "ok" else "issues"
  let reading := if problems.isEmpty
    then s!"{p.name}: no issues; {p.roles.length} roles, {messageCount g} messages, {g.calls.length} top-level calls"
    else s!"{p.name}: {problems.length} issue{if problems.length == 1 then "" else "s"}: {problems.head!}"
  return fit <| Json.mkObj
    [ ("tool", "session_check"), ("verdict", verdict), ("reading", reading), ("name", p.name)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol"), ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p)
    , ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("issues", Json.arr (issues.map Json.str).toArray)
    , ("httpCuts", match calls with | some _ => Json.arr (cuts.map Json.str).toArray | none => Json.null)
    , ("projections", Json.mkObj projections)
    , ("calls", Json.arr (g.calls.map callJson).toArray)
    , ("callsText", g.callsText)
    , ("diagram", diagramJson p)
    , ("limits", limitsJson) ]

def diagram (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let m := annotatedModel p
  return fit <| Json.mkObj
    [ ("tool", "session_diagram"), ("verdict", "drawn")
    , ("reading", s!"{p.name}: sequence diagram of {messageCount p.global} messages across {p.roles.length} lifelines")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol"), ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p)
    , ("svg", m.svg (themeOf args)), ("diagram", diagramJson p) ]

/-- Whether the statements need the chain: a loop (rec), which the tree cannot unfold, or an accrual
or event delay, which accrue over time spent in states. -/
partial def hasLoop : List Text.Stmt → Bool
  | [] => false
  | s :: rest => (match s with
    | .loop .. | .accrue .. | .timed _ (.event ..) => true
    | .timed t _ => t.period.isSome
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.any hasLoop
    | .sessions b => hasLoop b
    | _ => false) || hasLoop rest

/-- session_mdp for a session with loops, or when view is chain: expected visits, traversals and
amounts from the absorbing chain (selfhost.session.mdp.loops). -/
def mdpChain (args : Json) (p : Protocol) (layer : Generative.Resolved) : Except String Json := do
  let c ← Chain.analyse layer
  let model ← Chain.drawing c p.roles
  let exp := Chain.expected c p.roles
  let stateLine (s : Chain.State) : String :=
    let name := if s.kind == "state" then s!"S{s.id}" else s.label
    s!"- {name}" ++ (if s.detail.isEmpty then "" else s!" ({s.detail})") ++ s!": {Chain.ratText c.visits[s.id]!}"
  let edgeLines := (c.edges.toList.filter (·.kind == "message")).map fun e =>
    s!"- {e.label}: ×{Chain.ratText (Chain.traversals c e)}" ++ (if e.amountText.isEmpty then "" else s!" · {e.amountText}")
  let outcomes := c.ends.map fun k => (k, Chain.outcome c p.roles k)
  let outcomeLines := outcomes.map fun (k, (prob, given)) =>
    s!"- {c.states[k]!.label}: probability {Chain.ratText prob}" ++ match given with
      | some (bal, dur) => (if Chain.balancesText bal == "" then "" else s!", expected {Chain.balancesText bal}") ++
          (if dur == 0 then "" else s!", expected duration {Chain.daysText dur}")
      | none => " (never happens, so nothing is expected given it)"
  let duration := Chain.expectedDuration c
  let report := "\n".intercalate (["Outcomes (how the session ends):"] ++ outcomeLines ++
    ["Expected visits per state:"] ++ c.states.toList.map stateLine ++
    ["Expected traversals per message edge:"] ++ edgeLines ++
    [s!"Expected messages: {Chain.ratText (Chain.expectedMessages c)}"] ++
    (if duration == 0 then [] else [s!"Expected duration: {Chain.daysText duration}"]) ++
    (if exp.isEmpty then [] else ["Expected net balance per role:"] ++ exp.map fun (r,u,v) => s!"- {r}: {Chain.ratText v} {u}") ++
    Chain.legend c p.roles ++ c.notes)
  let provenance := Decision.output
  let result := Json.mkObj [("report", report),
    ("tool", "session_mdp"), ("verdict", "drawn"), ("view", "chain"), ("name", p.name), ("lean", p.lean),
    ("overlay", args.getObjValD "overlay"), ("generative", layer.metadata),
    ("reading", "Absorbing Markov chain under the supplied policy, with several rewards: expected visits solve v = start + vQ exactly; an edge's expected traversals are its source's visits times its probability; expected time is traversals times mean delay; amounts are traversals times each edge's trade vector, plus every rate in force times the time spent; each outcome's probability and conditional expectations come from absorption probabilities. Loops are counted, not unrolled. Not policy optimization."),
    ("states", toJson (c.states.map (Chain.stateJson c))), ("edges", toJson (c.edges.map (Chain.edgeJson c))),
    ("terminalProbability", Chain.ratText (outcomes.foldl (fun acc (_, (q, _)) => acc + q) 0)),
    ("expectedMessages", Chain.ratText (Chain.expectedMessages c)),
    ("expectedDurationMs", Chain.ratText duration),
    ("outcomes", toJson (outcomes.map fun (k, (prob, given)) => Json.mkObj ([("state", toJson k), ("label", c.states[k]!.label),
      ("probability", Chain.ratText prob)] ++ match given with
      | some (bal, dur) => [("expectedBalances", toJson (bal.map fun ((r, u, v) : String × String × Rat) =>
            Json.mkObj [("role", Json.str r), ("unit", Json.str u), ("expected", Json.str (Chain.ratText v))])),
          ("expectedDurationMs", Json.str (Chain.ratText dur))]
      | none => [("expectedBalances", Json.null), ("expectedDurationMs", Json.null)]))),
    ("expectedBalances", toJson (exp.map fun (r,u,v) => Json.mkObj [("role", r), ("unit", u), ("expected", Chain.ratText v)])),
    ("expectedByRole", Chain.byRole exp), ("breakdown", Chain.breakdownJson c),
    ("notes", toJson c.notes),
    ("diagramKind", "mdp"), ("svg", model.svg (themeOf args)),
    ("diagram", Json.mkObj [("width", model.width), ("height", model.height), ("shapes", toJson (model.shapes.map shapeJson))]),
    ("provenance", Json.mkObj [("prompt", provenance.prompt), ("question", "What are the expected visits to each state, traversals of each edge and net balance per role under the supplied policy?"),
      ("eventSource", provenance.eventSource), ("reducer", "Build the state graph; solve v = start + vQ over transient states with exact rationals; traversals = visits × probability; balances = Σ traversals × mean amount"),
      ("unit", "expected counts and amounts as exact rationals, per complete session"),
      ("boundary", "One session from start until it ends, which happens with probability 1 (otherwise the tool refuses); delays are after the previous step (after d); absolute times and deadlines are not used")])]
  if result.compress.length > limits.maxResult then throw "MDP output exceeds response limit; simplify the session"
  return result

/-- A step of a hand-written walk, or an event of a stream with its session and time. -/
def walkStep (j : Json) : Except String (Chain.Step × Option String × Option Nat) := do
  let label ← match j.getObjValAs? String "label" with
    | .ok l => if l.isEmpty || l.length > limits.maxString then throw "a step's label is empty or too long" else pure l
    | .error _ => throw "every step or event needs a label"
  let opt (k : String) : Option String := (j.getObjValAs? String k).toOption
  let opt (k : String) : Option String := (opt k).orElse fun _ =>
    if k == "from" then (j.getObjValAs? String "src").toOption else if k == "to" then (j.getObjValAs? String "dst").toOption else none
  let amounts : Option (List Chain.Move) ← match j.getObjVal? "amounts" with
    | .ok (.arr a) => some <$> a.toList.mapM fun m => do
        let f ← (m.getObjValAs? String "from").mapError fun _ => "an amount needs from, to, unit and quantity"
        let t ← (m.getObjValAs? String "to").mapError fun _ => "an amount needs from, to, unit and quantity"
        let u ← (m.getObjValAs? String "unit").mapError fun _ => "an amount needs from, to, unit and quantity"
        let q ← (m.getObjValAs? Nat "quantity").mapError fun _ => "an amount's quantity is a whole number"
        pure ((f, t, u, (q : Rat)) : Chain.Move)
    | _ => pure none
  let session : Option String := match j.getObjVal? "session" with
    | .ok (.str x) => some x
    | .ok (.num n) => some (toString n)
    | _ => none
  let time := ((j.getObjValAs? Nat "timeMs").toOption.orElse fun _ => (j.getObjValAs? Nat "time").toOption)
  let after := (j.getObjValAs? Nat "afterMs").toOption.map (fun (n : Nat) => (n : Rat))
  return ({ label, sender := opt "from", receiver := opt "to", afterMs := after, amounts }, session, time)

def walkJson (c : Chain.Chain) (w : Chain.Walked) (session : Option String) : Json := Json.mkObj
  [("session", toJson session), ("steps", w.steps), ("ended", w.ended),
   ("probability", Chain.ratText w.probability), ("durationMs", Chain.ratText w.duration),
   ("balances", Chain.byRole w.balances),
   ("edges", toJson ((List.range c.edges.size).filterMap fun i =>
     if w.counts[i]! == 0 then none else some (Json.mkObj [("label", c.edges[i]!.label), ("count", toJson (w.counts[i]! : Nat))])))]

/-- session_mdp with events (an event stream, walked per session) or walk (one hand-written walk):
realized rewards on actual counts and times (selfhost.session.mdp.walk). -/
def mdpWalk (args : Json) (p : Protocol) (layer : Generative.Resolved) : Except String Json := do
  let c ← Chain.analyse layer
  let raw ← match args.getObjVal? "events", args.getObjVal? "walk" with
    | .ok (.arr a), _ => pure (a.toList, true)
    | _, .ok (.arr a) => pure (a.toList, false)
    | _, _ => throw "events or walk must be an array"
  let (items, isStream) := raw
  if items.length > (if isStream then 5000 else 512) then
    throw (if isStream then "an event stream has at most 5000 events" else "a walk has at most 512 steps")
  let parsed ← items.mapM walkStep
  -- sessions in order of first appearance; a stream's times become delays since the previous event
  let sessions := (parsed.map (·.2.1)).eraseDups
  let timed := parsed.filter (·.2.2.isSome)
  if isStream && !timed.isEmpty && timed.length != parsed.length then
    throw "every event needs timeMs (or time) when any does"
  let mut walks : List (Option String × Chain.Walked) := []
  for sid in sessions do
    let mine := parsed.filter (·.2.1 == sid)
    let mut prev := 0
    let mut steps := []
    for (st, _, t) in mine do
      match t with
      | some ms =>
        if ms < prev then throw s!"time goes backwards in session {sid.getD "?"} at {st.label}"
        steps := steps ++ [{ st with afterMs := some ((ms - prev : Nat) : Rat) }]
        prev := ms
      | none => steps := steps ++ [st]
    let w ← (Chain.walk c steps).mapError fun e => match sid with | some x => s!"session {x}: {e}" | none => e
    walks := walks ++ [(sid, { w with balances := Chain.ordered c p.roles w.balances })]
  let total := Chain.ordered c p.roles <|
    walks.foldl (fun acc (_, w) => w.balances.foldl (fun acc (r, u, x) => Chain.addTo acc r u x) acc) []
  let totalDuration := walks.foldl (fun acc (_, w) => acc + w.duration) 0
  let line (sid : Option String) (w : Chain.Walked) : String :=
    s!"- {(sid.map (s!"session " ++ ·)).getD "walk"}: {w.steps} steps, " ++ (if w.ended then "ended" else "not ended") ++
      s!", probability {Chain.ratText w.probability}, duration {Chain.daysText w.duration}" ++
      (if Chain.balancesText w.balances == "" then "" else s!", {Chain.balancesText w.balances}")
  let report := "\n".intercalate (["Realized rewards of the given walks (not expectations):"] ++
    walks.map (fun (sid, w) => line sid w) ++
    (if walks.length > 1 then [s!"Total over {walks.length} sessions: duration {Chain.daysText totalDuration}" ++
      (if Chain.balancesText total == "" then "" else s!", {Chain.balancesText total}")] else []))
  return Json.mkObj [("report", report), ("tool", "session_mdp"), ("verdict", "walked"), ("view", "walk"),
    ("name", p.name), ("lean", p.lean),
    ("reading", "Realized rewards of the given walks: the chain's weights (trade vectors per traversal, rates in force times time) applied to actual counts and times, not expectations."),
    ("walks", toJson (walks.map fun (sid, w) => walkJson c w sid)),
    ("total", Json.mkObj [("sessions", walks.length), ("durationMs", Chain.ratText totalDuration), ("balances", Chain.byRole total)]),
    ("provenance", Json.mkObj [("prompt", Decision.output.prompt), ("question", "What did these walks realize, per role and unit?"),
      ("eventSource", if isStream then "the given event stream, grouped by session" else "the given walk"),
      ("reducer", "Match each step to the one edge reachable through choice, loop and rate edges; count traversals and time; apply each edge's trade vector and the rates in force"),
      ("unit", "exact amounts per role and unit, milliseconds"), ("boundary", "the given events only; a session that stops early is reported as not ended")])]

/-- session_mdp with horizon: whole periods behind a periodic gate (selfhost.session.mdp.horizon). -/
def mdpHorizon (args : Json) (p : Protocol) (layer : Generative.Resolved) (text : String) : Except String Json := do
  let horizonMs ← (Generative.parseValue Text.duration text).mapError (s!"horizon: " ++ ·)
  let c0 ← Chain.analyse layer (solveAll := false)
  let h ← Chain.horizon c0 horizonMs
  let c := h.chain
  let model ← Chain.drawing c p.roles
  let exp := Chain.expected c p.roles
  let duration := Chain.expectedDuration c
  let edgeLines := (c.edges.toList.filter fun e => e.kind == "message" || e.kind == "event").map fun e =>
    s!"- {e.label}: ×{Chain.ratText (Chain.traversals c e)}" ++ (if e.amountText.isEmpty then "" else s!" · {e.amountText}")
  let remainder := horizonMs - h.periods * h.periodMs
  let report := "\n".intercalate ([s!"Over {h.periods} whole periods of {Chain.periodText h.periodMs}:",
      s!"- gate passages: {Chain.ratText h.passages}", s!"- still running at the horizon: probability {Chain.ratText h.stillRunning}",
      s!"- expected time: {Chain.daysText duration}"] ++
    (if remainder == 0 then [] else [s!"- the last {Chain.daysText (remainder : Nat)} (a partial period) is not counted"]) ++
    ["Expected traversals per step:"] ++ edgeLines ++
    (if exp.isEmpty then [] else ["Expected totals per role:"] ++ exp.map fun (r,u,v) => s!"- {r}: {Chain.ratText v} {u}") ++
    Chain.legend c p.roles)
  let provenance := Decision.output
  let result := Json.mkObj [("report", report),
    ("tool", "session_mdp"), ("verdict", "drawn"), ("view", "horizon"), ("name", p.name), ("lean", p.lean),
    ("reading", "Whole periods behind a periodic gate: the start's segment and the cycle between gates are solved as absorbing chains; the gate passes q0(1 + q + ... + q^(N-1)) times; the wait at the gate fills each period; rewards are traversals times trade vectors plus rates in force times time. The graph does not depend on the horizon; only the number of periods does."),
    ("periods", h.periods), ("periodMs", h.periodMs), ("horizonMs", horizonMs), ("uncountedMs", remainder),
    ("gatePassages", Chain.ratText h.passages), ("stillRunning", Chain.ratText h.stillRunning),
    ("expectedDurationMs", Chain.ratText duration), ("expectedMessages", Chain.ratText (Chain.expectedMessages c)),
    ("states", toJson (c.states.map (Chain.stateJson c))), ("edges", toJson (c.edges.map (Chain.edgeJson c))),
    ("expectedBalances", toJson (exp.map fun (r,u,v) => Json.mkObj [("role", r), ("unit", u), ("expected", Chain.ratText v)])),
    ("expectedByRole", Chain.byRole exp), ("breakdown", Chain.breakdownJson c),
    ("diagramKind", "mdp"), ("svg", model.svg (themeOf args)),
    ("diagram", Json.mkObj [("width", model.width), ("height", model.height), ("shapes", toJson (model.shapes.map shapeJson))]),
    ("provenance", Json.mkObj [("prompt", provenance.prompt), ("question", s!"What happens over {h.periods} whole periods behind the gate?"),
      ("eventSource", provenance.eventSource),
      ("reducer", "Solve the start's segment and the cycle between gates as absorbing chains; combine with exact geometric sums over the periods; the gate's wait fills each period"),
      ("unit", "expected counts, milliseconds and amounts per role and unit, exact, over the horizon"),
      ("boundary", s!"{h.periods} whole periods of {h.periodMs} ms from the session's start; a partial period after them is not counted")])]
  if result.compress.length > limits.maxResult then throw "MDP output exceeds response limit; simplify the session"
  return result

/-- Native decision view under the resolved policy (selfhost.session.mdp, .mdp.loops). -/
def mdp (args : Json) : Except String Json := do
  let p ← parseProtocol args
  if !(p.global.issues p.roles).isEmpty then throw "fix protocol issues before rendering the MDP"
  let parsed ← Text.parse p.lean
  let layer ← match p.generative with
    | some r => pure r
    | none => Generative.resolve parsed.body
  let view := (args.getObjValAs? String "view").toOption.getD "auto"
  if !["auto", "tree", "chain"].contains view then throw "view must be tree, chain or auto"
  if (args.getObjVal? "events").isOk || (args.getObjVal? "walk").isOk then return ← mdpWalk args p layer
  if let .ok (.str text) := args.getObjVal? "horizon" then return ← mdpHorizon args p layer text
  if view == "chain" || (view == "auto" && hasLoop layer.body) then return ← mdpChain args p layer
  let nodes ← Decision.build layer p.roles
  let model ← Decision.drawing nodes
  let terminals := nodes.filter (·.kind == "terminal")
  let total := terminals.foldl (fun q n => LeanFM.Overlay.Q.add q n.mass) LeanFM.Overlay.Q.zero
  let provenance := Decision.output
  -- the outcome in the text a model reads: each terminal, then the expected results
  let terminalLine (n : Decision.Node) : String :=
    let money := Decision.balanceText n.balances
    s!"- {n.mass.text}: {n.label}, {n.detail}" ++ (if money.isEmpty then "" else s!" · {money}")
  let expectedLines := (Decision.expected nodes).map fun (r,u,v) => s!"- {r}: {v} {u}"
  let penaltyLines := (Decision.expectedPenalties nodes).map fun (r,u,v) => s!"- {r} pays {v} {u} in penalties"
  let report := "\n".intercalate (["Terminals (probability: outcome):"] ++ terminals.toList.map terminalLine ++
    [s!"P(any violation) = {(Decision.violationMass nodes).text}"] ++
    (if expectedLines.isEmpty then [] else ["Expected net balance per role:"] ++ expectedLines) ++ penaltyLines)
  let result := Json.mkObj [("report", report),
    ("tool", "session_mdp"), ("verdict", "drawn"), ("name", p.name), ("lean", p.lean),
    ("overlay", args.getObjValD "overlay"), ("generative", layer.metadata),
    ("reading", "Finite decision tree under the supplied policy. Policy edges select actions; transition edges describe outcomes. Terminal probabilities sum exactly to 1. This is not policy optimization."),
    ("nodes", toJson (nodes.map Decision.nodeJson)),
    ("terminals", toJson (terminals.map Decision.nodeJson)),
    ("terminalProbability", total.text), ("violationProbability", (Decision.violationMass nodes).text),
    ("expectedBalances", toJson ((Decision.expected nodes).map fun (r,u,v) =>
      Json.mkObj [("role", r), ("unit", u), ("expected", v)])),
    ("expectedPenalties", toJson ((Decision.expectedPenalties nodes).map fun (r,u,v) =>
      Json.mkObj [("payer", r), ("unit", u), ("expected", v)])),
    ("diagramKind", "mdp"), ("svg", model.svg (themeOf args)),
    ("diagram", Json.mkObj [("width", model.width), ("height", model.height), ("shapes", toJson (model.shapes.map shapeJson))]),
    ("provenance", Json.mkObj [("prompt", provenance.prompt), ("question", provenance.question),
      ("eventSource", provenance.eventSource), ("reducer", provenance.reducer), ("unit", provenance.unit),
      ("boundary", "One complete finite sequential session, including zero-mass paths; obligations observed until each terminal time")])]
  if result.compress.length > limits.maxResult then throw "MDP output exceeds response limit; simplify the session"
  return result

def natArg (args : Json) (key : String) (dflt maxV : Nat) : Except String Nat :=
  match args.getObjVal? key with
  | .error _ => .ok dflt
  | .ok v => match v.getNat? with
    | .ok n => if n ≤ maxV then .ok n else .error s!"{key} is at most {maxV}"
    | .error _ => .error s!"{key} must be a natural number"

/-- Whether a protocol already serves instances itself. -/
partial def hasSessions : Global String → Bool
  | .sessions _ _ => true
  | .msg _ k | .act _ _ k => hasSessions k
  | .choice bs => bs.any hasSessions
  | .par bs k | .join _ bs k => bs.any hasSessions || hasSessions k
  | .loop _ b => hasSessions b
  | .box _ b k => hasSessions b || hasSessions k
  | .var _ | .done => false

def simulate (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let seed ← natArg args "seed" 1 4294967295
  let instances ← natArg args "instances" 8 limits.maxInstances
  let spread ← natArg args "spread" 40 limits.maxSpread
  let loops ← natArg args "loops" 4 limits.maxLoops
  let maxEvents ← natArg args "maxEvents" 300 limits.maxEvents
  -- loops, rates and gates: generate walks of the chain (selfhost.session.generate.chain)
  if let some layer := p.generative then
    if hasLoop layer.body then
      if !(p.global.issues p.roles).isEmpty then throw "fix protocol issues before generation"
      let c ← Chain.analyse layer (solveAll := false)
      let g ← Chain.generate c seed instances
      let evJson := (g.events.zip g.amounts).map fun (e, ms) =>
        (eventJson e).setObjVal! "amounts" (toJson (ms.map fun (f, t, u, q) =>
          Json.mkObj [("from", f), ("to", t), ("unit", u), ("quantity", toJson q.num.toNat)]))
      let endedCount := (g.ended.filter (·.2)).length
      return fit <| Json.mkObj
        [("tool", "session_simulate"), ("verdict", "generated"),
         ("reading", s!"{p.name}: {g.events.size} events in {instances} sessions generated from the chain (seed {seed}); {endedCount} ended; ms relative to each session; each event carries the amounts it moved"),
         ("name", p.name), ("roles", toJson p.roles), ("lean", p.lean), ("protocol", args.getObjValD "protocol"),
         ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p), ("timeUnit", "ms"), ("timeBasis", "session-relative"),
         ("seed", seed), ("instances", instances), ("sessions", instances),
         ("ended", toJson (g.ended.map fun (sid, e) => Json.mkObj [("session", sid), ("ended", e)])),
         ("events", Json.arr evJson), ("diagram", diagramJson p)]
  if let some layer := p.generative then
    if !(p.global.issues p.roles).isEmpty then throw "fix protocol issues before timed generation"
    if (args.getObjVal? "spread").isOk || (args.getObjVal? "loops").isOk then
      throw "timed generation uses session-relative clocks; spread and loops are unsupported"
    let generated ← Generative.generate layer p.roles seed instances maxEvents
    return fit <| Json.mkObj
      [("tool", "session_simulate"), ("verdict", "generated"),
       ("reading", s!"{p.name}: {generated.events.size} timed events in {instances} sessions; ms relative to each session; deadlines reported separately"),
       ("name", p.name), ("roles", toJson p.roles), ("lean", p.lean), ("protocol", args.getObjValD "protocol"),
       ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p), ("timeUnit", "ms"), ("timeBasis", "session-relative"),
       ("seed", seed), ("instances", instances), ("sessions", instances),
       ("events", Json.arr (generated.events.map eventJson)), ("deadlineReports", toJson generated.reports),
       ("diagram", diagramJson p)]
  -- a protocol without a sessions block runs as `instances` concurrent copies of itself
  let g := if hasSessions p.global then p.global else .sessions p.global .done
  let evs := g.simulate seed instances spread loops maxEvents
  let sessions := (evs.toList.map (·.session)).eraseDups.length
  return fit <| Json.mkObj
    [ ("tool", "session_simulate"), ("verdict", "generated")
    , ("reading", s!"{p.name}: {evs.size} events from {sessions} session{if sessions == 1 then "" else "s"} (seed {seed})")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol"), ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p)
    , ("seed", seed), ("instances", instances), ("sessions", sessions)
    , ("events", Json.arr (evs.map eventJson))
    , ("diagram", diagramJson p) ]

/-- A logged event: the fields session_simulate writes (src, dst, act) or from/to; ids, sessions and
causes may be strings or numbers. -/
def logEvent (j : Json) : Except String LogEvent := do
  let text (k : String) : Option String :=
    match j.getObjVal? k with
    | .ok (.str s) => some s
    | .ok (.num n) => some n.toString
    | _ => none
  let id ← match text "id" with | some s => pure s | none => .error "every event needs an id"
  let label ← match text "label" with | some s => pure s | none => .error s!"event {id} has no label"
  let isAct := (j.getObjValAs? Bool "act").toOption.getD false
  let src ← match text "from" <|> text "src" <|> text "at" with
    | some s => pure s | none => .error s!"event {id} has no from (or src)"
  let dst := if isAct then src else (text "to" <|> text "dst").getD ""
  if !isAct && dst.isEmpty then .error s!"event {id} has no to (or dst)"
  for s in [id, label, src, dst] do
    if s.length > limits.maxString then .error s!"event {id} has a field over {limits.maxString} characters"
  return { id, session := (text "session").getD "0", src, dst, label, cause := text "cause", isAct }

def maxLogEvents : Nat := 2000

def deadlineReports (p : Protocol) (args : Json) (evs : List LogEvent) : Except String Json := do
  let some layer := p.generative | return Json.null
  let raw ← args.getObjValAs? (Array Json) "events"
  let timed ← (evs.zip raw.toList).mapM fun (e,j) => do
    let t ← match (j.getObjVal? "timeMs").toOption <|> (j.getObjVal? "time").toOption with
      | some v => v.getNat?
      | none => throw s!"event {e.id}: timed monitoring requires timeMs (or time)"
    if t > 9007199254740991 then throw "timestamp exceeds the safe integer limit"
    return (e.session, { src := e.src, dst := e.dst, label := e.label, time := t, isAct := e.isAct : Generative.Observation })
  let horizon ← match args.getObjVal? "horizonMs" with
    | .error _ => pure none
    | .ok j => pure (some (← j.getNat?))
  if horizon.any (· > 9007199254740991) then throw "horizon exceeds the safe integer limit"
  let sessions := (evs.map (·.session)).eraseDups
  let result ← sessions.mapM fun id => do
    let observations := timed.filterMap fun (s,e) => if s == id then some e else none
    let report ← Generative.monitor layer p.roles observations horizon
    return Json.mkObj [("session", id), ("report", report)]
  return toJson result

def conform (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let evs ← match args.getObjVal? "events" with
    | .ok (.arr a) =>
        if a.size > maxLogEvents then throw s!"at most {maxLogEvents} events"
        a.toList.mapM logEvent
    | _ => throw "events must be an array of logged events {id, session?, from, to, label, cause?} (or {id, at, label, act: true})"
  let allowIncomplete := (args.getObjValAs? Bool "allowIncomplete").toOption.getD false
  let results := p.global.conforms evs allowIncomplete
  let bad := results.filter (·.problem.isSome)
  let incomplete := results.filter (!·.complete)
  let verdict := if bad.isEmpty then "conforms" else "violates"
  let problems := bad.filterMap fun r => r.problem.map fun (e, why) => s!"session {r.session}, event {e}: {why}"
  let reading := if bad.isEmpty
    then s!"{p.name}: {evs.length} events in {results.length} session{if results.length == 1 then "" else "s"} follow the protocol" ++
      (if incomplete.isEmpty then "" else s!"; {incomplete.length} still running")
    else s!"{p.name}: {bad.length} of {results.length} sessions break the protocol; first: {problems.head!}"
  let deadlines ← if bad.isEmpty then deadlineReports p args evs else pure Json.null
  return fit <| Json.mkObj
    [ ("tool", "session_conform"), ("deadlineReports", deadlines), ("verdict", verdict), ("reading", reading), ("name", p.name)
    , ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol"), ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p)
    , ("issues", Json.arr ((problems.take 64).map Json.str).toArray)
    , ("sessions", Json.arr ((results.take 200).map fun r => Json.mkObj
        [("session", r.session), ("events", r.events), ("complete", r.complete),
         ("problem", match r.problem with | some (e, why) => Json.mkObj [("event", e), ("reason", why)] | none => Json.null)]).toArray)
    , ("diagram", diagramJson p) ]

/-- What may happen next in one session: the walk-through in the view calls this after each step. -/
def next (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let evs ← match args.getObjVal? "events" with
    | .ok (.arr a) =>
        if a.size > limits.maxSteps then throw s!"at most {limits.maxSteps} events in a walk"
        a.toList.mapM logEvent
    | .ok .null | .error _ => pure []
    | _ => throw "events must be an array of the events so far"
  let stepJson (s : Conform.NextStep) : Json :=
    let base := [("label", Json.str s.label), ("from", Json.str s.src)]
    let tail := if s.isAct then [("act", Json.bool true)] else [("to", Json.str s.dst)]
    Json.mkObj (base ++ tail ++ (match s.cause with | some c => [("cause", Json.str c)] | none => []))
  match p.global.next evs with
  | .error why =>
    return Json.mkObj [("tool", "session_next"), ("verdict", "violates"), ("name", p.name),
      ("reading", s!"{p.name}: the walk breaks the protocol at {why}"), ("issues", Json.arr #[Json.str why]),
      ("next", Json.arr #[]), ("canEnd", false), ("lean", p.lean)]
  | .ok (steps, canEnd) =>
    let verdict := if steps.isEmpty then (if canEnd then "finished" else "stuck") else "running"
    let what := match steps.length with
      | 0 => if canEnd then "the session has ended" else "nothing can happen and the session cannot end"
      | 1 => "1 step may happen next"
      | n => s!"{n} steps may happen next"
    let ending := if canEnd && !steps.isEmpty then "; the session may also end here" else ""
    -- the steps go in the text a model reads too, one per line
    let line (s : Conform.NextStep) : String :=
      let who := if s.isAct then s!"{s.label} at {s.src}" else s!"{s.label} from {s.src} to {s.dst}"
      match s.cause with | some c => s!"- {who} (cause {c})" | none => s!"- {who}"
    let report := "\n".intercalate (steps.map line)
    return Json.mkObj [("tool", "session_next"), ("verdict", verdict), ("name", p.name), ("report", report),
      ("roles", Json.arr (p.roles.map Json.str).toArray),
      ("reading", s!"{p.name}: after {evs.length} event{if evs.length == 1 then "" else "s"}, {what}{ending}"),
      ("next", Json.arr (steps.map stepJson).toArray), ("canEnd", canEnd), ("lean", p.lean)]

/-- Two versions of a protocol: which roles can upgrade first, and which can stay on the old one. -/
def compat (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let oldText ← match args.getObjVal? "old" with
    | .ok (.str s) => pure s
    | _ => throw "old is required: the previous version's LeanFM protocol text"
  let q ← (parseProtocol (Json.mkObj [("lean", Json.str oldText)])).mapError ("the old version: " ++ ·)
  let body (g : Global String) := match g with | .sessions b _ => b | other => other
  let results ← (body p.global).compat (body q.global) p.roles q.roles
  let answer (r : Except String (Option Evolution.Failure)) : Json × Bool :=
    match r with
    | .ok none => (Json.mkObj [("ok", true)], true)
    | .ok (some f) => (Json.mkObj [("ok", false), ("reason", Json.str f.reason),
        ("after", Json.arr (f.path.map Json.str).toArray)], false)
    | .error e => (Json.mkObj [("ok", false), ("reason", Json.str e)], false)
  let rows := results.map fun c =>
    let (u, uok) := answer c.upgradeFirst
    let (s, sok) := answer c.stayBehind
    (c.role, uok, sok, Json.mkObj [("role", Json.str c.role), ("upgradeFirst", u), ("stayBehind", s)])
  let why (j : Json) : String :=
    let reason := (j.getObjValAs? String "reason").toOption.getD ""
    match j.getObjValD "after" with
    | .arr a => if a.isEmpty then reason else
        s!"{reason} (after {"; ".intercalate (a.toList.filterMap (·.getStr?.toOption))})"
    | _ => reason
  let issues := rows.flatMap fun (r, uok, sok, j) =>
    (if uok then [] else [s!"{r} cannot upgrade first: " ++ why (j.getObjValD "upgradeFirst")]) ++
    (if sok then [] else [s!"{r} cannot stay on the old version: " ++ why (j.getObjValD "stayBehind")])
  let onlyNew := p.roles.filter (!q.roles.contains ·)
  let onlyOld := q.roles.filter (!p.roles.contains ·)
  let first := rows.filter (·.2.1) |>.map (·.1)
  let order := if issues.isEmpty then "every role can upgrade on its own schedule"
    else if first.isEmpty then "no role can upgrade on its own"
    else s!"upgrade first: {", ".intercalate first}"
  let notes := (if onlyNew.isEmpty then [] else [s!"only in the new version: {", ".intercalate onlyNew}"]) ++
    (if onlyOld.isEmpty then [] else [s!"only in the old version: {", ".intercalate onlyOld}"])
  return Json.mkObj [("tool", "session_compat"), ("verdict", if issues.isEmpty then "compatible" else "incompatible"),
    ("name", p.name), ("reading", s!"{q.name} → {p.name}: {order}"),
    ("roles", Json.arr (rows.map (·.2.2.2)).toArray), ("issues", Json.arr (issues.map Json.str).toArray),
    ("notes", Json.arr (notes.map Json.str).toArray), ("lean", p.lean)]

/-- A CTL formula over one session of the protocol: the protocol's state graph handed to the
logic tools' checker as an inline task, so `{"after": "Charge"}` holds in the state a Charge has
just reached, and the answer carries a witness or counterexample path. -/
def ctl (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let formula ← match args.getObjVal? "formula" with
    | .ok f => pure f
    | .error _ => throw "formula is required: a JSON CTL formula, such as {\"never\": {\"after\": \"Charge\"}}"
  let graph ← p.global.stateGraph
  let transition (e : String × String × Conform.NextStep) : Json :=
    let (a, b, n) := e
    Json.mkObj ([("src", Json.str a), ("dst", Json.str b), ("message", Json.str n.label), ("from", Json.str n.src)] ++
      (if n.isAct then [] else [("to", Json.str n.dst)]))
  let draft := Json.mkObj [("id", Json.str p.name), ("states", Json.arr (graph.states.map Json.str).toArray),
    ("initial", "s0"), ("terminals", Json.arr (graph.terminals.map Json.str).toArray),
    ("transitions", Json.arr (graph.edges.map transition).toArray)]
  let answer ← LeanFM.Logic.checkCtl (Json.mkObj [("task", draft), ("formula", formula)])
  let reading := (answer.getObjValAs? String "reading").toOption.getD ""
  -- the path goes in the text a model reads too: the messages in order, and where a lasso repeats
  let evidence := (answer.getObjVal? "evidence").toOption.getD Json.null
  let steps := match evidence.getObjVal? "path" with
    | .ok (.arr a) => a.toList.filterMap fun st => (st.getObjValAs? String "message").toOption
    | _ => []
  let kind := (evidence.getObjValAs? String "kind").toOption.getD "path"
  -- loopsBackTo indexes the path, whose first entry is the start state (no message)
  let loop := match (evidence.getObjValAs? Nat "loopsBackTo").toOption with
    | some 0 => " (then repeats from the start)"
    | some i => if i ≥ steps.length then " (and stays there)"
      else s!" (then repeats from {steps.getD i ""})"
    | none => ""
  let report := if steps.isEmpty then "" else s!"{kind}: {" → ".intercalate steps}{loop}"
  return answer.setObjVal! "tool" (Json.str "session_ctl")
    |>.setObjVal! "report" (Json.str report)
    |>.setObjVal! "reading" (Json.str s!"{p.name}: {reading}")
    |>.setObjVal! "states" (toJson graph.states.length)
    |>.setObjVal! "lean" (Json.str p.lean)

/-- A role's HTTP interface: the requests it receives with their routes, as OpenAPI 3.1. -/
def openapi (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let role ← match args.getObjVal? "role" with
    | .ok (.str r) => pure r
    | _ => throw s!"role is required: one of {", ".intercalate p.roles}"
  if !p.roles.contains role then throw s!"{role} is not a role of {p.name}; its roles are {", ".intercalate p.roles}"
  let (doc, unrouted) ← p.global.openApi p.name role
  let ops := match doc.getObjValD "paths" with
    | .obj kvs => kvs.toList.foldl (fun n (_, v) => n + (match v with | .obj ms => ms.size | _ => 0)) 0
    | _ => 0
  let note := if unrouted.isEmpty then "" else s!"; {unrouted.length} request{if unrouted.length == 1 then "" else "s"} without a route left out"
  return Json.mkObj [("tool", "session_openapi"), ("verdict", "generated"), ("name", p.name), ("role", Json.str role),
    ("reading", s!"{p.name}: OpenAPI 3.1 for {role}, {ops} operation{if ops == 1 then "" else "s"}{note}"),
    ("openapi", doc), ("unrouted", Json.arr (unrouted.map Json.str).toArray),
    ("language", "json"), ("code", Json.str doc.pretty), ("lean", Json.str p.lean)]

/-- Every check that applies, as findings with an edit to try for each. -/
def review (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let findings ← p.global.review p.roles
  let routed := (p.global.messages.filter (·.route.isSome)).length
  let scope := s!"structure, {if routed == 0 then "no HTTP (no routes)" else s!"HTTP from {routed} routed request{if routed == 1 then "" else "s"}"}, liveness, roles"
  let reading := if findings.isEmpty then s!"{p.name}: no findings ({scope})"
    else s!"{p.name}: {findings.length} finding{if findings.length == 1 then "" else "s"} ({scope})"
  let report := "\n".intercalate ((List.range findings.length).map fun i =>
    let f := findings[i]!
    s!"{i + 1}. [{f.kind}] {f.message}\n   try: {f.suggestion}")
  return Json.mkObj [("tool", "session_review"), ("verdict", if findings.isEmpty then "clean" else "findings"),
    ("name", p.name), ("reading", reading),
    ("findings", Json.arr (findings.map fun f => Json.mkObj [("kind", Json.str f.kind), ("message", Json.str f.message),
      ("suggestion", Json.str f.suggestion)]).toArray),
    ("issues", Json.arr (findings.map fun f => Json.str s!"{f.message} (try: {f.suggestion})").toArray),
    ("report", Json.str report), ("lean", Json.str p.lean)]

def skeleton (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let language := (args.getObjValAs? String "language").toOption.getD "python"
  let code ← match language with
    | "python" => p.global.pythonSkeleton p.name p.roles
    | "typescript" => p.global.typescriptSkeleton p.name p.roles
    | other => throw s!"language {other} is not supported; use python or typescript"
  let starts := ", ".intercalate (p.roles.map Skeleton.snake)
  let what := if language == "python" then "a Python" else "a TypeScript"
  return fit <| Json.mkObj
    [ ("tool", "session_skeleton"), ("verdict", "generated")
    , ("reading", s!"{p.name}: {what} module with each role's typestate as classes; start functions {starts}")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("language", language), ("code", code), ("lean", p.lean) ]

def toolNames : List String := ["session_check", "session_diagram", "session_mdp", "session_simulate", "session_conform", "session_skeleton", "session_next", "session_compat", "session_ctl", "session_openapi", "session_review"]

def run (name : String) (args : Json) : Option (Except String Json) :=
  match name with
  | "session_check" => some (check args)
  | "session_diagram" => some (diagram args)
  | "session_mdp" => some (mdp args)
  | "session_simulate" => some (simulate args)
  | "session_conform" => some (conform args)
  | "session_skeleton" => some (skeleton args)
  | "session_next" => some (next args)
  | "session_compat" => some (compat args)
  | "session_ctl" => some (ctl args)
  | "session_openapi" => some (openapi args)
  | "session_review" => some (review args)
  | _ => none

/-! ## Reference -/

def reference : String := "# LeanFM session types

Design interactions between roles as a session type in LeanFM's protocol syntax, then let LeanFM
check it, draw it and run it. Every diagram, call list and event stream is generated from the text.
Send the text as the `lean` argument of the tools. It is read by a parser for this grammar only:
nothing in it is elaborated or run, and a `where` condition is shown, never evaluated.

## Inline generation and deadline monitoring

The text parser also accepts named weighted choices, clocks, message times and obligations.
See examples/sessions/DepositSettlement.leanfm for the complete legal illustration.
Use choice at Landlord using declared(\"settlement-v1\") with probability 3/4:
and probability 1/4: at the start of its two branches. Fractions must sum exactly to one.
A clock can be max(time(ended), time(address)); message timing can be
at settlement + sample { 7 days : 9/10; 25 days : 1/10; }.
An obligation names its actor, trigger clock, required message labels, inclusive within
duration and on breach record label. Breaches are reports, not invented wire messages.

The optional overlay object has name, choices [{choice, weights}] and timings [{message, at}].
Weights are fraction strings; at is a time-expression string. A named choice or plain choice:0
is its target; a timing targets a message id or unique label. External entries explicitly
replace matching inline entries, retain origin metadata, and never remove structural paths.
Zero probability does not prove impossibility in CTL.

Timed simulation uses exact rational probabilities, seeded sampling and session-relative ms.
Days are fixed 24-hour durations. Unannotated messages occur at the preceding message time.
Timed conformance requires timeMs (or time) on every event, with optional horizonMs for
an incomplete capture. Structural verdict and deadlineReports are separate; observed delays
need not belong to a sampling distribution. A deadline is pending at its exact boundary
unless satisfied, and violated after it. Generation currently supports finite sequential
choices, at most 4096 expanded paths, and rejects timed concurrency, recursion and includes.
Legacy unannotated simulation is unchanged. These annotations belong to the MCP text
parser; the native Lean protocol macro remains the structural grammar.

## Amounts, time, rates and trades: decision processes

Messages can move value, steps can take time, and rates can run while time passes. `session_mdp`
then gives expected values (and realized ones for an event stream), all as exact fractions.
These annotations never change the structure: projection, conformance and CTL are unchanged.

| annotation | meaning |
|---|---|
| `Pay from A to B amount 1000 USD;` | moves 1000 USD from sender to receiver |
| `amount sample { 700 USD : 1/2; 400 USD : 1/2; }` | an uncertain amount; probabilities sum to 1 |
| `Swap from A to B amount { 5 apple; 4 orange; -3 USD; };` | a trade vector: positive entries move from sender to receiver, negative ones back, so the two sides sum to zero in every unit |
| `on breach record Late pays 2000 USD to Tenant;` | in an obligation: a penalty its actor pays when it is violated |
| `Reply from B to A after 2 days;` | a delay after the previous step (also `after sample { 1 days : 1/2; 3 days : 1/2; }`; units ms, seconds, minutes, hours, days, weeks) |
| `accrue 10 USD per week from Borrower to Lender;` | a rate in force from here until the next accrue for the same two roles and unit; `accrue 0` (or none at all) is grace |
| `accrue { 1000 USD per week; -1 roomweek per week; } from Tenant to Landlord;` | a rate vector: a continuous trade whose two sides cancel unit by unit at every moment |
| `Rent from Tenant to Landlord amount 1000 USD at next 1 week;` | a periodic gate: waits for the next whole week since the session began |

Units are names: a roomweek is one room for one week, and 1000 USD per week is the exchange rate
between roomweeks and dollars, not an amount. Results are maps keyed by unit, per role.

How `session_mdp` reads a session:

- without loops, rates or gates: a decision tree; each terminal has its probability, times,
  deadline reports and each role's balance; `expectedBalances` sums them.
- with `rec`, `accrue` or `after` on an event (or `view: \"chain\"`): an absorbing Markov chain.
  Expected visits solve v = start + vQ; an edge's traversals are visits times probability; time is
  traversals times mean delay; balances are traversals times trade vectors plus rates times time.
  Each way of ending (its last step) is an outcome with its probability and the expected balances
  given it. A rate that depends on which path reached a state, and deadlines in loops, are refused.
- with one gate and `horizon: \"52 weeks\"`: whole periods, whether or not the session ends. The gate
  makes each period hold one passage, so the graph is the same for every horizon: a weekly trade
  that always continues passes exactly 52 times. Work before a gate must fit in its period, and every
  loop must pass the gate.
- with `events` (session_conform's format, with timeMs): the realized rewards of each session's
  walk, its probability under the policy, and the totals.

`session_simulate` generates sessions from the same probabilities. For a session with loops, rates
or gates it walks the chain, drawing each branch, delay and amount; every event carries the amounts
it moved. Feeding the stream back to `session_mdp` as `events` gives each session's realized
rewards, and over many sessions their mean approaches the expected value.

See examples/sessions: PricedDepositSettlement (amounts, a penalty), LimitOrder (a loop, fees, two
outcomes), Loan (grace, then interest), Rental (a rate vector), WeeklyRent (a gate over a horizon),
RentWithRepairs (a nested choice behind a gate) and Ride (three parties, a retry loop, nested
choices, delays and payments through a platform).

## Tools

- `session_review {lean}`: every check that applies, in one answer, each finding with an edit to
  try: the core rules; HTTP wherever a message has a `route` (its channel is HTTP and its sender may
  call its receiver, so no flags are needed), including requests never answered (with the response
  line to add) and responses to routed requests without a status; a session that can never end (a
  loop with no way out); roles that take no part. Call it after every change while designing.

- `session_check {lean, mayCall?}`: the core rules (one role decides each choice; every role can
  tell which branch was taken; a cause names a message its sender saw), each role's local type and
  typestate API, the calls (request, responses with status, nested calls), and the diagram. With
  `mayCall: [[caller, callee], ...]`, every channel is HTTP and calls that break the request/response
  discipline are reported, including a request that never gets a response; `notHttp: [[a, b], ...]`
  marks the channels between those roles as something else (a text message, a queue).
- `session_mdp {lean, overlay?, theme?}`: render the finite decision tree with policy edges,
  timed transitions and terminal outcomes. Returns SVG, shapes, exact terminal masses summing
  to 1 and violationProbability (any obligation violated, each terminal counted once).
  Pending obligations remain pending. Requires a complete probability layer for choices;
  rejects unsupported scheduling and graphs above 96 nodes rather than truncate.
  This unfolds the supplied policy; it does not optimize actions or solve unbounded MDPs.
- `session_diagram {lean, theme?}`: the UML sequence diagram, as SVG text and as shapes.
- `session_simulate {lean, seed?, instances?, spread?, loops?, maxEvents?}`: a seeded event stream.
  Each event has prior (what it happened after, per role, plus join ends), cause, and answers (the
  request it responds to). The view animates it. A protocol without `sessions` runs as `instances`
  concurrent copies.

- `session_conform {lean, events, allowIncomplete?}`: check what a running program logged against
  the protocol. Log one event per message sent, `{\"id\": \"e7\", \"session\": \"42\", \"from\": \"Shop\",
  \"to\": \"Client\", \"label\": \"Quote\", \"cause\": \"e6\"}`, and one per event, `{\"id\": ..., \"at\":
  \"Shop\", \"label\": \"Completed\", \"act\": true}`. Each session must follow the protocol: order,
  choices, the cause the protocol names, and an end the protocol allows (unless allowIncomplete).
  session_simulate's events are accepted as they are.

- `session_next {lean, events?}`: what may happen next in one session after the events so far (in
  session_conform's format): each allowed step with the cause it must name, and whether the session
  may end here (`running`, `finished`, or `violates` with the first problem). The view's walk-through
  calls it after every click.

- `session_ctl {lean, formula}`: a CTL formula over one session, decided on the protocol's state
  graph by the same checker as check_ctl, with a witness or counterexample path. Atoms:
  `{\"after\": \"Label\"}` (a Label message or event has just happened) and `\"terminal\"` (the session
  has ended). Rules the structure does not show belong here, for example:
  never charge after no seat, `{\"AG\": {\"implies\": [{\"after\": \"NoSeat\"}, {\"AG\": {\"not\": {\"after\": \"Charge\"}}}]}}`;
  every held seat is confirmed or released, `{\"AG\": {\"implies\": [{\"after\": \"SeatHeld\"}, {\"AF\": {\"or\":
  [{\"after\": \"SeatConfirmed\"}, {\"after\": \"SeatReleased\"}]}}]}}`; every session ends, `{\"AF\": \"terminal\"}`.

- `session_openapi {lean, role}`: the requests `role` receives, with their routes and the responses
  the protocol allows, as an OpenAPI 3.1 document: one operation per route, the label as its
  operationId and body, each response under its status. Message fields are not in the protocol, so
  each message is an open object schema to fill in. Requests without a route are listed, not guessed.

- `session_compat {lean, old}`: two versions of a protocol (`lean` the new one, `old` the
  previous one). For each role in both: can its new version be deployed first, among the old
  versions of every other role, and can its old version stay deployed after the others upgrade?
  Each mixed system is explored to every reachable state; a no comes with the steps to where it gets
  stuck. Adding a message a role may receive usually lets that role upgrade first; adding one it
  may send usually means the receivers must upgrade first.

- `session_skeleton {lean, language?}`: a self-contained Python (the default) or TypeScript
  (`\"language\": \"typescript\"`) module with every role's typestate as classes, one per state. In
  TypeScript a step the state does not allow does not type-check, and `receive` returns a union
  tagged by `label` that narrows `next`. A method sends only what its state allows, fills in the cause the
  protocol names, logs the event in session_conform's format and returns the next state; `receive`
  accepts only what the state allows; a state used twice raises. Write only the decisions (which
  branch, what each message carries) and the transport: a function that delivers a message.

Every answer echoes the text as `lean`; the view shows it in an editor and rechecks as you type.
Under the editor, the sketch adds statements by clicking: the sender's lifeline, then the
receiver's (the same one twice for an event), then a label, with an optional route and, for a
reply to the latest request the other way, a status. To design from nothing, check a protocol with
no statements, such as `protocol Shop (Client, Server) { }`, and sketch from there.

## Building software from a protocol

1. Write the protocol and run session_check until it has no issues; with `mayCall` (and `notHttp`
   for channels that are not HTTP) for HTTP.
2. Show it: the diagram, each role's typestate (its API: one state per point in the conversation),
   a walk through one session (session_next), and session_simulate's stream.
3. Generate the roles' states with session_skeleton and implement each role on them: per session,
   keep the state the last method returned and decide what to do next; the generated methods send
   only what each state allows, fill in causes and log every message. (In another language, write a
   handler per typestate state the same way.)
4. Log every message as an event with the protocol's label, the session it belongs to and the
   event that caused it (the generated module does this; give it a log function).
5. Run it, and check the log with session_conform; fix the code (or, if the protocol was wrong, the
   protocol) until every session conforms.
6. State each rule the structure does not show as a CTL formula and check it with session_ctl.
7. When a running protocol changes, session_compat says which roles can be deployed first.

## A protocol

```lean
/-- Placing an order: quote, pay, charge the card. -/
protocol PlaceOrder (Client, Shop, Bank) {
  o: CreateOrder from Client to Shop route \"POST /orders\";
  choice {
    q: Quote from Shop to Client cause o status 201;
    p: Pay from Client to Shop cause q where p.amount = q.price;
    c: Charge from Shop to Bank cause p;
    choice {
      d: Charged from Bank to Shop cause c;
      Receipt from Shop to Client cause d status 200;
    } or {
      x: Declined from Bank to Shop cause c;
      PaymentDeclined from Shop to Client cause x status 402;
    }
  } or {
    SoldOut from Shop to Client cause o status 409;
  }
}
```

## Statements

| statement | meaning |
|---|---|
| `x: Label from A to B cause y route \"...\" status 201 where e;` | a message; `x:`, `cause`, `route`, `status` and `where` are optional; `cause y` names an earlier id, and a response's cause chain reaches its request |
| `Label at A;` | something a role does on its own |
| `choice { ... } or { ... }` | exactly one branch happens; the role that sends the first message of every branch decides (`select` in its local type); the others learn the branch from what reaches them (`offer`) |
| `par { ... } and { ... }` | branches run concurrently; what follows waits for all |
| `join 2 of { ... } and { ... } and { ... }` | what follows waits for any 2 branches |
| `rec Loop { ... continue Loop; }` | a loop; `continue` is the last statement of its block |
| `sessions { ... }` | any number of independent instances, as a server handles requests; nested inside a protocol, a role that appears only in such blocks is a service that handles each one on its own |
| `include Replicate Primary R1 R2 R3;` | an earlier protocol in the same text, roles renamed in order, drawn as a ref frame |

Write several protocols in one text to include one in another; the last protocol is the one
checked. Names are Lean identifiers (`«two words»` works). `--` and `/- -/` comments are allowed.
Statements after a choice continue every branch. Limits: 64 KiB of text, 200 statements, 12 roles,
16 branches per construct, nesting 24 deep, names and strings of 200 characters; simulations up to
200 instances and 600 events.

## Reading the answers

- A choice whose branches are started by different roles is a race; pick one decider.
- \"R cannot tell which branch C chose\": give R a message in every branch, or one that differs. If R
  is a service that handles each request on its own (a mailer, a text-message gateway), put each of
  its exchanges in a nested `sessions { ... }` block: R then serves those sessions and never needs
  to know the conversation around them.
- \"L: S never saw y\": the cause of L must be something its sender sent or received.
- \"R from A to B never gets a response\": over HTTP every request gets one. Add the response (a
  message from B to A with `cause` naming the request and a `status`), or, if the channel is not
  HTTP (a text message, a queue), name it in `notHttp`.
- Responses are dashed in diagrams; each call is an activation bar on the callee.

## The JSON form

The tools also accept `protocol: {name, roles, steps}` in place of `lean`, and answer with the same
protocol written as text. Each step is an object with exactly one kind key: `msg` (with `from`,
`to`, and optional `id`, `cause`, `route`, `status`, `where`), `event` (with `at`), `choice` and
`par` (arrays of branches, each an array of steps), `join` (a number, with `of`), `rec` (with
`steps`), `continue`, `sessions` (an array of steps) and `include` (with `steps`):

```json
{\"name\": \"PlaceOrder\", \"roles\": [\"Client\", \"Shop\", \"Bank\"], \"steps\": [
  {\"msg\": \"CreateOrder\", \"id\": \"o\", \"from\": \"Client\", \"to\": \"Shop\", \"route\": \"POST /orders\"},
  {\"choice\": [
    [{\"msg\": \"Quote\", \"id\": \"q\", \"from\": \"Shop\", \"to\": \"Client\", \"cause\": \"o\", \"status\": 201},
     {\"msg\": \"Pay\", \"id\": \"p\", \"from\": \"Client\", \"to\": \"Shop\", \"cause\": \"q\", \"where\": \"p.amount = q.price\"},
     {\"msg\": \"Charge\", \"id\": \"c\", \"from\": \"Shop\", \"to\": \"Bank\", \"cause\": \"p\"},
     {\"choice\": [
       [{\"msg\": \"Charged\", \"id\": \"d\", \"from\": \"Bank\", \"to\": \"Shop\", \"cause\": \"c\"},
        {\"msg\": \"Receipt\", \"from\": \"Shop\", \"to\": \"Client\", \"cause\": \"d\", \"status\": 200}],
       [{\"msg\": \"Declined\", \"id\": \"x\", \"from\": \"Bank\", \"to\": \"Shop\", \"cause\": \"c\"},
        {\"msg\": \"PaymentDeclined\", \"from\": \"Shop\", \"to\": \"Client\", \"cause\": \"x\", \"status\": 402}]]}],
    [{\"msg\": \"SoldOut\", \"from\": \"Shop\", \"to\": \"Client\", \"cause\": \"o\", \"status\": 409}]]}
]}
```
"

end LeanFM.SessionTools
