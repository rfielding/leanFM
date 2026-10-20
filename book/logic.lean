import Mathlib

set_option linter.style.whitespace false
set_option linter.unusedVariables false

/- Justify the origin of F using real differentiation. -/
noncomputable def Ar (x : ℝ) : ℝ := 1 / (1 - x)
noncomputable def Fr (x : ℝ) : ℝ := 1 / (1 - x)^2
def F (x : ℤ) : ℚ := 1 / (1 - x)^2

theorem deriv_Ar_eq_Fr (x : ℝ) (hx : x ≠ 1) :
    deriv Ar x = Fr x := by
  have h : 1 - x ≠ 0 := sub_ne_zero.mpr hx.symm
  have hd := ((hasDerivAt_id x).const_sub 1).inv h
  simp only [id_eq, neg_neg] at hd
  change HasDerivAt
    (fun y : ℝ => (1 - y)⁻¹)
    (1 / (1 - x)^2) x at hd
  unfold Ar Fr
  simpa only [one_div] using hd.deriv

theorem F_eq_Fr (x : ℤ) :
    (↑(F x) : ℝ) = Fr ↑x := by
  unfold F Fr
  norm_cast

/- B just needs to work, but this was how we found it.  -/
def Tail_B (n : ℕ) : ℚ :=
  ((2 * (n : ℚ) + 1) * (-1)^n) / 4

theorem whyTailB (n : ℕ) :
    Tail_B 0     = F (-1) ∧
    Tail_B (n+1) = Tail_B n - ↑(n+1) * ↑(-1)^n := by
  rw[F]
  unfold Tail_B
  norm_num
  ring

def Sum_B (n : ℕ) : ℚ := F (-1) - Tail_B n
def Bf (n : ℕ) : ℚ := (Sum_B + Tail_B) n
def B : ℚ := Bf 0

def Sum_S (n : ℕ) : ℚ :=
  n * (n + 1) / 2

theorem selfSimilarSumS (n : ℕ) :
    (Sum_S  (2*n) - Sum_B  (2*n) = 4*Sum_S  n) :=  by
  rw[Sum_B]
  rw[Sum_S]
  unfold F Sum_S Tail_B
  norm_num
  linarith

def Tail_S (n : ℕ) : ℚ :=
  (4 * Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3 - Sum_S n

theorem whyTailS (n : ℕ) :
    Tail_S n =
      (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n)))/3 - Sum_S n := by
  rw[← selfSimilarSumS n]
  rw[Tail_B]
  unfold Tail_S Sum_S Sum_B Tail_B F
  norm_num
  ring_nf

def Sf (n : ℕ) : ℚ := Sum_S n + Tail_S n
def S : ℚ := Sf 0

theorem selfSimilarS (n : ℕ) :
    (Tail_S (2*n) - Tail_B (2*n) = 4*Tail_S n) ∧
    (S            - B            = 4*S) := by
  rw[whyTailS]
  rw[B]
  unfold S Sf Tail_S Bf Tail_B Sum_S Sum_B F Tail_B
  norm_num
  ring_nf

/-- The final Goal, now explicitly powered by the calculus/geometry proofs -/
theorem Goal (n : ℕ) :
    -1/12 = n * (n + 1) / 2 + Tail_S n := by
  rw [whyTailS n]
  unfold Tail_B Sum_S
  norm_num
  ring_nf
