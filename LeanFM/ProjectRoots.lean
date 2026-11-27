import Lean.Data.Json

/-! Projects that live outside the LeanFM checkout (clause selfhost.project.external, decision
project-external).

`LEANFM_PROJECTS` lists project roots as absolute paths separated by colons. It is read once at
startup; a root that cannot be served stops the server, naming the variable and the root, so a
project is never served in part. The server only reads these roots: nothing is written to them and
nothing about them is kept elsewhere, so the list is rebuilt from the variable on every start. -/

namespace LeanFM.ProjectRoots
open Lean

def envName : String := "LEANFM_PROJECTS"

/-- A project root accepted at startup. -/
structure Root where
  name : String
  /-- the absolute path as listed -/
  root : System.FilePath
  /-- the path with symlinks resolved; every read must stay below it -/
  real : System.FilePath
  manifest : Json

/-- What startup learns about one listed root, before deciding. -/
structure Facts where
  given : String
  isDir : Bool := false
  hasManifest : Bool := false
  real : String := ""
  name : String := ""

/-- A name usable as a project name and in a log name: letters, digits, _ and -. -/
def safeName (n : String) : Bool :=
  !n.isEmpty && n.length ≤ 64 && n.toList.all fun c => c.isAlphanum || c == '_' || c == '-'

def below (path dir : String) : Bool := path == dir || path.startsWith (dir ++ "/")

/-- The first problem with the listed roots, given the checkout's real path and the names already
taken (LeanFM and the projects/ children), or none. Pure, so it is tested without a disk. -/
def validate (checkout : String) (taken : List String) (fs : List Facts) : Option String := Id.run do
  let mut names := taken
  let mut seen : List Facts := []
  for f in fs do
    let bad := fun (why : String) => some s!"{envName}: the project root {f.given} {why}"
    if !f.given.startsWith "/" then return bad "is not an absolute path"
    if !f.isDir then return bad "is not an existing directory"
    if !f.hasManifest then return bad "has no manifest.json"
    if below f.real checkout then
      return bad s!"is inside the LeanFM checkout ({checkout}); put it under projects/ instead, or move it out"
    if let some o := seen.find? (fun o => below f.real o.real || below o.real f.real) then
      return bad s!"overlaps the project root {o.given}; list each project once, by its own root"
    if !safeName f.name then
      return bad s!"is named {f.name}, which is not only letters, digits, _ and -; set display_name in its manifest.json"
    if names.contains f.name then
      return bad s!"is named {f.name}, which another project already has; set a different display_name in its manifest.json"
    names := names ++ [f.name]
    seen := seen ++ [f]
  return none

initialize roots : IO.Ref (Array Root) ← IO.mkRef #[]

def manifestOf (dir : System.FilePath) : IO Json := do
  match Json.parse (← IO.FS.readFile (dir / "manifest.json")) with
  | .ok j => pure j
  | .error _ => pure (Json.mkObj [])

def nameOf (dir : System.FilePath) (manifest : Json) : String :=
  (manifest.getObjValAs? String "display_name").toOption.getD (dir.fileName.getD dir.toString)

/-- The names LeanFM itself and its projects/ children take. -/
def takenNames : IO (List String) := do
  let dir : System.FilePath := "projects"
  let mut out := ["LeanFM"]
  if !(← dir.isDir) then return out
  for e in ← dir.readDir do
    let root := dir / e.fileName
    if (← root.isDir) && (← (root / "manifest.json").pathExists) then
      out := out ++ [nameOf e.fileName (← manifestOf root)]
  return out

/-- Read LEANFM_PROJECTS once at startup (selfhost.env.startup); throws on the first bad root. -/
def configureFromEnv : IO Unit := do
  let some raw ← IO.getEnv envName | return
  let given : List String := ((raw.splitOn ":").map fun (x : String) => x.trimAscii.toString).filter fun (x : String) => !x.isEmpty
  let checkout := (← IO.FS.realPath ".").toString
  let mut facts : List Facts := []
  let mut manifests : List Json := []
  for g in given do
    let p : System.FilePath := g
    let isDir ← p.isDir
    let hasManifest ← if isDir then (p / "manifest.json").pathExists else pure false
    let real ← if isDir then (·.toString) <$> IO.FS.realPath p else pure ""
    let manifest ← if hasManifest then manifestOf p else pure (Json.mkObj [])
    facts := facts ++ [{ given := g, isDir, hasManifest, real, name := nameOf p manifest }]
    manifests := manifests ++ [manifest]
  if let some problem := validate checkout (← takenNames) facts then throw (IO.userError problem)
  roots.set ((facts.zip manifests).map fun (f, m) =>
    { name := f.name, root := f.given, real := f.real, manifest := m }).toArray

end LeanFM.ProjectRoots
