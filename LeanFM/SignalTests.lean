import LeanFM.Signal

/-! Tests of check_signal (clause selfhost.mcp.logic.signal, decision logic-signal). -/

open Lean LeanFM.Signal

namespace LeanFM.SignalTests

def sample (t : Float) (fields : List (String × Float)) (label : String := "") : Json :=
  Json.mkObj ([("t", toJson t)] ++ (if label == "" then [] else [("label", Json.str label)]) ++
    fields.map fun (k, v) => (k, toJson v))

def run (claim : String) (samples : List Json) : Except String Json :=
  check (Json.mkObj [("claim", Json.str claim), ("samples", Json.arr samples.toArray)])

def get (r : Except String Json) (k : String) : String :=
  match r with
  | .ok j => match j.getObjValD k with
    | .str s => s
    | v => v.compress
  | .error e => "refused: " ++ e

def refusedWith (r : Except String Json) (needle : String) : Bool :=
  match r with
  | .error e => (e.splitOn needle).length > 1
  | .ok _ => false

-- a temperature that reaches 27.1 degrees fails a 18 to 26 band at that sample, by 1.1
def temps : List Json := [sample 0 [("temp", 20)], sample 600 [("temp", 24)], sample 1200 [("temp", 27.1)],
  sample 1800 [("temp", 18)]]
def band := "(always (and (above temp 18) (below temp 26)))"
#guard get (run band temps) "verdict" == "fails"
#guard get (run band temps) "margin" == "-1.1"
#guard match run band temps with
  | .ok j => (j.getObjValD "firstFailure").getObjValD "sample" == toJson (3 : Nat) &&
             ((j.getObjValD "firstFailure").getObjValD "readings").getObjValD "temp" == Json.num ⟨27100, 3⟩
  | _ => false
-- 18 itself is inside the band: above is "at least"
#guard get (run band (temps.take 2 ++ [sample 1800 [("temp", 18)]])) "verdict" == "holds"

-- water below 100 ml for 1800 seconds never happens: it drops for 1200 seconds and is refilled
def water : List Json := [sample 0 [("water", 300)], sample 600 [("water", 90)], sample 1200 [("water", 80)],
  sample 1800 [("water", 250)], sample 2400 [("water", 240)]]
#guard get (run "(never (throughout 1800 (below water 100)))" water) "verdict" == "holds"
-- and below 100 for 600 seconds does happen
#guard get (run "(never (throughout 600 (below water 100)))" water) "verdict" == "fails"

-- food below 20 g is followed by a Dispense within 600 seconds: holds; the margin is the room left
-- where food is not low (30 g above the bound at the start), unbounded where a Dispense came
def food (late : Bool) : List Json := [sample 0 [("food", 50)], sample 600 [("food", 15)],
  sample (if late then 1500 else 900) [] "Dispense", sample 2000 [("food", 60)]]
def fed := "(always (implies (below food 20) (within 600 (on Dispense))))"
#guard get (run fed (food false)) "verdict" == "holds"
#guard get (run fed (food false)) "margin" == "30"
#guard get (run "(within 600 (on Dispense))" (food false)) "margin" == "-unbounded"
#guard get (run "(within 900 (on Dispense))" (food false)) "margin" == "unbounded"
#guard get (run fed (food true)) "verdict" == "fails"

-- refusals
#guard refusedWith (run "(always (below food 20))" temps) "reads food before its first reading"
#guard refusedWith (run band [sample 600 [("temp", 20)], sample 0 [("temp", 21)]]) "sample 2"
#guard refusedWith (run "(eventually (below temp 26))" temps) "not a word here"
#guard refusedWith (run "(within -5 (below temp 26))" temps) "not negative"
#guard refusedWith (run "(within 5x (below temp 26))" temps) "is a number"
#guard refusedWith (run ("(and " ++ String.join (List.replicate 256 "(below temp 26) ") ++ ")") temps) "at most 256 words"
#guard !refusedWith (run ("(and " ++ String.join (List.replicate 255 "(below temp 26) ") ++ ")") temps) "at most 256 words"
#guard refusedWith (run band []) "no samples"

-- possibly and inevitably mean the same over one run
#guard get (run "(possibly (above temp 27))" temps) "verdict" == "holds"
#guard get (run "(inevitably (above temp 27))" temps) "verdict" == "holds"
#guard get (run "(inevitably (above temp 28))" temps) "verdict" == "fails"

-- a window that reaches past the last sample is counted, never hidden
#guard get (run "(always (within 900 (above temp 0)))" temps) "cutShort" == "2"

-- a log of event lines gives the same answer as the same samples
def logText : String := String.intercalate "\n"
  ["started", "{\"type\":\"leanFM\",\"ts\":\"0\",\"label\":\"Reading\",\"payload\":{\"temp\":20}}",
   "{\"type\":\"leanFM\",\"ts\":\"600000000000\",\"label\":\"Reading\",\"payload\":{\"temp\":24}}",
   "{\"type\":\"leanFM\",\"ts\":1200000000000,\"label\":\"Reading\",\"payload\":{\"temp\":27.1}}",
   "{\"type\":\"leanFM\",\"ts\":\"1800000000000\",\"label\":\"Reading\",\"payload\":{\"temp\":18}}"]
#guard get (check (Json.mkObj [("claim", Json.str band), ("log", Json.str logText)])) "margin" == "-1.1"
#guard get (check (Json.mkObj [("claim", Json.str band), ("log", Json.str logText)])) "samples" == "4"

-- linear: 100000 samples through a sliding window and a suffix answer at once
def many : Array Json := (Array.range 100000).map fun i => sample i.toFloat [("temp", (i % 7).toFloat + 20)]
#guard get (check (Json.mkObj [("claim", Json.str "(always (throughout 30 (above temp 19)))"), ("samples", Json.arr many)])) "verdict" == "holds"
#guard refusedWith (check (Json.mkObj [("claim", Json.str band), ("samples", Json.arr (many.push (sample 1e6 [("temp", 20)])))])) "at most 100000"

-- the chart: one panel per field, the bound dashed, red marks only at the failing sample, names escaped
def chart (claim : String) (samples : List Json) : String :=
  get (check (Json.mkObj [("claim", Json.str claim), ("samples", Json.arr samples.toArray), ("theme", Json.str "dark")])) "svg"
def occurs (s pat : String) : Nat := (s.splitOn pat).length - 1
#guard occurs (chart band temps) "<polyline" == 1
#guard occurs (chart band temps) "stroke-dasharray=\"6 4\"" == 2
#guard occurs (chart band temps) "<circle" == 1
#guard occurs (chart "(always (below <x> 5))" [sample 0 [("<x>", 1)]]) "&lt;x&gt;" == 1
#guard occurs (chart "(always (below <x> 5))" [sample 0 [("<x>", 1)]]) "<x>" == 0
#guard occurs (chart fed (food true)) "ticks: Dispense<" == 1
#guard get (run band temps) "svg" == "refused: no svg" || (match run band temps with | .ok j => j.getObjValD "svg" == Json.null | _ => false)

end LeanFM.SignalTests
