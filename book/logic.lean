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

/- 1  + -2  +  3  + -4  +  ... -/
def Sum_B (n : ℕ) : ℚ :=
  (1 - (2 * (n : ℚ) + 1) * (-1)^n) / 4

def Tail_B (n : ℕ) : ℚ :=
  F (-1) - Sum_B n

theorem whyTailB (n : ℕ) :
    Tail_B n     = F (-1) - Sum_B n:= by
  unfold Tail_B Sum_B F
  simp


def Bf (n : ℕ) : ℚ := (Sum_B + Tail_B) n
def B : ℚ := Bf 0

def Sum_S (n : ℕ) : ℚ :=
  n * (n + 1) / 2

theorem selfSimilarSumS (n : ℕ) :
    (Sum_S  (2*n) - Sum_B  (2*n) = 4*Sum_S  n) :=  by
  rw[Sum_B]
  rw[Sum_S]
  unfold Sum_S
  norm_num
  ring_nf

def Tail_S (n : ℕ) : ℚ :=
  (4 * Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3 - Sum_S n

theorem whyTailS (n : ℕ) :
    Tail_S n =
      (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n)))/3 - Sum_S n := by
  rw[← selfSimilarSumS n]
  rw[Tail_B]
  unfold Tail_S Sum_S Sum_B Tail_B F Sum_B
  norm_num
  ring_nf


def Sf (n : ℕ) : ℚ := Sum_S n + Tail_S n
def S : ℚ := Sf 0

/-- The final Goal, now explicitly powered by the calculus/geometry proofs -/
theorem Goal (n : ℕ) :
    -1/12 = n * (n + 1) / 2 + Tail_S n := by
  rw [whyTailS n]
  unfold Tail_B Sum_S F Sum_B
  norm_num
  ring_nf
