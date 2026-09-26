import LeanFM.LLMGenerated.Requirements

namespace LeanFM

open LeanFM.LLMGenerated.Requirements

example : workerRequirement.actorInstances.length = 24 := by native_decide
example : workerRequirement.actorInstances.contains "client-20" := by native_decide
example : workerRequirement.actorInstances.contains "gateway-2" := by native_decide
example : workerRequirement.actorInstances.contains "worker-2" := by native_decide

end LeanFM
