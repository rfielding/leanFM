import Lean.Data.Json
import LeanFM.Artifacts
import LeanFM.LLMGenerated.SelfHosting
import LeanFM.Session.Knowledge
import LeanFM.Session.Attack
import LeanFM.Session.Reassembly

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
  /-- `actor` can derive `term` from the messages it has seen on the path to this state -/
  | knows (actor : String) (term : LeanFM.Session.Knowledge.Msg)
  /-- some role has made this claim, such as `commit(B, A)`, on the path to this state -/
  | claimed (claim : String)
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
  | knows a t => Json.mkObj [("knows", Json.mkObj [("actor", Json.str a), ("term", LeanFM.Session.Attack.termJson t)])]
  | claimed c => Json.mkObj [("claimed", Json.str c)]
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
  | tt | ff | atState _ | after _ | terminal | field .. | predicate _ | derived _ | unsupported _ | knows .. | claimed _ => true
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
  | knows a t => a ++ " can derive " ++ t.render
  | claimed c => "the claim " ++ c ++ " has been made"
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

/-! ### Symbolic terms (decision logic-knows) -/

section Terms
open LeanFM.Session.Knowledge

/-- A term from JSON: one key per object, within the formula bounds. -/
partial def parseTerm (depth : Nat) (j : Json) : Except String Msg := do
  if depth > bounds.maxDepth then throw s!"a term is nested deeper than {bounds.maxDepth}"
  match j with
  | .obj kvs =>
    match kvs.toList with
    | [(k, v)] =>
      let name := fun (what : String) => match str? v with
        | some n => checkString what n
        | none => .error s!"{what} names are strings"
      match k with
      | "atom" => return .atom (← name "atom")
      | "key" => return .key (← name "key")
      | "pk" => return .pk (← name "pk")
      | "sk" => return .sk (← name "sk")
      | "hash" => return .hash (← parseTerm (depth + 1) v)
      | "pair" => match v with
        | .arr #[a, b] => return .pair (← parseTerm (depth + 1) a) (← parseTerm (depth + 1) b)
        | _ => throw "pair takes exactly two terms"
      | "tuple" => match v with
        | .arr items =>
          if items.size < 2 then throw "tuple takes two or more terms"
          let ts ← items.toList.mapM (parseTerm (depth + 1))
          return (ts.dropLast.foldr (fun t acc => Msg.pair t acc) ts.getLast!)
        | _ => throw "tuple takes an array of terms"
      | "enc" =>
        let key ← match (v.getObjVal? "key").toOption with
          | some kj => parseTerm (depth + 1) kj
          | none => throw "enc needs a key"
        let body ← match (v.getObjVal? "body").toOption with
          | some bj => parseTerm (depth + 1) bj
          | none => throw "enc needs a body"
        return .enc key body
      | other => throw s!"unknown term constructor {other.take 40}; use atom, key, pk, sk, pair, tuple, enc or hash"
    | _ => throw "a term is an object with exactly one key"
  | _ => throw "a term is an object such as {\"atom\": \"na\"}"

def boundedTerm (j : Json) : Except String Msg := do
  let t ← parseTerm 0 j
  if t.size > bounds.maxFormulaNodes then throw s!"a term has {t.size} nodes; the bound is {bounds.maxFormulaNodes}"
  return t

end Terms

def pathOperatorHint (op : String) : Option String :=
  match op with
  | "F" | "eventually" | "<>" => some "F is a path operator; quantify it: AF (on every path) or EF (on some path)"
  | "G" | "always" | "[]" => some "G is a path operator; quantify it: AG (on every path) or EG (on some path)"
  | "X" | "next" => some "X is a path operator; quantify it: AX (every path) or EX (some path)"
  | "U" | "until" => some "U is a path operator; quantify it: AU or EU (or AW/EW when the right side need not happen)"
  | "W" | "unless" => some "W is a path operator; quantify it: AW or EW"
  | _ => none

def unsupportedOperators : List String :=
  ["K", "O", "obliged", "obligatory", "P", "permitted", "B", "believes", "Pr", "probability", "C", "common"]

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
      | "claimed" => atomStr .claimed
      | "knows" =>
        let actor ← match (arg.getObjVal? "actor").toOption.bind str? with
          | some a => checkString "knows.actor" a
          | none => throw "knows needs a string actor"
        let term ← match (arg.getObjVal? "term").toOption with
          | some t => boundedTerm t
          | none => throw "knows needs a term"
        return .knows actor term
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
  /-- the message as a symbolic term, for knowledge atoms -/
  term : Option LeanFM.Session.Knowledge.Msg := none
  /-- a claim this transition makes, for `claimed` atoms -/
  claim : Option String := none
deriving Repr, Inhabited

