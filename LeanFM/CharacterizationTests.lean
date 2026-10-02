import LeanFM.Characterization

namespace LeanFM

def targetCharacterization : ScenarioCharacterization :=
  { scenario := "observed"
  , metrics :=
      [ { name := "latency.p50.ms", numerator := 100, denominator := 1 }
      , { name := "throughput.bytes_per_ms", numerator := 20, denominator := 1 }
      ] }

def similarCharacterization : ScenarioCharacterization :=
  { scenario := "generated"
  , metrics :=
      [ { name := "latency.p50.ms", numerator := 102, denominator := 1 }
      , { name := "throughput.bytes_per_ms", numerator := 199, denominator := 10 }
      ] }

example : characterizationMatches 25 targetCharacterization similarCharacterization := by
  native_decide

example : !characterizationMatches 10 targetCharacterization similarCharacterization := by
  native_decide

example : validateDerivedPropertyPlan baselineDerivedProperties = [] := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "finance.tax" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "finance.profit_loss" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "waste.rate" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "scalability.usl" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "memory.headroom" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "reliability.network_outage_impact" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "reliability.composed_uptime" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "reliability.failure_cascade" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "reliability.dos_criticality" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "infrastructure.cost" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "capacity.load_per_instance" := by
  native_decide

example : (baselineDerivedProperties.map (fun plan => plan.name)).contains "capacity.optimal_supply" := by
  native_decide

end LeanFM
