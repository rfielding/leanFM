import Lean.Data.Json
import LeanFM.Session.Global
import LeanFM.Session.Http
import LeanFM.Session.Diagram
import LeanFM.Session.Calls
import LeanFM.Session.Events
import LeanFM.Session.Text
import LeanFM.Session.Proto
import LeanFM.Session.SpecCheck
import LeanFM.Session.Faithful
import LeanFM.Session.Suggest
import LeanFM.Session.LogSessions
import LeanFM.Session.Actors
import LeanFM.Session.Spans
import LeanFM.Session.Instances
import LeanFM.Session.Deployment
import LeanFM.Session.Versions
import LeanFM.Session.LeanGen
import LeanFM.Session.Generative
import LeanFM.Session.Decision
import LeanFM.Session.Chain
import LeanFM.Session.Sla
import LeanFM.Session.Conform
import LeanFM.Session.Linked
import LeanFM.Session.Skeleton
import LeanFM.Session.SkeletonTs
import LeanFM.Session.Evolution
import LeanFM.Session.OpenApi
import LeanFM.Session.Review
import LeanFM.Session.ActorView
import LeanFM.Session.Realizable
import LeanFM.Session.Dataset
import LeanFM.Session.Outline
import LeanFM.Session.Derived
import LeanFM.Session.Layout
import LeanFM.Logic

/-!
# Session-type tools for MCP agents (clauses selfhost.mcp.session.tools, selfhost.mcp.session.view)

`session_check`, `session_diagram` and `session_simulate` take a protocol in a closed JSON form,
build the same `Global String` the `protocol` command builds, and answer with the session library:
issues, projections, calls, typestate, the diagram as shapes and SVG, and seeded event streams.

A protocol is data: no field carries code, a guard's `where` text is interpreted, never run as code,
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

def stepKinds : List String := ["msg", "event", "choice", "parallel", "join", "loop", "continue", "sessions", "include"]

def allowedKeys : String → List String
  | "msg" => ["msg", "from", "to", "id", "cause", "route", "status", "media", "where"]
  | "event" => ["event", "at"]
  | "choice" => ["choice"]
  | "parallel" => ["parallel"]
  | "join" => ["join", "of"]
  | "loop" => ["loop", "steps"]
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
    if keys.isEmpty then fail c "a step must be an object with one of the keys msg, event, choice, parallel, join, rec, continue, sessions, include"
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
        let media ← optString c j "media"
        if let some m := media then
          if !Session.Text.validMedia m then fail c s!"media \"{m}\" is not a media type: write type/subtype in lower case, such as \"image/png\""
        let guardText ← optString c j "where"
        -- a where clause in the JSON form is text: conformance interprets it, nothing runs it as code
        let guard := guardText.map fun t => ({ text := t } : Guard)
        let i : Interaction String := { id, label, src, dst, cause, status, route, media, guard }
        return .msg i (← next ())
    | "event" =>
        let label ← reqString c j "event"
        let r ← role c j "at"
        return .act r label (← next ())
    | "choice" =>
        let bs ← branches c j "choice"
        return Global.andThen (.choice bs) (← next ())
    | "parallel" =>
        let bs ← branches c j "parallel"
        return .par bs (← next ())
    | "join" =>
        let n ← match j.getObjVal? "join" with
          | .ok v => match v.getNat? with | .ok n => pure n | .error _ => fail c "join must be a number"
          | .error _ => fail c "join must be a number"
        let bs ← branches c j "of"
        if n == 0 || n > bs.length then fail c s!"join {n} of {bs.length} branches is out of range"
        return .join n bs (← next ())
    | "loop" =>
        let name ← reqString c j "loop"
        let body ← nested { c with loops := name :: c.loops } (← stepList c j "steps") "steps"
        return Global.andThen (.loop name body) (← next ())
    | "continue" =>
        let name ← reqString c j "continue"
        if !c.loops.contains name then fail c s!"continue {name} is not inside loop {name}"
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
  /-- the message types the text declares (selfhost.session.types) -/
  types : Session.Types.Env := []
  /-- session keys, (message id, field path) (selfhost.session.envelope) -/
  keys : List (String × String) := []
  /-- Link fields an include renames, (label, field) to the Fresh field named (selfhost.session.identity.scopes) -/
  linkTargets : List ((String × String) × String) := []
  parentLinks : List (String × String) := []
  /-- sessions bodies whose copies cannot be told apart (selfhost.session.identity.scopes) -/
  identityNotes : List String := []
  /-- the main protocol's version, 0 when it has none (selfhost.session.versions) -/
  version : Nat := 0
  /-- each version of the main protocol, oldest first: (number, roles, global type); empty when
  it has one version -/
  versions : List (Prod Nat (Prod (List String) (Global String))) := []
  /-- each version checked against the one before it, with the upgrade order found -/
  upgrades : List Versions.Upgrade := []
  /-- the main protocol's labels across its versions: each one's payload field number -/
  labelHistory : List String := []

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
      ((j.getObjVal? "status").toOption.bind (·.getNat?.toOption))
      ((str j "media").filter Session.Text.validMedia) (str j "where")
  if let some l := str j "event" then return .event l ((str j "at").getD "")
  if (j.getObjVal? "choice").isOk then return .choice (← branchesOf roles j "choice")
  if (j.getObjVal? "parallel").isOk then return .par (← branchesOf roles j "parallel")
  if let .ok v := j.getObjVal? "join" then
    return .join (v.getNat?.toOption.getD 1) (← branchesOf roles j "of")
  if let some n := str j "loop" then return .loop n (← listOf roles j "steps")
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

def generativeLayer (body : List Text.Stmt) (roles : List String) (args : Json) : Except String (Option Generative.Resolved) := do
  let r ← Generative.resolve body ((args.getObjVal? "overlay").toOption.filter (· != Json.null))
  if !r.active then return none
  match Generative.compile r roles with
  | .ok _ => return some r
  | .error e =>
    -- constructs the tree and the simulator cannot run, but the chain can: keep the layer, say why
    if e.startsWith "timed generation/monitoring supports" || e.startsWith "accrue needs the chain view" ||
       e.startsWith "after on an event" then
      -- say what does and does not run: with a loop or a rate the chain generates (session_simulate,
      -- session_dataset) and solves it (session_mdp); only the finite-path deadline monitor cannot
      let note := if hasLoop body
        then "Generation and expectations use the chain view: session_simulate, session_dataset and session_mdp run this protocol with its loops and rates. Per-session deadline monitoring needs finite paths (no rec, parallel, join, sessions or include), so session_conform gives no deadline reports for it."
        else e
      return some { r with metadata := Json.mkObj [("layer", r.metadata), ("executionUnsupported", note)] }
    throw e

def generativeJson (p : Protocol) : Json := (p.generative.map (·.metadata)).getD Json.null

/-- The JSON form's `types`, `[{name, fields: ["amount : Nat", ...]}]`, as structure declarations.
Names and fields are checked to be only identifiers, `:` and spaces, so they cannot carry other
text into the protocol. -/
def jsonTypesText (j : Json) : Except String String := do
  match j with
  | .null => return ""
  | .arr a =>
    if a.size > Types.maxMessages then throw s!"at most {Types.maxMessages} types"
    let plain (s : String) : Bool := s.toList.all fun c => (c.isAlphanum && c.toNat < 128) || c == '_' || c == ' ' || c == ':'
    let decls ← a.toList.mapM fun t => do
      let name ← (t.getObjValAs? String "name").mapError fun _ => "every type needs a name"
      if !Types.isAsciiIdent name then throw s!"type {name.quote}: a name is letters, digits and _"
      let fs ← match t.getObjVal? "fields" with
        | .ok (.arr fa) => fa.toList.mapM fun f => match f.getStr? with
          | .ok x => if plain x && x.length ≤ limits.maxString && (x.splitOn ":").length == 2 then pure x
                     else throw s!"type {name}: a field is written \"name : Type\", not {x.quote}"
          | .error _ => throw s!"type {name}: fields are strings such as \"amount : Nat\""
        | .error _ => pure []
        | _ => throw s!"type {name}: fields is an array of strings such as \"amount : Nat\""
      return "structure " ++ name ++ (if fs.isEmpty then "" else " where\n" ++ "\n".intercalate (fs.map ("  " ++ ·))) ++ "\n"
    return "\n".intercalate decls ++ "\n"
  | _ => throw "types is an array of {name, fields: [\"amount : Nat\", ...]}"

/-- The message types from the `proto` argument, a proto3 file's text (selfhost.session.proto). -/
def protoTypes (args : Json) : Except String (Option Session.Types.Env) := do
  match args.getObjVal? "proto" with
  | .error _ | .ok .null => return none
  | .ok (.str t) => return some (← Session.Proto.ofProto t)
  | .ok _ => throw "proto is the text of a proto3 file"

/-- Protocols LeanFM carries, compiled in, so a client that cannot send a file (Claude Desktop, a
phone) can name one: `example: "goserver"` instead of `lean` (clause selfhost.session.explorer). A
fixed list of names: no argument names a path, and nothing is read from disk. Lake does not track
include_str, so after one of these files changes, MCPTests (which compares each with its file)
fails until this module is rebuilt (GoServer's now starts at sign-in, runs each game as a session its players join, and polls its game list beside the lobby). -/
def examples : List (String × String × String) :=
  [ ("goserver", "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm",
      include_str "../projects/GoServer/source/cmd/demo/static/session/goserver.leanfm")
  , ("ride", "examples/sessions/Ride.leanfm", include_str "../examples/sessions/Ride.leanfm")
  , ("boundedride", "examples/sessions/BoundedRide.leanfm", include_str "../examples/sessions/BoundedRide.leanfm")
  , ("placeorder", "examples/sessions/PlaceOrder.leanfm", include_str "../examples/sessions/PlaceOrder.leanfm")
  , ("lending", "examples/vibecode/lending/Lending.protocol", include_str "../examples/vibecode/lending/Lending.protocol") ]

/-- The names, as the tools offer them (the examples above are compiled in: see examples). -/
def exampleNames : List String := examples.map (·.1)

/-- The arguments with `example` replaced by that example's text as `lean`. -/
def withExample (args : Json) : Except String Json := do
  match args.getObjVal? "example" with
  | .error _ => pure args
  | .ok (.str n) =>
    if (args.getObjVal? "lean").isOk || (args.getObjVal? "protocol").isOk then
      throw "give example or lean (or protocol), not both"
    match examples.find? (·.1 == n) with
    | some (_, _, text) => pure ((match args with | .obj kvs => Json.obj (kvs.erase "example") | j => j).setObjVal! "lean" (Json.str text))
    | none => throw s!"example must be one of {", ".intercalate exampleNames}"
  | .ok _ => throw s!"example must be the name of one of LeanFM's examples: {", ".intercalate exampleNames}"

def parseProtocol (args0 : Json) : Except String Protocol := do
  if args0.compress.length > limits.maxArgumentBytes then
    throw s!"arguments exceed {limits.maxArgumentBytes} bytes"
  let args ← withExample args0
  if args.compress.length > limits.maxArgumentBytes then
    throw s!"arguments exceed {limits.maxArgumentBytes} bytes"
  if let .ok v := args.getObjVal? "lean" then
    let text ← match v.getStr? with
      | .ok t => pure t
      | .error _ => throw "lean must be a string of LeanFM protocol text"
    let r ← LeanFM.Session.Text.parse text (← protoTypes args)
    -- a version without a clean upgrade path from the one before is refused, as the Lean
    -- elaborator refuses it (selfhost.session.versions)
    let upgrades <- Versions.check r
    return { name := r.name, roles := r.roles, global := r.global, steps := r.steps, lean := text, generative := <- generativeLayer r.body r.roles args, types := r.types, keys := r.keys, linkTargets := r.linkTargets, parentLinks := r.parentLinks, identityNotes := r.identityNotes,
             version := r.version, versions := (r.versioned.lookup r.name).getD [], upgrades,
             labelHistory := Versions.labelHistory r }
  let p ← match args.getObjVal? "protocol" with
    | .ok p => pure p
    | .error _ => throw "lean is required: LeanFM protocol text such as protocol PingPong (A, B) { p: Ping from A to B; Pong from B to A cause p; }; read leanfm://language/session-reference"
  if p.getStr?.isOk then
    throw "protocol is the JSON form {name?, roles, steps, types?}; put LeanFM protocol text in lean instead"
  let extra := (keysOf p).filter (!["name", "roles", "steps", "types"].contains ·)
  if !extra.isEmpty then throw s!"protocol has unknown keys {extra}; allowed: name, roles, steps, types"
  let typesText ← jsonTypesText (p.getObjValD "types")
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
  -- the echoed text is a whole Lean file (selfhost.session.lean-syntax)
  let text := Text.header ++ typesText ++ ToText.write name roles js
  let parsed ← Text.parse text (← protoTypes args)
  return { name, roles, global, steps := count, lean := text, generative := ← generativeLayer parsed.body roles args, types := parsed.types, keys := parsed.keys, linkTargets := parsed.linkTargets, parentLinks := parsed.parentLinks, identityNotes := parsed.identityNotes }

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

/-- A sequence diagram for a view: its shapes, and for folding and eliding (clause
selfhost.session.diagram.folds) its lanes, rows and calls. The shapes are the same either way. -/
def modelJson (m : DiagramModel) : Json :=
  Json.mkObj [("width", m.width), ("height", m.height), ("shapes", Json.arr (m.shapes.map shapeJson)),
    ("colW", m.colW),
    ("lanes", Json.arr (m.lanes.map fun (r, x) => Json.mkObj [("role", r), ("x", x)]).toArray),
    ("steps", Json.arr (m.steps.map fun w => Json.mkObj [("top", w.top), ("y", w.y), ("bottom", w.bottom),
      ("src", w.src), ("dst", w.dst)])),
    ("calls", Json.arr (m.calls.map fun c => Json.mkObj [("request", c.request), ("caller", c.caller),
      ("callee", c.callee), ("label", Json.str s!"{c.reqLabel} -> {c.resLabel}"),
      ("top", c.top), ("y", c.y), ("bottom", c.bottom), ("depth", c.depth),
      ("roles", Json.arr (c.roles.map Json.str).toArray)]))]

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
      let note := " - ".intercalate (pending.toList ++ amounts.map amountNote ++ (time.map timeNote).toList)
      modify (·.push note)
      let tagged := match core with
        | .msg id label src dst cause route status media guard => Text.Stmt.msg id (label ++ tag ++ toString k) src dst cause route status media guard
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
  let some layer := p.generative | return p.global.diagramModel p.roles p.name (keys := p.keys)
  let (tagged, notes) := (Annotate.tagStmts none layer.body).run #[]
  if notes.all (· == "") then return p.global.diagramModel p.roles p.name (keys := p.keys)
  let .ok g := Text.buildWith p.lean tagged | return p.global.diagramModel p.roles p.name (keys := p.keys)
  -- expected counts and totals from the chain, when it can be solved without a horizon
  let chain := (Chain.analyse { layer with body := tagged }).toOption
  let counts : Array String := match chain with
    | some c => (List.range notes.size).toArray.map fun k =>
        let t := c.edges.foldl (fun acc e => if (Annotate.untag e.step).2 == some k then acc + Chain.traversals c e else acc) 0
        s!"x{Chain.ratText t}"
    | none => #[]
  -- the legend comes from the untagged chain, so no position tag reaches the reader
  let footer : List String := match (Chain.analyse layer).toOption with
    | some c =>
      let d := Chain.expectedDuration c
      Chain.legend c p.roles ++ (if d == 0 then [] else [s!"Expected duration per session: {Chain.daysText d}"])
    | none => []
  let full := (List.range notes.size).toArray.map fun k =>
    " - ".intercalate (([notes[k]!] ++ (counts[k]?).toList).filter (· != ""))
  let (order, plain) := Annotate.strip g
  return plain.diagramModel p.roles p.name (order.toArray.map fun k => (full[k]?).getD "") footer p.keys

def diagramJson (p : Protocol) : Json := modelJson (annotatedModel p)

def themeOf (args : Json) : DiagramTheme :=
  match (args.getObjValAs? String "theme").toOption with
  | some "light" => .light
  | _ => .dark

def eventJson (e : Event String) : Json :=
  Json.mkObj [("id", e.id), ("session", e.session), ("thread", Json.str s!"{e.src}@{e.session}"), ("time", e.time),
    ("prior", Json.arr (e.prior.map toJson).toArray), ("cause", toJson e.cause),
    ("answers", toJson e.answers), ("src", e.src), ("dst", e.dst), ("label", e.label),
    ("msgId", toJson e.msgId), ("route", toJson e.route), ("status", toJson e.status),
    ("act", e.isAct)]

/-- A timestamp or other integer as the protobuf JSON mapping sends it: a decimal string, or a JSON
number that is whole and within 2^53 - 1 (beyond that a double has already lost the low bits). -/
def wireNat (j : Json) : Except String Nat :=
  match j with
  | .str t => match Session.Types.decimal? t with
    | some n => if n < 0 then .error s!"{t} is negative" else .ok n.toNat
    | none => .error s!"{t.quote} is not a decimal integer"
  | .num n =>
    if n.exponent != 0 then .error s!"{n.toString} is not a whole number"
    else if n.mantissa < 0 then .error s!"{n.toString} is negative"
    else if n.mantissa.natAbs > Session.Types.maxSafe then .error s!"{n.toString} is beyond 2^53 - 1, where JSON numbers are not exact; send it as a decimal string"
    else .ok n.mantissa.natAbs
  | _ => .error s!"{j.compress} is not an integer"

/-- Give every event of a generated stream `ts`: nanoseconds as a decimal string, unique in the
stream and later than every event it happened after (its prior events and its cause). The time
(ms, or the step of an untimed run counted as 1 ms) times 10^6 is where it starts; an event that
would share or precede one already stamped is moved 1 ns past it (selfhost.session.envelope). -/
def stampNs (evs : Array Json) : Array Json := Id.run do
  let num (j : Json) (k : String) : Option Nat := (j.getObjValAs? Nat k).toOption
  let before (j : Json) : List Nat :=
    (match j.getObjValD "prior" with | .arr a => a.toList.filterMap (·.getNat?.toOption) | _ => []) ++ (num j "cause").toList
  let order := (List.range evs.size).toArray.qsort fun a b =>
    let ta := (num evs[a]! "time").getD 0
    let tb := (num evs[b]! "time").getD 0
    ta < tb || (ta == tb && a < b)
  let mut stamped : Std.HashMap Nat Nat := {}   -- event id to ts
  let mut out := evs
  let mut last : Option Nat := none
  let mut pending := order.toList
  let mut fuel := evs.size + 1
  while !pending.isEmpty && fuel > 0 do
    fuel := fuel - 1
    let mut later : List Nat := []
    for i in pending do
      let e := evs[i]!
      let ps := before e
      if ps.all fun x => stamped.contains x || !(evs.any fun f => num f "id" == some x) then
        let base := ((num e "time").getD 0) * 1000000
        let after := (ps.filterMap stamped.get?).foldl max 0
        let ts := [some base, last.map (· + 1), if ps.any stamped.contains then some (after + 1) else none].filterMap id |>.foldl max 0
        last := some ts
        if let some id := num e "id" then stamped := stamped.insert id ts
        out := out.set! i (e.setObjVal! "ts" (Json.str (toString ts)))
      else later := later ++ [i]
    pending := later
  return out

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
  -- the SVG first (the view draws from the shapes in diagram), then per-role and per-call detail
  -- that session_actor gives for one role, duplicates (openapi when openapiYaml has it, proto which
  -- session_types gives) and the protocol text's echo (the caller sent it, or named the example);
  -- the shapes last, since without them the view has no drawing at all
  for key in ["svg", "projections", "calls", "types", "openapi", "proto", "lean", "diagram"] do
    if b.compress.length > limits.maxResult && (b.getObjVal? key).isOk && b.getObjValD key != Json.null then
      if key == "openapi" && !(b.getObjVal? "openapiYaml").isOk && !(b.getObjVal? "code").isOk then continue
      b := b.setObjVal! key Json.null
      omitted := omitted ++ [match key with
        | "projections" => "projections (each role's local type and typestate: session_actor gives one role's)"
        | "openapi" => "openapi (the same document is in openapiYaml)"
        | "proto" => "proto (session_types gives it)"
        | "lean" => "lean (the protocol text you sent, or the example you named)"
        | k => k]
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
  let issues := g.issues p.roles ++ g.httpIssues
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
    -- sessions bodies whose copies cannot be told apart; the verdict does not depend on them
    -- (selfhost.session.identity.scopes)
    , ("identity", Json.arr (p.identityNotes.map Json.str).toArray)
    , ("types", Json.arr (p.types.map fun m => Json.mkObj [("name", Json.str m.name),
        ("fields", Json.arr (m.fields.map fun f => Json.str s!"{f.name} : {f.render}").toArray)]).toArray)
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

/-- A distribution's report lines and JSON: per role and unit, its values with probabilities (all of
them when there are few; otherwise its range and most likely value). -/
def distributionReport (ms : List (String × String × List (Rat × Rat))) : List String :=
  ms.map fun (r, u, vals) =>
    let mean := vals.foldl (fun acc (x, p) => acc + x * p) 0
    if vals.length ≤ 12 then
      s!"- {r} {u}: " ++ ", ".intercalate (vals.map fun (x, p) => s!"{Chain.readable x} ({Chain.readable p true})") ++ s!"; mean {Chain.readable mean}"
    else
      let best := vals.foldl (fun b (x, p) => if p > b.2 then (x, p) else b) (0, 0)
      s!"- {r} {u}: {vals.length} values from {Chain.readable ((vals.head?).map (·.1) |>.getD 0)} to " ++
        s!"{Chain.readable ((vals.getLast?).map (·.1) |>.getD 0)}; most likely {Chain.readable best.1} ({Chain.readable best.2 true}); mean {Chain.readable mean}"

