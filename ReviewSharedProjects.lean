import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.Implementation
import LeanFM.ChatUI.Server

open LeanFM

def main : IO Unit := do
  let proposed := LeanFM.LLMGenerated.SharedProjects.spec
  let errors := LeanFM.LLMGenerated.SharedProjects.errors ++
    LeanFM.LLMGenerated.Implementation.sharedProjectsProposalErrors
  unless errors.isEmpty do throw (IO.userError (joinWithNewline errors))
  let root := "reports/shared-projects"
  IO.FS.createDirAll root
  let fence := String.ofList (List.replicate 3 (Char.ofNat 96))
  let tasks := proposed.tasks.filter fun task =>
    ["manage_projects", "authenticate_user", "configure_provider", "argue_requirements"].contains task.id
  let mut review := "# Shared-project requirements review\n\n" ++
    "Status: generated requirements review. Exact stakeholder acceptance is recorded separately in acceptance.json; this generator accepts neither gate.\n\n" ++
    "Prompt: remove ./data, keep projects directly in ./projects, remove user ownership, and use login only to protect API keys.\n\n" ++
    "Positive invariant: project identity and its complete shared directory are independent of credential accounts; model requests use only their initiating caller's unlocked key.\n\n" ++
    "Confirmed access policy: projects open without login; login is required for LLM calls and key management. Confirmation of that policy does not accept the complete revised specification or implementation mapping.\n\n" ++
    "## Observable requirements\n\n"
  for property in LeanFM.LLMGenerated.SharedProjects.properties do
    review := review ++ "- " ++ property.name ++ " [" ++ propertyModeName property.mode ++ "]: " ++ property.expression ++ "\n"
  for constraint in LeanFM.LLMGenerated.SharedProjects.constraints do
    review := review ++ "- " ++ constraint.id ++ ": " ++ constraint.predicate ++ "\n"
  review := review ++ "\n## Generated task views\n\n"
  for task in tasks do
    let interaction := LeanFM.ChatUI.Requirements.interactionMermaid task proposed
    let states := LeanFM.ChatUI.Requirements.stateMachineMermaid task
    IO.FS.writeFile (root ++ "/" ++ task.id ++ ".interaction.mmd") (interaction ++ "\n")
    IO.FS.writeFile (root ++ "/" ++ task.id ++ ".state.mmd") (states ++ "\n")
    review := review ++ "### " ++ task.title ++ "\n\n" ++ fence ++ "mermaid\n" ++ interaction ++
      "\n" ++ fence ++ "\n\n" ++ fence ++ "mermaid\n" ++ states ++ "\n" ++ fence ++ "\n\n"
  review := review ++ "## Output provenance\n\n"
  for output in proposed.desiredOutputs do
    review := review ++ "- " ++ output.id ++ "\n  - Prompt: " ++ output.prompt ++
      "\n  - Question: " ++ output.question ++ "\n  - Source: " ++ output.eventSource ++
      "\n  - Reducer: " ++ output.reducer ++ "\n  - Unit and boundary: " ++ output.unit ++ "\n"
  IO.FS.writeFile (root ++ "/requirements-review.md") review
  IO.FS.writeFile (root ++ "/tasks.json")
    (LeanFM.ChatUI.Server.tasksJson "LeanFM/LLMGenerated/SharedProjects.lean (proposal)"
      proposed LeanFM.LLMGenerated.SharedProjects.constraints ++ "\n")
  let mut implementation := "# Shared-project implementation mapping review\n\n" ++
    "Status: separate implementation review. Exact stakeholder acceptance is recorded in acceptance.json; this document accepts neither gate.\n\n"
  for decision in LeanFM.LLMGenerated.Implementation.sharedProjectsProposal do
    implementation := implementation ++ "## " ++ decision.id ++ "\n\n" ++ decision.decision ++
      "\n\nRequirement references:\n" ++ joinWithNewline (decision.requirementRefs.map ("- " ++ ·)) ++
      "\n\nFiles:\n" ++ joinWithNewline (decision.files.map ("- " ++ ·)) ++
      "\n\nRequired conformance evidence:\n" ++ joinWithNewline (decision.conformanceTests.map ("- " ++ ·)) ++ "\n\n"
  IO.FS.writeFile (root ++ "/implementation-review.md") implementation
  IO.FS.writeFile (root ++ "/validation.txt")
    "ok: shared-project RequirementSpec is structurally valid\nok: implementation references resolve to the requirements\ngate status: see acceptance.json; structural validation accepts neither gate\nruntime implementation and reset evidence are recorded separately\n"
  IO.println "ok: shared-project requirements, generated views and separate implementation mapping validated; see acceptance.json for gate status"
