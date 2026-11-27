import Lean.Data.Json

/-!
# Claims over measured values (clause selfhost.mcp.logic.signal, decision logic-signal)

A recorded run of readings, such as an Arduino's water, food and temperature levels and a webcam's
motion, checked against claims written in the same plain words as the rest of the logic. Each
claim gets a margin at every sample: how far it is from failing, in the units of the readings it
compares. The check is one pass per word of the claim: windows are sliding minimums and maximums,
so the time is the claim's size times the number of samples.
-/

open Lean

namespace LeanFM.Signal

def maxWords : Nat := 256
def maxSamples : Nat := 100000
def maxPoints : Nat := 2000

/-- A claim. `possibly` also stands for `inevitably`: over one recorded run they mean the same. -/
inductive Claim where
  | over (f : String) (c : Float)
  | under (f : String) (c : Float)
  | on (m : String)
  | not (p : Claim)
  | and (ps : List Claim)
  | or (ps : List Claim)
  | implies (a b : Claim)
  | within (d : Float) (p : Claim)
  | throughout (d : Float) (p : Claim)
  | always (p : Claim)
  | never (p : Claim)
  | possibly (p : Claim)
  deriving Inhabited

/-! ## Reading a claim -/

inductive Sx where
  | atom (s : String)
  | list (xs : List Sx)
  deriving Inhabited

def tokens (s : String) : List String := Id.run do
  let mut out : Array String := #[]
  let mut cur := ""
  for c in s.toList do
    if c == '(' || c == ')' || c.isWhitespace then
      if cur != "" then out := out.push cur; cur := ""
      if c == '(' || c == ')' then out := out.push c.toString
    else cur := cur.push c
  if cur != "" then out := out.push cur
  return out.toList

partial def sexp : List String → Except String (Sx × List String)
  | "(" :: rest => do
      let rec go (acc : Array Sx) : List String → Except String (Sx × List String)
        | ")" :: r => pure (.list acc.toList, r)
        | [] => throw "a ( is never closed"
        | ts => do let (x, r) ← sexp ts; go (acc.push x) r
      go #[] rest
  | ")" :: _ => throw "a ) closes nothing"
  | t :: rest => pure (.atom t, rest)
  | [] => throw "the claim is empty"

def number (what s : String) : Except String Float :=
  if s.isEmpty || !s.toList.all (fun c => c.isDigit || c == '.' || c == '-') then
    throw s!"{what} is a number, not {s}"
  else match Json.parse s with
    | .ok (.num n) => pure n.toFloat
    | _ => throw s!"{what} is a number, not {s}"

def words : String := "above, below, on, not, and, or, implies, within, throughout, always, never, possibly, inevitably"

partial def claimOf (x : Sx) : StateT Nat (Except String) Claim := do
  modify (· + 1)
  if (← get) > maxWords then throw s!"a claim has at most {maxWords} words"
  let lift {α} (e : Except String α) : StateT Nat (Except String) α := liftM (m := Except String) e
  match x with
  | .list [.atom "above", .atom f, .atom c] => return .over f (← lift (number "the bound of above" c))
  | .list [.atom "below", .atom f, .atom c] => return .under f (← lift (number "the bound of below" c))
  | .list [.atom "on", .atom m] => return .on m
  | .list [.atom "not", p] => return .not (← claimOf p)
  | .list (.atom "and" :: ps) => return .and (← ps.mapM claimOf)
  | .list (.atom "or" :: ps) => return .or (← ps.mapM claimOf)
  | .list [.atom "implies", a, b] => return .implies (← claimOf a) (← claimOf b)
  | .list [.atom w, .atom d, p] =>
      if w == "within" || w == "throughout" then do
        let d ← lift (number s!"the window of {w}" d)
        if d < 0 then throw s!"the window of {w} is not negative"
        let p ← claimOf p
        return if w == "within" then .within d p else .throughout d p
      else throw s!"({w} ...) is not a word here; the words are {words}"
  | .list [.atom "always", p] => return .always (← claimOf p)
  | .list [.atom "never", p] => return .never (← claimOf p)
  | .list [.atom "possibly", p] | .list [.atom "inevitably", p] => return .possibly (← claimOf p)
  | .list (.atom w :: _) => throw s!"({w} ...) is not a word here, or has the wrong number of parts; the words are {words}"
  | .atom a => throw s!"{a} on its own is not a claim; the words are {words}"
  | .list _ => throw "a claim starts with one of its words"

