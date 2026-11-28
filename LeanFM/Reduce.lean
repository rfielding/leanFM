import Lean.Data.Json
import LeanFM.CallLimits

/-! # reduce_run: descriptive numbers and charts from a run
(clause selfhost.mcp.logic.reduce; decision logic-reduce; hazards reduce.*)

A chart's reducer is a small program that runs, not a sentence. The language is a sandboxed Lisp:
`define` names values and functions, numbers are exact rationals, and names resolve only to a fixed
primitive list, the program's defines and parameters. It has no IO, no clock, no randomness and no
way to turn a string into code, so the same program over the same run gives the same answer.

Requirements this module is held to:
* positive (AG): every output is the value of its form over the run; every chart carries its data,
  title and units; the answer says how many ticks it used.
* negative (never): a name outside the list; a division by zero answered as a number; a program past
  its tick budget, its depth bound or the bit bound on numbers; a chart over maxPoints drawn whole. -/

namespace LeanFM.Reduce
open Lean

def maxDepth : Nat := 10000
def maxBits : Nat := 4096
def maxPoints : Nat := 2000
def defaultTicks : Nat := 1000000

/-- The tick budget: LEANFM_REDUCE_TICKS at startup, else `defaultTicks`. No call raises it. -/
initialize tickBudget : IO.Ref Nat ← IO.mkRef defaultTicks

def parseTicks (raw : Option String) : Except String Nat :=
  match raw with
  | none => .ok defaultTicks
  | some r => match r.trimAscii.toString.toNat? with
    | some n => if n ≥ 1 then .ok n else .error "LEANFM_REDUCE_TICKS must be a whole number of at least 1"
    | none => .error "LEANFM_REDUCE_TICKS must be a whole number of at least 1 (reduce_run's tick budget)"

/-- Read LEANFM_REDUCE_TICKS once at startup; a malformed value stops startup. -/
def configureFromEnv : IO Unit := do
  match parseTicks (← IO.getEnv "LEANFM_REDUCE_TICKS") with
  | .ok n => tickBudget.set n
  | .error e => throw (IO.userError e)

/-! ## Reading -/

inductive Sx where
  | atom (s : String)
  | str (s : String)
  | list (xs : List Sx)
  deriving Repr, Inhabited, BEq

partial def Sx.text : Sx → String
  | .atom s => s
  | .str s => "\"" ++ s ++ "\""
  | .list xs => "(" ++ " ".intercalate (xs.map Sx.text) ++ ")"

inductive Tok | lp | rp | atom (s : String) | str (s : String)
  deriving Repr, BEq

def tokenize (s : String) : Except String (List Tok) := do
  let mut out : Array Tok := #[]
  let mut cs := s.toList
  let mut fuel := cs.length + 1
  while fuel > 0 do
    fuel := fuel - 1
    match cs with
    | [] => break
    | c :: rest =>
      if c == '(' then out := out.push .lp; cs := rest
      else if c == ')' then out := out.push .rp; cs := rest
      else if c.isWhitespace then cs := rest
      else if c == ';' then cs := rest.dropWhile (· != '\n')
      else if c == '"' then
        let mut acc : Array Char := #[]
        let mut r := rest
        let mut closed := false
        let mut f2 := r.length + 1
        while f2 > 0 do
          f2 := f2 - 1
          match r with
          | [] => break
          | '"' :: r' => closed := true; r := r'; break
          | '\\' :: x :: r' => acc := acc.push x; r := r'
          | x :: r' => acc := acc.push x; r := r'
        unless closed do throw "a string is not closed with \""
        out := out.push (.str (String.ofList acc.toList)); cs := r
      else
        let word := cs.takeWhile fun x => !(x.isWhitespace || x == '(' || x == ')' || x == '"' || x == ';')
        out := out.push (.atom (String.ofList word)); cs := cs.drop word.length
  return out.toList

