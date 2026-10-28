import Mathlib

set_option linter.style.whitespace false
set_option linter.unusedVariables false

/-!
# 1 - 1 + 1 - ... = 1/2,  1 - 2 + 3 - ... = 1/4,  1 + 2 + 3 + ... = -1/12

Everything lives in ℚ. No limits, no convergence, and no values are given:
all three totals are derived.

Partial sums:
* `Sum_G n` : 1 - 1 + 1 - 1 + ...   (n terms)
* `Sum_B n` : 1 - 2 + 3 - 4 + ...   (n terms)
* `Sum_S n` : 1 + 2 + 3 + ... + n

Three finite identities, proved for every n:
* `idG` : Sum_G (n+1) + Sum_G n       = 1
* `idB` : Sum_B (n+1) + Sum_B n       = Sum_G (n+1)
* `idS` : Sum_S (2n)  - Sum_B (2n)    = 4 * Sum_S n

The rules of the system (hypotheses, never baked into definitions):
1. A total does not depend on n:  Sum n + Tail n = constant
2. Tails obey the same three identities (the constant 1 in idG has no tail,
   so its tail version has 0 on the right)

Only these three identities are admitted. Admitting *every* finite identity
is inconsistent (e.g. the shift identity for S), so the list is explicit
and `tails_exist` proves this list is consistent.
-/

/-! ## Partial sums -/

/-- 1 - 1 + 1 - 1 + ... (n terms) -/
def Sum_G (n : ℕ) : ℚ :=
  (1 - (-1)^n) / 2

/-- 1 - 2 + 3 - 4 + ... (n terms) -/
def Sum_B (n : ℕ) : ℚ :=
  (1 - (2 * (n : ℚ) + 1) * (-1)^n) / 4

/-- 1 + 2 + ... + n -/
def Sum_S (n : ℕ) : ℚ :=
  n * (n + 1) / 2

/-! ## The finite identities -/

theorem idG (n : ℕ) :
    Sum_G (n+1) + Sum_G n = 1 := by
  unfold Sum_G
  ring

theorem idB (n : ℕ) :
    Sum_B (n+1) + Sum_B n = Sum_G (n+1) := by
  unfold Sum_B Sum_G
  push_cast
  ring

theorem idS (n : ℕ) :
    Sum_S (2*n) - Sum_B (2*n) = 4 * Sum_S n := by
  have h : ((-1 : ℚ))^(2*n) = 1 := by
    rw [pow_mul]
    norm_num
  unfold Sum_S Sum_B
  rw [h]
  push_cast
  ring

/-! ## The rules force all three totals -/

/-- Any tails obeying the rules force G = 1/2, B = 1/4, S = -1/12.
    None of these numbers appears in the hypotheses. -/
theorem totals_forced (TS TB TG : ℕ → ℚ) (s b g : ℚ)
    (hG : ∀ n, Sum_G n + TG n = g)                     -- rule 1
    (hB : ∀ n, Sum_B n + TB n = b)                     -- rule 1
    (hS : ∀ n, Sum_S n + TS n = s)                     -- rule 1
    (tG : ∀ n, TG (n+1) + TG n = 0)                    -- rule 2 for idG
    (tB : ∀ n, TB (n+1) + TB n = TG (n+1))             -- rule 2 for idB
    (tS : ∀ n, TS (2*n) - TB (2*n) = 4 * TS n) :       -- rule 2 for idS
    g = 1/2 ∧ b = 1/4 ∧ s = -1/12 := by
  have hg : g = 1/2 := by
    have i := idG 0
    have a := hG (0+1)
    have c := hG 0
    have t := tG 0
    linarith
  have hb : b = 1/4 := by
    have i := idB 0
    have a := hB (0+1)
    have c := hB 0
    have d := hG (0+1)
    have t := tB 0
    linarith
  have hs : s = -1/12 := by
    have i := idS 1
    have a := hS (2*1)
    have c := hB (2*1)
    have d := hS 1
    have t := tS 1
    linarith
  exact ⟨hg, hb, hs⟩

/-! ## The rules are consistent -/

/-- Witness tails (used only to show the rules can be met). -/
def Tail_G (n : ℕ) : ℚ := 1/2 - Sum_G n
def Tail_B (n : ℕ) : ℚ := 1/4 - Sum_B n
def Tail_S (n : ℕ) : ℚ := -1/12 - Sum_S n

theorem tails_exist : ∃ TS TB TG : ℕ → ℚ,
    (∀ n, Sum_G n + TG n = 1/2) ∧
    (∀ n, Sum_B n + TB n = 1/4) ∧
    (∀ n, Sum_S n + TS n = -1/12) ∧
    (∀ n, TG (n+1) + TG n = 0) ∧
    (∀ n, TB (n+1) + TB n = TG (n+1)) ∧
    (∀ n, TS (2*n) - TB (2*n) = 4 * TS n) :=
  ⟨Tail_S, Tail_B, Tail_G,
    fun n => by unfold Tail_G; ring,
    fun n => by unfold Tail_B; ring,
    fun n => by unfold Tail_S; ring,
    fun n => by
      have := idG n
      unfold Tail_G
      linarith,
    fun n => by
      have := idB n
      unfold Tail_B Tail_G
      linarith,
    fun n => by
      have := idS n
      unfold Tail_S Tail_B
      linarith⟩

/-! ## The tail is determined by the Sum -/

theorem tails_unique (TS TB TG : ℕ → ℚ) (s b g : ℚ)
    (hG : ∀ n, Sum_G n + TG n = g)
    (hB : ∀ n, Sum_B n + TB n = b)
    (hS : ∀ n, Sum_S n + TS n = s)
    (tG : ∀ n, TG (n+1) + TG n = 0)
    (tB : ∀ n, TB (n+1) + TB n = TG (n+1))
    (tS : ∀ n, TS (2*n) - TB (2*n) = 4 * TS n)
    (n : ℕ) :
    TS n = Tail_S n := by
  obtain ⟨_, _, hs⟩ := totals_forced TS TB TG s b g hG hB hS tG tB tS
  have := hS n
  unfold Tail_S
  linarith

/-! ## Final statement -/

theorem Goal (TS TB TG : ℕ → ℚ) (s b g : ℚ)
    (hG : ∀ n, Sum_G n + TG n = g)
    (hB : ∀ n, Sum_B n + TB n = b)
    (hS : ∀ n, Sum_S n + TS n = s)
    (tG : ∀ n, TG (n+1) + TG n = 0)
    (tB : ∀ n, TB (n+1) + TB n = TG (n+1))
    (tS : ∀ n, TS (2*n) - TB (2*n) = 4 * TS n)
    (n : ℕ) :
    -1/12 = n * (n + 1) / 2 + TS n := by
  obtain ⟨_, _, hs⟩ := totals_forced TS TB TG s b g hG hB hS tG tB tS
  have := hS n
  unfold Sum_S at this
  linarith

#print axioms Goal
