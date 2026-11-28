import LeanFM.Deps

/-! Writes ./setup.sh and README.md's install table from LeanFM/Deps.lean (clause selfhost.setup).
Usage: lake env lean --run SetupScript.lean [--check]; --check writes nothing and fails when either
is not what the list generates. -/

def begin_ := "<!-- deps: generated from LeanFM/Deps.lean by SetupScript.lean -->\n"
def end_ := "<!-- deps: end -->\n"

def readme (old : String) : Option String :=
  match old.splitOn begin_ with
  | [a, rest] => match rest.splitOn end_ with
    | [_, b] => some (a ++ begin_ ++ LeanFM.Deps.table ++ end_ ++ b)
    | _ => none
  | _ => none

def main (args : List String) : IO UInt32 := do
  let check := args.contains "--check"
  let old ← IO.FS.readFile "README.md"
  let some new := readme old | IO.eprintln "README.md has no deps markers"; return 1
  let oldScript ← (do IO.FS.readFile "setup.sh") <|> pure ""
  if check then
    let mut ok := true
    if oldScript != LeanFM.Deps.script then IO.eprintln "setup.sh is not what LeanFM/Deps.lean generates: run make setup-script"; ok := false
    if old != new then IO.eprintln "README.md's install table is not what LeanFM/Deps.lean generates: run make setup-script"; ok := false
    if ok then IO.println "ok: setup.sh and README.md's install table match LeanFM/Deps.lean"
    return if ok then 0 else 1
  IO.FS.writeFile "setup.sh" LeanFM.Deps.script
  let rwx : IO.AccessRight := { read := true, write := true, execution := true }
  let rx : IO.AccessRight := { read := true, execution := true }
  IO.setAccessRights "setup.sh" { user := rwx, group := rx, other := rx }
  IO.FS.writeFile "README.md" new
  IO.println "wrote setup.sh and README.md's install table"
  return 0
