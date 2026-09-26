import LeanFM.StreamStats

namespace LeanFM

/-- One exact reducer result. Histogram bins are represented as separately named metrics. -/
structure MeasuredMetric where
  name : String
  numerator : Nat
  denominator : Nat
deriving DecidableEq, Repr

structure ScenarioCharacterization where
  scenario : String
  metrics : List MeasuredMetric
deriving DecidableEq, Repr

def natDistance (a b : Nat) : Nat :=
  if a <= b then b - a else a - b

/-- Relative error in permille, checked without floating-point rounding. -/
def metricWithinTolerance (tolerancePermille : Nat)
    (target candidate : MeasuredMetric) : Bool :=
  if target.name != candidate.name || target.denominator == 0 || candidate.denominator == 0 then false
  else if target.numerator == 0 then candidate.numerator == 0
  else
    let crossDistance := natDistance
      (candidate.numerator * target.denominator)
      (target.numerator * candidate.denominator)
    1000 * crossDistance <= tolerancePermille * target.numerator * candidate.denominator

def findMetric? (name : String) : List MeasuredMetric -> Option MeasuredMetric
  | [] => none
  | metric :: rest => if metric.name == name then some metric else findMetric? name rest

/-- Replay acceptance for a synthesized stream: every target reducer must match. -/
def characterizationMatches (tolerancePermille : Nat)
    (target candidate : ScenarioCharacterization) : Bool :=
  target.metrics.all fun expected =>
    match findMetric? expected.name candidate.metrics with
    | some actual => metricWithinTolerance tolerancePermille expected actual
    | none => false

/-- Artifacts expected from every sufficiently identified event stream. -/
def outOfBoxArtifacts : List String :=
  [ "per-scenario interaction diagrams"
  , "per-scenario state machines"
  , "XY line metrics"
  , "pie-chart histograms"
  , "uptime and reliability"
  , "throughput"
  , "latency"
  ]

end LeanFM