def distributionJson (ms : List (String × String × List (Rat × Rat))) : Json :=
  let roles := (ms.map (·.1)).eraseDups
  Json.mkObj (roles.map fun r => (r, Json.mkObj ((ms.filter (·.1 == r)).map fun (_, u, vals) =>
    (u, toJson (vals.map fun (x, p) => Json.mkObj [("value", Chain.ratText x), ("probability", Chain.ratText p)])))))

/-- An MDP answer within the response limit: when it is too large, drop the redundant parts in order
(the drawing's shapes, which repeat its SVG; then the per-state, per-edge and per-node detail, which
the text report summarizes) and say which were dropped; refuse only if it still does not fit. -/
def fitMdp (result0 : Json) : Except String Json := do
  -- "= ≈ 0.35" reads as "≈ 0.35", and "×≈ 8.89" as "≈ ×8.89"
  let tidy (t : String) : String := (t.replace " = ~" " ~").replace "x~" "~x"
  let result := match result0.getObjValAs? String "report" with
    | .ok t => result0.setObjVal! "report" (Json.str (tidy t))
    | .error _ => result0
  if result.compress.length ≤ limits.maxResult then return result
  let mut r := result
  let mut dropped : List String := []
  for (keys, what) in [(["diagram"], "the drawing's shapes (its svg is kept)"),
                       (["states", "edges", "nodes", "terminals"], "the per-state, per-edge and per-node detail (the report keeps the numbers)"),
                       (["distributionSvg"], "the histogram drawing"),
                       (["distribution"], "the full distribution data (the report summarizes it)")] do
    if r.compress.length > limits.maxResult then
      for k in keys do
        if (r.getObjVal? k).isOk then r := r.setObjVal! k Json.null
      dropped := dropped ++ [what]
  if r.compress.length > limits.maxResult then throw "MDP output exceeds response limit; simplify the session"
  let note := "To fit the response limit, this answer leaves out " ++ " and ".intercalate dropped ++ "."
  let report := (r.getObjValAs? String "report").toOption.getD ""
  return (r.setObjVal! "omitted" (toJson dropped)).setObjVal! "report" (Json.str (report ++ "\n" ++ note))

/-- session_mdp for a session with loops, or when view is chain: expected visits, traversals and
amounts from the absorbing chain (selfhost.session.mdp.loops). -/
def mdpChain (args : Json) (p : Protocol) (layer : Generative.Resolved)
    (solved : Option Chain.Chain := none) (extra : List (String × Json) := []) (lead : List String := []) : Except String Json := do
  let c ← match solved with | some c => pure c | none => Chain.analyse layer
  let model ← Chain.drawing c p.roles
  let exp := Chain.expected c p.roles
  let stateLine (s : Chain.State) : String :=
    let name := if s.kind == "state" then s!"S{s.id}" else s.label
    s!"- {name}" ++ (if s.detail.isEmpty then "" else s!" ({s.detail})") ++ s!": {Chain.ratText c.visits[s.id]!}"
  let edgeLines := (c.edges.toList.filter (·.kind == "message")).map fun e =>
    s!"- {e.label}: x{Chain.ratText (Chain.traversals c e)}" ++ (if e.amountText.isEmpty then "" else s!" - {e.amountText}")
  let outcomes := c.ends.map fun k => (k, Chain.outcome c p.roles k)
  let outcomeLines := outcomes.map fun (k, (prob, given)) =>
    s!"- {c.states[k]!.label}: probability {Chain.ratText prob}" ++ match given with
      | some (bal, dur) => (if Chain.balancesText bal == "" then "" else s!", expected {Chain.balancesText bal}") ++
          (if dur == 0 then "" else s!", expected duration {Chain.daysText dur}")
      | none => " (never happens, so nothing is expected given it)"
  let duration := Chain.expectedDuration c
  let report := "\n".intercalate (lead ++ ["Outcomes (how the session ends):"] ++ outcomeLines ++
    ["Expected visits per state:"] ++ c.states.toList.map stateLine ++
    ["Expected traversals per message edge:"] ++ edgeLines ++
    [s!"Expected messages: {Chain.ratText (Chain.expectedMessages c)}"] ++
    (if duration == 0 then [] else [s!"Expected duration: {Chain.daysText duration}"]) ++
    (if exp.isEmpty then [] else ["Expected net balance per role:"] ++ exp.map fun (r,u,v) => s!"- {r}: {Chain.ratText v} {u}") ++
    Chain.legend c p.roles ++ c.notes ++
    (if hasLoop layer.body then ["No distribution: with loops and no horizon its support is infinite; bound the loop (loop Name at most N) or pass a horizon behind a gate."] else []))
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
      ("eventSource", provenance.eventSource), ("reducer", "Build the state graph; solve v = start + vQ over transient states with exact rationals; traversals = visits times probability; balances = Σ traversals times mean amount"),
      ("unit", "expected counts and amounts as exact rationals, per complete session"),
      ("boundary", "One session from start until it ends, which happens with probability 1 (otherwise the tool refuses); delays are after the previous step (after d); absolute times and deadlines are not used")])]
  fitMdp (extra.foldl (fun r (k, v) => r.setObjVal! k v) result)

/-- session_mdp with optimize: the best branch at every open choice for one role's objective,
by exact policy iteration (selfhost.session.mdp.optimize). -/
def mdpOptimize (args : Json) (p : Protocol) (layer : Generative.Resolved) (o : Json) : Except String Json := do
  let role ← (o.getObjValAs? String "role").mapError fun _ => "optimize needs role, unit and goal (max or min)"
  let unit ← (o.getObjValAs? String "unit").mapError fun _ => "optimize needs role, unit and goal (max or min)"
  let goal := (o.getObjValAs? String "goal").toOption.getD "max"
  if !["max", "min"].contains goal then throw "optimize goal must be max or min"
  if !p.roles.contains role then throw s!"optimize role {role} is not a role of the protocol"
  let c0 ← Chain.analyse layer (allowOpen := true)
  let opens := c0.states.toList.filter (·.kind == "open")
  if opens.isEmpty then throw "optimize needs at least one open choice (a choice without probabilities)"
  if unit != "time" && !(c0.edges.any fun e => (Chain.rewards c0 e).any fun (r, u, _) => r == role && u == unit) then
    throw s!"no step or rate gives {role} any {unit}; use one of the session's units, or time"
  let objective : Chain.Objective := { role, unit, maximize := goal == "max" }
  let best ← Chain.optimize c0 objective
  let c := best.chain
  let shown (x : Rat) : String := if unit == "time" then Chain.daysText x else s!"{Chain.ratText x} {unit}"
  let firstOf (i : Nat) : String := c.edges[i]!.step
  let choiceJson := best.choices.map fun (s, chosen, branches) => Json.mkObj
    [("state", toJson s), ("decider", c.states[s]!.label.replace " chooses (open)" ""),
     ("chosen", firstOf chosen),
     ("branches", toJson (branches.map fun (i, v) => Json.mkObj [("first", firstOf i), ("value", Chain.ratText v), ("valueText", shown v)]))]
  let lead := [s!"Optimal policy for {role}, {goal}imizing expected {unit} (exact policy iteration, {best.rounds} rounds):"] ++
    best.choices.map (fun (s, chosen, branches) =>
      s!"- at S{s}, {c.states[s]!.label.replace " chooses (open)" ""} picks {firstOf chosen}. From this choice on, following the policy afterwards: " ++
      ", ".intercalate (branches.map fun (i, v) => s!"{firstOf i} gives {shown v}")) ++
    [s!"Optimal value from the start: {shown best.value}"] ++
    (if best.excluded then ["A policy that never ends would have scored better and was excluded: only policies that end with probability 1 count."] else []) ++
    ["The other roles' numbers below are what they get under this policy, not their own optimum."]
  mdpChain args p layer (solved := some c) (lead := lead) (extra := [
    ("view", "optimize"),
    ("objective", Json.mkObj [("role", role), ("unit", unit), ("goal", goal)]),
    ("policy", toJson choiceJson), ("optimalValue", Chain.ratText best.value),
    ("rounds", toJson best.rounds), ("excludedNonEnding", toJson best.excluded),
    ("reading", "An MDP: open choices are actions, weighted choices are the environment. Policy iteration starts from a policy under which every state ends, evaluates it exactly (V = R + QV over exact rationals) and switches an open choice only to a strictly better branch that still ends; it stops when no switch helps. The chain is then solved again with the chosen branches at probability 1.")])

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
  let horizonMs ← (Text.durationText text).mapError (s!"horizon: " ++ ·)
  let c0 ← Chain.analyse layer (solveAll := false)
  let h ← Chain.horizon c0 horizonMs
  let c := h.chain
  let model ← Chain.drawing c p.roles
  let exp := Chain.expected c p.roles
  let duration := Chain.expectedDuration c
  let edgeLines := (c.edges.toList.filter fun e => e.kind == "message" || e.kind == "event").map fun e =>
    s!"- {e.label}: x{Chain.readable (Chain.traversals c e)}" ++ (if e.amountText.isEmpty then "" else s!" - {e.amountText}")
  let remainder := horizonMs - h.periods * h.periodMs
  -- the exact distribution over the periods, when it is small enough to enumerate
  let distResult := Chain.horizonDistribution c0 h
  let dist := match distResult with
    | .ok d => (Chain.marginals d.outcomes p.roles).filter fun (_, _, vals) => vals.any (·.1 != 0)
    | .error _ => []
  let passages := match distResult with | .ok d => d.passages | .error _ => []
  let distLines := match distResult with
    | .ok _ =>
      let N := h.periods
      let atLeast (k : Nat) : Rat := passages.foldl (fun acc (j, q) => if j ≥ k then acc + q else acc) 0
      let marks := ([N / 4, N / 2, (3 * N) / 4, N].filter (· ≥ 1)).eraseDups
      ["Distribution (value (probability)):"] ++ distributionReport dist ++
        ["- gate passages: " ++ ", ".intercalate (marks.map fun k => s!"P(at least {k}) = {Chain.readable (atLeast k) true}") ++
         s!", P(none) = {Chain.readable ((passages.head?).map (·.2) |>.getD 0) true}"]
    | .error e => [s!"No distribution: {e}"]
  let report := "\n".intercalate ([s!"Over {h.periods} whole periods of {Chain.periodText h.periodMs}:",
      s!"- gate passages: {Chain.readable h.passages}", s!"- still running at the horizon: probability {Chain.readable h.stillRunning true}",
      s!"- expected time: {Chain.daysText duration}"] ++
    (if remainder == 0 then [] else [s!"- the last {Chain.daysText (remainder : Nat)} (a partial period) is not counted"]) ++
    ["Expected traversals per step:"] ++ edgeLines ++
    (if exp.isEmpty then [] else ["Expected totals per role:"] ++ exp.map fun (r,u,v) => s!"- {r}: {Chain.readable v} {u}") ++
    Chain.legend c p.roles ++ distLines)
  let provenance := Decision.output
  let result := Json.mkObj [("report", report),
    ("tool", "session_mdp"), ("verdict", "drawn"), ("view", "horizon"), ("name", p.name), ("lean", p.lean),
    ("reading", "Whole periods behind a periodic gate: the start's segment and the cycle between gates are solved as absorbing chains; the gate passes q0(1 + q + ... + q^(N-1)) times; the wait at the gate fills each period; rewards are traversals times trade vectors plus rates in force times time. The graph does not depend on the horizon; only the number of periods does."),
    ("periods", h.periods), ("periodMs", h.periodMs), ("horizonMs", horizonMs), ("uncountedMs", remainder),
    ("gatePassages", Chain.ratText h.passages), ("stillRunning", Chain.ratText h.stillRunning),
    ("distribution", distributionJson dist),
    ("passagesDistribution", toJson (passages.map fun (k, q) => Json.mkObj [("passages", toJson k), ("probability", Chain.ratText q)])),
    ("distributionSvg", if dist.isEmpty then Json.null else Json.str ((Chain.histogram s!"{p.name} over {h.periods} periods: distribution per role and unit" dist).svg (themeOf args))),
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
  fitMdp result

/-- Native decision view under the resolved policy (selfhost.session.mdp, .mdp.loops). -/
def mdp (args : Json) : Except String Json := do
  let p ← parseProtocol args
  if !(p.global.issues p.roles).isEmpty then throw "fix protocol issues before rendering the MDP"
  let parsed ← Text.parse p.lean (← protoTypes args)
  let layer ← match p.generative with
    | some r => pure r
    | none => Generative.resolve parsed.body
  let view := (args.getObjValAs? String "view").toOption.getD "auto"
  if !["auto", "tree", "chain"].contains view then throw "view must be tree, chain or auto"
  if (args.getObjVal? "events").isOk || (args.getObjVal? "walk").isOk then return ← mdpWalk args p layer
  if let .ok o := args.getObjVal? "optimize" then
    if o != Json.null then return ← mdpOptimize args p layer o
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
    s!"- {n.mass.text}: {n.label}, {n.detail}" ++ (if money.isEmpty then "" else s!" - {money}")
  let expectedLines := (Decision.expected nodes).map fun (r,u,v) => s!"- {r}: {v} {u}"
  let penaltyLines := (Decision.expectedPenalties nodes).map fun (r,u,v) => s!"- {r} pays {v} {u} in penalties"
  -- the distribution: the terminals grouped by each role and unit's balance
  let outcomes : List (Chain.Vec × Rat) := terminals.toList.map fun n =>
    (n.balances.map fun (r, u, v) => (r, u, (v : Rat)), Chain.qRat n.mass)
  let dist := (Chain.marginals outcomes p.roles).filter fun (_, _, vals) => vals.any (·.1 != 0)
  let distModel := Chain.histogram s!"{p.name}: distribution per role and unit" dist
  let report := "\n".intercalate (["Terminals (probability: outcome):"] ++ terminals.toList.map terminalLine ++
    [s!"P(any violation) = {(Decision.violationMass nodes).text}"] ++
    (if expectedLines.isEmpty then [] else ["Expected net balance per role:"] ++ expectedLines) ++ penaltyLines ++
    (if dist.isEmpty then [] else ["Distribution (value (probability)):"] ++ distributionReport dist))
  let result := Json.mkObj [("report", report),
    ("distribution", distributionJson dist),
    ("distributionSvg", if dist.isEmpty then Json.null else Json.str (distModel.svg (themeOf args))),
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
  fitMdp result

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

/-! ## Example contents for simulated messages (clause selfhost.session.events) -/

/-- The sessionId a simulated session carries: session 0 (the main protocol) is `sess-1`, and every
other session belongs to one of three people, chosen from the seed and the session number. -/
def simSessionId (seed session : Nat) : String :=
  if session == 0 then "sess-1" else s!"sess-{(seed + session * 2654435761) % 3 + 1}"

/-- A `where` literal as a logged field: integers as decimal strings, as the protobuf JSON mapping
writes them and conformance reads them. -/
def whereJson : Session.Where.Value → Json
  | .num q => if q.den == 1 then Json.str (toString q.num) else Json.str s!"{q.num}/{q.den}"
  | .str s => Json.str s
  | .bool b => Json.bool b

/-- Set field `f` to `v`, keeping the fields' order (a field not yet there is added at the end). -/
def setField (fs : List (String × Json)) (f : String) (v : Json) : List (String × Json) :=
  if fs.any (·.1 == f) then fs.map fun (k, w) => if k == f then (k, v) else (k, w) else fs ++ [(f, v)]

/-- Make a `where` clause true by filling the fields of message `me`: `me.f = other.g` copies,
`me.f = literal` sets, `and` does both, `or` the first branch that can be done. `none` for any
other clause, so nothing is invented that the clause would reject. -/
partial def fillWhere (me : String) (look : String → Option (List (String × Json)))
    (fs : List (String × Json)) : Session.Where.Expr → Option (List (String × Json))
  | .bin "and" a b => do
    let fs ← fillWhere me look fs a
    fillWhere me look fs b
  | .bin "or" a b => (fillWhere me look fs a) <|> (fillWhere me look fs b)
  | .bin "=" l r =>
    let valueOf : Session.Where.Expr → Option Json := fun
      | .lit v => some (whereJson v)
      | .path y [g] => if y == me then fs.lookup g else (look y).bind (·.lookup g)
      | _ => none
    match l, r with
    | .path x [f], .path y [g] =>
      if x == me then (valueOf r).map (setField fs f)
      else if y == me then (valueOf l).map (setField fs g) else none
    | .path x [f], _ => if x == me then (valueOf r).map (setField fs f) else none
    | _, .path y [g] => if y == me then (valueOf l).map (setField fs g) else none
    | _, _ => none
  | _ => none

/-- Make a message's constraint fields hold in its example contents: a bound on one field
(`amount >= 5`, `quantity <= 100`, `0 < n`) moves the field to the nearest value that keeps it,
`and` does both. `none` when the constraints still fail, so no stream carries contents its
constructors would reject. -/
def fillConstraints (m : Session.Types.Message) (fs : List (String × Json)) : Option (List (String × Json)) := Id.run do
  let toV : Json -> Session.Where.Value := fun
    | Json.str t => match t.toInt? with
      | some n => Session.Where.Value.num n
      | none => Session.Where.Value.str t
    | Json.num n => Session.Where.Value.num ((n.mantissa : Rat) / ((10 ^ n.exponent : Nat) : Rat))
    | Json.bool b => Session.Where.Value.bool b
    | _ => Session.Where.Value.str ""
  let rec bounds : Session.Where.Expr -> List (String × String × Int)
    | .bin "and" a b => bounds a ++ bounds b
    | .bin op (.path x []) (.lit (.num q)) => if q.den == 1 then [(x, op, q.num)] else []
    | .bin op (.lit (.num q)) (.path x []) =>
      let flip := match op with | "<" => ">" | "<=" => ">=" | ">" => "<" | ">=" => "<=" | o => o
      if q.den == 1 then [(x, flip, q.num)] else []
    | _ => []
  let mut fs := fs
  for _ in [0:3] do
    match Session.Types.brokenConstraint m (fs.map fun (k, v) => (k, toV v)) with
    | none => return some fs
    | some (c, _) =>
      let .ok ex := Session.Where.parse c.text | return none
      for (x, op, n) in bounds ex do
        let num? : Session.Where.Value -> Option Int := fun
          | Session.Where.Value.num q => some q.num
          | _ => none
        let cur := ((fs.lookup x).bind fun v => num? (toV v)).getD 0
        let ok := match op with
          | "<" => cur < n | "<=" => cur <= n | ">" => cur > n | ">=" => cur >= n | "=" => cur == n | _ => true
        if !ok then
          let v := match op with | "<" => n - 1 | "<=" => n | ">" => n + 1 | ">=" => n | _ => n
          fs := setField fs x (Json.str (toString v))
  return none

/-- Example contents for every message of a simulated stream, as the `fields` conformance reads:
`sessionId` names the person (simSessionId), `requestId` counts requests, other strings and
numbers are small examples, nested messages are their example, and each message's `where` clause
is then made true by copying fields from the message it names or setting literals (fillWhere).
`none` when the text declares no message types, or when some clause in the stream is not of that
form, so the stream keeps no contents rather than contents its protocol would reject. -/
def simFields (p : Protocol) (seed : Nat) (evs : Array (Event String)) :
    Option (Array (List (String × Json))) := Id.run do
  if p.types.isEmpty then return none
  let labels := (p.global.messages.map (·.label)).eraseDups
  let ms := (Session.Types.complete p.types labels).toOption.getD []
  let inters := p.global.messages
  let mut out : Array (List (String × Json)) := #[]
  let mut latest : List ((Nat × String) × Nat) := []
  let mut req := 0
  -- the value each marked field last minted, by name: a Link carries it (selfhost.session.identity.marks)
  let mut minted : List (String × Json) := []
  for e in evs do
    if e.isAct then
      out := out.push []
      continue
    let decl := ((ms.find? (·.name == e.label)).map (·.fields)).getD []
    let mut fs : List (String × Json) := []
    for f in decl do
      let target := (p.linkTargets.lookup (e.label, f.name)).getD f.name
      let v : Json := if f.mark == .fresh then
          Json.str (if f.name == "sessionId" then s!"sess-{e.session + 1}" else s!"{f.name}-{e.id}")
        else if f.mark == .link && (minted.lookup target).isSome then (minted.lookup target).get!
        else match f.ty with
        | .str => if f.name == "sessionId" then Json.str (simSessionId seed e.session)
                  else Json.str s!"{f.name}-{e.session % 3 + 1}"
        | .nat | .int => if f.name == "requestId" then Json.str (toString (req + 1))
                         else Json.str (toString (e.id % 7 + 1))
        | .bool => Json.bool false
        | t => Session.Types.Ty.example p.types 4 t
      fs := fs ++ [(f.name, v)]
      if f.mark == .fresh then minted := (f.name, v) :: minted.filter (·.1 != f.name)
    if decl.any (·.name == "requestId") then req := req + 1
    -- the same label, roles and id can appear in several places with different clauses (GoServer
    -- rejects many requests with `x: RequestRejected`), so the message it answers picks the place
    let causeId : Option String := (e.cause.bind (evs[·]?)).bind (·.msgId)
    let same := fun (i : Interaction String) => i.label == e.label && i.src == e.src && i.dst == e.dst && i.id == e.msgId
    let inter := match inters.find? (fun i => same i && i.cause == causeId) with
      | some i => some i
      | none => inters.find? same
    if let some i := inter then
      if let some g := i.guard then
        let some me := i.id | return none
        let .ok ex := Session.Where.parse g.text | return none
        let soFar := out
        let look (y : String) : Option (List (String × Json)) :=
          (latest.lookup (e.session, y)).bind fun j => soFar[j]?
        match fillWhere me look fs ex with
        | some filled => fs := filled
        | none => return none
    if let some m := ms.find? (·.name == e.label) then
      if !m.constraints.isEmpty then
        match fillConstraints m fs with
        | some filled => fs := filled
        | none => return none
    if let some m := e.msgId then
      latest := ((e.session, m), out.size) :: latest.filter (·.1 != (e.session, m))
    out := out.push fs
  return some out

/-- The stream's sessions derived from the protocol's where-clause equations and the events' cause
and prior links (clause selfhost.session.derived-sessions); the simulated session numbers are only
a cross-check. -/
def derivedJson (p : Protocol) (events : Array Json) : Json :=
  let guards := p.global.messages.filterMap fun i => i.guard.map (·.text)
  (Derived.group (Derived.equations guards) (events.map Derived.Ev.ofJson)).json

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
         ("tsUnit", "ns"), ("events", Json.arr (stampNs evJson)), ("derivedSessions", derivedJson p evJson), ("diagram", diagramJson p)]
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
       ("tsUnit", "ns"), ("events", Json.arr (stampNs (generated.events.map eventJson))), ("deadlineReports", toJson generated.reports),
       ("derivedSessions", derivedJson p (generated.events.map eventJson)),
       ("diagram", diagramJson p)]
  -- a protocol without a sessions block runs as `instances` concurrent copies of itself
  let g := if hasSessions p.global then p.global else .sessions p.global .done
  let evs := g.simulate seed instances spread loops maxEvents
  let sessions := (evs.toList.map (·.session)).eraseDups.length
  -- each message with example contents that satisfy its where clause, when they can be made so
  let filled := simFields p seed evs
  let evJson := match filled with
    | some fs => (evs.zip fs).map fun (e, f) => if e.isAct then eventJson e else (eventJson e).setObjVal! "fields" (Json.mkObj f)
    | none => evs.map eventJson
  let contents := match filled with
    | some _ => "; each message carries example fields (sessionId names one of three people) that satisfy its where clause"
    | none => ""
  return fit <| Json.mkObj
    [ ("tool", "session_simulate"), ("verdict", "generated")
    , ("reading", Json.str (s!"{p.name}: {evs.size} events from {sessions} session{if sessions == 1 then "" else "s"} (seed {seed})" ++ contents))
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol"), ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p)
    , ("seed", seed), ("instances", instances), ("sessions", sessions)
    , ("tsUnit", "ns"), ("events", Json.arr (stampNs evJson))
    , ("derivedSessions", derivedJson p evJson)
    , ("diagram", diagramJson p) ]

