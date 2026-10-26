import LeanFM.LLMGenerated.ApplicationLaunchImplementation

def main : IO Unit := do
  let errors := LeanFM.validateImplementationSpec LeanFM.LLMGenerated.ApplicationLaunch.requirements LeanFM.LLMGenerated.ApplicationLaunchImplementation.implementation
  unless errors.isEmpty do
    throw (IO.userError (LeanFM.joinWithNewline errors))
  IO.println "ok: persistent launcher implementation mapping is traceable"
