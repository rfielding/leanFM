import LeanFM.RunCheck

/-! # The four values of run judging, proved (clause selfhost.requirements.proofs)

The laws selfhost.requirements.standing states for RunCheck.V, proved by Lean's kernel rather than
tested: `not` twice is the identity, `and` and `or` commute, De Morgan holds both ways, and one run
never refutes a some-path claim nor proves an all-paths claim. -/

namespace LeanFM.RunCheck.Proofs
open LeanFM.RunCheck

theorem not_not (v : V) : v.not.not = v := by cases v <;> rfl
theorem and_comm (a b : V) : a.and b = b.and a := by cases a <;> cases b <;> rfl
theorem or_comm (a b : V) : a.or b = b.or a := by cases a <;> cases b <;> rfl
theorem not_and (a b : V) : (a.and b).not = a.not.or b.not := by cases a <;> cases b <;> rfl
theorem not_or (a b : V) : (a.or b).not = a.not.and b.not := by cases a <;> cases b <;> rfl
theorem some_never_false (v : V) : v.some_ ≠ .false_ := by cases v <;> simp [V.some_]
theorem all_never_true (v : V) : v.all_ ≠ .true_ := by cases v <;> simp [V.all_]

/-- Every law above, as one statement an implementation can name as evidence. -/
theorem standing_laws :
    (∀ v : V, v.not.not = v) ∧ (∀ a b : V, a.and b = b.and a) ∧ (∀ a b : V, a.or b = b.or a) ∧
    (∀ a b : V, (a.and b).not = a.not.or b.not) ∧ (∀ a b : V, (a.or b).not = a.not.and b.not) ∧
    (∀ v : V, v.some_ ≠ .false_) ∧ (∀ v : V, v.all_ ≠ .true_) :=
  ⟨not_not, and_comm, or_comm, not_and, not_or, some_never_false, all_never_true⟩

end LeanFM.RunCheck.Proofs
