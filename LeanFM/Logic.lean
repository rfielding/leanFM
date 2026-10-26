import Lean.Data.Json
import LeanFM.Artifacts
import LeanFM.LLMGenerated.SelfHosting

/-!
# LeanFM logic consultation (selfhost.mcp.logic.*)

Pure, path-free, deterministic logic tools for MCP agents. Formulas, tasks,
traces and predicate texts are parsed from JSON into closed data types; no
constructor carries code, a closure or a file path, so nothing submitted can
run (proof obligation: "Submitted logic never runs as code"). This module
defines no `IO` actions.

Requirement refs: clause:selfhost.mcp.logic.reference, .explain, .ctl, .trace,
.observability, .knows, .safety; property:Logic answers carry their evidence;
proof:Exhausted search never proves; proof:Hidden predicates never pass as observable.
-/

namespace LeanFM.Logic
open Lean

/-! ## Bounds -/

structure Bounds where
  maxFormulaNodes : Nat := 256
  maxDepth : Nat := 64
  maxString : Nat := 256
  maxArgumentBytes : Nat := 65536
  maxDraftStates : Nat := 8192
  maxDraftTransitions : Nat := 16384
  maxModelNodes : Nat := 4096
  maxEvents : Nat := 512
  maxConcurrentPairs : Nat := 64
  maxPredicates : Nat := 64
deriving Repr

def bounds : Bounds := {}

def boundsJson (b : Bounds := bounds) : Json :=
  Json.mkObj
    [ ("maxFormulaNodes", toJson b.maxFormulaNodes), ("maxDepth", toJson b.maxDepth)
    , ("maxString", toJson b.maxString), ("maxArgumentBytes", toJson b.maxArgumentBytes)
    , ("maxDraftStates", toJson b.maxDraftStates), ("maxDraftTransitions", toJson b.maxDraftTransitions)
    , ("maxModelNodes", toJson b.maxModelNodes), ("maxEvents", toJson b.maxEvents)
    , ("maxConcurrentPairs", toJson b.maxConcurrentPairs), ("maxPredicates", toJson b.maxPredicates) ]

def terminalConvention : String :=
  "Terminal states, and non-terminal states with no outgoing transition (reported as deadlocks), " ++
  "repeat forever: they stutter on themselves, keeping the message that reached them, so every path is infinite. " ++
  "after(m) holds in the state reached by delivering m; the initial state has no message."

/-! ## Formulas -/

inductive Formula where
  | tt
  | ff
  | atState (state : String)
  | after (message : String)
  | terminal
  | field (message name value : String)
  | predicate (text : String)
  | derived (name : String)
  | unsupported (operator : String)
  | not (f : Formula)
  | and (fs : List Formula)
  | or (fs : List Formula)
  | implies (a b : Formula)
  | stronglyImplies (a b : Formula)
  | never (f : Formula)
  | ex (f : Formula)
  | ax (f : Formula)
  | ef (f : Formula)
  | af (f : Formula)
  | eg (f : Formula)
  | ag (f : Formula)
  | eu (a b : Formula)
  | au (a b : Formula)
  | ew (a b : Formula)
  | aw (a b : Formula)
deriving Repr, Inhabited, BEq

namespace Formula

partial def size : Formula → Nat
  | not f | never f | ex f | ax f | ef f | af f | eg f | ag f => 1 + size f
  | and fs | or fs => 1 + (fs.map size).foldl (· + ·) 0
  | implies a b | stronglyImplies a b | eu a b | au a b | ew a b | aw a b => 1 + size a + size b
  | _ => 1

