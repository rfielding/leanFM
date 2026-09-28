import LeanFM.StreamStats

namespace LeanFM

def testKey : TaskKey := { session := "s1", task := "get_docs" }
def testStarted : ObservedTaskEvent :=
  { id := "start-1", prior := [], key := testKey, timeAt := 10, boundary := .started }
def testCompleted : ObservedTaskEvent :=
  { id := "end-1", prior := ["start-1"], key := testKey, timeAt := 37, boundary := .succeeded }

def testAttempt : TaskAttempt :=
  { key := testKey, started := testStarted, completed := some testCompleted
  , outcome := some .succeeded }

example : testAttempt.latency = some 27 := by native_decide
example : (attemptsFromEventStream [testStarted, testCompleted]).head? = some testAttempt := by
  native_decide

def overlappingStart : ObservedTaskEvent :=
  { id := "start-2", prior := [], key := testKey, timeAt := 12, boundary := .started }

def overlappingEnd : ObservedTaskEvent :=
  { id := "end-2", prior := ["start-2"], key := testKey, timeAt := 20, boundary := .failed }

example :
    (attemptsFromEventStream [testStarted, overlappingStart, overlappingEnd, testCompleted]).map
      (fun attempt => (attempt.started.id, attempt.completed.map (fun event => event.id))) =
      [("start-1", some "end-1"), ("start-2", some "end-2")] := by
  native_decide

def workObservations : List WorkObservation :=
  [ { client := "client-1", server := "server-1"
    , started := testStarted, completed := testCompleted, work := 100 }
  , { client := "client-2", server := "server-1"
    , started := overlappingStart, completed := overlappingEnd, work := 100 }
  ]

example : clientExperiencedRate workObservations = some { work := 200, milliseconds := 35 } := by
  native_decide

example : serverAggregateRate workObservations = some { work := 200, milliseconds := 27 } := by
  native_decide

example :
    (scalabilityObservation 2 workObservations).map (fun point => point.clientCount) = some 2 := by
  native_decide

def idealUSL : USLParameters :=
  { gamma := 100, alphaNum := 0, alphaDen := 1, betaNum := 0, betaDen := 1 }

def contentionUSL : USLParameters :=
  { gamma := 100, alphaNum := 1, alphaDen := 10, betaNum := 0, betaDen := 1 }

def coherencyUSL : USLParameters :=
  { gamma := 100, alphaNum := 1, alphaDen := 10, betaNum := 1, betaDen := 200 }

example : idealUSL.regime = .ideal := by native_decide
example : contentionUSL.regime = .contentionOnly := by native_decide
example : coherencyUSL.regime = .coherencyLimited := by native_decide
example : idealUSL.throughput 4 = some (400, 1) := by native_decide
example : contentionUSL.throughput 10 = some (10000, 19) := by native_decide
example : idealUSL.capacityPopulation? 32 = none := by native_decide
example : contentionUSL.capacityPopulation? 32 = none := by native_decide
example : coherencyUSL.capacityPopulation? 32 = some 13 := by native_decide
example :
    (match coherencyUSL.throughput 13, coherencyUSL.throughput 32 with
    | some atCapacity, some overCapacity => ratioLess overCapacity atCapacity
    | _, _ => false) = true := by
  native_decide
example : offeredLoadState 99 100 = some .belowCapacity := by native_decide
example : offeredLoadState 100 100 = some .atCapacity := by native_decide
example : offeredLoadState 101 100 = some .overCapacity := by native_decide
example : admittedThroughput 120 100 = some 100 := by native_decide
example : queueingSteadyState 80 100 = some ((100, 20), (80, 20)) := by native_decide
example :
    (match queueingSteadyState 80 100, queueingSteadyState 90 100 with
    | some (_, queued80), some (_, queued90) => ratioLess queued80 queued90
    | _, _ => false) = true := by
  native_decide
example : queueingSteadyState 100 100 = none := by native_decide
example : queueingSteadyState 120 100 = none := by native_decide

def unavailable : ObservedTaskEvent :=
  { id := "gateway-1-down", prior := [], key := { session := "cluster", task := "reliability" }
  , timeAt := 100, boundary := .started }

def recovered : ObservedTaskEvent :=
  { id := "gateway-1-up", prior := ["gateway-1-down"]
  , key := { session := "cluster", task := "reliability" }
  , timeAt := 140, boundary := .succeeded }

def thresholdJoinEvent : ObservedTaskEvent :=
  { id := "join", prior := ["branch-a", "branch-c", "start"]
  , key := testKey, timeAt := 50, boundary := .progress
  , join := some { required := 2, total := 3, selected := ["branch-a", "branch-c"] } }

example : thresholdJoinEvent.hasValidJoinEvidence := by native_decide
example :
    !({ thresholdJoinEvent with join := some { required := 3, total := 2
                                               , selected := ["branch-a", "branch-c"] } }).hasValidJoinEvidence := by
  native_decide

def gatewayOutage : OutageObservation :=
  { actorSpec := "Gateway", actorInstance := "gateway-1"
  , unavailable := unavailable, recovered := recovered }

example : gatewayOutage.repairTime = some 40 := by native_decide
example :
    (estimateReliability "Gateway" 2 0 1000 [gatewayOutage]).map
      (fun estimate => (estimate.outageFraction, estimate.meanTimeToRepair)) =
      some ((40, 2000), some (40, 1)) := by
  native_decide

end LeanFM
