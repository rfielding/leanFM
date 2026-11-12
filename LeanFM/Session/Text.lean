import LeanFM.Session.Global
import LeanFM.Session.GenerativeTypes

/-!
# Protocol text: LeanFM's `protocol` syntax, read without elaborating it (clause selfhost.mcp.session.tools)

The `protocol` command is a Lean macro, so the only way to read it inside Lean would be to elaborate
Lean, which can run code. This module reads exactly the protocol grammar and nothing else, and
builds the same `Global String` the command builds:

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
earlier one with its roles renamed in order. Labels and roles are identifiers (`«with spaces»` is
allowed). A `where` condition is kept as text, never evaluated. `--` and `/- -/` comments and doc
comments are skipped. Errors give the line and column.

Negative requirements: no text is elaborated or run; a statement after `continue`, an unknown role,
an undefined or recursive include, a repeated protocol name, unbalanced braces, an unterminated
string or comment, and anything over the limits are errors, not guesses.
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

structure Limits where
  maxBytes   : Nat := 65536
  maxSteps   : Nat := 200
  maxDepth   : Nat := 24
  maxRoles   : Nat := 12
  maxString  : Nat := 200
  maxBranches : Nat := 16

def limits : Limits := {}

/-! ## Reading -/

structure St where
  pos : Nat := 0
  depth : Nat := 0
  /-- `require per q { ... }` clauses after the protocols (selfhost.session.sla) -/
  requires : Array Generative.Requirement := #[]

abbrev P := ReaderT (Array Char) (StateT St (Except String))

def lineCol (src : Array Char) (pos : Nat) : Nat × Nat := Id.run do
  let mut line := 1
  let mut col := 1
  for i in [0:min pos src.size] do
    if src[i]! == '\n' then line := line + 1; col := 1 else col := col + 1
  return (line, col)

def failAt (pos : Nat) (msg : String) : P α := do
  let (l, c) := lineCol (← read) pos
  throw s!"line {l}, column {c}: {msg}"

def fail (msg : String) : P α := do failAt (← get).pos msg

def peekAt (k : Nat) : P (Option Char) := do return (← read)[(← get).pos + k]?
def peek : P (Option Char) := peekAt 0
def bump (n : Nat := 1) : P Unit := modify fun s => { s with pos := s.pos + n }

/-- Skip whitespace, `--` line comments and nested `/- -/` block comments (doc comments too). -/
partial def skip : P Unit := do
  match ← peek with
  | some c =>
    if c.isWhitespace then bump; skip
    else if c == '-' && (← peekAt 1) == some '-' then
      let rec toEol : P Unit := do
        match ← peek with
        | some '\n' | none => pure ()
        | some _ => bump; toEol
      toEol; skip
    else if c == '/' && (← peekAt 1) == some '-' then
      let start := (← get).pos
      bump 2
      let rec block (depth : Nat) : P Unit := do
        match ← peek, ← peekAt 1 with
        | none, _ => failAt start "this comment is never closed"
        | some '-', some '/' => bump 2; if depth > 0 then block (depth - 1)
        | some '/', some '-' => bump 2; block (depth + 1)
        | some _, _ => bump; block depth
      block 0; skip
    else pure ()
  | none => pure ()

def isIdStart (c : Char) : Bool := c.isAlpha || c == '_' || c.toNat > 127
def isIdRest (c : Char) : Bool := c.isAlphanum || c == '_' || c == '\'' || c == '!' || c == '?' || c.toNat > 127

def checkLen (start : Nat) (what s : String) : P String := do
  if s.isEmpty then failAt start s!"{what} is empty"
  if s.length > limits.maxString then failAt start s!"{what} is longer than {limits.maxString} characters"
  return s