partial def toJson : Formula → Json
  | tt => Json.bool true
  | ff => Json.bool false
  | atState s => Json.mkObj [("at", s)]
  | after m => Json.mkObj [("after", m)]
  | terminal => "terminal"
  | field m n v => Json.mkObj [("field", Json.mkObj [("message", m), ("name", n), ("value", v)])]
  | predicate t => Json.mkObj [("predicate", t)]
  | derived n => Json.mkObj [("derived", n)]
  | unsupported op => Json.mkObj [(op, Json.null)]
  | not f => Json.mkObj [("not", toJson f)]
  | and fs => Json.mkObj [("and", Json.arr (fs.map toJson).toArray)]
  | or fs => Json.mkObj [("or", Json.arr (fs.map toJson).toArray)]
  | implies a b => Json.mkObj [("implies", Json.arr #[toJson a, toJson b])]
  | stronglyImplies a b => Json.mkObj [("stronglyImplies", Json.arr #[toJson a, toJson b])]
  | never f => Json.mkObj [("never", toJson f)]
  | ex f => Json.mkObj [("EX", toJson f)]
  | ax f => Json.mkObj [("AX", toJson f)]
  | ef f => Json.mkObj [("EF", toJson f)]
  | af f => Json.mkObj [("AF", toJson f)]
  | eg f => Json.mkObj [("EG", toJson f)]
  | ag f => Json.mkObj [("AG", toJson f)]
  | eu a b => Json.mkObj [("EU", Json.arr #[toJson a, toJson b])]
  | au a b => Json.mkObj [("AU", Json.arr #[toJson a, toJson b])]
  | ew a b => Json.mkObj [("EW", Json.arr #[toJson a, toJson b])]
  | aw a b => Json.mkObj [("AW", Json.arr #[toJson a, toJson b])]

def isAtomic : Formula → Bool
  | tt | ff | atState _ | after _ | terminal | field .. | predicate _ | derived _ | unsupported _ => true
  | _ => false

mutual
partial def reading : Formula → String
  | tt => "true"
  | ff => "false"
  | atState s => "the task is in state " ++ s
  | after m => m ++ " was just delivered"
  | terminal => "the task has ended"
  | field m n v => "the last message was " ++ m ++ " with " ++ n ++ " = " ++ v
  | predicate t => "\"" ++ t ++ "\" holds (a predicate text, not an observable event)"
  | derived n => "the derived predicate " ++ n ++ " holds"
  | unsupported op => "the " ++ op ++ " modality holds (not supported by these tools yet)"
  | not f => "it is not the case that " ++ paren f
  | and fs => " and ".intercalate (fs.map paren)
  | or fs => " or ".intercalate (fs.map paren)
  | implies a b => "if " ++ paren a ++ " then " ++ paren b
  | stronglyImplies a b => paren a ++ " can happen, and on every path, whenever " ++ paren a ++ " then " ++ paren b
  | never f => "on every path, never " ++ paren f
  | ex f => "on some path, at the next step " ++ paren f
  | ax f => "on every path, at the next step " ++ paren f
  | ef f => "it is possible that eventually " ++ paren f
  | af f => "on every path, eventually " ++ paren f
  | eg f => "on some path, always " ++ paren f
  | ag f => "on every path, always " ++ paren f
  | eu a b => "on some path, " ++ paren a ++ " holds until " ++ paren b ++ " (and " ++ paren b ++ " does happen)"
  | au a b => "on every path, " ++ paren a ++ " holds until " ++ paren b ++ " (and " ++ paren b ++ " does happen)"
  | ew a b => "on some path, " ++ paren a ++ " holds unless " ++ paren b ++ " (" ++ paren b ++ " need not happen)"
  | aw a b => "on every path, " ++ paren a ++ " holds unless " ++ paren b ++ " (" ++ paren b ++ " need not happen)"
partial def paren (f : Formula) : String :=
  if f.isAtomic then reading f else "(" ++ reading f ++ ")"
end

/-- Negation pushed inward through the CTL dualities. -/
partial def negate : Formula → Formula
  | tt => ff
  | ff => tt
  | not f => f
  | and fs => or (fs.map negate)
  | or fs => and (fs.map negate)
  | implies a b => and [a, negate b]
  | stronglyImplies a b => or [ag (negate a), ef (and [a, negate b])]
  | never f => ef f
  | ex f => ax (negate f)
  | ax f => ex (negate f)
  | ef f => ag (negate f)
  | af f => eg (negate f)
  | eg f => af (negate f)
  | ag f => ef (negate f)
  | au a b => ew (negate b) (and [negate a, negate b])
  | eu a b => aw (negate b) (and [negate a, negate b])
  | aw a b => eu (negate b) (and [negate a, negate b])
  | ew a b => au (negate b) (and [negate a, negate b])
  | f => not f

def mode : Formula → String
  | never _ => "never"
  | ag (not _) => "never"
  | ag _ => "always"
  | af _ => "eventually"
  | au .. => "eventually"
  | ef _ | ex _ | eu .. | eg _ | ew .. => "possibly"
  | stronglyImplies .. => "always (non-vacuous)"
  | _ => "compound"

partial def subformulas (f : Formula) : List Formula :=
  f :: match f with
    | not g | never g | ex g | ax g | ef g | af g | eg g | ag g => subformulas g
    | and fs | or fs => fs.flatMap subformulas
    | implies a b | stronglyImplies a b | eu a b | au a b | ew a b | aw a b => subformulas a ++ subformulas b
    | _ => []

def atoms (f : Formula) : List Formula := (subformulas f).filter isAtomic

end Formula

/-! ## Parsing (JSON data only) -/

def keyValues (j : Json) : List (String × Json) :=
  match j with
  | .obj kvs => kvs.toList
  | _ => []

def str? (j : Json) : Option String := (j.getStr?).toOption

def checkString (what s : String) : Except String String :=
  if s.length > bounds.maxString then .error s!"{what} is longer than {bounds.maxString} characters"
  else if s.isEmpty then .error s!"{what} is empty"
  else .ok s

def pathOperatorHint (op : String) : Option String :=
  match op with
  | "F" | "eventually" | "<>" => some "F is a path operator; quantify it: AF (on every path) or EF (on some path)"
  | "G" | "always" | "[]" => some "G is a path operator; quantify it: AG (on every path) or EG (on some path)"
  | "X" | "next" => some "X is a path operator; quantify it: AX (every path) or EX (some path)"
  | "U" | "until" => some "U is a path operator; quantify it: AU or EU (or AW/EW when the right side need not happen)"
  | "W" | "unless" => some "W is a path operator; quantify it: AW or EW"
  | _ => none

def unsupportedOperators : List String :=
  ["K", "knows", "O", "obliged", "obligatory", "P", "permitted", "B", "believes", "Pr", "probability", "C", "common"]

partial def parseFormula (j : Json) (depth : Nat := 0) : Except String Formula := do
  if depth > bounds.maxDepth then throw s!"formula nesting exceeds depth {bounds.maxDepth}"
  match j with
  | .bool true => return .tt
  | .bool false => return .ff
  | .str "terminal" => return .terminal
  | .str "true" => return .tt
  | .str "false" => return .ff
  | .str s => throw ("bare string \"" ++ (s.take 40).toString ++ "\" is not a formula; write {\"at\": state}, {\"after\": message} or \"terminal\"")
  | .obj _ =>
    match keyValues j with
    | [(op, arg)] =>
      let one := fun (k : Formula → Formula) => do return k (← parseFormula arg (depth + 1))
      let two := fun (k : Formula → Formula → Formula) => do
        match arg with
        | .arr #[a, b] => return k (← parseFormula a (depth + 1)) (← parseFormula b (depth + 1))
        | _ => throw s!"{op} takes an array of exactly two formulas"
      let many := fun (k : List Formula → Formula) => do
        match arg with
        | .arr items =>
          if items.isEmpty then throw s!"{op} needs at least one formula"
          return k (← items.toList.mapM (parseFormula · (depth + 1)))
        | _ => throw s!"{op} takes an array of formulas"
      let atomStr := fun (k : String → Formula) => do
        match str? arg with
        | some s => return k (← checkString op s)
        | none => throw s!"{op} takes a string"
      match op with
      | "at" => atomStr .atState
      | "after" => atomStr .after
      | "predicate" => atomStr .predicate
      | "derived" => atomStr .derived
      | "field" =>
        let get := fun (k : String) => match (arg.getObjVal? k).toOption.bind str? with
          | some v => checkString ("field." ++ k) v
          | none => .error s!"field needs a string {k}"
        return .field (← get "message") (← get "name") (← get "value")
      | "not" => one .not
      | "never" => one .never
      | "EX" => one .ex | "AX" => one .ax | "EF" => one .ef | "AF" => one .af
      | "EG" => one .eg | "AG" => one .ag
      | "and" => many .and
      | "or" => many .or
      | "implies" => two .implies
      | "stronglyImplies" => two .stronglyImplies
      | "EU" => two .eu | "AU" => two .au | "EW" => two .ew | "AW" => two .aw
      | other =>
        if unsupportedOperators.contains other then return .unsupported other
        match pathOperatorHint other with
        | some hint => throw ("typing error: " ++ hint)
        | none => throw s!"unknown operator \"{other.take 40}\"; see leanfm://language/logic-reference"
    | [] => throw "empty object is not a formula"
    | _ => throw "a formula object has exactly one operator key"
  | _ => throw "a formula is a JSON object, true, false or \"terminal\""

def parseBounded (j : Json) : Except String Formula := do
  let f ← parseFormula j
  if f.size > bounds.maxFormulaNodes then
    throw s!"formula has {f.size} nodes; the bound is {bounds.maxFormulaNodes}"
  return f

/-! ## Task models -/

structure Transition where
  src : String
  dst : String
  message : String
  sender : Option String := none
  receiver : Option String := none
deriving Repr, Inhabited

structure TaskModel where
  id : String
  states : List String
  initial : String
  terminals : List String
  transitions : List Transition
  canonical : Bool
deriving Repr, Inhabited

def canonicalTasks : List TaskRequirement := LeanFM.LLMGenerated.SelfHosting.spec.tasks
def canonicalMessages : List MessageSchema := LeanFM.LLMGenerated.SelfHosting.spec.messages

def ofRequirement (t : TaskRequirement) : TaskModel :=
  { id := t.id, states := t.states.map (·.id), initial := t.initialState
  , terminals := (t.states.filter (·.terminal)).map (·.id)
  , transitions := t.transitions.map fun tr => { src := tr.src, dst := tr.dst, message := tr.message }
  , canonical := true }

def strings (j : Json) (what : String) (limit : Nat) : Except String (List String) := do
  match j with
  | .arr items =>
    if items.size > limit then throw s!"{what} has {items.size} entries; the bound is {limit}"
    items.toList.mapM fun item => match str? item with
      | some s => checkString what s
      | none => .error s!"{what} entries are strings"
  | _ => throw s!"{what} is an array of strings"

def parseDraft (j : Json) : Except String TaskModel := do
  let field := fun (k : String) => (j.getObjVal? k).toOption
  let states ← strings ((field "states").getD (Json.arr #[])) "states" bounds.maxDraftStates
  if states.isEmpty then throw "a draft task needs states"
  let initial ← match (field "initial").bind str? with
    | some s => pure s
    | none => throw "a draft task needs a string initial state"
  let terminals ← strings ((field "terminals").getD (Json.arr #[])) "terminals" bounds.maxDraftStates
  let transitions ← match field "transitions" with
    | some (.arr items) =>
      if items.size > bounds.maxDraftTransitions then
        throw s!"draft has {items.size} transitions; the bound is {bounds.maxDraftTransitions}"
      items.toList.mapM fun t => do
        let g := fun (k : String) => match (t.getObjVal? k).toOption.bind str? with
          | some v => checkString ("transition." ++ k) v
          | none => .error s!"each transition needs a string {k}"
        let opt := fun (k : String) => (t.getObjVal? k).toOption.bind str?
        let tr : Transition := { src := ← g "src", dst := ← g "dst", message := ← g "message"
                               , sender := opt "from", receiver := opt "to" }
        return tr
    | some _ => throw "transitions is an array"
    | none => pure []
  let unknown := ([initial] ++ terminals ++ transitions.flatMap (fun t => [t.src, t.dst])).filter (!states.contains ·)
  if let some s := unknown.head? then throw s!"draft refers to undeclared state \"{s}\""
  let id := ((field "id").bind str?).getD "draft"
  return { id, states, initial, terminals, transitions, canonical := false }

def resolveTask (j : Json) : Except String TaskModel :=
  match j with
  | .str id => match canonicalTasks.find? (·.id == id) with
    | some t => .ok (ofRequirement t)
    | none => .error s!"unknown canonical task \"{id.take 60}\"; known tasks: {", ".intercalate (canonicalTasks.map (·.id))}"
  | .obj _ => parseDraft j
  | _ => .error "task is a canonical task id string or an inline draft object"

def TaskModel.messages (t : TaskModel) : List String := (t.transitions.map (·.message)).eraseDups

def unknownAtoms (t : TaskModel) (f : Formula) : List String :=
  (f.atoms.filterMap fun
    | .atState s => if t.states.contains s then none else some ("unknown state " ++ s)
    | .after m => if t.messages.contains m then none else some ("unknown message " ++ m ++ " for task " ++ t.id)
    | .field m _ _ => if t.messages.contains m then none else some ("unknown message " ++ m ++ " for task " ++ t.id)
    | _ => none).eraseDups

/-! ## Kripke structure -/

structure Node where
  state : String
  message : Option String
deriving Repr, BEq, Inhabited

structure Model where
  task : TaskModel
  nodes : Array Node
  succ : Array (Array Nat)
  deadlocks : List String
deriving Inhabited

def nodeIndex (nodes : Array Node) (n : Node) : Option Nat := nodes.findIdx? (· == n)

/-- Breadth-first construction; `none` when the node bound is exceeded. -/
def buildModel (t : TaskModel) : Option Model := Id.run do
  let mut nodes : Array Node := #[{ state := t.initial, message := none }]
  let mut succ : Array (Array Nat) := #[]
  let mut deadlocks : List String := []
  let mut i := 0
  let mut fuel := bounds.maxModelNodes + 1
  while i < nodes.size && fuel > 0 do
    fuel := fuel - 1
    let n := nodes[i]!
    let outs := t.transitions.filter (·.src == n.state)
    let stutter := t.terminals.contains n.state || outs.isEmpty
    if outs.isEmpty && !t.terminals.contains n.state && !deadlocks.contains n.state then
      deadlocks := deadlocks ++ [n.state]
    let mut next : Array Nat := #[]
    if stutter then
      next := #[i]
    else
      for tr in outs do
        let m : Node := { state := tr.dst, message := some tr.message }
        match nodeIndex nodes m with
        | some j => if !next.contains j then next := next.push j
        | none =>
          if nodes.size >= bounds.maxModelNodes then return none
          nodes := nodes.push m
          next := next.push (nodes.size - 1)
    succ := succ.push next
    i := i + 1
  return some { task := t, nodes, succ, deadlocks }

namespace Model

def size (m : Model) : Nat := m.nodes.size
def all (m : Model) (b : Bool) : Array Bool := Array.replicate m.size b
def mapI (m : Model) (f : Nat → Bool) : Array Bool := (Array.range m.size).map f
def get (a : Array Bool) (i : Nat) : Bool := a[i]?.getD false

def lfp (m : Model) (step : Array Bool → Array Bool) : Array Bool := Id.run do
  let mut z := m.all false
  for _ in [0:m.size + 2] do
    let z' := step z
    if z' == z then return z
    z := z'
  return z

def gfp (m : Model) (step : Array Bool → Array Bool) : Array Bool := Id.run do
  let mut z := m.all true
  for _ in [0:m.size + 2] do
    let z' := step z
    if z' == z then return z
    z := z'
  return z

def existsSucc (m : Model) (z : Array Bool) (i : Nat) : Bool := (m.succ[i]?.getD #[]).any (get z ·)
def allSucc (m : Model) (z : Array Bool) (i : Nat) : Bool := (m.succ[i]?.getD #[]).all (get z ·)

/-- Satisfaction sets by explicit fixpoint labelling; only observable atoms reach here. -/
partial def sat (m : Model) : Formula → Array Bool
  | .tt => m.all true
  | .ff => m.all false
  | .atState s => m.nodes.map (·.state == s)
  | .after msg => m.nodes.map (·.message == some msg)
  | .terminal => m.nodes.map (fun n => m.task.terminals.contains n.state)
  | .not f => (sat m f).map (!·)
  | .and fs => fs.foldl (fun acc f => (acc.zip (sat m f)).map fun (a, b) => a && b) (m.all true)
  | .or fs => fs.foldl (fun acc f => (acc.zip (sat m f)).map fun (a, b) => a || b) (m.all false)
  | .implies a b => sat m (.or [.not a, b])
  | .stronglyImplies a b => sat m (.and [.ef a, .ag (.implies a b)])
  | .never f => sat m (.ag (.not f))
  | .ex f => let s := sat m f; m.mapI (m.existsSucc s)
  | .ax f => let s := sat m f; m.mapI (m.allSucc s)
  | .ef f => sat m (.eu .tt f)
  | .af f => sat m (.au .tt f)
  | .eg f => let s := sat m f; m.gfp fun z => m.mapI fun i => get s i && m.existsSucc z i
  | .ag f => (sat m (.ef (.not f))).map (!·)
  | .eu a b =>
    let sa := sat m a; let sb := sat m b
    m.lfp fun z => m.mapI fun i => get sb i || (get sa i && m.existsSucc z i)
  | .au a b =>
    let sa := sat m a; let sb := sat m b
    m.lfp fun z => m.mapI fun i => get sb i || (get sa i && m.allSucc z i)
  | .ew a b => sat m (.or [.eu a b, .eg a])
  | .aw a b => (sat m (.eu (.not b) (.and [.not a, .not b]))).map (!·)
  | _ => m.all false

/-- Shortest path from `start` through `allowed` nodes to a `goal` node. -/
def bfs (m : Model) (start : Nat) (allowed goal : Nat → Bool) : Option (List Nat) := Id.run do
  if goal start then return some [start]
  if !allowed start then return none
  let mut parent : Array (Option Nat) := Array.replicate m.size none
  let mut seen : Array Bool := (Array.replicate m.size false).set! start true
  let mut queue : Array Nat := #[start]
  let mut head := 0
  while head < queue.size do
    let i := queue[head]!
    head := head + 1
    for j in m.succ[i]!.toList do
      if !seen[j]! then
        seen := seen.set! j true
        parent := parent.set! j (some i)
        if goal j then
          let mut path := [j]
          let mut cur := j
          for _ in [0:m.size] do
            match parent[cur]! with
            | some p => path := p :: path; cur := p
            | none => break
          return some path
        if allowed j then queue := queue.push j
  return none

/-- A lasso staying inside `region` (which must be closed under some successor). -/
def lasso (m : Model) (start : Nat) (region : Array Bool) : Option (List Nat × Nat) := Id.run do
  if !get region start then return none
  let mut path : Array Nat := #[start]
  let mut cur := start
  for _ in [0:m.size + 1] do
    match (m.succ[cur]?.getD #[]).find? (get region ·) with
    | none => return none
    | some j =>
      match path.findIdx? (· == j) with
      | some k => return some (path.toList, k)
      | none => path := path.push j; cur := j
  return none

end Model

/-! ## Evidence -/

structure Evidence where
  kind : String
  path : List Nat := []
  loopStart : Option Nat := none
  note : String := ""
deriving Inhabited

open Model in
/-- `holds = true`: explain why `f` holds at node `i`; `false`: why it fails. -/
partial def evidence (m : Model) (i : Nat) (holds : Bool) (f : Formula) : Option Evidence :=
  let sat := Model.sat m
  let reach := fun (goal : Formula) (kind : String) =>
    (m.bfs i (fun _ => true) (get (sat goal))).map fun p => { kind, path := p }
  let reachThrough := fun (a b : Formula) (kind : String) =>
    (m.bfs i (get (sat a)) (get (sat b))).map fun p => { kind, path := p }
  let loop := fun (region : Formula) (kind : String) =>
    (m.lasso i (sat (.eg region))).map fun (p, k) => { kind, path := p, loopStart := some k }
  let step := fun (goal : Formula) (kind : String) =>
    ((m.succ[i]?.getD #[]).find? (get (sat goal))).map fun j => { kind, path := [i, j] }
  match holds, f with
  | _, .not g => evidence m i (!holds) g
  | true, .ef g => reach g "witness"
  | true, .ex g => step g "witness"
  | true, .eu a b => reachThrough a b "witness"
  | true, .eg g => loop g "witness"
  | true, .ew a b => if get (sat (.eu a b)) i then reachThrough a b "witness" else loop a "witness"
  | true, .stronglyImplies a _ => reach a "witness"
  | true, .or fs => (fs.find? (fun g => get (sat g) i)).bind (evidence m i true)
  | true, .implies a b => if get (sat b) i then evidence m i true b else evidence m i false a
  | false, .ag g => reach (.not g) "counterexample"
  | false, .never g => reach g "counterexample"
  | false, .ax g => step (.not g) "counterexample"
  | false, .af g => loop (.not g) "counterexample"
  | false, .au a b =>
    match reachThrough (.and [a, .not b]) (.and [.not a, .not b]) "counterexample" with
    | some e => some e
    | none => loop (.and [a, .not b]) "counterexample"
  | false, .aw a b => reachThrough (.and [a, .not b]) (.and [.not a, .not b]) "counterexample"
  | false, .stronglyImplies a b =>
    if !get (sat (.ef a)) i then
      some { kind := "vacuous", path := [i], note := "the antecedent is unreachable, so the claim would hold vacuously; stronglyImplies rejects that" }
    else reach (.and [a, .not b]) "counterexample"
  | false, .and fs => (fs.find? (fun g => !get (sat g) i)).bind (evidence m i false)
  | false, .implies a b => (evidence m i true a).orElse fun _ => evidence m i false b
  | _, _ => none

def nodeJson (m : Model) (i : Nat) : Json :=
  let n := m.nodes[i]!
  Json.mkObj [("state", n.state), ("message", match n.message with | some s => Json.str s | none => Json.null)]

def evidenceJson (m : Model) (e : Evidence) : Json :=
  Json.mkObj <|
    [("kind", Json.str e.kind), ("path", Json.arr (e.path.map (nodeJson m)).toArray)] ++
    (match e.loopStart with | some k => [("loopsBackTo", toJson k)] | none => []) ++
    (if e.note.isEmpty then [] else [("note", Json.str e.note)])

/-! ## Tool results -/

/-- `.error` is LogicInputRejected; `.ok` is a LogicVerdict body. -/
abbrev ToolOutcome := Except String Json

def verdictJson (tool verdict reading : String) (extra : List (String × Json)) : Json :=
  Json.mkObj ([("tool", Json.str tool), ("verdict", Json.str verdict), ("reading", Json.str reading), ("bounds", boundsJson)] ++ extra)

def lints (f : Formula) (sentence : Option String) : List String :=
  let subs := f.subformulas
  let vacuity := if subs.any (fun | .ag (.implies ..) => true | _ => false) then
      ["AG(implies(a, b)) also holds when a never happens. If a is meant to be possible, use stronglyImplies(a, b), which means EF a and AG(a -> b)."]
    else []
  let topImplies := match f with
    | .implies .. => ["A plain implication is checked only at the initial state. Did you mean AG(implies(a, b))?"]
    | _ => []
  let afag := if subs.any (fun | .af (.ag _) => true | _ => false) then
      ["AF AG p: on every path p eventually holds forever (it stabilizes). AG AF p is different: p recurs infinitely often."]
    else []
  let agaf := if subs.any (fun | .ag (.af _) => true | _ => false) then
      ["AG AF p: on every path p keeps coming back (infinitely often). AF AG p is different: p eventually holds forever."]
    else []
  let efag := if subs.any (fun | .ef (.ag _) => true | _ => false) then
      ["EF AG p: some path reaches a point after which p holds on every continuation. If you meant that p always holds, use AG p."]
    else []
  let nextOnTerminal := if subs.any (fun | .ex _ | .ax _ => true | _ => false) then
      ["EX/AX at a terminal state look at the same state again, because terminal states stutter."]
    else []
  let words := match sentence with
    | some s => (s.toLower.splitOn " ").map (fun (w : String) => String.ofList (w.toList.filter Char.isAlphanum))
    | none => []
  let universalWords := ["always", "never", "every", "all", "must", "cannot", "whenever", "only"]
  let existentialWords := ["can", "may", "possible", "possibly", "some", "might", "could"]
  let m := Formula.mode f
  let quantifier :=
    if words.any (universalWords.contains ·) && m == "possibly" then
      ["The sentence sounds universal (always/never/every/must) but the formula is existential (EF/EX/EU/EG). Did you mean AG or AF?"]
    else if words.any (existentialWords.contains ·) && (m == "always" || m == "never") then
      ["The sentence sounds existential (can/may/possible) but the formula is universal. Did you mean EF?"]
    else []
  vacuity ++ topImplies ++ afag ++ agaf ++ efag ++ nextOnTerminal ++ quantifier

def unsupportedIn (f : Formula) : List String :=
  (f.atoms.filterMap fun | .unsupported op => some op | _ => none).eraseDups

def unobservableIn (f : Formula) : List String :=
  (f.atoms.filterMap fun
    | .predicate t => some ("predicate \"" ++ t ++ "\"")
    | .derived n => some ("derived " ++ n)
    | .field m n _ => some ("field " ++ m ++ "." ++ n ++ " (field values are not in the task model; check them with check_trace)")
    | _ => none).eraseDups

def explainFormula (args : Json) : ToolOutcome := do
  let fj ← match (args.getObjVal? "formula").toOption with
    | some j => pure j
    | none => throw "explain_formula needs a formula"
  let f ← parseBounded fj
  let sentence := (args.getObjVal? "sentence").toOption.bind str?
  let unknown ← match (args.getObjVal? "task").toOption with
    | some tj => do let t ← resolveTask tj; pure (unknownAtoms t f)
    | none => pure []
  let neg := f.negate
  return verdictJson "explain_formula" "explained" f.reading
    [ ("formula", f.toJson), ("mode", Formula.mode f)
    , ("negation", Json.mkObj [("formula", neg.toJson), ("reading", neg.reading)])
    , ("typingErrors", Json.arr #[])
    , ("unknownAtoms", Json.arr (unknown.map Json.str).toArray)
    , ("unsupportedOperators", Json.arr ((unsupportedIn f).map Json.str).toArray)
    , ("unobservableAtoms", Json.arr ((unobservableIn f).map Json.str).toArray)
    , ("lints", Json.arr ((lints f sentence).map Json.str).toArray) ]

def checkCtl (args : Json) : ToolOutcome := do
  let tj ← match (args.getObjVal? "task").toOption with
    | some j => pure j
    | none => throw "check_ctl needs a task (canonical id or inline draft)"
  let fj ← match (args.getObjVal? "formula").toOption with
    | some j => pure j
    | none => throw "check_ctl needs a formula"
  let t ← resolveTask tj
  let f ← parseBounded fj
  let unknown := unknownAtoms t f
  if !unknown.isEmpty then
    throw ("formula names atoms the task does not declare: " ++ "; ".intercalate unknown)
  let common : List (String × Json) :=
    [("task", t.id), ("formula", f.toJson), ("mode", Formula.mode f), ("terminalConvention", terminalConvention)]
  let unsupported := unsupportedIn f
  if !unsupported.isEmpty then
    return verdictJson "check_ctl" "unsupported" f.reading <| common ++
      [("unsupportedOperators", Json.arr (unsupported.map Json.str).toArray),
       ("evidence", Json.mkObj [("kind", "none"), ("note", "knowledge, obligation, permission and probability modalities are not evaluated by these tools yet")])]
  let unobservable := unobservableIn f
  if !unobservable.isEmpty then
    return verdictJson "check_ctl" "unknown" f.reading <| common ++
      [("unobservableAtoms", Json.arr (unobservable.map Json.str).toArray),
       ("evidence", Json.mkObj [("kind", "none"), ("note", "the task model cannot decide these atoms; run classify_requirement to restate them over events")])]
  match buildModel t with
  | none =>
    return verdictJson "check_ctl" "resource-limit" f.reading <| common ++
      [("evidence", Json.mkObj [("kind", "none"), ("note", s!"the reachable model exceeds {bounds.maxModelNodes} nodes; nothing was proved")])]
  | some m =>
    let holds := Model.get (Model.sat m f) 0
    let ev := evidence m 0 holds f
    let evJson := match ev with
      | some e => evidenceJson m e
      | none => Json.mkObj [("kind", "exhaustive"), ("note", s!"evaluated over all {m.size} reachable nodes")]
    return verdictJson "check_ctl" (if holds then "proved" else "disproved") f.reading <| common ++
      [ ("reachableNodes", toJson m.size)
      , ("deadlocks", Json.arr (m.deadlocks.map Json.str).toArray)
      , ("evidence", evJson) ]

/-! ## Traces -/

structure Event where
  id : String
  prevIds : List String
  causeIds : List String
  task : String
  src : String
  dst : String
  message : String
deriving Repr, Inhabited

def parseEvent (j : Json) : Except String Event := do
  let g := fun (k : String) => match (j.getObjVal? k).toOption.bind str? with
    | some v => checkString ("event." ++ k) v
    | none => .error s!"each event needs a string {k}"
  let ids := fun (k : String) => match (j.getObjVal? k).toOption with
    | some a => strings a ("event." ++ k) bounds.maxEvents
    | none => .ok []
  return { id := ← g "id", prevIds := ← ids "prevIds", causeIds := ← ids "causeIds"
         , task := ← g "task", src := ← g "src", dst := ← g "dst", message := ← g "message" }

def mermaidName (s : String) : String :=
  String.ofList (s.toList.map fun c => if c.isAlphanum || c == '_' then c else '_')

def mermaidLabel (s : String) : String :=
  String.ofList (s.toList.filter fun c => c != ';' && c != '#' && c != '"' && c != '\n' && c != '`')

def checkTrace (args : Json) : ToolOutcome := do
  let events ← match (args.getObjVal? "events").toOption with
    | some (.arr items) =>
      if items.size > bounds.maxEvents then throw s!"trace has {items.size} events; the bound is {bounds.maxEvents}"
      items.toList.mapM parseEvent
    | _ => throw "check_trace needs an events array"
  let drafts ← match (args.getObjVal? "drafts").toOption with
    | some (.arr items) => items.toList.mapM parseDraft
    | some _ => throw "drafts is an array of draft tasks"
    | none => pure []
  let ev := events.toArray
  let n := ev.size
  let index := fun (id : String) => ev.findIdx? (·.id == id)
  let mut issues : List String := []
  -- identifiers
  for i in [0:n] do
    if (ev.toList.take i).any (·.id == ev[i]!.id) then issues := issues ++ [s!"duplicate id {ev[i]!.id}"]
  -- references
  let mut edges : List (Nat × Nat × String) := []
  for i in [0:n] do
    let e := ev[i]!
    for (kind, refs) in [("prev", e.prevIds), ("cause", e.causeIds)] do
      for r in refs do
        match index r with
        | none => issues := issues ++ [s!"{e.id}: {kind} id {r} does not exist"]
        | some j =>
          edges := edges ++ [(j, i, kind)]
          if j >= i then issues := issues ++ [s!"{e.id}: {kind} {r} does not precede it in the trace"]
  -- cycles (Kahn)
  let mut indeg := Array.replicate n 0
  for (_, b, _) in edges do indeg := indeg.modify b (· + 1)
  let mut ready := (List.range n).filter (indeg[·]! == 0)
  let mut done := 0
  for _ in [0:n + 1] do
    match ready with
    | [] => break
    | i :: rest =>
      ready := rest
      done := done + 1
      for (a, b, _) in edges do
        if a == i then
          indeg := indeg.modify b (· - 1)
          if indeg[b]! == 0 then ready := ready ++ [b]
  let acyclic := done == n
  if !acyclic then issues := issues ++ ["the prev/cause references form a cycle"]
  -- message schemas and task acceptance
  let taskFor : String → Option TaskModel := fun id =>
    match drafts.find? (·.id == id) with
    | some d => some d
    | none => (canonicalTasks.find? (·.id == id)).map ofRequirement
  for e in events do
    match canonicalMessages.find? (·.name == e.message) with
    | some s =>
      if s.src != e.src || s.dst != e.dst then
        issues := issues ++ [s!"{e.id}: {e.message} is declared {s.src} -> {s.dst}, not {e.src} -> {e.dst}"]
    | none =>
      match taskFor e.task with
      | some t =>
        match t.transitions.find? (·.message == e.message) with
        | some tr =>
          if (tr.sender.isSome && tr.sender != some e.src) || (tr.receiver.isSome && tr.receiver != some e.dst) then
            issues := issues ++ [s!"{e.id}: {e.message} is declared {tr.sender.getD "?"} -> {tr.receiver.getD "?"}, not {e.src} -> {e.dst}"]
        | none => pure ()
      | none => pure ()
  let taskIds := (events.map (·.task)).eraseDups
  let mut acceptance : Array Json := #[]
  for tid in taskIds do
    match taskFor tid with
    | none =>
      issues := issues ++ [s!"unknown task {tid}; pass an inline draft in drafts"]
      acceptance := acceptance.push (Json.mkObj [("task", tid), ("accepted", false), ("reason", "unknown task")])
    | some t =>
      let mut cur : List String := [t.initial]
      let mut rejected : Option Json := none
      for e in events.filter (·.task == tid) do
        if rejected.isNone then
          let next := ((t.transitions.filter fun tr => cur.contains tr.src && tr.message == e.message).map (·.dst)).eraseDups
          if next.isEmpty then
            let expected := ((t.transitions.filter fun tr => cur.contains tr.src).map (·.message)).eraseDups
            rejected := some (Json.mkObj [("event", e.id), ("message", e.message),
              ("expected", Json.arr (expected.map Json.str).toArray)])
          else cur := next
      let complete := cur.any (t.terminals.contains ·)
      acceptance := acceptance.push <| Json.mkObj <|
        [("task", Json.str tid), ("accepted", rejected.isNone), ("reachedTerminal", complete),
         ("states", Json.arr (cur.map Json.str).toArray)] ++
        (match rejected with | some r => [("firstRejected", r)] | none => [])
      if let some r := rejected then
        issues := issues ++ [s!"task {tid}: event {(r.getObjValD "event").getStr?.toOption.getD "?"} is not accepted by the task's transitions"]
  -- happens-before and concurrency
  let mut concurrent : Array Json := #[]
  let mut concurrentCount := 0
  if acyclic then
    let mut anc : Array (Array Bool) := Array.replicate n (Array.replicate n false)
    for i in [0:n] do
      let mut row := Array.replicate n false
      for (a, b, _) in edges do
        if b == i && a < i then
          row := row.set! a true
          row := (row.zip anc[a]!).map fun (x, y) => x || y
      anc := anc.set! i row
    for i in [0:n] do
      for j in [i+1:n] do
        if !anc[j]![i]! && !anc[i]![j]! then
          concurrentCount := concurrentCount + 1
          if concurrent.size < bounds.maxConcurrentPairs then
            concurrent := concurrent.push (Json.arr #[ev[i]!.id, ev[j]!.id])
  -- diagrams
  let participants := (events.flatMap fun e => [e.src, e.dst]).eraseDups
  let seqLines := ["sequenceDiagram"] ++
    participants.map (fun p => "    participant " ++ mermaidName p) ++
    events.map (fun e => "    " ++ mermaidName e.src ++ "->>" ++ mermaidName e.dst ++ ": " ++ mermaidLabel (e.id ++ " " ++ e.message))
  let causalLines := ["flowchart TD"] ++
    (List.range n).map (fun i => "    e" ++ toString i ++ "[\"" ++ mermaidLabel (ev[i]!.id ++ ": " ++ ev[i]!.message) ++ "\"]") ++
    edges.map (fun (a, b, kind) => "    e" ++ toString a ++ (if kind == "prev" then " --> " else " -.-> ") ++ "e" ++ toString b)
  let verdict := if issues.isEmpty then "admissible" else "inadmissible"
  return verdictJson "check_trace" verdict
    (s!"{n} events over {taskIds.length} task(s); {concurrentCount} concurrent pair(s)")
    [ ("issues", Json.arr (issues.map Json.str).toArray)
    , ("acceptance", Json.arr acceptance)
    , ("concurrent", Json.arr concurrent), ("concurrentCount", toJson concurrentCount)
    , ("sequenceDiagram", "\n".intercalate seqLines)
    , ("causalGraph", "\n".intercalate causalLines) ]

/-! ## Observability -/

def stopWords : List String :=
  ["the", "a", "an", "is", "are", "be", "of", "to", "in", "on", "and", "or", "that", "it", "its",
   "always", "never", "every", "all", "must", "should", "has", "have", "with", "by", "for", "not", "no"]

def camel (w : String) : String :=
  match w.toList with
  | c :: cs => String.ofList (c.toUpper :: cs)
  | [] => ""

def proposedEventName (text : String) : String :=
  let words := (text.splitOn " ").map (fun w => String.ofList (w.toList.filter Char.isAlphanum))
  let significant := (words.filter fun w => !w.isEmpty && !stopWords.contains w.toLower).take 3
  (String.join (significant.map (camel ·.toLower))) ++ "Observed"

def tokens (text : String) : List String :=
  ((text.splitOn " ").map fun w => String.ofList (w.toList.filter fun c => c.isAlphanum || c == '_')).filter (!·.isEmpty)

def classifyText (task : Option TaskModel) (text : String) : Json :=
  let names := match task with
    | some t => t.messages ++ t.states
    | none => canonicalMessages.map (fun (m : MessageSchema) => m.name)
  let mentioned := (tokens text).filter (names.contains ·) |>.eraseDups
  if !mentioned.isEmpty then
    Json.mkObj [("atom", text), ("class", "derived"),
      ("reason", "the text refers to declared events or states, but a predicate over them is computed, not observed"),
      ("needs", "a reducer declaration over " ++ ", ".intercalate mentioned ++ " (state it in Requirements.lean as a derived predicate), then use {\"derived\": name}")]
  else
    let ev := proposedEventName text
    Json.mkObj [("atom", text), ("class", "implementation-only"),
      ("reason", "no declared message or state reveals this; no event trace can test it"),
      ("advice", "move it to Implementation.lean as an internal invariant, or restate it over an event that exposes it"),
      ("proposedEvent", Json.mkObj [("message", ev), ("from", "the actor that owns this state"), ("to", "an observer that can check it"),
        ("fields", Json.arr #["subject", "holds", "observed_at"])]),
      ("restated", (Formula.ag (.implies (.after ev) (.field ev "holds" "true"))).toJson)]

def classifyAtom (task : Option TaskModel) : Formula → Json
  | .atState s =>
    let ok := task.map (·.states.contains s) |>.getD true
    Json.mkObj [("atom", "at " ++ s), ("class", if ok then "observable" else "unknown name"),
      ("reason", if ok then "a task state reached by delivered messages" else "the task does not declare this state")]
  | .after m =>
    let ok := task.map (·.messages.contains m) |>.getD true
    Json.mkObj [("atom", "after " ++ m), ("class", if ok then "observable" else "unknown name"),
      ("reason", if ok then "a delivered message" else "the task does not send this message")]
  | .terminal => Json.mkObj [("atom", "terminal"), ("class", "observable"), ("reason", "a terminal task state")]
  | .field m n _ => Json.mkObj [("atom", m ++ "." ++ n), ("class", "observable"), ("reason", "a field of a delivered message")]
  | .derived n => Json.mkObj [("atom", "derived " ++ n), ("class", "derived"),
      ("needs", "a declared reducer, policy or knowledge rule named " ++ n ++ " in Requirements.lean")]
  | .predicate t => classifyText task t
  | .unsupported op =>
    let kind := if ["K", "knows", "B", "believes", "C", "common"].contains op then "knowledge derived from the causal past"
      else if ["Pr", "probability"].contains op then "a probability over declared branch weights"
      else "an obligation or permission over a declared normative code"
    Json.mkObj [("atom", op), ("class", "derived"), ("needs", kind ++ "; the knows tool is deferred")]
  | f => Json.mkObj [("atom", f.reading), ("class", "observable")]

def classifyRequirement (args : Json) : ToolOutcome := do
  let task ← match (args.getObjVal? "task").toOption with
    | some tj => some <$> resolveTask tj
    | none => pure none
  let items ← match (args.getObjVal? "formula").toOption, (args.getObjVal? "predicates").toOption with
    | some fj, _ => do
      let f ← parseBounded fj
      pure ((f.atoms.eraseDups).map (classifyAtom task))
    | none, some pj => do
      let texts ← strings pj "predicates" bounds.maxPredicates
      pure (texts.map (classifyText task))
    | none, none => throw "classify_requirement needs a formula or a predicates array"
  let classes := items.map fun j => (j.getObjValD "class").getStr?.toOption.getD ""
  let summary :=
    if classes.all (· == "observable") then "every atom is observable; check_ctl or check_trace can decide it"
    else if classes.any (· == "implementation-only") then "some atoms are implementation-only; restate them over proposed events before the requirements gate"
    else "some atoms are derived; declare their reducers before the requirements gate"
  return verdictJson "classify_requirement" "classified" summary [("atoms", Json.arr items.toArray)]

def knows (_ : Json) : ToolOutcome :=
  return verdictJson "knows" "unsupported"
    "derivable knowledge from the causal past"
    [("evidence", Json.mkObj [("kind", "none"),
      ("note", "selfhost.mcp.logic.knows is accepted but deferred to a later revision")])]

/-! ## Reference -/

def reference : String := String.intercalate "\n"
  [ "# LeanFM logic reference (MCP)"
  , ""
  , "Formulas, tasks and traces are JSON data. They are parsed into closed types and never executed."
  , ""
  , "## Formula grammar"
  , ""
  , "| JSON | Meaning |"
  , "|---|---|"
  , "| `true`, `false` | constants |"
  , "| `{\"at\": \"s\"}` | the task is in state s (observable) |"
  , "| `{\"after\": \"M\"}` | message M was just delivered (observable) |"
  , "| `\"terminal\"` | the task has ended (observable) |"
  , "| `{\"field\": {\"message\": \"M\", \"name\": \"f\", \"value\": \"v\"}}` | last message M had f = v (observable in traces; not in task models) |"
  , "| `{\"derived\": \"name\"}` | a declared reducer, policy or knowledge predicate |"
  , "| `{\"predicate\": \"text\"}` | free text: never observable; classify it first |"
  , "| `{\"not\": f}`, `{\"and\": [..]}`, `{\"or\": [..]}`, `{\"implies\": [a, b]}` | Boolean |"
  , "| `{\"stronglyImplies\": [a, b]}` | EF a and AG(a -> b): non-vacuous always |"
  , "| `{\"never\": f}` | AG not f |"
  , "| `{\"AG\": f}` `{\"AF\": f}` `{\"EG\": f}` `{\"EF\": f}` `{\"AX\": f}` `{\"EX\": f}` | CTL unary |"
  , "| `{\"AU\": [a, b]}` `{\"EU\": [a, b]}` | a until b, and b happens |"
  , "| `{\"AW\": [a, b]}` `{\"EW\": [a, b]}` | a unless b, b need not happen |"
  , ""
  , "Bare F, G, X, U and W are typing errors: quantify them with A (every path) or E (some path)."
  , "K, O, P, B and Pr are parsed and reported as unsupported."
  , ""
  , "## Requirement modes"
  , ""
  , "always = AG p; never = AG not p; eventually = AF p; possibly = EF p."
  , "AG(implies(a, b)) is vacuous when a is unreachable; prefer stronglyImplies(a, b)."
  , ""
  , "## Tasks"
  , ""
  , "A task is a canonical id string, or a draft: `{\"id\", \"states\": [..], \"initial\", \"terminals\": [..], \"transitions\": [{\"src\", \"dst\", \"message\", \"from\"?, \"to\"?}]}`."
  , ""
  , "## Terminal convention"
  , ""
  , terminalConvention
  , ""
  , "## Verdicts"
  , ""
  , "- proved: holds on every reachable node; existential claims carry a witness path."
  , "- disproved: fails; universal claims carry a counterexample path (a lasso with loopsBackTo for AF and EG)."
  , "- unknown: a derived, predicate or field atom cannot be decided from the task model."
  , "- unsupported: a modality outside the implemented logic."
  , "- resource-limit: the model exceeded the node bound; nothing was proved."
  , "- Malformed or oversized input is rejected with a reason (isError)."
  , ""
  , "## Traces"
  , ""
  , "check_trace takes `{\"events\": [{\"id\", \"prevIds\", \"causeIds\", \"task\", \"src\", \"dst\", \"message\"}], \"drafts\"?: [task]}`."
  , "prevIds orders events within an actor or task; causeIds names the events that caused it (for example the HTTP request a response answers)."
  , "References must point to earlier events. Events unordered by the transitive closure of both are concurrent."
  , ""
  , "## Observability"
  , ""
  , "observable: decided by the event trace. derived: computed from it by a declared reducer. implementation-only: no event reveals it."
  , "classify_requirement proposes an event for each implementation-only atom so it can be restated and tested."
  , ""
  , "## Example"
  , ""
  , "```json"
  , "{\"task\": \"mcp_logic_consult\", \"formula\": {\"AG\": {\"implies\": [{\"after\": \"LogicConsultRequested\"}, {\"AF\": \"terminal\"}]}}}"
  , "```" ]

/-! ## Dispatch -/

def toolNames : List String := ["explain_formula", "check_ctl", "check_trace", "classify_requirement", "knows"]

def run (name : String) (args : Json) : Option ToolOutcome :=
  if args.compress.length > bounds.maxArgumentBytes then
    some (.error s!"arguments exceed {bounds.maxArgumentBytes} bytes")
  else match name with
    | "explain_formula" => some (explainFormula args)
    | "check_ctl" => some (checkCtl args)
    | "check_trace" => some (checkTrace args)
    | "classify_requirement" => some (classifyRequirement args)
    | "knows" => some (knows args)
    | _ => none

end LeanFM.Logic