def parse (s : String) : Except String Claim := do
  let (x, rest) ← sexp (tokens s)
  unless rest.isEmpty do throw "text follows the claim"
  let (c, _) ← (claimOf x).run 0
  return c

/-- A number as it was written: rounded to 3 decimals, no trailing zeros. -/
def fmt (x : Float) : String :=
  let k := (x * 1000).round
  let m : Nat := (if k < 0 then -k else k).toUInt64.toNat
  (Json.num ⟨if k < 0 then -(m : Int) else (m : Int), 3⟩).compress

partial def Claim.text : Claim → String
  | .over f c => s!"(above {f} {fmt c})"
  | .under f c => s!"(below {f} {fmt c})"
  | .on m => s!"(on {m})"
  | .not p => s!"(not {p.text})"
  | .and ps => "(and " ++ " ".intercalate (ps.map Claim.text) ++ ")"
  | .or ps => "(or " ++ " ".intercalate (ps.map Claim.text) ++ ")"
  | .implies a b => s!"(implies {a.text} {b.text})"
  | .within d p => s!"(within {fmt d} {p.text})"
  | .throughout d p => s!"(throughout {fmt d} {p.text})"
  | .always p => s!"(always {p.text})"
  | .never p => s!"(never {p.text})"
  | .possibly p => s!"(possibly {p.text})"

partial def Claim.fields : Claim → List String
  | .over f _ | .under f _ => [f]
  | .on _ => []
  | .not p | .within _ p | .throughout _ p | .always p | .never p | .possibly p => p.fields
  | .and ps | .or ps => ps.flatMap Claim.fields
  | .implies a b => a.fields ++ b.fields

/-! ## Samples -/

structure Sample where
  t : Float
  label : String := ""
  vals : List (String × Float) := []
  deriving Inhabited

def numFields (j : Json) (skip : List String) : List (String × Float) :=
  match j with
  | .obj kvs => kvs.toList.filterMap fun (k, v) =>
      if skip.contains k then none else match v with
        | .num n => some (k, n.toFloat)
        | _ => none
  | _ => []

def ofSamples (js : Array Json) : Except String (Array Sample) :=
  js.mapM fun j => do
    let t ← match j.getObjValD "t" with
      | .num n => pure n.toFloat
      | _ => throw "each sample has a time t in seconds"
    let label := (j.getObjValD "label").getStr?.toOption.getD ""
    pure { t, label, vals := numFields j ["t"] }

def ofLog (text : String) : Except String (Array Sample) := do
  let mut out : Array Sample := #[]
  for line in text.splitOn "\n" do
    unless line.startsWith "{\"type\":\"leanFM\"" do continue
    let j ← match Json.parse line with
      | .ok j => pure j
      | .error _ => throw s!"an event line is not JSON: {(line.take 60).toString}"
    let ns : Float ← match j.getObjValD "ts" with
      | .num n => pure n.toFloat
      | .str s => match s.toNat? with
        | some n => pure n.toFloat
        | none => throw s!"an event's ts is not a whole number: {s}"
      | _ => throw "each event line has a ts in nanoseconds"
    out := out.push { t := ns / 1e9, label := (j.getObjValD "label").getStr?.toOption.getD "",
                      vals := numFields (j.getObjValD "payload") [] }
  return out

/-! ## Margins -/

def inf : Float := 1.0 / 0.0

/-- Each field's value at every sample: its latest reading at or before it. -/
def hold (ss : Array Sample) (f : String) : Except String (Array Float) := do
  let some first := ((ss[0]!).vals.lookup f) | throw s!"the claim reads {f} before its first reading (the first sample has no {f})"
  let mut cur := first
  let mut out : Array Float := Array.mkEmpty ss.size
  for s in ss do
    if let some v := s.vals.lookup f then cur := v
    out := out.push cur
  return out

structure Run where
  t : Array Float
  labels : Array String
  vals : List (String × Array Float)
  cutShort : Nat := 0

