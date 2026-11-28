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
def exceptions : List (String × String) :=
  [("LeanFM.Logic.Dag.addUnsafe", "LeanFM.Logic.Dag.addUnsafe: a cache keyed by pointer address in front of Dag.add, whose own definition (addRef) builds the same DAG; it reads no file, clock or network and changes only how much work is repeated"),
   ("_private.LeanFM.Session.Grammar.0.LeanFM.Session.Grammar.runImpl", "LeanFM.Session.Grammar.run: reads Lean's built-in token table and runs the protocol grammar's parsers with a placeholder for the environment; it parses, elaborates nothing, and writes nothing")]

/-- What reads the environment while parsing: a category parser, the parser context's environment, or
an environment extension. -/
def envReader (n : Name) : Bool :=
  n == ``Lean.Parser.ParserModuleContext.env || n == ``Lean.Parser.categoryParser || n == ``Lean.Parser.categoryParserFn ||
  n == ``Lean.Parser.categoryParserFnRef || (`Lean.Environment).isPrefixOf n || (`Lean.EnvExtension).isPrefixOf n ||
  (`Lean.PersistentEnvExtension).isPrefixOf n || (`Lean.ScopedEnvExtension).isPrefixOf n

/-- The parsers Session.Grammar.run is given (parseFile's file, and parseValue's frac, dur and timeExpr),
walked through LeanFM's modules and Lean's parser library: how many definitions, and each place one
reads the environment, which the placeholder run passes cannot answer (hazard parser.environment). -/
def grammarEnvReads (env : Environment) : Nat × List String := Id.run do
  let follow (c : Name) : Bool := (env.getModuleIdxFor? c).any fun i =>
    let m := (env.header.moduleNames[i.toNat]!).toString
    m.startsWith "LeanFM" || m.startsWith "Lean.Parser" || m.startsWith "Init"
  let mut seen : NameSet := {}
  let mut todo : List Name := [`LeanFM.Session.Grammar.file, `LeanFM.Session.Grammar.frac, `LeanFM.Session.Grammar.dur,
    `LeanFM.Session.Grammar.timeExpr]
  let mut hits : List String := []
  let mut n := 0
  while !todo.isEmpty do
    let c := todo.head!
    todo := todo.tail!
    if seen.contains c then continue
    seen := seen.insert c
    let some ci := env.find? c | continue
    unless follow c do continue
    n := n + 1
    if let some i := Compiler.getImplementedBy? env c then todo := i :: todo
    let ur := c.str "_unsafe_rec"
    if env.contains ur then todo := ur :: todo
    if let some v := ci.value? (allowOpaque := true) then
      for k in v.getUsedConstants do
        if envReader k then hits := hits ++ [s!"{c} uses {k}"]
      todo := v.getUsedConstants.toList ++ todo
  return (n, hits)

/-- Definitions the read-only walk does not follow, each with why it writes nothing. -/
def readonlyExceptions : List (String × String) :=
  [("LeanFM.ProjectView.runBounded", "LeanFM.ProjectView.runBounded: runs pdfinfo and pdftoppm with fixed arguments and no shell (its only callers), and pdftoppm, given no output file, writes the page image to standard output, which the server reads")]

/-- Calls that change the disk or start a process. -/
def writes : List Name := [``IO.FS.writeFile, ``IO.FS.writeBinFile, ``IO.FS.createDir, ``IO.FS.createDirAll,
  ``IO.FS.removeFile, ``IO.FS.removeDir, ``IO.FS.removeDirAll, ``IO.FS.rename, ``IO.setAccessRights,
  ``IO.Process.spawn, ``IO.Process.output, ``IO.Process.run, ``IO.FS.createTempFile, ``IO.FS.Handle.truncate]

def isOpen (n : Name) : Bool := n == ``IO.FS.Handle.mk || n == ``IO.FS.withFile

/-- A file opened in any mode but read, or an opening function passed around unapplied. -/
partial def opensForWriting : Expr → Bool
  | e@(.app ..) =>
    let f := e.getAppFn
    let args := e.getAppArgs
    let here := match f.constName? with
      | some n => isOpen n && !(args.size ≥ 2 && args[1]! == mkConst ``IO.FS.Mode.read)
      | none => opensForWriting f
    here || args.any opensForWriting
  | .const n _ => isOpen n
  | .lam _ t b _ | .forallE _ t b _ => opensForWriting t || opensForWriting b
  | .letE _ t v b _ => opensForWriting t || opensForWriting v || opensForWriting b
  | .mdata _ e | .proj _ _ e => opensForWriting e
  | _ => false

def mentionsIO (e : Expr) : Bool :=
  e.getUsedConstants.any fun k => k == ``IO || k == ``EIO || k == ``BaseIO || k == ``IO.RealWorld

