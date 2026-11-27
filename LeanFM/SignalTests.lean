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
#guard refusedWith (run "(always (below food 20))" temps) "which the run never reads"
-- a field first read later starts the claim there: the samples before are skipped, not refused
#guard get (run "(always (below food 20))" (temps ++ [sample 2400 [("food", 15)]])) "verdict" == "holds"
#guard get (run "(always (below food 20))" (temps ++ [sample 2400 [("food", 15)]])) "skipped" == "4"
-- branches that would start at different samples are refused, since starting the whole claim at
-- food's first reading would judge the temp branch over fewer samples than alone (where it fails)
def mixed := "(and (always (above temp 19)) (always (below food 20)))"
def late := temps ++ [sample 2400 [("food", 15)]]
#guard get (run "(always (above temp 19))" late) "verdict" == "fails"
#guard refusedWith (run mixed late) "(above temp 19) starts at sample 1"
#guard refusedWith (run mixed late) "would not give the answer it gives alone"
-- an on reads no field, so it starts at the first sample
#guard refusedWith (run "(possibly (and (on Dispense) (below food 20)))" ([sample 0 [] "Dispense"] ++ late)) "since it reads no field"
-- from says where the claim starts; temp's reading of 18 from t 1800 is carried in at t 2400
def runFrom (claim : String) (ss : List Json) (t : Float) : Except String Json :=
  check (Json.mkObj [("claim", Json.str claim), ("samples", Json.arr ss.toArray), ("from", toJson t)])
#guard get (runFrom mixed late 2400) "verdict" == "fails"
#guard get (runFrom mixed late 2400) "margin" == "-1"
#guard get (runFrom mixed late 2400) "skipped" == "4"
#guard get (runFrom "(always (above temp 19))" late 2400) "margin" == "-1"
#guard refusedWith (runFrom mixed late 600) "food is first read at sample 5"
#guard refusedWith (runFrom mixed late 9999) "no sample is at or after from"
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

