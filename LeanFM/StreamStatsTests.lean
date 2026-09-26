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

end LeanFM
