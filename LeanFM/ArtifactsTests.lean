import LeanFM.Artifacts

namespace LeanFM

def validResource : ActorResourceContract :=
  { actor := "A"
  , inboundCapacity := 1
  , outboundCapacity := 2
  , maxInFlight := 3
  , memoryBudgetBytes := 4096
  }

example : validateActorResources ["A"] [validResource] = [] := by
  native_decide

example :
    validateActorResources ["A"] [] =
      ["actor has no finite resource contract: A"] := by
  native_decide

example :
    !(validateActorResources ["A"] [{ validResource with memoryBudgetBytes := 0 }]).isEmpty := by
  native_decide

example :
    !(validateActorResources ["A"] [validResource, validResource]).isEmpty := by
  native_decide

end LeanFM
