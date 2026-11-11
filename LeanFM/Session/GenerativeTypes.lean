import LeanFM.Overlay

/-! Typed metadata for selfhost.session.generative; it never changes Global. -/
namespace LeanFM.Session.Generative
open LeanFM.Overlay

structure TimeExpr where
  /-- A clock name, or the maximum of the named prior message times. Empty means now. -/
  clock : Option String := none
  refs : List String := []
  offsets : List (Nat × Q) := [(0, Q.one)]
  deriving Inhabited, Repr

structure Obligation where
  name : String
  actor : String
  clock : String
  labels : List String
  withinMs : Nat
  breach : String
  deriving Inhabited, Repr

def checkWeights (weights : List Q) : Except String Unit := do
  if weights.isEmpty || weights.length > 16 then throw "a distribution needs 1 to 16 entries"
  if weights.any (fun q => q.den == 0 || q.num > q.den || q.num > 999999 || q.den > 999999) then
    throw "probabilities must be fractions between 0 and 1 with nonzero denominators (at most 999999)"
  let sum := weights.foldl Q.add Q.zero
  if sum != Q.one then throw s!"probabilities sum to {sum.text}, not 1; no silent normalization"

end LeanFM.Session.Generative
