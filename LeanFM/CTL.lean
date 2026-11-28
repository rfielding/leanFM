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
  | eu : CTL S -> CTL S -> CTL S
  | au : CTL S -> CTL S -> CTL S
  | ew : CTL S -> CTL S -> CTL S
  | aw : CTL S -> CTL S -> CTL S

namespace CTL

infixr:45 " AU " => CTL.au
infixr:45 " EU " => CTL.eu
infixr:45 " AW " => CTL.aw
infixr:45 " EW " => CTL.ew

def implies {S : Type} (p q : CTL S) : CTL S :=
  CTL.or (CTL.neg p) q

/-- Non-vacuous temporal implication: `p` is possible and necessarily implies `q`. -/
def stronglyImplies {S : Type} (p q : CTL S) : CTL S :=
  CTL.and (CTL.ef p) (CTL.ag (implies p q))

/-- The outcomes of a choice (selfhost.mcp.logic.functions): each of `ps` can happen, and on every path
one of them eventually happens; the disjunction under one `AF`, not one `AF` per outcome. -/
def outcomes {S : Type} (ps : List (CTL S)) : CTL S :=
  ps.foldr (fun p acc => CTL.and (CTL.ef p) acc) (CTL.af (ps.foldr CTL.or (CTL.atom fun _ => false)))

/-- Right after `p`, the next step is one of `qs`, each possible (selfhost.mcp.logic.functions). -/
def follows {S : Type} (p : CTL S) (qs : List (CTL S)) : CTL S :=
  CTL.ag (implies p (qs.foldr (fun q acc => CTL.and (CTL.ex q) acc) (CTL.ax (qs.foldr CTL.or (CTL.atom fun _ => false)))))

/-- `p` can happen, and every `p` is eventually followed by `q`: never vacuous. -/
def leadsTo {S : Type} (p q : CTL S) : CTL S := stronglyImplies p (CTL.af q)

/-- `q` never happens before `p`, and need not happen at all. -/
def precedes {S : Type} (p q : CTL S) : CTL S := CTL.neg (CTL.eu (CTL.neg p) q)

/-! Words that read as English (selfhost.mcp.logic.words), each one primitive. -/
def possibly {S : Type} (p : CTL S) : CTL S := CTL.ef p
def inevitably {S : Type} (p : CTL S) : CTL S := CTL.af p
def always {S : Type} (p : CTL S) : CTL S := CTL.ag p
def someAlways {S : Type} (p : CTL S) : CTL S := CTL.eg p
def allNext {S : Type} (p : CTL S) : CTL S := CTL.ax p
def someNext {S : Type} (p : CTL S) : CTL S := CTL.ex p
def allUntil {S : Type} (p q : CTL S) : CTL S := CTL.au p q
def someUntil {S : Type} (p q : CTL S) : CTL S := CTL.eu p q
def allUnless {S : Type} (p q : CTL S) : CTL S := CTL.aw p q
def someUnless {S : Type} (p q : CTL S) : CTL S := CTL.ew p q

variable {S : Type}

/-! The checker (clause selfhost.mcp.logic.checker): explore the reachable states, then label each
subformula with the list of states where it holds, once. -/

/-- Membership in a label. -/
def mem [DecidableEq S] (z : List S) (s : S) : Bool := z.contains s

/-- A step over `states`, applied from `z` until it changes nothing, at most `fuel` times. -/
def iter [DecidableEq S] (states : List S) (f : (S → Bool) → S → Bool) : Nat → List S → List S
  | 0, z => z
  | k + 1, z => let z' := states.filter (f (mem z)); if z' = z then z else iter states f k z'

/-- The least fixpoint: from no states. -/
def lfp [DecidableEq S] (states : List S) (f : (S → Bool) → S → Bool) : List S :=
  iter states f (states.length + 1) []

/-- The greatest fixpoint: from every state. -/
def gfp [DecidableEq S] (states : List S) (f : (S → Bool) → S → Bool) : List S :=
  iter states f (states.length + 1) states

/-- The labels of one formula over `states`. -/
def label [DecidableEq S] (states : List S) (succ : S → List S) : CTL S → List S
  | .atom p => states.filter p
  | .neg p => let a := label states succ p; states.filter fun s => !mem a s
  | .and p q => let a := label states succ p; let b := label states succ q; states.filter fun s => mem a s && mem b s
  | .or p q => let a := label states succ p; let b := label states succ q; states.filter fun s => mem a s || mem b s
  | .ex p => let a := label states succ p; states.filter fun s => (succ s).any (mem a)
  | .ax p => let a := label states succ p; states.filter fun s => (succ s).all (mem a)
  | .ef p => let a := label states succ p
      lfp states (fun z s => mem a s || (succ s).any z)
  | .ag p => let a := label states succ p
      let e := lfp states (fun z s => !mem a s || (succ s).any z)
      states.filter fun s => !mem e s
  | .af p => let a := label states succ p
      lfp states (fun z s => mem a s || (!(succ s).isEmpty && (succ s).all z))
  | .eg p => let a := label states succ p
      gfp states (fun z s => mem a s && ((succ s).isEmpty || (succ s).any z))
  | .eu p q => let a := label states succ p; let b := label states succ q
      lfp states (fun z s => mem b s || (mem a s && (succ s).any z))
  | .au p q => let a := label states succ p; let b := label states succ q
      lfp states (fun z s => mem b s || (mem a s && !(succ s).isEmpty && (succ s).all z))
  | .ew p q => let a := label states succ p; let b := label states succ q
      gfp states (fun z s => mem b s || (mem a s && ((succ s).isEmpty || (succ s).any z)))
  | .aw p q => let a := label states succ p; let b := label states succ q
      gfp states (fun z s => mem b s || (mem a s && (succ s).all z))

/-- The states reachable from `seen`, breadth first; `frontier` are the ones not yet expanded. -/
partial def explore [DecidableEq S] (succ : S → List S) (seen frontier : List S) : List S :=
  match frontier with
  | [] => seen
  | _ =>
    let next := ((frontier.flatMap succ).eraseDups).filter fun t => !seen.contains t
    explore succ (seen ++ next) next

def holds [DecidableEq S] (succ : S -> List S) (s : S) (f : CTL S) : Bool :=
  mem (label (explore succ [s] [s]) succ f) s

end CTL
end LeanFM