structure TaskModel where
  id : String
  states : List String
  initial : String
  terminals : List String
  transitions : List Transition
  canonical : Bool
  /-- actors whose knowledge the model tracks: name, initial terms, and whether they see every
  channel (a network attacker) rather than only transitions they send or receive -/
  knowers : List (String × List LeanFM.Session.Knowledge.Msg × Bool) := []
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
        let term ← match (t.getObjVal? "term").toOption with
          | some tj => some <$> boundedTerm tj
          | none => pure none
        let claim ← match opt "claim" with
          | some c => some <$> checkString "transition.claim" c
          | none => pure none
        let tr : Transition := { src := ← g "src", dst := ← g "dst", message := ← g "message"
                               , sender := opt "from", receiver := opt "to", term, claim }
        return tr
    | some _ => throw "transitions is an array"
    | none => pure []
  let unknown := ([initial] ++ terminals ++ transitions.flatMap (fun t => [t.src, t.dst])).filter (!states.contains ·)
  if let some s := unknown.head? then throw s!"draft refers to undeclared state \"{s}\""
  let knowers ← match field "knowledge" with
    | some (.obj kvs) =>
      if kvs.size > bounds.maxPredicates then throw s!"knowledge declares {kvs.size} actors; the bound is {bounds.maxPredicates}"
      kvs.toList.mapM fun (actor, decl) => do
        let actor ← checkString "knowledge actor" actor
        let initial ← match (decl.getObjVal? "initial").toOption with
          | some (.arr items) =>
            if items.size > bounds.maxPredicates then throw s!"{actor}'s initial knowledge has {items.size} terms; the bound is {bounds.maxPredicates}"
            items.toList.mapM boundedTerm
          | some _ => throw "initial is an array of terms"
          | none => pure []
        let seesAll := match (decl.getObjVal? "seesAll").toOption with | some (.bool b) => b | _ => false
        return (actor, initial, seesAll)
    | some _ => throw "knowledge maps each actor to {initial, seesAll}"
    | none => pure []
  let id := ((field "id").bind str?).getD "draft"
  return { id, states, initial, terminals, transitions, canonical := false, knowers }

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
    | .claimed c => if t.transitions.any (·.claim == some c) then none
        else some ("no transition of task " ++ t.id ++ " makes the claim " ++ c)
    | .knows a _ => if t.knowers.any (·.1 == a) then none
        else some ("actor " ++ a ++ " has no declared knowledge in task " ++ t.id ++ "; add it to the draft's knowledge field")
    | _ => none).eraseDups

/-! ## Kripke structure -/

structure Node where
  state : String
  message : Option String
  /-- each declared knower's knowledge, taken apart and kept in one order, so that nodes reached
  with different knowledge stay different -/
  knowledge : List (List LeanFM.Session.Knowledge.Msg) := []
  /-- the claims made on the path here, in one order -/
  claims : List String := []
deriving Repr, BEq, Inhabited

def canonTerms (K : List LeanFM.Session.Knowledge.Msg) : List LeanFM.Session.Knowledge.Msg :=
  K.mergeSort (fun x y => decide (x.render ≤ y.render))

/-- What each knower holds after a transition: a term reaches an actor that sends or receives it,
or that sees every channel. -/
def TaskModel.learnOn (t : TaskModel) (tr : Transition) (ks : List (List LeanFM.Session.Knowledge.Msg)) :
    List (List LeanFM.Session.Knowledge.Msg) :=
  (t.knowers.zip ks).map fun ((actor, _, seesAll), K) =>
    match tr.term with
    | some m => if seesAll || tr.sender == some actor || tr.receiver == some actor
        then canonTerms (LeanFM.Session.Knowledge.learn K m) else K
    | none => K

structure Model where
  task : TaskModel
  nodes : Array Node
  succ : Array (Array Nat)
  deadlocks : List String
deriving Inhabited

def nodeIndex (nodes : Array Node) (n : Node) : Option Nat := nodes.findIdx? (· == n)

/-- Breadth-first construction; `none` when the node bound is exceeded. -/
def buildModel (t : TaskModel) : Option Model := Id.run do
  let start := t.knowers.map fun (_, init, _) => canonTerms (LeanFM.Session.Knowledge.analz init)
  let mut nodes : Array Node := #[{ state := t.initial, message := none, knowledge := start }]
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
        let claims := match tr.claim with
          | some c => if n.claims.contains c then n.claims else (c :: n.claims).mergeSort (· ≤ ·)
          | none => n.claims
        let m : Node := { state := tr.dst, message := some tr.message, knowledge := t.learnOn tr n.knowledge, claims }
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
  | .claimed c => m.nodes.map (·.claims.contains c)
  | .knows a v =>
    match m.task.knowers.findIdx? (·.1 == a) with
    | some k => m.nodes.map fun n => LeanFM.Session.Knowledge.knows (n.knowledge[k]?.getD []) v
    | none => m.all false
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
  let base := [("state", Json.str n.state), ("message", match n.message with | some s => Json.str s | none => Json.null)]
  let held := (m.task.knowers.zip n.knowledge).map fun ((actor, _, _), K) =>
    (actor, Json.arr (K.map (Json.str ·.render)).toArray)
  let base := if held.isEmpty then base else base ++ [("holds", Json.mkObj held)]
  Json.mkObj (if n.claims.isEmpty then base else base ++ [("claims", Json.arr (n.claims.map Json.str).toArray)])

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
  /-- Optional timestamp (ms); when present, no prev/cause edge may run backwards in time. -/
  timeAt : Option Nat := none
deriving Repr, Inhabited