/-- Every constant the `roots` can reach, through each definition's value, its implemented_by target and the
_unsafe_rec code of a partial definition, followed through LeanFM's modules: how many LeanFM constants,
the problems, and the exceptions reached (clause selfhost.requirements.proofs). -/
def purityWalk (env : Environment) (roots : List Name) (readonly : Bool := false) : Nat × List String × List String := Id.run do
  let (gn, gHits) := grammarEnvReads env
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
    if let some (_, why) := (exceptions ++ (if readonly then readonlyExceptions else [])).find? (·.1 == c.toString) then
      if c.toString.endsWith "Grammar.runImpl" then
        if gHits.isEmpty then excepted := excepted ++ [why ++ s!"; checked: none of the {gn} definitions its parsers can reach reads the environment"]
        else problems := problems ++ [s!"Session.Grammar.run's parsers can reach the environment: {gHits.take 3}"]
      else excepted := excepted ++ [why]
      continue
    if readonly && writes.contains c then problems := problems ++ [s!"reaches {c}"]; continue
    let some ci := env.find? c | continue
    let inLeanFM := (env.getModuleIdxFor? c).any fun i => (env.header.moduleNames[i.toNat]!).toString.startsWith "LeanFM"
    if !readonly && mentionsIO ci.type then problems := problems ++ [s!"{c} has IO in its type"]
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
    if let some v := ci.value? (allowOpaque := true) then
      if readonly && opensForWriting v then problems := problems ++ [s!"{c} opens a file other than to read it"]
      todo := v.getUsedConstants.toList ++ todo
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
  let (_, storeProblems, _) := purityWalk env [`LeanFM.ChatUI.Store.writeAtomic] (readonly := true)
  if storeProblems.isEmpty then IO.eprintln "self-test: the chat UI store's writes were not found"; return 1
  let (gn, gHits) := grammarEnvReads env
  if !gHits.isEmpty || gn < 100 then IO.eprintln s!"self-test: the grammar walk: {gn} definitions, {gHits.take 3}"; return 1
  if !envReader ``Lean.Parser.categoryParser then IO.eprintln "self-test: categoryParser is not an environment reader"; return 1
  IO.println s!"ok: ProofCheck self-test: IO found in configureFromEnv; Reduce.eval's {n} definitions clean; Dag.add's exception declared; the chat UI store's writes found"
  return 0

def main (args : List String) : IO UInt32 := do
  let ps ← LeanFM.ProjectView.projects
  let some p := ps.find? (·.isLeanFM) | IO.eprintln "no LeanFM project"; return 1
  let (protocols, _) ← LeanFM.ProjectView.protocolFiles p
  let (files, _) ← LeanFM.ProjectView.readMapFiles p (LeanFM.ProjectView.specProtocols p protocols)
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `LeanFM.Proofs }, { module := `LeanFM.Logic }, { module := `LeanFM.MCP }, { module := `LeanFM.ChatUI.Store }] {} 0
  if args.contains "--self-test" then return ← selfTest env
  let mut failed := false
  for mf in files do
    let names : List String := mf.impls.flatMap fun d => d.entries.filterMap fun (_, ev) =>
      match ev with | .proof n => some n | _ => none
    let pures : List (String × Bool) := mf.impls.flatMap fun d => d.entries.filterMap fun (_, ev) =>
      match ev with | .purity n => some (n, false) | .readonly n => some (n, true) | _ => none
    if names.isEmpty && pures.isEmpty then continue
    let mut out : List (String × Json) := []
    for (n, ro) in pures.eraseDups do
      let kind := if ro then "readonly" else "pure"
      let roots := (n.splitOn " ").filter (· ≠ "") |>.map String.toName
      if let some c := roots.find? (!env.contains ·) then
        out := out ++ [(s!"{kind} {n}", Json.mkObj [("exists", false), ("reached", (0 : Nat)), ("problems", Json.arr #[]), ("exceptions", Json.arr #[])])]
        IO.eprintln s!"{kind} {n}: no such function {c}"; failed := true
        continue
      let (reached, problems, excepted) := purityWalk env roots ro
      if !problems.isEmpty then IO.eprintln s!"{kind} {n}: {problems}"; failed := true
      out := out ++ [(s!"{kind} {n}", Json.mkObj [("exists", true), ("reached", reached),
        ("problems", Json.arr (problems.map Json.str).toArray), ("exceptions", Json.arr (excepted.eraseDups.map Json.str).toArray)])]
      IO.println s!"ok: {kind} {n}: {reached} LeanFM definitions reached; problems: {problems.length}; exceptions: {excepted.eraseDups.length}"
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
