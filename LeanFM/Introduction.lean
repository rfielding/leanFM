import LeanFM.ProjectView

/-! # introduction: where a client starts (clause selfhost.mcp.introduction; decision mcp-introduction)

One call answers what LeanFM is, the implication rule, the projects and their requirement files, the
named project's standings, and the next calls to make, written out. Read-only.

Requirements this module is held to:
* positive (AG): every project and file it names is one project_view lists; every standing is
  computed from the project's files.
* negative (never): a project or file it invents; a standing it did not compute. -/

namespace LeanFM.Introduction
open Lean LeanFM.ProjectView

def about : String :=
  "LeanFM checks requirements before code exists. A project's specification is a list of named requirements: " ++
  "protocols (interactions between roles, drawn as diagrams), CTL formulas over them, and deployments. " ++
  "Every requirement reduces to CTL and stands proved (by the model checker), tested (a run of an implementation " ++
  "meets it), sorry (nothing shows it yet) or failing. Runs, logs and charts of a running project are judged " ++
  "against the same requirements."

def rule : String :=
  "Features need strong implication, (leadsTo a b) or (stronglyImplies a b): the trigger a must be able to happen. " ++
  "Security guarantees need weak implication, (weaklyImplies a b): a trigger that never happens is fine. " ++
  "The difference is (possibly a), which CTL can say and LTL cannot."

def call (tool why : String) (args : List (String × Json)) : Json :=
  Json.mkObj [("tool", Json.str tool), ("arguments", Json.mkObj args), ("why", Json.str why)]

def answer (args : Json) : IO (Except String (String × Json)) := do
  let asked := (args.getObjValAs? String "project").toOption
  if !(← enabled.get) then
    let next := #[call "session_check" "check a protocol written as text" [("lean", "protocol P (A, B) { M from A to B; }")],
      call "explain_formula" "read a CTL formula in English" [("formula", "(leadsTo (on Call) (on Answer))")]]
    let body := Json.mkObj [("tool", "introduction"), ("about", Json.str about), ("rule", Json.str rule),
      ("projects", Json.arr #[]), ("next", Json.arr next)]
    return .ok (s!"{about}\n\n{rule}\n\nThis server does not serve project files; send protocols as lean text.", body)
  let ps ← projects
  let name := asked.getD "LeanFM"
  let some chosen := ps.find? (·.name == name)
    | return .error s!"project must be one of {", ".intercalate (ps.toList.map (·.name))}"
  let mut projJson : Array Json := #[]
  let mut chosenFiles : Array String := #[]
  for p in ps do
    let (protocols, _) ← protocolFiles p
    let specs := specProtocols p protocols
    let (files, _) ← readMapFiles p specs
    let withMaps := files.filter (!·.reqMap.isEmpty) |>.map (·.path)
    if p.name == chosen.name then chosenFiles := withMaps
    projJson := projJson.push (Json.mkObj [("name", Json.str p.name), ("requirementFiles", Json.arr (withMaps.map Json.str))])
  let (protocols, _) ← protocolFiles chosen
  let (reqs, _) ← listSummaries chosen protocols
  let standing := reqs.getObjValD "standing"
  let n (k : String) : Nat := (standing.getObjValAs? Nat k).toOption.getD 0
  let explore := chosenFiles.toList.take 8 |>.map fun f =>
    call "session_explore" s!"the requirements list of {f}: its protocols, interaction diagrams, CTL and evidence"
      [("project", Json.str chosen.name), ("file", Json.str f)]
  let next := explore.toArray ++ #[
    call "project_view" "the project's stages: chat, book, requirements, code" [("project", Json.str chosen.name), ("stage", "requirements")],
    call "reduce_run" "numbers and charts from a run, with a small sandboxed Lisp" [("program", "(pie \"events\" \"events\" (countBy label (events)))"), ("events", Json.arr #[])],
    call "server_logs" "the logs this server and the projects write" []]
  let body := Json.mkObj [("tool", "introduction"), ("about", Json.str about), ("rule", Json.str rule),
    ("project", Json.str chosen.name), ("projects", Json.arr projJson), ("standing", standing),
    ("book", "leanfm://project/book/main.pdf"), ("next", Json.arr next)]
  let fileLines := "\n".intercalate (chosenFiles.toList.map fun f => s!"  - {f}")
  let text := s!"{about}\n\n{rule}\n\nProjects: {", ".intercalate (ps.toList.map (·.name))}.\n" ++
    s!"{chosen.name}: {n "proved"} proved, {n "tested"} tested, {n "sorry"} sorry, {n "failing"} failing.\n" ++
    s!"Its requirement files:\n{fileLines}\n\nStart with session_explore on one of them (project {chosen.name}, file as above): " ++
    "the tree is the requirements list, each row with its standing, its interaction diagram and its CTL."
  return .ok (text, body)

end LeanFM.Introduction