/-- A logged event: the fields session_simulate writes (src, dst, act) or from/to; ids, sessions and
causes may be strings or numbers. -/
def maxFields : Nat := 64

/-- A logged event's fields: nested objects flattened to dotted keys, numbers as exact rationals,
strings and booleans kept, anything else dropped (selfhost.session.where). -/
partial def flattenFields (pre : String) (j : Json) : List (String × Session.Where.Value) :=
  match j with
  | .obj kvs => kvs.toList.flatMap fun (k, v) => flattenFields (if pre.isEmpty then k else pre ++ "." ++ k) v
  | .num n => [(pre, .num ((n.mantissa : Rat) / ((10 ^ n.exponent : Nat) : Rat)))]
  | .str t => [(pre, .str t)]
  | .bool b => [(pre, .bool b)]
  | _ => []

def logEvent (j : Json) : Except String LogEvent := do
  let text (k : String) : Option String :=
    match j.getObjVal? k with
    | .ok (.str s) => some s
    | .ok (.num n) => some n.toString
    | _ => none
  -- an event is named by its id, or in the envelope's form by its ts (selfhost.session.envelope)
  let id ← match text "id" <|> text "ts" with | some s => pure s | none => .error "every event needs an id or a ts"
  let label ← match text "label" with | some s => pure s | none => .error s!"event {id} has no label"
  let isAct := (j.getObjValAs? Bool "act").toOption.getD false
  let src ← match text "from" <|> text "src" <|> text "at" with
    | some s => pure s | none => .error s!"event {id} has no from (or src)"
  let dst := if isAct then src else (text "to" <|> text "dst").getD ""
  if !isAct && dst.isEmpty then .error s!"event {id} has no to (or dst)"
  for s in [id, label, src, dst] do
    if s.length > limits.maxString then .error s!"event {id} has a field over {limits.maxString} characters"
  -- a field may travel in a header, a URL parameter or the body; conformance reads them alike
  -- (selfhost.session.identity.marks)
  let fields := ["fields", "body", "headers", "path", "query"].flatMap fun k => match j.getObjVal? k with
    | .ok o@(.obj _) => flattenFields "" o
    | _ => []
  if fields.length > maxFields then .error s!"event {id} has {fields.length} fields; the bound is {maxFields}"
  for (k, v) in fields do
    if k.length > limits.maxString then .error s!"event {id} has a field name over {limits.maxString} characters"
    if let .str t := v then
      if t.length > limits.maxString then .error s!"event {id}: field {k} is over {limits.maxString} characters"
  -- actors (selfhost.session.actor-conformance): from and to may be Role/instance
  let (srcRole, srcActor) ← Actors.parse src |>.mapError (s!"event {id}: " ++ ·)
  let (dstRole, dstActor) ← if isAct then pure (srcRole, srcActor) else Actors.parse dst |>.mapError (s!"event {id}: " ++ ·)
  -- clock readings (selfhost.session.timelines): nanoseconds on the sender's and the receiver's clock
  let reading (k : String) : Except String (Option Nat) := match j.getObjVal? k with
    | .ok .null => pure none
    | .ok v => do let n ← (wireNat v).mapError (s!"event {id}: {k} " ++ ·); pure (some n)
    | .error _ => pure none
  let sentAt ← reading "sentAt"
  let receivedAt ← reading "receivedAt"
  -- the protocol and version it was sent in (selfhost.session.versions); 0 is no version
  let version := match <- reading "version" with | some 0 => none | v => v
  let protocolName := text "protocol"
  let prev := text "prev"
  for t in [prev, protocolName] do
    if let some p := t then
      if p.length > limits.maxString then .error s!"event {id} has a field over {limits.maxString} characters"
  return { id, session := (text "session").getD "0", src := srcRole, dst := dstRole, label, cause := text "cause", isAct, fields,
           srcActor, dstActor := if isAct then srcActor else dstActor, prev, sentAt, receivedAt, protocolName, version }

/-- What is wrong with the versions a log's events name (selfhost.session.versions): against a
versioned protocol, every event names one of its versions and no other protocol, and one session
speaks one version. -/
def versionProblems (p : Protocol) (evs : List LogEvent) : List String := Id.run do
  let declared := if p.versions.isEmpty then (if p.version == 0 then [] else [p.version]) else p.versions.map (fun v => v.1)
  let shown := ", ".intercalate (declared.map toString)
  let mut out : List String := []
  for e in evs do
    if let some n := e.protocolName then
      if n != p.name then out := out ++ [s!"event {e.id}: it belongs to protocol {n}, not {p.name}"]
    if declared.isEmpty then
      if let some v := e.version then out := out ++ [s!"event {e.id}: it names version {v}, but {p.name} has no versions"]
    else match e.version with
      | none => out := out ++ [s!"event {e.id}: it names no version; {p.name} has version{if declared.length == 1 then "" else "s"} {shown}, so every event says which it speaks"]
      | some v => if !declared.contains v then out := out ++ [s!"event {e.id}: version {v} is not a version of {p.name} ({shown})"]
  for sid in (evs.map fun e => e.session).eraseDups do
    let vs := ((evs.filter fun e => e.session == sid).filterMap fun e => e.version).eraseDups
    if vs.length > 1 then
      out := out ++ [s!"session {sid}: its events name versions {", ".intercalate (vs.map toString)}; one session speaks one version"]
  return out

def maxLogEvents : Nat := 2000

def deadlineReports (p : Protocol) (args : Json) (evs : List LogEvent) : Except String Json := do
  let some layer := p.generative | return Json.null
  -- a layer only the chain can run (rec, rates) has no finite paths to monitor: no deadline
  -- reports, and the layer's executionUnsupported note says so; the structural verdict stands
  if (layer.metadata.getObjVal? "executionUnsupported").isOk then return Json.null
  let raw ← args.getObjValAs? (Array Json) "events"
  let timed ← (evs.zip raw.toList).mapM fun (e,j) => do
    let t ← match (j.getObjVal? "timeMs").toOption <|> (j.getObjVal? "time").toOption, (j.getObjVal? "ts").toOption with
      | some v, _ => v.getNat?
      -- ts is nanoseconds; deadlines are whole ms, so a fraction of a ms counts as late (rounded up)
      | none, some v => do let ns ← (wireNat v).mapError (s!"event {e.id}: ts " ++ ·); pure ((ns + 999999) / 1000000)
      | none, none => throw s!"event {e.id}: timed monitoring requires ts (nanoseconds) or timeMs"
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

