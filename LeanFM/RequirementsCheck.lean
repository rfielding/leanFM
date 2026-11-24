import LeanFM.ProjectView

/-! The requirements gate (clauses selfhost.requirements.map, selfhost.implementations.map):
every entry of every requirements map and implementation block of the LeanFM project (or the
project named by the first argument) is converted to CTL and decided, like `sorry` in Lean.
A failing entry (disproved, a broken refinement, a log that does not conform, an error) fails the
check; each sorry is a warning, and with --strict a failure too.
Usage: lake env lean --run LeanFM/RequirementsCheck.lean [Project] [--strict] [--files f ...] -/

open Lean LeanFM.ProjectView

def main (args : List String) : IO UInt32 := do
  let strict := args.contains "--strict"
  -- --files a b ...: check those listed protocol files instead of the project's specification files
  let (args, given) := match args.span (· != "--files") with
    | (before, _ :: fs) => (before, some fs)
    | (before, []) => (before, none)
  let name := (args.filter (· != "--strict")).headD "LeanFM"
  let ps ← projects
  let some p := ps.find? (·.name == name) | IO.eprintln s!"no project {name}"; return 2
  let (listed, _) ← protocolFiles p
  let protos := match given with
    | some fs => listed.filter fs.contains
    | none => specProtocols p listed
  if let some fs := given then
    for f in fs do
      unless protos.contains f do IO.eprintln s!"{f} is not one of the {name} protocol files"; return 2
  let (files, errs) ← readMapFiles p protos
  let rows := requirementRows p files errs (withClauses := given.isNone) ++ implementationRows files
  let mut failing := 0
  let mut sorries := 0
  for r in rows do
    let c ← checkRow p protos files r
    let g (k : String) := (c.getObjValAs? String k).toOption.getD ""
    let where_ := if g "list" == "implementations" then s!"implementation {g "impl"} ({g "file"})" else g "file"
    if c.getObjValD "failing" == Json.bool true then
      failing := failing + 1
      IO.eprintln s!"error: {where_}: \"{g "id"}\": {g "verdict"}: {g "reading"}"
    else if c.getObjValD "sorry" == Json.bool true then
      sorries := sorries + 1
      if strict then IO.eprintln s!"error (strict): {where_}: \"{g "id"}\" uses sorry"
  IO.println s!"{name}: {rows.size} entries in {files.size} files; {failing} failing; {sorries} use sorry{if strict then " (strict: each is an error)" else " (warnings)"}"
  return if failing > 0 || (strict && sorries > 0) then 1 else 0
