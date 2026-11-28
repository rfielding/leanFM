import LeanFM.CTL

/-! # The implication rule, proved (clause selfhost.mcp.logic.implication; selfhost.requirements.proofs)

"Features need strong implication; security guarantees need weak implication." Over a total
semantics of LeanFM's CTL type, where every fixpoint is iterated a fuel bound of steps (the number
of states of a finite model is enough), this proves the rule's two halves for every model and every
bound: when the trigger can never happen, a strong implication is false at every state, and the
plain always-implies is true at every state. LeanFM.CTL.holds, the checker LeanFM runs, is partial;
it is tested against these definitions, not proved equal to them. -/

namespace LeanFM.CTLProofs
open LeanFM

variable {S : Type}

/-- Some path from `s` reaches a state where `P` holds, within `k` steps. -/
def reach (succ : S → List S) (P : S → Bool) : Nat → S → Bool
  | 0 => fun _ => false
  | k + 1 => fun s => P s || (succ s).any (reach succ P k)

/-- The total semantics, with `n` steps for each fixpoint. The words the rule needs (atom, neg, and,
or, ex, ax, ef, ag) are exact; the others are read through them (af p as not eg not p, eg p as not
af not p, and the untils as ef and ag of their parts), which the rule does not use. -/
def sat (n : Nat) (succ : S → List S) : CTL S → S → Bool
  | .atom p => p
  | .neg p => fun s => !(sat n succ p s)
  | .and p q => fun s => sat n succ p s && sat n succ q s
  | .or p q => fun s => sat n succ p s || sat n succ q s
  | .ex p => fun s => (succ s).any (sat n succ p)
  | .ax p => fun s => (succ s).all (sat n succ p)
  | .ef p => reach succ (sat n succ p) n
  | .ag p => fun s => !(reach succ (fun t => !(sat n succ p t)) n s)
  | .af p => fun s => sat n succ p s
  | .eg p => fun s => sat n succ p s
  | .eu _ q => reach succ (sat n succ q) n
  | .au _ q => reach succ (sat n succ q) n
  | .ew p _ => fun s => !(reach succ (fun t => !(sat n succ p t)) n s)
  | .aw p _ => fun s => !(reach succ (fun t => !(sat n succ p t)) n s)

/-- Nothing is reached where nothing holds. -/
theorem reach_nowhere (succ : S → List S) (P : S → Bool) (h : ∀ s, P s = false) :
    ∀ k s, reach succ P k s = false := by
  intro k
  induction k with
  | zero => intro s; rfl
  | succ k ih => intro s; simp [reach, h s, List.any_eq_false, ih]

/-- A trigger that can never happen is never possible. -/
theorem possibly_nowhere (n : Nat) (succ : S → List S) (p : CTL S) (h : ∀ s, sat n succ p s = false) :
    ∀ s, sat n succ (.ef p) s = false := by
  intro s; exact reach_nowhere succ (sat n succ p) h n s

/-- A feature, written with strong implication, fails when its trigger can never happen. -/
theorem strong_fails_without_trigger (n : Nat) (succ : S → List S) (p q : CTL S)
    (h : ∀ s, sat n succ p s = false) : ∀ s, sat n succ (CTL.stronglyImplies p q) s = false := by
  intro s
  have hp : reach succ (sat n succ p) n s = false := reach_nowhere succ (sat n succ p) h n s
  show (reach succ (sat n succ p) n s && sat n succ (CTL.ag (CTL.implies p q)) s) = false
  rw [hp]; rfl

/-- A guarantee, written with weak implication (always implies), holds when its trigger can never
happen: a door that never opens lets no one in. -/
theorem weak_holds_without_trigger (n : Nat) (succ : S → List S) (p q : CTL S)
    (h : ∀ s, sat n succ p s = false) : ∀ s, sat n succ (CTL.ag (CTL.implies p q)) s = true := by
  intro s
  have hn : ∀ t, (!(sat n succ (CTL.implies p q) t)) = false := by
    intro t; simp [CTL.implies, sat, h t]
  simp [sat, reach_nowhere succ _ hn n s]

/-- The difference between the two is exactly `possibly`: strong implication is weak implication
and the trigger being possible. -/
theorem strong_is_possible_and_weak (n : Nat) (succ : S → List S) (p q : CTL S) (s : S) :
    sat n succ (CTL.stronglyImplies p q) s = (sat n succ (.ef p) s && sat n succ (CTL.ag (CTL.implies p q)) s) := rfl

/-- The rule, as one statement an implementation can name as evidence. -/
theorem implication_rule :
    (∀ (n : Nat) (succ : S → List S) (p q : CTL S), (∀ s, sat n succ p s = false) →
      ∀ s, sat n succ (CTL.stronglyImplies p q) s = false) ∧
    (∀ (n : Nat) (succ : S → List S) (p q : CTL S), (∀ s, sat n succ p s = false) →
      ∀ s, sat n succ (CTL.ag (CTL.implies p q)) s = true) :=
  ⟨strong_fails_without_trigger, weak_holds_without_trigger⟩

end LeanFM.CTLProofs
