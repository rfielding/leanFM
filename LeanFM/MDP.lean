namespace LeanFM

structure Weighted (α : Type) where
  weight : Nat
  dwell : Nat
  value : α
deriving DecidableEq, Repr

inductive Choice (S A : Type) where
  | action : A -> Nat -> S -> Choice S A
  | chance : A -> List (Weighted S) -> Choice S A
deriving Repr

namespace Choice

def label {S A : Type} : Choice S A -> A
  | action a _ _ => a
  | chance a _ => a

def support {S A : Type} : Choice S A -> List S
  | action _ _ s => [s]
  | chance _ outcomes => outcomes.map Weighted.value

def isChance {S A : Type} : Choice S A -> Bool
  | action _ _ _ => false
  | chance _ _ => true

def totalWeight {S A : Type} : Choice S A -> Nat
  | action _ _ _ => 1
  | chance _ outcomes => outcomes.foldl (fun n outcome => n + outcome.weight) 0

def timedSupport {S A : Type} : Choice S A -> List (Weighted S)
  | action _ dwell s => [{ weight := 1, dwell := dwell, value := s }]
  | chance _ outcomes => outcomes

end Choice

structure MDP (S A : Type) where
  choices : S -> List (Choice S A)

def MDP.successors {S A : Type} (m : MDP S A) (s : S) : List S :=
  (m.choices s).flatMap Choice.support

structure Component (S A : Type) where
  initial : S
  states : List S
  grammar : List A
  choices : S -> List (Choice S A)

def Component.mdp {S A : Type} (c : Component S A) : MDP S A :=
  { choices := c.choices }

def Component.successors {S A : Type} (c : Component S A) (s : S) : List S :=
  c.mdp.successors s

structure PathMass (S : Type) where
  mass : Nat
  dwell : Nat
  state : S
deriving DecidableEq, Repr

def nextMass {S A : Type} (path : PathMass S) (choice : Choice S A) : List (PathMass S) :=
  (Choice.timedSupport choice).map fun outcome =>
    { mass := path.mass * outcome.weight
    , dwell := outcome.dwell
    , state := outcome.value
    }

def addBucket (buckets : List (Nat × Nat)) (key amount : Nat) : List (Nat × Nat) :=
  match buckets with
  | [] => [(key, amount)]
  | (k, v) :: rest =>
      if k = key then (k, v + amount) :: rest else (k, v) :: addBucket rest key amount

def bucketMass (measure : S -> Nat) (paths : List (PathMass S)) : List (Nat × Nat) :=
  paths.foldl
    (fun buckets path => addBucket buckets (measure path.state) (path.mass * path.dwell))
    []

structure PathStats (S A : Type) where
  mass : Nat
  scale : Nat
  lastDwell : Nat
  elapsed : Nat
  state : S
  trace : List A
deriving Repr

def bucketScaledMass (commonScale : Nat) (measure : S -> Nat)
    (paths : List (PathStats S A)) : List (Nat × Nat) :=
  paths.foldl
    (fun buckets path =>
      addBucket buckets (measure path.state)
        (path.mass * path.lastDwell * (commonScale / path.scale)))
    []

def nextStats {S A : Type} (path : PathStats S A) (choice : Choice S A) : List (PathStats S A) :=
  let total := Choice.totalWeight choice
  (Choice.timedSupport choice).map fun outcome =>
    { mass := path.mass * outcome.weight
    , scale := path.scale * total
    , lastDwell := outcome.dwell
    , elapsed := path.elapsed + outcome.dwell
    , state := outcome.value
    , trace := path.trace ++ [Choice.label choice]
    }

def advancePolicy {S A : Type} (policy : S -> Option (Choice S A))
    (path : PathStats S A) : List (PathStats S A) :=
  match policy path.state with
  | some choice => nextStats path choice
  | none => [path]

def ratioText (num den : Nat) : String :=
  s!"{num}/{den}"

def decimalText (num den : Nat) : String :=
  if den = 0 then
    "undefined"
  else
    let whole := num / den
    let frac := ((num % den) * 100) / den
    let padded := if frac < 10 then s!"0{frac}" else toString frac
    s!"{whole}.{padded}"

structure Metrics where
  successNum : Nat
  successDen : Nat
  latencyNum : Nat
  latencyDen : Nat
deriving Repr

def Metrics.throughputNum (m : Metrics) : Nat :=
  m.successNum * m.latencyDen

def Metrics.throughputDen (m : Metrics) : Nat :=
  m.successDen * m.latencyNum

def composeSequential (a b : Metrics) : Metrics :=
  { successNum := a.successNum * b.successNum
  , successDen := a.successDen * b.successDen
  , latencyNum :=
      a.latencyNum * a.successDen * b.latencyDen +
        a.successNum * b.latencyNum * a.latencyDen
  , latencyDen := a.latencyDen * a.successDen * b.latencyDen
  }

end LeanFM
