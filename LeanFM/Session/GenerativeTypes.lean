import LeanFM.Overlay

/-! Typed metadata for selfhost.session.generative; it never changes Global. -/
namespace LeanFM.Session.Generative
open LeanFM.Overlay

structure TimeExpr where
  /-- A clock name, or the maximum of the named prior message times. Empty means now. -/
  clock : Option String := none
  refs : List String := []
  offsets : List (Nat × Q) := [(0, Q.one)]
  /-- `after d`: d after the previous step on the path, rather than after a clock or message. -/
  relative : Bool := false
  /-- `at next d`: the next whole multiple of d since the session began (a periodic gate) -/
  period : Option Nat := none
  deriving Inhabited, Repr

/-- What a message moves from its sender to its receiver (selfhost.session.amounts):
one unit, and one or more whole quantities with exact probabilities. -/
structure Amount where
  unit : String
  outcomes : List (Nat × Q)
  /-- moves from the receiver to the sender: the negative entries of a trade vector -/
  reverse : Bool := false
  deriving Inhabited, Repr

/-- Paid by an obligation's actor to `payee` when the obligation is violated. -/
structure Penalty where
  quantity : Nat
  unit : String
  payee : String
  deriving Inhabited, Repr

/-- `accrue N UNIT per PERIOD from A to B`: A pays B at this rate until the next accrual for the
same payer, payee and unit (selfhost.session.mdp.rewards). -/
structure Accrual where
  payer : String
  payee : String
  unit : String
  quantity : Nat
  periodMs : Nat
  deriving Inhabited, Repr, BEq

structure Obligation where
  name : String
  actor : String
  clock : String
  labels : List String
  withinMs : Nat
  breach : String
  penalty : Option Penalty := none
  deriving Inhabited, Repr

def checkWeights (weights : List Q) : Except String Unit := do
  if weights.isEmpty || weights.length > 16 then throw "a distribution needs 1 to 16 entries"
  if weights.any (fun q => q.den == 0 || q.num > q.den || q.num > 999999 || q.den > 999999) then
    throw "probabilities must be fractions between 0 and 1 with nonzero denominators (at most 999999)"
  let sum := weights.foldl Q.add Q.zero
  if sum != Q.one then throw s!"probabilities sum to {sum.text}, not 1; no silent normalization"

end LeanFM.Session.Generative
