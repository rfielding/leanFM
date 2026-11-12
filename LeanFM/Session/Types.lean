import Lean.Data.Json
import LeanFM.Session.Where

/-!
# Message types (clause selfhost.session.types)

Every message of a protocol has a type. The protocol text declares them as Lean structures, before
the protocols that use them:

```
structure Pay where
  amount : Nat
  card_secr : String
```

A message whose label names a structure carries that structure; a message whose label names none
carries nothing (the empty structure), and so does an event. Field types are `Nat`, `Int`,
`String`, `Bool`, another structure, or `List T` / `Option T` of one of those.
Fields are numbered in the order written, which is their protobuf number: add new fields at the
end.

The types decide three things. A `where` condition must be well typed against them before anything
runs (`checkCondition`): it reads single fields that exist, compares like with like, and is true or
false. A logged event's fields must be fields of its message, of their declared types
(`checkFields`). And the generated outputs (protobuf, Lean, OpenAPI schemas, the Python and
TypeScript message classes) are written from them.

Negative requirements: a type that names no structure, a structure that contains itself, two
structures or two fields with one name, a field name that is a keyword of Lean, Python,
TypeScript or protobuf, a `List` or `Option` of a `List` or `Option`, and more than 64 structures or
64 fields in one are errors. A condition that reads a field whose name ends in `_secr` is refused,
because the fields conditions read are logged; a logged event that carries a `_secr` field, or a
field its message does not declare, is refused.
-/

namespace LeanFM.Session.Types
open Where

inductive Ty where
  | nat | int | str | bool
  | msg (name : String)
  | list (t : Ty)
  | opt (t : Ty)
  deriving BEq, Repr, Inhabited

structure Field where
  name : String
  ty   : Ty
  /-- the protobuf field number a .proto gave it; 0 when numbered by position -/
  number : Nat := 0
  deriving BEq, Repr, Inhabited

structure Message where
  name   : String
  fields : List Field
  doc    : String := ""
  deriving BEq, Repr, Inhabited

/-- The structures a text declares, in the order written. -/
abbrev Env := List Message

def maxMessages : Nat := 64
def maxFieldsPer : Nat := 64

def builtins : List (String × Ty) :=
  [("Nat", .nat), ("Int", .int), ("String", .str), ("Bool", .bool)]

/-- A plain type name as written: a builtin, or a structure's name. -/
def Ty.ofName (n : String) : Ty := (builtins.lookup n).getD (.msg n)

def Ty.render : Ty → String
  | .nat => "Nat" | .int => "Int" | .str => "String" | .bool => "Bool"
  | .msg n => n
  | .list t => "List " ++ t.render
  | .opt t => "Option " ++ t.render

/-- Words that cannot be field names in some generated language. -/
def reserved : List String :=
  [ "and", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue",
    "def", "default", "del", "delete", "do", "elif", "else", "end", "enum", "except", "export",
    "extends", "false", "finally", "for", "from", "fun", "function", "global", "if", "import", "in",
    "instance", "interface", "is", "lambda", "let", "match", "message", "namespace", "new", "none",
    "nonlocal", "not", "null", "open", "option", "optional", "or", "package", "pass", "raise",
    "repeated", "return", "self", "structure", "switch", "syntax", "then", "this", "throw", "true",
    "try", "type", "typeof", "var", "void", "where", "while", "with", "yield", "None", "True", "False" ]

def isAsciiIdent (s : String) : Bool :=
  match s.toList with
  | c :: cs => (c.isAlpha || c == '_') && c.toNat < 128 && cs.all fun d => (d.isAlphanum || d == '_') && d.toNat < 128
  | [] => false

def isSecret (name : String) : Bool := name.endsWith "_secr"

def find (env : Env) (name : String) : Option Message := env.find? (·.name == name)

/-- The fields a label carries: its structure's, or none when no structure has that name. -/
def fieldsOf (env : Env) (label : String) : List Field := ((find env label).map (·.fields)).getD []