/-- An identifier, or `none` without moving. -/
partial def ident? : P (Option String) := do
  skip
  let start := (← get).pos
  match ← peek with
  | some '«' =>
    bump
    let rec quoted (acc : String) : P String := do
      match ← peek with
      | some '»' => bump; return acc
      | some '\n' | none => failAt start "«name» is never closed"
      | some c => bump; quoted (acc.push c)
    return some (← checkLen start "name" (← quoted ""))
  | some c =>
    if !isIdStart c then return none
    let rec plain (acc : String) : P String := do
      match ← peek with
      | some c => if isIdRest c then bump; plain (acc.push c) else return acc
      | none => return acc
    return some (← checkLen start "name" (← plain ""))
  | none => return none

def ident (what : String) : P String := do
  match ← ident? with
  | some s => return s
  | none => fail s!"expected {what}"

/-- Look at the next identifier without consuming it. -/
def peekIdent : P (Option String) := do
  let s ← get
  let r ← ident?
  set s
  return r

def nextChar : P (Option Char) := do skip; peek

def keyword? (w : String) : P Bool := do
  let s ← get
  match ← ident? with
  | some x => if x == w then return true else set s; return false
  | none => set s; return false

def sym? (c : Char) : P Bool := do
  skip
  if (← peek) == some c then bump; return true else return false

def sym (c : Char) (what : String := s!"'{c}'") : P Unit := do
  if !(← sym? c) then fail s!"expected {what}"

partial def boundedNumber (maxDigits : Nat) : P Nat := do
  skip
  let start := (← get).pos
  let rec go (acc : Nat) (n : Nat) : P (Nat × Nat) := do
    match ← peek with
    | some c => if c.isDigit then bump; go (acc * 10 + (c.toNat - '0'.toNat)) (n + 1) else return (acc, n)
    | none => return (acc, n)
  let (v, n) ← go 0 0
  if n == 0 then failAt start "expected a number"
  if n > maxDigits then failAt start "this number is too large"
  return v

def number : P Nat := boundedNumber 6

partial def stringLit : P String := do
  skip
  let start := (← get).pos
  if (← peek) != some '"' then fail "expected a string in double quotes"
  bump
  let rec go (acc : String) : P String := do
    match ← peek with
    | none | some '\n' => failAt start "this string is never closed"
    | some '"' => bump; return acc
    | some '\\' =>
      bump
      match ← peek with
      | some 'n' => bump; go (acc.push '\n')
      | some 't' => bump; go (acc.push '\t')
      | some '"' => bump; go (acc.push '"')
      | some '\\' => bump; go (acc.push '\\')
      | _ => fail "unknown escape in string"
    | some c => bump; go (acc.push c)
  let s ← go ""
  if s.toList.any (fun (ch : Char) => ch.toNat < 32) then failAt start "the string contains a control character"
  checkLen start "string" s

/-- A where condition: the text up to the `;` that ends the statement, outside brackets and strings,
with runs of whitespace made single spaces. Kept as text; never evaluated. -/
partial def whereText : P String := do
  skip
  let start := (← get).pos
  let rec go (acc : String) (depth : Nat) (inStr : Bool) : P String := do
    match ← peek with
    | none => failAt start "this where condition never ends with ';'"
    | some c =>
      if inStr then
        bump
        if c == '\\' then
          match ← peek with
          | some d => bump; go ((acc.push c).push d) depth true
          | none => go acc depth true
        else go (acc.push c) depth (c != '"')
      else if c == '"' then bump; go (acc.push c) depth true
      else if c == ';' && depth == 0 then return acc
      else if c == '(' || c == '[' || c == '{' then bump; go (acc.push c) (depth + 1) false
      else if c == ')' || c == ']' || c == '}' then
        if depth == 0 then failAt (← get).pos "unbalanced bracket in where condition"
        bump; go (acc.push c) (depth - 1) false
      else bump; go (acc.push c) depth false
  let raw ← go "" 0 false
  let words := (raw.splitOn " ").flatMap (fun w => w.splitOn "\n") |>.flatMap (·.splitOn "\t") |>.filter (· != "")
  checkLen start "where condition" (" ".intercalate words)


