import LeanFM.CTL

/-! The depth-first CTL checker LeanFM used before the labelling checker (clause
selfhost.mcp.logic.checker): kept unchanged for tests only, which compare the two. -/

namespace LeanFM.CTL.Dfs
open LeanFM.CTL

variable {S : Type}

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

partial def existsUntil [DecidableEq S]
    (succ : S -> List S) (p q : S -> Bool) (seen : List S) (s : S) : Bool :=
  if q s then
    true
  else if seen.contains s then
    false
  else if !p s then
    false
  else
    (succ s).any (existsUntil succ p q (s :: seen))

partial def allUntilFrom [DecidableEq S]
    (succ : S -> List S) (p q : S -> Bool) (seen : List S) (s : S) : Bool :=
  if q s then
    true
  else if seen.contains s then
    false
  else if !p s then
    false
  else
    match succ s with
    | [] => false
    | next => next.all (allUntilFrom succ p q (s :: seen))

partial def existsWeakUntil [DecidableEq S]
    (succ : S -> List S) (p q : S -> Bool) (seen : List S) (s : S) : Bool :=
  if q s then
    true
  else if !p s then
    false
  else if seen.contains s then
    true
  else
    match succ s with
    | [] => true
    | next => next.any (existsWeakUntil succ p q (s :: seen))

partial def allWeakUntil [DecidableEq S]
    (succ : S -> List S) (p q : S -> Bool) (seen : List S) (s : S) : Bool :=
  if q s then
    true
  else if !p s then
    false
  else if seen.contains s then
    true
  else
    match succ s with
    | [] => true
    | next => next.all (allWeakUntil succ p q (s :: seen))

partial def holds [DecidableEq S] (succ : S -> List S) (s : S) : CTL S -> Bool
  | .atom p => p s
  | .neg p => !(holds succ s p)
  | .and p q => holds succ s p && holds succ s q
  | .or p q => holds succ s p || holds succ s q
  | .ex p => (succ s).any (fun s' => holds succ s' p)
  | .ax p => (succ s).all (fun s' => holds succ s' p)
  | .ef p => anyReachable succ (fun s' => holds succ s' p) [] s
  /- Keep universal eventuality in its exact dual form: search for one path on
     which the negation persists, then negate that existential witness. -/
  | .af p => !(existsPathAlways succ (fun s' => !(holds succ s' p)) [] s)
  | .eg p => existsPathAlways succ (fun s' => holds succ s' p) [] s
  /- Keep universal invariance in its exact dual form: search for one reachable
     counterexample instead of implementing a separate universal traversal. -/
  | .ag p => !(anyReachable succ (fun s' => !(holds succ s' p)) [] s)
  | .eu p q => existsUntil succ (fun s' => holds succ s' p) (fun s' => holds succ s' q) [] s
  | .au p q => allUntilFrom succ (fun s' => holds succ s' p) (fun s' => holds succ s' q) [] s
  | .ew p q => existsWeakUntil succ (fun s' => holds succ s' p) (fun s' => holds succ s' q) [] s
  | .aw p q => allWeakUntil succ (fun s' => holds succ s' p) (fun s' => holds succ s' q) [] s

end LeanFM.CTL.Dfs