def fieldNames (env : Env) (label : String) : String :=
  match fieldsOf env label with
  | [] => s!"{label} carries no fields; declare them, as in structure {label} where amount : Nat"
  | fs => s!"the fields of {label} are {", ".intercalate (fs.map (·.name))}"

/-! ## Checking the declarations -/

/-- The structures a type refers to. -/
def Ty.refs : Ty → List String
  | .msg n => [n]
  | .list t | .opt t => t.refs
  | _ => []

/-- Structures in an order where each comes after every structure it uses; an error names a cycle. -/
partial def ordered (env : Env) : Except String (List Message) := do
  let rec visit (path : List String) (done : List String) (n : String) : Except String (List String) := do
    if done.contains n then return done
    if path.contains n then throw s!"structure {n} contains itself (through {" -> ".intercalate ((path.reverse.dropWhile (· != n)) ++ [n])})"
    let some m := find env n | return done
    let mut d := done
    for f in m.fields do
      for r in f.ty.refs do d ← visit (n :: path) d r
    return d ++ [n]
  let mut done : List String := []
  for m in env do done ← visit [] done m.name
  return done.filterMap (find env)

def check (env : Env) : Except String Unit := do
  if env.length > maxMessages then throw s!"at most {maxMessages} structures"
  for m in env do
    if !isAsciiIdent m.name then throw s!"structure {m.name}: a structure's name is letters, digits and _ (it names a protobuf message)"
    if (builtins.lookup m.name).isSome || ["List", "Option", "Array"].contains m.name then
      throw s!"structure {m.name}: {m.name} is a built-in type"
    if (env.filter (·.name == m.name)).length > 1 then throw s!"structure {m.name} is declared twice"
    if m.fields.length > maxFieldsPer then throw s!"structure {m.name} has more than {maxFieldsPer} fields"
    for f in m.fields do
      if !isAsciiIdent f.name then throw s!"{m.name}.{f.name}: a field name is letters, digits and _"
      if reserved.contains f.name then throw s!"{m.name}.{f.name}: {f.name} is a keyword in a generated language; choose another name"
      if (m.fields.filter (·.name == f.name)).length > 1 then throw s!"{m.name} has two fields named {f.name}"
      match f.ty with
      | .list (.list _) | .list (.opt _) | .opt (.list _) | .opt (.opt _) =>
        throw s!"{m.name}.{f.name}: {f.ty.render} has no protobuf form; a List or Option holds one plain type"
      | _ => pure ()
      for r in f.ty.refs do
        if (find env r).isNone then throw s!"{m.name}.{f.name}: {r} is not a declared structure or a built-in type (Nat, Int, String, Bool)"
  discard <| ordered env

/-! ## Conditions -/

inductive Base where
  | num | str | bool
  deriving BEq, Repr, Inhabited

def Base.render : Base → String
  | .num => "a number" | .str => "a string" | .bool => "true or false"

def baseOf : Value → Base
  | .num _ => .num | .str _ => .str | .bool _ => .bool

/-- The scalar type at a field path of a label's structure. `forLog` changes only the wording. -/
partial def leaf (env : Env) (label : String) (path : List String) : Except String Ty := do
  let rec go (owner : String) (seen : List String) : List String → Except String Ty
    | [] => throw s!"{label}.{".".intercalate seen} is a whole structure; read one of its fields"
    | f :: rest => do
      let some fld := (fieldsOf env owner).find? (·.name == f)
        | throw s!"{owner} has no field {f}; {fieldNames env owner}"
      let here := ".".intercalate (seen ++ [f])
      let t := match fld.ty with | .opt t => t | t => t
      match t, rest with
      | .list _, _ => throw s!"{label}.{here} is a list; a condition or log reads single values"
      | .msg m, [] => throw s!"{label}.{here} is a {m}; read one of its fields"
      | .msg m, _ => go m (seen ++ [f]) rest
      | _, [] => return t
      | _, _ => throw s!"{label}.{here} is {t.render}, which has no fields"
  go label [] path

