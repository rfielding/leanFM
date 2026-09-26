import LeanFM.StreamStats

namespace LeanFM

def testKey : TaskKey := { session := "s1", task := "get_docs" }
def testStarted : ObservedTaskEvent :=
  { key := testKey, timeAt := 10, boundary := .started }
def testCompleted : ObservedTaskEvent :=
  { key := testKey, timeAt := 37, boundary := .succeeded }

def testAttempt : TaskAttempt :=
  { key := testKey, started := testStarted, completed := some testCompleted
  , outcome := some .succeeded }

example : testAttempt.latency = some 27 := by native_decide
example : (attemptsFromEventStream [testStarted, testCompleted]).head? = some testAttempt := by
  native_decide

end LeanFM
