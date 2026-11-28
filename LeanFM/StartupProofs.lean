import LeanFM.MCPHost
import LeanFM.CallLimits
import LeanFM.Reduce
import LeanFM.Env

/-! # Startup settings are checked, and secrets are never written, proved
(clauses selfhost.env.startup and selfhost.env.registry; selfhost.requirements.proofs)

A switch takes the default only when absent or empty, true only for 1 or true, false only for 0 or
false, and refuses every other value: no unrecognised value is taken silently as off. The ceiling and
the tick budget are whole numbers of at least 1. A secret's setting in MainEntered is the same
whatever its value, so its value cannot be in it. -/

namespace LeanFM.StartupProofs
open LeanFM

/-- What a switch accepts, read after trimming and lower case. -/
def switchReads (d : Bool) (t : String) (b : Bool) : Prop :=
  (t = "" ∧ b = d) ∨ ((t = "1" ∨ t = "true") ∧ b = true) ∨ ((t = "0" ∨ t = "false") ∧ b = false)

theorem switch_checked (name : String) (d : Bool) (r : String) (b : Bool)
    (h : MCPHost.parseSwitch name d (some r) = .ok b) :
    switchReads d r.trimAscii.toString.toLower b := by
  simp only [MCPHost.parseSwitch] at h
  unfold switchReads
  generalize r.trimAscii.toString.toLower = t at h ⊢
  split at h <;> simp_all

theorem switch_absent (name : String) (d : Bool) : MCPHost.parseSwitch name d none = .ok d := rfl

theorem ceiling_checked (r : Option String) (n : Nat) (h : CallLimits.parseCeiling r = .ok n) : 1 ≤ n := by
  unfold CallLimits.parseCeiling at h
  split at h
  · simp at h; subst h; decide
  · split at h
    · split at h <;> simp_all
    · simp at h

theorem ticks_checked (r : Option String) (n : Nat) (h : Reduce.parseTicks r = .ok n) : 1 ≤ n := by
  unfold Reduce.parseTicks at h
  split at h
  · simp at h; subst h; decide
  · split at h
    · split at h <;> simp_all
    · simp at h

/-- Every startup check this file proves, as one statement an implementation can name. -/
theorem startup_checked :
    (∀ name d r b, MCPHost.parseSwitch name d (some r) = .ok b → switchReads d r.trimAscii.toString.toLower b) ∧
    (∀ r n, CallLimits.parseCeiling r = .ok n → 1 ≤ n) ∧
    (∀ r n, Reduce.parseTicks r = .ok n → 1 ≤ n) :=
  ⟨switch_checked, ceiling_checked, ticks_checked⟩

/-- A secret's setting does not depend on its value: no value of it is written. -/
theorem secret_never_written (v : Env.Variable) (h : v.secret = true) (x y : String) :
    Env.entry v (some x) = Env.entry v (some y) := by
  simp [Env.entry, h]

end LeanFM.StartupProofs
