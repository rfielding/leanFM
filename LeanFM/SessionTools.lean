import Lean.Data.Json
import LeanFM.Session.Global
import LeanFM.Session.Http
import LeanFM.Session.Diagram
import LeanFM.Session.Calls
import LeanFM.Session.Events
import LeanFM.Session.Text
import LeanFM.Session.Conform
import LeanFM.Session.Skeleton
import LeanFM.Session.SkeletonTs

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

def parseProtocol (args : Json) : Except String Protocol := do
  if args.compress.length > limits.maxArgumentBytes then
    throw s!"arguments exceed {limits.maxArgumentBytes} bytes"
  if let .ok v := args.getObjVal? "lean" then
    let text ← match v.getStr? with
      | .ok t => pure t
      | .error _ => throw "lean must be a string of LeanFM protocol text"
    let r ← LeanFM.Session.Text.parse text
    return { name := r.name, roles := r.roles, global := r.global, steps := r.steps, lean := text }
  let p ← match args.getObjVal? "protocol" with
    | .ok p => pure p
    | .error _ => throw "lean is required: LeanFM protocol text such as protocol Ping (A, B) { p: Ping from A to B; Pong from B to A cause p; }; read leanfm://language/session-reference"
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
  return { name, roles, global, steps := count, lean := ToText.write name roles js }

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

def diagramJson (p : Protocol) : Json :=
  let m := p.global.diagramModel p.roles p.name
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
  let cuts := match calls with
    | some pairs => g.httpCuts (fun _ _ => true) (fun a b => pairs.contains (a, b))
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
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol")
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
  let m := p.global.diagramModel p.roles p.name
  return fit <| Json.mkObj
    [ ("tool", "session_diagram"), ("verdict", "drawn")
    , ("reading", s!"{p.name}: sequence diagram of {messageCount p.global} messages across {p.roles.length} lifelines")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol")
    , ("svg", m.svg (themeOf args)), ("diagram", diagramJson p) ]

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
  -- a protocol without a sessions block runs as `instances` concurrent copies of itself
  let g := if hasSessions p.global then p.global else .sessions p.global .done
  let evs := g.simulate seed instances spread loops maxEvents
  let sessions := (evs.toList.map (·.session)).eraseDups.length
  return fit <| Json.mkObj
    [ ("tool", "session_simulate"), ("verdict", "generated")
    , ("reading", s!"{p.name}: {evs.size} events from {sessions} session{if sessions == 1 then "" else "s"} (seed {seed})")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol")
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
  return fit <| Json.mkObj
    [ ("tool", "session_conform"), ("verdict", verdict), ("reading", reading), ("name", p.name)
    , ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol")
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
    return Json.mkObj [("tool", "session_next"), ("verdict", verdict), ("name", p.name),
      ("roles", Json.arr (p.roles.map Json.str).toArray),
      ("reading", s!"{p.name}: after {evs.length} event{if evs.length == 1 then "" else "s"}, {what}{ending}"),
      ("next", Json.arr (steps.map stepJson).toArray), ("canEnd", canEnd), ("lean", p.lean)]

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

def toolNames : List String := ["session_check", "session_diagram", "session_simulate", "session_conform", "session_skeleton", "session_next"]

def run (name : String) (args : Json) : Option (Except String Json) :=
  match name with
  | "session_check" => some (check args)
  | "session_diagram" => some (diagram args)
  | "session_simulate" => some (simulate args)
  | "session_conform" => some (conform args)
  | "session_skeleton" => some (skeleton args)
  | "session_next" => some (next args)
  | _ => none

/-! ## Reference -/

def reference : String := "# LeanFM session types

Design interactions between roles as a session type in LeanFM's protocol syntax, then let LeanFM
check it, draw it and run it. Every diagram, call list and event stream is generated from the text.
Send the text as the `lean` argument of the tools. It is read by a parser for this grammar only:
nothing in it is elaborated or run, and a `where` condition is shown, never evaluated.

## Tools

- `session_check {lean, mayCall?}`: the core rules (one role decides each choice; every role can
  tell which branch was taken; a cause names a message its sender saw), each role's local type and
  typestate API, the calls (request, responses with status, nested calls), and the diagram. With
  `mayCall: [[caller, callee], ...]`, every channel is HTTP and calls that break the request/response
  discipline are reported.
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

- `session_skeleton {lean, language?}`: a self-contained Python (the default) or TypeScript
  (`\"language\": \"typescript\"`) module with every role's typestate as classes, one per state. In
  TypeScript a step the state does not allow does not type-check, and `receive` returns a union
  tagged by `label` that narrows `next`. A method sends only what its state allows, fills in the cause the
  protocol names, logs the event in session_conform's format and returns the next state; `receive`
  accepts only what the state allows; a state used twice raises. Write only the decisions (which
  branch, what each message carries) and the transport: a function that delivers a message.

Every answer echoes the text as `lean`; the view shows it in an editor and rechecks as you type.

## Building software from a protocol

1. Write the protocol and run session_check until it has no issues; with `mayCall` for HTTP.
2. Show it: the diagram, each role's typestate (its API: one state per point in the conversation),
   and session_simulate's stream.
3. Generate the roles' states with session_skeleton and implement each role on them: per session,
   keep the state the last method returned and decide what to do next; the generated methods send
   only what each state allows, fill in causes and log every message. (In another language, write a
   handler per typestate state the same way.)
4. Log every message as an event with the protocol's label, the session it belongs to and the
   event that caused it (the generated module does this; give it a log function).
5. Run it, and check the log with session_conform; fix the code (or, if the protocol was wrong, the
   protocol) until every session conforms.

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
| `choice { ... } or { ... }` | exactly one branch happens; the role that starts every branch decides (⊕, internal choice: `select ⊕` in its projection); the others learn the branch from what arrives (&, external choice: `offer &`) |
| `par { ... } and { ... }` | branches run concurrently; what follows waits for all |
| `join 2 of { ... } and { ... } and { ... }` | what follows waits for any 2 branches |
| `rec Loop { ... continue Loop; }` | a loop; `continue` is the last statement of its block |
| `sessions { ... }` | any number of independent instances, as a server handles requests |
| `include Replicate Primary R1 R2 R3;` | an earlier protocol in the same text, roles renamed in order, drawn as a ref frame |

Write several protocols in one text to include one in another; the last protocol is the one
checked. Names are Lean identifiers (`«two words»` works). `--` and `/- -/` comments are allowed.
Statements after a choice continue every branch. Limits: 64 KiB of text, 200 statements, 12 roles,
16 branches per construct, nesting 24 deep, names and strings of 200 characters; simulations up to
200 instances and 600 events.

## Reading the answers

- A choice whose branches are started by different roles is a race; pick one decider.
- \"R cannot tell which branch C chose\": give R a message in every branch, or one that differs.
- \"L: S never saw y\": the cause of L must be something its sender sent or received.
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