def Ty.base : Ty → Base
  | .str => .str | .bool => .bool | _ => .num

/-- The type of a condition, given the labels each message id can have. -/
partial def typeOf (env : Env) (labelsOf : String → List String) : Expr → Except String Base
  | .lit v => return baseOf v
  | .path x f => do
    let ls := labelsOf x
    if ls.isEmpty then throw s!"{x} is not a message id of this protocol"
    if f.isEmpty then throw s!"{x} is a whole message; read one of its fields, as in {x}.amount"
    if let some s := f.find? isSecret then
      throw s!"{x}.{".".intercalate f} reads the secret {s}: the fields conditions read are logged, so a condition may not read a secret"
    let mut found : Option Base := none
    for l in ls do
      let b := (← leaf env l f).base
      if let some b0 := found then
        if b0 != b then throw s!"{x}.{".".intercalate f} is {b0.render} in one message and {b.render} in another"
      found := some b
    return found.getD .num
  | .neg e => do
    let t ← typeOf env labelsOf e
    if t != .num then throw s!"- needs a number, and {e.render} is {t.render}"
    return .num
  | .not e => do
    let t ← typeOf env labelsOf e
    if t != .bool then throw s!"not needs true or false, and {e.render} is {t.render}"
    return .bool
  | .bin op a b => do
    let ta ← typeOf env labelsOf a
    let tb ← typeOf env labelsOf b
    let both (t : Base) : Bool := ta == t && tb == t
    match op with
    | "and" | "or" => if both .bool then return .bool else throw s!"{op} needs true or false on both sides: {a.render} is {ta.render}, {b.render} is {tb.render}"
    | "+" | "-" | "*" | "/" => if both .num then return .num else throw s!"{op} needs numbers: {a.render} is {ta.render}, {b.render} is {tb.render}"
    | "=" | "!=" => if ta == tb then return .bool else throw s!"{a.render} is {ta.render} and {b.render} is {tb.render}; {op} compares like with like"
    | _ => if both .num || both .str then return .bool else throw s!"{op} compares two numbers or two strings: {a.render} is {ta.render}, {b.render} is {tb.render}"

/-- A condition's text, parsed and typed: it must be true or false. -/
def checkCondition (env : Env) (labelsOf : String → List String) (text : String) : Except String Expr := do
  let e ← (Where.parse text).mapError fun m => s!"where {text}: {m}"
  match typeOf env labelsOf e with
  | .ok .bool => return e
  | .ok t => throw s!"where {text}: the condition is {t.render}, not true or false"
  | .error m => throw s!"where {text}: {m}"

/-! ## Integers on the wire (selfhost.session.envelope) -/

/-- The largest integer a double holds exactly: 2^53 - 1. Beyond it a JSON number is not exact in
most languages, so integers travel as decimal strings. -/
def maxSafe : Nat := 9007199254740991

/-- A decimal string as an integer: an optional `-` and 1 to 20 digits, nothing else. -/
def decimal? (s : String) : Option Int :=
  let (neg, ds) := match s.toList with
    | '-' :: rest => (true, rest)
    | cs => (false, cs)
  if ds.isEmpty || ds.length > 20 || !ds.all Char.isDigit then none
  else
    let n : Nat := ds.foldl (fun acc c => acc * 10 + (c.toNat - '0'.toNat)) 0
    some (if neg then -(n : Int) else n)

/-- An integer as JSON gives it: a decimal string, or a number that is a whole number within 2^53 - 1. -/
def integer? (v : Value) : Except String Int :=
  match v with
  | .str t => match decimal? t with
    | some n => .ok n
    | none => .error s!"{v.render} is not a decimal integer"
  | .num q =>
    if q.den != 1 then .error s!"{v.render} is not a whole number"
    else if q.num.natAbs > maxSafe then .error s!"{v.render} is beyond 2^53 - 1, where JSON numbers are not exact; send it as a decimal string"
    else .ok q.num
  | _ => .error s!"{v.render} is not an integer"