/-- For each i, the max (or min) of `xs` over samples j ≥ i with t j ≤ t i + d: a monotone deque,
each index pushed and popped once. Also how many windows reach past the last sample. -/
def slide (t xs : Array Float) (d : Float) (isMax : Bool) : Array Float × Nat := Id.run do
  let n := xs.size
  let better := fun (a b : Float) => if isMax then a ≥ b else a ≤ b
  let mut dq : Array Nat := #[]
  let mut head := 0
  let mut r := 0          -- next index to push
  let mut out : Array Float := Array.mkEmpty n
  let mut cut := 0
  for i in [0:n] do
    while r < n && t[r]! ≤ t[i]! + d do
      while dq.size > head && better xs[r]! xs[dq.back!]! do dq := dq.pop
      dq := dq.push r
      r := r + 1
    while head < dq.size && dq[head]! < i do head := head + 1
    out := out.push xs[dq[head]!]!
    if t[n - 1]! < t[i]! + d then cut := cut + 1
  return (out, cut)

def suffix (xs : Array Float) (isMax : Bool) : Array Float := Id.run do
  let n := xs.size
  let mut out := xs
  for k in [1:n] do
    let i := n - 1 - k
    out := out.set! i (if isMax then max out[i]! out[i+1]! else min out[i]! out[i+1]!)
  return out

