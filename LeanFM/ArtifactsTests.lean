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

def costedServer : ActorCostContract :=
  { actor := "A", hardwarePool := "general", currency := "USD-cent"
  , hardwareCostPerProvisionedHour := 10
  , serviceCostPerAvailableHour := 2
  , capacityWorkPerHour := 100 }

example :
    (optimalSupply? costedServer { numerator := 9, denominator := 10 } 250 8).map
      (fun plan => (plan.replicas, plan.averageLoadNumerator,
                    plan.averageLoadDenominator, plan.effectiveCapacityNumerator,
                    plan.hourlyCostNumerator, plan.denominator)) =
      some (3, 250, 3, 2700, 354, 10) := by
  native_decide

example : optimalSupply? costedServer { numerator := 9, denominator := 10 } 1000 8 = none := by
  native_decide

def grammarLeaf : GrammarExpr :=
  .event { task := "t", src := "A", dst := "B", message := "Done" }

example : validateThresholdJoins (GrammarExpr.mOfN 2 [grammarLeaf, grammarLeaf, grammarLeaf]) = [] := by
  native_decide

example : !(validateThresholdJoins (GrammarExpr.mOfN 3 [grammarLeaf, grammarLeaf])).isEmpty := by
  native_decide

end LeanFM
