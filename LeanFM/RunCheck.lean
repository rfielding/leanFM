import LeanFM.Logic

/-! # Judging a requirement on runs
(clause selfhost.requirements.standing; decision requirement-standing)

A test's run is one path through the system. It proves what one path can: it witnesses a
`possibly` and refutes an `always`, but it cannot refute a `possibly` (another run may show it) or
prove an `always` (another run may break it). So a formula is judged with four values, not two:

* true: the run shows it;
* presumably true: it holds so far;
* presumably false: not shown yet;
* false: the run refutes it, and the shortest refuting prefix is the counterexample.

`and` is the weaker value, `or` the stronger, `not` reverses the order. At the end of a session still
running, `eventually`, `until` and `next` are presumably false and `always` and `unless` presumably
true; in a complete session they are definite. Then a some-path operator's false becomes presumably
false and an all-paths operator's true becomes presumably true.

Requirements this module is held to:
* positive (AG): every value comes from one pass per subformula over the run, formula size times
  events; a counterexample is the shortest prefix whose value is false.
* negative (never): false from a some-path part alone; true from an all-paths part alone; a value for
  an atom a run does not show (it is refused, naming the atom). -/

namespace LeanFM.RunCheck
open Lean LeanFM.Logic

/-- The four values, weakest first. -/
inductive V | false_ | presumablyFalse | presumablyTrue | true_
deriving BEq, Repr, Inhabited, DecidableEq

namespace V
def rank : V → Nat | false_ => 0 | presumablyFalse => 1 | presumablyTrue => 2 | true_ => 3
def ofRank : Nat → V | 0 => false_ | 1 => presumablyFalse | 2 => presumablyTrue | _ => true_
def and (a b : V) : V := ofRank (min a.rank b.rank)
def or (a b : V) : V := ofRank (max a.rank b.rank)
def not : V → V
  | false_ => true_ | presumablyFalse => presumablyTrue | presumablyTrue => presumablyFalse | true_ => false_
def name : V → String
  | false_ => "false" | presumablyFalse => "presumably false" | presumablyTrue => "presumably true" | true_ => "true"
/-- One run can witness but not refute a some-path claim. -/
def some_ : V → V | false_ => presumablyFalse | v => v
/-- One run can refute but not prove an all-paths claim. -/
def all_ : V → V | true_ => presumablyTrue | v => v
/-- Holds as far as a run can show: true or presumably true. -/
def holds (v : V) : Bool := v.rank ≥ 2
end V

/-- One session of a run: its message labels in order, and whether the protocol allows no further
step (the run is whole). State 0 is before any event, state i just after event i. -/
structure Run where
  labels : Array String
  complete : Bool
deriving Repr, Inhabited

/-- The value at the end of a run, for an operator that needs a future step (strong) or does not
(weak). -/
def strongEnd (r : Run) : V := if r.complete then .false_ else .presumablyFalse
def weakEnd (r : Run) : V := if r.complete then .true_ else .presumablyTrue

/-- The first atom of an unfolded formula that a run does not show, if any. -/
partial def unjudged : Formula → Option String
  | .tt | .ff | .after _ | .terminal => none
  | .not g | .ex g | .ax g | .ef g | .af g | .eg g | .ag g => unjudged g
  | .and fs | .or fs => fs.findSome? unjudged
  | .implies a b | .eu a b | .au a b | .ew a b | .aw a b => (unjudged a).orElse fun _ => unjudged b
  | g => some g.toJson.compress

/-- `out[i] = b[i] or (a[i] and out[i+1])`, ending in `endV`: until (strong end) or unless (weak). -/
def untilPass (a b : Array V) (endV : V) : Array V := Id.run do
  let n := a.size - 1
  let mut out := Array.replicate a.size endV
  let mut next := endV
  for k in [0:a.size] do
    let i := n - k
    let v := b[i]!.or (a[i]!.and next)
    out := out.set! i v
    next := v
  return out

