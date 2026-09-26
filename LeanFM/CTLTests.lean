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

inductive WeakState where
  | start
  | reachedQ
  | pForever
deriving DecidableEq

def weakBranches : WeakState -> List WeakState
  | .start => [.reachedQ, .pForever]
  | .reachedQ => []
  | .pForever => [.pForever]

def weakP : CTL WeakState := .atom fun state => state != .reachedQ
def weakQ : CTL WeakState := .atom fun state => state == .reachedQ

/-- Every path either reaches q under p or keeps p forever. -/
example : CTL.holds weakBranches .start (weakP AW weakQ) := by native_decide

/-- Strong until fails because one path keeps p forever without reaching q. -/
example : !CTL.holds weakBranches .start (weakP AU weakQ) := by native_decide

/-- AW is not `(AU) or AG`: q may release p on one branch while another keeps p. -/
example : !CTL.holds weakBranches .start (CTL.or (weakP AU weakQ) (CTL.ag weakP)) := by
  native_decide

example : CTL.holds weakBranches .start (weakP EW weakQ) := by native_decide

end LeanFM