def parseEvent (j : Json) : Except String Event := do
  let g := fun (k : String) => match (j.getObjVal? k).toOption.bind str? with
    | some v => checkString ("event." ++ k) v
    | none => .error s!"each event needs a string {k}"
  let ids := fun (k : String) => match (j.getObjVal? k).toOption with
    | some a => strings a ("event." ++ k) bounds.maxEvents
    | none => .ok []
  return { id := ← g "id", prevIds := ← ids "prevIds", causeIds := ← ids "causeIds"
         , task := ← g "task", src := ← g "src", dst := ← g "dst", message := ← g "message"
         , timeAt := (j.getObjVal? "timeAt").toOption.bind (·.getNat?.toOption) }

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
          match ev[j]!.timeAt, e.timeAt with
          | some before, some after =>
            if before > after then issues := issues ++ [s!"{e.id}: {kind} {r} has a later timeAt ({before} > {after})"]
          | _, _ => pure ()
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
  | .claimed c =>
    let ok := task.map (·.transitions.any (·.claim == some c)) |>.getD true
    Json.mkObj [("atom", "claimed " ++ c), ("class", if ok then "observable" else "unknown name"),
      ("reason", if ok then "a claim made by a transition on the path" else "no transition of the task makes this claim")]
  | .knows a v =>
    let declared := task.map (·.knowers.any (·.1 == a)) |>.getD false
    Json.mkObj [("atom", a ++ " knows " ++ v.render), ("class", if declared then "observable" else "derived"),
      ("reason", if declared then "computed from the terms delivered to " ++ a ++ " on the path, by the declared derivation rules"
        else "needs terms on the task's transitions and " ++ a ++ "'s initial knowledge in the draft's knowledge field")]
  | .unsupported op =>
    let kind := if ["K", "B", "believes", "C", "common"].contains op then "knowledge over indistinguishable histories"
      else if ["Pr", "probability"].contains op then "a probability over declared branch weights"
      else "an obligation or permission over a declared normative code"
    let tool := if ["K", "B", "believes", "C", "common"].contains op then "; for what an actor can derive, use the knows atom or the knows tool" else ""
    Json.mkObj [("atom", op), ("class", "derived"), ("needs", kind ++ tool)]
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

/-! ## knows (decision logic-knows)

What an actor can derive from the messages it has seen by an event. Terms are symbolic
(`LeanFM.Session.Knowledge.Msg`); the decision is `Knowledge.synth` over the pieces the actor
holds, proved sound by `Knowledge.knows_sound`. Every held piece carries the event that first gave
it, so an answer says not only that a value leaked but where. -/

section Knows
open LeanFM.Session.Knowledge

structure KEvent where
  id : String
  prevIds : List String
  causeIds : List String
  src : String
  dst : String
  term : Msg

def parseKEvent (j : Json) : Except String KEvent := do
  let g := fun (k : String) => match (j.getObjVal? k).toOption.bind str? with
    | some v => checkString ("event." ++ k) v
    | none => .error s!"each event needs a string {k}"
  let ids := fun (k : String) => match (j.getObjVal? k).toOption with
    | some a => strings a ("event." ++ k) bounds.maxEvents
    | none => .ok []
  let term ← match (j.getObjVal? "term").toOption with
    | some t => boundedTerm t
    | none => throw "each event needs a term"
  return { id := ← g "id", prevIds := ← ids "prevIds", causeIds := ← ids "causeIds",
           src := ← g "src", dst := ← g "dst", term }

/-- A piece the actor holds, the event that first gave it, and how it was obtained. -/
structure Held where
  term : Msg
  source : String
  how : String

def Held.json (h : Held) : Json :=
  Json.mkObj [("term", Json.str h.term.render), ("from", Json.str h.source), ("how", Json.str h.how)]

/-- The parts one held piece gives up, with how. -/
def partsWhy (S : List Msg) (h : Held) : List Held :=
  match h.term with
  | .pair a b =>
    [⟨a, h.source, s!"first part of {h.term.render}"⟩, ⟨b, h.source, s!"second part of {h.term.render}"⟩]
  | .enc k b =>
    if synth S k.inverse then [⟨b, h.source, s!"opened {h.term.render} with {k.inverse.render}"⟩] else []
  | _ => []

/-- Take everything apart until a round adds nothing. Each round adds at least one subterm of a
starting term, so their total size bounds the rounds. -/
def analyseHeld (start : List Held) : List Held := Id.run do
  let mut held : List Held := []
  for h in start do
    unless held.any (·.term == h.term) do held := held ++ [h]
  let fuel := start.foldl (fun n h => n + h.term.size) 1
  for _ in [0:fuel] do
    let S := held.map (·.term)
    let mut added := false
    for h in held do
      for p in partsWhy S h do
        unless held.any (·.term == p.term) do
          held := held ++ [p]; added := true
    if !added then break
  return held

/-- Why `v` can be built from the held pieces, as a tree; `none` when it cannot. Mirrors `synth`. -/
partial def derivation (held : List Held) : Msg → Option Json
  | v =>
    match held.find? (·.term == v) with
    | some h => some (Json.mkObj [("term", Json.str v.render), ("held", Json.str h.source), ("how", Json.str h.how)])
    | none =>
      let node := fun (op : String) (subs : List (Option Json)) =>
        if subs.all Option.isSome then
          some (Json.mkObj [("term", Json.str v.render), ("built", Json.str op),
            ("from", Json.arr (subs.filterMap id).toArray)])
        else none
      match v with
      | .pair a b => node "pair" [derivation held a, derivation held b]
      | .enc k b => node "encrypt" [derivation held k, derivation held b]
      | .hash b => node "hash" [derivation held b]
      | _ => none

end Knows