partial def parseOne : List Tok → Except String (Sx × List Tok)
  | [] => .error "the program ends before a form is complete"
  | .rp :: _ => .error "a ) closes nothing"
  | .atom s :: r => .ok (.atom s, r)
  | .str s :: r => .ok (.str s, r)
  | .lp :: r => do
    let mut acc : Array Sx := #[]
    let mut rest := r
    repeat
      match rest with
      | .rp :: r' => return (.list acc.toList, r')
      | [] => throw "a ( is not closed"
      | _ =>
        let (x, r') ← parseOne rest
        acc := acc.push x
        rest := r'
    throw "a ( is not closed"

def read (s : String) : Except String (List Sx) := do
  let mut toks ← tokenize s
  let mut out : Array Sx := #[]
  let mut fuel := toks.length + 1
  while !toks.isEmpty && fuel > 0 do
    fuel := fuel - 1
    let (x, r) ← parseOne toks
    out := out.push x
    toks := r
  return out.toList

/-- A number written as an integer, a decimal (0.25) or a fraction (1/20), exactly. -/
def parseNum (s : String) : Option Rat :=
  let neg := s.startsWith "-"
  let body := if neg then (s.drop 1).toString else s
  let sign : Rat := if neg then -1 else 1
  if body.isEmpty || !(body.front.isDigit) then none else
  match body.splitOn "/" with
  | [a, b] => match a.toNat?, b.toNat? with
    | some x, some y => if y == 0 then none else some (sign * (x : Rat) / (y : Rat))
    | _, _ => none
  | [a] => match a.splitOn "." with
    | [w] => w.toNat?.map fun n => sign * (n : Rat)
    | [w, f] => match w.toNat?, f.toNat? with
      | some x, some y => some (sign * ((x : Rat) + (y : Rat) / ((10 ^ f.length : Nat) : Rat)))
      | _, _ => none
    | _ => none
  | _ => none

/-! ## Values -/

inductive Value where
  | num (q : Rat)
  | str (s : String)
  | bool (b : Bool)
  | list (xs : List Value)
  | event (i : Nat)
  | closure (params : List String) (body : Sx) (scope : List (String × Value))
  | prim (name : String)
  | chart (spec : Json)
  deriving Inhabited

/-- One event of the run. -/
structure Ev where
  id : String
  label : String
  time : Rat
  fields : List (String × Value)
  cause : Option Nat
  deriving Inhabited

def ratText (q : Rat) : String := if q.den == 1 then toString q.num else s!"{q.num}/{q.den}"
def ratFloat (q : Rat) : Float := Float.ofInt q.num / Float.ofNat q.den

def jsonRat (n : JsonNumber) : Rat := (n.mantissa : Rat) / ((10 ^ n.exponent : Nat) : Rat)

partial def ofJson : Json → Value
  | .num n => .num (jsonRat n)
  | .str s => .str s
  | .bool b => .bool b
  | .arr a => .list (a.toList.map ofJson)
  | .null => .list []
  | j => .str j.compress

def primitives : List String :=
  ["+", "-", "*", "/", "=", "<", "<=", ">", ">=", "not", "zero?", "list", "cons", "first", "rest", "empty?",
   "length", "append", "map", "filter", "fold", "sum", "count", "min", "max", "countBy", "sumBy", "field",
   "has?", "label", "time", "cause", "events", "pie", "xy", "histogram"]

def special : List String := ["define", "lambda", "if", "let", "and", "or"]

/-! ## Names

A program's names are checked before it runs (unbound), and resolved while it runs (resolve); both
are total, and LeanFM/ReduceProofs.lean proves what they let through. -/

/-- A name the check accepts where `bound` are the names in scope. -/
def allowed (defs bound : List String) (a : String) : Bool :=
  (parseNum a).isSome || a == "true" || a == "false" || bound.contains a || defs.contains a || primitives.contains a

def paramNames (ps : List Sx) : List String := ps.filterMap fun | .atom p => some p | _ => none

mutual
/-- The first name a form uses that is not a number, true or false, bound, a define, a primitive or
a special form, checked over the whole program before anything runs, so a name outside the list never
reaches evaluation (decision logic-reduce). -/
def unbound (defs bound : List String) : Sx → Option String
  | .str _ => none
  | .atom a => if allowed defs bound a then none else some a
  | .list [.atom "lambda", .list ps, body] => unbound defs (paramNames ps ++ bound) body
  | .list [.atom "let", .list binds, body] => unboundLet defs bound binds body
  | .list (.atom s :: rest) =>
    if special.contains s || allowed defs bound s then unboundAll defs bound rest else some s
  | .list xs => unboundAll defs bound xs
termination_by x => sizeOf x
def unboundAll (defs bound : List String) : List Sx → Option String
  | [] => none
  | x :: xs => (unbound defs bound x).orElse fun _ => unboundAll defs bound xs
termination_by xs => sizeOf xs
/-- A let's bindings in order, each name in scope for the ones after it and the body; a binding that
is not (name expr) is checked as a form. -/
def unboundLet (defs bound : List String) : List Sx → Sx → Option String
  | [], body => unbound defs bound body
  | .list [.atom n, e] :: bs, body => (unbound defs bound e).orElse fun _ => unboundLet defs (n :: bound) bs body
  | b :: bs, body => (unbound defs bound b).orElse fun _ => unboundLet defs bound bs body
termination_by bs body => sizeOf bs + sizeOf body
end

/-- What a name means while the program runs: a number, true or false, a local, a define, or a
primitive, and nothing else. -/
def resolve (scope : List (String × Value)) (globals : Std.HashMap String Value) (a : String) : Option Value :=
  match parseNum a with
  | some q => some (.num q)
  | none =>
    if a == "true" then some (.bool true)
    else if a == "false" then some (.bool false)
    else match scope.lookup a with
      | some v => some v
      | none => match globals.get? a with
        | some v => some v
        | none => if primitives.contains a then some (.prim a) else none

/-! ## Evaluation -/

structure St where
  ticks : Nat := 0
  budget : Nat
  globals : Std.HashMap String Value := {}

abbrev M := ExceptT String (StateM St)

def tick (k : Nat := 1) : M Unit := do
  let s ← get
  if s.ticks + k > s.budget then
    throw s!"the program ran past its tick budget of {s.budget} steps; it may loop or recurse without end (the operator can raise the budget with LEANFM_REDUCE_TICKS)"
  set { s with ticks := s.ticks + k }

def bitsOk (q : Rat) : Bool := q.num.natAbs.log2 < maxBits && q.den.log2 < maxBits

def numV (q : Rat) (what : String) : M Value :=
  if bitsOk q then pure (.num q)
  else throw s!"{what} gives a number over {maxBits} bits; a reducer never needs one so large"

def typeName : Value → String
  | .num _ => "a number" | .str _ => "a string" | .bool _ => "a boolean" | .list _ => "a list"
  | .event _ => "an event" | .closure .. | .prim _ => "a function" | .chart _ => "a chart"

def asNum (what : String) : Value → M Rat
  | .num q => pure q
  | v => throw s!"{what} needs a number, not {typeName v}"
def asList (what : String) : Value → M (List Value)
  | .list xs => pure xs
  | v => throw s!"{what} needs a list, not {typeName v}"
def asStr (what : String) : Value → M String
  | .str s => pure s
  | v => throw s!"{what} needs a string, not {typeName v}"
def asBool (what : String) : Value → M Bool
  | .bool b => pure b
  | v => throw s!"{what} needs true or false, not {typeName v}"

partial def valueEq : Value → Value → Bool
  | .num a, .num b => a == b
  | .str a, .str b => a == b
  | .bool a, .bool b => a == b
  | .event a, .event b => a == b
  | .list a, .list b => a.length == b.length && (a.zip b).all fun (x, y) => valueEq x y
  | _, _ => false

partial def keyText : Value → String
  | .num q => ratText q
  | .str s => s
  | .bool b => toString b
  | .event i => s!"event {i}"
  | .list xs => "(" ++ " ".intercalate (xs.map keyText) ++ ")"
  | _ => "?"

/-- Points of a chart, cut at maxPoints. -/
def cutPoints (xs : List Json) : Json × Nat :=
  if xs.length > maxPoints then (Json.arr (xs.take maxPoints).toArray, xs.length - maxPoints) else (Json.arr xs.toArray, 0)

def numJson (q : Rat) : Json := Json.mkObj [("exact", Json.str (ratText q)), ("value", toJson (ratFloat q))]

mutual
partial def eval (run : Array Ev) (scope : List (String × Value)) (d : Nat) (x : Sx) : M Value := do
  tick
  if d > maxDepth then
    throw s!"the program nests calls more than {maxDepth} deep, which could exhaust the server's stack; recurse over a shorter list or use fold"
  match x with
  | .str s => pure (.str s)
  | .atom a =>
    match resolve scope (← get).globals a with
    | some v => return v
    | none => throw s!"{a} is not defined here"
  | .list [] => pure (.list [])
  | .list (.atom "if" :: rest) =>
    match rest with
    | [c, t, e] => if ← asBool s!"the test of {x.text}" (← eval run scope d c) then eval run scope d t else eval run scope d e
    | _ => throw s!"if takes a test, a then and an else: {x.text}"
  | .list (.atom "and" :: rest) =>
    for r in rest do
      unless ← asBool s!"and in {x.text}" (← eval run scope d r) do return .bool false
    return .bool true
  | .list (.atom "or" :: rest) =>
    for r in rest do
      if ← asBool s!"or in {x.text}" (← eval run scope d r) then return .bool true
    return .bool false
  | .list [.atom "lambda", .list ps, body] =>
    let names ← ps.mapM fun | .atom p => pure p | p => throw s!"a parameter is a name, not {p.text}"
    return .closure names body scope
  | .list [.atom "let", .list binds, body] =>
    let mut sc := scope
    for b in binds do
      match b with
      | .list [.atom n, e] => sc := (n, ← eval run sc d e) :: sc
      | _ => throw s!"let binds (name expr) pairs: {b.text}"
    eval run sc d body
  | .list (.atom "define" :: _) => throw s!"define is a top-level form: {x.text}"
  | .list (f :: args) =>
    let fv ← eval run scope d f
    let avs ← args.mapM (eval run scope d)
    apply run fv avs (d + 1) x

partial def apply (run : Array Ev) (f : Value) (args : List Value) (d : Nat) (at_ : Sx) : M Value := do
  match f with
  | .closure ps body sc =>
    if ps.length != args.length then
      throw s!"{at_.text} gives {args.length} arguments to a function of {ps.length}"
    eval run (ps.zip args ++ sc) d body
  | .prim p => prim run p args d at_
  | v => throw s!"{at_.text}: {typeName v} is not a function"

partial def prim (run : Array Ev) (p : String) (args : List Value) (d : Nat) (at_ : Sx) : M Value := do
  let w := at_.text
  let nums := fun (xs : List Value) => xs.mapM (asNum w)
  let evOf (v : Value) : M Ev := match v with
    | .event i => pure run[i]!
    | v => throw s!"{w} needs an event, not {typeName v}"
  match p, args with
  | "+", xs => do numV ((← nums xs).foldl (· + ·) 0) w
  | "*", xs => do numV ((← nums xs).foldl (· * ·) 1) w
  | "-", [a] => do numV (-(← asNum w a)) w
  | "-", a :: bs => do numV ((← nums bs).foldl (· - ·) (← asNum w a)) w
  | "/", [a, b] => do
    let y ← asNum w b
    if y == 0 then throw s!"{w} divides by zero; test the divisor with zero? first"
    numV ((← asNum w a) / y) w
  | "=", [a, b] => pure (.bool (valueEq a b))
  | "<", [a, b] => do pure (.bool ((← asNum w a) < (← asNum w b)))
  | "<=", [a, b] => do pure (.bool ((← asNum w a) ≤ (← asNum w b)))
  | ">", [a, b] => do pure (.bool ((← asNum w a) > (← asNum w b)))
  | ">=", [a, b] => do pure (.bool ((← asNum w a) ≥ (← asNum w b)))
  | "not", [a] => do pure (.bool !(← asBool w a))
  | "zero?", [a] => do pure (.bool ((← asNum w a) == 0))
  | "list", xs => do tick xs.length; pure (.list xs)
  | "cons", [a, b] => do pure (.list (a :: (← asList w b)))
  | "first", [a] => do match ← asList w a with
    | x :: _ => pure x | [] => throw s!"{w}: first of an empty list"
  | "rest", [a] => do match ← asList w a with
    | _ :: xs => pure (.list xs) | [] => throw s!"{w}: rest of an empty list"
  | "empty?", [a] => do pure (.bool (← asList w a).isEmpty)
  | "length", [a] => do pure (.num (← asList w a).length)
  | "count", [a] => do pure (.num (← asList w a).length)
  | "append", [a, b] => do
    let xs ← asList w a; let ys ← asList w b
    tick xs.length; pure (.list (xs ++ ys))
  | "map", [f, xs] => do pure (.list (← (← asList w xs).mapM fun x => apply run f [x] d at_))
  | "filter", [f, xs] => do
    pure (.list (← (← asList w xs).filterM fun x => do asBool w (← apply run f [x] d at_)))
  | "fold", [f, init, xs] => do (← asList w xs).foldlM (fun acc x => apply run f [acc, x] d at_) init
  | "sum", [xs] => do
    let qs ← nums (← asList w xs); tick qs.length; numV (qs.foldl (· + ·) 0) w
  | "min", [xs] => do match ← nums (← asList w xs) with
    | q :: qs => tick qs.length; pure (.num (qs.foldl min q)) | [] => throw s!"{w}: min of an empty list"
  | "max", [xs] => do match ← nums (← asList w xs) with
    | q :: qs => tick qs.length; pure (.num (qs.foldl max q)) | [] => throw s!"{w}: max of an empty list"
  | "countBy", [f, xs] => do
    let mut acc : Array (Value × Nat) := #[]
    for x in ← asList w xs do
      let k ← apply run f [x] d at_
      tick acc.size
      match acc.findIdx? (fun (k', _) => valueEq k k') with
      | some i => acc := acc.modify i fun (k', n) => (k', n + 1)
      | none => acc := acc.push (k, 1)
    pure (.list (acc.toList.map fun (k, n) => .list [k, .num n]))
  | "sumBy", [f, g, xs] => do
    let mut acc : Array (Value × Rat) := #[]
    for x in ← asList w xs do
      let k ← apply run f [x] d at_
      let v ← asNum w (← apply run g [x] d at_)
      tick acc.size
      match acc.findIdx? (fun (k', _) => valueEq k k') with
      | some i => acc := acc.modify i fun (k', n) => (k', n + v)
      | none => acc := acc.push (k, v)
    pure (.list (← acc.toList.mapM fun (k, n) => do pure (.list [k, ← numV n w])))
  | "field", [e, n] => do
    let ev ← evOf e; let name ← asStr w n
    match ev.fields.lookup name with
    | some v => pure v
    | none => throw s!"{w}: event {ev.id} ({ev.label}) has no field {name}; test with has? first"
  | "has?", [e, n] => do pure (.bool ((← evOf e).fields.lookup (← asStr w n)).isSome)
  | "label", [e] => do pure (.str (← evOf e).label)
  | "time", [e] => do pure (.num (← evOf e).time)
  | "cause", [e] => do
    let ev ← evOf e
    match ev.cause with
    | some i => pure (.event i)
    | none => throw s!"{w}: event {ev.id} ({ev.label}) names no cause"
  | "events", [] => do tick run.size; pure (.list ((List.range run.size).map Value.event))
  | "events", [l] => do
    let lab ← asStr w l; tick run.size
    pure (.list (((List.range run.size).filter fun i => run[i]!.label == lab).map Value.event))
  | "pie", [t, u, ps] => do
    let pairs ← (← asList w ps).mapM fun pr => do match pr with
      | .list [k, v] => do
        let q ← asNum w v
        if q < 0 then throw s!"{w}: a pie slice cannot be negative ({keyText k} is {ratText q})"
        pure (Json.mkObj [("label", Json.str (keyText k)), ("value", numJson q)])
      | v => throw s!"{w}: a pie takes (label value) pairs, not {typeName v}"
    let (data, cut) := cutPoints pairs
    pure (.chart (Json.mkObj [("kind", "pie"), ("title", Json.str (← asStr w t)), ("unit", Json.str (← asStr w u)), ("data", data), ("cut", cut)]))
  | "xy", [t, xu, yu, ps] => do
    let pts ← (← asList w ps).mapM fun pr => do match pr with
      | .list [x, y] => do pure (Json.mkObj [("x", numJson (← asNum w x)), ("y", numJson (← asNum w y))])
      | v => throw s!"{w}: an xy chart takes (x y) points, not {typeName v}"
    let (data, cut) := cutPoints pts
    pure (.chart (Json.mkObj [("kind", "xy"), ("title", Json.str (← asStr w t)), ("xunit", Json.str (← asStr w xu)),
      ("yunit", Json.str (← asStr w yu)), ("data", data), ("cut", cut)]))
  | "histogram", [t, u, width, vs] => do
    let bw ← asNum w width
    if bw ≤ 0 then throw s!"{w}: a histogram's bin width must be above zero"
    let qs ← nums (← asList w vs)
    tick qs.length
    let bins : List (Int × Nat) := qs.foldl (fun acc q =>
      let b := (q / bw).floor
      match acc.lookup b with
      | some _ => acc.map fun (k, n) => if k == b then (k, n + 1) else (k, n)
      | none => acc ++ [(b, 1)]) []
    let sorted := bins.mergeSort (fun a b => a.1 ≤ b.1)
    let rows := sorted.map fun (b, n) => Json.mkObj [("from", numJson ((b : Rat) * bw)), ("to", numJson (((b : Rat) + 1) * bw)), ("count", toJson n)]
    let (data, cut) := cutPoints rows
    pure (.chart (Json.mkObj [("kind", "histogram"), ("title", Json.str (← asStr w t)), ("unit", Json.str (← asStr w u)),
      ("width", numJson bw), ("data", data), ("cut", cut)]))
  | p, args => throw s!"{w}: {p} does not take {args.length} argument{if args.length == 1 then "" else "s"} of these kinds"
end

/-- The value of an output as JSON. -/
partial def render : Value → Json
  | .num q => numJson q
  | .str s => Json.str s
  | .bool b => Json.bool b
  | .list xs => Json.arr (xs.map render).toArray
  | .event i => Json.mkObj [("event", toJson i)]
  | .closure .. | .prim _ => Json.str "a function"
  | .chart j => j

/-! ## Drawing -/

def esc (s : String) : String :=
  s.replace "&" "&amp;" |>.replace "<" "&lt;" |>.replace ">" "&gt;" |>.replace "\"" "&quot;"

/-- A number to two decimals, without trailing zeros: 28.57, 50, 0.5. -/
def fmt (x : Float) : String :=
  let r := Float.round (x * 100) / 100
  let s := toString r
  if s.contains '.' then
    let t := (s.toList.reverse.dropWhile (· == '0')).reverse
    String.ofList (if t.getLast? == some '.' then t.dropLast else t)
  else s

def pi : Float := 3.141592653589793

def palette : List String := ["#4e79a7", "#f28e2b", "#59a14f", "#e15759", "#76b7b2", "#edc948", "#b07aa1", "#9c755f"]

def getF (j : Json) (k : String) : Float :=
  match (j.getObjValD k).getObjValD "value" with
  | .num n => n.toFloat
  | _ => 0

/-- An SVG of a chart spec, in the light or dark theme. -/
def svg (spec : Json) (dark : Bool) : String := Id.run do
  let fg := if dark then "#e8e8e8" else "#1a1a1a"
  let bg := if dark then "#111418" else "#ffffff"
  let axis := if dark then "#888" else "#666"
  let kind := (spec.getObjValAs? String "kind").toOption.getD ""
  let title := esc ((spec.getObjValAs? String "title").toOption.getD "")
  let data := ((spec.getObjValD "data").getArr?).toOption.getD #[]
  let w := 640.0; let h := 360.0
  let mut out := s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"640\" height=\"360\" viewBox=\"0 0 640 360\" role=\"img\" aria-label=\"{title}\"><rect width=\"640\" height=\"360\" fill=\"{bg}\"/><text x=\"20\" y=\"24\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"16\">{title}</text>"
  if kind == "pie" then
    let vals := data.map (getF · "value")
    let total := vals.foldl (· + ·) 0
    let cx := 180.0; let cy := 195.0; let r := 130.0
    let mut a := -pi / 2
    for i in [0:data.size] do
      let v := vals[i]!
      let col := palette[i % palette.length]!
      let lab := esc ((data[i]!.getObjValAs? String "label").toOption.getD "")
      let pct := if total > 0 then v / total * 100 else 0
      if total > 0 && v > 0 then
        let b := a + 2 * pi * v / total
        if v == total then
          out := out ++ s!"<circle cx=\"{fmt cx}\" cy=\"{fmt cy}\" r=\"{fmt r}\" fill=\"{col}\"/>"
        else
          let large := if b - a > pi then 1 else 0
          out := out ++ s!"<path d=\"M{fmt cx},{fmt cy} L{fmt (cx + r * Float.cos a)},{fmt (cy + r * Float.sin a)} A{fmt r},{fmt r} 0 {large} 1 {fmt (cx + r * Float.cos b)},{fmt (cy + r * Float.sin b)} Z\" fill=\"{col}\" stroke=\"{bg}\"/>"
        a := b
      let ly := 70.0 + 24.0 * i.toFloat
      out := out ++ s!"<rect x=\"350\" y=\"{fmt (ly - 12)}\" width=\"14\" height=\"14\" fill=\"{col}\"/><text x=\"372\" y=\"{fmt ly}\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"13\">{lab}: {fmt v} ({fmt pct}%)</text>"
  else
    -- xy and histogram share axes
    let pts : Array (Float × Float × Float) := if kind == "xy" then data.map fun p => (getF p "x", getF p "x", getF p "y")
      else data.map fun p => (getF p "from", getF p "to", ((p.getObjValD "count").getNat?.toOption.getD 0).toFloat)
    let col (f : Float × Float × Float → Float) (pick : Float → Float → Float) (dflt : Float) : Float :=
      match pts.toList.map f with
      | [] => dflt
      | v :: vs => vs.foldl pick v
    let x0 := col (·.1) min 0
    let x1 := col (·.2.1) max 1
    let y0 := if kind == "histogram" then 0 else col (·.2.2) min 0
    let y1 := col (·.2.2) max 1
    let sx := fun (x : Float) => 60 + (if x1 > x0 then (x - x0) / (x1 - x0) else 0.5) * (w - 90)
    let sy := fun (y : Float) => h - 40 - (if y1 > y0 then (y - y0) / (y1 - y0) else 0.5) * (h - 90)
    out := out ++ s!"<line x1=\"60\" y1=\"{fmt (h - 40)}\" x2=\"{fmt (w - 30)}\" y2=\"{fmt (h - 40)}\" stroke=\"{axis}\"/><line x1=\"60\" y1=\"50\" x2=\"60\" y2=\"{fmt (h - 40)}\" stroke=\"{axis}\"/>"
    out := out ++ s!"<text x=\"60\" y=\"{fmt (h - 20)}\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"12\">{fmt x0}</text><text x=\"{fmt (w - 30)}\" y=\"{fmt (h - 20)}\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"12\" text-anchor=\"end\">{fmt x1}</text>"
    out := out ++ s!"<text x=\"55\" y=\"{fmt (h - 40)}\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"12\" text-anchor=\"end\">{fmt y0}</text><text x=\"55\" y=\"55\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"12\" text-anchor=\"end\">{fmt y1}</text>"
    let xu := esc ((spec.getObjValAs? String (if kind == "xy" then "xunit" else "unit")).toOption.getD "")
    let yu := if kind == "xy" then esc ((spec.getObjValAs? String "yunit").toOption.getD "") else "count"
    out := out ++ s!"<text x=\"{fmt ((w + 30) / 2)}\" y=\"{fmt (h - 8)}\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"12\" text-anchor=\"middle\">{xu}</text><text x=\"64\" y=\"44\" fill=\"{fg}\" font-family=\"sans-serif\" font-size=\"12\">{yu}</text>"
    if kind == "xy" then
      let line := " ".intercalate (pts.toList.map fun (x, _, y) => s!"{fmt (sx x)},{fmt (sy y)}")
      out := out ++ s!"<polyline points=\"{line}\" fill=\"none\" stroke=\"{palette[0]!}\" stroke-width=\"2\"/>"
    else
      for (a, b, c) in pts do
        out := out ++ s!"<rect x=\"{fmt (sx a)}\" y=\"{fmt (sy c)}\" width=\"{fmt (max 1 (sx b - sx a - 1))}\" height=\"{fmt (sy 0 - sy c)}\" fill=\"{palette[0]!}\"/>"
  return out ++ "</svg>"

/-! ## The run -/

def nsRat (j : Json) : Option Rat :=
  match j with
  | .num n => some (jsonRat n / 1000000000)
  | .str s => s.toNat?.map fun n => (n : Rat) / 1000000000
  | _ => none

/-- The run's events from event objects or leanFM event lines, causes resolved to positions. -/
def runOf (raw : Array Json) : Except String (Array Ev) := do
  let ids := raw.mapIdx fun i j => ((j.getObjValAs? String "id").toOption.getD s!"e{i + 1}")
  let evs ← raw.mapIdxM fun i j => do
    let label ← match j.getObjValD "label" with
      | .str s => pure s
      | _ => throw s!"event {i + 1} has no label"
    let time := match j.getObjValD "t" with
      | .num n => jsonRat n
      | _ => (nsRat (j.getObjValD "ts")).getD 0
    let body := [j.getObjValD "body", j.getObjValD "fields", j.getObjValD "payload"].find? (fun b => match b with | .obj _ => true | _ => false)
    let fields := match body with
      | some (.obj kvs) => kvs.toList.map fun (k, v) => (k, ofJson v)
      | _ => []
    let cause := match j.getObjValD "cause" with
      | .str c => ids.findIdx? (· == c)
      | _ => none
    pure ({ id := ids[i]!, label, time, fields, cause } : Ev)
  return evs

def logLines (text : String) : Except String (Array Json) :=
  (text.splitOn "\n").toArray.filterMapM fun line =>
    if line.startsWith "{\"type\":\"leanFM\"" then
      match Json.parse line with
      | .ok j => pure (some j)
      | .error _ => throw s!"an event line is not JSON: {(line.take 60).toString}"
    else pure none

/-! ## The tool -/

/-- Run a program over a run: each non-define form's value, the ticks used. -/
def runProgram (program : String) (run : Array Ev) (budget : Nat) : Except String (List (Sx × Value) × Nat) := do
  let forms ← read program
  if forms.isEmpty then throw "the program has no forms"
  let defName : Sx → Option String
    | .list [.atom "define", .atom n, _] => some n
    | .list (.atom "define" :: .list (.atom n :: _) :: _) => some n
    | _ => none
  let defs := forms.filterMap defName
  for n in defs do
    if primitives.contains n || special.contains n then throw s!"define {n}: {n} is a primitive and cannot be redefined"
  if let some n := defs.find? (fun n => (defs.filter (· == n)).length > 1) then throw s!"{n} is defined twice"
  for f in forms do
    let (bound, body) := match f with
      | .list [.atom "define", .atom _, e] => ([], e)
      | .list [.atom "define", .list (_ :: ps), e] => (ps.filterMap (fun | .atom p => some p | _ => none), e)
      | e => ([], e)
    if let some u := unbound defs bound body then
      throw s!"{u} is not a primitive, a define of this program or a parameter; the names are {", ".intercalate primitives}"
  let go : M (List (Sx × Value)) := do
    -- function defines first, so every define may call any other, itself included
    for f in forms do
      if let .list [.atom "define", .list (.atom n :: ps), body] := f then
        let names ← ps.mapM fun | .atom p => pure p | p => throw s!"a parameter is a name, not {p.text}"
        modify fun s => { s with globals := s.globals.insert n (.closure names body []) }
    let mut outs : Array (Sx × Value) := #[]
    for f in forms do
      match f with
      | .list [.atom "define", .atom n, e] =>
        let v ← eval run [] 0 e
        modify fun s => { s with globals := s.globals.insert n v }
      | .list (.atom "define" :: .list _ :: _) => pure ()
      | .list (.atom "define" :: _) => throw s!"define takes a name and a value, or (name params) and a body: {f.text}"
      | e => outs := outs.push (e, ← eval run [] 0 e)
    return outs.toList
  let (r, st) := (go.run).run { budget }
  match r with
  | .ok outs => return (outs, st.ticks)
  | .error e => throw e

def check (args : Json) (budget : Nat := defaultTicks) : Except String Json := do
  let program ← match args.getObjValD "program" with
    | .str s => pure s
    | _ => throw "reduce_run needs a program, such as (pie \"outcomes\" \"events\" (countBy label (events)))"
  let raw ← match args.getObjValD "events", args.getObjValD "log" with
    | .arr a, _ => pure a
    | _, .str l => logLines l
    | _, _ => throw "reduce_run needs events ([{id, label, t or ts, cause?, body?}]), log (event lines) or serverLog"
  let lim := LeanFM.CallLimits.get args "reduceEvents"
  if raw.size > lim then
    throw s!"the run has {raw.size} events, over reduceEvents {lim}; {LeanFM.CallLimits.raise "reduceEvents" lim}"
  let run ← runOf raw
  let (outs, ticks) ← runProgram program run budget
  let theme := (args.getObjValAs? String "theme").toOption
  let outJson := outs.map fun (f, v) =>
    let base := [("form", Json.str f.text), ("value", render v)]
    match v, theme with
    | .chart spec, some t => Json.mkObj (base ++ [("svg", Json.str (svg spec (t == "dark")))])
    | _, _ => Json.mkObj base
  let charts := (outs.filter fun (_, v) => match v with | .chart _ => true | _ => false).length
  return Json.mkObj [("tool", "reduce_run"), ("verdict", "computed"),
    ("reading", Json.str s!"{outs.length} output{if outs.length == 1 then "" else "s"} ({charts} chart{if charts == 1 then "" else "s"}) over {run.size} events in {ticks} ticks of {budget}"),
    ("outputs", Json.arr outJson.toArray), ("events", toJson run.size), ("ticks", toJson ticks), ("tickBudget", toJson budget)]

end LeanFM.Reduce
