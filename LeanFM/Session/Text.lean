import LeanFM.Session.Global
import LeanFM.Session.GenerativeTypes
import LeanFM.Session.Types
import LeanFM.Session.Grammar

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
      (status : Option Nat) (guard : Option String)
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
  | incl (name : String) (args : List String)
  deriving Inhabited

structure Def where
  name  : String
  roles : List String
  body  : List Stmt
  deriving Inhabited

/-- A `system` block as written (selfhost.session.instances): shared instances (name, role,
serial) and accepts (protocol, players: `fresh Role` as `(true, Role)`, an instance as
`(false, name)`). -/
structure SystemDef where
  name    : String
  shared  : List (Prod String (Prod String Bool))
  accepts : List (Prod String (List (Prod Bool String)))
  deriving Inhabited, Repr

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

/-- Every message's label and where condition in a body. -/
partial def conditions : List Stmt → List (String × String)
  | [] => []
  | s :: rest => (match s with
    | .msg _ label _ _ _ _ _ (some g) => [(label, g)]
    | .timed _ m | .valued _ m => conditions [m]
    | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap conditions
    | .loop _ b | .sessions b => conditions b
    | .bounded _ _ b o => conditions b ++ conditions o
    | _ => []) ++ conditions rest

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
    | .msg id l a b cause route status guard => .msg (id.map r) l a b (cause.map r) route status (guard.map rg)
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

/-- Reading: the source (for positions and requirement texts) and what has been collected. -/
abbrev R := ReaderT String (StateT Acc (Except String))

open Lean (Syntax Name) in
section
variable (stx : Syntax)

def lineCol (src : String) (pos : String.Pos.Raw) : Nat × Nat := Id.run do
  let mut line := 1
  let mut col := 1
  let mut i : String.Pos.Raw := 0
  while i.byteIdx < pos.byteIdx && !src.atEnd i do
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
  let as ← match opt stx[9] 0 with | some a => amounts a | none => pure []
  let time ← match opt stx[10] 0 with | some t => pure (some (← timing t)) | none => pure none
  let guard ← match opt stx[11] 1 with | some c => pure (some (← condText c)) | none => pure none
  let message := Stmt.msg id label src dst cause route status guard
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
  | `LeanFM.Session.Grammar.incl => return .incl (← name stx[1] "a protocol") (← stx[2].getArgs.toList.mapM (name · "a role name"))
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
  for f in ofKind `LeanFM.Session.Grammar.field stx[2] do
    let ft := f[2]
    let tn ← name ft[0] "a type, such as Nat, String or a structure's name"
    let ty ← if ft[1].isIdent then do
        let inner ← name ft[1] s!"the type the {tn} holds"
        if ["List", "Array", "Option"].contains inner then
          failAt ft s!"{tn} holds one plain type, such as {tn} Nat (protobuf has no {tn} of a List or Option)"
        pure ((if tn == "Option" then Types.Ty.opt else Types.Ty.list) (Types.Ty.ofName inner))
      else pure (Types.Ty.ofName tn)
    for n in f[0].getArgs do
      fields := fields.push { name := ← name n "a field name", ty }
  if fields.size > Types.maxFieldsPer then failAt stx s!"structure {mname} has more than {Types.maxFieldsPer} fields"
  let docText := match doc with
    | some d =>
      let raw := ((d[1].getAtomVal.dropEnd 2).toString)
      " ".intercalate ((raw.split Char.isWhitespace).toList.map (·.toString) |>.filter (· != ""))
    | none => ""
  return { name := mname, fields := fields.toList, doc := docText }

open Lean (Syntax) in
/-- One protocol (`protocolBody`): its name, roles and statements, bounded loops unrolled. -/
def protocolDef (body : Syntax) : R Def := do
  let pname ← name body[1] "the protocol's name"
  let rs ← (body[3].getArgs.filter (·.isIdent)).toList.mapM (name · "a role")
  if rs.isEmpty then failAt body "a protocol needs at least one role"
  if rs.length > limits.maxRoles then failAt body s!"a protocol has at most {limits.maxRoles} roles"
  if rs.eraseDups.length != rs.length then failAt body "role names must be distinct"
  let b ← block 0 body[5]
  if (labelsOf b).contains pname then
    failAt body s!"protocol {pname} has a message {pname}; in Lean they would be two declarations with one name, so rename one of them"
  return { name := pname, roles := rs, body := unroll b }

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
      let some d := defs.find? (fun x => x.name == p)
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

