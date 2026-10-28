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

/-! ## Measured overlays -/

namespace LeanFM.Overlay
open LeanFM.Logic

/-- One recorded message of a session, with its time in ms. -/
structure Observed where
  message : String
  atMs : Nat
deriving Repr, Inhabited

/-- Reduce recorded sessions into a measured overlay of the same shape as a
    declared one: branch probability = times taken / times its source state
    was left; delay = mean time since the previous message (rounded). Sessions
    that leave the task's grammar are reported, not counted. -/
def measure (t : TaskModel) (name : String) (sessions : List (List Observed)) : Overlay × List String := Id.run do
  let mut taken : List ((String × String) × Nat) := []
  let mut delays : List ((String × String) × Nat) := []
  let mut issues : List String := []
  let bump := fun (xs : List ((String × String) × Nat)) (k : String × String) (v : Nat) =>
    match xs.find? (·.1 == k) with
    | some _ => xs.map fun (k', n) => if k' == k then (k', n + v) else (k', n)
    | none => (k, v) :: xs
  for session in sessions do
    let mut state := t.initial
    let mut prev := (session.head?.map (·.atMs)).getD 0
    let mut steps : List ((String × String) × Nat) := []
    let mut ok := true
    for e in session do
      if ok then
        match t.transitions.find? (fun tr => tr.src == state && tr.message == e.message) with
        | some tr =>
          steps := ((state, e.message), e.atMs - prev) :: steps
          prev := e.atMs
          state := tr.dst
        | none =>
          ok := false
          if issues.length < 20 then issues := issues ++ [s!"message {e.message} is not allowed in state {state}"]
    if ok then
      for (k, d) in steps do
        taken := bump taken k 1
        delays := bump delays k d
  let visits := fun (s : String) => taken.foldl (fun acc ((src, _), n) => if src == s then acc + n else acc) 0
  let count := fun (k : String × String) => ((taken.find? (·.1 == k)).map (·.2)).getD 0
  let annotations := t.transitions.map fun tr =>
    let k := (tr.src, tr.message)
    let n := count k
    let total := visits tr.src
    let delay := if n == 0 then 0 else (((delays.find? (·.1 == k)).map (·.2)).getD 0 + n / 2) / n
    { src := tr.src, message := tr.message, probability := Q.norm n (if total == 0 then 1 else total), delayMs := delay : Annotation }
  return ({ name, kind := "measured", annotations }, issues)

/-- Branch counts behind a measured overlay: (src, message, times taken, times src was left). -/
def counts (t : TaskModel) (sessions : List (List Observed)) : List (String × String × Nat × Nat) :=
  let walk := sessions.map fun s => Id.run do
    let mut state := t.initial
    let mut out : List (String × String) := []
    for e in s do
      match t.transitions.find? (fun tr => tr.src == state && tr.message == e.message) with
      | some tr => out := (state, e.message) :: out; state := tr.dst
      | none => pure ()
    return out
  let all := walk.flatten
  t.transitions.map fun tr =>
    (tr.src, tr.message, (all.filter (· == (tr.src, tr.message))).length, (all.filter (·.1 == tr.src)).length)

/-- Fraction of sessions whose `message` occurs within `deadlineMs` of the session start. -/
def empiricalWithin (sessions : List (List Observed)) (message : String) (deadlineMs : Nat) : Q :=
  let hits := sessions.filter fun s => match s.head? with
    | none => false
    | some first => s.any fun e => e.message == message && e.atMs - first.atMs ≤ deadlineMs
  Q.norm hits.length (max sessions.length 1)

end LeanFM.Overlay
