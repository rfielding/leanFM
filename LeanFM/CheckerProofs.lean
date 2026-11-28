import LeanFM.CTL

/-! # LeanFM's CTL checker, proved (clause selfhost.mcp.logic.checker; selfhost.requirements.proofs)

`CTL.label states succ f` lists the states where `f` holds. For every list of states that holds every
successor of its members (`Closed`), this proves: the fixpoint iteration of a monotone step reaches a
fixpoint within its bound; EX and AX are exact over the successors; EU and EF are exact over finite
paths; AG is the negation of EF of the negation; and the implication rule holds of the checker. -/

set_option linter.unusedSectionVars false

namespace LeanFM.CheckerProofs
open LeanFM LeanFM.CTL

variable {S : Type} [DecidableEq S]

/-- Every successor of a listed state is listed. -/
def Closed (states : List S) (succ : S → List S) : Prop := ∀ s ∈ states, ∀ t ∈ succ s, t ∈ states

theorem mem_iff (z : List S) (s : S) : mem z s = true ↔ s ∈ z := by
  simp [mem]

/-- A step that keeps what it had when given more. -/
def Mono (f : (S → Bool) → S → Bool) : Prop :=
  ∀ z z' : S → Bool, (∀ x, z x = true → z' x = true) → ∀ s, f z s = true → f z' s = true

theorem filter_length_le {α : Type} (l : List α) (P Q : α → Bool) (h : ∀ x ∈ l, P x = true → Q x = true) :
    (l.filter P).length ≤ (l.filter Q).length := by
  induction l with
  | nil => simp
  | cons x xs ih =>
    have ih' := ih (fun y hy => h y (List.mem_cons_of_mem _ hy))
    cases hP : P x <;> cases hQ : Q x <;> simp [List.filter_cons, hP, hQ] <;> try omega
    exact absurd (h x List.mem_cons_self hP) (by simp [hQ])

theorem filter_length_lt {α : Type} (l : List α) (P Q : α → Bool) (h : ∀ x ∈ l, P x = true → Q x = true)
    (hne : l.filter P ≠ l.filter Q) : (l.filter P).length < (l.filter Q).length := by
  induction l with
  | nil => simp at hne
  | cons x xs ih =>
    have h' : ∀ y ∈ xs, P y = true → Q y = true := fun y hy => h y (List.mem_cons_of_mem _ hy)
    cases hP : P x <;> cases hQ : Q x <;> simp [List.filter_cons, hP, hQ] at hne ⊢
    · exact ih h' hne
    · have := filter_length_le xs P Q h'; omega
    · exact absurd (h x List.mem_cons_self hP) (by simp [hQ])
    · exact ih h' hne

/-- One step of the iteration. -/
def step (states : List S) (f : (S → Bool) → S → Bool) (z : List S) : List S := states.filter (f (mem z))

