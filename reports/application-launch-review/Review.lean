import LeanFM.LLMGenerated.ApplicationLaunch
import LeanFM.ChatUI.Server

def main : IO Unit := do
  let requirements := LeanFM.LLMGenerated.ApplicationLaunch.requirements
  let errors := LeanFM.validateRequirementSpec requirements ++ LeanFM.validateRequirementProtoFile requirements LeanFM.LLMGenerated.ApplicationLaunch.protoSource
  unless errors.isEmpty do
    throw (IO.userError (LeanFM.joinWithNewline errors))
  IO.println (LeanFM.ChatUI.Server.tasksJson "LeanFM/LLMGenerated/ApplicationLaunch.lean" requirements [])