def knows (args : Json) : ToolOutcome := do
  let field := fun (k : String) => (args.getObjVal? k).toOption
  let events ← match field "events" with
    | some (.arr items) =>
      if items.size > bounds.maxEvents then throw s!"trace has {items.size} events; the bound is {bounds.maxEvents}"
      items.toList.mapM parseKEvent
    | _ => throw "knows needs an events array"
  let actor ← match (field "actor").bind str? with
    | some a => checkString "actor" a
    | none => throw "knows needs a string actor"
  let atId ← match (field "at").bind str? with
    | some a => checkString "at" a
    | none => throw "knows needs the id of the event to ask at"
  let initial ← match field "initial" with
    | some (.arr items) =>
      if items.size > bounds.maxPredicates then throw s!"initial has {items.size} terms; the bound is {bounds.maxPredicates}"
      items.toList.mapM boundedTerm
    | some _ => throw "initial is an array of terms"
    | none => pure []
  let query ← match field "query" with
    | some q => some <$> boundedTerm q
    | none => pure none
  let seesAll := match field "seesAll" with | some (.bool b) => b | _ => false
  -- ids are unique, references resolve, the asked-at event exists
  let ids := events.map (·.id)
  if ids.eraseDups.length != ids.length then throw "event ids must be unique"
  for e in events do
    for r in e.prevIds ++ e.causeIds do
      unless ids.contains r do throw s!"event {e.id} refers to unknown event {r}"
  unless ids.contains atId do throw s!"no event has id {atId}"
  -- the causal past of the asked-at event: everything reachable backwards through prev and cause
  let past := Id.run do
    let mut seen : List String := [atId]
    let mut frontier : List String := [atId]
    for _ in [0:events.length + 1] do
      let next := frontier.flatMap fun i =>
        match events.find? (·.id == i) with
        | some e => (e.prevIds ++ e.causeIds).filter (fun r => !seen.contains r)
        | none => []
      if next.isEmpty then break
      seen := seen ++ next.eraseDups
      frontier := next.eraseDups
    return seen
  let visible := events.filter fun e => past.contains e.id && (seesAll || e.src == actor || e.dst == actor)
  let start := initial.map (fun t => (⟨t, "initial", "known at the start"⟩ : Held)) ++
    visible.map (fun e => (⟨e.term, e.id, s!"delivered in {e.id} ({e.src} to {e.dst})"⟩ : Held))
  let held := analyseHeld start
  let common : List (String × Json) :=
    [ ("actor", Json.str actor), ("at", Json.str atId)
    , ("causalPast", Json.arr ((events.filter (past.contains ·.id)).map (Json.str ·.id)).toArray)
    , ("visible", Json.arr (visible.map (Json.str ·.id)).toArray)
    , ("holds", Json.arr (held.map Held.json).toArray) ]
  match query with
  | none =>
    return verdictJson "knows" "derived" s!"what {actor} holds at {atId}" <| common ++
      [("evidence", Json.mkObj [("kind", "analysis"),
        ("note", s!"{held.length} pieces from {visible.length} visible events and {initial.length} initial terms, taken apart until nothing new appeared")])]
  | some v =>
    let reading := fun (yes : Bool) => s!"{actor} {if yes then "can" else "cannot"} derive {v.render} at {atId}"
    match derivation held v with
    | some tree =>
      return verdictJson "knows" "proved" (reading true) <| common ++
        [("query", Json.str v.render), ("evidence", Json.mkObj [("kind", "derivation"), ("derivation", tree)])]
    | none =>
      return verdictJson "knows" "disproved" (reading false) <| common ++
        [("query", Json.str v.render), ("evidence", Json.mkObj [("kind", "exhaustive"),
          ("note", s!"no derivation from the {held.length} pieces held once analysis reached its fixpoint")])]

/-! ## check_protocol (decision logic-protocol)

A security protocol declared as data: honest roles as scripts over message patterns, an attacker
who is the network, and one formula. The state space is generated by `LeanFM.Session.Attack` and
decided by `check_ctl`, so the answer has the same verdicts and evidence, plus the messages that
crossed the wire on the returned path. -/

section ProtocolTool
open LeanFM.Session.Knowledge LeanFM.Session.Attack

/-- A pattern: a term, `{"var": x}`, or a constructor over patterns. `pk` and `sk` take a name or a
pattern for one. -/
partial def parsePat (depth : Nat) (j : Json) : Except String Pat := do
  if depth > bounds.maxDepth then throw s!"a pattern is nested deeper than {bounds.maxDepth}"
  let sub := parsePat (depth + 1)
  match j with
  | .obj kvs =>
    match kvs.toList with
    | [("var", v)] => match str? v with
      | some x => return .var (← checkString "var" x)
      | none => throw "var takes a variable name"
    | [("pk", v)] => match str? v with
      | some n => return .lit (.pk (← checkString "pk" n))
      | none => return .pk (← sub v)
    | [("sk", v)] => match str? v with
      | some n => return .lit (.sk (← checkString "sk" n))
      | none => return .sk (← sub v)
    | [("pair", v)] => match v with
      | .arr #[a, b] => return .pair (← sub a) (← sub b)
      | _ => throw "pair takes exactly two patterns"
    | [("tuple", v)] => match v with
      | .arr items =>
        if items.size < 2 then throw "tuple takes two or more patterns"
        return Pat.tuple (← items.toList.mapM sub)
      | _ => throw "tuple takes an array of patterns"
    | [("enc", v)] =>
      let key ← match (v.getObjVal? "key").toOption with | some k => sub k | none => throw "enc needs a key"
      let body ← match (v.getObjVal? "body").toOption with | some b => sub b | none => throw "enc needs a body"
      return .enc key body
    | [("hash", v)] => return .hash (← sub v)
    | _ => return .lit (← parseTerm depth j)
  | _ => throw "a pattern is an object such as {\"var\": \"x\"} or {\"atom\": \"na\"}"

