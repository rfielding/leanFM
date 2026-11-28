import Lean
import LeanFM.ProjectView

/-! Checks every theorem a LeanFM implementation names with `proof "Name"` (clause
selfhost.requirements.proofs): imports LeanFM.Proofs, and for each name asks the kernel's environment
whether the theorem exists and which axioms it rests on, writing proofs.json beside the implementation
file. A theorem resting on sorryAx is not free of sorry. The server reads proofs.json; it never checks
a theorem itself. Usage: lake env lean --run ProofCheck.lean (make selfhost-check runs it). -/

open Lean

def main : IO UInt32 := do
  let ps ← LeanFM.ProjectView.projects
  let some p := ps.find? (·.isLeanFM) | IO.eprintln "no LeanFM project"; return 1
  let (protocols, _) ← LeanFM.ProjectView.protocolFiles p
  let (files, _) ← LeanFM.ProjectView.readMapFiles p (LeanFM.ProjectView.specProtocols p protocols)
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `LeanFM.Proofs }] {} 0
  let mut failed := false
  for mf in files do
    let names : List String := mf.impls.flatMap fun d => d.entries.filterMap fun (_, ev) =>
      match ev with | .proof n => some n | _ => none
    if names.isEmpty then continue
    let mut out : List (String × Json) := []
    for n in names.eraseDups do
      let c := n.toName
      if !env.contains c then
        out := out ++ [(n, Json.mkObj [("exists", false), ("axioms", Json.arr #[]), ("sorryFree", false)])]
        IO.eprintln s!"proof {n}: no such theorem"; failed := true
        continue
      let (axs, _) ← (collectAxioms c : CoreM (Array Name)).toIO { fileName := "ProofCheck", fileMap := default } { env }
      let free := !axs.contains ``sorryAx
      if !free then IO.eprintln s!"proof {n} rests on sorry"; failed := true
      out := out ++ [(n, Json.mkObj [("exists", true), ("axioms", Json.arr (axs.map (Json.str ·.toString))), ("sorryFree", Json.bool free)])]
      IO.println s!"ok: proof {n}: free of sorry: {free}; axioms: {axs.toList}"
    let dir := "/".intercalate ((mf.path.splitOn "/").dropLast)
    let path := if dir.isEmpty then "proofs.json" else dir ++ "/proofs.json"
    IO.FS.writeFile path ((Json.mkObj out).pretty ++ "\n")
    IO.println s!"wrote {path}"
  return if failed then 1 else 0
