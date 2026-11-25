import LeanFM.Session.Global
import LeanFM.Session.GenerativeTypes
import LeanFM.Session.Types
import LeanFM.Session.Grammar
import LeanFM.Session.Topology

/-!
# Protocol text, read with the grammar (clauses selfhost.mcp.session.tools, selfhost.session.lean-syntax)

A session type is a Lean file (`Session.Syntax`). The tools read the same text with the same grammar
(`Session.Grammar`): Lean's parser and token rules run over it, and nothing is elaborated, so text
from any client cannot run code. This module turns the syntax tree into statements, checking every
limit and value, and builds the `Global String` the `protocol` command builds:

```
/-- A purchase. -/
protocol Purchase (Client, Shop, Bank) {
  o: Order from Client to Shop route "POST /orders";
  choice {
    q: Quote from Shop to Client cause o status 201;
    p: Pay from Client to Bank cause q where p.amount = q.price;
  } or {
    SoldOut from Shop to Client cause o status 409;
  }
}
```

Several protocols may be written; the last is the one checked, and `include P A B;` applies an
earlier one with its roles renamed in order. Message types are declared first, as Lean structures
(`structure Pay where amount : Nat`; see `Session.Types`). A `where` condition is typed against
them when the text is read and run by conformance with LeanFM's interpreter (`Session.Where`) over
logged fields, never compiled or executed. Errors give the line and column.

Negative requirements: no text is elaborated or run; a statement after `continue`, an unknown role,
an undefined or recursive include, a repeated protocol name, unbalanced braces, an unterminated
string or comment, nesting deeper than the grammar allows, and anything over the limits are errors,
not guesses.
-/

namespace LeanFM.Session.Text

/-! ## Statements -/

inductive Stmt where
  | msg (id : Option String) (label src dst : String) (cause route : Option String)
      (status : Option Nat) (media : Option String) (guard : Option String)
  | timed (time : Generative.TimeExpr) (message : Stmt)
  | valued (amount : Generative.Amount) (message : Stmt)
  | accrue (as : List Generative.Accrual)
  | clock (name : String) (refs : List String)
  | obligation (spec : Generative.Obligation)
  | weighted (name actor : String) (weights : List LeanFM.Overlay.Q) (branches : List (List Stmt))
  | event (label role : String)
  | choice (branches : List (List Stmt))
  | par (branches : List (List Stmt))
  | join (need : Nat) (branches : List (List Stmt))
  | loop (name : String) (body : List Stmt)
  /-- `rec Name at most N { body } otherwise { stmts }`; expanded by `unroll` right after parsing -/
  | bounded (name : String) (n : Nat) (body : List Stmt) (otherwise : List Stmt)
  | cont (name : String)
  | sessions (body : List Stmt)
  /-- `include P A B with g, h = x;`: roles in order, and each given field of P bound to a field in
  scope, as (given field, field in scope) (selfhost.session.identity.scopes) -/
  | incl (name : String) (args : List String) (binds : List (String × String) := [])
  deriving Inhabited

structure Def where
  name  : String
  roles : List String
  body  : List Stmt
  /-- `version N` (selfhost.session.versions); 0 when the protocol has none -/
  version : Nat := 0
  /-- `given token`: the fields its includer binds (selfhost.session.identity.scopes) -/
  givens : List String := []
  deriving Inhabited

/-- The highest version a protocol may declare. -/
def maxVersion : Nat := 9999

/-- The newest protocol of this name among `defs` (defined earlier ones first). -/
def latest (defs : List Def) (n : String) : Option Def := defs.reverse.find? fun d => d.name == n

/-- A `system` block as written (selfhost.session.instances): shared instances (name, role,
serial) and accepts (protocol, players: `fresh Role` as `(true, Role)`, an instance as
`(false, name)`). -/
structure SystemDef where
  name    : String
  shared  : List (Prod String (Prod String Bool))
  accepts : List (Prod String (List (Prod Bool String)))
  deriving Inhabited, Repr

/-- A `deployment` block as written (selfhost.session.deployment): the protocol it places and its
deployment tree, the roles as actors with their interfaces. -/
structure DeploymentDef where
  name     : String
  protocolName : String
  world    : List (Node String)

/-- The most groups, roles and interfaces one deployment holds. -/
def maxDeployNodes : Nat := 256

/-- The interface kinds a deployment may name without declaring them. -/
def builtinKinds : List IfaceKind :=
  [IfaceKind.call, .queue, .stream, .http, .api, .ingressHttp, .ingressHttps, .datagram]

/-- What a requirement points at (selfhost.requirements.map): a protocol of the file, a formula
over one (`P ⊨ φ`, φ an s-expression), or `sorry` with an optional note. -/
inductive Pointer where
  | protocol (name : String)
  | formula (name : String) (sexpr : String)
  | sorry_ (note : String)
  deriving Inhabited, Repr, BEq

/-- An implementation entry's value (selfhost.implementations.map): evidence for an imported
requirement, or a pointer for the implementation's own CTL. -/
inductive Evidence where
  | conform (log : String)
  | test (name : String)
  | pointer (p : Pointer)
  deriving Inhabited, Repr, BEq

/-- An `implementation Name of Module { ... }` block as written. -/
structure ImplDef where
  name    : String
  of      : String
  refines : List (String × String) := []
  entries : List (String × Evidence) := []
  hints   : List String := []
  deriving Inhabited, Repr

/-- At most this many entries in one requirements map or implementation block, and this long a
requirement name. -/
def maxMapEntries : Nat := 512
def maxReqName : Nat := 200

/-- At most this many shared instances and accepts in one system. -/
def maxShared : Nat := 8
def maxAccepts : Nat := 4

structure Limits where
  maxBytes   : Nat := 65536
  maxSteps   : Nat := 200
  maxDepth   : Nat := 24
  maxRoles   : Nat := 12
  maxString  : Nat := 200
  maxBranches : Nat := 16

def limits : Limits := {}

/-! ## Bounded loops (selfhost.session.rec.bounded): expanded into explicit copies -/