/-- session_conform's answer for a log that is not linked: every dangling link, nothing replayed. -/
def danglingAnswer (p : Protocol) (args : Json) (dangling : List String) : Json :=
  let n := dangling.length
  Json.mkObj
    [ ("tool", "session_conform"), ("verdict", "violates")
    , ("reading", s!"{p.name}: {n} link{if n == 1 then "" else "s"} name{if n == 1 then "s" else ""} an event that is not in the log; first: {dangling.headD ""}")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray), ("lean", p.lean)
    , ("protocol", args.getObjValD "protocol")
    , ("issues", Json.arr ((dangling.take 64).map Json.str).toArray)
    , ("unchecked", Json.arr #[]), ("sessions", Json.arr #[]), ("diagram", diagramJson p) ]

/-- The secret field paths a log carries (a segment ending in _secr), each once with the first event
carrying it: information that the log is sensitive, never a reason to refuse it (selfhost.session.conform). -/
def secretFields (evs : List LogEvent) : Json := Id.run do
  let mut seen : List (String × String) := []
  for e in evs do
    for (k, _) in e.fields do
      if (k.splitOn ".").any Session.Types.isSecret && !seen.any (·.1 == k) then
        seen := seen ++ [(k, e.id)]
  return Json.arr (seen.map fun (k, id) => Json.mkObj [("field", Json.str k), ("event", Json.str id)]).toArray

def conform (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let evs ← match args.getObjVal? "events" with
    | .ok (.arr a) =>
        if a.size > CallLimits.get args "logEvents" then throw s!"at most {CallLimits.get args "logEvents"} events; {CallLimits.raise "logEvents" (CallLimits.get args "logEvents")}"
        a.toList.mapM logEvent
    | _ => throw "events must be an array of logged events {id, session?, from, to, label, cause?} (or {id, at, label, act: true})"
  -- a log is read only once it is a Linked log: every prev and cause names one of its events.
  -- One that is not is reported with every dangling link and not replayed.
  let linked ← match Linked.check evs with
    | .ok l => pure l
    | .error dangling => return fit (danglingAnswer p args dangling)
  let evs := linked.events
  -- sessions are named on every event, or on none and derived from causes and the declared session
  -- key, never from prev or a where equation (selfhost.session.log-sessions)
  let raw := match args.getObjVal? "events" with | .ok (.arr a) => a.toList | _ => []
  let hasSession := raw.map fun j => (j.getObjVal? "session").toOption.isSome
  let named : Bool := hasSession.all (· == true)
  if !named && hasSession.any (· == true) then
    throw "name a session on every event or on none: with none, LeanFM derives the sessions from causes and the declared session key"
  let logKeys := p.keys.map fun (x, f) =>
    ({ labels := (p.global.messages.filter (·.id == some x)).map (·.label), field := f } : LogSessions.Key)
  let starts := match p.global.stateGraph (CallLimits.get args "states") with
    | .ok g => ((g.edges.filter (·.1 == "s0")).map (·.2.2.label)).eraseDups
    | .error _ => p.global.messages.map (·.label)
  -- Fresh and Link fields name sessions; a session that allows no further step has freed its value
  -- (selfhost.session.identity.checks)
  -- a Link an include renames (token bound to sid) names the session that minted sid
  -- (selfhost.session.identity.scopes)
  let marked := p.types.flatMap fun m => (m.fields.filter (·.mark != .plain)).map fun f =>
    ({ label := m.name, field := f.name, mark := f.mark,
       target := (p.linkTargets.lookup (m.name, f.name)).getD f.name,
       parent := f.mark == .link && p.parentLinks.contains (m.name, f.name) } : LogSessions.Marked)
  -- a session has ended when the body it fits allows no further step: the protocol's body, or a
  -- sessions block nested in it at any depth (a child session; selfhost.session.identity.children)
  let body := match p.global with | .sessions b _ => b | other => other
  let terminated := fun (sofar : List Session.LogEvent) =>
    match p.global.next sofar with
    | .ok (steps, _) => steps.isEmpty
    | .error _ => match body.nextOwn sofar with
      | .ok steps => steps.isEmpty
      | .error _ => match (Global.allNestedSessions body).findSome? (fun g => (g.nextOwn sofar).toOption) with
        | some steps => steps.isEmpty
        | none => false
  let derived := LogSessions.derive evs.toArray logKeys starts named marked terminated
  let crossProblems : List String := bif named then LogSessions.crossCheck evs.toArray logKeys else []
  let placeProblems : List String := bif named then [] else LogSessions.unattributedProblems evs.toArray derived
  let streamEvs := LogSessions.stream evs.toArray derived named
  -- an event the log cannot place stays in the log (links to it still resolve), alone in a session
  let evs := bif named then evs else evs.zipIdx.map fun (e, i) =>
    { e with session := (derived.sessionOf[i]!).getD s!"unplaced {e.id}" }
  -- a logged event's fields are fields of its message, of their declared types (selfhost.session.types)
  for e in evs do
    if let .error why := Session.Types.checkFields p.types e.label e.isAct e.fields then
      throw s!"event {e.id}: {why}"
  -- integers travel as decimal strings; conditions read them as exact numbers
  let evs := evs.map fun e => { e with fields := Session.Types.coerceFields p.types e.label e.fields }
  let allowIncomplete := (args.getObjValAs? Bool "allowIncomplete").toOption.getD false
  -- the log's interleaving carries no information: each session is replayed in an order consistent
  -- with its prev and cause links (selfhost.session.actor-conformance)
  let linkProblems := (Actors.check evs).map fun (e, why) => s!"event {e}: {why}"
  -- with a system declared, every actor is one of its instances (selfhost.session.instances)
  let systems <- if p.lean.isEmpty then pure [] else Instances.systemsOf p.lean
  let linkProblems := linkProblems ++ match systems.getLast? with
    | some sys => (Instances.checkActors sys evs).map fun (e, why) => s!"event {e}: {why}"
    | none => []
  -- each session is checked against the version its events name (selfhost.session.versions)
  let versionIssues := versionProblems p evs
  let results := if p.versions.isEmpty then p.global.conforms (Actors.linearize evs) allowIncomplete
    else p.versions.flatMap fun (v, _, g) =>
      let mine := evs.filter fun e => e.version == some v
      if mine.isEmpty then [] else g.conforms (Actors.linearize mine) allowIncomplete
  -- a keyed session's events all carry its key's value as their session (selfhost.session.envelope)
  let keyProblems := p.keys.flatMap fun (x, f) =>
    let labels := (p.global.messages.filter (·.id == some x)).map (·.label)
    (evs.map (·.session)).eraseDups.filterMap fun sid =>
      match evs.find? (fun e => e.session == sid && labels.contains e.label) with
      | none => none
      | some e => match e.fields.lookup f with
        | none => some s!"session {sid}, event {e.id}: {e.label} does not log the session key {x}.{f}"
        | some v =>
          let shown := match v with
            | .str t => t
            | .num q => if q.den == 1 then toString q.num else v.render
            | .bool b => toString b
          if shown == sid then none
          else some s!"session {sid}, event {e.id}: the session key {x}.{f} is {shown}, so this session's events must name session {shown}, not {sid}"
  let bad := results.filter (·.problem.isSome)
  let incomplete := results.filter (!·.complete)
  -- a logged message its constructor could never have made breaks the protocol's types
  -- (selfhost.session.constructors)
  let constraintProblems := evs.filterMap fun e =>
    (Session.Types.constraintProblem p.types e.label e.fields).map fun why => s!"session {e.session}, event {e.id}: {why}"
  -- a derived session is formed by its key, so the key check applies only to a log that names sessions
  let keyChecked : List String := match named with | true => keyProblems | false => []
  let keyProblems : List String := versionIssues ++ linkProblems ++ constraintProblems ++ keyChecked ++
    crossProblems ++ placeProblems ++ derived.problems.toList
  let verdict := if bad.isEmpty && keyProblems.isEmpty then "conforms" else "violates"
  let problems := (bad.filterMap fun r => r.problem.map fun (e, why) => s!"session {r.session}, event {e}: {why}") ++ keyProblems
  let unchecked := results.flatMap fun r => r.unchecked.map fun (e, why) => s!"session {r.session}, event {e}: {why}"
  let reading := if !versionIssues.isEmpty
    then s!"{p.name}: {versionIssues.length} version problem{if versionIssues.length == 1 then "" else "s"}; first: {versionIssues.head!}"
    else if !linkProblems.isEmpty && bad.isEmpty
    then s!"{p.name}: {linkProblems.length} problem{if linkProblems.length == 1 then "" else "s"} with the log's links; first: {linkProblems.head!}"
    else if !keyProblems.isEmpty && bad.isEmpty
    then s!"{p.name}: {keyProblems.length} problem{if keyProblems.length == 1 then "" else "s"} with the logged values (constraints, links, session keys, versions); first: {keyProblems.head!}"
    else if bad.isEmpty
    then s!"{p.name}: {evs.length} events in {results.length} session{if results.length == 1 then "" else "s"} follow the protocol" ++
      (if incomplete.isEmpty then "" else s!"; {incomplete.length} still running") ++
      (if unchecked.isEmpty then "" else s!"; {unchecked.length} where condition{if unchecked.length == 1 then "" else "s"} unchecked: {unchecked.head!}")
    else s!"{p.name}: {bad.length} of {results.length} sessions break the protocol; first: {problems.head!}"
  let deadlines ← if bad.isEmpty && keyProblems.isEmpty then deadlineReports p args evs else pure Json.null
  return fit <| Json.mkObj
    [ ("tool", "session_conform"), ("secretFields", secretFields evs), ("deadlineReports", deadlines), ("verdict", verdict), ("reading", reading), ("name", p.name)
    , ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("protocol", args.getObjValD "protocol"), ("overlay", args.getObjValD "overlay"), ("generative", generativeJson p)
    , ("issues", Json.arr ((problems.take 64).map Json.str).toArray)
    , ("unchecked", Json.arr ((unchecked.take 64).map Json.str).toArray)
    , ("sessions", Json.arr ((results.take 200).map fun r => Json.mkObj
        [("session", r.session), ("events", r.events), ("complete", r.complete),
         ("unchecked", toJson (r.unchecked.map fun (e, why) => s!"{e}: {why}")),
         ("problem", match r.problem with | some (e, why) => Json.mkObj [("event", e), ("reason", why)] | none => Json.null)]).toArray)
    , ("derivedSessions", derived.json named), ("events", Json.arr streamEvs)
    , ("diagram", diagramJson p) ]

/-- Calls, their two views, timelines and critical paths of a log (selfhost.session.timelines,
selfhost.session.critical-path): every duration a difference of one clock's readings. -/
def spans (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let evs ← match args.getObjVal? "events" with
    | .ok (.arr a) =>
        if a.size > CallLimits.get args "logEvents" then throw s!"at most {CallLimits.get args "logEvents"} events; {CallLimits.raise "logEvents" (CallLimits.get args "logEvents")}"
        a.toList.mapM logEvent
    | _ => throw "events must be an array of logged events {id, session?, from, to, label, cause?, prev?, sentAt?, receivedAt?}"
  for e in evs do
    for r in (if e.isAct then [e.src] else [e.src, e.dst]) do
      if !p.roles.contains r then throw s!"event {e.id}: {r} is not a role of {p.name}; its roles are {", ".intercalate p.roles}"
  let dangling := match Linked.check evs with | .error ps => ps | .ok _ => []
  let linkProblems := dangling ++ (Actors.check evs).map fun (e, why) => s!"event {e}: {why}"
  let ordered := Actors.linearize evs
  let byId := ordered.map fun e => (e.id, e)
  let all := Spans.spans ordered
  let reports := all.map (Spans.report byId all)
  let issues := linkProblems ++ reports.flatMap (·.issues)
  let ns (o : Option Nat) : Json := match o with | some n => Json.str (toString n) | none => Json.null
  let ids (cs : List Spans.Span) : Json := Json.arr (cs.map fun c => Json.str c.request.id).toArray
  let spanJson (r : Spans.Report) : Json := Json.mkObj
    [ ("request", Json.str r.span.request.id), ("reply", Json.str r.span.reply.id), ("label", Json.str r.span.request.label)
    , ("caller", Json.str (Spans.caller r.span)), ("callee", Json.str (Spans.callee r.span))
    , ("callerViewNs", ns r.span.callerView), ("calleeViewNs", ns r.span.calleeView), ("networkNs", ns r.network)
    , ("subcalls", ids r.subs), ("notAwaited", ids r.notAwaited)
    , ("criticalPath", ids r.critical), ("criticalNs", Json.str (toString r.criticalNs)), ("boundNs", Json.str (toString r.boundNs)) ]
  let roots := Spans.roots byId all
  let timelines := roots.map fun s =>
    let placed := Spans.place byId all s (- (Int.ofNat (s.request.sentAt.getD 0)))
    let placed := placed.toArray.qsort (fun a b => a.2.2 < b.2.2) |>.toList
    Json.mkObj [("root", Json.str s.request.id), ("events", Json.arr (placed.map fun (e, a, t) =>
      Json.mkObj [("event", Json.str e), ("actor", Json.str a), ("atNs", Json.str (toString t))]).toArray)]
  let ms (n : Nat) : String :=
    let whole := n / 1000000
    let frac := (n % 1000000) / 1000
    s!"{whole}.{if frac < 10 then "00" else if frac < 100 then "0" else ""}{frac} ms"
  let rootText := roots.filterMap fun s => (reports.find? (·.span.request.id == s.request.id)).map fun r =>
    let took := (r.span.callerView.map fun n => s!"{Spans.caller r.span} waited {ms n}").getD "unmeasured"
    let crit := if r.critical.isEmpty then "" else s!", critical path {" -> ".intercalate (r.critical.map (·.request.label))} ({ms r.criticalNs})"
    s!"{r.span.request.label}: {took}{crit}"
  let verdict := if issues.isEmpty then "measured" else "inconsistent"
  let reading := if issues.isEmpty
    then s!"{p.name}: {all.length} call{if all.length == 1 then "" else "s"} in {roots.length} tree{if roots.length == 1 then "" else "s"}" ++
      (if rootText.isEmpty then "" else "; " ++ "; ".intercalate (rootText.take 4))
    else s!"{p.name}: {issues.length} problem{if issues.length == 1 then "" else "s"}; first: {issues.head!}"
  return Json.mkObj [("tool", "session_spans"), ("verdict", Json.str verdict), ("reading", Json.str reading), ("name", Json.str p.name),
    ("spans", Json.arr ((reports.take 200).map spanJson).toArray), ("timelines", Json.arr (timelines.take 20).toArray),
    ("issues", Json.arr ((issues.take 64).map Json.str).toArray), ("lean", Json.str p.lean)]

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
    -- the protocol state the walk is in, as a short name: equal for walks that reach the same state
    -- (a loop's start again), so a view can draw a revisit as a cycle (selfhost.session.explorer)
    let body := Conform.inlineNested (match p.global with | .sessions b _ => b | other => other)
    let stateId := match Conform.statesAfter body evs with
      -- named as Global.stateGraph names a state (Conform.graphKey)
      | .ok sts => s!"q{(String.intercalate ";" (((sts.map Conform.graphKey).eraseDups).mergeSort (· ≤ ·))).hash}"
      | .error _ => ""
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
      ("next", Json.arr (steps.map stepJson).toArray), ("canEnd", canEnd), ("state", Json.str stateId), ("lean", p.lean)]

/-- Two versions of a protocol: which roles can upgrade first, and which can stay on the old one. -/
def compat (args : Json) : Except String Json := do
  -- without old, the text's own versions: the newest two (selfhost.session.versions); a text whose
  -- versions have no clean upgrade path is refused by parseProtocol before this
  let p <- match args.getObjVal? "old" with
    | .ok _ => parseProtocol args
    | .error _ => (parseProtocol args).mapError fun e => e
  let q <- match args.getObjVal? "old" with
    | .ok (.str oldText) =>
      -- the old version reads the same .proto, unless one is given for it (oldProto)
      let oldProto := match args.getObjVal? "oldProto" with | .ok v => v | .error _ => args.getObjValD "proto"
      (parseProtocol (Json.mkObj [("lean", Json.str oldText), ("proto", oldProto)])).mapError (fun e => "the old version: " ++ e)
    | .ok _ => throw "old is the previous version's LeanFM protocol text"
    | .error _ =>
      match p.versions.reverse with
      | _ :: (v, roles, g) :: _ => pure { p with name := s!"{p.name} version {v}", roles, global := g }
      | _ => throw "old is required: the previous version's LeanFM protocol text, unless the text keeps two versions (protocol Name (...) version 1 { ... } then version 2)"
  let p := if args.getObjVal? "old" |>.isOk then p else
    { p with name := if p.version == 0 then p.name else s!"{p.name} version {p.version}" }
  let body (g : Global String) := match g with | .sessions b _ => b | other => other
  let results ← (body p.global).compat (body q.global) p.roles q.roles
  -- the deployment order: every role upgrading one at a time, every mixture on the way checked
  let path <- Versions.search q.global p.global q.roles p.roles
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
  let (pathJson, pathText) := match path with
    | .clean o => (Json.mkObj [("clean", true), ("order", Json.arr (o.map Json.str).toArray)],
        s!"clean upgrade path: {" then ".intercalate o}")
    | .none why => (Json.mkObj [("clean", false), ("stuck", Json.arr (why.map fun (w : Versions.Stuck) => Json.str w.text).toArray)],
        "no clean upgrade path")
  return Json.mkObj [("tool", "session_compat"), ("verdict", if issues.isEmpty then "compatible" else "incompatible"),
    ("name", p.name), ("reading", s!"{q.name} -> {p.name}: {order}; {pathText}"), ("upgradePath", pathJson),
    ("roles", Json.arr (rows.map fun (r : Prod String (Prod Bool (Prod Bool Json))) => r.2.2.2).toArray), ("issues", Json.arr (issues.map Json.str).toArray),
    ("notes", Json.arr (notes.map Json.str).toArray), ("lean", p.lean)]

/-- Formulas given as an array argument, at most `maxV` of them. -/
def formulas (args : Json) (key : String) (maxV : Nat := 8) : Except String (List Json) :=
  match args.getObjVal? key with
  | .error _ => .ok []
  | .ok (.arr a) => if a.size > maxV then .error s!"{key} holds at most {maxV} formulas" else .ok a.toList
  | .ok _ => .error s!"{key} is an array of JSON CTL formulas"

/-- The text's last system explored with instances interleaved (selfhost.session.instances):
deadlocks with their paths, isolation over every step, and per-instance and system formulas. -/
def instances (args : Json) : Except String Json := do
  let p <- parseProtocol args
  let systems <- Instances.systemsOf p.lean
  let some sys := systems.getLast?
    | throw "the text declares no system; add one after the protocols: system Shop { instance db : Db serial; accept Order (fresh Client, db); }"
  let n <- natArg args "instances" 2 Instances.maxInstances
  let perInstance <- formulas args "perInstance"
  let properties <- formulas args "properties"
  let r <- Instances.run sys n perInstance properties
  let g := r.graph
  let disproved := r.verdicts.filter (fun x => x.verdict != "proved")
  let verdict := if !r.deadlocks.isEmpty then "deadlock" else if !r.isolation.isEmpty then "isolation"
    else if !disproved.isEmpty then "disproved" else "ok"
  let count := g.insts.length
  let reading := match verdict with
    | "deadlock" => s!"{sys.name}: {g.deadlocks.length} deadlocked state{if g.deadlocks.length == 1 then "" else "s"} with {count} instances; first: {r.deadlocks.head!}"
    | "isolation" => s!"{sys.name}: {r.isolation.length} isolation problem{if r.isolation.length == 1 then "" else "s"}; first: {r.isolation.head!}"
    | "disproved" => let v := disproved.head!; s!"{sys.name}: {disproved.length} propert{if disproved.length == 1 then "y" else "ies"} not proved; first, {v.formula.compress} for {v.scope}: {v.verdict}: {v.why}"
    | _ => s!"{sys.name}: {count} instances interleaved over {g.keys.size} states: no deadlock, every step isolated" ++
      (if r.verdicts.isEmpty then "" else s!", {r.verdicts.length} propert{if r.verdicts.length == 1 then "y" else "ies"} proved")
  return fit <| Json.mkObj
    [ ("tool", "session_instances"), ("verdict", Json.str verdict), ("reading", Json.str reading), ("name", Json.str sys.name)
    , ("instances", Json.arr (g.insts.map fun i => Json.mkObj
        [("id", Json.str i.id), ("protocol", Json.str i.protocolName),
         ("actors", Json.mkObj (i.actors.map fun (r, a) => (r, Json.str a)))]).toArray)
    , ("shared", Json.arr (sys.shared.map fun sh => Json.mkObj
        [("name", Json.str sh.name), ("role", Json.str sh.role), ("actor", Json.str s!"{sh.role}/{sh.name}"), ("serial", Json.bool sh.serial)]).toArray)
    , ("states", toJson g.keys.size), ("steps", toJson g.edges.size), ("deadlockedStates", toJson g.deadlocks.length)
    , ("deadlocks", Json.arr (r.deadlocks.map Json.str).toArray)
    , ("isolation", Json.arr ((r.isolation.take 64).map Json.str).toArray)
    , ("properties", Json.arr (r.verdicts.map fun v => Json.mkObj
        [("formula", v.formula), ("scope", Json.str v.scope), ("verdict", Json.str v.verdict), ("reading", Json.str v.why)]).toArray)
    , ("lean", Json.str p.lean) ]

/-- What a deployment can do with FIFO, lossless inboxes of the sizes the protocol gives its roles
(selfhost.session.buffers, LeanFM/Session/Realizable.lean). -/
def realizable (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let parsed ← Text.parse p.lean (← protoTypes args)
  let a ← Realizable.explore p.global p.roles parsed.buffers (CallLimits.get args "states")
  let sizes := p.roles.map fun r => (r, (parsed.buffers.lookup r).getD 0)
  let guarantees := ["in order: a role takes the oldest message in its inbox first", "lossless: every message put in an inbox stays until it is taken"] ++
    sizes.map fun (r, n) => if n == 0 then s!"{r}'s inbox holds nothing: a send to {r} is taken at once (a rendezvous)" else s!"{r}'s inbox holds at most {n}"
  let reading := if a.verdict == "realizable" then
      s!"{p.name}: realizable: every order of deliveries a deployment can produce is one the protocol allows, and no deployment state is stuck ({a.states} deployment states)"
    else s!"{p.name}: unrealizable: {a.problem}" ++ (if a.path.isEmpty then "" else s!"; after {", ".intercalate a.path}")
  return Json.mkObj
    [ ("tool", "session_realizable"), ("verdict", Json.str a.verdict), ("reading", Json.str reading)
    , ("problem", Json.str a.problem), ("path", Json.arr (a.path.map Json.str).toArray)
    , ("inboxes", Json.mkObj (a.inboxes.map fun (r, q) => (r, Json.arr (q.map Json.str).toArray)))
    , ("waiting", Json.mkObj (a.waiting.map fun (r, q) => (r, Json.arr (q.map Json.str).toArray)))
    , ("sizes", Json.mkObj (sizes.map fun (r, n) => (r, toJson n)))
    , ("guarantees", Json.arr (guarantees.map Json.str).toArray)
    , ("states", toJson a.states) ]

/-- The text's last deployment block, or the one named by `deployment`, checked against the
protocol it places (selfhost.session.deployment): placed or refused, where each role runs, each link
with the interface it uses and the conditions it adds, every issue, and the view. -/
def deployment (args : Json) : Except String Json := do
  let p <- parseProtocol args
  let named := (args.getObjValAs? String "deployment").toOption
  let (d, roles, g) <- Deployment.ofText p.lean named
  let r := Deployment.check d roles g
  let refused := r.links.filter (!·.reachable)
  let verdict := if r.issues.isEmpty then "placed" else "refused"
  let reading := if r.issues.isEmpty then
      s!"{d.name}: {d.protocolName}'s {roles.length} roles placed; {r.links.length} link{if r.links.length == 1 then "" else "s"}, each through an interface its sender can reach"
    else s!"{d.name}: {r.issues.length} issue{if r.issues.length == 1 then "" else "s"}; first: {r.issues.head!.2}"
  let path (pl : Deployment.Placement) : String :=
    ".".intercalate (pl.path.map fun (n, pc) => if pc == .outside then "outside" else n)
  return Json.mkObj
    [ ("tool", "session_deployment"), ("verdict", Json.str verdict), ("reading", Json.str reading)
    , ("name", Json.str d.name), ("protocol", Json.str d.protocolName)
    , ("placements", Json.arr (r.placements.map fun pl => Json.mkObj
        [ ("role", Json.str pl.role), ("path", Json.str (path pl))
        , ("groups", Json.arr (pl.path.map fun (n, pc) => Json.mkObj [("name", Json.str n), ("place", Json.str (Deployment.placeWord pc))]).toArray)
        , ("interfaces", Json.arr (pl.ifaces.map fun i => Json.mkObj
            [("scope", Json.str i.scope.name), ("name", Json.str i.name), ("kind", Json.str i.kind.name),
             ("lineage", Json.arr (i.kind.lineage.map Json.str).toArray)]).toArray) ]).toArray)
    , ("links", Json.arr (r.links.map fun l => Json.mkObj
        [ ("from", Json.str l.src), ("to", Json.str l.dst), ("labels", Json.arr (l.labels.map Json.str).toArray)
        , ("via", match l.via with | some v => Json.str v | none => Json.null), ("reachable", Json.bool l.reachable)
        , ("conditions", Json.arr (l.conditions.map Json.str).toArray), ("note", Json.str l.why) ]).toArray)
    , ("refused", toJson refused.length)
    , ("issues", Json.arr (r.issues.map fun (who, t) => Json.mkObj [("role", Json.str who), ("issue", Json.str t)]).toArray)
    , ("svg", Json.str (Deployment.svg d r (themeOf args)))
    , ("provenance", Json.mkObj
        [ ("question", Json.str s!"Where does each role of {d.protocolName} run, and which interface does each of its messages arrive on, with what conditions?")
        , ("eventSource", "the protocol text and its deployment block")
        , ("reducer", "Text.deploymentDecl into the deployment tree; Deployment.pairs over the protocol's global type (includes inlined); Deployment.check with Topology.reachable and Topology.channel")
        , ("unit", "links: distinct sender and receiver pairs of the protocol's messages; conditions by name")
        , ("boundary", s!"deployment {d.name} and protocol {d.protocolName}; at most {Text.maxDeployNodes} groups, roles and interfaces") ]) ]

/-- The most faithful rules an answer lists; the rest are counted. -/
def maxFaithfulRules : Nat := 64

/-- session_ctl with faithful (selfhost.session.faithful): "rules" answers the protocol's typestates
and one rule per typestate; a task (an inline draft) or lean (another protocol text) answers
whether that model is faithful to this protocol, decided as one walk or one refinement. -/
def faithful (p : Protocol) (fa : Json) (args : Json := Json.mkObj []) : Except String Json := do
  let b := Session.sessionBoundsOf args
  let maxRules := CallLimits.get args "faithfulRules"
  let (draft, _) ← p.global.draft p.name (maxStates := b.maxDraftStates)
  let spec ← Session.Faithful.modelOfDraft draft b
  let t := Session.Faithful.typestates spec
  let base : List (String × Json) :=
    [("tool", "session_ctl"), ("name", Json.str p.name), ("nodes", toJson spec.size), ("typestates", toJson t.count),
     ("lookahead", toJson t.lookahead), ("deterministic", Json.bool t.deterministic), ("lean", Json.str p.lean)]
  match fa with
  | .str "rules" =>
    let rs := Session.Faithful.rules t
    let shown := rs.take maxRules
    let row := fun (n, f) =>
      let d := Logic.Dag.ofFormula f
      let small := d.treeSize (Logic.treeLimit + 1) ≤ Logic.treeLimit
      Json.mkObj ([("name", Json.str n), ("formula", Json.str d.toSexpr), ("sexprPretty", Json.str d.toSexprPretty), ("subformulas", toJson d.size)] ++
        (if small then [("notation", Json.str f.symbols), ("readingIndented", Json.str d.toReadingIndented)] else []))
    return fit <| Json.mkObj (base ++
      [ ("verdict", Json.str "rules")
      , ("reading", Json.str s!"{p.name}: {t.count} typestates over {spec.size} checker nodes, lookahead {t.lookahead}; {rs.length} rules (the start and one per typestate: in it each next typestate is possible and nothing else is){if rs.length > shown.length then s!", the first {shown.length} listed ({CallLimits.raise "faithfulRules" maxRules})" else ""}. Faithfulness is decided as one bisimulation check: pass faithful a task or lean to compare a model with this protocol")
      , ("rules", Json.arr (shown.map row).toArray), ("ruleCount", toJson rs.length) ])
  | .obj _ =>
    let cand ← match fa.getObjVal? "task", fa.getObjVal? "lean" with
      | .ok d, _ => Session.Faithful.modelOfDraft d b
      | _, .ok (.str text) => do
        let q ← parseProtocol (Json.mkObj [("lean", Json.str text)])
        let (d, _) ← q.global.draft q.name (maxStates := b.maxDraftStates)
        Session.Faithful.modelOfDraft d b
      | _, _ => throw "faithful is \"rules\", {task: an inline draft as check_ctl takes} or {lean: another protocol text}"
    let v := Session.Faithful.compare spec cand
    let whereAt := if v.path.isEmpty then "at the start" else s!"after {" -> ".intercalate v.path}"
    let why := if v.faithful then "" else
      s!": {whereAt}, the protocol allows {if v.protocolNext.isEmpty then "nothing" else ", ".intercalate v.protocolNext} and the candidate {if v.candidateNext.isEmpty then "nothing" else ", ".intercalate v.candidateNext}" ++
      (if v.note.isEmpty then "" else s!" ({v.note})")
    return Json.mkObj (base ++
      [ ("verdict", Json.str (if v.faithful then "faithful" else "unfaithful")), ("method", Json.str v.method)
      , ("candidateNodes", toJson cand.size)
      , ("reading", Json.str s!"{p.name}: the candidate ({cand.size} nodes) is {if v.faithful then "faithful" else "not faithful"} to the protocol ({t.count} typestates), decided by {v.method}{why}")
      , ("path", Json.arr (v.path.map Json.str).toArray)
      , ("protocolNext", Json.arr (v.protocolNext.map Json.str).toArray)
      , ("candidateNext", Json.arr (v.candidateNext.map Json.str).toArray)
      , ("note", Json.str v.note) ])
  | _ => throw "faithful is \"rules\", {task: an inline draft as check_ctl takes} or {lean: another protocol text}"

/-- A CTL formula over one session of the protocol: the protocol's state graph handed to the
logic tools' checker as an inline task, so `{"on": "Charge"}` holds in the state a Charge has
just reached, and the answer carries a witness or counterexample path. -/
def ctl (args : Json) : Except String Json := do
  let p ← parseProtocol args
  -- the secret field paths each label carries, for the secret atom (asked, never imposed)
  let secretsOf := fun (label : String) => Session.Types.secretPaths p.types label
  if let .ok fa := args.getObjVal? "faithful" then
    return ← faithful p fa args
  match args.getObjVal? "formula" with
  | .ok formula =>
    -- the same check as a Lean Spec's properties (Spec.check): one checker, one answer
    let answer ← p.global.checkFormula p.name formula secretsOf (Session.sessionBoundsOf args)
    return answer.setObjVal! "tool" (Json.str "session_ctl")
      |>.setObjVal! "lean" (Json.str p.lean)
  | .error _ =>
    -- no formula: properties built from this protocol, each decided (selfhost.session.properties)
    let ss ← p.global.suggestions p.name p.roles secretsOf (Session.sessionBoundsOf args)
    let rows := ss.map fun (n, f, a) => match a with
      | .ok ans =>
        let get := fun (k : String) => (ans.getObjValAs? String k).toOption.getD ""
        Json.mkObj [("name", Json.str n), ("formula", f), ("notation", Json.str (get "notation")),
          ("verdict", Json.str (get "verdict")), ("reading", Json.str (get "reading")), ("report", Json.str (get "report"))]
      | .error e => Json.mkObj [("name", Json.str n), ("formula", f), ("verdict", "not checked"), ("reading", Json.str e)]
    let proved := (rows.filter fun r => (r.getObjValAs? String "verdict").toOption == some "proved").length
    return fit <| Json.mkObj
      [ ("tool", "session_ctl"), ("verdict", "suggested")
      , ("reading", Json.str s!"{p.name}: {rows.length} properties suggested from the protocol, {proved} proved; pass one as formula to decide it with its path")
      , ("suggestions", Json.arr rows.toArray), ("name", Json.str p.name), ("lean", Json.str p.lean) ]

/-- session_ctl's state graph for a formula, built from the protocol; none when the call asks for
suggestions or faithfulness, which build their own (selfhost.mcp.model-token). -/
def ctlDraft (args : Json) : Except String (Option (Json × Nat)) := do
  if (args.getObjVal? "faithful").isOk || (args.getObjVal? "formula").toOption.isNone then return none
  let p ← parseProtocol args
  let secretsOf := fun (label : String) => Session.Types.secretPaths p.types label
  return some (← p.global.draft p.name secretsOf (Session.sessionBoundsOf args).maxDraftStates)

/-- session_ctl over a state graph already built for this call's protocol, or computed afresh. -/
def ctlWith (args : Json) (pre : Option (Json × Nat)) : Except String Json := do
  match pre, (args.getObjVal? "formula").toOption with
  | some (d, n), some formula =>
    let p ← parseProtocol args
    let answer ← Session.checkFormulaOn p.name d n formula (Session.sessionBoundsOf args)
    return answer.setObjVal! "tool" (Json.str "session_ctl") |>.setObjVal! "lean" (Json.str p.lean)
  | _, _ => ctl args

/-- JSON as YAML in block style: keys and strings in JSON's double quotes (valid YAML), so nothing
in a label, route or description can change the document's structure. -/
partial def yaml (j : Json) (ind : String := "") : String :=
  let key (k : String) : String :=
    if !k.isEmpty && k.toList.all (fun c => c.isAlphanum || c == '_') && (k.toList.head?.map Char.isAlpha).getD false
    then k else (Json.str k).compress
  match j with
  | .obj kvs =>
    if kvs.size == 0 then "{}" else
    "\n".intercalate (kvs.toList.map fun (k, v) => match v with
      | .obj o => if o.size == 0 then s!"{ind}{key k}: \{}" else s!"{ind}{key k}:\n" ++ yaml v (ind ++ "  ")
      | .arr a => if a.size == 0 then s!"{ind}{key k}: []" else s!"{ind}{key k}:\n" ++ yaml v (ind ++ "  ")
      | _ => s!"{ind}{key k}: {yaml v}")
  | .arr a =>
    if a.size == 0 then "[]" else
    "\n".intercalate (a.toList.map fun v => match v with
      | .obj o => if o.size == 0 then s!"{ind}- \{}" else
          let inner := yaml v (ind ++ "  ")
          s!"{ind}- " ++ (inner.drop (ind.length + 2)).toString
      | .arr _ => s!"{ind}-\n" ++ yaml v (ind ++ "  ")
      | _ => s!"{ind}- {yaml v}")
  | .str t => (Json.str t).compress
  | other => other.compress

/-- An OpenAPI document as YAML, read top down: the version and info first, then paths, then
components (a Json object keeps its keys sorted, which would put components first). -/
def openApiYaml (doc : Json) : String :=
  let order := ["openapi", "info", "jsonSchemaDialect", "servers", "paths", "components"]
  let kvs := match doc with | .obj o => o.toList | _ => []
  let ordered := (order.filterMap fun k => (kvs.lookup k).map (k, ·)) ++ kvs.filter (fun (k, _) => !order.contains k)
  "\n".intercalate (ordered.map fun (k, v) => yaml (Json.mkObj [(k, v)]))

/-- A role's HTTP interface: the requests it receives with their routes, as OpenAPI 3.1. -/
def openapi (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let role ← match args.getObjVal? "role" with
    | .ok (.str r) => pure r
    | _ => throw s!"role is required: one of {", ".intercalate p.roles}"
  if !p.roles.contains role then throw s!"{role} is not a role of {p.name}; its roles are {", ".intercalate p.roles}"
  let (doc, unrouted) ← p.global.openApi p.name role p.types
  let ops := match doc.getObjValD "paths" with
    | .obj kvs => kvs.toList.foldl (fun n (_, v) => n + (match v with | .obj ms => ms.size | _ => 0)) 0
    | _ => 0
  let note := if unrouted.isEmpty then "" else s!"; {unrouted.length} request{if unrouted.length == 1 then "" else "s"} without a route left out"
  -- the document goes in code as YAML (block style, the way OpenAPI documents are usually read and
  -- served), which the text content repeats; a large one goes once, without the structured copy,
  -- so a whole server's interface fits the result limit; only a document too large even for that
  -- falls back to compact JSON
  let docYaml := openApiYaml doc ++ "\n"
  let large := docYaml.length > 20000
  let tooLarge := docYaml.length > limits.maxResult - 10000
  let (code, language) := if tooLarge then (doc.compress, "json") else (docYaml, "yaml")
  let head : List (String × Json) := [("tool", Json.str "session_openapi"), ("verdict", Json.str "generated"),
    ("name", Json.str p.name), ("role", Json.str role),
    ("reading", Json.str (s!"{p.name}: OpenAPI 3.1 for {role}, {ops} operation{if ops == 1 then "" else "s"}{note}" ++
      (if tooLarge then "; the document is in code, compact JSON (too large for YAML)"
       else if large then "; the document is in code as YAML (too large to send twice)" else "")))]
  let docPart : List (String × Json) := if large then [] else [("openapi", doc)]
  let tail : List (String × Json) := [("unrouted", Json.arr (unrouted.map Json.str).toArray),
    ("language", Json.str language), ("code", Json.str code), ("lean", Json.str p.lean)]
  return fit <| Json.mkObj (head ++ docPart ++ tail)

/-- Each label sent with a media type, and the type (selfhost.session.openapi). -/
def mediaLabels (p : Protocol) : List (String × String) :=
  (p.global.messages.filterMap fun i => i.media.map (i.label, ·)).eraseDups

/-- The message types as protobuf, Lean structures and JSON schemas (selfhost.session.types). -/
def types (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let labels := (p.global.messages.map (·.label)).eraseDups
  let pkg := Skeleton.snake p.name
  let proto <- Session.Types.proto p.types labels pkg p.labelHistory (mediaLabels p)
  let lean ← Session.Types.lean p.types labels (Skeleton.ident p.name ++ "Types")
  -- the whole session as one Lean module: payloads, envelope, and each role's states (selfhost.session.lean)
  let (leanModule, moduleNote) := match p.global.leanModule p.name p.roles p.types (p.version, p.versions.map (fun v => v.1)) with
    | .ok (m, []) => (Json.str m, Json.null)
    | .ok (m, notes) => (Json.str m, Json.str ("; ".intercalate notes))
    | .error e => (Json.null, Json.str e)
  let ms ← Session.Types.complete p.types labels
  let empty := labels.filter fun l => (Session.Types.find p.types l).isNone
  let note := if empty.isEmpty then "" else s!"; {empty.length} carr{if empty.length == 1 then "ies" else "y"} no fields ({", ".intercalate (empty.take 6)})"
  return Json.mkObj [("tool", "session_types"), ("verdict", "generated"), ("name", p.name),
    ("reading", s!"{p.name}: {ms.length} message type{if ms.length == 1 then "" else "s"} as protobuf, Lean and JSON schema{note}"),
    ("proto", Json.str proto), ("leanTypes", Json.str lean), ("leanModule", leanModule), ("leanModuleNote", moduleNote),
    ("schemas", Json.mkObj (ms.map fun m => (m.name, m.schema))),
    ("language", "protobuf"), ("code", Json.str proto), ("lean", Json.str p.lean)]

/-! ## The files a session type generates (selfhost.session.files) -/

/-- A role's name as a file name: lower case letters, digits, _ and -; anything else is refused, so
no role can name a path outside the directory. -/
def fileName (role : String) : Except String String :=
  let t := role.toLower
  if !t.isEmpty && t.length ≤ 64 && t.toList.all (fun c => (c.isAlphanum && c.toNat < 128) || c == '_' || c == '-')
  then pure t else throw s!"role {role} cannot name a file; use letters, digits, _ and -"

/-- Everything generated from one session type, as (path under generated/, content):
Payload.proto, Payload.lean, and actors/<role>-openapi.yaml for each role that serves HTTP. -/
def sessionFiles (args : Json) : Except String (List (String × String)) := do
  let p ← parseProtocol args
  let labels := (p.global.messages.map (·.label)).eraseDups
  let proto <- Session.Types.proto p.types labels (Skeleton.snake p.name) p.labelHistory (mediaLabels p)
  let (lean, _) <- p.global.leanModule p.name p.roles p.types (p.version, p.versions.map (fun v => v.1))
  let mut files := [("Payload.proto", proto), ("Payload.lean", lean)]
  for r in p.roles do
    let (doc, _) ← p.global.openApi p.name r p.types
    let ops := match doc.getObjValD "paths" with | .obj kvs => kvs.size | _ => 0
    if ops > 0 then
      files := files ++ [(s!"actors/{← fileName r}-openapi.yaml",
        s!"# Generated by LeanFM from protocol {p.name}: the requests {r} serves. Regenerate it rather than editing.\n" ++ yaml doc ++ "\n")]
  return files

/-- Every check that applies, as findings with an edit to try for each. -/
def review (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let (findings, notChecked) := p.global.reviewAll p.roles (CallLimits.get args "states")
  let routed := (p.global.messages.filter (·.route.isSome)).length
  let scope := s!"structure, {if routed == 0 then "no HTTP (no routes)" else s!"HTTP from {routed} routed request{if routed == 1 then "" else "s"}"}, " ++
    (if notChecked.isEmpty then "liveness, " else "") ++ "roles"
  let skipped := if notChecked.isEmpty then "" else "; not checked: " ++ "; ".intercalate notChecked
  let reading := if findings.isEmpty then s!"{p.name}: no findings ({scope}){skipped}"
    else s!"{p.name}: {findings.length} finding{if findings.length == 1 then "" else "s"} ({scope}){skipped}"
  let report := "\n".intercalate ((List.range findings.length).map fun i =>
    let f := findings[i]!
    s!"{i + 1}. [{f.kind}] {f.message}\n   try: {f.suggestion}")
  -- clean means every check ran and found nothing; with a check skipped and nothing found, partial
  let verdict := if !findings.isEmpty then "findings" else if notChecked.isEmpty then "clean" else "partial"
  return Json.mkObj [("tool", "session_review"), ("verdict", Json.str verdict), ("notChecked", Json.arr (notChecked.map Json.str).toArray),
    ("name", p.name), ("reading", reading),
    ("findings", Json.arr (findings.map fun f => Json.mkObj [("kind", Json.str f.kind), ("message", Json.str f.message),
      ("suggestion", Json.str f.suggestion)]).toArray),
    ("issues", Json.arr (findings.map fun f => Json.str s!"{f.message} (try: {f.suggestion})").toArray),
    ("report", Json.str report), ("lean", Json.str p.lean)]

def skeleton (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let language := (args.getObjValAs? String "language").toOption.getD "python"
  let code ← match language with
    | "python" => p.global.pythonSkeleton p.name p.roles p.types p.keys
    | "typescript" => p.global.typescriptSkeleton p.name p.roles p.types p.keys
    | other => throw s!"language {other} is not supported; use python or typescript"
  let starts := ", ".intercalate (p.roles.map Skeleton.snake)
  let what := if language == "python" then "a Python" else "a TypeScript"
  return fit <| Json.mkObj
    [ ("tool", "session_skeleton"), ("verdict", "generated")
    , ("reading", s!"{p.name}: {what} module with each role's typestate as classes; start functions {starts}")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("language", language), ("code", code), ("lean", p.lean) ]

/-! ## Requirements: assumptions against requirements, and observed event streams (selfhost.session.sla, .execution) -/

def boundText (b : Generative.Bound) : String :=
  match b with
  | .every => "every"
  | .atLeast p => s!"at least {p.text}"
  | .atMost p => s!"at most {p.text}"

def windowText (w : Option Generative.Window) : String :=
  match w with
  | some (.time ms) => Chain.daysText (ms : Rat)
  | some (.entries n) => s!"{n} entries"
  | none => "-"

def slaEvent (j : Json) : Except String (Sla.Ev × Option (List (String × String × Rat))) := do
  let ts ← match j.getObjVal? "ts" with
    | .ok v => (wireNat v).mapError fun why => s!"ts {why}: ts is the event's time in nanoseconds, unique in the stream"
    | .error _ => throw "every event needs ts, its time in nanoseconds as a decimal string, unique in the stream"
  let label ← match j.getObjValAs? String "label" with
    | .ok l => if l.isEmpty || l.length > limits.maxString then throw s!"event {ts}: the label is empty or too long" else pure l
    | .error _ => throw s!"event {ts} needs a label"
  let str (k : String) : String := (j.getObjValAs? String k).toOption.getD ""
  let src := if (str "from").isEmpty then str "role" else str "from"
  let link (k : String) : Except String (Option Nat) := match j.getObjVal? k with
    | .ok .null | .error _ => pure none
    | .ok v => match wireNat v with
      | .ok n => pure (some n)
      | .error why => throw s!"event {ts}: {k} is the timestamp of an earlier event ({why})"
  let reward : Option (List (String × String × Rat)) ← match j.getObjVal? "reward" with
    | .ok (.obj kv) => some <$> (kv.toList.flatMapM fun (role, units) => match units with
        | .obj ukv => ukv.toList.mapM fun (unit, v) => match v.getInt? with
          | .ok n => pure (role, unit, (n : Rat))
          | .error _ => throw s!"event {ts}: reward amounts are whole numbers"
        | _ => throw s!"event {ts}: reward is {"{"}role: {"{"}unit: amount}}")
    | .ok .null | .error _ => pure none
    | _ => throw s!"event {ts}: reward is {"{"}role: {"{"}unit: amount}}"
  return ({ ts, label, src, dst := str "to", prev := ← link "prev", cause := ← link "cause" }, reward)

/-- A duration for people: ms below a second, otherwise the largest unit. -/
def msText (ms : Nat) : String := if ms < 1000 then s!"{ms} ms" else Chain.daysText (ms : Rat)

/-- A probability for people: the exact fraction when it is short, else ≈ a decimal with the exact value after it. -/
def probText (r : Rat) : String :=
  let x := Chain.readable r true
  if x.startsWith "~" then s!"{x} (exactly {Chain.ratText r})" else x

def vectorJson (v : List (String × String × Rat)) : Json :=
  Json.arr (v.map fun (r, u, a) => Json.mkObj [("role", r), ("unit", u), ("amount", Chain.ratText a)]).toArray

def vectorText (v : List (String × String × Rat)) : String :=
  if v.isEmpty then "zero" else ", ".intercalate (v.map fun (r, u, a) => s!"{r} {Chain.ratText a} {u}")

def sla (args : Json) : Except String Json := do
  let p ← parseProtocol args
  if !(p.global.issues p.roles).isEmpty then throw "fix protocol issues before checking its requirements"
  let parsed ← Text.parse p.lean (← protoTypes args)
  if parsed.requires.isEmpty then
    throw "the protocol states no requirements: add require per q { every q reaches Reply within 2 seconds; } after it, where q is a message id"
  let layer ← match p.generative with
    | some r => pure r
    | none => Generative.resolve parsed.body
  let c ← (Chain.analyse layer).mapError fun e =>
    if e.startsWith "every choice needs probabilities" || (e.splitOn "needs probabilities").length > 1 then
      s!"an assumption is missing: requirements are checked against the probabilities stated on every choice ({e})"
    else e
  let designs ← parsed.requires.mapM (Sla.design c parsed.body)
  let designJson := designs.map fun d => Json.mkObj
    [ ("requirement", d.req.text), ("entry", d.req.entry), ("bound", boundText d.req.bound),
      ("targets", toJson d.req.targets), ("withinMs", toJson d.req.withinMs), ("window", windowText d.req.window),
      ("confidence", d.req.confidence.text), ("verdict", d.verdict),
      ("probability", Json.mkObj [("lo", Chain.ratText d.lo), ("hi", Chain.ratText d.hi), ("loText", Chain.readable d.lo true), ("hiText", Chain.readable d.hi true)]),
      ("entries", toJson d.entries.length), ("path", toJson d.path), ("assumptions", toJson d.assumptions),
      ("windowNeeds", toJson d.need), ("windowHoldsThem", toJson d.windowOk), ("note", d.note) ]
  let intervalText (d : Sla.DesignVerdict) : String :=
    if d.lo == d.hi then probText d.lo else s!"between {probText d.lo} and {probText d.hi}"
  let designLines := designs.map fun d =>
    let need := match d.need, d.windowOk with
      | some n, some true => s!" The window holds the {n} entries it needs to decide at {d.req.confidence.text} confidence."
      | some n, some false => s!" The window will not hold the {n} entries it needs to decide at {d.req.confidence.text} confidence: lengthen it or expect more traffic."
      | some n, none => s!" Deciding it needs about {n} entries per window at {d.req.confidence.text} confidence; add expecting N per hour to check the window holds them."
      | none, _ => ""
    let path := if d.verdict == "met" || d.path.isEmpty then "" else
      s!" The most probable path that breaks it: {" -> ".intercalate d.path}" ++
      (if d.assumptions.isEmpty then "." else s!", through the assumption{if d.assumptions.length > 1 then "s" else ""} {", ".intercalate d.assumptions}.")
    let note := if d.note.isEmpty then "" else " " ++ (d.note.take 1).toString.toUpper ++ (d.note.drop 1).toString ++ "."
    s!"- {d.req.text}
  {d.verdict.toUpper}: per entry the probability of reaching {", ".intercalate d.req.targets}{(d.req.withinMs.map fun w => s!" within {msText w}").getD ""} is {intervalText d}.{path}{need}{note}"
  -- an observed stream: the execution is its events
  let mut observedJson : Json := Json.null
  let mut observedLines : List String := []
  let mut atJson : Json := Json.null
  if let .ok (.arr evs) := args.getObjVal? "events" then
    let parsedEvs ← evs.toList.mapM slaEvent
    -- an observed stream is of this protocol: its labels and its units (selfhost.session.envelope)
    let labels := p.global.labels.eraseDups
    let units := (Text.unitsOf parsed.body).eraseDups
    for (e, r) in parsedEvs do
      if !labels.contains e.label then throw s!"event {e.ts}: {e.label} is not a message or event of {p.name}"
      for (_, u, _) in r.getD [] do
        if !units.contains u then throw s!"event {e.ts}: the reward names unit {u}, which {p.name} never uses{if units.isEmpty then "" else s!"; its units are {", ".intercalate units}"}"
    -- the stream is in nanoseconds; requirements are written in ms and longer units
    let inNs (r : Generative.Requirement) : Generative.Requirement :=
      { r with withinMs := r.withinMs.map (· * 1000000),
               window := r.window.map fun w => match w with | .time ms => .time (ms * 1000000) | other => other }
    let parsed : Text.Parsed := { parsed with requires := parsed.requires.map inNs }
    let x ← Sla.Execution.make (parsedEvs.map (·.1)) (parsedEvs.filterMap fun (e, r) => r.map (e.ts, ·))
    let mut perReq := #[]
    for r in parsed.requires do
      let some label := Sla.entryLabelOf parsed.body r.entry | throw s!"{r.entry} is not a message id"
      let ts := Sla.trials x r label
      let misses := ts.filter (·.outcome == "miss")
      let pending := (ts.filter (·.outcome == "pending")).length
      let ws := if r.bound == .every then [] else Sla.windows r ts (x.order.back?.getD 0)
      let verdict := if r.bound == .every then (if misses.isEmpty then "met" else "violated")
        else if ws.any (·.verdict == "violated") then "violated"
        else if ws.any (·.closed) && (ws.filter (·.closed)).all (·.verdict == "met") then "met"
        else if ws.any (·.closed) then "undecided" else "open"
      perReq := perReq.push (Json.mkObj
        [ ("requirement", r.text), ("verdict", verdict), ("entries", toJson ts.length),
          ("hits", toJson (ts.filter (·.outcome == "hit")).length), ("misses", toJson misses.length), ("pending", toJson pending),
          ("missedEntries", toJson ((misses.take 20).map (·.entry))),
          ("counterexample", match misses.head? with
            | some m => Json.mkObj [("entry", toJson m.entry), ("causalFuture", toJson (x.future m.entry (m.entry + (r.withinMs.getD 0))))]
            | none => Json.null),
          ("windows", Json.arr (ws.map fun w => Json.mkObj [("start", toJson w.start), ("entries", toJson w.entries), ("hits", toJson w.hits), ("closed", toJson w.closed), ("verdict", w.verdict), ("pValue", toJson w.pValue)]).toArray) ])
      let wtext := if ws.isEmpty then "" else " Windows: " ++ ", ".intercalate (ws.map fun w => s!"{w.hits}/{w.entries} {w.verdict}") ++
        (if verdict == "open" then " (no observation period has closed yet, so nothing is decided)." else ".")
      observedLines := observedLines ++ [s!"- {r.text}
  {verdict.toUpper} on the stream: {ts.length} entries, {(ts.filter (·.outcome == "hit")).length} reached a target, {misses.length} missed, {pending} pending.{wtext}{match misses.head? with | some m => s!" First miss: the entry at {m.entry}." | none => ""}"]
    let views := p.roles.map fun role => (role, (x.view role).length)
    let last := x.order.back?.getD 0
    let finals := p.roles.map fun role => (role, x.view role |>.getLast?.map x.rewardAt |>.getD [])
    observedJson := Json.mkObj [("events", toJson x.order.size), ("requirements", Json.arr perReq),
      ("views", Json.arr (views.map fun (r, n) => Json.mkObj [("role", r), ("events", toJson n)]).toArray),
      ("rewardAtLast", vectorJson (x.rewardAt last)),
      ("rewardPerRole", Json.arr (finals.map fun (r, v) => Json.mkObj [("role", r), ("atLatestEventInView", vectorJson v)]).toArray)]
    observedLines := observedLines ++ [s!"Each role's state is its view: " ++ ", ".intercalate (views.map fun (r, n) => s!"{r} {n} events") ++ ".",
      s!"The reward vector at the last event ({last}), found by walking prev back to the latest vector: {vectorText (x.rewardAt last)}."]
    if let .ok atv := args.getObjVal? "at" then
      let atTs ← (wireNat atv).mapError fun why => s!"at is the timestamp of an event ({why})"
      if !x.events.contains atTs then throw s!"at {atTs} is not an event of the stream"
      atJson := Json.mkObj [("at", toJson atTs), ("causalPast", toJson (x.causalPast atTs)), ("reward", vectorJson (x.rewardAt atTs)),
        ("views", Json.arr (p.roles.map fun (role : String) => Json.mkObj [("role", Json.str role), ("events", toJson ((x.view role).filter (· ≤ atTs)))]).toArray)]
      observedLines := observedLines ++ [s!"At {atTs}: {(x.causalPast atTs).length} events in its causal past; reward vector {vectorText (x.rewardAt atTs)}."]
  let report := "\n".intercalate (["Requirements against the stated assumptions (exact, per entry):"] ++ designLines ++
    (if observedLines.isEmpty then [] else ["", "Requirements on the observed event stream:"] ++ observedLines))
  let verdict := if designs.any (·.verdict == "violated") then "violated" else if designs.all (·.verdict == "met") then "met" else "undecided"
  return Json.mkObj
    [ ("tool", "session_sla"), ("verdict", verdict), ("name", p.name), ("lean", p.lean), ("report", report),
      ("design", Json.arr designJson.toArray), ("observed", observedJson), ("at", atJson),
      ("provenance", Json.mkObj
        [ ("question", "Does the protocol meet its require clauses, per entry, under the probabilities stated on its choices, and on the observed stream?"),
          ("eventSource", "the protocol text's choices and delays (assumptions); the events argument when given (unique timestamps, prev and cause links, reward vectors where they change)"),
          ("reducer", "design: exact enumeration over the chain view from each entry until a target, the deadline, the next entry or the end, interval [hits, hits + unresolved]; observed: causal future of each entry, tumbling windows, exact one-sided binomial test"),
          ("unit", "probability per entry; entries per window; reward amounts per role and unit"),
          ("boundary", "one entry per occurrence of the require block's message id; the main protocol") ]) ]

/-! ## One role's view (selfhost.session.actor) -/

def rowJson (r : ActorView.Row) : Json :=
  Json.mkObj ([("label", Json.str r.label), ("direction", Json.str r.direction), ("peer", Json.str r.peer)] ++
    (match r.route with | some x => [("route", Json.str x)] | none => []) ++
    (match r.status with | some x => [("status", toJson x)] | none => []) ++
    (match r.field with | some x => [("field", toJson x)] | none => []))

/-- The protocol as one role sees it: its local type and typestate, a sequence diagram of only the
steps it takes part in (lifelines: the role and its peers), its messages with direction, peer, route,
status and payload field number, the HTTP interface it serves as OpenAPI, the routes it calls, and
the whole protocol's proto file (a role's payloads keep the whole protocol's field numbers). -/
def actor (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let role ← match args.getObjVal? "role" with
    | .ok (.str r) => pure r
    | _ => throw s!"role is required: one of {", ".intercalate p.roles}"
  if !p.roles.contains role then throw s!"{role} is not a role of {p.name}; its roles are {", ".intercalate p.roles}"
  let projection := match p.global.project role with
    | .ok l => Json.mkObj [("local", l.render), ("typestate", l.typestate)]
    | .error e => Json.mkObj [("error", e)]
  let lanes := ActorView.lanes p.roles role p.global
  let model := (p.global.restrict role).diagramModel lanes s!"{p.name} as {role} sees it" (keys := p.keys)
  let rows := ActorView.rows p.global role p.labelHistory
  let labels := (p.global.messages.map (·.label)).eraseDups
  let proto := match Session.Types.proto p.types labels (Skeleton.snake p.name) p.labelHistory (mediaLabels p) with
    | .ok t => Json.str t
    | .error e => Json.mkObj [("error", e)]
  let (served, servedYaml) := match p.global.openApi p.name role p.types with
    | .ok (doc, _) => (doc, Json.str (yaml doc))
    | .error e => (Json.mkObj [("error", e)], Json.null)
  let sends := (rows.filter (·.direction == "sends")).length
  let receives := (rows.filter (·.direction == "receives")).length
  let evs := (rows.filter (·.direction == "event")).length
  let serves := (ActorView.serves rows).length
  let calls := ActorView.calls rows
  let peers := lanes.filter (· != role)
  let problem := (projection.getObjValAs? String "error").toOption
  let plural (n : Nat) (w : String) : String := s!"{n} {w}{if n == 1 then "" else "s"}"
  let reading := s!"{p.name} as {role} sees it: sends {plural sends "message"}, receives {receives}" ++
    (if evs == 0 then "" else s!", {plural evs "event"} of its own") ++
    s!"; serves {plural serves "route"}, calls {plural calls.length "route"}; peers: " ++
    (if peers.isEmpty then "none" else ", ".intercalate peers) ++
    (match problem with | some e => s!"; it has no local type: {e}" | none => "")
  return fit <| Json.mkObj
    [ ("tool", "session_actor"), ("verdict", if problem.isSome then "issues" else "projected"), ("reading", reading)
    , ("name", p.name), ("role", Json.str role), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("overlay", args.getObjValD "overlay")
    , ("lanes", Json.arr (lanes.map Json.str).toArray)
    , ("projection", projection)
    , ("messages", Json.arr (rows.map rowJson).toArray)
    , ("calls", Json.arr (calls.map rowJson).toArray)
    , ("openapi", served), ("openapiYaml", servedYaml)
    , ("proto", proto)
    , ("svg", model.svg (themeOf args))
    , ("diagram", modelJson model)
    , ("provenance", Json.mkObj
        [ ("question", Json.str s!"What does {role} send, receive and serve in {p.name}, and with whom?")
        , ("eventSource", "the protocol text")
        , ("reducer", "Global.restrict (the steps the role takes part in, in their frames), Global.project (the local type), ActorView.rows (messages with Types.payloadNumbers), Global.openApi")
        , ("unit", "messages and routes")
        , ("boundary", "the main protocol; nested sessions and included protocols in place") ]) ]

/-! ## Large datasets (selfhost.session.dataset) -/

def datasetStep (e : Event String) : Dataset.Step :=
  { label := e.label, src := e.src, dst := e.dst, isAct := e.isAct, time := e.time }

/-- Events grouped by session, sessions in order of first appearance. -/
def bySession (evs : Array (Event String)) : List (Nat × Array Dataset.Step) := Id.run do
  let mut order : Array Nat := #[]
  let mut groups : Std.HashMap Nat (Array Dataset.Step) := {}
  for e in evs do
    if !groups.contains e.session then order := order.push e.session
    groups := groups.insert e.session ((groups.getD e.session #[]).push (datasetStep e))
  return order.toList.map fun sid => (sid, groups.getD sid #[])

/-- Many generated sessions, summarized: path, message, role, length and duration distributions.
With a probability layer the sessions follow its exact weights (the chain for loops and rates, the
timed generator otherwise); without one each walk takes one allowed step or the end, equally likely,
and the answer says that these frequencies describe the walker, not the system. -/
def dataset (args : Json) : Except String Json := do
  let p ← parseProtocol args
  if !(p.global.issues p.roles).isEmpty then throw "fix protocol issues before generating a dataset (session_check lists them)"
  let seed ← natArg args "seed" 1 4294967295
  let maxSessions := CallLimits.get args "datasetSessions"
  let maxEvents := CallLimits.get args "datasetEvents"
  let sessionEvents := CallLimits.get args "sessionEvents"
  let sessions ← (natArg args "sessions" (min 1000 maxSessions) maxSessions).mapError (· ++ s!"; {CallLimits.raise "datasetSessions" maxSessions}")
  if sessions == 0 then throw s!"sessions must be 1 to {maxSessions}"
  let (acc, basis, timeUnit) ← match p.generative with
    | some layer =>
      if hasLoop layer.body then do
        let c ← Chain.analyse layer (solveAll := false)
        let mut acc : Dataset.Acc := {}
        for i in [0:sessions] do
          let g ← Chain.generate c (Dataset.sessionSeed seed i) 1 sessionEvents
          let ended := g.ended.any (·.2)
          if acc.events + g.events.size > maxEvents then
            throw s!"the dataset would exceed {maxEvents} events after {acc.sessions} sessions; ask for fewer sessions, or {CallLimits.raise "datasetEvents" maxEvents}"
          acc := acc.add { steps := g.events.map datasetStep, ended, truncated := !ended }
        pure (acc, "weighted", "ms")
      else do
        let gen ← match Generative.generate layer p.roles seed sessions maxEvents with
          | .ok g => pure g
          | .error e => throw (if e.startsWith "generative event limit"
              then s!"the dataset would exceed {maxEvents} events; ask for fewer sessions, or {CallLimits.raise "datasetEvents" maxEvents}" else e)
        let acc := (bySession gen.events).foldl (fun a (_, st) => a.add ({ steps := st, ended := true } : Dataset.Run)) ({} : Dataset.Acc)
        pure (acc, "weighted", "ms")
    | none => do
      let acc ← Dataset.walkCounts p.global seed sessions maxEvents maxSessions sessionEvents
      pure (acc, "walk", "steps")
  let sum := acc.summary timeUnit
  let n := acc.sessions
  let events := (sum.getObjValAs? Nat "events").toOption.getD 0
  let distinct := (sum.getObjValAs? Nat "distinctPaths").toOption.getD 0
  let top := match sum.getObjValD "paths" with
    | .arr a => match a[0]? with
      | some row => s!"; most common ({Dataset.decimal2 (((row.getObjValAs? Nat "count").toOption.getD 0) * 100) n}%): {(row.getObjValAs? String "path").toOption.getD ""}"
      | none => ""
    | _ => ""
  let basisText := if basis == "weighted"
    then "sessions follow the protocol's probability layer, so frequencies estimate its stated probabilities"
    else "the protocol states no probabilities: each walk took one allowed step or the end, equally likely, so these frequencies describe the walker, not the system"
  let notEnded := n - ((sum.getObjValAs? Nat "ended").toOption.getD 0)
  let endNote := if notEnded == 0 then "" else s!"; {notEnded} did not end (cut at the event limit or stuck)"
  let pathsNote := match sum.getObjValAs? String "pathsNote" with | .ok t => if t.isEmpty then "" else s!" ({t})" | .error _ => ""
  return fit <| (sum.mergeObj (Json.mkObj
    [ ("tool", "session_dataset"), ("verdict", "generated")
    , ("reading", s!"{p.name}: {n} sessions, {events} events (seed {seed}); {distinct} distinct paths{pathsNote}{if pathsNote.isEmpty then top else ""}{endNote}; {basisText}")
    , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray)
    , ("lean", p.lean), ("overlay", args.getObjValD "overlay")
    , ("seed", seed), ("basis", Json.str basis)
    , ("provenance", Json.mkObj
        [ ("prompt", Json.str s!"session_dataset sessions={sessions} seed={seed}")
        , ("question", Json.str s!"How are {sessions} generated sessions of {p.name} distributed over paths, messages, roles, lengths and durations?")
        , ("eventSource", Json.str (if basis == "weighted" then "the probability layer's generator (Chain.generate for loops and rates, Generative.generate otherwise), seeded"
            else "Dataset.walk: Conform.nextOf and Conform.step from the start, one allowed step or the end chosen uniformly by the seeded generator"))
        , ("reducer", "group by session; count paths (labels in order), messages (label, sender, receiver), sessions containing each message, messages sent and received per role, events per session, and session duration")
        , ("unit", Json.str s!"sessions; events; duration in {timeUnit}")
        , ("boundary", Json.str s!"{n} generated sessions, at most {sessionEvents} events each and {maxEvents} in all; the top {Dataset.maxPaths} paths and {Dataset.maxRows} messages listed, the rest counted") ]) ]))

/-! ## The tree to browse (selfhost.session.explorer) -/

/-- The protocol as a tree to browse, or, with `focus`, the sequence diagram of one protocol the text
defines. The tree: the main protocol's structure (included protocols with their own lines,
choices and their branches, parallel branches, loops, independent sessions, messages and events
with their lines), the roles (what each sends and receives), and every protocol defined, each node
with the lines of the text it comes from. With `focus: Name`, the text up to the end of Name's
definition is read, so Name is its main protocol, and its diagram is drawn as session_diagram draws
it (an include as a box). With `focus: Name` and `states: Role`, Role's state machine in Name. -/
def explore (args : Json) : Except String Json := do
  let p ← parseProtocol args
  let text := p.lean
  let ds := Outline.defs text
  -- with focus: the text up to the end of Name's definition, read on its own so Name is its main
  -- protocol; with states as well, a role of Name is projected, and without, Name's diagram is drawn
  let focused : Option (Protocol × Outline.Def) ← match args.getObjVal? "focus" with
    | .ok (.str name) => do
      let some d := ds.find? (·.name == name)
        | throw s!"{name} is not a protocol of the text; its protocols are {", ".intercalate (ds.map (·.name))}"
      let upto := "\n".intercalate ((text.splitOn "\n").take d.last) ++ "\n"
      let q ← parseProtocol (Json.mkObj ([("lean", Json.str upto)] ++
        (match args.getObjVal? "proto" with | .ok v => [("proto", v)] | .error _ => [])))
      if q.name != name then throw s!"{name} could not be read on its own (the text up to it ends with {q.name})"
      pure (some (q, d))
    | .ok _ => throw "focus must be the name of a protocol the text defines"
    | .error _ => pure none
  -- a message's payload: example JSON, JSON schema, protobuf message, field number, where it is sent
  if let .ok v := args.getObjVal? "message" then
    let .ok label := v.getStr? | throw "message must be the label of a message of the protocol"
    let uses := p.global.messages.filter (·.label == label)
    if uses.isEmpty then throw s!"{label} is not a message of {p.name}"
    let labels := (p.global.messages.map (·.label)).eraseDups
    let ms ← Session.Types.complete p.types labels
    let some m := ms.find? (·.name == label) | throw s!"{label} has no message type"
    let proto ← Session.Types.proto p.types labels (Skeleton.snake p.name) p.labelHistory (mediaLabels p)
    let field := (Session.Types.payloadNumbers labels p.labelHistory).lookup label
    let declared := (Session.Types.find p.types label).isSome
    return fit <| Json.mkObj
      [ ("tool", "session_explore"), ("verdict", "described"), ("message", Json.str label)
      , ("reading", s!"{label}: {m.fields.length} field{if m.fields.length == 1 then "" else "s"}" ++
          (if declared then "" else " (no structure declares it, so it carries nothing)") ++
          (match field with | some f => s!"; payload field {f} of the envelope" | none => "") ++
          s!"; sent {uses.length} way{if uses.length == 1 then "" else "s"}")
      , ("name", p.name)
      , ("uses", Json.arr (uses.map fun i => Json.mkObj ([("from", Json.str i.src), ("to", Json.str i.dst)] ++
          (match i.route with | some r => [("route", Json.str r)] | none => []) ++
          (match i.status with | some x => [("status", toJson x)] | none => []))).toArray)
      , ("field", toJson field)
      , ("example", m.example p.types)
      , ("exampleNote", "integers are decimal strings, as the protobuf JSON mapping writes 64-bit integers and conformance reads them")
      , ("schema", m.schema)
      , ("proto", match Session.Types.protoBlock proto label with | some b => Json.str b | none => Json.null) ]
  -- a role's state machine: its typestate's states and transitions
  if let .ok v := args.getObjVal? "states" then
    let p := (focused.map (·.1)).getD p
    let .ok role := v.getStr? | throw s!"states must be a role: one of {", ".intercalate p.roles}"
    if !p.roles.contains role then throw s!"{role} is not a role of {p.name}; its roles are {", ".intercalate p.roles}"
    let l ← p.global.project role
    let (start, methods) := l.machine
    let edge (a b label kind : String) : Json :=
      Json.mkObj [("from", Json.str a), ("to", Json.str b), ("label", Json.str label), ("kind", Json.str kind)]
    let mut edges : Array Json := #[]
    let mut finals : List String := []
    for (i, m) in methods do
      let src := s!"S{i}"
      match m with
      | .send t lab n => edges := edges.push (edge src n s!"send {lab} to {t}" "send")
      | .recv f lab n => edges := edges.push (edge src n s!"receive {lab} from {f}" "receive")
      | .act lab n => edges := edges.push (edge src n lab "event")
      | .offer alts =>
        for a in alts do
          match a with
          | .recv f lab n => edges := edges.push (edge src n s!"receive {lab} from {f}" "receive")
          | .other n => edges := edges.push (edge src n "another branch" "other")
          -- the role takes no part in this branch: its session is over
          | .nothing => edges := edges.push (edge src "End" "nothing for this role" "other")
      | .fork bs n need =>
        for b in bs do edges := edges.push (edge src b "branch" "fork")
        edges := edges.push (edge src n (match need with | some k => s!"after {k} branches" | none => "after every branch") "join")
      | .serve body n =>
        edges := edges.push (edge src body "each session" "serve")
        edges := edges.push (edge src n "then" "then")
      | .cont n => edges := edges.push (edge src n "" "then")
      | .stop => finals := finals ++ [src]
    let named := (edges.toList.flatMap fun e => [(e.getObjValAs? String "from").toOption.getD "", (e.getObjValAs? String "to").toOption.getD ""])
    let states := ([start] ++ (methods.map fun (x : Prod Nat (Method String)) => s!"S{x.1}") ++ named).eraseDups.filter (· != "")
    if states.contains "End" then finals := (finals ++ ["End"]).eraseDups
    if states.length > 400 then throw s!"{role}'s state machine has {states.length} states; at most 400 are drawn"
    return fit <| Json.mkObj
      [ ("tool", "session_explore"), ("verdict", "states"), ("role", Json.str role), ("name", p.name)
      , ("reading", s!"{p.name} as {role}: a state machine of {states.length} states and {edges.size} transitions, from its typestate")
      , ("start", Json.str start), ("finals", Json.arr (finals.map Json.str).toArray)
      , ("states", Json.arr (states.map Json.str).toArray), ("edges", Json.arr edges)
      -- laid out on the server, as the book draws typestates (selfhost.session.layout)
      , ("layout", (Session.Layout.machineJson states start finals (edges.toList.map fun e =>
          let g := fun (k : String) => (e.getObjValAs? String k).toOption.getD ""
          (g "from", g "to", g "label", g "kind"))).getD Json.null)
      , ("typestate", Json.str l.typestate) ]
  match focused with
  | some (q, d) =>
    let name := q.name
    let m := annotatedModel q
    return fit <| Json.mkObj
      [ ("tool", "session_explore"), ("verdict", "drawn"), ("focus", Json.str name)
      , ("reading", s!"{name}: sequence diagram of {messageCount q.global} messages across {q.roles.length} lifelines (lines {d.first} to {d.last})")
      , ("name", p.name), ("roles", Json.arr (q.roles.map Json.str).toArray), ("first", toJson d.first), ("last", toJson d.last)
      , ("svg", m.svg (themeOf args))
      , ("diagram", modelJson m) ]
  | none =>
    let load := p.roles.map fun r =>
      let rows := ActorView.rows p.global r
      let sends := (rows.filter (·.direction == "sends")).length
      let receives := (rows.filter (·.direction == "receives")).length
      (r, s!"sends {sends} and receives {receives} kinds of message; open it for its view")
    let (nodes, omitted, _) := Outline.tree text p.name p.global load
    let msgs := (nodes.filter (·.kind == "message")).size
    let incs := (nodes.filter (·.kind == "include")).size
    let cut := if omitted == 0 then "" else s!"; {omitted} more nodes left out (at most {Outline.maxNodes})"
    return fit <| Json.mkObj
      [ ("tool", "session_explore"), ("verdict", "outlined")
      , ("reading", s!"{p.name}: {nodes.size} nodes to browse: {ds.length} protocols defined, {incs} included where used, {msgs} message steps, {p.roles.length} roles{cut}; folded at the start, open a node to see inside")
      , ("name", p.name), ("roles", Json.arr (p.roles.map Json.str).toArray), ("lean", Json.str text)
      , ("tree", Json.arr (nodes.map Outline.nodeJson)), ("treeOmitted", toJson omitted)
      , ("definitions", Json.arr (ds.map fun d => Json.mkObj [("name", Json.str d.name), ("first", toJson d.first), ("last", toJson d.last)]).toArray)
      , ("provenance", Json.mkObj
          [ ("question", Json.str s!"How is {p.name} put together: which protocols it includes, where it chooses, runs in parallel, loops and starts independent sessions, and which messages each part sends?")
          , ("eventSource", "the protocol text")
          , ("reducer", "Text.parse into the main protocol's global type, walked by Outline.walk (an include as its protocol's node); Outline.defs for each definition's lines; ActorView.rows for each role's messages")
          , ("unit", "nodes: protocols, frames, branches, messages and events; lines of the text")
          , ("boundary", s!"the main protocol {p.name} with every protocol it includes, the protocols defined, and the roles; at most {Outline.maxNodes} nodes") ]) ]

def toolNames : List String := ["session_check", "session_diagram", "session_mdp", "session_sla", "session_simulate", "session_conform", "session_spans", "session_skeleton", "session_next", "session_compat", "session_ctl", "session_instances", "session_openapi", "session_types", "session_review", "session_actor", "session_dataset", "session_explore", "session_deployment", "session_realizable"]

def run (name : String) (args : Json) : Option (Except String Json) :=
  match name with
  | "session_check" => some (check args)
  | "session_diagram" => some (diagram args)
  | "session_mdp" => some (mdp args)
  | "session_sla" => some (sla args)
  | "session_simulate" => some (simulate args)
  | "session_conform" => some (conform args)
  | "session_spans" => some (spans args)
  | "session_skeleton" => some (skeleton args)
  | "session_next" => some (next args)
  | "session_compat" => some (compat args)
  | "session_ctl" => some (ctl args)
  | "session_instances" => some (instances args)
  | "session_openapi" => some (openapi args)
  | "session_types" => some (types args)
  | "session_review" => some (review args)
  | "session_actor" => some (actor args)
  | "session_dataset" => some (dataset args)
  | "session_explore" => some (explore args)
  | "session_deployment" => some (deployment args)
  | "session_realizable" => some (realizable args)
  | _ => none

/-! ## Reference -/

def reference : String := "# LeanFM session types

Design interactions between roles as a session type in LeanFM's protocol syntax, then let LeanFM
check it, draw it and run it. Every diagram, call list and event stream is generated from the text.
Send the text as the `lean` argument of the tools. It is parsed with the same Lean parser that
reads it in a Lean file, and nothing in it is elaborated or run as code. A `where` condition is run by conformance with
LeanFM's own interpreter over the fields each event logs (see Conditions, below).
" ++ "\n" ++ LeanFM.Logic.renamedWords ++ "\n\n" ++ "
The same text is a Lean file. Saved with `import LeanFM.Session.Syntax` as its first line (the
tools accept and write that line), `lake env lean File.leanfm` elaborates it with the LeanFM
library: labels are types (a label no structure declares carries nothing), and every condition is
type-checked against the structures. So names may not be Lean keywords, and a protocol may not
share its name with one of its labels.

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
- with `loop`, `accrue` or `after` on an event (or `view: \"chain\"`): an absorbing Markov chain.
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

## Requirements: what is promised, and the event stream as state

Choice probabilities are assumptions: what peers decide where nobody else can see. Requirements
are promises, written after the protocols in one block per entry message id:

```
require per q {
  every q reaches Ok, NotFound, Unavailable, Timeout504 within 2 seconds;
  at least 98/100 of q reach Ok, NotFound within 300 ms over 1 hour expecting 500 per hour;
  at most 1/200 of q reach Unavailable, Timeout504 over 1 hour confidence 99/100;
}
```

| clause | meaning |
|---|---|
| `every q reaches A, B within d;` | a hard deadline: every occurrence of q is followed in its causal future by A or B within d. One miss is a counterexample, so it takes no window. |
| `at least p of q reach A within d over W;` | a promised minimum fraction of entries. |
| `at most p of q reach A over W;` | a promised maximum fraction. |
| `over 1 hour`, `over 500 entries` | the observation period: tumbling windows by time or by entry count, required for every fraction, so the first miss alone never breaks a promise. |
| `confidence 95/100` | the confidence a window's verdict must reach (default 95/100). |
| `expecting 500 per hour` | the expected entry rate, so a time window can be checked for size at design time. |

At design time, `session_sla` checks each requirement against the assumptions on the chain: per
entry, the exact interval of the probability (an interval when exploration is cut short), the
verdict met, violated or undecided, and the most probable path that breaks it, with each
assumption it passes through shown as `[name -> First: p]`: the choice's name, the first message
of the branch taken, and its probability. Name a choice for its question (`IsBusy`), since the
name covers every branch. A window needs ceil(ln(1/(1-c))/margin)
entries to tell the promise from a failure rate of 0 or 1. The tool says when a window cannot hold
that many.

An execution is an event stream, and it is the only state: actors keep none of their own.
`{ts, label, from, to, prev?, cause?, reward?}` names each event by a unique timestamp in
nanoseconds, sent as a decimal string (nanoseconds since the epoch are past 2^53, where a JSON
number in a browser has already lost its low bits), and `prev` and `cause` link it to earlier
events. Labels must be the protocol's, and reward units ones its amounts use. A role's view is its events and their causal past. A reward
vector `{role: {unit: amount}}` is written only where it changes, and the vector at an event is
found by walking `prev` back to the latest one written (none means zero). An entry hits when a
target is in its causal future within the deadline. An entry whose deadline outlives the stream is
pending. Each window is judged only once it closes, with an exact one-sided binomial test, and
until then it is open.

See examples/sessions/UserLookup (a lost forward, a failing lookup and a 504 timer; the error
budget is violated by the stated assumptions).

## Message types

Every message has a type, declared in the session type itself, as Lean structures before the
protocols. From them LeanFM writes the .proto, the Lean module and the OpenAPI document:

```
structure Quote where
  price : Nat
structure Pay where
  amount : Nat
  card_secr : String
```

An existing proto3 file may stand in for the structures, given as `proto` beside `lean`. LeanFM
reads `message`s whose fields are unsigned integers (`Nat`), signed ones (`Int`), `string`,
`bool`, another message, `repeated` (`List`) or `optional` (`Option`), keeping each field's number;
`float`, `double`, `bytes`, `import`, nested messages, `enum`, `oneof` and `map` are refused with
the reason, and the text may not declare structures as well.

A message whose label names a structure carries it; one whose label names none carries nothing, and
so does an event. Field types are `Nat`, `Int`, `String`, `Bool`, another structure,
or `List T` / `Option T` of one of those. Fields are numbered in the order written, which is their
protobuf number, so add new fields at the end. `deriving ...` is accepted and ignored. A name ending
in `_secr` is a secret: a mark protocol tests may ask about (session_ctl's `secret` atom), not a rule;
a condition may read one and a log may carry one (session_conform lists them as `secretFields`). `session_types` writes the types as protobuf, as Lean structures with JSON
conversions, and as JSON schemas; `session_openapi` and `session_skeleton` use the same types.

## The event envelope

JSON is only how a protobuf message travels. Every event is an `Event`: `ts` (nanoseconds, unique in
its stream), `id`, `session`, `from`, `to`, `label`, `cause`, `prev`, and a payload of one of the
protocol's message types; `session_types` writes it with the messages. Integers (`Nat`, `Int`,
timestamps) travel as decimal strings, as the protobuf JSON mapping writes 64-bit values; a JSON
number is accepted for one only when it is whole and within 2^53 - 1. `session_simulate` stamps every
event with such a `ts`, unique and after everything the event happened after.

A sessions block may name its key: `sessions by a.caller { a: Ask from A to B; ... }`. The key is a
`Nat` or `String` field of a message of the block; generated code logs it with that message, and
conformance requires every event of a session to name the key's value as its session, so threads
are told apart by data the protocol declares.

## Conditions

`p: Pay from Client to Shop cause q where p.amount = q.price;` is typed when the text is read and
run by conformance, never compiled. The language: field paths over message ids (`p.amount`, or
`p.address.city` through a nested structure), numbers (exact), strings, `true`, `false`,
`= != < <= > >=`, `+ - * /`, `and`, `or`, `not`, parentheses. It must type-check against the message
types: each path names a declared single field (not a list or a whole structure), both sides
of a comparison have the same type, and the whole is true or false. At run time conformance evaluates it over the
`fields` each event logs: `{\"id\": \"e3\", \"label\": \"Pay\", ..., \"fields\": {\"amount\": 12}}`. A false
condition means the message does not match (a guard selects among branches by data), and the problem
names the condition and the values it read. One that cannot be decided (a field missing from the log,
a message not yet in the session, division by zero) is reported as unchecked, never as satisfied.
Logged fields must be fields of the event's message, of their declared types: a log that breaks this
is refused, naming the event. A log may carry secrets; the answer's `secretFields` names each one. Generated code logs exactly the fields conditions
read, and nothing else of a body.

## Versions

A file keeps the versions of a protocol still deployed, oldest first, each a whole protocol:

```
protocol Lookup (Client, Server) version 1 { q: Get from Client to Server; Found from Server to Client cause q; }
protocol Lookup (Client, Server) version 2 {
  q: Get from Client to Server;
  choice { Found from Server to Client cause q; } or { Missing from Server to Client cause q; }
}
```

Each version must have a clean upgrade path from the one before: an order to upgrade the roles one
at a time such that every mixed deployment on the way (upgraded roles on the new version, the rest
on the old) runs without getting stuck. A version without one is refused, by Lean when the file
compiles and by every tool when it reads the text, with the first steps that get stuck. In Lean,
version N is `Lookup.vN`; a plain `include Lookup` or `accept Lookup` means the newest version
defined before it. Every event carries `protocol` and `version` in its envelope (fields 11 and 12;
payloads start at 16), and a label keeps its payload number in every version; a dropped label's
number is reserved. With a versioned protocol, `session_conform` requires every event to name one of
its versions and checks each session against the version it names.

## Deployments

A protocol says who sends what, in which order; a `deployment` block, after it, says where each role
runs. It adds no message and changes no order or nesting:

```
deployment Production of ShopImpl {
  kind grpc refines http adds \"deadline exceeded\";   -- optional: a kind refined from a known one
  outside { Client; }
  island us {
    datacenter dc1 {
      machine m1 {
        Api { ingress https : ingressHttps; }
        Db { local sql : call; }
      }
    }
  }
  island eu {
    replicated ledger { Bank { peering api : api; internal admin : api; } }
  }
}
```

`outside` and `island` groups are the top of the tree; `datacenter`, `machine`, `replicated` and
`sharded` groups go inside an island. A role is written `Role;` or `Role { scope name : kind; }`,
each role of the protocol exactly once. Scopes: `ingress` (anyone may call it), `peering` (any
island, not outside), `internal` (the same island), `local` (the same machine). Kinds: call, queue,
stream, http, api, ingressHttp, ingressHttps, datagram, or one declared with `kind`. Each message
from A to B arrives on the first of B's interfaces A can reach; a role with no interfaces is
unrestricted. Placement adds conditions for the implementation to handle: hostile from or to
outside, partition across islands, reject into a replicated group, per-key order into a sharded
one. A role unplaced or placed twice, a name that is not a role, an unknown kind, and a message no
interface of its receiver lets through are errors, in Lean when the file compiles and from
`session_deployment`, which also draws the tree with its links.

## Instances

A protocol describes one conversation; a server runs many at once. A `system` block, after the
protocols, says which instances exist:

```
system Shop {
  instance db : Db serial;
  instance cache : Cache;
  accept Order (fresh Client, db, cache);
}
```

`instance db : Db serial;` is a shared instance, created once, playing role `Db` (its actor is
`Db/db`). `accept Order (...)` is one instance of `Order` per accept, with one player per role in
`Order`'s order: `fresh Client` (that position's role) is a new actor for every instance
(`Client/s1`, `Client/s2`, ...), and a shared instance plays its own role. Instances share nothing
but messages, and use only the shared instances they were given. A `serial` instance serves one
session at a time, from its first message in a session until that session no longer mentions its
role; without `serial`, each caller gets a session of its own. So two accepts that take two serial
instances in opposite orders can deadlock, and `session_instances` shows how. With a system in the
text, `session_conform` also checks the log's actors: every one is `Role/instance`, a shared
instance plays its own role, and a fresh actor belongs to one session only.

## Tools

- `session_review {lean}`: every check that applies, in one answer, each finding with an edit to
  try: the core rules; HTTP wherever a message has a `route` (its channel is HTTP and its sender may
  call its receiver, so no flags are needed), including requests never answered (with the response
  line to add) and responses to routed requests without a status; a session that can never end (a
  loop with no way out); roles that take no part. Call it after every change while designing.

- `session_sla {lean, events?, at?}`: the `require per` block against the assumptions (exact
  interval, verdict, breaking path, window size), and with `events` against an execution (hits,
  misses, pending, each closed window's verdict, each role's view); `at` gives one event's reward
  vector and causal past.

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
  concurrent copies. When the text declares message types, each message also carries example
  `fields`: sessionId names one of three people, requestId counts requests, and every `where`
  clause holds (a response copies the fields it must equal); a clause that is not equalities
  leaves the stream without fields.

- `session_conform {lean, events, allowIncomplete?}`: check what a running program logged against
  the protocol. Log one event per message sent, `{\"id\": \"e7\", \"session\": \"42\", \"from\": \"Shop\",
  \"to\": \"Client\", \"label\": \"Quote\", \"cause\": \"e6\"}`, and one per event, `{\"id\": ..., \"at\":
  \"Shop\", \"label\": \"Completed\", \"act\": true}`. Each session must follow the protocol: order,
  choices, the cause the protocol names, and an end the protocol allows (unless allowIncomplete).
  session_simulate's events are accepted as they are. The order of the log does not matter: `from`
  and `to` may name actors (`Server/s1`), `prev` names the previous event the same actor sent, and
  `sentAt`/`receivedAt` are the sender's and the receiver's clock readings in nanoseconds; each
  session is replayed in the order these links and each actor's own clock give, and links that
  name nothing, fork an actor's order, or form a cycle are reported.

- `session_spans {lean, events}`: time every call in a log (a request and the reply naming it as
  cause) without comparing clocks: the caller's view (reply received minus request sent, its
  clock), the callee's own (reply sent minus request received, its clock), the network time both
  ways together, the sub-calls (concurrent where they overlap on the callee's clock), the critical
  path, and each call tree on its root caller's timeline. A callee that took longer than its caller
  waited is reported as inconsistent.

- `session_actor {lean, role}`: the protocol as one role sees it: its local type and typestate, a
  sequence diagram of only the steps it takes part in (its lifeline and its peers'), its messages
  (sends, receives or its own event, with peer, route, status and payload field number), the HTTP
  interface it serves as OpenAPI (JSON and YAML), the routes it calls, and the whole protocol's
  proto file (a role's payloads keep the whole protocol's field numbers).

- `session_dataset {lean, sessions?, seed?}`: generate many sessions (default 1000, at most
  10000, 1000000 events in all) and answer how they are distributed: paths with their counts (top
  12), messages with how many sessions contain each, messages sent and received per role, events
  per session and duration histograms. With a probability layer the sessions follow its weights;
  without one each walk takes one allowed step or the end, equally likely, and the answer says those
  frequencies describe the walker, not the system. Sessions that were cut at 600 events or got stuck
  are counted, never reported as ended.

- `session_explore {lean | example, focus?}`: the protocol as a tree to browse: the main protocol's
  structure (included protocols, choices and branches, parallel branches, loops, sessions, messages
  and events), the roles and every protocol defined, each node with the lines it comes from. The
  view lists it like a file explorer, folded at the start: click a row to see it, click its arrow
  or double click to open it, and a node shows its source, a protocol's sequence diagram or a role's view. With `focus: Name`, the
  sequence diagram of the protocol Name the text defines.

- Every session tool also takes `example` instead of `lean`: the name of a protocol LeanFM carries
  (goserver, ride, boundedride, placeorder, lending), for a client that cannot send a file.

- `session_deployment {lean, deployment?, theme?}`: the text's last `deployment` block, or the one
  named, checked against the protocol it places: placed or refused, each role's groups and
  interfaces, each link (sender and receiver) with the interface it uses and the conditions it adds,
  every issue, and an SVG of the tree with the links (a refused one dashed).

- `session_instances {lean, instances?, perInstance?, properties?}`: the text's last `system`
  block (see Instances below) with 1 to 4 instances of each accept interleaved (default 2, at
  most 4 in all): every deadlock with the steps that reach it and what each instance waits for,
  isolation over every step, and each formula's verdict with its path. A `perInstance` formula is
  checked for every instance: `{\"on\": \"Label\"}` is that instance's Label and `\"stop\"`
  means it has finished. A `properties` formula is about the system: any instance's Label, and
  every instance able to end. Answers `ok`, `deadlock`, `isolation` or `disproved`.

- `session_next {lean, events?}`: what may happen next in one session after the events so far (in
  session_conform's format): each allowed step with the cause it must name, and whether the session
  may stop here (`running`, `finished`, or `violates` with the first problem). The view's walk-through
  calls it after every click.

- `session_ctl {lean, faithful}`: the protocol's faithful CTL. `faithful: \"rules\"` answers its
  typestates (its checker model's states up to bisimulation), the lookahead (how many steps a typestate
  needs to be told from another; 0 when its last message names it) and one rule per typestate: in it,
  each next typestate is possible and nothing else is. `faithful: {task: draft}` or `{lean: text}`
  decides whether that model is faithful to the protocol as one bisimulation check (a walk when the
  typestates are deterministic, a refinement otherwise), and names the shortest path to where they
  differ.
- `session_ctl {lean, formula}`: a CTL formula over one session, decided on the protocol's state
  graph by the same checker as check_ctl, with a witness or counterexample path. The formula may be
  JSON or an s-expression string such as `(AG (implies (on Order) (AF (on Confirmed))))`, with
  shared parts labelled `#1=` and reused as `#1#`. Atoms:
  `{\"on\": \"Label\"}` (a Label message or event has just happened) and `\"stop\"` (the session
  has ended), and `{\"secret\": {from?, to?, field?}}` (the step just taken carried a field ending in
  `_secr`; ask it when the project needs secrecy, such as no secret ever reaching Log:
  `{\"AG\": {\"not\": {\"secret\": {\"to\": \"Log\"}}}}`). Without a formula it suggests up to 12
  properties built from the protocol, each decided. Rules the structure does not show belong here, for example:
  never charge after no seat, `{\"AG\": {\"implies\": [{\"on\": \"NoSeat\"}, {\"AG\": {\"not\": {\"on\": \"Charge\"}}}]}}`;
  every held seat is confirmed or released, `{\"AG\": {\"implies\": [{\"on\": \"SeatHeld\"}, {\"AF\": {\"or\":
  [{\"on\": \"SeatConfirmed\"}, {\"on\": \"SeatReleased\"}]}}]}}`; every session ends, `{\"AF\": \"stop\"}`.

- `session_openapi {lean, role}`: the requests `role` receives, with their routes and the responses
  the protocol allows, as an OpenAPI 3.1 document: one operation per route, the label as its
  operationId and body, each response under its status. Each body's schema is its message type,
  admitting no other fields. Requests without a route are listed, not guessed.

- `session_types {lean, proto?}`: the message types as a proto3 file with the `Event` envelope, as
  Lean structures and as JSON schemas, one per message; and `leanModule`, the session as one Lean
  module: the payload types, `Role`, `Payload` (one constructor per message and event), `Event`,
  and for each role its states as an inductive type with `start`, `step : State -> Event -> Option
  State`, `final` and `accepts`. A role whose projection runs branches in parallel or serves
  sessions has no single machine; `leanModuleNote` says so.

- `session_compat {lean, old?}`: two versions of a protocol (`lean` the new one, `old` the
  previous one; without `old`, the newest two versions `lean` keeps). For each role in both: can
  its new version be deployed first, among the old versions of every other role, and can its old
  version stay deployed after the others upgrade? Each mixed system is explored to every reachable
  state; a no comes with the steps to where it gets stuck. `upgradePath` is an order to upgrade the
  roles one at a time, every mixed deployment on the way checked, or why there is none. Adding a
  message a role may receive usually lets that role upgrade first; adding one it may send usually
  means the receivers must upgrade first.

- `session_skeleton {lean, language?}`: a self-contained Python (the default) or TypeScript
  (`\"language\": \"typescript\"`) module with every role's typestate as classes, one per state. In
  TypeScript a step the state does not allow does not type-check, and `receive` returns a union
  tagged by `label` that narrows `next`. A method sends only what its state allows, fills in the cause the
  protocol names, logs the event in session_conform's format and returns the next state; `receive`
  accepts only what the state allows; a state used twice raises. Write only the decisions (which
  branch, what each message carries) and the transport: a function that delivers a message. Each
  message type is a dataclass (Python) or interface (TypeScript, with `Nat` and `Int` as bigint);
  send methods take it and encode it, `receive` decodes the body into it, and a body that does not
  fit its type is refused either way. Every logged event carries `ts` in nanoseconds; `set_clock`
  (`setClock`) replaces the clock for replayable runs.

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
import LeanFM.Session.Syntax

/-- The shop's price for the order, in cents. -/
structure Quote where
  price : Nat

/-- The client pays; the card number is a secret, never logged. -/
structure Pay where
  amount : Nat
  card_secr : String

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
| `x: Label from A to B cause y route \"...\" status 201 media \"image/png\" where e;` | a message; `x:`, `cause`, `route`, `status`, `media` and `where` are optional; `media` says the body is raw bytes of that type instead of JSON, so the message's fields travel as `Header`, `PathParam` or `QueryParam`; `cause y` names an earlier id, and a response's cause chain reaches its request |
| `Label at A;` | something a role does on its own |
| `choice { ... } or { ... }` | exactly one branch happens; the role that sends the first message of every branch decides (`select` in its local type); the others learn the branch from what reaches them (`offer`) |
| `parallel { ... } and { ... }` | branches run concurrently; what follows waits for all |
| `join 2 of { ... } and { ... } and { ... }` | what follows waits for any 2 branches |
| `loop Loop { ... continue Loop; }` | a loop; `continue` is the last statement of its block |
| `sessions { ... }` | any number of independent instances, as a server handles requests; nested inside a protocol, a role that appears only in such blocks is a service that handles each one on its own |
| `include Replicate Primary R1 R2 R3;` | an earlier protocol in the same text, roles renamed in order, drawn as a ref frame |

A role may carry its inbox size, `protocol Shop (Client, Api[8], Bank[2])`: a FIFO buffer that loses
nothing, 0 to 64 messages, 0 (a rendezvous) when no size is given. Only `session_realizable` reads
sizes: it checks what a deployment of independent roles with those inboxes can do against the
protocol, and reports an order the protocol does not allow or a deadlock.

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

The tools also accept `protocol: {name, roles, steps, types?}` in place of `lean`, and answer with
the same protocol written as text. `types` declares the message types:
`[{\"name\": \"Pay\", \"fields\": [\"amount : Nat\"]}]`. Each step is an object with exactly one kind key: `msg` (with `from`,
`to`, and optional `id`, `cause`, `route`, `status`, `where`), `event` (with `at`), `choice` and
`parallel` (arrays of branches, each an array of steps), `join` (a number, with `of`), `loop` (with
`steps`), `continue`, `sessions` (an array of steps) and `include` (with `steps`):

```json
{\"name\": \"PlaceOrder\", \"roles\": [\"Client\", \"Shop\", \"Bank\"],
 \"types\": [{\"name\": \"Quote\", \"fields\": [\"price : Nat\"]},
           {\"name\": \"Pay\", \"fields\": [\"amount : Nat\", \"card_secr : String\"]}],
 \"steps\": [
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
