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

/-- The stable identity used to keep concurrent/repeated scenarios separate. -/
structure SessionScenario where
  session : String
  scenario : String
deriving DecidableEq, Repr

/-- A property must be planned before interviewing so its observations are not
    discovered only after the event schema has already been fixed. -/
structure DerivedPropertyPlan where
  name : String
  requiredFields : List String
  reducer : String
  unit : String
  visual : String
  boundary : String
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

/-- Baseline catalog. A domain may extend it, but must explicitly retain,
    replace, or mark each applicable entry indeterminate. Financial names are
    deliberately separate so that contribution margin is never mislabeled as
    profit after tax. -/
def baselineDerivedProperties : List DerivedPropertyPlan :=
  [ { name := "interaction.diagram", requiredFields := ["session", "scenario", "id", "prior", "src", "dst", "timeAt", "message"], reducer := "lifelines ordered by the transitive closure of prior, with timeAt as measurement", unit := "events", visual := "interaction diagram", boundary := "one session-scenario" }
  , { name := "state_machine", requiredFields := ["session", "scenario", "state", "message"], reducer := "observed states and message-labeled transitions", unit := "states", visual := "state machine", boundary := "one session-scenario" }
  , { name := "latency.distribution", requiredFields := ["session", "scenario", "id", "prior", "timeAt"], reducer := "end.timeAt - start.timeAt using the named prior start event", unit := "declared clock unit", visual := "line and histogram", boundary := "task and scenario" }
  , { name := "throughput.client", requiredFields := ["work", "observationTime", "client"], reducer := "sum(work) / sum(observationTime)", unit := "work/time", visual := "line", boundary := "client population and window" }
  , { name := "throughput.server", requiredFields := ["work", "start.timeAt", "end.timeAt"], reducer := "sum(work) / (max(end) - min(start))", unit := "work/time", visual := "line", boundary := "server population and window" }
  , { name := "outcome.distribution", requiredFields := ["terminal", "outcome"], reducer := "count by terminal outcome", unit := "events and ratio", visual := "line and pie", boundary := "task and scenario" }
  , { name := "queue.pressure", requiredFields := ["actor", "timeAt", "queueLength"], reducer := "time-weighted queue length", unit := "messages", visual := "line and histogram", boundary := "actor instance and window" }
  , { name := "queue.latency_relation", requiredFields := ["actor", "queueLength", "start.id", "end.prior", "timeAt"], reducer := "pair queue length at admission with end.timeAt - start.timeAt; group or scatter by queue length", unit := "declared clock unit by queued messages", visual := "XY line and scatter", boundary := "actor, task, load level, and observation window" }
  , { name := "concurrency", requiredFields := ["session", "task", "id", "prior", "start.timeAt", "end.timeAt"], reducer := "count overlapping intervals and incomparable events in the prior partial order", unit := "in-flight tasks", visual := "line", boundary := "actor and window" }
  , { name := "scalability.usl", requiredFields := ["clientPopulation", "completedWork", "observationTime", "loadRun"], reducer := "derive throughput by population and fit X(N)=gamma*N/(1+alpha*(N-1)+beta*N*(N-1)) with fit error", unit := "work/time by clients", visual := "observed and fitted XY lines", boundary := "comparable load runs after declared warm-up and censoring" }
  , { name := "memory.headroom", requiredFields := ["actor", "residentBytes", "memoryBudgetBytes", "timeAt", "outcome"], reducer := "memoryBudgetBytes - max(residentBytes), utilization over time, and fatal exhaustion count", unit := "bytes and ratio", visual := "line with fatal threshold", boundary := "actor instance and observation window" }
  , { name := "reliability.uptime", requiredFields := ["actor", "Unavailable.timeAt", "Recovered.timeAt", "observationTime"], reducer := "1 - sum(outageTime) / (replicas * observationTime)", unit := "ratio", visual := "line", boundary := "actor population and window" }
  , { name := "reliability.mttr", requiredFields := ["Unavailable.id", "Recovered.prior", "timeAt"], reducer := "sum(repairTime) / incidentCount", unit := "declared clock unit", visual := "line", boundary := "actor population and window" }
  , { name := "reliability.composed_uptime", requiredFields := ["actorInstance", "Unavailable.timeAt", "Recovered.timeAt", "observationWindow", "dependencyGate", "composition", "requiredCount"], reducer := "sweep synchronized up/down intervals; series is all members up, parallel is any member up, and threshold is at least requiredCount members up; integrate each predicate over the window", unit := "ratio over time", visual := "per-instance and composed-availability lines", boundary := "declared service dependency gate and observation window" }
  , { name := "reliability.failure_cascade", requiredFields := ["actorInstance", "dependencyGate", "provider", "consumer", "composition", "requiredCount", "Unavailable.id", "Recovered.prior", "timeAt", "task", "message", "outcome"], reducer := "at every outage/recovery boundary compute the fixed point of unavailable consumers under series/parallel/threshold gates; disable ordinary sends/receives for unavailable instances; retain initiating failures, propagation edges, stalled or terminated tasks, protocol/property violations, outcomes, and recovery order", unit := "services, tasks, outage time, messages, and ratio", visual := "dependency graph with cascade overlay, synchronized outage timeline, and violated interaction paths", boundary := "actor dependency network, named failure scenario, and observation window" }
  , { name := "reliability.dos_criticality", requiredFields := ["actorInstance", "dependencyGate", "provider", "consumer", "requiredCount", "task", "messageTraffic", "taskValue", "failureScenario"], reducer := "rank nodes with a declared PageRank-like dependency centrality, then validate the ranking with single-node and named multi-node fixed-point cascades, minimal cut sets, lost task capacity, and client-visible outcomes", unit := "centrality score, services, tasks, work/time, and ratio", visual := "ranked dependency graph, cut-set table, and cascade overlays", boundary := "declared attacker capability, dependency network, traffic/value window, and failure-set size" }
  , { name := "reliability.network_outage_impact", requiredFields := ["actor", "src", "dst", "Unavailable.id", "Recovered.prior", "timeAt", "task", "outcome", "dependencyGate"], reducer := "join composed service outages and cascade propagation edges to task events; count affected, failed, delayed, and recovered tasks without assuming independent failures", unit := "outage time, tasks, and ratio", visual := "actor-network overlay and outage timeline", boundary := "actor network and observation window" }
  , { name := "infrastructure.cost", requiredFields := ["actor", "hardwarePool", "replicas", "provisionedHours", "availableHours", "hardwareCostPerProvisionedHour", "serviceCostPerAvailableHour", "currency"], reducer := "replicas * provisionedHours * hardwareCostPerProvisionedHour + sum(availableHours) * serviceCostPerAvailableHour", unit := "minor currency units", visual := "stacked line and pie", boundary := "service cluster and accounting period" }
  , { name := "capacity.load_per_instance", requiredFields := ["actor", "actorInstance", "replicas", "routing", "completedWork", "observationTime"], reducer := "plot nominal demand/replicas and observed work/observationTime for every instance; report imbalance and hottest instance", unit := "work/hour per instance", visual := "XY lines and per-instance histogram", boundary := "homogeneous service cluster and demand window" }
  , { name := "capacity.optimal_supply", requiredFields := ["actor", "demandWorkPerHour", "capacityWorkPerHour", "availabilityTarget", "routing", "replicaChoices", "hardwareCostPerProvisionedHour", "serviceCostPerAvailableHour", "currency"], reducer := "enumerate permitted replica/supply choices, reject plans whose availability-adjusted sustainable capacity is below demand, and choose minimum hourly cost with demand served and headroom reported", unit := "replicas, work/hour, and minor currency units/hour", visual := "demand/supply and cost XY lines with feasible optimum", boundary := "service cluster, demand window, reliability target, and permitted supply set" }
  , { name := "finance.gross_sales", requiredFields := ["saleAmount", "currency"], reducer := "sum(saleAmount)", unit := "currency", visual := "line", boundary := "accounting period" }
  , { name := "finance.refunds", requiredFields := ["refundAmount", "currency"], reducer := "sum(refundAmount)", unit := "currency", visual := "line", boundary := "accounting period" }
  , { name := "finance.net_revenue", requiredFields := ["saleAmount", "refundAmount", "currency"], reducer := "grossSales - refunds", unit := "currency", visual := "line", boundary := "accounting period" }
  , { name := "finance.labor", requiredFields := ["payAmount", "currency"], reducer := "sum(payAmount)", unit := "currency", visual := "line", boundary := "accounting period" }
  , { name := "finance.material_cost", requiredFields := ["materialCost", "currency"], reducer := "sum(materialCost)", unit := "currency", visual := "line", boundary := "accounting period" }
  , { name := "finance.tax", requiredFields := ["taxType", "taxAmount", "currency"], reducer := "sum(taxAmount) by taxType", unit := "currency", visual := "line and pie", boundary := "jurisdiction and accounting period" }
  , { name := "finance.other_cost", requiredFields := ["costType", "costAmount", "currency"], reducer := "sum(costAmount) by costType", unit := "currency", visual := "line and pie", boundary := "accounting period" }
  , { name := "finance.profit_loss", requiredFields := ["saleAmount", "refundAmount", "payAmount", "materialCost", "taxAmount", "costAmount", "currency"], reducer := "netRevenue - labor - materialCost - tax - otherCost", unit := "currency", visual := "line", boundary := "declared accounting model and period" }
  , { name := "waste.units", requiredFields := ["wasteType", "wasteUnits"], reducer := "sum(wasteUnits) by wasteType", unit := "declared item unit", visual := "line and pie", boundary := "scenario and accounting period" }
  , { name := "waste.cost", requiredFields := ["wasteType", "wasteCost", "currency"], reducer := "sum(wasteCost) by wasteType", unit := "currency", visual := "line and pie", boundary := "scenario and accounting period" }
  , { name := "waste.rate", requiredFields := ["wasteUnits", "producedUnits"], reducer := "sum(wasteUnits) / sum(producedUnits)", unit := "ratio", visual := "line", boundary := "scenario and accounting period" }
  , { name := "inventory.sell_through", requiredFields := ["batchId", "breadKind", "unitsStocked", "unitsReserved", "stocked.timeAt", "reserved.timeAt"], reducer := "sum(unitsReserved) / sum(unitsStocked), grouped by bread kind and batch age", unit := "ratio", visual := "line and histogram", boundary := "batch schedule and freshness window" }
  , { name := "inventory.stockout", requiredFields := ["breadKind", "requestedUnits", "availableUnits", "timeAt"], reducer := "count stockout orders and unfilled units by bread kind and time", unit := "orders, units, and ratio", visual := "line and pie", boundary := "storefront and demand window" }
  , { name := "inventory.charity_transfer", requiredFields := ["batchId", "breadKind", "freshnessWindow", "donatedUnits", "eligibleDonationValue", "currency", "timeAt"], reducer := "sum donated units and eligible receipt value by bread kind and batch age; leave tax savings indeterminate without declared tax rules and rate", unit := "units and currency", visual := "line and pie", boundary := "charity transfer and accounting period" }
  ]

def validateDerivedPropertyPlan (plans : List DerivedPropertyPlan) : List String :=
  plans.foldr (fun plan errors =>
    (if plan.name == "" then ["derived property has empty name"] else []) ++
    (if plan.requiredFields.isEmpty then ["derived property " ++ plan.name ++ " has no required fields"] else []) ++
    (if plan.reducer == "" then ["derived property " ++ plan.name ++ " has no reducer"] else []) ++
    (if plan.unit == "" then ["derived property " ++ plan.name ++ " has no unit"] else []) ++
    (if plan.visual == "" then ["derived property " ++ plan.name ++ " has no visual"] else []) ++
    (if plan.boundary == "" then ["derived property " ++ plan.name ++ " has no boundary"] else []) ++ errors) []

end LeanFM