/-- Bounded exact annotation syntax (selfhost.session.generative). -/
def fraction : P LeanFM.Overlay.Q := do
  let n ← number
  let d ← if ← sym? '/' then number else pure 1
  if d == 0 || n > d then fail "probability must be between 0 and 1 with a nonzero denominator"
  return LeanFM.Overlay.Q.norm n d

def duration : P Nat := do
  let n ← boundedNumber 16
  let unit ← ident "a time unit (ms, seconds, minutes, hours, days)"
  let scale ← match unit with
    | "ms" => pure 1
    | "second" | "seconds" => pure 1000
    | "minute" | "minutes" => pure 60000
    | "hour" | "hours" => pure 3600000
    | "day" | "days" => pure 86400000
    | "week" | "weeks" => pure 604800000
    | _ => fail "unknown time unit; use ms, seconds, minutes, hours, days or weeks"
  if n * scale > 9007199254740991 then fail "duration exceeds the safe integer millisecond limit"
  return n * scale

def timeRef : P String := do
  if !(← keyword? "time") then fail "expected time(messageId)"
  sym '('; let id ← ident "a prior message id"; sym ')'; return id

def timeRefs : P (List String) := do
  if ← keyword? "max" then
    sym '('; let a ← timeRef; sym ','; let b ← timeRef; sym ')'; return [a,b]
  return [← timeRef]

/-- `after d` or `after sample { d : p; ... }`: a delay after the previous step. -/
partial def delaySample : P (List (Nat × LeanFM.Overlay.Q)) := do
  if !(← keyword? "sample") then return [(← duration, LeanFM.Overlay.Q.one)]
  sym '{'
  let rec entries (acc : List (Nat × LeanFM.Overlay.Q)) : P (List (Nat × LeanFM.Overlay.Q)) := do
    if ← sym? '}' then return acc
    if acc.length ≥ 16 then fail "a delay distribution has at most 16 entries"
    let d ← duration; sym ':'; let q ← fraction; sym ';'
    entries (acc ++ [(d,q)])
  let offsets ← entries []
  match Generative.checkWeights (offsets.map (·.2)) with
  | .error e => fail e
  | .ok _ => pure ()
  if (offsets.map (·.1)).eraseDups.length != offsets.length then fail "duplicate delay in sample"
  return offsets

partial def timeExpr : P Generative.TimeExpr := do
  if ← keyword? "next" then
    let d ← duration
    if d == 0 then fail "a gate's period must be longer than zero"
    return { period := some d }
  let base ← if (← peekIdent) == some "time" || (← peekIdent) == some "max" then
      pure ({ refs := ← timeRefs } : Generative.TimeExpr)
    else pure { clock := some (← ident "a clock name or time(messageId)") }
  if !(← sym? '+') then return base
  if !(← keyword? "sample") then return { base with offsets := [(← duration, LeanFM.Overlay.Q.one)] }
  sym '{'
  let rec entries (acc : List (Nat × LeanFM.Overlay.Q)) : P (List (Nat × LeanFM.Overlay.Q)) := do
    if ← sym? '}' then return acc
    if acc.length ≥ 16 then fail "a delay distribution has at most 16 entries"
    let d ← duration; sym ':'; let q ← fraction; sym ';'
    entries (acc ++ [(d,q)])
  let offsets ← entries []
  match Generative.checkWeights (offsets.map (·.2)) with
  | .error e => fail e
  | .ok _ => pure ()
  if (offsets.map (·.1)).eraseDups.length != offsets.length then fail "duplicate delay in sample"
  return { base with offsets }

/-- `N UNIT`: a whole quantity of at most 12 digits and a unit name (selfhost.session.amounts). -/
def quantity : P (Nat × String) := do
  let n ← boundedNumber 12
  let unit ← ident "a unit (such as USD)"
  if unit.length > 32 then fail "a unit name has at most 32 characters"
  return (n, unit)

