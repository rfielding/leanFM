import LeanFM.CTL
import LeanFM.CTLDfs

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

/-- AG is implemented as the absence of an existentially reachable violation. -/
example :
    CTL.holds weakBranches .start (CTL.ag weakP) ==
      CTL.holds weakBranches .start (CTL.neg (CTL.ef (CTL.neg weakP))) := by
  native_decide

/-- AF is implemented as the absence of a path where the negation persists. -/
example :
    CTL.holds weakBranches .start (CTL.af weakQ) ==
      CTL.holds weakBranches .start (CTL.neg (CTL.eg (CTL.neg weakQ))) := by
  native_decide

/-! The labelling checker agrees with the previous depth-first one (clause selfhost.mcp.logic.checker):
every successor function over 1 to 3 states (each state's successors any subset of the states), two
atoms, every formula of depth 2 over the 14 operators, from every state. -/

def subsets : List Nat → List (List Nat)
  | [] => [[]]
  | x :: xs => let r := subsets xs; r ++ r.map (x :: ·)

def succFns (n : Nat) : List (Nat → List Nat) :=
  (List.range n).foldr (fun i acc => (subsets (List.range n)).flatMap fun out =>
    acc.map fun f => fun s => if s == i then out else f s) [fun _ => []]

def ops1 (f : CTL Nat) : List (CTL Nat) := [.neg f, .ex f, .ax f, .ef f, .af f, .eg f, .ag f]
def ops2 (f g : CTL Nat) : List (CTL Nat) := [.and f g, .or f g, .eu f g, .au f g, .ew f g, .aw f g]

def formulas (n : Nat) : List (CTL Nat) :=
  let a : CTL Nat := .atom (· == 0); let b : CTL Nat := .atom (· == n - 1)
  let one := [a, b] ++ ops1 a ++ ops1 b ++ ops2 a b ++ ops2 b a
  one ++ one.flatMap ops1 ++ one.flatMap (fun f => ops2 f a ++ ops2 b f)

def disagreements : Nat :=
  ([1, 2, 3].flatMap fun n => (succFns n).flatMap fun succ => (formulas n).flatMap fun f =>
    (List.range n).filter fun s => CTL.holds succ s f != CTL.Dfs.holds succ s f).length

example : disagreements = 0 := by native_decide

end LeanFM
