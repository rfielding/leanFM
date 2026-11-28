import Lean
import LeanFM.ProjectView

/-! Checks every theorem a LeanFM implementation names with `proof "Name"` (clause
selfhost.requirements.proofs): imports LeanFM.Proofs, and for each name asks the kernel's environment
whether the theorem exists and which axioms it rests on, writing proofs.json beside the implementation
file. A theorem resting on sorryAx is not free of sorry. For every function a pure entry names, it
walks what the function can reach (purityWalk) and writes the problems and declared exceptions under
`pure Name`. The server reads proofs.json; it never checks a theorem itself.
Usage: lake env lean --run ProofCheck.lean (make selfhost-check runs it). -/

open Lean

/-- Definitions the purity walk does not follow, each with why it is safe; every one reached is named
in the answer. -/
def exceptions : List (Name × String) :=
  [(`LeanFM.Logic.Dag.addUnsafe, "LeanFM.Logic.Dag.addUnsafe: a cache keyed by pointer address in front of Dag.add, whose own definition (addRef) builds the same DAG; it reads no file, clock or network and changes only how much work is repeated")]

def mentionsIO (e : Expr) : Bool :=
  e.getUsedConstants.any fun k => k == ``IO || k == ``EIO || k == ``BaseIO || k == ``IO.RealWorld

/-- Every constant the `roots` can reach, through each definition's value, its implemented_by target and the
_unsafe_rec code of a partial definition, followed through LeanFM's modules: how many LeanFM constants,
the problems, and the exceptions reached (clause selfhost.requirements.proofs). -/
def purityWalk (env : Environment) (roots : List Name) : Nat × List String × List String := Id.run do
  let mut seen : NameSet := {}
  let mut todo := roots
  let mut problems : List String := []
  let mut excepted : List String := []
  let mut n := 0
  while !todo.isEmpty do
    let c := todo.head!
    todo := todo.tail!
    if seen.contains c then continue
    seen := seen.insert c
    if let some (_, why) := exceptions.find? (·.1 == c) then excepted := excepted ++ [why]; continue
    let some ci := env.find? c | continue
    let inLeanFM := (env.getModuleIdxFor? c).any fun i => (env.header.moduleNames[i.toNat]!).toString.startsWith "LeanFM"
    if mentionsIO ci.type then problems := problems ++ [s!"{c} has IO in its type"]
    if ci.isUnsafe && !(c.toString.endsWith "_unsafe_rec") then problems := problems ++ [s!"{c} is unsafe"]
    unless inLeanFM do continue
    n := n + 1
    if isExtern env c then problems := problems ++ [s!"{c} is extern"]
    if let some i := Compiler.getImplementedBy? env c then
      if !((env.getModuleIdxFor? i).any fun k => (env.header.moduleNames[k.toNat]!).toString.startsWith "LeanFM") then
        problems := problems ++ [s!"{c} is implemented by {i}, outside LeanFM"]
      todo := i :: todo
    let ur := c.str "_unsafe_rec"
    if env.contains ur then todo := ur :: todo
    if let some v := ci.value? (allowOpaque := true) then todo := v.getUsedConstants.toList ++ todo
  return (n, problems, excepted)

/-- The walk catches a way out: configureFromEnv reads the environment; Reduce.eval's partial code is
followed and clean; Dag.add reaches only its declared exception. -/
def selfTest (env : Environment) : IO UInt32 := do
  let (_, bad, _) := purityWalk env [`LeanFM.Reduce.configureFromEnv]
  let (n, good, _) := purityWalk env [`LeanFM.Reduce.eval]
  let (_, addProblems, addEx) := purityWalk env [`LeanFM.Logic.Dag.ofFormula]
  if bad.isEmpty then IO.eprintln "self-test: configureFromEnv's IO was not found"; return 1
  if !good.isEmpty || n < 50 then IO.eprintln s!"self-test: Reduce.eval: {n} reached, problems {good}"; return 1
  if !addProblems.isEmpty || addEx.isEmpty then IO.eprintln s!"self-test: Dag.ofFormula: {addProblems} {addEx}"; return 1
  IO.println s!"ok: ProofCheck self-test: IO found in configureFromEnv; Reduce.eval's {n} definitions clean; Dag.add's exception declared"
  return 0

def main (args : List String) : IO UInt32 := do
  let ps ← LeanFM.ProjectView.projects
  let some p := ps.find? (·.isLeanFM) | IO.eprintln "no LeanFM project"; return 1
  let (protocols, _) ← LeanFM.ProjectView.protocolFiles p
  let (files, _) ← LeanFM.ProjectView.readMapFiles p (LeanFM.ProjectView.specProtocols p protocols)
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `LeanFM.Proofs }, { module := `LeanFM.Logic }] {} 0
  if args.contains "--self-test" then return ← selfTest env
  let mut failed := false
  for mf in files do
    let names : List String := mf.impls.flatMap fun d => d.entries.filterMap fun (_, ev) =>
      match ev with | .proof n => some n | _ => none
    let pures : List String := mf.impls.flatMap fun d => d.entries.filterMap fun (_, ev) =>
      match ev with | .purity n => some n | _ => none
    if names.isEmpty && pures.isEmpty then continue
    let mut out : List (String × Json) := []
    for n in pures.eraseDups do
      let roots := (n.splitOn " ").filter (· ≠ "") |>.map String.toName
      if let some c := roots.find? (!env.contains ·) then
        out := out ++ [(s!"pure {n}", Json.mkObj [("exists", false), ("reached", (0 : Nat)), ("problems", Json.arr #[]), ("exceptions", Json.arr #[])])]
        IO.eprintln s!"pure {n}: no such function {c}"; failed := true
        continue
      let (reached, problems, excepted) := purityWalk env roots
      if !problems.isEmpty then IO.eprintln s!"pure {n}: {problems}"; failed := true
      out := out ++ [(s!"pure {n}", Json.mkObj [("exists", true), ("reached", reached),
        ("problems", Json.arr (problems.map Json.str).toArray), ("exceptions", Json.arr (excepted.eraseDups.map Json.str).toArray)])]
      IO.println s!"ok: pure {n}: {reached} LeanFM definitions reached; problems: {problems.length}; exceptions: {excepted.eraseDups.length}"
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