/-- `{ 5 apple; 4 orange; -3 USD; }`: a trade vector. Positive entries move from the sender to the
receiver and negative ones back, so the two sides cancel unit by unit. -/
partial def tradeVector : P (List Generative.Amount) := do
  let rec entries (acc : List Generative.Amount) : P (List Generative.Amount) := do
    if ← sym? '}' then return acc
    if acc.length ≥ 16 then fail "a trade vector has at most 16 entries"
    let reverse ← sym? '-'
    let (n, unit) ← quantity; sym ';'
    if acc.any (·.unit == unit) then fail s!"unit {unit} appears twice in the trade vector"
    entries (acc ++ [{ unit, outcomes := [(n, LeanFM.Overlay.Q.one)], reverse }])
  let es ← entries []
  if es.isEmpty then fail "a trade vector needs at least one entry"
  return es

/-- `N UNIT`, or `sample { N UNIT : p; ... }` with one unit and distinct quantities. -/
partial def amountExpr : P Generative.Amount := do
  if !(← keyword? "sample") then
    let (n, unit) ← quantity
    return { unit, outcomes := [(n, LeanFM.Overlay.Q.one)] }
  sym '{'
  let rec entries (acc : List (Nat × String × LeanFM.Overlay.Q)) : P (List (Nat × String × LeanFM.Overlay.Q)) := do
    if ← sym? '}' then return acc
    if acc.length ≥ 16 then fail "an amount distribution has at most 16 entries"
    let (n, unit) ← quantity; sym ':'; let q ← fraction; sym ';'
    entries (acc ++ [(n, unit, q)])
  let es ← entries []
  let some (_, unit, _) := es.head? | fail "an amount sample needs at least one entry"
  if es.any (fun (_, u, _) => u != unit) then fail "an amount sample uses one unit"
  if (es.map (·.1)).eraseDups.length != es.length then fail "duplicate quantity in amount sample"
  match Generative.checkWeights (es.map (·.2.2)) with
  | .error e => fail e
  | .ok _ => pure ()
  return { unit, outcomes := es.map fun (n, _, q) => (n, q) }

partial def obligationSpec : P Generative.Obligation := do
  let first ← ident "an obligation name"
  let rec qualified (name : String) : P String := do
    if ← sym? '.' then qualified (name ++ "." ++ (← ident "a name component"))
    else return name
  let name ← qualified first
  if name.length > limits.maxString then fail "obligation name is too long"
  if !(← keyword? "on") then fail "expected on Role"
  let actor ← ident "a role"; sym '{'
  if !(← keyword? "trigger") then fail "expected trigger clock"
  let clock ← ident "a clock"; sym ';'
  if !(← keyword? "require") then fail "expected require Label"
  let first ← ident "a message label"
  let rec labels (acc : List String) : P (List String) := do
    if ← keyword? "or" then
      if acc.length ≥ 16 then fail "at most 16 obligation labels"
      labels (acc ++ [← ident "a message label"])
    else return acc
  let ls ← labels [first]
  if !(← keyword? "within") then fail "expected within duration"
  let withinMs ← duration; sym ';'
  if !(← keyword? "on") || !(← keyword? "breach") || !(← keyword? "record") then
    fail "expected on breach record Label"
  let breach ← ident "a monitor label"
  let penalty ← do
    if ← keyword? "pays" then
      let (quantity, unit) ← quantity
      if !(← keyword? "to") then fail "expected to Role after the penalty"
      let payee ← ident "the role paid"
      if payee == actor then fail "a penalty is paid to another role, not to its payer"
      pure (some ({ quantity, unit, payee } : Generative.Penalty))
    else pure none
  sym ';'; sym '}'
  return { name, actor, clock, labels := ls, withinMs, breach, penalty }

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

/-- Rename the ids in `ids` (and causes and time references to them) with suffix `sfx`. -/
partial def renameIds (ids : List String) (sfx : String) : List Stmt → List Stmt
  | [] => []
  | s :: rest => go s :: renameIds ids sfx rest