def patNodes : Pat → Nat
  | .pair a b | .enc a b => 1 + patNodes a + patNodes b
  | .hash b | .pk b | .sk b => 1 + patNodes b
  | .lit m => m.size
  | .var _ => 1

def boundedPat (j : Json) : Except String Pat := do
  let p ← parsePat 0 j
  if patNodes p > bounds.maxFormulaNodes then throw s!"a pattern has {patNodes p} nodes; the bound is {bounds.maxFormulaNodes}"
  return p

def maxRoles : Nat := 8
/-- sessions of one role; every session is a thread, and all threads together stay within `maxRoles` -/
def maxSessions : Nat := 4
def maxSteps : Nat := 32

def parseStep (role : String) (i : Nat) (j : Json) : Except String Step := do
  let here := s!"{role}, step {i + 1}"
  match j with
  | .obj kvs =>
    match kvs.toList with
    | [("choose", v)] =>
      let x ← match (v.getObjVal? "var").toOption.bind str? with
        | some x => checkString "choose.var" x
        | none => throw s!"{here}: choose needs a var"
      let values ← match (v.getObjVal? "values").toOption with
        | some (.arr items) =>
          if items.isEmpty || items.size > bounds.maxPredicates then throw s!"{here}: choose takes 1 to {bounds.maxPredicates} values"
          items.toList.mapM boundedTerm
        | _ => throw s!"{here}: choose needs an array of values"
      return .choose x values
    | [("send", v)] =>
      let to ← match (v.getObjVal? "to").toOption with | some t => boundedPat t | none => throw s!"{here}: send needs to"
      let msg ← match (v.getObjVal? "message").toOption with | some m => boundedPat m | none => throw s!"{here}: send needs a message"
      return .send to msg
    | [("recv", v)] => return .recv (← boundedPat v)
    | [("claim", v)] =>
      let name ← match (v.getObjVal? "name").toOption.bind str? with
        | some n => checkString "claim.name" n
        | none => throw s!"{here}: claim needs a name"
      let args ← match (v.getObjVal? "args").toOption with
        | some (.arr items) =>
          if items.size > bounds.maxPredicates then throw s!"{here}: too many claim arguments"
          items.toList.mapM boundedPat
        | none => pure []
        | _ => throw s!"{here}: claim args is an array of patterns"
      return .claim name args
    | [("fresh", v)] => match v with
      | .str x =>
        let x ← checkString "fresh" x
        if x.contains '#' then throw s!"{here}: a fresh variable's name may not contain #"
        return .fresh x
      | _ => throw s!"{here}: fresh takes a variable name"
    | _ => throw s!"{here}: a step is one of choose, fresh, send, recv or claim"
  | _ => throw s!"{here}: a step is an object"

/-- A send or a claim may use only variables an earlier choose, fresh or recv of the same role bound. -/
def checkBindings (r : Role) : Except String Unit := do
  let mut bound : List String := []
  for (st, i) in r.steps.zipIdx do
    match st with
    | .choose x _ | .fresh x => bound := x :: bound
    | .recv p => bound := p.vars ++ bound
    | .send to p =>
      for x in to.vars ++ p.vars do
        unless bound.contains x do throw s!"{r.name}, step {i + 1}: sends {x} before anything binds it"
    | .claim _ args =>
      for x in args.flatMap Pat.vars do
        unless bound.contains x do throw s!"{r.name}, step {i + 1}: claims with {x} before anything binds it"

