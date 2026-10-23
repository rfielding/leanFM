import LeanFM.LLMGenerated.ResumableWork
import LeanFM.LLMGenerated.ResumableWorkImplementation
import LeanFM.ChatUI.Requirements

open LeanFM LeanFM.LLMGenerated.ResumableWork

def main : IO Unit := do
  let errors := validateRequirementSpec spec ++ LeanFM.LLMGenerated.ResumableWorkImplementation.errors
  unless errors.isEmpty do throw (IO.userError (joinWithNewline errors))
  IO.FS.writeFile "reports/resumable-work/work.interaction.mmd" (LeanFM.ChatUI.Requirements.interactionMermaid task spec)
  IO.FS.writeFile "reports/resumable-work/work.state.mmd" (LeanFM.ChatUI.Requirements.stateMachineMermaid task)
  IO.println "ok: resumable work candidate requirements and generated views"