open Lean (Syntax) in
/-- Every protocol of a file, earlier ones first; structures and requirements are collected. -/
def fileDefs (stx : Syntax) : R (List Def) := do
  let mut defs : Array Def := #[]
  for item in stx[1].getArgs do
    let doc := opt item[0] 0
    let body := item[1]
    let k := body.getKind
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
    else if k == `LeanFM.Session.Grammar.systemBody then
      if defs.isEmpty then failAt body "a system follows the protocols it accepts"
      let s <- systemDecl defs.toList body
      if (<- get).systems.any (fun x => x.name == s.name) then failAt body s!"system {s.name} is defined twice"
      if defs.any (fun x => x.name == s.name) then failAt body s!"system {s.name} has the name of a protocol"
      modify fun a => { a with systems := a.systems.push s }
    else
      let d ← protocolDef body
      if defs.any (·.name == d.name) then failAt body s!"protocol {d.name} is defined twice"
      if (← get).systems.any (·.name == d.name) then failAt body s!"protocol {d.name} has the name of a system"
      defs := defs.push d
  if defs.isEmpty then failAt stx "no protocol in the text"
  return defs.toList

/-- Read protocol text with the grammar (Lean's parser, never elaborated): its protocols and what
else it declares. -/
def readText (text : String) : Except String (List Def × Acc) := do
  if text.utf8ByteSize > limits.maxBytes then throw s!"the text is over {limits.maxBytes} bytes"
  let stx ← Grammar.parseFile text
  (fileDefs stx |>.run text).run {}

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
    | .msg id label src dst cause route status guard =>
      let src' ← role here src
      let dst' ← role here dst
      let g : Option Guard := guard.map fun t => { text := t }
      let i : Interaction String :=
        { id := id, label := label, src := src', dst := dst', cause := cause, route := route,
          status := status, guard := g }
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
    | .incl name args =>
      let some d := c.defs.find? (·.name == name)
        | bfail here s!"include {name}: no protocol {name} is defined before this one"
      if c.inside.contains name then bfail here s!"include {name} includes itself"
      if args.length != d.roles.length then
        bfail here s!"include {name} needs {d.roles.length} roles, not {args.length}"
      let mapped ← args.mapM (role here)
      let body ← deeper { here with rename := d.roles.zip mapped, inside := name :: c.inside,
                                    loops := [], path := name } d.body
      return .box name body (← next ())

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
  /-- the labels of every protocol in the text, the main one's and the earlier ones' -/
  allLabels : List String := []
  /-- the text's `system` blocks (selfhost.session.instances) -/
  systems : List SystemDef := []
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
  Types.check env
  for d in defs do
    let ids := idLabels d.body
    let labelsOf (x : String) : List String := ((ids.filter (·.1 == x)).map (·.2)).eraseDups
    for (label, text) in conditions d.body do
      match Types.checkCondition env labelsOf text with
      | .ok _ => pure ()
      | .error e => throw s!"in {d.name}, {label}: {e}"
  -- a session key is a Nat or String field of its message, and not a secret
  let allIds := defs.flatMap fun d => idLabels d.body
  for (x, f) in st.keys do
    let some (_, label) := allIds.find? (·.1 == x)
      | throw s!"sessions by {x}.{f}: {x} is not a message id of the text"
    if (f.splitOn ".").any Types.isSecret then throw s!"sessions by {x}.{f}: a session key is logged with every event, so it may not be a secret"
    match Types.leaf env label (f.splitOn ".") with
    | .ok .nat | .ok .str => pure ()
    | .ok t => throw s!"sessions by {x}.{f}: a session key is a Nat or String field, and {label}.{f} is {t.render}"
    | .error e => throw s!"sessions by {x}.{f}: {e}"
  return { name := main.name, roles := main.roles, global := g, steps := n, body := main.body,
           requires := st.requires.toList, types := env, keys := st.keys.toList,
           allLabels := (defs.flatMap fun d => labelsOf d.body).eraseDups, systems := st.systems.toList }

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
  | .msg id label src dst cause route status guard =>
    (writeStmt ind (.msg id label src dst cause route status none)).map fun line =>
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
  | .msg id label src dst cause route status guard =>
    [ind ++ (match id with | some i => showIdent i ++ ": " | none => "") ++ showIdent label ++
      " from " ++ showIdent src ++ " to " ++ showIdent dst ++
      (match cause with | some c => " cause " ++ showIdent c | none => "") ++
      (match route with | some r => " route " ++ showString r | none => "") ++
      (match status with | some s => s!" status {s}" | none => "") ++
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
  | .incl n args => [ind ++ "include " ++ showIdent n ++ String.join (args.map (" " ++ showIdent ·)) ++ ";"]
end

def Def.write (d : Def) : String :=
  "\n".intercalate (s!"protocol {showIdent d.name} ({", ".intercalate (d.roles.map showIdent)}) \{" ::
    writeStmts "  " d.body ++ ["}"])

/-- Protocol text for definitions, earlier ones first. -/
def write (defs : List Def) : String := "\n\n".intercalate (defs.map Def.write)

/-- A message type as the parser reads it. -/
def writeType (m : Types.Message) : String :=
  (if m.doc.isEmpty then "" else s!"/-- {m.doc} -/\n") ++ "structure " ++ m.name ++
    (if m.fields.isEmpty then "" else " where\n" ++ "\n".intercalate (m.fields.map fun f => s!"  {f.name} : {f.ty.render}"))

/-- The header that makes protocol text a Lean file (selfhost.session.lean-syntax). -/
def header : String := "import LeanFM.Session.Syntax\n\n"

/-- Protocol text for message types and definitions: a whole Lean file. -/
def writeAll (types : Types.Env) (defs : List Def) : String :=
  header ++ "\n\n".intercalate (types.map writeType ++ defs.map Def.write)

end LeanFM.Session.Text
