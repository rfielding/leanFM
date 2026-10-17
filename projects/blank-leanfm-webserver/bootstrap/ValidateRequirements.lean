import LeanFM.Artifacts
import Specification.Requirements

def main : IO Unit := do
  let report := LeanFM.generatedRequirementValidationReport LeanFMProject.Requirements.all
  IO.print report
  if !report.startsWith "ok:" then
    throw <| IO.userError "candidate requirements failed LeanFM validation"
