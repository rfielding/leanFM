import LeanFM.Artifacts
import Specification.Requirements

open LeanFM

def stateMachineMermaid (task : TaskRequirement) : String :=
  joinWithNewline <| ["stateDiagram-v2", "    [*] --> " ++ task.initialState] ++
    task.transitions.map (fun tr =>
      "    " ++ tr.src ++ " --> " ++ tr.dst ++ ": " ++ tr.message) ++
    task.states.filterMap (fun state =>
      if state.terminal then some ("    " ++ state.id ++ " --> [*]") else none)

def interactionMermaid (spec : RequirementSpec) (task : TaskRequirement) : String :=
  joinWithNewline <| ["sequenceDiagram"] ++
    task.actors.map (fun actor => "    participant " ++ actor) ++
    task.transitions.filterMap (fun tr =>
      match spec.messages.find? (fun message => message.name == tr.message) with
      | none => none
      | some message => some ("    " ++ message.src ++ "->>" ++ message.dst ++ ": " ++ message.name))

def diagramSection (title body : String) : String :=
  "## " ++ title ++ "\n\n```mermaid\n" ++ body ++ "\n```\n\n"

def main : IO Unit := do
  let spec := LeanFMProject.Requirements.spec
  IO.FS.createDirAll "generated/review"
  let interactions := "# Generated interaction diagrams\n\n" ++
    String.join (spec.tasks.map fun task => diagramSection task.id (interactionMermaid spec task))
  let states := "# Generated residual state machines\n\n" ++
    String.join (spec.tasks.map fun task => diagramSection task.id (stateMachineMermaid task))
  IO.FS.writeFile "generated/review/interaction-diagrams.md" interactions
  IO.FS.writeFile "generated/review/state-machines.md" states
  IO.println s!"ok: rendered {spec.tasks.length} interaction diagrams and state machines from RequirementSpec"
