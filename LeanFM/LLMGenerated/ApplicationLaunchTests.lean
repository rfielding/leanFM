import LeanFM.LLMGenerated.ApplicationLaunchImplementation

open LeanFM
open LeanFM.LLMGenerated.ApplicationLaunch

-- Refs: the accepted launcher component; checked independently from the host example.
def main : IO Unit := do
  let errors := validateRequirementSpec requirements
    ++ validateRequirementProtoFile requirements protoSource
    ++ validateImplementationSpec requirements LeanFM.LLMGenerated.ApplicationLaunchImplementation.implementation
  let valid := requirementReferenceIds requirements
  let decisions := LeanFM.LLMGenerated.ApplicationLaunchImplementation.decisions
  let unknown := decisions.filter fun decision => !valid.contains decision.requirementId
  unless errors.isEmpty && unknown.isEmpty do
    throw (IO.userError (joinWithNewline (errors ++ unknown.map (fun item => "Unknown launcher decision: " ++ item.requirementId))))
  IO.println "ok: accepted application launch requirements, protobuf and implementation traceability"
