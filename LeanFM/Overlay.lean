import LeanFM.Logic

/-!
# Probability and time overlays (selfhost.logic.overlay)

The grammar/task core carries no numbers: it decides only what can happen.
An overlay is a separate table that annotates transitions with a branch
probability and a delivery delay. A declared overlay states what we expect;
a measured overlay (same shape) would be reduced from recorded traces. Every
answer names the overlay it used.

Overlays never change a CTL verdict: they are consulted only by the
probability, time and generation functions here. Weights are exact fractions;
they are validated, never silently normalized.
-/

namespace LeanFM.Overlay
open LeanFM.Logic

/-! ## Exact fractions -/

structure Q where
  num : Nat
  den : Nat
deriving Repr, Inhabited, BEq

namespace Q
def norm (num den : Nat) : Q :=
  if den == 0 then ⟨0, 1⟩ else
  let g := Nat.gcd num den
  if g == 0 then ⟨0, 1⟩ else ⟨num / g, den / g⟩
def zero : Q := ⟨0, 1⟩
def one : Q := ⟨1, 1⟩
def mul (a b : Q) : Q := norm (a.num * b.num) (a.den * b.den)
def add (a b : Q) : Q := norm (a.num * b.den + b.num * a.den) (a.den * b.den)
def le (a b : Q) : Bool := a.num * b.den ≤ b.num * a.den
def lt (a b : Q) : Bool := a.num * b.den < b.num * a.den
def text (q : Q) : String := if q.den == 1 then toString q.num else s!"{q.num}/{q.den}"
/-- Decimal rendering with `digits` places, rounded half up. -/
def decimal (q : Q) (digits : Nat := 4) : String :=
  let scale := 10 ^ digits
  let scaled := (q.num * scale * 2 + q.den) / (q.den * 2)
  let whole := scaled / scale
  let frac := toString (scaled % scale)
  let padded := String.ofList (List.replicate (digits - frac.length) '0') ++ frac
  if digits == 0 then toString whole else s!"{whole}.{padded}"
end Q

/-! ## Overlays -/

structure Annotation where
  src : String
  message : String
  probability : Q
  delayMs : Nat
deriving Repr, Inhabited

structure Overlay where
  name : String
  /-- `declared` (stated expectation) or `measured` (reduced from traces). -/
  kind : String
  annotations : List Annotation
deriving Repr, Inhabited

def annotationFor (o : Overlay) (t : Transition) : Option Annotation :=
  o.annotations.find? fun a => a.src == t.src && a.message == t.message

/-- Every transition is annotated, every annotation names a transition, and the
    branch probabilities leaving each non-terminal state sum to exactly 1. -/
def validate (t : TaskModel) (o : Overlay) : List String :=
  let missing := t.transitions.filterMap fun tr =>
    if (annotationFor o tr).isSome then none
    else some s!"transition {tr.src} --{tr.message}--> {tr.dst} has no annotation in overlay {o.name}"
  let stray := o.annotations.filterMap fun a =>
    if t.transitions.any (fun tr => tr.src == a.src && tr.message == a.message) then none
    else some s!"overlay {o.name} annotates {a.src} --{a.message}--> which the task does not declare"
  let zeroDen := o.annotations.filterMap fun a =>
    if a.probability.den == 0 then some s!"{a.src} --{a.message}--> has a zero denominator" else none
  let sums := (t.states.filter (fun s => !t.terminals.contains s)).filterMap fun s =>
    let outs := t.transitions.filter (·.src == s)
    if outs.isEmpty then none else
    let total := outs.foldl (fun acc tr => match annotationFor o tr with
      | some a => Q.add acc a.probability | none => acc) Q.zero
    if total == Q.one then none
    else some s!"branch probabilities leaving {s} sum to {total.text}, not 1 (overlays are never normalized silently)"
  missing ++ stray ++ zeroDen ++ sums

/-! ## Generated runs -/

structure Step where
  transition : Transition
  probability : Q
  /-- Delivery time of this message, measured from the start of the run. -/
  atMs : Nat
deriving Repr, Inhabited

structure Run where
  steps : List Step
  probability : Q
  durationMs : Nat
  final : String
deriving Repr, Inhabited

def maxRuns : Nat := 10000

/-- Every complete run from the initial state, with its exact probability and
    duration. Requires an acyclic task (bounded retries are unrolled into
    states); a cycle is reported rather than truncated. -/
partial def runs (t : TaskModel) (o : Overlay) : Except String (List Run) := do
  let errors := validate t o
  if !errors.isEmpty then throw ("; ".intercalate errors)
  let rec go (state : String) (seen : List String) (acc : List Step) (p : Q) (time : Nat) (budget : Nat) :
      Except String (List Run) := do
    if budget == 0 then throw s!"more than {maxRuns} runs; reduce the model"
    if seen.contains state then
      throw s!"the task revisits state {state}; unroll the loop into bounded states to compute exact distributions"
    let outs := t.transitions.filter (·.src == state)
    if t.terminals.contains state || outs.isEmpty then
      return [{ steps := acc.reverse, probability := p, durationMs := time, final := state }]
    let mut all : List Run := []
    for tr in outs do
      let some a := annotationFor o tr | throw "unannotated transition"
      let arrival := time + a.delayMs
      let more ← go tr.dst (state :: seen) ({ transition := tr, probability := a.probability, atMs := arrival } :: acc)
        (Q.mul p a.probability) arrival (budget - 1)
      all := all ++ more
    return all
  go t.initial [] [] Q.one 0 maxRuns

/-- Most likely first, then shortest. -/
def ranked (rs : List Run) : List Run :=
  rs.toArray.qsort (fun a b => Q.lt b.probability a.probability ||
    (a.probability == b.probability && a.durationMs < b.durationMs)) |>.toList

def total (rs : List Run) : Q := rs.foldl (fun acc r => Q.add acc r.probability) Q.zero

/-- `P=? [F target]` over complete runs. -/
def probabilityReaching (rs : List Run) (target : String → Bool) : Q :=
  total (rs.filter fun r => r.steps.any (fun s => target s.transition.dst) || target r.final)

/-- `P=? [F≤deadline target]`: the run reaches a target state by `deadline` ms. -/
def probabilityWithin (rs : List Run) (target : String → Bool) (deadlineMs : Nat) : Q :=
  total (rs.filter fun r => r.steps.any fun s => target s.transition.dst && s.atMs ≤ deadlineMs)

/-- The most likely run satisfying `pred`: a generated witness. -/
def mostLikely (rs : List Run) (pred : Run → Bool) : Option Run :=
  (ranked rs).find? pred

/-- Completion-time distribution: (duration, probability) pairs, ascending. -/
def completionTimes (rs : List Run) (target : String → Bool) : List (Nat × Q) :=
  let hits := rs.filter (fun r => target r.final)
  let times := (hits.map (·.durationMs)).eraseDups.toArray.qsort (· < ·) |>.toList
  times.map fun d => (d, total (hits.filter (·.durationMs == d)))

def expectedDuration (rs : List Run) : Q :=
  rs.foldl (fun acc r => Q.add acc (Q.mul r.probability ⟨r.durationMs, 1⟩)) Q.zero

end LeanFM.Overlay
