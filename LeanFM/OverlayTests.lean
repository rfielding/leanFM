import LeanFM.Overlay

/-! Negative and exact-value tests for LeanFM.Overlay (selfhost.logic.overlay). -/

open LeanFM.Logic
open LeanFM.Overlay

def expect (label : String) (ok : Bool) : IO Unit :=
  if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"FAILED: {label}"

def t (src dst msg : String) : Transition := { src, dst, message := msg }

def coin : TaskModel :=
  { id := "coin", canonical := false, initial := "s", states := ["s", "h", "x"], terminals := ["h", "x"]
  , transitions := [t "s" "h" "Heads", t "s" "x" "Tails"] }

def a (src msg : String) (n d ms : Nat) : Annotation := { src, message := msg, probability := Q.norm n d, delayMs := ms }

def main : IO Unit := do
  let good : Overlay := { name := "fair", kind := "declared", annotations := [a "s" "Heads" 1 2 10, a "s" "Tails" 1 2 30] }
  expect "valid overlay accepted" (validate coin good).isEmpty
  let short : Overlay := { good with annotations := [a "s" "Heads" 1 2 10, a "s" "Tails" 1 3 30] }
  expect "weights summing to 5/6 are rejected, never normalized" ((validate coin short).any (·.contains "sum to 5/6"))
  let missing : Overlay := { good with annotations := [a "s" "Heads" 1 1 10] }
  expect "unannotated transition rejected" ((validate coin missing).any (·.contains "has no annotation"))
  let stray : Overlay := { good with annotations := good.annotations ++ [a "s" "Edge" 0 1 0] }
  expect "annotation of an undeclared transition rejected" ((validate coin stray).any (·.contains "does not declare"))
  expect "invalid overlay yields no runs" (match runs coin short with | .error _ => true | .ok _ => false)
  let loop : TaskModel := { coin with states := ["s", "h"], terminals := ["h"], transitions := [t "s" "s" "Again", t "s" "h" "Stop"] }
  let loopOverlay : Overlay := { good with annotations := [a "s" "Again" 1 2 1, a "s" "Stop" 1 2 1] }
  expect "a cycle is reported, not truncated" (match runs loop loopOverlay with | .error e => e.contains "revisits" | .ok _ => false)
  match runs coin good with
  | .error e => throw (IO.userError e)
  | .ok rs =>
    expect "probabilities of complete runs sum to exactly 1" (total rs == Q.one)
    expect "P(F h) = 1/2" (probabilityReaching rs (· == "h") == Q.norm 1 2)
    expect "P(F<=20ms h) = 1/2 and P(F<=5ms h) = 0" (probabilityWithin rs (· == "h") 20 == Q.norm 1 2 && probabilityWithin rs (· == "h") 5 == Q.zero)
    expect "expected duration is exact (20 ms)" (expectedDuration rs == Q.norm 20 1)
    expect "most likely tie broken by shorter duration" ((mostLikely rs (fun _ => true)).map (·.final) == some "h")
  expect "decimal rendering rounds" ((Q.norm 2 3).decimal 3 == "0.667" && (Q.norm 999 1000).decimal 3 == "0.999")
  IO.println "ok: all LeanFM.Overlay tests passed"
