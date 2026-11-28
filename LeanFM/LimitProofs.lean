import LeanFM.CallLimits

/-! # A call never raises a limit past the operator's ceiling, proved
(clause selfhost.mcp.limits; selfhost.requirements.proofs)

Every limit `validate` applies is `cap` of what was asked, and `cap` never exceeds the request nor the
limit's default times the operator's factor (LEANFM_LIMIT_CEILING). -/

namespace LeanFM.LimitProofs
open Lean LeanFM.CallLimits

theorem cap_within_ceiling (l : Limit) (k : String) (n factor : Nat) :
    (cap l k n factor).applied ≤ l.default * factor := Nat.min_le_right _ _

theorem cap_within_request (l : Limit) (k : String) (n factor : Nat) :
    (cap l k n factor).applied ≤ (cap l k n factor).requested := Nat.min_le_left _ _

/-- What `mapM` answers in `Except` keeps every property each answer has. -/
theorem mapM_all {α β ε : Type} (f : α → Except ε β) (P : β → Prop)
    (hf : ∀ x y, f x = .ok y → P y) : ∀ (xs : List α) (ys : List β), xs.mapM f = .ok ys → ∀ y ∈ ys, P y := by
  intro xs
  induction xs with
  | nil => intro ys h y hy; simp [List.mapM_nil, pure, Except.pure] at h; subst h; simp at hy
  | cons x xs ih =>
    intro ys h y hy
    simp only [List.mapM_cons] at h
    cases hx : f x with
    | error e => simp [hx, bind, Except.bind] at h
    | ok b =>
      cases hr : xs.mapM f with
      | error e => simp [hx, hr, bind, Except.bind] at h
      | ok bs =>
        simp [hx, hr, bind, Except.bind, pure, Except.pure] at h
        subst h
        rcases List.mem_cons.mp hy with rfl | hm
        · exact hf x y hx
        · exact ih bs hr y hm

/-- Every entry a call gives is capped at its limit's default times the factor. -/
theorem applyEntry_within_ceiling (factor : Nat) (kv : String × Json) (a : Applied)
    (h : applyEntry factor kv = .ok a) : a.applied ≤ defaultOf a.name * factor := by
  unfold applyEntry at h
  split at h
  · cases h
  · rename_i l hl
    split at h
    · split at h
      · cases h; simp [cap, defaultOf, hl]; exact Nat.min_le_right _ _
      · cases h
    · cases h

/-- Every limit a call is given is at most its default times the operator's factor. -/
theorem validate_within_ceiling (args : Json) (factor : Nat) (as : List Applied)
    (h : validate args factor = .ok as) : ∀ a ∈ as, a.applied ≤ defaultOf a.name * factor := by
  unfold validate at h
  split at h
  · cases h; simp
  · cases h; simp
  · exact mapM_all _ _ (fun kv a hy => applyEntry_within_ceiling factor kv a hy) _ _ h
  · cases h

end LeanFM.LimitProofs
