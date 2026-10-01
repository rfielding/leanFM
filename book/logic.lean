import Mathlib

/- Justify the origin of our choice of F, with a real variant -/
noncomputable def Ar (x : ℝ) : ℝ := 1 / (1 - x)
noncomputable def Fr (x : ℝ) : ℝ := 1 / (1 - x)^2
def F (x : ℤ) : ℚ                := 1 / (1 - x)^2

theorem deriv_Ar_eq_Fr (x : ℝ) (hx : x ≠ 1) :
    deriv Ar x = Fr x := by
  have h : 1 - x ≠ 0 := sub_ne_zero.mpr hx.symm
  have hd            := (((hasDerivAt_id x).const_sub 1).inv h).deriv
  unfold Ar Fr
  simpa only [one_div, id_eq, neg_neg] using hd

theorem F_eq_Fr (x : ℤ) :
    ((F x : ℚ) : ℝ) = Fr (x : ℝ) := by
  unfold F Fr
  push_cast
  rfl

/- define B from F -/
def Tail_B (n : ℕ) : ℚ := ((2 * (n : ℚ) + 1) * (-1)^n) / 4
def Sum_B (n : ℕ) : ℚ  := F (-1) - Tail_B n
def Bf (n : ℕ) : ℚ     := (Sum_B + Tail_B) n
def B : ℚ              := Bf 0

/- define S. Calculate (S - B) -/
def Sum_S (n : ℕ) : ℚ  := n * (n + 1) / 2
def Tail_S (n : ℕ) : ℚ := (4 * Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3 - Sum_S n
def Sf (n : ℕ) : ℚ     := Sum_S n + Tail_S n
def S : ℚ              := Sf 0

theorem selfSimilarS (n : ℕ) :
    (Sum_S (2*n) - Sum_B (2*n) = 4*Sum_S n) ∧
    (Tail_S (2*n) - Tail_B (2*n) = 4*Tail_S n) ∧
    (S - B = 4*S) := by
  have finite :
      Sum_S (2*n) - Sum_B (2*n) = 4*Sum_S n := by
    unfold Sum_S Sum_B Tail_B F
    simp
    ring_nf
  have tails :
      Tail_S (2*n) - Tail_B (2*n) = 4*Tail_S n := by
    unfold Tail_S Sum_S Tail_B
    simp
    ring_nf
  have splitS (k : ℕ) : S = Sum_S k + Tail_S k := by
    unfold S Sf Tail_S Sum_S Tail_B
    simp
    ring_nf
  have splitB (k : ℕ) : B = Sum_B k + Tail_B k := by
    unfold B Bf Sum_B
    simp
  refine ⟨finite, tails, ?_⟩
  calc
    S - B =
        (Sum_S (2*n) + Tail_S (2*n)) -
        (Sum_B (2*n) + Tail_B (2*n)) := by
      rw [splitS (2*n), splitB (2*n)]
    _ = (Sum_S (2*n) - Sum_B (2*n)) +
        (Tail_S (2*n) - Tail_B (2*n)) := by ring
    _ = 4*Sum_S n + 4*Tail_S n := by
      rw [finite, tails]
    _ = 4*(Sum_S n + Tail_S n) := by ring
    _ = 4*S := by rw [splitS n]

theorem whyTailS (n : ℕ) :
    Tail_S n =
      (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n)))/3
        - Sum_S n := by
  have split (k : ℕ) : Tail_S k = S - Sum_S k := by
    unfold S Sf Tail_S Sum_S Tail_B
    simp
    ring_nf
  have hn := split n
  have h2n := split (2*n)
  have derivation :
      (Tail_S (2*n) - Tail_B (2*n) = 4*Tail_S n) ↔
      (Tail_S n =
        (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n)))/3
          - Sum_S n) := by
    calc
      (Tail_S (2*n) - Tail_B (2*n) = 4*Tail_S n)
        ↔ (4*(S - Sum_S n) =
            S - (Sum_S (2*n) + Tail_B (2*n))) := by
          constructor <;> intro h <;> linarith
      _ ↔ (3*S =
            4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) := by
          constructor <;> intro h <;> linarith
      _ ↔ (Tail_S n =
            (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n)))/3
              - Sum_S n) := by
          constructor <;> intro h <;> linarith
  exact derivation.mp (selfSimilarS n).2.1

theorem whyTailB (n : ℕ) :
  Tail_B 0 = F (-1) ∧
  Tail_B (n+1) =
    Tail_B n - (n+1 : ℚ) * (-1 : ℚ)^n := by
  unfold Tail_B F
  simp [pow_succ]
  ring_nf
  simp

theorem Goal (n : ℕ) :
  -1/12 = n*(n+1)/2 + Tail_S n := by
  unfold Tail_S Sum_S Tail_B
  simp
  ring_nf
