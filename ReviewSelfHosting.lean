import LeanFM.LLMGenerated.Requirements

def main : IO Unit := do
  let errors := LeanFM.LLMGenerated.SelfHosting.errors
  if !errors.isEmpty then
    throw (IO.userError (LeanFM.joinWithNewline errors))
  IO.FS.writeFile "SELF_HOSTING_REVIEW.md" LeanFM.LLMGenerated.SelfHosting.report
  IO.println "ok: self-hosting product composition and review generated (structural validation only)"
