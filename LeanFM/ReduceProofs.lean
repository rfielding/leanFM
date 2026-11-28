import LeanFM.Reduce

/-! # Submitted reduce_run programs use only the names they are given, proved
(required proof "Submitted logic never runs as code", for reduce_run; hazard reduce.code-execution;
selfhost.requirements.proofs)

Before a program runs, `unbound` checks every form. `names_checked`: when it accepts a form, every
atom anywhere in the form is a number, true or false, one of the program's defines, a primitive, a
special form's keyword, a name in scope, or a name the form itself binds (a lambda's parameter or a
let's name). While it runs, `resolve` is the only way a name gets a meaning. `resolve_only`: it gives a
number, true or false, a local, a define, or a primitive of the fixed list, and nothing else. There
is no name for a file, the clock, the network, Lean or a shell; `Reduce.M` has no IO in its type. -/

set_option linter.unusedSectionVars false

namespace LeanFM.ReduceProofs
open LeanFM.Reduce

mutual
def atoms : Sx → List String
  | .atom a => [a]
  | .str _ => []
  | .list xs => atomsAll xs
def atomsAll : List Sx → List String
  | [] => []
  | x :: xs => atoms x ++ atomsAll xs
end

def letNames (bs : List Sx) : List String := bs.filterMap fun | .list (.atom n :: _) => some n | _ => none

def here : List Sx → List String
  | .atom "lambda" :: .list ps :: _ => atomsAll ps
  | .atom "let" :: .list binds :: _ => letNames binds
  | _ => []

mutual
def binders : Sx → List String
  | .list xs => here xs ++ bindersAll xs
  | _ => []
def bindersAll : List Sx → List String
  | [] => []
  | x :: xs => binders x ++ bindersAll xs
end

/-- A name a program may use: a number, true or false, one of its defines, a primitive, a special
form's keyword, or a name in `V`. -/
def Ok (defs V : List String) (a : String) : Prop :=
  (parseNum a).isSome = true ∨ a = "true" ∨ a = "false" ∨ a ∈ defs ∨ a ∈ primitives ∨ a ∈ special ∨ a ∈ V

theorem Ok.mono {defs V W : List String} {a : String} (h : Ok defs V a) (hw : ∀ x ∈ V, x ∈ W) : Ok defs W a := by
  unfold Ok at *; rcases h with h|h|h|h|h|h|h <;> simp_all

theorem allowed_ok {defs bound : List String} {a : String} (h : allowed defs bound a = true) : Ok defs bound a := by
  unfold allowed at h; unfold Ok; simp only [Bool.or_eq_true, beq_iff_eq, List.contains_iff_mem] at h
  rcases h with ((((h|h)|h)|h)|h)|h <;> simp_all

theorem orElse_none {α : Type} (o : Option α) (f : Unit → Option α) : o.orElse f = none ↔ o = none ∧ f () = none := by
  cases o <;> simp [Option.orElse]

