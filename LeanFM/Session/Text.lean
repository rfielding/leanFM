import LeanFM.Session.Global

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
  | event (label role : String)
  | choice (branches : List (List Stmt))
  | par (branches : List (List Stmt))
  | join (need : Nat) (branches : List (List Stmt))
  | loop (name : String) (body : List Stmt)
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

partial def number : P Nat := do
  skip
  let start := (← get).pos
  let rec go (acc : Nat) (n : Nat) : P (Nat × Nat) := do
    match ← peek with
    | some c => if c.isDigit then bump; go (acc * 10 + (c.toNat - '0'.toNat)) (n + 1) else return (acc, n)
    | none => return (acc, n)
  let (v, n) ← go 0 0
  if n == 0 then failAt start "expected a number"
  if n > 6 then failAt start "this number is too large"
  return v

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

mutual
partial def block : P (List Stmt) := do
  skip
  let opened := (← get).pos
  sym '{'
  let rec go (acc : Array Stmt) : P (List Stmt) := do
    if ← sym? '}' then return acc.toList
    if (← peek).isNone then failAt opened "a '{' is never closed"
    go (acc.push (← stmt))
  go #[]

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
    sym ';'
    return .event label r
  if !(← keyword? "from") then fail s!"expected 'from' or 'at' after {label}"
  let src ← ident "the sending role"
  if !(← keyword? "to") then fail "expected 'to'"
  let dst ← ident "the receiving role"
  let cause ← do if ← keyword? "cause" then pure (some (← ident "a message id")) else pure none
  let route ← do if ← keyword? "route" then pure (some (← stringLit)) else pure none
  let status ← do if ← keyword? "status" then pure (some (← number)) else pure none
  let guard ← do if ← keyword? "where" then pure (some (← whereText)) else pure none
  sym ';' "';' at the end of the message"
  return .msg id label src dst cause route status guard
end

partial def file : P (List Def) := do
  let rec go (acc : Array Def) : P (List Def) := do
    skip
    if (← peek).isNone then return acc.toList
    let start := (← get).pos
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
    go (acc.push { name, roles := rs, body := ← block })
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

def parse (text : String) : Except String Parsed := do
  if text.utf8ByteSize > limits.maxBytes then throw s!"the text is over {limits.maxBytes} bytes"
  let src := text.toList.toArray
  let (defs, _) ← (file.run src).run {}
  let main := defs.getLast!
  let earlier := defs.dropLast
  let ctx : Ctx := { defs := earlier, rename := [], roles := main.roles, path := main.name,
                     inside := [main.name] }
  let (g, n) ← (build ctx main.body).run 0
  return { name := main.name, roles := main.roles, global := g, steps := n }

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

mutual
partial def writeStmts (ind : String) (ss : List Stmt) : List String := ss.flatMap (writeStmt ind)

partial def writeBranches (ind kw sep : String) (bs : List (List Stmt)) : List String :=
  match bs with
  | [] => []
  | b :: rest =>
    [ind ++ kw ++ " {"] ++ writeStmts (ind ++ "  ") b ++
      (rest.flatMap fun b => [ind ++ "} " ++ sep ++ " {"] ++ writeStmts (ind ++ "  ") b) ++ [ind ++ "}"]

partial def writeStmt (ind : String) : Stmt → List String
  | .msg id label src dst cause route status guard =>
    [ind ++ (match id with | some i => showIdent i ++ ": " | none => "") ++ showIdent label ++
      " from " ++ showIdent src ++ " to " ++ showIdent dst ++
      (match cause with | some c => " cause " ++ showIdent c | none => "") ++
      (match route with | some r => " route " ++ showString r | none => "") ++
      (match status with | some s => s!" status {s}" | none => "") ++
      (match guard with | some g => " where " ++ g | none => "") ++ ";"]
  | .event label r => [ind ++ showIdent label ++ " at " ++ showIdent r ++ ";"]
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