def parseProtocol (args : Json) : Except String Protocol := do
  let field := fun (k : String) => (args.getObjVal? k).toOption
  let roles ← match field "roles" with
    | some (.arr items) =>
      if items.isEmpty || items.size > maxRoles then throw s!"check_protocol takes 1 to {maxRoles} roles"
      items.toList.mapM fun rj => do
        let name ← match (rj.getObjVal? "name").toOption.bind str? with
          | some n => checkString "role.name" n
          | none => throw "each role needs a name"
        let steps ← match (rj.getObjVal? "steps").toOption with
          | some (.arr ss) =>
            if ss.size > maxSteps then throw s!"{name} has {ss.size} steps; the bound is {maxSteps}"
            ss.toList.zipIdx.mapM fun (sj, i) => parseStep name i sj
          | _ => throw s!"{name} needs an array of steps"
        if name.contains '#' then throw s!"role {name}: a role's name may not contain #; later sessions are named {name}#2, …"
        let sessions ← match (rj.getObjVal? "sessions").toOption with
          | none => pure 1
          | some j => match j.getNat? with
            | .ok n => if n < 1 || n > maxSessions then throw s!"{name}: sessions is 1 to {maxSessions}" else pure n
            | .error _ => throw s!"{name}: sessions is a whole number"
        let r : Role := { name, steps }
        checkBindings r
        return (r, sessions)
    | _ => throw "check_protocol needs an array of roles"
  let declaredNames := roles.map (·.1.name)
  if declaredNames.eraseDups.length != declaredNames.length then throw "role names must be unique"
  let freshVars := roles.flatMap (·.1.freshVars)
  if freshVars.eraseDups.length != freshVars.length then
    throw "each fresh variable is made by one step of one role, so its values in different sessions stay distinct"
  let threadCount := (roles.map (·.2)).foldl (· + ·) 0
  if threadCount > maxRoles then throw s!"the roles' sessions add up to {threadCount} threads; the bound is {maxRoles}"
  let roles := roles.flatMap fun (r, n) => r.sessions n
  let names := roles.map (·.name)
  let (attacker, attackerKnows) ← match field "attacker" with
    | some aj => do
      let n ← match (aj.getObjVal? "name").toOption.bind str? with
        | some n => checkString "attacker.name" n
        | none => throw "the attacker needs a name"
      if names.contains n then throw "the attacker is not one of the honest roles"
      let ks ← match (aj.getObjVal? "knows").toOption with
        | some (.arr items) =>
          if items.size > bounds.maxPredicates then throw s!"the attacker's initial knowledge has {items.size} terms; the bound is {bounds.maxPredicates}"
          items.toList.mapM boundedTerm
        | none => pure []
        | _ => throw "attacker.knows is an array of terms"
      pure (n, ks)
    | none => throw "check_protocol needs an attacker {name, knows}"
  let terms := fun (what : String) (j : Json) => match j with
    | .arr items =>
      if items.size > bounds.maxPredicates then .error s!"{what} has {items.size} values; the bound is {bounds.maxPredicates}"
      else items.toList.mapM boundedTerm
    | _ => .error s!"{what} is an array of terms"
  let domain ← match field "domain" with | some j => terms "domain" j | none => pure []
  let domains ← match field "domains" with
    | some (.obj kvs) => kvs.toList.mapM fun (x, j) => do return (x, ← terms s!"domains.{x}" j)
    | some _ => throw "domains maps variable names to arrays of terms"
    | none => pure []
  for (x, v) in freshValues roles do
    if LeanFM.Session.Knowledge.knows attackerKnows v then
      throw s!"fresh {x} makes {v.render}, which the attacker already knows; a fresh value is new to everyone"
  let domain := coverFresh roles domain
  let domains := domains.map fun (x, vs) => (x, coverFresh roles vs)
  let defender ← match field "defender" with
    | none => pure none
    | some dj => do
      let n ← match (dj.getObjVal? "name").toOption.bind str? with
        | some n => checkString "defender.name" n
        | none => throw "the defender needs a name"
      if declaredNames.contains n || n == attacker then throw "the defender is neither an honest role nor the attacker"
      let protects ← match (dj.getObjVal? "protects").toOption with
        | some (.arr items) =>
          if items.isEmpty then throw "defender.protects names at least one role"
          items.toList.mapM fun j => match str? j with
            | some r => if declaredNames.contains r then pure r else throw s!"the defender protects {r}, which is not a declared role"
            | none => throw "defender.protects is an array of role names"
        | _ => throw "the defender needs protects: an array of role names"
      let items := fun (k : String) => match (dj.getObjVal? k).toOption with
        | none => pure []
        | some (.arr xs) =>
          if xs.size > bounds.maxPredicates then .error s!"defender.{k} has {xs.size} entries; the bound is {bounds.maxPredicates}"
          else pure xs.toList
        | some _ => .error s!"defender.{k} is an array"
      let knows ← (← items "knows").mapM boundedTerm
      let drop ← (← items "drop").mapM boundedPat
      let rewrite ← (← items "rewrite").mapM fun rj => do
        let pat ← match (rj.getObjVal? "match").toOption with | some j => boundedPat j | none => throw "a rewrite needs match"
        let replace ← match (rj.getObjVal? "replace").toOption with | some j => boundedPat j | none => throw "a rewrite needs replace"
        for x in replace.vars do
          unless pat.vars.contains x do throw s!"a rewrite's replacement uses {x}, which its match does not bind"
        return ({ pat, replace } : Rewrite)
      pure (some ({ name := n, protects, knows, drop, rewrite } : Inline))
  return { attacker, attackerKnows, domain, domains, roles, flags := [], defender }

end ProtocolTool

/-- Ask `check_ctl` a formula over a generated protocol model. -/
def _root_.LeanFM.Session.Attack.Protocol.check (p : LeanFM.Session.Attack.Protocol)
    (m : LeanFM.Session.Attack.Model) (id : String) (formula : Json) : Json :=
  match checkCtl (Json.mkObj [("task", p.draft m id), ("formula", formula)]) with
  | .ok j => j
  | .error e => Json.mkObj [("verdict", "error"), ("reason", e)]