/-- The labels of every message and event in a body (included protocols are checked when built). -/
partial def labelsOf : List Stmt → List String
  | [] => []
  | s :: rest => (match s with
    | .msg _ label .. => [label]
    | .event label _ => [label]
    | .timed _ m | .valued _ m => labelsOf [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap labelsOf
    | .loop _ b | .sessions b => labelsOf b
    | .bounded _ _ b o => labelsOf b ++ labelsOf o
    | _ => []) ++ labelsOf rest

/-- The ids a body declares (message ids), in any branch. -/
partial def declaredIds : List Stmt → List String
  | [] => []
  | s :: rest => (match s with
    | .msg (some x) .. => [x]
    | .timed _ m | .valued _ m => declaredIds [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap declaredIds
    | .loop _ b | .sessions b => declaredIds b
    | .bounded _ _ b o => declaredIds b ++ declaredIds o
    | _ => []) ++ declaredIds rest

/-- The units a body's amounts, rates and penalties name (selfhost.session.envelope). -/
partial def unitsOf : List Stmt → List String
  | [] => []
  | s :: rest => (match s with
    | .valued a m => a.unit :: unitsOf [m]
    | .timed _ m => unitsOf [m]
    | .accrue as => as.map (·.unit)
    | .obligation o => (o.penalty.map (·.unit)).toList
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap unitsOf
    | .loop _ b | .sessions b => unitsOf b
    | .bounded _ _ b o => unitsOf b ++ unitsOf o
    | _ => []) ++ unitsOf rest

/-- Each message id a body declares with its label, in any branch. -/
partial def idLabels : List Stmt → List (String × String)
  | [] => []
  | s :: rest => (match s with
    | .msg (some x) label .. => [(x, label)]
    | .timed _ m | .valued _ m => idLabels [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap idLabels
    | .loop _ b | .sessions b => idLabels b
    | .bounded _ _ b o => idLabels b ++ idLabels o
    | _ => []) ++ idLabels rest

/-- Every message's label with its media type, if it has one. -/
partial def mediaOf : List Stmt → List (String × Option String)
  | [] => []
  | s :: rest => (match s with
    | .msg _ label _ _ _ _ _ media _ => [(label, media)]
    | .timed _ m | .valued _ m => mediaOf [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap mediaOf
    | .loop _ b | .sessions b => mediaOf b
    | .bounded _ _ b o => mediaOf b ++ mediaOf o
    | _ => []) ++ mediaOf rest

/-- Every message's label and where condition in a body. -/
partial def conditions : List Stmt → List (String × String)
  | [] => []
  | s :: rest => (match s with
    | .msg _ label _ _ _ _ _ _ (some g) => [(label, g)]
    | .timed _ m | .valued _ m => conditions [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap conditions
    | .loop _ b | .sessions b => conditions b
    | .bounded _ _ b o => conditions b ++ conditions o
    | _ => []) ++ conditions rest

/-- Every message's label and where condition in a body, each with the ids in scope where it
stands: its own id, then the messages before it on its path, nearest first. A protocol may reuse
an id in another place (GoServer names many messages `a` or `x`), so a condition reads the
message its id names there, not every message the id names anywhere. After a choice or parallel
branches, an id bound in a branch names any of the labels the branches gave it. -/
partial def scopedConditions (scope : List (String × List String)) :
    List Stmt → List (String × String × List (String × List String)) × List (String × List String)
  | [] => ([], scope)
  | s :: rest =>
    let (here, scope') : List (String × String × List (String × List String)) × List (String × List String) :=
      match s with
      | .msg id label _ _ _ _ _ _ g =>
        let sc := match id with | some x => (x, [label]) :: scope | none => scope
        ((match g with | some t => [(label, t, sc)] | none => []), sc)
      | .timed _ m | .valued _ m => scopedConditions scope [m]
      | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs =>
        let outs := bs.map (scopedConditions scope)
        let bound := outs.flatMap fun (_, sc) => (sc.take (sc.length - scope.length))
        let names := (bound.map (·.1)).eraseDups
        let merged := names.map fun x => (x, (bound.filter (·.1 == x) |>.flatMap (·.2)).eraseDups)
        (outs.flatMap (·.1), merged ++ scope)
      | .loop _ b | .sessions b => scopedConditions scope b
      | .bounded _ _ b o =>
        let (c1, sc1) := scopedConditions scope b
        let (c2, _) := scopedConditions sc1 o
        (c1 ++ c2, sc1)
      | _ => ([], scope)
    let (more, final) := scopedConditions scope' rest
    (here ++ more, final)

/-- Rename the ids in `ids` (and causes and time references to them) with suffix `sfx`. -/
partial def renameIds (ids : List String) (sfx : String) : List Stmt → List Stmt
  | [] => []
  | s :: rest => go s :: renameIds ids sfx rest
where
  r (x : String) : String := if ids.contains x then x ++ sfx else x
  rt (t : Generative.TimeExpr) : Generative.TimeExpr := { t with refs := t.refs.map r }
  -- a condition reads the ids of its own copy
  rg (text : String) : String := match Where.parse text with
    | .ok e => (e.mapIds r).render
    | .error _ => text
  go : Stmt → Stmt
    | .msg id l a b cause route status media guard => .msg (id.map r) l a b (cause.map r) route status media (guard.map rg)
    | .timed t m => .timed (rt t) (go m)
    | .valued a m => .valued a (go m)
    | .clock name refs => .clock name (refs.map r)
    -- named choices stay unique too: copy k's choice is name_k
    | .weighted n a qs bs => .weighted (n ++ sfx) a qs (bs.map (renameIds ids sfx))
    | .choice bs => .choice (bs.map (renameIds ids sfx))
    | .par bs => .par (bs.map (renameIds ids sfx))
    | .join k bs => .join k (bs.map (renameIds ids sfx))
    | .loop n b => .loop n (renameIds ids sfx b)
    | .sessions b => .sessions (renameIds ids sfx b)
    | .bounded n k b o => .bounded n k (renameIds ids sfx b) (renameIds ids sfx o)
    | other => other

/-- Replace each `continue name` in `ss` (in any nested branch, but not inside a loop of the same
name) by the statements `next`. -/
partial def splice (name : String) (next : List Stmt) : List Stmt → List Stmt
  | [] => []
  | .cont n :: rest => if n == name then next ++ splice name next rest else .cont n :: splice name next rest
  | s :: rest => (match s with
    | .weighted n a qs bs => .weighted n a qs (bs.map (splice name next))
    | .choice bs => .choice (bs.map (splice name next))
    | .par bs => .par (bs.map (splice name next))
    | .join k bs => .join k (bs.map (splice name next))
    | .loop n b => if n == name then s else .loop n (splice name next b)
    | .sessions b => .sessions (splice name next b)
    | other => other) :: splice name next rest

/-- Expand every bounded loop into explicit copies: copy k continues into copy k+1, and copy N
continues into the otherwise block. -/
partial def unroll : List Stmt → List Stmt
  | [] => []
  | .bounded name n body other :: rest =>
    let ids := declaredIds body
    let body := unroll body
    let other := unroll other
    let rec copy (k : Nat) (fuel : Nat) : List Stmt :=
      let mine := if k == 1 then body else renameIds ids s!"_{k}" body
      match fuel with
      | 0 => splice name other mine
      | f + 1 => splice name (if k ≥ n then other else copy (k + 1) f) mine
    copy 1 n ++ unroll rest
  | s :: rest => (match s with
    | .weighted n a qs bs => .weighted n a qs (bs.map unroll)
    | .choice bs => .choice (bs.map unroll)
    | .par bs => .par (bs.map unroll)
    | .join k bs => .join k (bs.map unroll)
    | .loop n b => .loop n (unroll b)
    | .sessions b => .sessions (unroll b)
    | .timed t m => .timed t m
    | other => other) :: unroll rest

/-! ## Reading: the grammar's syntax tree as statements -/

/-- A time unit's length in milliseconds. -/
def unitMs (u : String) : Option Nat :=
  match u with
  | "ms" => some 1
  | "second" | "seconds" => some 1000
  | "minute" | "minutes" => some 60000
  | "hour" | "hours" => some 3600000
  | "day" | "days" => some 86400000
  | "week" | "weeks" => some 604800000
  | _ => none

/-- What reading a file collects besides its protocols. -/
structure Acc where
  /-- `require per q { ... }` clauses after the protocols (selfhost.session.sla) -/
  requires : Array Generative.Requirement := #[]
  /-- `structure Name where field : Type` declarations: the message types (selfhost.session.types) -/
  types : Array Types.Message := #[]
  /-- `sessions by x.field`: session keys as (message id, field path) (selfhost.session.envelope) -/
  keys : Array (String × String) := #[]
  /-- `system` blocks after the protocols they accept (selfhost.session.instances) -/
  systems : Array SystemDef := #[]
  /-- the file's `requirements { ... }` map, its last item (selfhost.requirements.map) -/
  reqMap : Option (Array (String × Pointer)) := none
  /-- `implementation` blocks (selfhost.implementations.map) -/
  impls : Array ImplDef := #[]
  /-- `deployment` blocks after the protocols they place (selfhost.session.deployment) -/
  deployments : Array DeploymentDef := #[]

/-- Reading: the source (for positions and requirement texts) and what has been collected. -/
abbrev R := ReaderT String (StateT Acc (Except String))

open Lean (Syntax Name) in
section
variable (stx : Syntax)

def lineCol (src : String) (pos : String.Pos.Raw) : Nat × Nat := Id.run do
  let mut line := 1
  let mut col := 1
  let mut i : String.Pos.Raw := 0
  while i.byteIdx < pos.byteIdx && !String.Pos.Raw.atEnd src i do
    if String.Pos.Raw.get src i == '\n' then line := line + 1; col := 1 else col := col + 1
    i := String.Pos.Raw.next src i
  return (line, col)

/-- An error at a node's position. -/
def failAt (msg : String) : R α := do
  let (l, c) := lineCol (← read) (stx.getPos?.getD 0)
  throw s!"line {l}, column {c}: {msg}"

def kids : Array Syntax := stx.getArgs

/-- The `i`th child of an optional group, when the group is present. -/
def opt (i : Nat) : Option Syntax := if stx.getNumArgs > i then some stx[i] else none

/-- The descendants of kind `k`, outside nested nodes of that kind. -/
partial def ofKind (k : Lean.SyntaxNodeKind) : Syntax → Array Syntax
  | s@(.node _ kind args) => if kind == k then #[s] else args.flatMap (ofKind k)
  | _ => #[]

/-- The identifiers under a node (words the grammar matched are atoms, not identifiers). -/
partial def identsIn : Syntax → Array Syntax
  | s@(.ident ..) => #[s]
  | .node _ _ args => args.flatMap identsIn
  | _ => #[]

def checkLen (what s : String) : R String := do
  if s.isEmpty then failAt stx s!"{what} is empty"
  if s.toList.any (fun (ch : Char) => ch.toNat < 32) then failAt stx s!"{what} contains a line break or another control character"
  if s.length > limits.maxString then failAt stx s!"{what} is longer than {limits.maxString} characters"
  return s

/-- A plain name: one Lean identifier, not a dotted path. -/
def name (what : String) : R String := do
  match stx.getId with
  | .str .anonymous s => checkLen stx what s
  | .anonymous => failAt stx s!"expected {what}"
  | n => failAt stx s!"{what} {n} is a dotted path; use one name"

/-- A dotted path such as `b.member`, as its components. -/
def path (what : String) : R (List String) := do
  let cs := stx.getId.components.map (·.toString (escape := false))
  if cs.isEmpty then failAt stx s!"expected {what}"
  cs.mapM (checkLen stx what)

/-- A decimal number of at most `maxDigits` digits. -/
def nat (maxDigits : Nat := 6) : R Nat := do
  let raw := (stx.isLit? Lean.numLitKind).getD ""
  if raw.isEmpty || !raw.toList.all Char.isDigit then failAt stx "expected a decimal number"
  if raw.length > maxDigits then failAt stx "this number is too large"
  return raw.toNat!

def strVal : R String := do
  let some s := stx.isStrLit? | failAt stx "expected a string in double quotes"
  if s.toList.any (fun (ch : Char) => ch.toNat < 32) then failAt stx "the string contains a control character"
  checkLen stx "string" s

def fraction : R LeanFM.Overlay.Q := do
  let n ← nat stx[0]
  let d ← match opt stx[1] 1 with
    | some d => nat d
    | none => pure 1
  if d == 0 || n > d then failAt stx "probability must be between 0 and 1 with a nonzero denominator"
  return LeanFM.Overlay.Q.norm n d

def duration : R Nat := do
  let n ← nat stx[0] 16
  let u ← name stx[1] "a time unit"
  let some scale := unitMs u | failAt stx[1] "unknown time unit; use ms, seconds, minutes, hours, days or weeks"
  if n * scale > 9007199254740991 then failAt stx "duration exceeds the safe integer millisecond limit"
  return n * scale

def weighted (entries : List (Nat × LeanFM.Overlay.Q)) (what : String) : R (List (Nat × LeanFM.Overlay.Q)) := do
  if entries.length > 16 then failAt stx s!"a {what} distribution has at most 16 entries"
  match Generative.checkWeights (entries.map (·.2)) with
  | .error e => failAt stx e
  | .ok _ => pure ()
  if (entries.map (·.1)).eraseDups.length != entries.length then failAt stx s!"duplicate {what} in sample"
  return entries

/-- `d` or `sample { d : p; ... }`. -/
def delay : R (List (Nat × LeanFM.Overlay.Q)) := do
  if stx.getNumArgs == 1 then return [(← duration stx[0], LeanFM.Overlay.Q.one)]
  else
    let es ← (ofKind `LeanFM.Session.Grammar.durWeight stx).toList.mapM fun w => do pure (← duration w[0], ← fraction w[2])
    if es.isEmpty then failAt stx "a delay sample needs at least one entry"
    weighted stx es "delay"

def timeRef1 : R String := name stx[stx.getNumArgs - 2] "a prior message id"

def timeRefs : R (List String) := (ofKind `LeanFM.Session.Grammar.timeRef1 stx).toList.mapM timeRef1

def timeExpr : R Generative.TimeExpr := do
  if stx[1].isOfKind `LeanFM.Session.Grammar.dur then
    let d ← duration stx[1]
    if d == 0 then failAt stx "a gate's period must be longer than zero"
    return { period := some d }
  let base : Generative.TimeExpr ← if stx[0].isOfKind `LeanFM.Session.Grammar.timeRef then pure { refs := ← timeRefs stx[0] }
    else pure { clock := some (← name stx[0] "a clock name or time(messageId)") }
  match opt stx[1] 1 with
  | some d => return { base with offsets := ← delay d }
  | none => return base

def quantity : R (Bool × Nat × String) := do
  let neg := stx[0].getNumArgs > 0
  let n ← nat stx[1] 12
  let unit ← name stx[2] "a unit (such as USD)"
  if unit.length > 32 then failAt stx[2] "a unit name has at most 32 characters"
  return (neg, n, unit)

def amounts : R (List Generative.Amount) := do
  if stx.getNumArgs == 2 then
    let q := stx[1]
    let (neg, n, unit) ← quantity q
    if neg then failAt q "a single amount is not negative; use a trade vector { ... } for both directions"
    return [{ unit, outcomes := [(n, LeanFM.Overlay.Q.one)] }]
  else
    if stx.getNumArgs == 5 then
      -- sample { N UNIT : p; ... }: one unit, distinct quantities
      let es ← (ofKind `LeanFM.Session.Grammar.qtyWeight stx).toList.mapM fun w => do
        let (neg, n, unit) ← quantity w[0]
        if neg then failAt w "an amount sample has no negative entries"
        pure (n, unit, ← fraction w[2])
      let some (_, unit, _) := es.head? | failAt stx "an amount sample needs at least one entry"
      if es.any (fun (_, u, _) => u != unit) then failAt stx "an amount sample uses one unit"
      let outcomes ← weighted stx (es.map fun (n, _, q) => (n, q)) "quantity"
      return [{ unit, outcomes }]
    else
      -- { 5 apple; -3 USD; }: a trade vector; negative entries move the other way
      let es := ofKind `LeanFM.Session.Grammar.qty stx
      if es.isEmpty then failAt stx "a trade vector needs at least one entry"
      if es.size > 16 then failAt stx "a trade vector has at most 16 entries"
      let mut out : List Generative.Amount := []
      for q in es do
        let (neg, n, unit) ← quantity q
        if out.any (·.unit == unit) then failAt q s!"unit {unit} appears twice in the trade vector"
        out := out ++ [{ unit, outcomes := [(n, LeanFM.Overlay.Q.one)], reverse := neg }]
      return out

def timing : R Generative.TimeExpr := do
  if stx[1].isOfKind `LeanFM.Session.Grammar.timeExpr then timeExpr stx[1]
  else return { offsets := ← delay stx[1], relative := true }

def eventTiming : R Generative.TimeExpr := do
  if stx[1].isOfKind `LeanFM.Session.Grammar.delay then return { offsets := ← delay stx[1], relative := true }
  let d ← duration stx[2]
  if d == 0 then failAt stx "a gate's period must be longer than zero"
  return { period := some d }

/-- `N UNIT per PERIOD`: `per week` is per one week, `per 2 weeks` a duration. -/
def rateEntry : R (Bool × Nat × String × Nat) := do
  let neg := stx[0].getNumArgs > 0
  let n ← nat stx[1] 12
  let unit ← name stx[2] "a unit (such as USD)"
  let periodMs ← if stx[4].isOfKind `LeanFM.Session.Grammar.dur then duration stx[4] else do
    match ← name stx[4] "a time unit" with
    | "ms" => pure 1 | "second" => pure 1000 | "minute" => pure 60000 | "hour" => pure 3600000
    | "day" => pure 86400000 | "week" => pure 604800000
    | _ => failAt stx[4] "unknown period; use ms, second, minute, hour, day or week, or a number and unit"
  if periodMs == 0 then failAt stx[4] "a rate's period must be longer than zero"
  return (neg, n, unit, periodMs)

/-- A condition's text with runs of whitespace made single spaces. -/
def condText : R String := do
  let raw := stx.getAtomVal
  let words := (raw.split Char.isWhitespace).toList.map (·.toString) |>.filter (· != "")
  checkLen stx "where condition" (" ".intercalate words)

end

/-- A media type as a message's `media` names it: a lower-case type/subtype of letters, digits and
!#$&^_.+- (the subtype may be *), at most 100 characters (selfhost.session.openapi). -/
def validMedia (t : String) : Bool :=
  let ok := fun (c : Char) => (c.isLower || c.isDigit || "!#$&^_.+-".contains c)
  match t.splitOn "/" with
  | [a, b] => t.length ≤ 100 && !a.isEmpty && !b.isEmpty && a.all ok && (b == "*" || b.all ok)
  | _ => false

open Lean (Syntax) in
/-- A message statement. -/
def msgStmt (stx : Syntax) : R Stmt := do
  let id ← match opt stx[0] 0 with | some i => pure (some (← name i "a message id")) | none => pure none
  let label ← name stx[1] "a message label"
  let src ← name stx[3] "the sending role"
  let dst ← name stx[5] "the receiving role"
  let cause ← match opt stx[6] 1 with | some c => pure (some (← name c "a message id")) | none => pure none
  let route ← match opt stx[7] 1 with | some r => pure (some (← strVal r)) | none => pure none
  let status ← match opt stx[8] 1 with | some n => pure (some (← nat n)) | none => pure none
  let media ← match opt stx[9] 1 with
    | some m => do
      let t ← strVal m
      if !validMedia t then failAt m s!"media \"{t}\" is not a media type: write type/subtype in lower case, such as \"image/png\""
      pure (some t)
    | none => pure none
  let as ← match opt stx[10] 0 with | some a => amounts a | none => pure []
  let time ← match opt stx[11] 0 with | some t => pure (some (← timing t)) | none => pure none
  let guard ← match opt stx[12] 1 with | some c => pure (some (← condText c)) | none => pure none
  let message := Stmt.msg id label src dst cause route status media guard
  let message := as.foldl (fun m a => .valued a m) message
  return match time with | some t => .timed t message | none => message

open Lean (Syntax) in
def eventStmt (stx : Syntax) : R Stmt := do
  let label ← name stx[0] "an event label"
  let r ← name stx[2] "a role"
  match opt stx[3] 0 with
  | some t => return .timed (← eventTiming t) (.event label r)
  | none => return .event label r

open Lean (Syntax) in
def obligationStmt (stx : Syntax) : R Stmt := do
  let oname := ".".intercalate (← path stx[1] "an obligation name")
  if oname.length > limits.maxString then failAt stx[1] "obligation name is too long"
  let actor ← name stx[3] "a role"
  let ls ← ([stx[9]] ++ (identsIn stx[10]).toList).mapM (name · "a message label")
  if ls.length > 16 then failAt stx[10] "at most 16 obligation labels"
  let pen := stx[18]
  let penalty ← if pen.getNumArgs == 4 then do
      let (neg, quantity, unit) ← quantity pen[1]
      if neg then failAt pen[1] "a penalty is not negative"
      let payee ← name pen[3] "the role paid"
      if payee == actor then failAt pen "a penalty is paid to another role, not to its payer"
      pure (some ({ quantity, unit, payee } : Generative.Penalty))
    else pure none
  let clock ← name stx[6] "a clock"
  let withinMs ← duration stx[12]
  let breach ← name stx[17] "a monitor label"
  return .obligation { name := oname, actor, clock, labels := ls, withinMs, breach, penalty }

open Lean (Syntax) in
def accrueStmt (stx : Syntax) : R Stmt := do
  -- one rate, or a rate vector whose negative entries flow the other way
  let args := stx.getArgs
  let rates := ofKind `LeanFM.Session.Grammar.rate stx
  if rates.isEmpty then failAt stx "a rate vector needs at least one entry"
  if rates.size > 16 then failAt stx "a rate vector has at most 16 entries"
  let payer ← name args[args.size - 4]! "the paying role"
  let payee ← name args[args.size - 2]! "the role paid"
  if payer == payee then failAt stx "an accrual is paid to another role, not to its payer"
  let mut out : List Generative.Accrual := []
  for r in rates do
    let (rev, quantity, unit, periodMs) ← rateEntry r
    if rev && args.size == 7 then failAt r "accrue: a single rate is not negative; use a rate vector { ... } for both directions"
    if out.any (·.unit == unit) then failAt r s!"unit {unit} appears twice in the rate vector"
    out := out ++ [if rev then { payer := payee, payee := payer, unit, quantity, periodMs }
      else { payer, payee, unit, quantity, periodMs }]
  return .accrue out

open Lean (Syntax) in
/-- The blocks directly under a statement (not those nested in its blocks). -/
def blocksOf (stx : Syntax) : Array Syntax := ofKind `LeanFM.Session.Grammar.block stx |>.filter (· != stx)

open Lean (Syntax) in
mutual
/-- The statements of a block, one level deeper. -/
partial def block (depth : Nat) (stx : Syntax) : R (List Stmt) := do
  if depth ≥ limits.maxDepth then failAt stx "statements are nested too deeply"
  let ss := stx[1].getArgs
  if ss.size > limits.maxSteps then failAt stx s!"more than {limits.maxSteps} steps in block"
  ss.toList.mapM (stmt (depth + 1))

partial def blocks (depth : Nat) (stx : Syntax) : R (List (List Stmt)) := do
  let bs := (stx.getArgs.toList.flatMap fun a => (ofKind `LeanFM.Session.Grammar.block a).toList)
  if bs.length > limits.maxBranches then failAt stx s!"more than {limits.maxBranches} branches"
  bs.mapM (block depth)

partial def declaredStmt (depth : Nat) (stx : Syntax) : R Stmt := do
  let actor ← name stx[2] "the choosing role"
  let n ← strVal stx[6]
  let branches := [stx[8]] ++ (ofKind `LeanFM.Session.Grammar.wbranch stx[9]).toList
  if branches.length > limits.maxBranches then failAt stx s!"more than {limits.maxBranches} branches"
  if depth ≥ limits.maxDepth then failAt stx "statements are nested too deeply"
  let mut weights : List LeanFM.Overlay.Q := []
  let mut bodies : List (List Stmt) := []
  for b in branches do
    if b[1].getNumArgs == 3 then weights := weights ++ [← fraction b[1][1]]
    let ss := b[2].getArgs
    if ss.size > limits.maxSteps then failAt b s!"more than {limits.maxSteps} steps in block"
    bodies := bodies ++ [← ss.toList.mapM (stmt (depth + 1))]
  if !weights.isEmpty then
    if weights.length != bodies.length then failAt stx "every branch needs probability n/d"
    match Generative.checkWeights weights with
    | .error e => failAt stx e
    | .ok _ => pure ()
  return .weighted n actor weights bodies

partial def keyedStmt (depth : Nat) (stx : Syntax) : R Stmt := do
  -- `sessions by b.member { ... }`: the session key, a field of a message of the block
  let p ← path stx[2] "the session key"
  let (x, field) ← match p with
    | x :: f :: more => pure (x, ".".intercalate (f :: more))
    | _ => failAt stx[2] "expected '.' and the key's field, as in sessions by b.member"
  let body ← block depth stx[3]
  if !(declaredIds body).contains x then
    failAt stx[2] s!"sessions by {x}: {x} is not the id of a message of this sessions block"
  modify fun a => { a with keys := a.keys.push (x, field) }
  return .sessions body

partial def boundedStmt (depth : Nat) (stx : Syntax) : R Stmt := do
  let n ← nat stx[4]
  if n < 1 || n > 32 then failAt stx[4] "a bounded loop runs between 1 and 32 times"
  let other ← match opt stx[6] 1 with | some b => block depth b | none => pure []
  return .bounded (← name stx[1] "a loop name") n (← block depth stx[5]) other

partial def stmt (depth : Nat) (stx : Syntax) : R Stmt := do
  match stx.getKind with
  | `LeanFM.Session.Grammar.msg => msgStmt stx
  | `LeanFM.Session.Grammar.event => eventStmt stx
  | `LeanFM.Session.Grammar.choice => return .choice (← blocks depth stx)
  | `LeanFM.Session.Grammar.par => return .par (← blocks depth stx)
  | `LeanFM.Session.Grammar.join => return .join (← nat stx[1]) (← blocks depth stx)
  | `LeanFM.Session.Grammar.rec => return .loop (← name stx[1] "a loop name") (← block depth stx[2])
  | `LeanFM.Session.Grammar.bounded => boundedStmt depth stx
  | `LeanFM.Session.Grammar.sessions => return .sessions (← block depth stx[1])
  | `LeanFM.Session.Grammar.keyed => keyedStmt depth stx
  | `LeanFM.Session.Grammar.cont => return .cont (← name stx[1] "a loop name")
  | `LeanFM.Session.Grammar.incl => do
    let binds ← match stx[3].getArgs with
      | #[_, bs] => (bs.getArgs.filter (·.getKind == `LeanFM.Session.Grammar.binding)).toList.mapM fun b => do
          let g ← name b[0] "a given field"
          match b[1].getArgs with
          | #[_, x] => return (g, ← name x "a field in scope")
          | _ => return (g, g)
      | _ => pure []
    return .incl (← name stx[1] "a protocol") (← stx[2].getArgs.toList.mapM (name · "a role name")) binds
  | `LeanFM.Session.Grammar.clock => return .clock (← name stx[1] "a clock name") (← timeRefs stx[3])
  | `LeanFM.Session.Grammar.obligation => obligationStmt stx
  | `LeanFM.Session.Grammar.accrue => accrueStmt stx
  | `LeanFM.Session.Grammar.declared => declaredStmt depth stx
  | k => failAt stx s!"unexpected {k}"
end

open Lean (Syntax) in
/-- One clause of `require per q { ... }` (selfhost.session.sla). -/
def requirement (entry : String) (stx : Syntax) : R Generative.Requirement := do
  let args := stx.getArgs
  let every := args.size == 6
  let bound ← if every then pure Generative.Bound.every else
    let f ← fraction args[2]!
    pure (if (args[1]!.getAtomVal == "least" || args[1]!.getId.toString == "least") then Generative.Bound.atLeast f else Generative.Bound.atMost f)
  let whoStx := if every then args[1]! else args[4]!
  let who ← name whoStx "the entry"
  if who != entry then failAt stx s!"this block requires per {entry}; the clause is about {who}"
  let tsStx := args[args.size - 3]!
  let ts ← (tsStx.getArgs.filter (·.isIdent)).toList.mapM (name · "a message or event label")
  if ts.length > 16 then failAt tsStx "at most 16 targets"
  let mut r : Generative.Requirement := { entry, bound, targets := ts }
  for o in args[args.size - 2]!.getArgs do
    let word := if o[0].isIdent then o[0].getId.toString else o[0].getAtomVal
    match word with
    | "within" =>
      if r.withinMs.isSome then failAt o "'within' given twice"
      r := { r with withinMs := some (← duration o[1]) }
    | "over" =>
      if r.window.isSome then failAt o "'over' given twice"
      let n ← nat o[1] 9
      let u ← name o[2] "a time unit or 'entries'"
      if u == "entries" || u == "entry" then
        if n == 0 then failAt o "a window needs at least one entry"
        r := { r with window := some (.entries n) }
      else match unitMs u with
        | some ms => if n == 0 then failAt o "a window needs a positive length" else r := { r with window := some (.time (n * ms)) }
        | none => failAt o[2] "unknown window unit; use entries, ms, seconds, minutes, hours, days or weeks"
    | "confidence" =>
      let c ← fraction o[1]
      if c.num == 0 || c.num == c.den then failAt o "confidence must be strictly between 0 and 1"
      r := { r with confidence := c }
    | _ =>
      let n ← nat o[1] 9
      match unitMs (← name o[3] "a time unit") with
      | some ms => r := { r with rate := some (n, ms) }
      | none => failAt o[3] "unknown time unit; use ms, second, minute, hour, day or week"
  if bound == .every && r.window.isSome then
    failAt stx "'every' is a hard deadline, checkable on each entry: it takes no observation window"
  if bound != .every && r.window.isNone then
    failAt stx "a required fraction is only checkable over an observation window: add 'over 1 hour' or 'over 1000 entries'"
  let src ← read
  let text := match stx.getPos? with
    | some a => match stx.getTailPos? with
      | some b => String.Pos.Raw.extract src a b
      | none => ""
    | none => ""
  return { r with text := text.trimAscii.toString }

open Lean (Syntax) in
/-- A message type: `structure Name where field : Type ... deriving A, B` (`x y : Nat` declares
both); `structure Name` is empty. The doc comment before it documents it. -/
def structureDecl (doc : Option Syntax) (stx : Syntax) : R Types.Message := do
  let mname ← name stx[1] "the structure's name"
  let mut fields : Array Types.Field := #[]
  let mut constraints : Array Types.Constraint := #[]
  for f in ofKind `LeanFM.Session.Grammar.field stx[2] do
    let ft := f[2]
    if ft.getKind == `LeanFM.Session.Grammar.constraintField then
      let text := ft[0].getAtomVal
      let names := f[0].getArgs
      if names.size != 1 then failAt f "a constraint field has one name"
      let cname ← name names[0]! "a constraint's name"
      -- in the condition language, a bare name is a field of this structure
      let checkable ← match Where.parse text with
        | .ok ex =>
          for (x, _) in ex.paths do
            -- size is the raw body's length in bytes (selfhost.session.wire-constraints)
            if !(fields.any (·.name == x)) && x != Types.sizeName then
              failAt ft s!"structure {mname}: constraint {cname} reads {x}, which is not a field declared before it"
          pure true
        | .error _ => pure false
      constraints := constraints.push { name := cname, text, checkable }
      continue
    let tn ← name ft[0] "a type, such as Nat, String or a structure's name"
    -- marks and placement (selfhost.session.identity.marks): Fresh T, Link T, Header T,
    -- PathParam T, QueryParam T, and a placement over a mark, Header (Link T)
    let wrappers := ["List", "Array", "Option", "Fresh", "Link", "Header", "PathParam", "QueryParam"]
    let (ty, mark, place) ← if ft[2].isIdent then do
        let mk ← name ft[1] "Fresh or Link"
        let inner ← name ft[2] s!"the type {mk} holds"
        let some pl := Types.placeOf tn | failAt ft s!"{tn} takes one plain type"
        let some m := Types.markOf mk | failAt ft s!"{tn} ({mk} ...): inside the parentheses comes Fresh or Link, as in {tn} (Link String)"
        if wrappers.contains inner then failAt ft s!"{mk} holds one plain type, such as {mk} String"
        pure (Types.Ty.ofName inner, m, pl)
      else if ft[1].isIdent then do
        let inner ← name ft[1] s!"the type the {tn} holds"
        if wrappers.contains inner then
          failAt ft s!"{tn} holds one plain type, such as {tn} Nat (protobuf has no {tn} of a List or Option)"
        match Types.markOf tn, Types.placeOf tn with
        | some m, _ => pure (Types.Ty.ofName inner, m, Types.Place.body)
        | _, some pl => pure (Types.Ty.ofName inner, Types.Mark.plain, pl)
        | _, _ => pure ((if tn == "Option" then Types.Ty.opt else Types.Ty.list) (Types.Ty.ofName inner), Types.Mark.plain, Types.Place.body)
      else pure (Types.Ty.ofName tn, Types.Mark.plain, Types.Place.body)
    for n in f[0].getArgs do
      fields := fields.push { name := ← name n "a field name", ty, mark, place }
  if fields.size > Types.maxFieldsPer then failAt stx s!"structure {mname} has more than {Types.maxFieldsPer} fields"
  let docText := match doc with
    | some d =>
      let raw := ((d[1].getAtomVal.dropEnd 2).toString)
      " ".intercalate ((raw.split Char.isWhitespace).toList.map (·.toString) |>.filter (· != ""))
    | none => ""
  let (ctor, priv) := match (ofKind `LeanFM.Session.Grammar.ctorLine stx[2])[0]? with
    | some cl => ((identsIn cl).back?.map (·.getId.toString) |>.getD "mk", cl[0].getNumArgs > 0)
    | none => ("", false)
  return { name := mname, fields := fields.toList, doc := docText, constraints := constraints.toList,
           ctor, privateCtor := priv }

open Lean (Syntax) in
/-- One protocol (`protocolBody`): its name, roles and statements, bounded loops unrolled. -/
def protocolDef (body : Syntax) : R Def := do
  let pname ← name body[1] "the protocol's name"
  let rs ← (body[3].getArgs.filter (·.isIdent)).toList.mapM (name · "a role")
  if rs.isEmpty then failAt body "a protocol needs at least one role"
  if rs.length > limits.maxRoles then failAt body s!"a protocol has at most {limits.maxRoles} roles"
  if rs.eraseDups.length != rs.length then failAt body "role names must be distinct"
  let version <- match body[5].getArgs with
    | #[_, v] =>
      let n <- nat v
      if n == 0 || n > maxVersion then failAt v s!"a version is 1 to {maxVersion}"
      pure n
    | _ => pure 0
  let gv ← match body[6].getArgs with
    | #[_, xs] => xs.getArgs.toList.mapM (name · "a given field")
    | _ => pure []
  if gv.eraseDups.length != gv.length then failAt body[6] "a protocol is given each field once"
  let b <- block 0 body[7]
  if (labelsOf b).contains pname then
    failAt body s!"protocol {pname} has a message {pname}; in Lean they would be two declarations with one name, so rename one of them"
  return { name := pname, roles := rs, body := unroll b, version, givens := gv }

/-- A word the grammar matched with `W`: an atom, or an identifier when the word is not reserved. -/
def word (stx : Lean.Syntax) : String := if stx.isAtom then stx.getAtomVal else stx.getId.toString

open Lean (Syntax) in
/-- The items of a deployment block or group (selfhost.session.deployment), with the kinds known so
far and the nodes counted so far. Kinds are declared at the top, before the groups; outside and
islands are the top of the tree and every other group is inside one; a role holds interfaces, each
named once, of a known kind. -/
partial def deployItems (top : Bool) (items : Array Syntax) (kinds : List IfaceKind) (count : Nat) :
    R (List (Node String) × List IfaceKind × Nat) := do
  let mut out : Array (Node String) := #[]
  let mut kinds := kinds
  let mut count := count
  let mut tops : List String := []
  let known (ks : List IfaceKind) : String := ", ".intercalate (ks.map (·.name))
  for it in items do
    count := count + 1
    if count > maxDeployNodes then failAt it s!"a deployment holds at most {maxDeployNodes} groups, roles and interfaces"
    let k := it.getKind
    if k == `LeanFM.Session.Grammar.kindDecl then
      if !top then failAt it "declare a kind at the top of the deployment, before the groups that use it"
      let n ← name it[1] "the kind's name"
      if kinds.any (·.name == n) then failAt it[1] s!"kind {n} is already a kind; known: {known kinds}"
      let b ← name it[3] "the kind it refines"
      let some base := kinds.find? (·.name == b)
        | failAt it[3] s!"kind {b} is not built in or declared before this line; known: {known kinds}"
      let strs (o : Syntax) : List Condition :=
        if o.getNumArgs > 1 then o[1].getArgs.toList.filterMap (·.isStrLit?) |>.map (⟨·⟩) else []
      kinds := kinds ++ [base.refine n (strs it[4]) (strs it[5])]
    else if k == `LeanFM.Session.Grammar.groupDecl then
      let w := word it[0]
      let (gname, place, body) ← if it.getNumArgs == 4 then pure ("outside", Place.outside, it[2])
        else do
          let n ← name it[1] s!"the {w}'s name"
          let p := match w with
            | "island" => Place.island | "datacenter" => .datacenter | "machine" => .machine
            | "replicated" => .replicated | _ => .sharded
          pure (n, p, it[3])
      let atTop := place == .outside || place == .island
      if atTop && !top then failAt it s!"{w} {gname} is inside another group; outside and the islands are the top of the tree"
      if !atTop && top then failAt it s!"{w} {gname} is at the top of the tree; put it inside an island"
      if atTop then
        if tops.contains gname then failAt it s!"{if place == .outside then "outside" else s!"island {gname}"} is written twice"
        tops := gname :: tops
      let (cs, ks, c) ← deployItems false body.getArgs kinds count
      kinds := ks
      count := c
      out := out.push (.group gname place cs)
    else
      let r ← name it[0] "a role"
      if top then failAt it s!"{r} is at the top of the tree; place it inside outside or an island"
      let mut ifs : Array Iface := #[]
      if it.getNumArgs > 2 then
        for i in it[2].getArgs do
          count := count + 1
          if count > maxDeployNodes then failAt i s!"a deployment holds at most {maxDeployNodes} groups, roles and interfaces"
          let n ← name i[1] "the interface's name"
          if ifs.any (·.name == n) then failAt i[1] s!"{r} has two interfaces named {n}"
          let kn ← name i[3] "the interface's kind"
          let some kd := kinds.find? (·.name == kn)
            | failAt i[3] s!"kind {kn} is not built in or declared in this deployment; known: {known kinds}"
          let scope := match word i[0] with
            | "ingress" => Scope.ingress | "peering" => .peering | "internal" => .internal | _ => .local
          ifs := ifs.push ⟨scope, n, kd⟩
      out := out.push (.actor r ifs.toList)
  return (out.toList, kinds, count)

open Lean (Syntax) in
/-- A `deployment Name of P { ... }` block (selfhost.session.deployment), read into its tree. Whether
`P` exists and whether the tree places its roles is checked by the caller and `Deployment.check`. -/
def deploymentDecl (stx : Syntax) : R DeploymentDef := do
  let n ← name stx[1] "the deployment's name"
  let p ← name stx[3] "the protocol it places"
  let (world, _, _) ← deployItems true stx[5].getArgs builtinKinds 0
  if world.isEmpty then failAt stx s!"deployment {n} places no role; put the roles of {p} in outside or an island"
  return { name := n, protocolName := p, world }

open Lean (Syntax) in
/-- A `system` block (selfhost.session.instances), checked against the protocols defined before it
(`defs`: each protocol's name and roles). Every accept names an earlier protocol and gives one
player per role, in the protocol's order: `fresh Role`, naming that role, or a shared instance
declared in the block whose role is that role. -/
def systemDecl (defs : List Def) (stx : Syntax) : R SystemDef := do
  let sname <- name stx[1] "the system's name"
  let mut shared : Array (Prod String (Prod String Bool)) := #[]
  let mut accepts : Array (String × List (Prod Bool String)) := #[]
  for item in stx[3].getArgs do
    if item.getKind == `LeanFM.Session.Grammar.instDecl then
      let n <- name item[1] "the instance's name"
      let r <- name item[3] "the role it plays"
      if shared.any (fun x => x.1 == n) then failAt item s!"instance {n} is declared twice"
      if shared.size >= maxShared then failAt item s!"a system has at most {maxShared} shared instances"
      shared := shared.push (n, r, item[4].getNumArgs > 0)
    else
      let p <- name item[1] "the protocol it accepts"
      if accepts.size >= maxAccepts then failAt item s!"a system has at most {maxAccepts} accepts"
      let some d := latest defs p
        | failAt item s!"accept {p}: no protocol {p} is defined before this system"
      let args := item[3].getArgs.filter (fun x => x.getKind == `LeanFM.Session.Grammar.acceptArg)
      if args.size != d.roles.length then
        failAt item s!"accept {p} needs one player for each of its {d.roles.length} roles ({", ".intercalate d.roles}), not {args.size}"
      let mut players : Array (Prod Bool String) := #[]
      for (a, r) in args.toList.zip d.roles do
        let isFresh := a[0].getNumArgs > 0
        let n <- name a[1] (if isFresh then "a role" else "a shared instance")
        if isFresh then
          if n != r then failAt a s!"accept {p}: the role in this position is {r}, so write fresh {r}"
          if shared.any (fun x => x.1 == n) then failAt a s!"accept {p}: {n} is a shared instance, so it cannot be fresh"
        else
          match shared.find? (fun x => x.1 == n) with
          | none => failAt a s!"accept {p}: {n} is not a shared instance declared before this accept; write fresh {r} for a new {r} per instance"
          | some (_, role, _) =>
            if role != r then failAt a s!"accept {p}: {n} plays {role}, but the role in this position is {r}"
        if players.any (fun x => x.2 == n) then failAt a s!"accept {p}: {n} is given twice"
        players := players.push (isFresh, n)
      accepts := accepts.push (p, players.toList)
  if accepts.isEmpty then failAt stx s!"system {sname} accepts nothing; add accept Protocol (fresh Role, ...);"
  return { name := sname, shared := shared.toList, accepts := accepts.toList }

/-- A requirement name: a nonempty string of at most `maxReqName` characters. -/
def reqName (stx : Lean.Syntax) : R String := do
  let some n := stx.isStrLit? | failAt stx "a requirement name in double quotes"
  if n.trimAscii.isEmpty then failAt stx "a requirement name must not be empty"
  if n.length > maxReqName then failAt stx s!"a requirement name is at most {maxReqName} characters"
  return n

/-- `sorry ["note"]`, `P` or `P ⊨ φ`. -/
def pointerOf (stx : Lean.Syntax) : R Pointer := do
  let a := stx[0]
  if a.isIdent then
    let n := a.getId.toString
    let rest := stx[1]
    if rest.getNumArgs ≥ 2 then
      let φ := rest[1].getAtomVal
      if φ.length > limits.maxBytes then failAt rest "the formula is too long"
      return .formula n φ
    return .protocol n
  let note := if stx[1].getNumArgs ≥ 1 then (stx[1][0].isStrLit?).getD "" else ""
  return .sorry_ note

/-- A `requirements { ... }` block: every name once, every protocol it points at defined in the file. -/
def requirementsDecl (defs : List Def) (body : Lean.Syntax) : R (Array (String × Pointer)) := do
  let mut out : Array (String × Pointer) := #[]
  for e in body[2].getArgs do
    if out.size ≥ maxMapEntries then failAt e s!"a requirements map has at most {maxMapEntries} entries"
    let n ← reqName e[0]
    if out.any (·.1 == n) then failAt e[0] s!"requirement \"{n}\" is in the map twice"
    let p ← pointerOf e[2]
    match p with
    | .protocol q | .formula q _ =>
      unless defs.any (·.name == q) do failAt e[2] s!"requirement \"{n}\": no protocol {q} is defined in this file"
    | .sorry_ _ => pure ()
    out := out.push (n, p)
  return out

/-- An `implementation Name of Module { ... }` block. What it names in the imported file is checked
where the project's files are read (ProjectView), since one file cannot see another. -/
def implementationDecl (body : Lean.Syntax) : R ImplDef := do
  let n ← name body[1] "the implementation's name"
  let of := body[3].getId.toString
  let mut d : ImplDef := { name := n, of }
  for it in body[5].getArgs do
    if d.entries.length + d.hints.length + d.refines.length ≥ maxMapEntries then
      failAt it s!"an implementation has at most {maxMapEntries} entries"
    let a := it[0]
    if a.isStrLit?.isSome then
      let k ← reqName a
      if d.entries.any (·.1 == k) then failAt a s!"\"{k}\" is in implementation {n} twice"
      let ev := it[2]
      let w := ev[0]
      let v ← if w.isAtom && w.getAtomVal == "conform" then
          match ev[1].isStrLit? with | some f => pure (Evidence.conform f) | none => failAt ev "conform \"log path\""
        else if w.isAtom && w.getAtomVal == "test" then
          match ev[1].isStrLit? with | some t => pure (Evidence.test t) | none => failAt ev "test \"name\""
        else pure (Evidence.pointer (← pointerOf w))
      d := { d with entries := d.entries ++ [(k, v)] }
    else if a.isAtom && a.getAtomVal == "hint" then
      let some h := it[1].isStrLit? | failAt it "hint \"text\""
      if h.trimAscii.isEmpty then failAt it "a hint must say something"
      d := { d with hints := d.hints ++ [h] }
    else
      d := { d with refines := d.refines ++ [(it[1].getId.toString, it[3].getId.toString)] }
  return d

open Lean (Syntax) in
/-- Every protocol of a file, earlier ones first; structures and requirements are collected. -/
def fileDefs (stx : Syntax) (allowNoProtocol : Bool := false) : R (List Def) := do
  let mut defs : Array Def := #[]
  let items := stx[1].getArgs
  for item in items do
    let doc := opt item[0] 0
    let body := item[1]
    let k := body.getKind
    if (← get).reqMap.isSome then failAt body "the requirements map is the file's last item"
    if k == `LeanFM.Session.Grammar.requirementsBody then
      let m ← requirementsDecl defs.toList body
      modify fun a => { a with reqMap := some m }
      continue
    if k == `LeanFM.Session.Grammar.implementationBody then
      let d ← implementationDecl body
      if (← get).impls.any (·.name == d.name) then failAt body s!"implementation {d.name} is defined twice"
      modify fun a => { a with impls := a.impls.push d }
      continue
    if k == `LeanFM.Session.Grammar.leanDecl then
      -- a theorem or definition about the messages: Lean checks it when the file is elaborated
      continue
    if k == `LeanFM.Session.Grammar.structureBody then
      if !defs.isEmpty then failAt body "structures come before the protocols that use them"
      if (← get).types.size ≥ Types.maxMessages then failAt body s!"at most {Types.maxMessages} structures"
      let m ← structureDecl doc body
      modify fun a => { a with types := a.types.push m }
    else if k == `LeanFM.Session.Grammar.requireBody then
      if defs.isEmpty then failAt body "requirements follow the protocol they are about"
      let entry ← name body[2] "a message id"
      for c in body[4].getArgs do
        if (← get).requires.size ≥ 16 then failAt c "at most 16 requirements"
        let r ← requirement entry c
        modify fun a => { a with requires := a.requires.push r }
    else if k == `LeanFM.Session.Grammar.deploymentBody then
      let d ← deploymentDecl body
      if (latest defs.toList d.protocolName).isNone then
        failAt body[3] s!"deployment {d.name}: no protocol {d.protocolName} is defined before it"
      if (← get).deployments.any (·.name == d.name) then failAt body s!"deployment {d.name} is defined twice"
      modify fun a => { a with deployments := a.deployments.push d }
    else if k == `LeanFM.Session.Grammar.systemBody then
      if defs.isEmpty then failAt body "a system follows the protocols it accepts"
      let s <- systemDecl defs.toList body
      if (<- get).systems.any (fun x => x.name == s.name) then failAt body s!"system {s.name} is defined twice"
      if defs.any (fun x => x.name == s.name) then failAt body s!"system {s.name} has the name of a protocol"
      modify fun a => { a with systems := a.systems.push s }
    else
      let d ← protocolDef body
      -- versions of one protocol: each numbered, oldest first (selfhost.session.versions)
      match latest defs.toList d.name with
      | none => pure ()
      | some prev =>
        if prev.version == 0 && d.version == 0 then failAt body s!"protocol {d.name} is defined twice"
        if prev.version == 0 || d.version == 0 then
          failAt body s!"protocol {d.name} is defined twice, once without a version; give every version of it a number"
        if d.version <= prev.version then
          failAt body s!"protocol {d.name} version {d.version} follows version {prev.version}; versions go oldest first, each higher than the one before"
      if (← get).systems.any (·.name == d.name) then failAt body s!"protocol {d.name} has the name of a system"
      defs := defs.push d
  if defs.isEmpty && !(← get).impls.isEmpty && !allowNoProtocol then
    failAt stx "this file holds only implementation blocks (selfhost.implementations.map), no protocol; open the protocols of the requirements it implements"
  if defs.isEmpty && (← get).impls.isEmpty then failAt stx "no protocol in the text"
  return defs.toList

/-- Read protocol text with the grammar (Lean's parser, never elaborated): its protocols and what
else it declares. -/
def readText (text : String) : Except String (List Def × Acc) := do
  if text.utf8ByteSize > limits.maxBytes then throw s!"the text is over {limits.maxBytes} bytes"
  let stx ← Grammar.parseFile text
  (fileDefs stx |>.run text).run {}

/-- Read a project file for its requirements map and implementation blocks: as `readText`, except
that a file holding only an implementation block (it uses its requirements' protocols) is accepted. -/
def readMaps (text : String) : Except String (List Def × Acc) := do
  if text.utf8ByteSize > limits.maxBytes then throw s!"the text is over {limits.maxBytes} bytes"
  let stx ← Grammar.parseFile text
  (fileDefs stx true |>.run text).run {}

/-- The text of `text` up to the end of its protocol `name`, so that protocol is the main one the
session tools check (what follows it, a requirements map included, is cut). -/
def textThrough (text name : String) : Except String String := do
  let stx ← Grammar.parseFile text
  let mut stop : Option String.Pos.Raw := none
  for item in stx[1].getArgs do
    let body := item[1]
    if body.getKind == `LeanFM.Session.Grammar.protocolBody && body[1].getId.toString == name then
      stop := body.getTailPos?
  match stop with
  | some p => return String.Pos.Raw.extract text 0 p
  | none => throw s!"no protocol {name} is defined in the file"

open Lean (Syntax) in
/-- Read one annotation value with a grammar parser: a fraction, duration or time expression in an
overlay or a tool argument. -/
def readValue (p : Lean.Parser.Parser) (f : Syntax → R α) (text : String) : Except String α := do
  if text.length > 4096 then throw "annotation text is too long"
  let stx ← Grammar.parseValue p text
  let (v, _) ← (f stx |>.run text).run {}
  return v

def fractionText : String → Except String LeanFM.Overlay.Q := readValue Grammar.frac fraction
def durationText : String → Except String Nat := readValue Grammar.dur duration
def timeExprText : String → Except String Generative.TimeExpr := readValue Grammar.timeExpr timeExpr


/-! ## Building the global type -/


structure Ctx where
  defs   : List Def
  rename : List (String × String)
  roles  : List String
  loops  : List String := []
  depth  : Nat := 0
  inside : List String := []
  /-- where we are, for errors: protocol name and statement number -/
  path   : String

abbrev B := StateT Nat (Except String)

def bfail (c : Ctx) (msg : String) : B α := throw s!"in {c.path}: {msg}"

def role (c : Ctx) (r : String) : B String := do
  let r' := (c.rename.lookup r).getD r
  if !c.roles.contains r' then bfail c s!"{r} is not one of the roles"
  return r'

mutual
partial def build (c : Ctx) (ss : List Stmt) (i : Nat := 0) : B (Global String) := do
  match ss with
  | [] => return .done
  | s :: rest =>
    let here := { c with path := s!"{c.path}, statement {i + 1}" }
    let n ← get
    if n + 1 > limits.maxSteps then bfail here s!"the protocol has more than {limits.maxSteps} steps"
    set (n + 1)
    let next := fun () => build c rest (i + 1)
    match s with
    | .clock _ _ | .obligation _ => next ()
    | .timed _ message => build c (message :: rest) i
    | .valued _ message => build c (message :: rest) i
    -- expanded by unroll at parse time; a body built directly is expanded here too
    | .bounded .. => build c (unroll [s] ++ rest) i
    | .accrue as =>
      for a in as do
        discard <| role here a.payer; discard <| role here a.payee
      next ()
    | .weighted name actor _ bs =>
      if name == "__branch" then bfail here "probability is only allowed inside choice at Role using declared(name)"
      let who ← role here actor
      let gs ← nest here bs
      match Global.decider gs with
      | .ok r => if r != who then bfail here "declared choice actor does not match its decider"
      | .error e => bfail here e
      return Global.andThen (.choice gs) (← next ())
    | .msg id label src dst cause route status media guard =>
      let src' ← role here src
      let dst' ← role here dst
      let g : Option Guard := guard.map fun t => { text := t }
      let i : Interaction String :=
        { id := id, label := label, src := src', dst := dst', cause := cause, route := route,
          status := status, media := media, guard := g }
      return .msg i (← next ())
    | .event label r => return .act (← role here r) label (← next ())
    | .choice bs => return Global.andThen (.choice (← nest here bs)) (← next ())
    | .par bs => return .par (← nest here bs) (← next ())
    | .join k bs =>
      if k == 0 || k > bs.length then bfail here s!"join {k} of {bs.length} branches is out of range"
      return .join k (← nest here bs) (← next ())
    | .loop name body =>
      let b ← deeper { here with loops := name :: c.loops } body
      return Global.andThen (.loop name b) (← next ())
    | .cont name =>
      if !c.loops.contains name then bfail here s!"continue {name} is not inside rec {name}"
      if !rest.isEmpty then bfail here s!"continue {name} must be the last statement of its block"
      return .var name
    | .sessions body => return .sessions (← deeper here body) (← next ())
    | .incl name args binds =>
      let some d := latest c.defs name
        | bfail here s!"include {name}: no protocol {name} is defined before this one"
      if c.inside.contains name then bfail here s!"include {name} includes itself"
      if args.length != d.roles.length then
        bfail here s!"include {name} needs {d.roles.length} roles, not {args.length}"
      -- every given field bound once, and nothing else (selfhost.session.identity.scopes)
      for (g, _) in binds do
        if !d.givens.contains g then
          bfail here s!"include {name} with {g}: {name} is not given {g}{if d.givens.isEmpty then "" else s!"; it is given {", ".intercalate d.givens}"}"
        if (binds.filter (·.1 == g)).length > 1 then bfail here s!"include {name} binds {g} twice"
      for g in d.givens do
        if !binds.any (·.1 == g) then
          bfail here s!"include {name}: {name} is given {g}, so bind it to a field in scope: include {name} {" ".intercalate args} with {g}"
      let mapped ← args.mapM (role here)
      let body ← deeper { here with rename := d.roles.zip mapped, inside := name :: c.inside,
                                    loops := [], path := name } d.body
      return .box (Global.boxName name binds) body (← next ())

partial def deeper (c : Ctx) (body : List Stmt) : B (Global String) := do
  if c.depth + 1 > limits.maxDepth then bfail c s!"statements are nested more than {limits.maxDepth} deep"
  build { c with depth := c.depth + 1 } body

partial def nest (c : Ctx) (bs : List (List Stmt)) : B (List (Global String)) :=
  bs.mapM (deeper c)
end

/-- The protocol a text defines: its last protocol, built, with the number of statements. -/
structure Parsed where
  name   : String
  roles  : List String
  global : Global String
  steps  : Nat
  body : List Stmt := []
  /-- `require per q { ... }` (selfhost.session.sla) -/
  requires : List Generative.Requirement := []
  /-- the message types (selfhost.session.types) -/
  types : Types.Env := []
  /-- session keys: (message id, field path) (selfhost.session.envelope) -/
  keys : List (String × String) := []
  /-- each Link field an include renames, (label, field) to the Fresh field it names
  (selfhost.session.identity.scopes: token bound to sid names the session that minted sid) -/
  linkTargets : List ((String × String) × String) := []
  /-- the given Links that name a parent session (selfhost.session.identity.children) -/
  parentLinks : List (String × String) := []
  /-- sessions bodies whose copies cannot be told apart, each with its fix (selfhost.session.identity.scopes) -/
  identityNotes : List String := []
  /-- the labels of every protocol in the text, the main one's and the earlier ones' -/
  allLabels : List String := []
  /-- the text's `system` blocks (selfhost.session.instances) -/
  systems : List SystemDef := []
  /-- the main protocol's version, 0 when it has none (selfhost.session.versions) -/
  version : Nat := 0
  /-- every protocol with more than one version: each version (number, roles, global type),
  oldest first -/
  versioned : List (Prod String (List (Prod Nat (Prod (List String) (Global String))))) := []
  deriving Inhabited

/-- The global type of the text's main protocol with its body replaced by `f` of it (used to draw
annotations: the body's messages tagged by position, built exactly as the parser builds them). -/
def buildWith (text : String) (body : List Stmt) : Except String (Global String) := do
  let (defs, _) ← readText text
  let main := defs.getLast!
  let ctx : Ctx := { defs := defs.dropLast, rename := [], roles := main.roles, path := main.name,
                     inside := [main.name] }
  let (g, _) ← (build ctx body).run 0
  return g

/-- Lean's keywords: a session-type file is Lean (selfhost.session.lean-syntax), so no protocol, role,
label or message id may be one. -/
def leanWords : List String :=
  [ "abbrev", "at", "attribute", "axiom", "by", "calc", "class", "def", "deriving", "do", "else", "end",
    "example", "export", "extends", "for", "from", "fun", "have", "if", "import", "in", "inductive",
    "instance", "let", "local", "macro", "match", "mutual", "namespace", "noncomputable", "nomatch", "opaque",
    "open", "partial", "private", "protected", "protocol", "require", "return", "scoped", "section",
    "set_option", "show", "structure", "suffices", "syntax", "system", "then", "theorem", "universe", "unsafe",
    "variable", "where", "with", "Prop", "Sort", "Type" ]

/-! ## Session identity in the text (selfhost.session.identity.scopes) -/

/-- The labels of a body's messages and events, its includes' too (the newest protocol of each
name among `defs`; a self-include is refused when the protocol is built). -/
partial def deepLabels (defs : List Def) (fuel : Nat) : List Stmt → List String
  | [] => []
  | s :: rest => (match s with
    | .msg _ label .. => [label]
    | .event label _ => [label]
    | .timed _ m | .valued _ m => deepLabels defs fuel [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap (deepLabels defs fuel)
    | .loop _ b | .sessions b => deepLabels defs fuel b
    | .bounded _ _ b o => deepLabels defs fuel b ++ deepLabels defs fuel o
    | .incl n _ _ => match fuel, latest defs n with
      | f + 1, some d => deepLabels defs f d.body
      | _, _ => []
    | _ => []) ++ deepLabels defs fuel rest

/-- A body's messages as (label, names a cause), its includes' too. -/
partial def deepMsgs (defs : List Def) (fuel : Nat) : List Stmt → List (String × Bool)
  | [] => []
  | s :: rest => (match s with
    | .msg _ label _ _ cause .. => [(label, cause.isSome)]
    | .timed _ m | .valued _ m => deepMsgs defs fuel [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap (deepMsgs defs fuel)
    | .loop _ b | .sessions b => deepMsgs defs fuel b
    | .bounded _ _ b o => deepMsgs defs fuel b ++ deepMsgs defs fuel o
    | .incl n _ _ => match fuel, latest defs n with
      | f + 1, some d => deepMsgs defs f d.body
      | _, _ => []
    | _ => []) ++ deepMsgs defs fuel rest

/-- The messages a body can begin with: (labels, whether it can also begin past them, having sent
no message). -/
partial def firstMsgs (defs : List Def) (fuel : Nat) : List Stmt → List String × Bool
  | [] => ([], true)
  | s :: rest =>
    let more (r : List String × Bool) : List String × Bool :=
      if r.2 then let (xs, e) := firstMsgs defs fuel rest; (r.1 ++ xs, e) else r
    match s with
    | .msg _ label .. => ([label], false)
    | .timed _ m | .valued _ m => more (firstMsgs defs fuel [m])
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs =>
      let rs := bs.map (firstMsgs defs fuel)
      more (rs.flatMap (·.1), rs.isEmpty || rs.any (·.2))
    | .loop _ b | .sessions b => more (firstMsgs defs fuel b)
    | .bounded _ _ b o => more (let (x, e) := firstMsgs defs fuel b; let (y, e2) := firstMsgs defs fuel o; (x ++ y, e || e2))
    | .incl n _ _ => match fuel, latest defs n with
      | f + 1, some d => more (firstMsgs defs f d.body)
      | _, _ => more ([], true)
    | .cont _ => ([], false)
    | _ => firstMsgs defs fuel rest

/-- The fields of a label's structure, or none when it declares none. -/
def fieldsOf (env : Types.Env) (label : String) : List Types.Field :=
  ((env.find? (·.name == label)).map (·.fields)).getD []

/-- Check one protocol's identity text: no given field minted inside it, every include's bindings in
scope and of the given field's type, and every sessions body's copies told apart. `keyIds` are the
message ids of `sessions by` keys. -/
partial def scopeCheck (env : Types.Env) (defs : List Def) (keyIds : List String) (d : Def) : Except String (List String) := do
  let fuel := defs.length + 1
  for l in deepLabels defs 0 d.body do
    for f in fieldsOf env l do
      if d.givens.contains f.name && f.mark == .fresh then
        throw s!"in {d.name}: {l}.{f.name} is Fresh, but {d.name} is given {f.name} by whoever includes it; a given field is minted by the includer, so mark it Link here"
  -- a field in scope: one this protocol is given, or a Fresh or Link field of a label seen so far
  let typeOf (seen : List String) (x : String) : Option Types.Ty := Id.run do
    for l in seen do
      for f in fieldsOf env l do
        if f.name == x && f.mark != .plain then return some f.ty
    for l in deepLabels defs fuel d.body do
      for f in fieldsOf env l do
        if f.name == x && d.givens.contains x then return some f.ty
    return none
  -- walks in order, returning the labels seen and the identity notes
  let rec walk (seen : List String) : List Stmt → Except String (List String × List String)
    | [] => pure (seen, [])
    | s :: rest => do
      let (seen', notes) ← match s with
        | .msg _ label .. | .event label _ => pure (seen ++ [label], [])
        | .timed _ m | .valued _ m => walk seen [m]
        | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => do
          let outs ← bs.mapM (walk seen)
          pure (seen ++ outs.flatMap (·.1), outs.flatMap (·.2))
        | .loop _ b => walk seen b
        | .bounded _ _ b o => do let (a, n1) ← walk seen b; let (c, n2) ← walk a o; pure (c, n1 ++ n2)
        | .sessions b => do
          let (a, n) ← walk seen b
          pure (a, (sessionsNote b).toList ++ n)
        | .incl n _ binds => do
          let some inc := latest defs n | pure (seen, [])
          let incLabels := deepLabels defs fuel inc.body
          for (g, x) in binds do
            let inScope := d.givens.contains x || seen.any fun l => (fieldsOf env l).any fun f => f.name == x
            if !inScope then
              throw s!"in {d.name}: include {n} with {Global.showBinds [(g, x)]}: {x} is not in scope; no message before the include carries {x}, and {d.name} is not given {x}"
            let gTys := (incLabels.flatMap fun l => (fieldsOf env l).filter (·.name == g)).map (·.ty)
            match typeOf seen x, gTys.head? with
            | some tx, some tg =>
              if tx != tg then
                throw s!"in {d.name}: include {n} with {Global.showBinds [(g, x)]}: {n}'s {g} is {tg.render}, but {x} is {tx.render}"
            | _, _ => pure ()
          pure (seen ++ incLabels, [])
        | _ => pure (seen, [])
      let (final, more) ← walk seen' rest
      pure (final, notes ++ more)
  return (← walk [] d.body).2
where
  /-- Why a sessions body's copies cannot be told apart, or none when they can. -/
  sessionsNote (b : List Stmt) : Option String := Id.run do
    let fuel := defs.length + 1
    let msgs := deepMsgs defs fuel b
    if msgs.length ≤ 1 then return none
    if (declaredIds b).any keyIds.contains then return none
    let (firsts, _) := firstMsgs defs fuel b
    -- the ids a copy mints itself; a Link to one of them places a message in its copy
    let minted := ((msgs.flatMap fun (l, _) => (fieldsOf env l).filter (·.mark == .fresh)).map (·.name)).eraseDups
    let placed (l : String) (c : Bool) : Bool :=
      c || firsts.contains l || (fieldsOf env l).any fun f => f.mark == .link && minted.contains f.name
    match msgs.find? fun (l, c) => !placed l c with
    | none => return none
    | some (l, _) =>
      return some s!"in {d.name}: the copies of sessions \{ ... } run at once and cannot be told apart: {l} names no cause and carries no Link to an id the copy mints; mint one on an answer (orderId : Fresh String) and carry it on {l} as a Link, name the message {l} answers as its cause, or write sessions by"

/- Each Link field an include binds, renamed or under its own name, through every level of include
from `d` with `ren` (given field to the field it stands for in the main protocol): (label, field) to
that field. These are the given Links: they name the parent session (selfhost.session.identity.children). -/
/-- The fewest sessions blocks a protocol body enters before a message of it mints field `x`
(Fresh), not looking into includes. -/
partial def freshDepth (env : Types.Env) (x : String) (depth : Nat := 0) : List Stmt → Option Nat
  | [] => none
  | s :: rest =>
    let here : Option Nat := match s with
      | .msg _ label .. => if (fieldsOf env label).any (fun f => f.name == x && f.mark == .fresh) then some depth else none
      | .timed _ m | .valued _ m => freshDepth env x depth [m]
      | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => (bs.filterMap (freshDepth env x depth)).min?
      | .loop _ b => freshDepth env x depth b
      | .sessions b => freshDepth env x (depth + 1) b
      | .bounded _ _ b o => [freshDepth env x depth b, freshDepth env x depth o].filterMap id |>.min?
      | _ => none
    match here, freshDepth env x depth rest with
    | some a, some b => some (min a b)
    | some a, none => some a
    | none, b => b

partial def linkTargetsOfDepth (env : Types.Env) (defs : List Def) (fuel : Nat) (ren : List (String × String × Nat)) (d : Def) :
    List ((String × String) × String × Bool) :=
  -- depth: the sessions blocks entered so far (through includes); each binding remembers the depth
  -- its value was minted at: where the includer mints it, or its own binding when it is given
  let rec go (fuel depth base : Nat) (cur : List Stmt) (ren : List (String × String × Nat)) : List Stmt → List ((String × String) × String × Bool)
    | [] => []
    | s :: rest => (match s with
      | .msg _ label .. =>
        ((fieldsOf env label).filter (·.mark == .link)).filterMap fun f =>
          (ren.lookup f.name).map fun (t, minted) => ((label, f.name), t, depth > minted)
      | .timed _ m | .valued _ m => go fuel depth base cur ren [m]
      | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap (go fuel depth base cur ren)
      | .loop _ b => go fuel depth base cur ren b
      | .sessions b => go fuel (depth + 1) base cur ren b
      | .bounded _ _ b o => go fuel depth base cur ren b ++ go fuel depth base cur ren o
      | .incl n _ binds => match fuel, latest defs n with
        | f + 1, some inc =>
          -- a field the includer neither mints nor is given is a reference read from another session
          -- (a gameId picked from a listing): its value was minted outside the includer's body
          let bound := binds.map fun (g, x) => (g, (ren.lookup x).getD (x, base + (freshDepth env x 0 cur).getD 0))
          go f depth depth inc.body bound inc.body
        | _, _ => []
      | _ => []) ++ go fuel depth base cur ren rest
  go fuel 0 0 d.body ren d.body

/-- The given Links as (label, field) to the field they stand for (selfhost.session.identity.scopes). -/
def linkTargetsOf (env : Types.Env) (defs : List Def) (fuel : Nat) (ren : List (String × String)) (d : Def) :
    List ((String × String) × String) :=
  (linkTargetsOfDepth env defs fuel (ren.map fun (g, x) => (g, x, 0)) d).map fun (k, t, _) => (k, t)

/-- Read protocol text. `types`, when given, are the message types from the protocol's .proto
(selfhost.session.proto); the text may then not declare structures of its own. -/
def parse (text : String) (types : Option Types.Env := none) : Except String Parsed := do
  let (defs, st) ← readText text
  let main := defs.getLast!
  let earlier := defs.dropLast
  let ctx : Ctx := { defs := earlier, rename := [], roles := main.roles, path := main.name,
                     inside := [main.name] }
  let (g, n) ← (build ctx main.body).run 0
  for d in defs do
    for (what, x) in [("protocol", d.name)] ++ d.roles.map (("role", ·)) ++ (labelsOf d.body).map (("label", ·)) ++
        (declaredIds d.body).map (("message id", ·)) do
      if leanWords.contains x then
        throw s!"in {d.name}: the {what} {x} is a Lean keyword; a session-type file is Lean, so choose another name"
  -- requirements name a message id of the main protocol and labels that occur in the text
  let ids := declaredIds main.body
  let labels := defs.flatMap (fun d => labelsOf d.body)
  for r in st.requires do
    if !ids.contains r.entry then
      throw s!"require per {r.entry}: {r.entry} is not a message id of protocol {main.name}; give the message an id, as in {r.entry}: Request from A to B;"
    for t in r.targets do
      if !labels.contains t then throw s!"requirement '{r.text}': {t} is not a message or event of the protocol"
  -- message types, and every where condition typed against them before anything runs
  let env ← match types with
    | some env =>
      if !st.types.isEmpty then throw "the message types come from the .proto, so the text may not declare structures as well"
      pure env
    | none => pure st.types.toList
  Types.check env (defs.flatMap (·.givens))
  -- a message with a media type carries its body as bytes of that type, so its fields travel
  -- outside the body, and a label means one media type everywhere (selfhost.session.openapi)
  let msgs := defs.flatMap fun d => mediaOf d.body
  for (label, media) in msgs do
    if let some (_, other) := msgs.find? (fun (l, m) => l == label && m != media) then
      throw s!"{label} is sent with two media types ({media.getD "application/json"} and {other.getD "application/json"}); give every {label} the same media"
    if media.isNone && ((Types.find env label).map Types.readsSize).getD false then
      throw s!"{label}: its constraints read size, the length of a raw body, but {label} is sent without a media type; send it with media \"type/subtype\" or read a field"
    if let some m := media then
      for f in Types.fieldsOf env label do
        if f.place == .body then
          throw s!"{label}.{f.name}: {label} is sent as {m}, so its body is the bytes; make {f.name} a Header, PathParam or QueryParam"
  -- session identity in the text (selfhost.session.identity.scopes)
  let keyIds := st.keys.toList.map (·.1)
  let mut identityNotes : List String := []
  for i in [0:defs.length] do
    identityNotes := identityNotes ++ (← scopeCheck env (defs.take i) keyIds defs[i]!)
  let targets := (linkTargetsOf env earlier (defs.length + 1) [] main).foldl
    (fun acc (k, t) => if acc.any (·.1 == k) then acc else acc ++ [(k, t)]) []
  -- the given Links that cross a sessions block entered after their value was minted name a parent
  -- (selfhost.session.identity.children)
  let parentLinks := ((linkTargetsOfDepth env earlier (defs.length + 1) [] main).filterMap fun (k, _, p) => if p then some k else none).eraseDups
  for d in defs do
    let ids := idLabels d.body
    -- an id not in scope (bound later in a loop, say) falls back to every label it has
    let everywhere (x : String) : List String := ((ids.filter (·.1 == x)).map (·.2)).eraseDups
    for (label, text, scope) in (scopedConditions [] d.body).1 do
      let labelsOf (x : String) : List String := (scope.lookup x).getD (everywhere x)
      match Types.checkCondition env labelsOf text with
      | .ok _ => pure ()
      | .error e => throw s!"in {d.name}, {label}: {e}"
  -- a session key is a Nat or String field of its message (a secret one too: the _secr mark is a
  -- question protocol tests ask, not a rule)
  let allIds := defs.flatMap fun d => idLabels d.body
  for (x, f) in st.keys do
    let some (_, label) := allIds.find? (·.1 == x)
      | throw s!"sessions by {x}.{f}: {x} is not a message id of the text"
    match Types.leaf env label (f.splitOn ".") with
    | .ok .nat | .ok .str => pure ()
    | .ok t => throw s!"sessions by {x}.{f}: a session key is a Nat or String field, and {label}.{f} is {t.render}"
    | .error e => throw s!"sessions by {x}.{f}: {e}"
  -- every version of every versioned protocol, each built against the protocols before it
  let builtAt (i : Nat) : Except String (Global String) := do
    let d := defs[i]!
    let ctx : Ctx := { defs := defs.take i, rename := [], roles := d.roles, path := d.name, inside := [d.name] }
    let (gi, _) <- (build ctx d.body).run 0
    pure gi
  let names := ((defs.filter fun d => d.version > 0).map fun d => d.name).eraseDups
  let versioned <- names.filterMapM fun nm => do
    let idx := (List.range defs.length).filter fun i => defs[i]!.name == nm
    if idx.length < 2 then return none
    let vs <- idx.mapM fun i => do
      let gi <- if i + 1 == defs.length then pure g else builtAt i
      pure (defs[i]!.version, defs[i]!.roles, gi)
    return some (nm, vs)
  return { name := main.name, roles := main.roles, global := g, steps := n, body := main.body,
           requires := st.requires.toList, types := env, keys := st.keys.toList, linkTargets := targets, parentLinks, identityNotes,
           allLabels := (defs.flatMap fun d => labelsOf d.body).eraseDups, systems := st.systems.toList,
           version := main.version, versioned }

/-! ## Writing -/

def isIdStart (c : Char) : Bool := c.isAlpha || c == '_' || c.toNat > 127
def isIdRest (c : Char) : Bool := c.isAlphanum || c == '_' || c == '\'' || c == '!' || c == '?' || c.toNat > 127


def isPlainIdent (s : String) : Bool :=
  match s.toList with
  | c :: cs => isIdStart c && c != '«' && cs.all isIdRest
  | [] => false

def showIdent (s : String) : String :=
  if isPlainIdent s then s else "«" ++ s.replace "»" "›" ++ "»"

def showString (s : String) : String :=
  "\"" ++ String.join (s.toList.map fun c =>
    if c == '"' then "\\\"" else if c == '\\' then "\\\\" else c.toString) ++ "\""

def showTime (t : Generative.TimeExpr) : String :=
  let base := match t.clock with
    | some c => showIdent c
    | none => match t.refs with
      | [r] => "time(" ++ showIdent r ++ ")"
      | rs => "max(" ++ ", ".intercalate (rs.map (fun r => "time(" ++ showIdent r ++ ")")) ++ ")"
  base ++ " + sample { " ++ " ".intercalate (t.offsets.map fun (d,q) => s!"{d} ms : {q.text};") ++ " }"

def showDelay (os : List (Nat × LeanFM.Overlay.Q)) : String :=
  "sample { " ++ " ".intercalate (os.map fun (d,q) => s!"{d} ms : {q.text};") ++ " }"

/-- ` at T` or ` after D`, as the parser reads them. -/
def timeText (t : Generative.TimeExpr) : String :=
  match t.period with
  | some d => s!" at next {d} ms"
  | none => if t.relative then " after " ++ showDelay t.offsets else " at " ++ showTime t

def showAmount (a : Generative.Amount) : String :=
  match a.outcomes with
  | [(n, _)] => s!"{if a.reverse then "-" else ""}{n} {showIdent a.unit}"
  | os => "sample { " ++ " ".intercalate (os.map fun (n,q) => s!"{n} {showIdent a.unit} : {q.text};") ++ " }"

mutual
partial def writeStmts (ind : String) (ss : List Stmt) : List String := ss.flatMap (writeStmt ind)

partial def writeBranches (ind kw sep : String) (bs : List (List Stmt)) : List String :=
  match bs with
  | [] => []
  | b :: rest =>
    [ind ++ kw ++ " {"] ++ writeStmts (ind ++ "  ") b ++
      (rest.flatMap fun b => [ind ++ "} " ++ sep ++ " {"] ++ writeStmts (ind ++ "  ") b) ++ [ind ++ "}"]

/-- A message with its amount and time, in the order the parser reads them. -/
partial def writeAnnotated (ind : String) (t : Option Generative.TimeExpr) (as : List Generative.Amount) : Stmt → List String
  | .timed t' m => writeAnnotated ind (some t') as m
  | .valued a' m => writeAnnotated ind t (a' :: as) m
  | .msg id label src dst cause route status media guard =>
    (writeStmt ind (.msg id label src dst cause route status media none)).map fun line =>
      (line.dropEnd 1).toString ++
        (match as with
         | [] => ""
         | [a] => if a.reverse then " amount { " ++ showAmount a ++ "; }" else " amount " ++ showAmount a
         | _ => " amount { " ++ " ".intercalate (as.map fun a => showAmount a ++ ";") ++ " }") ++
        (t.map timeText).getD "" ++
        (guard.map (" where " ++ ·)).getD "" ++ ";"
  | .event label r => [ind ++ showIdent label ++ " at " ++ showIdent r ++ (t.map timeText).getD "" ++ ";"]
  | _ => []

partial def writeStmt (ind : String) : Stmt → List String
  | .bounded name n body other => [ind ++ s!"rec {showIdent name} at most {n} \u007b"] ++ writeStmts (ind ++ "  ") body ++
      [ind ++ "} otherwise {"] ++ writeStmts (ind ++ "  ") other ++ [ind ++ "}"]
  | .clock name refs => [ind ++ "clock " ++ showIdent name ++ " = " ++
      (if refs.length == 1 then "time(" ++ showIdent refs.head! ++ ")" else
       "max(" ++ ", ".intercalate (refs.map (fun r => "time(" ++ showIdent r ++ ")")) ++ ")") ++ ";"]
  | .obligation o => [ind ++ s!"obligation {showIdent o.name} on {showIdent o.actor} \{ trigger {showIdent o.clock}; require " ++
      " or ".intercalate (o.labels.map showIdent) ++ s!" within {o.withinMs} ms; on breach record {showIdent o.breach}" ++
      (match o.penalty with | some p => s!" pays {p.quantity} {showIdent p.unit} to {showIdent p.payee}" | none => "") ++ "; }"]
  | .timed t m => writeAnnotated ind (some t) [] m
  | .valued a m => writeAnnotated ind none [a] m
  | .weighted name actor weights bs =>
    let decorated := bs.zipIdx |>.map fun (b,i) =>
      (if weights.isEmpty then [] else [ind ++ "  probability " ++ (weights[i]!).text ++ ":"]) ++ writeStmts (ind ++ "  ") b
    [ind ++ "choice at " ++ showIdent actor ++ " using declared(" ++ showString name ++ ") {"] ++
      List.flatten (decorated.zipIdx |>.map fun (lines,i) => (if i == 0 then [] else [ind ++ "} or {"]) ++ lines) ++ [ind ++ "}"]
  | .msg id label src dst cause route status media guard =>
    [ind ++ (match id with | some i => showIdent i ++ ": " | none => "") ++ showIdent label ++
      " from " ++ showIdent src ++ " to " ++ showIdent dst ++
      (match cause with | some c => " cause " ++ showIdent c | none => "") ++
      (match route with | some r => " route " ++ showString r | none => "") ++
      (match status with | some s => s!" status {s}" | none => "") ++
      (match media with | some m => " media " ++ showString m | none => "") ++
      (match guard with | some g => " where " ++ g | none => "") ++ ";"]
  | .event label r => [ind ++ showIdent label ++ " at " ++ showIdent r ++ ";"]
  | .accrue as =>
    match as with
    | [a] => [ind ++ s!"accrue {a.quantity} {showIdent a.unit} per {a.periodMs} ms from {showIdent a.payer} to {showIdent a.payee};"]
    | a :: _ =>
      -- the first entry fixes the direction; entries flowing the other way are negative
      [ind ++ "accrue { " ++ " ".intercalate (as.map fun x =>
        s!"{if x.payer == a.payer then "" else "-"}{x.quantity} {showIdent x.unit} per {x.periodMs} ms;") ++
        s!" }} from {showIdent a.payer} to {showIdent a.payee};"]
    | [] => []
  | .choice bs => writeBranches ind "choice" "or" bs
  | .par bs => writeBranches ind "par" "and" bs
  | .join k bs => writeBranches ind s!"join {k} of" "and" bs
  | .loop n body => [ind ++ "rec " ++ showIdent n ++ " {"] ++ writeStmts (ind ++ "  ") body ++ [ind ++ "}"]
  | .cont n => [ind ++ "continue " ++ showIdent n ++ ";"]
  | .sessions body => [ind ++ "sessions {"] ++ writeStmts (ind ++ "  ") body ++ [ind ++ "}"]
  | .incl n args binds => [ind ++ "include " ++ showIdent n ++ String.join (args.map (" " ++ showIdent ·)) ++
      (if binds.isEmpty then "" else " with " ++ ", ".intercalate (binds.map fun (g, x) =>
        if g == x then showIdent g else showIdent g ++ " = " ++ showIdent x)) ++ ";"]
end

def Def.write (d : Def) : String :=
  "\n".intercalate (s!"protocol {showIdent d.name} ({", ".intercalate (d.roles.map showIdent)}){if d.version == 0 then "" else s!" version {d.version}"}{if d.givens.isEmpty then "" else " given " ++ " ".intercalate (d.givens.map showIdent)} \{" ::
    writeStmts "  " d.body ++ ["}"])

/-- Protocol text for definitions, earlier ones first. -/
def write (defs : List Def) : String := "\n\n".intercalate (defs.map Def.write)

/-- A message type as the parser reads it. -/
def writeType (m : Types.Message) : String :=
  let ctor := if m.ctor.isEmpty then [] else [s!"  {if m.privateCtor then "private " else ""}{m.ctor} ::"]
  let body := ctor ++ m.fields.map (fun f => s!"  {f.name} : {f.render}") ++ m.constraints.map (fun c => s!"  {c.name} : {c.text}")
  (if m.doc.isEmpty then "" else s!"/-- {m.doc} -/\n") ++ "structure " ++ m.name ++
    (if body.isEmpty then "" else " where\n" ++ "\n".intercalate body)

/-- The header that makes protocol text a Lean file (selfhost.session.lean-syntax). -/
def header : String := "import LeanFM.Session.Syntax\n\n"

/-- Protocol text for message types and definitions: a whole Lean file. -/
def writeAll (types : Types.Env) (defs : List Def) : String :=
  header ++ "\n\n".intercalate (types.map writeType ++ defs.map Def.write)

end LeanFM.Session.Text
