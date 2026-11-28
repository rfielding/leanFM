import LeanFM.LLMGenerated.SelfHosting
import LeanFM.ProjectRoots

/-! # Paths stay inside a project, proved (clause selfhost.requirements.proofs; hazard path.escape)

A requirement or a tool names a protocol file by a path the project lists; LeanFM.LLMGenerated
.SelfHosting.protocolPathOk is the first gate, and ProjectRoots.safeName the gate on a project's name.
These theorems hold for every input, where a test only tries some. -/

namespace LeanFM.PathProofs
open LeanFM.LLMGenerated.SelfHosting

theorem absolute_refused (f : String) (h : f.startsWith "/" = true) : protocolPathOk f = false := by
  simp [protocolPathOk, h]

theorem dotdot_refused (f : String) (h : (f.splitOn "/").contains ".." = true) : protocolPathOk f = false := by
  simp_all [protocolPathOk]

theorem backslash_refused (f : String) (h : f.contains '\\' = true) : protocolPathOk f = false := by
  simp [protocolPathOk, h]

theorem empty_part_refused (f : String) (h : (f.splitOn "/").contains "" = true) : protocolPathOk f = false := by
  simp_all [protocolPathOk]

/-- A name safeName accepts holds only letters, digits, _ and -: never / or ., so it cannot climb
out of the projects directory or name a hidden one. -/
theorem safe_name_no_separator (n : String) (h : LeanFM.ProjectRoots.safeName n = true) :
    '/' ∉ n.toList ∧ '.' ∉ n.toList := by
  simp only [LeanFM.ProjectRoots.safeName, Bool.and_eq_true, Bool.not_eq_true', List.all_eq_true] at h
  obtain ⟨_, hall⟩ := h
  constructor
  · intro hm; have := hall '/' hm; revert this; decide
  · intro hm; have := hall '.' hm; revert this; decide

/-- Every gate above, as one statement an implementation can name as evidence. -/
theorem paths_stay_inside :
    (∀ f, f.startsWith "/" = true → protocolPathOk f = false) ∧
    (∀ f, (f.splitOn "/").contains ".." = true → protocolPathOk f = false) ∧
    (∀ f, f.contains '\\' = true → protocolPathOk f = false) ∧
    (∀ f, (f.splitOn "/").contains "" = true → protocolPathOk f = false) ∧
    (∀ n, LeanFM.ProjectRoots.safeName n = true → '/' ∉ n.toList ∧ '.' ∉ n.toList) :=
  ⟨absolute_refused, dotdot_refused, backslash_refused, empty_part_refused, safe_name_no_separator⟩

end LeanFM.PathProofs
