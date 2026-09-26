import LeanFM.CTL

namespace LeanFM

inductive ImplicationState where
  | start
  | witness
deriving DecidableEq

def oneWitness : ImplicationState -> List ImplicationState
  | .start => [.witness]
  | .witness => []

def noWitness (_ : ImplicationState) : List ImplicationState := []

def p : CTL ImplicationState := .atom fun state => state == .witness
def q : CTL ImplicationState := .atom fun state => state == .witness

/-- Material implication is true when its antecedent is absent. -/
example : CTL.holds noWitness .start (CTL.ag (CTL.implies p q)) := by native_decide

/-- Strong implication rejects the same vacuous model. -/
example : !CTL.holds noWitness .start (CTL.stronglyImplies p q) := by native_decide

/-- A reachable witness satisfying both antecedent and consequent is accepted. -/
example : CTL.holds oneWitness .start (CTL.stronglyImplies p q) := by native_decide

end LeanFM
