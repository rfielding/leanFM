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

end LeanFM