def checkProtocol (args : Json) : ToolOutcome := do
  let p ← parseProtocol args
  let f ← match (args.getObjVal? "formula").toOption with
    | some fj => parseBounded fj
    | none => throw "check_protocol needs a formula"
  let m := p.explore bounds.maxModelNodes
  let size : List (String × Json) := [("states", toJson m.states.size), ("transitions", toJson m.edges.length)]
  if m.truncated then
    return verdictJson "check_protocol" "resource-limit" f.reading <| size ++
      [("evidence", Json.mkObj [("kind", "none"), ("note", s!"the generated model exceeds {bounds.maxModelNodes} states; nothing was proved")])]
  let r ← checkCtl (Json.mkObj [("task", p.draft m "protocol"), ("formula", f.toJson)])
  let path := match (r.getObjValD "evidence").getObjValD "path" with
    | .arr ps => ps.toList.filterMap fun s => (s.getObjValD "message").getStr?.toOption
    | _ => []
  let wire := (p.replayWire path).map LeanFM.Session.Attack.Hop.toJson
  let keep := ["verdict", "reading", "mode", "evidence", "deadlocks"]
  let body := match r with
    | .obj kvs => kvs.toList.filter (fun (k, _) => keep.contains k)
    | _ => []
  return Json.mkObj ([("tool", Json.str "check_protocol"), ("bounds", boundsJson)] ++ body ++ size ++
    [("wire", Json.arr wire.toArray),
     ("note", Json.str ("bounded: each session runs once, with the declared number of sessions per role; variables bind values from the declared domains; every channel is the attacker's" ++
        (match p.defender with
         | some g => s!", except {g.name}'s links to the roles it protects; {g.name} sees inside a ciphertext only with a key it holds"
         | none => "")))])

/-! ## check_reassembly (decision logic-reassembly)

A defender and the host behind it reassemble the same attacker-segmented stream, each with its own
overlap policy. The model is `LeanFM.Session.Reassembly`; `check_ctl` decides the formula over it. -/

def maxSignature : Nat := 4

def parsePolicy (what : String) : Option Json → Except String LeanFM.Session.Reassembly.Policy
  | none => throw s!"internal: no default for {what}"
  | some (.str "first") => pure .first
  | some (.str "last") => pure .last
  | some _ => throw s!"{what} is \"first\" (old bytes win an overlap) or \"last\" (new bytes win)"