partial def margin (r : Run) : Claim → StateM Nat (Array Float)
  | .over f c => return ((r.vals.lookup f).getD #[]).map (· - c)
  | .under f c => return ((r.vals.lookup f).getD #[]).map (c - ·)
  | .on m => return r.labels.map fun l => if l == m then inf else -inf
  | .not p => return (← margin r p).map (- ·)
  | .and ps => do
      let ms ← ps.mapM (margin r)
      return ms.foldl (fun acc m => acc.zipWith min m) (r.t.map fun _ => inf)
  | .or ps => do
      let ms ← ps.mapM (margin r)
      return ms.foldl (fun acc m => acc.zipWith max m) (r.t.map fun _ => -inf)
  | .implies a b => do
      let ma ← margin r a; let mb ← margin r b
      return (ma.map (- ·)).zipWith max mb
  | .within d p => do
      let (o, c) := slide r.t (← margin r p) d true
      modify (· + c); return o
  | .throughout d p => do
      let (o, c) := slide r.t (← margin r p) d false
      modify (· + c); return o
  | .always p => return suffix (← margin r p) false
  | .never p => return suffix ((← margin r p).map (- ·)) false
  | .possibly p => return suffix (← margin r p) true

/-- A margin as JSON: rounded to 3 decimals, or `unbounded` when it is infinite. -/
def num (x : Float) : Json :=
  if x.isNaN then Json.str "undefined"
  else if x.isInf then Json.str (if x > 0 then "unbounded" else "-unbounded")
  else
    let k := (x * 1000).round
    let m : Nat := (if k < 0 then -k else k).toUInt64.toNat
    Json.num ⟨if k < 0 then -(m : Int) else (m : Int), 3⟩

def numText (x : Float) : String :=
  match num x with
  | .str s => s
  | j => j.compress

/-- Every `stride`th point, so a long run is drawn whole in at most `maxPoints` points. -/
def series (t xs : Array Float) : Json × Nat :=
  let n := xs.size
  let stride := max 1 ((n + maxPoints - 1) / maxPoints)
  let pts := (List.range ((n + stride - 1) / stride)).map fun k =>
    Json.arr #[num t[k * stride]!, num xs[k * stride]!]
  (Json.arr pts.toArray, n - pts.length)

/-! ## The chart -/

partial def Claim.bounds : Claim → List (String × Float)
  | .over f c | .under f c => [(f, c)]
  | .on _ => []
  | .not p | .within _ p | .throughout _ p | .always p | .never p | .possibly p => p.bounds
  | .and ps | .or ps => ps.flatMap Claim.bounds
  | .implies a b => a.bounds ++ b.bounds

partial def Claim.labels : Claim → List String
  | .on m => [m]
  | .over _ _ | .under _ _ => []
  | .not p | .within _ p | .throughout _ p | .always p | .never p | .possibly p => p.labels
  | .and ps | .or ps => ps.flatMap Claim.labels
  | .implies a b => a.labels ++ b.labels

def esc (s : String) : String :=
  String.join <| s.toList.map fun c =>
    if c == '&' then "&amp;" else if c == '<' then "&lt;" else if c == '>' then "&gt;"
    else if c == '"' then "&quot;" else c.toString

def px (x : Float) : String := fmt (Float.round (x * 10) / 10)

/-- One panel per field the claim reads: its line, the claim's bounds dashed, the failing samples
in red and a tick at each labelled sample the claim names. -/
def plot (r : Run) (claim : Claim) (inner : Array Float) (dark : Bool) : String := Id.run do
  let bg := if dark then "#111111" else "#ffffff"
  let fg := if dark then "#e5e7eb" else "#111827"
  let grid := if dark then "#4b5563" else "#9ca3af"
  let ink := if dark then "#93c5fd" else "#1d4ed8"
  let red := if dark then "#f87171" else "#dc2626"
  let amber := if dark then "#fbbf24" else "#b45309"
  let W := 460.0; let H := 150.0; let L := 48.0; let R := 34.0; let T := 22.0; let B := 22.0
  let n := r.t.size
  let t0 := r.t[0]!; let t1 := max r.t[n-1]! (t0 + 1)
  let xOf := fun (t : Float) => L + (t - t0) / (t1 - t0) * (W - L - R)
  let stride := max 1 ((n + maxPoints - 1) / maxPoints)
  let labels := claim.labels.eraseDups
  let panels := r.vals
  let total := H * panels.length.toFloat
  let mut out : Array String := #[s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{px W}\" height=\"{px total}\" viewBox=\"0 0 {px W} {px total}\" font-family=\"ui-sans-serif, system-ui, sans-serif\" font-size=\"11\">",
    s!"<rect width=\"100%\" height=\"100%\" fill=\"{bg}\"/>"]
  let mut k := 0
  for (f, vs) in panels do
    let top := H * k.toFloat
    let bs := (claim.bounds.filter (·.1 == f)).map (·.2)
    let lo0 := min (vs.foldl min inf) (bs.foldl min inf)
    let hi0 := max (vs.foldl max (-inf)) (bs.foldl max (-inf))
    let pad := max ((hi0 - lo0) * 0.08) 0.5
    let lo := lo0 - pad; let hi := hi0 + pad
    let yOf := fun (v : Float) => top + T + (hi - v) / (hi - lo) * (H - T - B)
    out := out.push s!"<text x=\"{px L}\" y=\"{px (top + 14)}\" fill=\"{fg}\" font-weight=\"bold\">{esc f}</text>"
    out := out.push s!"<line x1=\"{px L}\" y1=\"{px (top + H - B)}\" x2=\"{px (W - R)}\" y2=\"{px (top + H - B)}\" stroke=\"{grid}\"/>"
    out := out.push s!"<text x=\"{px (L - 4)}\" y=\"{px (yOf hi0 + 4)}\" text-anchor=\"end\" fill=\"{fg}\">{fmt hi0}</text>"
    out := out.push s!"<text x=\"{px (L - 4)}\" y=\"{px (yOf lo0 + 4)}\" text-anchor=\"end\" fill=\"{fg}\">{fmt lo0}</text>"
    -- day marks, when the run spans a day
    if t1 - t0 ≥ 86400 then
      let mut d := 1.0
      while t0 + d * 86400 < t1 do
        let x := xOf (t0 + d * 86400)
        out := out.push s!"<line x1=\"{px x}\" y1=\"{px (top + T)}\" x2=\"{px x}\" y2=\"{px (top + H - B)}\" stroke=\"{grid}\" stroke-dasharray=\"2 4\"/>"
        out := out.push s!"<text x=\"{px x}\" y=\"{px (top + H - 6)}\" text-anchor=\"middle\" fill=\"{fg}\">day {fmt (d + 1)}</text>"
        d := d + 1
    for b in bs do
      out := out.push s!"<line x1=\"{px L}\" y1=\"{px (yOf b)}\" x2=\"{px (W - R)}\" y2=\"{px (yOf b)}\" stroke=\"{amber}\" stroke-dasharray=\"6 4\"/>"
      out := out.push s!"<text x=\"{px (W - R + 4)}\" y=\"{px (yOf b + 4)}\" text-anchor=\"start\" fill=\"{amber}\">{fmt b}</text>"
    let pts := (List.range ((n + stride - 1) / stride)).map fun j =>
      let i := j * stride
      s!"{px (xOf r.t[i]!)},{px (yOf vs[i]!)}"
    out := out.push s!"<polyline fill=\"none\" stroke=\"{ink}\" stroke-width=\"1.5\" points=\"{" ".intercalate pts}\"/>"
    let bad := (List.range n).filter fun i => inner[i]! < 0
    for i in bad.take 400 do
      out := out.push s!"<circle cx=\"{px (xOf r.t[i]!)}\" cy=\"{px (yOf vs[i]!)}\" r=\"3\" fill=\"{red}\"/>"
    if bad.length > 400 then
      out := out.push s!"<text x=\"{px (W - R)}\" y=\"{px (top + 14)}\" text-anchor=\"end\" fill=\"{red}\">{bad.length - 400} more failing samples not marked</text>"
    for m in labels do
      let ts := (List.range n).filter fun i => r.labels[i]! == m
      for i in ts.take 400 do
        let x := xOf r.t[i]!
        out := out.push s!"<line x1=\"{px x}\" y1=\"{px (top + H - B - 8)}\" x2=\"{px x}\" y2=\"{px (top + H - B)}\" stroke=\"{amber}\" stroke-width=\"2\"/>"
      if !ts.isEmpty then
        out := out.push s!"<text x=\"{px (L + 8 + 7 * f.length.toFloat)}\" y=\"{px (top + 14)}\" text-anchor=\"start\" fill=\"{amber}\">| ticks: {esc m}</text>"
    k := k + 1
  out := out.push "</svg>"
  return "".intercalate out.toList

def check (args : Json) : Except String Json := do
  let text ← match args.getObjValD "claim" with
    | .str s => pure s
    | _ => throw "check_signal needs a claim, an s-expression such as (always (below temp 26))"
  let claim ← parse text
  let ss ← match args.getObjValD "samples", args.getObjValD "log" with
    | .arr js, _ => ofSamples js
    | _, .str l => ofLog l
    | _, _ => throw "check_signal needs samples ([{t, label?, field: number, ...}]) or log (event lines)"
  if ss.isEmpty then throw "there are no samples"
  if ss.size > maxSamples then throw s!"at most {maxSamples} samples"
  for i in [1:ss.size] do
    if ss[i]!.t < ss[i-1]!.t then
      throw s!"sample {i + 1} (t {numText ss[i]!.t}) comes before the one above it (t {numText ss[i-1]!.t})"
  let fields := claim.fields.eraseDups
  let vals ← fields.mapM fun f => do pure (f, ← hold ss f)
  let r : Run := { t := ss.map (·.t), labels := ss.map (·.label), vals }
  let (m, cut) := (margin r claim).run 0
  let holds := m[0]! ≥ 0
  -- the first failing sample of an always or never
  let inner : Option (Array Float) := match claim with
    | .always p => some ((margin r p).run' 0)
    | .never p => some (((margin r p).run' 0).map (- ·))
    | _ => none
  let first : Json := match inner with
    | some xs => match (List.range xs.size).find? (fun i => xs[i]! < 0) with
      | some i => Json.mkObj ([("sample", toJson (i + 1)), ("t", num r.t[i]!), ("label", Json.str r.labels[i]!)] ++
          [("readings", Json.mkObj (vals.map fun (f, a) => (f, num a[i]!)))])
      | none => Json.null
    | none => Json.null
  let (marginSeries, omitted) := series r.t (inner.getD m)
  let fieldSeries := vals.map fun (f, a) => (f, (series r.t a).1)
  let reading :=
    (if holds then s!"holds: margin {numText m[0]!} at the first sample"
     else s!"fails: margin {numText m[0]!} at the first sample") ++
    (match first with
      | .null => ""
      | j => s!"; it first fails at t {(j.getObjValD "t").compress}") ++
    (if cut > 0 then s!"; {cut} moments had a window cut short by the end of the run" else "")
  let svg : List (String × Json) := match args.getObjValD "theme" with
    | .str "dark" => [("svg", Json.str (plot r claim (inner.getD m) true))]
    | .str "light" => [("svg", Json.str (plot r claim (inner.getD m) false))]
    | _ => []
  return Json.mkObj <| svg ++ [("tool", Json.str "check_signal"), ("verdict", Json.str (if holds then "holds" else "fails")),
    ("reading", Json.str reading), ("claim", Json.str claim.text), ("margin", num m[0]!),
    ("firstFailure", first), ("samples", toJson ss.size), ("cutShort", toJson cut),
    ("series", Json.mkObj ([("margin", marginSeries)] ++ fieldSeries)), ("omittedPoints", toJson omitted)]

end LeanFM.Signal