/-! ## Logged fields -/

/-- A logged event's fields against its message's structure. -/
def checkFields (env : Env) (label : String) (isAct : Bool) (fields : List (String × Value)) : Except String Unit := do
  if fields.isEmpty then return
  if isAct then throw s!"{label} is an event, and events carry no fields"
  for (k, v) in fields do
    let path := k.splitOn "."
    if let some s := path.find? isSecret then throw s!"the log carries the secret {label}.{k} ({s}); secrets are never logged"
    let t ← leaf env label path
    match t, v with
    | .nat, .num _ | .nat, .str _ | .int, .num _ | .int, .str _ =>
      match integer? v with
      | .ok n => if t == .nat && n < 0 then throw s!"{label}.{k} is a Nat, and the log has {v.render}"
      | .error why => throw s!"{label}.{k} is {t.render}, and {why}"
    | .str, .str _ | .bool, .bool _ => pure ()
    | _, _ => throw s!"{label}.{k} is {t.render}, and the log has {v.render}"

/-- Logged fields with integers as exact numbers, after `checkFields` has accepted them. -/
def coerceFields (env : Env) (label : String) (fields : List (String × Value)) : List (String × Value) :=
  fields.map fun (k, v) =>
    match leaf env label (k.splitOn "."), integer? v with
    | .ok .nat, .ok n | .ok .int, .ok n => (k, .num n)
    | _, _ => (k, v)

/-! ## Generated forms -/

/-- The structures every label of the protocol needs: the declared ones in dependency order, then an
empty one for each label that names no structure. -/
def complete (env : Env) (labels : List String) (onlyUsed : Bool := false) : Except String (List Message) := do
  let ord ← ordered env
  -- the structures the labels reach through their fields
  let rec reach (fuel : Nat) (seen : List String) (todo : List String) : List String :=
    match fuel, todo with
    | 0, _ | _, [] => seen
    | f + 1, n :: rest =>
      if seen.contains n then reach f seen rest
      else reach f (n :: seen) (rest ++ (fieldsOf env n).flatMap (·.ty.refs))
  let used := reach (maxMessages * (maxFieldsPer + 1) + labels.length) [] labels
  let ord := if onlyUsed then ord.filter (used.contains ·.name) else ord
  let extra := labels.eraseDups.filter (fun l => (find env l).isNone) |>.map fun l => ({ name := l, fields := [] } : Message)
  return ord ++ extra

def protoScalar : Ty → String
  | .nat => "uint64" | .int => "int64" | .str => "string" | .bool => "bool"
  | .msg n => n | .list t | .opt t => protoScalar t

def protoField (f : Field) (n : Nat) : String :=
  let pre := match f.ty with | .list _ => "repeated " | .opt _ => "optional " | _ => ""
  s!"  {pre}{protoScalar f.ty} {f.name} = {if f.number != 0 then f.number else n};"

/-- A label as a protobuf message name: letters, digits and _ only. -/
def protoName (s : String) : String :=
  let t := String.ofList (s.toList.map fun c => if (c.isAlphanum || c == '_') && c.toNat < 128 then c else '_')
  if (t.toList.head?.map Char.isDigit).getD true then "M" ++ t else t

