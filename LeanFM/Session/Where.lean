/-!
# Where conditions, run (clause selfhost.session.where)

A `where` condition on a message is an expression over the message ids in scope and their fields,
such as `p.amount = q.price`. LeanFM parses it into a closed `Expr` and runs it with an interpreter
over logged payloads: there is no constructor that holds code, so protocol text from any client
cannot execute anything. A condition that cannot be decided (a missing field, a message that has not
happened, mismatched types, division by zero, text outside this language) is `unknown`, with the
reason, never silently true.

Grammar, loosest first:
  or  := and (("or" | "||" | "∨") and)*
  and := not (("and" | "&&" | "∧") not)*
  not := ("not" | "!" | "¬") not | cmp
  cmp := sum (("=" | "==" | "!=" | "≠" | "<" | "<=" | "≤" | ">" | ">=" | "≥") sum)?
  sum := prod (("+" | "-") prod)*
  prod := unary (("*" | "/") unary)*
  unary := "-" unary | atom
  atom := number | "string" | true | false | path | "(" or ")"
  path := ident ("." ident)*
-/

namespace LeanFM.Session.Where

inductive Value where
  | num (q : Rat)
  | str (s : String)
  | bool (b : Bool)
  deriving BEq, Repr, Inhabited

def Value.render : Value → String
  | .num q => if q.den == 1 then toString q.num else s!"{q.num}/{q.den}"
  | .str s => "\"" ++ s ++ "\""
  | .bool b => if b then "true" else "false"

inductive Expr where
  | lit (v : Value)
  | path (id : String) (field : List String)
  | neg (e : Expr)
  | bin (op : String) (a b : Expr)
  | not (e : Expr)
  deriving Repr, Inhabited

/-! ## Tokens -/

inductive Tok where
  | num (q : Rat) | str (s : String) | ident (s : String) | sym (s : String)
  deriving BEq, Repr, Inhabited

def maxText : Nat := 200

partial def lexDigits (cs : List Char) (acc : String := "") : String × List Char :=
  match cs with
  | c :: rest => if c.isDigit then lexDigits rest (acc.push c) else (acc, cs)
  | [] => (acc, [])

partial def lexIdent (cs : List Char) (acc : String := "") : String × List Char :=
  match cs with
  | c :: rest => if c.isAlphanum || c == '_' then lexIdent rest (acc.push c) else (acc, cs)
  | [] => (acc, [])

partial def lexString (cs : List Char) (acc : String := "") : Option (String × List Char) :=
  match cs with
  | '"' :: rest => some (acc, rest)
  | c :: rest => lexString rest (acc.push c)
  | [] => none

def symbols : List String := ["==", "!=", "<=", ">=", "&&", "||", "≠", "≤", "≥", "∧", "∨", "¬", "=", "<", ">", "+", "-", "*", "/", "(", ")", ".", "!"]