theorem paramNames_sub (ps : List Sx) : ∀ x ∈ paramNames ps, x ∈ atomsAll ps := by
  induction ps with
  | nil => simp [paramNames]
  | cons p ps ih =>
    intro x hx
    have ih' : x ∈ paramNames ps → x ∈ atomsAll ps := ih x
    cases p with
    | atom q =>
      simp only [paramNames, List.filterMap_cons, List.mem_cons] at hx
      simp only [atomsAll, atoms, List.mem_append, List.mem_singleton]
      rcases hx with h | h
      · exact Or.inl h
      · exact Or.inr (ih' h)
    | str q => simp only [paramNames, List.filterMap_cons] at hx; simp only [atomsAll, atoms, List.nil_append]; exact ih' hx
    | list q => simp only [paramNames, List.filterMap_cons] at hx; simp only [atomsAll, List.mem_append]; exact Or.inr (ih' hx)

macro "fin" : tactic => `(tactic| (simp only [Ok, allowed, special, atoms, atomsAll, binders, bindersAll, here, letNames,
    List.mem_append, List.mem_cons, List.not_mem_nil, or_false, List.append_nil, List.filterMap_cons,
    List.contains_iff_mem, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq] at *; grind))

theorem names_checked (defs : List String) :
    ∀ bound x, unbound defs bound x = none → ∀ a ∈ atoms x, Ok defs (bound ++ binders x) a := by
  intro bound x
  induction bound, x using unbound.induct defs
    (motive2 := fun bound xs => unboundAll defs bound xs = none → ∀ a ∈ atomsAll xs, Ok defs (bound ++ bindersAll xs) a)
    (motive3 := fun bound bs body => unboundLet defs bound bs body = none →
      ∀ a ∈ atomsAll bs ++ atoms body, Ok defs (bound ++ letNames bs ++ bindersAll bs ++ binders body) a) with
  | case1 => simp [atoms]
  | case2 bound a h => intro _ b hb; fin
  | case3 bound a h => intro hu; simp [unbound, h] at hu
  | case4 bound ps body ih =>
    intro hu a ha
    rw [unbound.eq_3] at hu
    have h1 := ih hu
    have h2 := paramNames_sub ps
    fin
  | case5 bound binds body ih =>
    intro hu a ha
    rw [unbound.eq_4] at hu
    have h1 := ih hu
    fin
  | case6 bound s rest n1 n2 hs ih =>
    intro hu a ha
    rw [unbound.eq_5 _ _ _ _ n1 n2] at hu
    simp only [hs, ite_true] at hu
    have h1 := ih hu
    fin
  | case7 bound s rest n1 n2 hs =>
    intro hu; rw [unbound.eq_5 _ _ _ _ n1 n2] at hu
    simp only [Bool.or_eq_true, List.contains_iff_mem] at hs; simp [hs] at hu
  | case8 bound xs n1 n2 n3 ih =>
    intro hu a ha
    rw [unbound.eq_6 _ _ _ n1 n2 n3] at hu
    have h1 := ih hu
    fin
  | case9 => rename_i ha; simp [atomsAll] at ha
  | case10 bound x xs ih1 ih2 =>
    rename_i hu a ha
    simp only [unboundAll, orElse_none] at hu
    have h1 := ih1 hu.1
    have h2 := ih2 hu.2
    fin
  | case11 bound body ih =>
    rename_i hu a ha
    simp only [unboundLet] at hu
    have h1 := ih hu
    fin
  | case12 bound n e bs body ih1 ih2 =>
    rename_i hu a ha
    simp only [unboundLet, orElse_none] at hu
    have h1 := ih1 hu.1
    have h2 := ih2 hu.2
    fin
  | case13 bound b bs body nb ih1 ih2 =>
    rename_i hu a ha
    rw [unboundLet.eq_3 _ _ _ _ _ nb] at hu
    simp only [orElse_none] at hu
    have h1 := ih1 hu.1
    have h2 := ih2 hu.2
    have hb : ∀ y ∈ letNames bs, y ∈ letNames (b :: bs) := by
      intro y hy
      simp only [letNames, List.filterMap_cons] at hy ⊢
      split <;> simp_all
    clear nb ih1 ih2
    revert hb
    generalize letNames (b :: bs) = L
    intro hb
    fin


/-- While a program runs, a name means a number, true or false, a local, a define, or a primitive of
the fixed list, and nothing else. -/
theorem resolve_only (scope : List (String × Value)) (globals : Std.HashMap String Value) (a : String) (v : Value)
    (h : resolve scope globals a = some v) :
    (∃ q, parseNum a = some q ∧ v = .num q) ∨ (a = "true" ∧ v = .bool true) ∨ (a = "false" ∧ v = .bool false) ∨
      scope.lookup a = some v ∨ globals.get? a = some v ∨ (a ∈ primitives ∧ v = .prim a) := by
  unfold resolve at h
  split at h
  · rename_i q hq; left; simp_all
  · split at h
    · right; left; simp_all
    · split at h
      · right; right; left; simp_all
      · split at h
        · rename_i v' hv; right; right; right; left; simp_all
        · split at h
          · rename_i v' hv; right; right; right; right; left; simp_all
          · split at h
            · rename_i hp; right; right; right; right; right; simp_all
            · simp at h

/-- Both, as one statement an implementation names. -/
theorem submitted_programs_closed :
    (∀ defs bound x, unbound defs bound x = none → ∀ a ∈ atoms x, Ok defs (bound ++ binders x) a) ∧
    (∀ scope globals a v, resolve scope globals a = some v →
      (∃ q, parseNum a = some q ∧ v = .num q) ∨ (a = "true" ∧ v = .bool true) ∨ (a = "false" ∧ v = .bool false) ∨
        scope.lookup a = some v ∨ globals.get? a = some v ∨ (a ∈ primitives ∧ v = .prim a)) :=
  ⟨names_checked, resolve_only⟩

end LeanFM.ReduceProofs
