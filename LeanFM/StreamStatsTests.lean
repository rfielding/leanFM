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