where
  r (x : String) : String := if ids.contains x then x ++ sfx else x
  rt (t : Generative.TimeExpr) : Generative.TimeExpr := { t with refs := t.refs.map r }
  go : Stmt → Stmt
    | .msg id l a b cause route status guard => .msg (id.map r) l a b (cause.map r) route status guard
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

/-- `N UNIT per PERIOD`: `per week` is per one week, `per 2 weeks` a duration. -/
def rateEntry : P (Nat × String × Nat) := do
  let (quantity, unit) ← quantity
  if !(← keyword? "per") then fail "expected per PERIOD (such as per week)"
  let periodMs ← if (← nextChar).any Char.isDigit then duration else do
    let u ← ident "a time unit"
    match u with
    | "ms" => pure 1 | "second" => pure 1000 | "minute" => pure 60000 | "hour" => pure 3600000
    | "day" => pure 86400000 | "week" => pure 604800000
    | _ => fail "unknown period; use ms, second, minute, hour, day or week, or a number and unit"
  if periodMs == 0 then fail "a rate's period must be longer than zero"
  return (quantity, unit, periodMs)

mutual
partial def block : P (List Stmt) := do
  skip
  let opened := (← get).pos
  sym '{'
  let depth := (← get).depth
  if depth ≥ limits.maxDepth then fail "statements are nested too deeply"
  modify fun s => { s with depth := depth + 1 }
  let rec go (acc : Array Stmt) : P (List Stmt) := do
    if ← sym? '}' then return acc.toList
    if (← peek).isNone then failAt opened "a '{' is never closed"
    if acc.size ≥ limits.maxSteps then fail "more than 200 steps in block"
    go (acc.push (← stmt))
  let result ← go #[]
  modify fun s => { s with depth := depth }
  return result

partial def branches (sep : String) : P (List (List Stmt)) := do
  let first ← block
  let rec more (acc : Array (List Stmt)) : P (List (List Stmt)) := do
    if ← keyword? sep then more (acc.push (← block)) else return acc.toList
  let bs ← more #[first]
  if bs.length > limits.maxBranches then fail s!"more than {limits.maxBranches} branches"
  return bs

