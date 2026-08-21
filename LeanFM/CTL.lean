namespace LeanFM

inductive CTL (S : Type) where
  | atom : (S -> Bool) -> CTL S
  | neg : CTL S -> CTL S
  | and : CTL S -> CTL S -> CTL S
  | or : CTL S -> CTL S -> CTL S
  | ex : CTL S -> CTL S
  | ax : CTL S -> CTL S
  | ef : CTL S -> CTL S
  | af : CTL S -> CTL S
  | eg : CTL S -> CTL S
  | ag : CTL S -> CTL S

namespace CTL

def implies {S : Type} (p q : CTL S) : CTL S :=
  CTL.or (CTL.neg p) q

partial def anyReachable [DecidableEq S]
    (succ : S -> List S) (p : S -> Bool) (seen : List S) (s : S) : Bool :=
  if p s then
    true
  else if seen.contains s then
    false
  else
    (succ s).any (anyReachable succ p (s :: seen))

partial def allReachable [DecidableEq S]
    (succ : S -> List S) (p : S -> Bool) (seen : List S) (s : S) : Bool :=
  if seen.contains s then
    true
  else
    p s && (succ s).all (allReachable succ p (s :: seen))

partial def allPathsEventually [DecidableEq S]
    (succ : S -> List S) (p : S -> Bool) (seen : List S) (s : S) : Bool :=
  if p s then
    true
  else if seen.contains s then
    false
  else
    match succ s with
    | [] => false
    | next => next.all (allPathsEventually succ p (s :: seen))

partial def existsPathAlways [DecidableEq S]
    (succ : S -> List S) (p : S -> Bool) (seen : List S) (s : S) : Bool :=
  if !p s then
    false
  else if seen.contains s then
    true
  else
    match succ s with
    | [] => true
    | next => next.any (existsPathAlways succ p (s :: seen))

partial def holds [DecidableEq S] (succ : S -> List S) (s : S) : CTL S -> Bool
  | atom p => p s
  | neg p => !(holds succ s p)
  | and p q => holds succ s p && holds succ s q
  | or p q => holds succ s p || holds succ s q
  | ex p => (succ s).any (fun s' => holds succ s' p)
  | ax p => (succ s).all (fun s' => holds succ s' p)
  | ef p => anyReachable succ (fun s' => holds succ s' p) [] s
  | af p => allPathsEventually succ (fun s' => holds succ s' p) [] s
  | eg p => existsPathAlways succ (fun s' => holds succ s' p) [] s
  | ag p => allReachable succ (fun s' => holds succ s' p) [] s

end CTL
end LeanFM