/-- The messages as a proto3 file. -/
def proto (env : Env) (labels : List String) (package : String) : Except String String := do
  let ms ← complete env labels
  let names := ms.map (protoName ·.name)
  if names.eraseDups.length != names.length then throw "two labels have the same protobuf name"
  let body := ms.map fun m =>
    let doc := if m.doc.isEmpty then [] else (m.doc.splitOn "\n").map ("// " ++ ·.trimAscii.toString)
    "\n".intercalate (doc ++ [s!"message {protoName m.name} \{"] ++
      (m.fields.zipIdx.map fun (f, i) => protoField f (i + 1)) ++ ["}"])
  if names.contains "Event" then throw "a message named Event would collide with the event envelope; rename it"
  -- the envelope every event travels and is logged in (selfhost.session.envelope)
  let carried := labels.eraseDups.map protoName
  let snake (n : String) : String := String.ofList (n.toList.zipIdx.flatMap fun (c, i) =>
    if c.isUpper then (if i == 0 then [c.toLower] else ['_', c.toLower]) else [c])
  let oneof := carried.zipIdx.map fun (n, i) => s!"    {n} {snake n} = {i + 9};"
  let envelope := "\n".intercalate ([
    "// The event envelope: every event of the protocol, as it is carried and logged. Integers travel",
    "// as decimal strings in JSON (the protobuf JSON mapping), so nanosecond timestamps stay exact.",
    "message Event {",
    "  uint64 ts = 1;        // nanoseconds; unique in its stream, and its identity",
    "  string id = 2;        // the event's name, in a log that names events",
    "  string session = 3;   // the session, or its key's value when the sessions block names one",
    "  string from = 4;",
    "  string to = 5;",
    "  string label = 6;",
    "  string cause = 7;     // the id or ts of the event this one answers",
    "  string prev = 8;      // the id or ts of the event before it, where reward vectors are walked"] ++
    (if oneof.isEmpty then [] else ["  oneof payload {"] ++ oneof ++ ["  }"]) ++ ["}"])
  return "\n".intercalate ([ "// Generated by LeanFM from the message types of the protocol; regenerate it rather than editing.",
    "syntax = \"proto3\";", "", s!"package {package};", ""]) ++ "\n" ++ "\n\n".intercalate (body ++ [envelope]) ++ "\n"

def leanField (f : Field) : String := s!"  {f.name} : {f.ty.render}"

/-- The messages as Lean structures with JSON conversions. -/
def lean (env : Env) (labels : List String) (ns : String) : Except String String := do
  let ms ← complete env labels
  let body := ms.map fun m =>
    let name := if isAsciiIdent m.name then m.name else "«" ++ m.name ++ "»"
    let doc := if m.doc.isEmpty then [] else [s!"/-- {m.doc} -/"]
    let derive := "  deriving Repr, BEq, Lean.ToJson, Lean.FromJson"
    "\n".intercalate (doc ++ (if m.fields.isEmpty then [s!"structure {name}"] else [s!"structure {name} where"] ++ m.fields.map leanField) ++ [derive])
  return "\n".intercalate [ "import Lean.Data.Json", "",
    "/-! Generated by LeanFM from the message types of the protocol; regenerate it rather than editing. -/", "", s!"namespace {ns}", "", "\n\n".intercalate body, "", s!"end {ns}", ""]

/-- A field's JSON schema, as the protobuf JSON mapping writes it. -/
partial def Ty.schema : Ty → Lean.Json
  | .nat => Lean.Json.mkObj [("type", "integer"), ("minimum", (0 : Nat))]
  | .int => Lean.Json.mkObj [("type", "integer")]
  | .str => Lean.Json.mkObj [("type", "string")]
  | .bool => Lean.Json.mkObj [("type", "boolean")]
  | .msg n => Lean.Json.mkObj [("$ref", Lean.Json.str ("#/components/schemas/" ++ n))]
  | .list t => Lean.Json.mkObj [("type", "array"), ("items", t.schema)]
  | .opt t => t.schema

/-- A message's JSON schema: its fields, the ones that are not Option required, nothing else. -/
def Message.schema (m : Message) : Lean.Json :=
  Lean.Json.mkObj ([("type", Lean.Json.str "object"), ("title", Lean.Json.str m.name),
    ("properties", Lean.Json.mkObj (m.fields.map fun f => (f.name, f.ty.schema))),
    ("required", Lean.Json.arr (m.fields.filterMap (fun f => match f.ty with | .opt _ => none | _ => some (Lean.Json.str f.name))).toArray),
    ("additionalProperties", Lean.Json.bool false)] ++
    (if m.doc.isEmpty then [] else [("description", Lean.Json.str m.doc)]))

end LeanFM.Session.Types