partial def stmt : P Stmt := do
  skip
  let start := (← get).pos
  let s0 ← get
  let w ← ident "a statement"
  -- the construct words are not reserved: they are constructs only when followed by their shape
  if w == "clock" && (← peekIdent) != some "from" && (← nextChar) != some ':' then
    let name ← ident "a clock name"; sym '='
    let refs ← timeRefs; sym ';'; return .clock name refs
  if w == "obligation" && (← peekIdent) != some "from" && (← nextChar) != some ':' then return .obligation (← obligationSpec)
  if w == "accrue" && ((← nextChar).any Char.isDigit || (← nextChar) == some '{') then
    -- one rate, or a rate vector { 1000 USD per week; -1 roomweek per week; } whose negative entries
    -- flow the other way, so the two sides cancel unit by unit at every moment
    let entries ← if ← sym? '{' then do
        let rec more (acc : List (Bool × Nat × String × Nat)) : P (List (Bool × Nat × String × Nat)) := do
          if ← sym? '}' then return acc
          if acc.length ≥ 16 then fail "a rate vector has at most 16 entries"
          let reverse ← sym? '-'
          let (n, unit, period) ← rateEntry
          sym ';'
          if acc.any (·.2.2.1 == unit) then fail s!"unit {unit} appears twice in the rate vector"
          more (acc ++ [(reverse, n, unit, period)])
        let es ← more []
        if es.isEmpty then fail "a rate vector needs at least one entry"
        pure es
      else do
        let (n, unit, period) ← rateEntry
        pure [(false, n, unit, period)]
    if !(← keyword? "from") then fail "expected from Payer"
    let payer ← ident "the paying role"
    if !(← keyword? "to") then fail "expected to Payee"
    let payee ← ident "the role paid"
    if payer == payee then fail "an accrual is paid to another role, not to its payer"
    sym ';'
    return .accrue (entries.map fun (rev, quantity, unit, periodMs) =>
      if rev then { payer := payee, payee := payer, unit, quantity, periodMs }
      else { payer, payee, unit, quantity, periodMs })
  if w == "choice" && (← peekIdent) == some "at" then
    discard <| keyword? "at"
    let actor ← ident "the choosing role"
    if !(← keyword? "using") || !(← keyword? "declared") then fail "expected using declared(name)"
    sym '('; let name ← stringLit; sym ')'
    let bs ← branches "or"
    let mut weights := []
    let mut bodies := []
    for b in bs do
      match b with
      | .weighted "__branch" "" ws body :: [] =>
        weights := weights ++ ws; bodies := bodies ++ body
      | _ =>
        if !weights.isEmpty then fail "every branch needs probability n/d"
        bodies := bodies ++ [b]
    if !weights.isEmpty then
      if weights.length != bs.length then fail "every branch needs probability n/d"
      match Generative.checkWeights weights with
      | .error e => fail e
      | .ok _ => pure ()
    return .weighted name actor weights bodies
  if w == "probability" && (← nextChar).any Char.isDigit then
    if (← get).depth ≥ limits.maxDepth then fail "statements are nested too deeply"
    modify fun s => { s with depth := s.depth + 1 }
    let q ← fraction; sym ':'
    let rec body (acc : List Stmt) : P (List Stmt) := do
      if (← nextChar) == some '}' then return acc
      if acc.length ≥ limits.maxSteps then fail "too many statements"
      body (acc ++ [← stmt])
    let parsedBody ← body []
    modify fun s => { s with depth := s.depth - 1 }
    return .weighted "__branch" "" [q] [parsedBody]
  if w == "choice" && (← nextChar) == some '{' then return .choice (← branches "or")
  if w == "par" && (← nextChar) == some '{' then return .par (← branches "and")
  if w == "sessions" && (← nextChar) == some '{' then return .sessions (← block)
  if w == "join" && (← nextChar).any Char.isDigit then
    let n ← number
    if !(← keyword? "of") then fail "expected 'of' after join's number"
    return .join n (← branches "and")
  if w == "rec" then
    let s1 ← get
    if let some n ← ident? then
      if (← nextChar) == some '{' then return .loop n (← block)
      if ← keyword? "at" then
        if !(← keyword? "most") then fail "expected rec Name at most N { ... }"
        let bound ← number
        if bound < 1 || bound > 32 then fail "a bounded loop runs between 1 and 32 times"
        let body ← block
        let other ← if ← keyword? "otherwise" then block else pure []
        return .bounded n bound body other
    set s1
  if w == "continue" then
    let s1 ← get
    if let some n ← ident? then
      if ← sym? ';' then return .cont n
    set s1
  if w == "include" then
    let s1 ← get
    if let some p ← ident? then
      let rec args (acc : Array String) : P (List String) := do
        if ← sym? ';' then return acc.toList
        match ← ident? with
        | some a => args (acc.push a)
        | none => fail "expected a role name or ';' in include"
      return .incl p (← args #[])
    set s1
  -- a message `[id:] Label from A to B ...;` or an event `Label at A;`
  set s0
  let first ← ident "a statement"
  let (id, label) ← do
    if ← sym? ':' then pure (some first, ← ident "a message label")
    else pure (none, first)
  if ← keyword? "at" then
    if id.isSome then failAt start "an event has no message id"
    let r ← ident "a role"
    let timing ← do
      if ← keyword? "after" then pure (some ({ offsets := ← delaySample, relative := true } : Generative.TimeExpr))
      else if ← keyword? "at" then
        if !(← keyword? "next") then fail "an event's time is after d or at next d"
        let d ← duration
        if d == 0 then fail "a gate's period must be longer than zero"
        pure (some ({ period := some d } : Generative.TimeExpr))
      else pure none
    sym ';'
    return match timing with | some t => .timed t (.event label r) | none => .event label r
  if !(← keyword? "from") then fail s!"expected 'from' or 'at' after {label}"
  let src ← ident "the sending role"
  if !(← keyword? "to") then fail "expected 'to'"
  let dst ← ident "the receiving role"
  let cause ← do if ← keyword? "cause" then pure (some (← ident "a message id")) else pure none
  let route ← do if ← keyword? "route" then pure (some (← stringLit)) else pure none
  let status ← do if ← keyword? "status" then pure (some (← number)) else pure none
  let amounts ← do
    if ← keyword? "amount" then
      if ← sym? '{' then tradeVector else pure [← amountExpr]
    else pure []
  let timing ← do
    if ← keyword? "at" then pure (some (← timeExpr))
    else if ← keyword? "after" then pure (some ({ offsets := ← delaySample, relative := true } : Generative.TimeExpr))
    else pure none
  let guard ← do if ← keyword? "where" then pure (some (← whereText)) else pure none
  sym ';' "';' at the end of the message"
  let message := Stmt.msg id label src dst cause route status guard
  let message := amounts.foldl (fun m a => .valued a m) message
  return match timing with | some t => .timed t message | none => message
end

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

/-- One clause of `require per q { ... }` (selfhost.session.sla):
`every q reaches A, B [within d];` or
`at least|at most p of q reach A, B [within d] over (d | N entries) [confidence c] [expecting N per unit];` -/
partial def requirement (entry : String) : P Generative.Requirement := do
  skip
  let start := (← get).pos
  let bound ← if ← keyword? "every" then pure Generative.Bound.every
    else if ← keyword? "at" then
      if ← keyword? "least" then pure (Generative.Bound.atLeast (← fraction))
      else if ← keyword? "most" then pure (Generative.Bound.atMost (← fraction))
      else fail "expected 'at least' or 'at most'"
    else fail "a requirement starts with 'every', 'at least' or 'at most'"
  if bound != .every && !(← keyword? "of") then fail "expected 'of' after the fraction"
  let who ← ident "the entry"
  if who != entry then failAt start s!"this block requires per {entry}; the clause is about {who}"
  if !(← keyword? (if bound == .every then "reaches" else "reach")) then
    fail (if bound == .every then "expected 'reaches'" else "expected 'reach'")
  let rec targets (acc : Array String) : P (List String) := do
    let t ← ident "a message or event label"
    let acc := acc.push t
    if acc.size > 16 then fail "at most 16 targets"
    if ← sym? ',' then targets acc else return acc.toList
  let ts ← targets #[]
  let mut r : Generative.Requirement := { entry, bound, targets := ts }
  let mut more := true
  while more do
    if ← keyword? "within" then
      if r.withinMs.isSome then fail "'within' given twice"
      r := { r with withinMs := some (← duration) }
    else if ← keyword? "over" then
      if r.window.isSome then fail "'over' given twice"
      let n ← boundedNumber 9
      let u ← ident "a time unit or 'entries'"
      if u == "entries" || u == "entry" then
        if n == 0 then fail "a window needs at least one entry"
        r := { r with window := some (.entries n) }
      else match unitMs u with
        | some ms => if n == 0 then fail "a window needs a positive length" else r := { r with window := some (.time (n * ms)) }
        | none => fail "unknown window unit; use entries, ms, seconds, minutes, hours, days or weeks"
    else if ← keyword? "confidence" then
      let c ← fraction
      if c.num == 0 || c.num == c.den then fail "confidence must be strictly between 0 and 1"
      r := { r with confidence := c }
    else if ← keyword? "expecting" then
      let n ← boundedNumber 9
      if !(← keyword? "per") then fail "expected 'per' and a time unit, as in expecting 500 per hour"
      let u ← ident "a time unit"
      match unitMs u with
      | some ms => r := { r with rate := some (n, ms) }
      | none => fail "unknown time unit; use ms, second, minute, hour, day or week"
    else more := false
  sym ';' "';' after the requirement"
  if bound == .every && r.window.isSome then
    failAt start "'every' is a hard deadline, checkable on each entry: it takes no observation window"
  if bound != .every && r.window.isNone then
    failAt start "a required fraction is only checkable over an observation window: add 'over 1 hour' or 'over 1000 entries'"
  let src ← read
  let text := String.ofList (src.extract start (← get).pos).toList
  return { r with text := text.trimAscii.toString }

partial def file : P (List Def) := do
  let rec go (acc : Array Def) : P (List Def) := do
    skip
    if (← peek).isNone then return acc.toList
    let start := (← get).pos
    if ← keyword? "require" then
      if acc.isEmpty then failAt start "requirements follow the protocol they are about"
      if !(← keyword? "per") then fail "expected 'per' and a message id, as in require per q { ... }"
      let entry ← ident "a message id"
      sym '{' "'{' and the requirements"
      let rec clauses : P Unit := do
        skip
        if ← sym? '}' then return
        let r ← requirement entry
        if (← get).requires.size ≥ 16 then fail "at most 16 requirements"
        modify fun s => { s with requires := s.requires.push r }
        clauses
      clauses
      return ← go acc
    if !(← keyword? "protocol") then fail "expected 'protocol'"
    let name ← ident "the protocol's name"
    if acc.any (·.name == name) then failAt start s!"protocol {name} is defined twice"
    sym '(' "'(' and the roles"
    let rec roles (rs : Array String) : P (List String) := do
      if ← sym? ')' then return rs.toList
      if !rs.isEmpty then sym ',' "',' or ')'"
      roles (rs.push (← ident "a role"))
    let rs ← roles #[]
    if rs.isEmpty then failAt start "a protocol needs at least one role"
    if rs.length > limits.maxRoles then failAt start s!"a protocol has at most {limits.maxRoles} roles"
    if rs.eraseDups.length != rs.length then failAt start "role names must be distinct"
    go (acc.push { name, roles := rs, body := unroll (← block) })
  let defs ← go #[]
  if defs.isEmpty then fail "no protocol in the text"
  return defs

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
      let g : Option Guard := guard.map fun t => { text := t, eval := fun _ => none }
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
  deriving Inhabited

/-- The global type of the text's main protocol with its body replaced by `f` of it (used to draw
annotations: the body's messages tagged by position, built exactly as the parser builds them). -/
def buildWith (text : String) (body : List Stmt) : Except String (Global String) := do
  if text.utf8ByteSize > limits.maxBytes then throw s!"the text is over {limits.maxBytes} bytes"
  let (defs, _) ← (file.run text.toList.toArray).run {}
  let main := defs.getLast!
  let ctx : Ctx := { defs := defs.dropLast, rename := [], roles := main.roles, path := main.name,
                     inside := [main.name] }
  let (g, _) ← (build ctx body).run 0
  return g

def parse (text : String) : Except String Parsed := do
  if text.utf8ByteSize > limits.maxBytes then throw s!"the text is over {limits.maxBytes} bytes"
  let src := text.toList.toArray
  let (defs, st) ← (file.run src).run {}
  let main := defs.getLast!
  let earlier := defs.dropLast
  let ctx : Ctx := { defs := earlier, rename := [], roles := main.roles, path := main.name,
                     inside := [main.name] }
  let (g, n) ← (build ctx main.body).run 0
  -- requirements name a message id of the main protocol and labels that occur in the text
  let ids := declaredIds main.body
  let labels := defs.flatMap (fun d => labelsOf d.body)
  for r in st.requires do
    if !ids.contains r.entry then
      throw s!"require per {r.entry}: {r.entry} is not a message id of protocol {main.name}; give the message an id, as in {r.entry}: Request from A to B;"
    for t in r.targets do
      if !labels.contains t then throw s!"requirement '{r.text}': {t} is not a message or event of the protocol"
  return { name := main.name, roles := main.roles, global := g, steps := n, body := main.body,
           requires := st.requires.toList }

/-! ## Writing -/

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

end LeanFM.Session.Text