-- Sharing is the same as inlining. `margin` computes each subclaim's margins once, as an array over
-- every sample, and its parent reads that array at its own sample (or across its window). `ref` is
-- the definition read literally: one anchor sample at a time, every subclaim evaluated from scratch
-- at the sample its parent asks about, nothing shared. A branch used twice, or under a window and
-- outside it (implies a (within d a)), must get the same margins either way, for every sample.
partial def ref (r : Run) (c : Claim) (i : Nat) : Float :=
  let n := r.t.size
  let later := (List.range n).filter (· ≥ i)
  let win (d : Float) := later.filter fun j => r.t[j]! ≤ r.t[i]! + d
  let mx (js : List Nat) (p : Claim) := js.foldl (fun acc j => max acc (ref r p j)) (-inf)
  let mn (js : List Nat) (p : Claim) := js.foldl (fun acc j => min acc (ref r p j)) inf
  match c with
  | .over f v => ((r.vals.lookup f).getD #[])[i]! - v
  | .under f v => v - ((r.vals.lookup f).getD #[])[i]!
  | .on m => if r.labels[i]! == m then inf else -inf
  | .not p => - ref r p i
  | .and ps => ps.foldl (fun acc p => min acc (ref r p i)) inf
  | .or ps => ps.foldl (fun acc p => max acc (ref r p i)) (-inf)
  | .implies a b => max (- ref r a i) (ref r b i)
  | .within d p => mx (win d) p
  | .throughout d p => mn (win d) p
  | .always p => mn later p
  | .never p => mn later (.not p)
  | .possibly p => mx later p

/-- A small deterministic generator (a linear congruential one). -/
def nextR (s : Nat) : Nat := (s * 6364136223846793005 + 1442695040888963407) % 18446744073709551616
def pick (s k : Nat) : Nat := (s / 65536) % k

/-- A random claim over fields x, y and labels A, B, drawn from a small pool so that the same branch
recurs, inside and outside windows. -/
partial def genClaim (s : Nat) (depth : Nat) : Claim × Nat :=
  let s := nextR s
  let leaf : Claim := match pick s 6 with
    | 0 => .over "x" 3 | 1 => .under "x" 6 | 2 => .over "y" 2 | 3 => .under "y" 5
    | 4 => .on "A" | _ => .on "B"
  if depth == 0 then (leaf, s) else
  let s1 := nextR s
  let (a, s2) := genClaim s1 (depth - 1)
  let (b, s3) := genClaim s2 (depth - 1)
  let d := (pick s3 4).toFloat * 2.5
  match pick s1 12 with
  | 0 => (leaf, s3) | 1 => (.not a, s3) | 2 => (.and [a, b], s3) | 3 => (.or [a, b, a], s3)
  | 4 => (.implies a b, s3) | 5 => (.within d a, s3) | 6 => (.throughout d a, s3)
  | 7 => (.always a, s3) | 8 => (.never a, s3) | 9 => (.possibly a, s3)
  -- the same branch at the anchor and inside a window from it
  | 10 => (.implies a (.within d (.and [a, b])), s3)
  | _ => (.always (.implies a (.throughout d (.or [a, b]))), s3)

/-- A random run: 12 samples at uneven times (gaps 0 to 3 seconds, so some share a time). -/
def genRun (s : Nat) : Run × Nat := Id.run do
  let mut s := s
  let mut t : Array Float := #[]
  let mut xs : Array Float := #[]
  let mut ys : Array Float := #[]
  let mut ls : Array String := #[]
  let mut now : Float := 0
  for _ in [0:12] do
    s := nextR s; now := now + (pick s 4).toFloat
    s := nextR s; let x := (pick s 10).toFloat
    s := nextR s; let y := (pick s 8).toFloat
    s := nextR s; let l := match pick s 3 with | 0 => "A" | 1 => "B" | _ => ""
    t := t.push now; xs := xs.push x; ys := ys.push y; ls := ls.push l
  return ({ t, labels := ls, vals := [("x", xs), ("y", ys)] }, s)

/-- How many of `trials` random (claim, run) pairs give different margins at some sample. -/
def disagreements (trials : Nat) : Nat := Id.run do
  let mut s := 7
  let mut bad := 0
  for _ in [0:trials] do
    let (r, s1) := genRun s
    let (c, s2) := genClaim s1 4
    s := s2
    let fast : Array Float := ((margin r c).run' {} : Id _)
    unless (List.range r.t.size).all (fun i => fast[i]! == ref r c i) do bad := bad + 1
  return bad

#guard disagreements 3000 == 0

-- the cases asked about, spelled out: a branch at the anchor and inside a window from it
def r3 : Run := { t := #[0, 1, 2, 4, 7], labels := #["", "A", "", "B", ""],
                  vals := [("x", #[1, 5, 2, 7, 4]), ("y", #[3, 0, 6, 1, 2])] }
def agrees (c : String) : Bool :=
  match parse c with
  | .ok cl => let fast : Array Float := ((margin r3 cl).run' {} : Id _); (List.range 5).all fun i => fast[i]! == ref r3 cl i
  | .error _ => false
#guard agrees "(always (implies (above x 3) (within 2 (above x 3))))"
#guard agrees "(always (implies (above x 3) (within 3 (and (above x 3) (on B)))))"
#guard agrees "(and (within 2 (above x 3)) (implies (above y 2) (within 2 (above x 3))))"
#guard agrees "(never (throughout 3 (implies (below x 4) (possibly (below x 4)))))"

-- linear, loudly: steps stay within stepBound, and doubling the samples at most doubles the steps
-- (2.1 allows for the deque's data-dependent pops); a regression fails the build with the growth
def stepsFor (claim : String) (n : Nat) : Except String (Nat × Nat) := do
  let ss := (Array.range n).map fun i => sample i.toFloat [("temp", ((i * 7919) % 13).toFloat + 15)]
    (if i % 17 == 0 then "Tick" else "")
  let j ← check (Json.mkObj [("claim", Json.str claim), ("samples", Json.arr ss)])
  return ((j.getObjValAs? Nat "steps").toOption.getD 0, (j.getObjValAs? Nat "stepBound").toOption.getD 0)
def linearClaims : List String :=
  [ "(always (within 30 (throughout 12 (above temp 16))))"
  , "(always (implies (below temp 17) (within 40 (on Tick))))"
  , "(never (and (throughout 5 (below temp 18)) (possibly (above temp 26))))"
  , "(or (within 1000 (above temp 27)) (always (throughout 300 (above temp 14))))" ]
#eval show IO Unit from do
  for c in linearClaims do
    let (s1, s2) ← match stepsFor c 4000, stepsFor c 8000 with
      | .ok (s1, _), .ok (s2, _) => pure (s1, s2)
      | .error e, _ | _, .error e => throw (IO.userError s!"check_signal refused {c}: {e}")
    if s1 == 0 then throw (IO.userError s!"check_signal answered no steps for {c}")
    if s2.toFloat > 2.1 * s1.toFloat then
      throw (IO.userError s!"check_signal is no longer linear for {c}: doubling the samples from 4000 to 8000 took the steps from {s1} to {s2}, {s2.toFloat / s1.toFloat} times")

end LeanFM.SignalTests