partial def lex (cs : List Char) (acc : Array Tok := #[]) : Except String (Array Tok) :=
  match cs with
  | [] => .ok acc
  | c :: rest =>
    if c.isWhitespace then lex rest acc
    else if c.isDigit then
      let (whole, r1) := lexDigits cs
      let (frac, r2) := match r1 with
        | '.' :: d :: r => if d.isDigit then lexDigits (d :: r) else ("", r1)
        | _ => ("", r1)
      let n := whole.toNat!
      let q : Rat := if frac.isEmpty then (n : Rat)
        else (n : Rat) + (frac.toNat! : Rat) / ((10 ^ frac.length : Nat) : Rat)
      lex r2 (acc.push (.num q))
    else if c == '"' then
      match lexString rest with
      | some (s, r) => lex r (acc.push (.str s))
      | none => .error "a string is not closed"
    else if c.isAlpha || c == '_' then
      let (w, r) := lexIdent cs
      lex r (acc.push (.ident w))
    else
      let two := String.ofList (cs.take 2)
      match symbols.find? (fun s => s == two || s == c.toString) with
      | some s => lex (cs.drop s.length) (acc.push (.sym s))
      | none => .error s!"unexpected character {c}"

/-! ## Parser -/

structure P where
  toks : Array Tok
  pos : Nat := 0

abbrev Parse := StateT P (Except String)

def peek : Parse (Option Tok) := do let s ← get; return s.toks[s.pos]?
def advance : Parse Unit := modify fun s => { s with pos := s.pos + 1 }
def isSym (t : Option Tok) (xs : List String) : Option String :=
  match t with | some (.sym s) => if xs.contains s then some s else none | _ => none
def isWord (t : Option Tok) (xs : List String) : Option String :=
  match t with | some (.ident s) => if xs.contains s then some s else none | _ => none

mutual
partial def pOr : Parse Expr := do
  let mut e ← pAnd
  repeat
    let t ← peek
    if (isWord t ["or"]).isSome || (isSym t ["||", "∨"]).isSome then advance; e := .bin "or" e (← pAnd) else break
  return e

partial def pAnd : Parse Expr := do
  let mut e ← pNot
  repeat
    let t ← peek
    if (isWord t ["and"]).isSome || (isSym t ["&&", "∧"]).isSome then advance; e := .bin "and" e (← pNot) else break
  return e

partial def pNot : Parse Expr := do
  let t ← peek
  if (isWord t ["not"]).isSome || (isSym t ["!", "¬"]).isSome then advance; return .not (← pNot)
  pCmp

partial def pCmp : Parse Expr := do
  let a ← pSum
  match isSym (← peek) ["=", "==", "!=", "≠", "<", "<=", "≤", ">", ">=", "≥"] with
  | some op =>
    advance
    let op := match op with | "==" => "=" | "≠" => "!=" | "≤" => "<=" | "≥" => ">=" | o => o
    return .bin op a (← pSum)
  | none => return a

partial def pSum : Parse Expr := do
  let mut e ← pProd
  repeat
    match isSym (← peek) ["+", "-"] with
    | some op => advance; e := .bin op e (← pProd)
    | none => break
  return e

partial def pProd : Parse Expr := do
  let mut e ← pUnary
  repeat
    match isSym (← peek) ["*", "/"] with
    | some op => advance; e := .bin op e (← pUnary)
    | none => break
  return e

partial def pUnary : Parse Expr := do
  if (isSym (← peek) ["-"]).isSome then advance; return .neg (← pUnary)
  pAtom

partial def pAtom : Parse Expr := do
  match ← peek with
  | some (.num q) => advance; return .lit (.num q)
  | some (.str s) => advance; return .lit (.str s)
  | some (.ident "true") => advance; return .lit (.bool true)
  | some (.ident "false") => advance; return .lit (.bool false)
  | some (.ident x) =>
    advance
    let mut field : List String := []
    repeat
      if (isSym (← peek) ["."]).isSome then
        advance
        match ← peek with
        | some (.ident f) => advance; field := field ++ [f]
        | _ => throw s!"a field name must follow {x}."
      else break
    return .path x field
  | some (.sym "(") =>
    advance
    let e ← pOr
    if (isSym (← peek) [")"]).isNone then throw "a ( is not closed"
    advance
    return e
  | some t => throw s!"unexpected {repr t}"
  | none => throw "the condition ends too early"
end

/-- Parse a condition's text. Text outside the language is an error naming why. -/
def parse (text : String) : Except String Expr := do
  if text.length > maxText then throw s!"a condition is over {maxText} characters"
  let toks ← lex text.toList
  let (e, s) ← pOr.run { toks }
  if s.pos != toks.size then throw s!"unexpected text after the condition"
  return e

/-- Every (message id, field path) a condition reads. -/
def Expr.paths : Expr → List (String × String)
  | .lit _ => []
  | .path x f => [(x, ".".intercalate f)]
  | .neg e | .not e => e.paths
  | .bin _ a b => a.paths ++ b.paths

/-- The condition as text that parses back to it: operands that are themselves operations are
parenthesized. -/
partial def Expr.render : Expr → String
  | .lit v => v.render
  | .path x f => ".".intercalate (x :: f)
  | .neg e => "-" ++ sub e
  | .not e => "not " ++ sub e
  | .bin op a b => s!"{sub a} {op} {sub b}"
where
  sub : Expr → String
    | e@(.lit _) | e@(.path ..) => e.render
    | e => "(" ++ e.render ++ ")"

/-- The condition with its message ids renamed (copies of a bounded loop rename their ids). -/
def Expr.mapIds (r : String → String) : Expr → Expr
  | .lit v => .lit v
  | .path x f => .path (r x) f
  | .neg e => .neg (e.mapIds r)
  | .not e => .not (e.mapIds r)
  | .bin op a b => .bin op (a.mapIds r) (b.mapIds r)

/-! ## Interpreter -/

inductive Verdict where
  | yes | no | unknown (why : String)
  deriving BEq, Repr, Inhabited

/-- Fields of a message id in scope, as dotted keys; `none` when that message has not happened. -/
abbrev Lookup := String → Option (List (String × Value))

/-- A value, or why there is none; with the (path, value) pairs read on the way, for reports. -/
partial def value (look : Lookup) : Expr → Except String Value
  | .lit v => .ok v
  | .path x f =>
    match look x with
    | none => .error s!"{x} has not happened in this session"
    | some fs =>
      let key := ".".intercalate f
      match fs.lookup key with
      | some v => .ok v
      | none => .error s!"{x}.{key} is not in the log"
  | .neg e => do
    match ← value look e with
    | .num q => return .num (-q)
    | _ => throw s!"- needs a number"
  | .not e => do
    match ← value look e with
    | .bool b => return .bool (!b)
    | _ => throw "not needs true or false"
  | .bin op a b => do
    let va ← value look a
    -- and/or decide on the left when they can, so a false guard is not hidden by a missing field
    if op == "and" && va == .bool false then return .bool false
    if op == "or" && va == .bool true then return .bool true
    let vb ← value look b
    match op, va, vb with
    | "and", .bool x, .bool y => return .bool (x && y)
    | "or", .bool x, .bool y => return .bool (x || y)
    | "+", .num x, .num y => return .num (x + y)
    | "-", .num x, .num y => return .num (x - y)
    | "*", .num x, .num y => return .num (x * y)
    | "/", .num x, .num y => if y == 0 then throw "division by zero" else return .num (x / y)
    | "=", x, y => if sameType x y then return .bool (x == y) else throw s!"{x.render} and {y.render} are different types"
    | "!=", x, y => if sameType x y then return .bool (x != y) else throw s!"{x.render} and {y.render} are different types"
    | "<", .num x, .num y => return .bool (x < y)
    | "<=", .num x, .num y => return .bool (x ≤ y)
    | ">", .num x, .num y => return .bool (x > y)
    | ">=", .num x, .num y => return .bool (x ≥ y)
    | "<", .str x, .str y => return .bool (x < y)
    | "<=", .str x, .str y => return .bool (x == y || x < y)
    | ">", .str x, .str y => return .bool (y < x)
    | ">=", .str x, .str y => return .bool (x == y || y < x)
    | o, x, y => throw s!"{o} does not apply to {x.render} and {y.render}"
where
  sameType : Value → Value → Bool
    | .num _, .num _ | .str _, .str _ | .bool _, .bool _ => true
    | _, _ => false

/-- Run a condition's text against the session's logged fields. -/
def run (text : String) (look : Lookup) : Verdict :=
  match parse text with
  | .error e => .unknown s!"not in the condition language ({e})"
  | .ok e => match value look e with
    | .ok (.bool true) => .yes
    | .ok (.bool false) => .no
    | .ok v => .unknown s!"the condition gives {v.render}, not true or false"
    | .error why => .unknown why

/-- The values a condition read, for the report when it is false: `p.amount = 12, q.price = 10`. -/
def readings (text : String) (look : Lookup) : String :=
  match parse text with
  | .error _ => ""
  | .ok e => ", ".intercalate (e.paths.eraseDups.filterMap fun (x, f) =>
      (look x).bind (fun fs => fs.lookup f) |>.map fun v => s!"{x}.{f} = {v.render}")

end LeanFM.Session.Where