theorem step_mono (states : List S) (f : (S → Bool) → S → Bool) (hm : Mono f) (z z' : List S)
    (h : ∀ x ∈ z, x ∈ z') : ∀ x ∈ step states f z, x ∈ step states f z' := by
  intro x hx
  simp only [step, List.mem_filter] at hx ⊢
  refine ⟨hx.1, hm (mem z) (mem z') ?_ x hx.2⟩
  intro y hy; rw [mem_iff] at hy ⊢; exact h y hy

/-- The iteration of a monotone step, from a list that is a filter of the states and grows under the
step, ends at a fixpoint once its fuel and the list's length exceed the number of states. -/
theorem iter_fix (states : List S) (f : (S → Bool) → S → Bool) (hm : Mono f) :
    ∀ (k : Nat) (z : List S) (P : S → Bool), z = states.filter P → (∀ x ∈ z, x ∈ step states f z) →
      states.length < k + z.length → step states f (iter states f k z) = iter states f k z := by
  intro k
  induction k with
  | zero =>
    intro z P hz _ hlen
    have : z.length ≤ states.length := by rw [hz]; exact List.length_filter_le _ _
    omega
  | succ k ih =>
    intro z P hz hgrow hlen
    simp only [iter]
    by_cases he : states.filter (f (mem z)) = z
    · simp only [he, if_true]; exact he
    · simp only [he, if_false]
      have hsub : ∀ x ∈ states, P x = true → f (mem z) x = true := by
        intro x hx hp
        have : x ∈ z := by rw [hz]; exact List.mem_filter.mpr ⟨hx, hp⟩
        have := hgrow x this
        simp only [step, List.mem_filter] at this; exact this.2
      have hlt : z.length < (states.filter (f (mem z))).length := by
        rw [hz] at he ⊢
        exact filter_length_lt states P _ (by rw [hz] at hsub; exact hsub) (fun e => he e.symm)
      exact ih _ _ rfl (step_mono states f hm z _ hgrow) (by omega)

/-- What every element of the start has, every element of the iteration has, when each step keeps it. -/
theorem iter_inv (states : List S) (f : (S → Bool) → S → Bool) (I : S → Prop)
    (hstep : ∀ z : List S, (∀ x ∈ z, I x) → ∀ x ∈ step states f z, I x) :
    ∀ (k : Nat) (z : List S), (∀ x ∈ z, I x) → ∀ x ∈ iter states f k z, I x := by
  intro k
  induction k with
  | zero => intro z hz; exact hz
  | succ k ih =>
    intro z hz
    simp only [iter]
    split
    · exact hz
    · exact ih _ (hstep z hz)

/-- The least fixpoint is a fixpoint. -/
theorem lfp_fixpoint (states : List S) (f : (S → Bool) → S → Bool) (hm : Mono f) :
    step states f (lfp states f) = lfp states f :=
  iter_fix states f hm _ [] (fun _ => false) (by simp) (by simp) (by simp)

/-- A finite path from `s` through states where `a` holds to one where `b` holds. -/
inductive Until (succ : S → List S) (a b : S → Bool) : S → Prop
  | here {s} : b s = true → Until succ a b s
  | next {s t} : a s = true → t ∈ succ s → Until succ a b t → Until succ a b s

/-- The until step, for any `a` and `b`, is monotone. -/
theorem until_mono (succ : S → List S) (a b : S → Bool) :
    Mono (fun z s => b s || (a s && (succ s).any z)) := by
  intro z z' h s hs
  simp only [Bool.or_eq_true, Bool.and_eq_true, List.any_eq_true] at hs ⊢
  rcases hs with hb | ⟨ha, t, ht, hz⟩
  · exact Or.inl hb
  · exact Or.inr ⟨ha, t, ht, h t hz⟩

/-- The least fixpoint of the until step is exactly the states with such a path. -/
theorem lfp_until (states : List S) (succ : S → List S) (hc : Closed states succ) (a b : S → Bool)
    (s : S) (hs : s ∈ states) :
    s ∈ lfp states (fun z s => b s || (a s && (succ s).any z)) ↔ Until succ a b s := by
  constructor
  · intro h
    refine iter_inv states _ (Until succ a b) ?_ _ [] (by simp) s h
    intro z hz x hx
    simp only [step, List.mem_filter, Bool.or_eq_true, Bool.and_eq_true, List.any_eq_true] at hx
    rcases hx.2 with hb | ⟨ha, t, ht, htz⟩
    · exact .here hb
    · exact .next ha ht (hz t ((mem_iff z t).mp htz))
  · intro h
    have hfix := lfp_fixpoint states _ (until_mono succ a b)
    induction h with
    | here hb =>
      rw [← hfix]; simp only [step, List.mem_filter]; exact ⟨hs, by simp [hb]⟩
    | @next s t ha ht _ ih =>
      have htz := ih (hc s hs t ht)
      rw [← hfix]; simp only [step, List.mem_filter]
      refine ⟨hs, ?_⟩
      simp only [Bool.or_eq_true, Bool.and_eq_true, List.any_eq_true]
      exact Or.inr ⟨ha, t, ht, (mem_iff _ t).mpr htz⟩

theorem label_ex (states : List S) (succ : S → List S) (p : CTL S) (s : S) (hs : s ∈ states) :
    mem (label states succ (.ex p)) s = true ↔ ∃ t ∈ succ s, mem (label states succ p) t = true := by
  simp [label, mem_iff, List.mem_filter, hs, List.any_eq_true]

theorem label_ax (states : List S) (succ : S → List S) (p : CTL S) (s : S) (hs : s ∈ states) :
    mem (label states succ (.ax p)) s = true ↔ ∀ t ∈ succ s, mem (label states succ p) t = true := by
  simp [label, mem_iff, List.mem_filter, hs, List.all_eq_true]

theorem label_eu (states : List S) (succ : S → List S) (hc : Closed states succ) (p q : CTL S)
    (s : S) (hs : s ∈ states) :
    mem (label states succ (.eu p q)) s = true ↔
      Until succ (mem (label states succ p)) (mem (label states succ q)) s := by
  rw [mem_iff]; exact lfp_until states succ hc _ _ s hs

theorem label_ef (states : List S) (succ : S → List S) (hc : Closed states succ) (p : CTL S)
    (s : S) (hs : s ∈ states) :
    mem (label states succ (.ef p)) s = true ↔ Until succ (fun _ => true) (mem (label states succ p)) s := by
  rw [mem_iff]
  have := lfp_until states succ hc (fun _ => true) (mem (label states succ p)) s hs
  simp only [Bool.true_and] at this
  simp only [label]; exact this

theorem label_ag (states : List S) (succ : S → List S) (hc : Closed states succ) (p : CTL S)
    (s : S) (hs : s ∈ states) :
    mem (label states succ (.ag p)) s = true ↔
      ¬ Until succ (fun _ => true) (fun t => !mem (label states succ p) t) s := by
  have := lfp_until states succ hc (fun _ => true) (fun t => !mem (label states succ p) t) s hs
  simp only [Bool.true_and] at this
  rw [← this, mem_iff]; simp only [label, List.mem_filter, hs, true_and]
  rw [Bool.not_eq_true', ← Bool.not_eq_true, mem_iff]

/-- Nothing is reached where nothing holds. -/
theorem until_nowhere (succ : S → List S) (a b : S → Bool) (hb : ∀ s, b s = false) (s : S) :
    ¬ Until succ a b s := by
  intro h
  induction h with
  | here h => simp [hb] at h
  | next _ _ _ ih => exact ih

/-- Nothing is reached where nothing listed holds, from a listed state. -/
theorem until_nowhere_in (states : List S) (succ : S → List S) (hc : Closed states succ) (a b : S → Bool)
    (hb : ∀ s ∈ states, b s = false) (s : S) (hs : s ∈ states) : ¬ Until succ a b s := by
  intro h
  revert hs
  induction h with
  | here h => intro hs; simp [hb _ hs] at h
  | @next s t _ ht _ ih => intro hs; exact ih (hc s hs t ht)

/-- The implication rule, of the checker itself: when the trigger holds at no state, a strong
implication holds at none and the plain always-implies at every one. -/
theorem checker_implication_rule (states : List S) (succ : S → List S) (hc : Closed states succ)
    (p q : CTL S) (hp : label states succ p = []) (s : S) (hs : s ∈ states) :
    mem (label states succ (CTL.stronglyImplies p q)) s = false ∧
    mem (label states succ (CTL.ag (CTL.implies p q))) s = true := by
  have hnone : ∀ t, mem (label states succ p) t = false := by intro t; simp [hp, mem]
  constructor
  · have hef : mem (label states succ (.ef p)) s = false := by
      cases h : mem (label states succ (.ef p)) s
      · rfl
      · exact absurd ((label_ef states succ hc p s hs).mp h) (until_nowhere succ _ _ hnone s)
    simp only [CTL.stronglyImplies, label, mem, List.contains_iff_mem, List.mem_filter] at hef ⊢
    simp_all
  · rw [label_ag states succ hc _ s hs]
    apply until_nowhere_in states succ hc _ _ _ s hs
    intro t ht
    have : t ∉ label states succ p := by simp [hp]
    simp [CTL.implies, label, mem, List.mem_filter, ht, this]

/-- The checker's proved properties, as one statement an implementation can name. -/
theorem checker_proved :
    (∀ (states : List S) (f : (S → Bool) → S → Bool), Mono f → step states f (lfp states f) = lfp states f) ∧
    (∀ (states : List S) succ (p : CTL S) s, s ∈ states →
      (mem (label states succ (.ex p)) s = true ↔ ∃ t ∈ succ s, mem (label states succ p) t = true)) ∧
    (∀ (states : List S) succ (p : CTL S) s, s ∈ states →
      (mem (label states succ (.ax p)) s = true ↔ ∀ t ∈ succ s, mem (label states succ p) t = true)) ∧
    (∀ (states : List S) succ, Closed states succ → ∀ (p q : CTL S) s, s ∈ states →
      (mem (label states succ (.eu p q)) s = true ↔ Until succ (mem (label states succ p)) (mem (label states succ q)) s)) ∧
    (∀ (states : List S) succ, Closed states succ → ∀ (p : CTL S) s, s ∈ states →
      (mem (label states succ (.ef p)) s = true ↔ Until succ (fun _ => true) (mem (label states succ p)) s)) ∧
    (∀ (states : List S) succ, Closed states succ → ∀ (p : CTL S) s, s ∈ states →
      (mem (label states succ (.ag p)) s = true ↔ ¬ Until succ (fun _ => true) (fun t => !mem (label states succ p) t) s)) ∧
    (∀ (states : List S) succ, Closed states succ → ∀ (p q : CTL S), label states succ p = [] → ∀ s, s ∈ states →
      mem (label states succ (CTL.stronglyImplies p q)) s = false ∧ mem (label states succ (CTL.ag (CTL.implies p q))) s = true) :=
  ⟨lfp_fixpoint, label_ex, label_ax, label_eu, label_ef, label_ag, checker_implication_rule⟩

end LeanFM.CheckerProofs
