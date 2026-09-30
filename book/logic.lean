import Mathlib

/- Justify the origin of our choice of F, with a real variant -/
noncomputable def Ar (x : Real) : Real := 1 / (1 - x)
noncomputable def Fr (x : Real) : Real := 1 / (1 - x)^2
def F (x : Int) : Rat := 1 / (1 - x)^2

theorem deriv_Ar_eq_Fr (x : Real) (hx : Ne x 1) :
    deriv Ar x = Fr x := by
  have h : Ne (1 - x) 0 := sub_ne_zero.mpr hx.symm
  have hd := (((hasDerivAt_id x).const_sub 1).inv h).deriv
  unfold Ar Fr
  simpa only [one_div, id_eq, neg_neg] using hd

theorem F_eq_Fr (x : Int) :
    ((F x : Rat) : Real) = Fr (x : Real) := by
  unfold F Fr
  push_cast
  rfl

/- define B from F -/
def Tail_B (n : Nat) : Rat := ((2 * (n : Rat) + 1) * (-1)^n) / 4
def Sum_B (n : Nat) : Rat := F (-1) - Tail_B n
def Bf (n : Nat) : Rat := (Sum_B + Tail_B) n
def B : Rat := Bf 0

/- define S. Calculate (S - B) -/
def Sum_S (n : Nat) : Rat := n * (n + 1) / 2
def Tail_S (n : Nat) : Rat := (4 * Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3 - Sum_S n
def Sf (n : Nat) : Rat := Sum_S n + Tail_S n
def S : Rat := Sf 0

theorem selfSimilarS (n : Nat) :
  And (Sum_S (2*n) - Sum_B (2*n) = 4*Sum_S n)
  (And (Tail_S (2*n) - Tail_B (2*n) = 4*Tail_S n)
  (S - B = 4*S)
  )
  := by
    unfold S B Sf Bf Tail_S Sum_S Sum_B Tail_B F
    simp
    ring_nf
    simp

theorem whyTailS (n : Nat) :
  And (Tail_S n = (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3 - Sum_S n)
  (And (Sum_S n + Tail_S n = (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3)
  (And (S = (4*Sum_S n - (Sum_S (2*n) + Tail_B (2*n))) / 3)
  (S = (4*Sum_S n - Sum_S (2*n) - Tail_B (2*n)) / 3)
  ))
  := by
    unfold Tail_S Sum_S Tail_B S Sf Tail_S Sum_S Tail_B
    simp
    ring_nf
    simp

theorem whyTailB (n : Nat) :
  And (Tail_B 0 = F (-1))
  Tail_B (n+1) =
    Tail_B n - (n+1 : Rat) * (-1 : Rat)^n := by
  unfold Tail_B F
  simp [pow_succ]
  ring_nf
  simp

theorem Goal (n : Nat) :
  -1/12 = n*(n+1)/2 + Tail_S n := by
  unfold Tail_S Sum_S Tail_B
  simp
  ring_nf