/-- The value of an unfolded formula at every state of one run (n + 1 values for n events). -/
partial def eval (r : Run) : Formula → Array V
  | .tt => Array.replicate (r.labels.size + 1) .true_
  | .ff => Array.replicate (r.labels.size + 1) .false_
  | .after m => (Array.range (r.labels.size + 1)).map fun i =>
      if i > 0 && r.labels[i - 1]! == m then .true_ else .false_
  | .terminal => (Array.range (r.labels.size + 1)).map fun i =>
      if i < r.labels.size then .false_ else if r.complete then .true_ else .presumablyFalse
  | .not g => (eval r g).map V.not
  | .and fs => fs.foldl (fun acc g => (acc.zip (eval r g)).map fun (x, y) => x.and y) (eval r .tt)
  | .or fs => fs.foldl (fun acc g => (acc.zip (eval r g)).map fun (x, y) => x.or y) (eval r .ff)
  | .implies a b => eval r (.or [.not a, b])
  | .ex g => (next (eval r g) (strongEnd r)).map V.some_
  | .ax g => (next (eval r g) (weakEnd r)).map V.all_
  | .ef g => (untilPass (eval r .tt) (eval r g) (strongEnd r)).map V.some_
  | .af g => (untilPass (eval r .tt) (eval r g) (strongEnd r)).map V.all_
  | .eg g => (untilPass (eval r g) (eval r .ff) (weakEnd r)).map V.some_
  | .ag g => (untilPass (eval r g) (eval r .ff) (weakEnd r)).map V.all_
  | .eu a b => (untilPass (eval r a) (eval r b) (strongEnd r)).map V.some_
  | .au a b => (untilPass (eval r a) (eval r b) (strongEnd r)).map V.all_
  | .ew a b => (untilPass (eval r a) (eval r b) (weakEnd r)).map V.some_
  | .aw a b => (untilPass (eval r a) (eval r b) (weakEnd r)).map V.all_
  | _ => Array.replicate (r.labels.size + 1) .presumablyFalse
where
  next (g : Array V) (endV : V) : Array V :=
    (Array.range g.size).map fun i => if i + 1 < g.size then g[i + 1]! else endV

/-- The value of a formula over one run, at its start. -/
def valueOn (r : Run) (f : Formula) : V := (eval r f)[0]!

/-- The first `k` events of a run, still running unless `k` is the whole of a complete run. -/
def Run.prefix (r : Run) (k : Nat) : Run :=
  { labels := r.labels.extract 0 k, complete := r.complete && k == r.labels.size }

/-- The shortest prefix of `r` on which `f` is false, given that it is false on all of `r`: false
stays false as a prefix grows, so a binary search finds it. -/
def shortestFalse (r : Run) (f : Formula) : Nat := Id.run do
  let mut lo := 0
  let mut hi := r.labels.size
  -- invariant: false on the prefix of length hi; not false on any prefix shorter than lo
  let mut fuel := r.labels.size + 1
  while lo < hi && fuel > 0 do
    fuel := fuel - 1
    let mid := (lo + hi) / 2
    if valueOn (r.prefix mid) f == .false_ then hi := mid else lo := mid + 1
  return hi

/-- Flatten a top-level conjunction. -/
partial def conjuncts : Formula → List Formula
  | .and fs => fs.flatMap conjuncts
  | g => [g]

/-- Triggers of weak implications (and plain implies) in a formula before it is unfolded. -/
partial def weakTriggers : Formula → List Formula
  | .ifEver a b | .implies a b => a :: weakTriggers a ++ weakTriggers b
  | .stronglyImplies a b | .leadsTo a b | .precedes a b | .eu a b | .au a b | .ew a b | .aw a b =>
      weakTriggers a ++ weakTriggers b
  | .not g | .never g | .ex g | .ax g | .ef g | .af g | .eg g | .ag g => weakTriggers g
  | .and fs | .or fs | .outcomes fs | .word _ fs => fs.flatMap weakTriggers
  | .follows a bs | .transition a bs => weakTriggers a ++ bs.flatMap weakTriggers
  | _ => []

/-- What the runs say about a formula. -/
structure Judgement where
  value : V
  /-- each top-level conjunct, unfolded, with its combined value -/
  parts : List (Formula × V)
  /-- for a false value: the session index and the length of its shortest refuting prefix -/
  counterexample : Option (Nat × Nat) := none
  /-- weak triggers no run makes happen (the guarantee was tested only vacuously) -/
  untriggered : List Formula := []

/-- Combine one conjunct's values across sessions: false if any, else true if any, else the weakest. -/
def combine (vs : List V) : V :=
  if vs.contains .false_ then .false_
  else if vs.contains .true_ then .true_
  else vs.foldl V.and .true_

/-- Judge a formula on the sessions of a log. -/
def judge (f : Formula) (runs : List Run) : Except String Judgement := do
  let u := f.unfold
  if let some a := unjudged u then
    throw s!"a run shows only on M, stop, true and false; this formula also has {a}"
  if runs.isEmpty then throw "the log has no session to judge"
  let parts := (conjuncts u).map fun c => (c, combine (runs.map (valueOn · c)))
  let value := parts.foldl (fun acc (_, v) => acc.and v) .true_
  let counterexample := (parts.find? (·.2 == .false_)).bind fun (c, _) =>
    (runs.zipIdx.find? fun (r, _) => valueOn r c == .false_).map fun (r, i) => (i, shortestFalse r c)
  let untriggered := (weakTriggers f).eraseDups.filter fun a =>
    let ua := a.unfold
    (unjudged ua).isNone && runs.all fun r => !(eval r ua).contains .true_
  return { value, parts, counterexample, untriggered }

end LeanFM.RunCheck