def checkReassembly (args : Json) : ToolOutcome := do
  let field := fun (k : String) => (args.getObjVal? k).toOption
  let signature ← match field "signature" with
    | none => pure "EVIL"
    | some (.str sig) =>
      if sig.isEmpty || sig.length > maxSignature then throw s!"the signature is 1 to {maxSignature} characters"
      if sig.contains '.' then throw "the signature may not contain . (it marks a byte that is not the signature's)"
      checkString "signature" sig
    | some _ => throw "signature is a string"
  let box ← parsePolicy "box" (some ((field "box").getD (Json.str "first")))
  let host ← parsePolicy "host" (some ((field "host").getD (Json.str "last")))
  let blocking ← match field "mode" with
    | none | some (.str "blocking") => pure true
    | some (.str "passive") => pure false
    | some _ => throw "mode is \"blocking\" (an IPS resets the stream on a match) or \"passive\" (an IDS alerts)"
  let c : LeanFM.Session.Reassembly.Config := { signature, box, host, blocking }
  let fj := (field "formula").getD c.defaultFormula
  let f ← parseBounded fj
  let m := c.explore bounds.maxModelNodes
  let size : List (String × Json) := [("states", toJson m.states.size), ("transitions", toJson m.edges.length)]
  if m.truncated then
    return verdictJson "check_reassembly" "resource-limit" f.reading <| size ++
      [("evidence", Json.mkObj [("kind", "none"), ("note", s!"the model exceeds {bounds.maxModelNodes} states; nothing was proved")])]
  let r ← checkCtl (Json.mkObj [("task", c.draft m), ("formula", f.toJson)])
  let path : List String := match (r.getObjValD "evidence").getObjValD "path" with
    | .arr ps => ps.toList.filterMap fun (s : Json) => (s.getObjValD "message").getStr?.toOption
    | _ => []
  let segments := (path.filter (fun (l : String) => l.startsWith "segment" && !l.endsWith "(host)")).map fun (l : String) =>
    match (l.drop "segment @".length).toString.splitOn ": " with
    | [off, data] => Json.mkObj [("offset", Json.str off), ("data", Json.str data)]
    | _ => Json.str l
  let keep := ["verdict", "reading", "mode", "evidence", "deadlocks"]
  let body := match r with
    | .obj kvs => kvs.toList.filter (fun (k, _) => keep.contains k)
    | _ => []
  return Json.mkObj ([("tool", Json.str "check_reassembly"), ("bounds", boundsJson)] ++ body ++ size ++
    [("segments", Json.arr segments.toArray),
     ("defender", Json.mkObj [("policy", Json.str box.name), ("mode", Json.str (if blocking then "blocking" else "passive"))]),
     ("host", Json.mkObj [("policy", Json.str host.name)]),
     ("note", Json.str s!"every segmentation of a {signature.length}-byte stream: any offset and length, each byte the signature's or another, sent any number of times; '.' is a byte that is not the signature's")])

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
  , "| `{\"claimed\": \"commit(B, A)\"}` | some transition on the path made this claim (drafts with claims, and check_protocol) |"
  , "| `{\"knows\": {\"actor\": \"Ivo\", \"term\": t}}` | the actor can derive term t from what reached it on the path (observable when the draft declares the actor's knowledge; terms as in the knows tool) |"
  , "| `{\"predicate\": \"text\"}` | free text: never observable; classify it first |"
  , "| `{\"not\": f}`, `{\"and\": [..]}`, `{\"or\": [..]}`, `{\"implies\": [a, b]}` | Boolean |"
  , "| `{\"stronglyImplies\": [a, b]}` | EF a and AG(a -> b): non-vacuous always |"
  , "| `{\"never\": f}` | AG not f |"
  , "| `{\"AG\": f}` `{\"AF\": f}` `{\"EG\": f}` `{\"EF\": f}` `{\"AX\": f}` `{\"EX\": f}` | CTL unary |"
  , "| `{\"AU\": [a, b]}` `{\"EU\": [a, b]}` | a until b, and b happens |"
  , "| `{\"AW\": [a, b]}` `{\"EW\": [a, b]}` | a unless b, b need not happen |"
  , ""
  , "Bare F, G, X, U and W are typing errors: quantify them with A (every path) or E (some path)."
  , "K, O, P, B and Pr are parsed and reported as unsupported inside formulas; the knows tool decides what an actor can derive at an event of a trace."
  , ""
  , "## knows"
  , ""
  , "Arguments: events (envelopes {id, prevIds, causeIds, src, dst, term}), actor, at (an event id), initial (terms the actor starts with), query (optional term), seesAll (optional: the actor sees every channel)."
  , ""
  , "Terms: `{\"atom\": n}`, `{\"key\": n}`, `{\"pk\": a}`, `{\"sk\": a}`, `{\"pair\": [x, y]}`, `{\"tuple\": [x, y, ...]}`, `{\"enc\": {\"key\": k, \"body\": b}}`, `{\"hash\": x}`."
  , ""
  , "Only events in the causal past of at count. Pairs split; a ciphertext opens with the private key for pk, the public key for sk (a signature), the key itself otherwise; nothing recovers a hash input. Without a query the verdict is derived and holds lists every piece with the event that gave it; with one, proved carries the derivation and disproved an exhaustive note."
  , ""
  , "## check_protocol"
  , ""
  , "Arguments: roles ([{name, steps, sessions?}]; sessions 1 to 4, default 1, every session a thread named name, name#2, …; at most 8 threads in all), attacker ({name, knows: [terms]}), domain ([terms] for received variables), domains ({var: [terms]}), formula."
  , ""
  , "Steps: `{\"choose\": {\"var\": x, \"values\": [terms]}}`, `{\"send\": {\"to\": p, \"message\": p}}`, `{\"recv\": p}`, `{\"claim\": {\"name\": n, \"args\": [p]}}`, `{\"fresh\": x}` (binds x to a value new in this session: x in the first, x#2 in the second; no two roles make the same fresh variable, and the attacker may not already know it). A domain that holds a fresh value also holds its copies in other sessions. Patterns are terms with `{\"var\": x}` anywhere; `pk` and `sk` take a name or a pattern."
  , ""
  , "Every channel is the attacker's: honest sends go to the attacker, honest receives accept any matching message the attacker can build. An optional defender ({name, protects, knows, drop, rewrite: [{match, replace}]}) stands between the attacker and the roles it protects: it drops a message when a drop pattern matches any part it can see, opening ciphertexts only with keys it can build from its knows, rewrites a whole message that matches a rewrite (the replacement uses only variables its match binds), and otherwise forwards it; the link from the defender to a protected role is not the attacker's. The formula may use claimed and knows atoms. Bounded: each session runs once, with as many sessions as declared; variables bind values from the domains; a model over 4096 states answers resource-limit."
  , ""
  , "## check_reassembly"
  , ""
  , "Arguments, all optional: signature (1 to 4 characters, default EVIL), box and host (first or last: which bytes win an overlap; defaults first and last), mode (blocking or passive), formula."
  , ""
  , "The attacker sends any segments of the stream, any number of times; each byte is the signature's or another, shown as . in the answer. The claims alerted(sig) and delivered(sig) mark the defender's copy and the host's copy first holding the signature. The search covers every segmentation; the answer lists the segments of an evasion."
  , ""
  , "## Requirement modes"
  , ""
  , "always = AG p; never = AG not p; eventually = AF p; possibly = EF p."
  , "AG(implies(a, b)) is vacuous when a is unreachable; prefer stronglyImplies(a, b)."
  , ""
  , "## Tasks"
  , ""
  , "A task is a canonical id string, or a draft: `{\"id\", \"states\": [..], \"initial\", \"terminals\": [..], \"transitions\": [{\"src\", \"dst\", \"message\", \"from\"?, \"to\"?, \"term\"?}], \"knowledge\"?: {actor: {\"initial\": [terms], \"seesAll\": bool}}}`."
  , ""
  , "With knowledge declared, a state of the model is a task state together with what each declared actor holds; a transition's term reaches its from and to actors and every actor that sees all channels."
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

def toolNames : List String := ["explain_formula", "check_ctl", "check_trace", "classify_requirement", "knows", "check_protocol", "check_reassembly"]

def run (name : String) (args : Json) : Option ToolOutcome :=
  if args.compress.length > bounds.maxArgumentBytes then
    some (.error s!"arguments exceed {bounds.maxArgumentBytes} bytes")
  else match name with
    | "explain_formula" => some (explainFormula args)
    | "check_ctl" => some (checkCtl args)
    | "check_trace" => some (checkTrace args)
    | "classify_requirement" => some (classifyRequirement args)
    | "knows" => some (knows args)
    | "check_protocol" => some (checkProtocol args)
    | "check_reassembly" => some (checkReassembly args)
    | _ => none

end LeanFM.Logic
