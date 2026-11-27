import LeanFM.Signal
import LeanFM.SessionTools

/-! Generates the book's "Claims over measurements" section: three days of a guinea pig cage
    while its owners are away. An Arduino reads the water bottle, the food bowl and the temperature
    every ten minutes and writes event lines; the food dispenser writes one when it runs; the
    webcam adds a motion level. The log is simulated here (deterministically, so the book does not
    change between builds), and everything shown about it (verdicts, margins, first failures,
    charts) comes from `LeanFM.Signal.check`, the function the check_signal tool calls.
    Run from the LeanFM root: `lake env lean --run SignalChapterExample.lean`. -/

namespace SignalChapterExample
open Lean LeanFM.Signal

def pi : Float := 3.141592653589793
/-- Seconds since the epoch of the first reading, a midnight. -/
def t0 : Nat := 1794528000

/-- A small deterministic noise in [-1, 1]. -/
def noise (i salt : Nat) : Float :=
  let x := (i * 2654435761 + salt * 40503) % 1000
  x.toFloat / 500 - 1

def round1 (x : Float) : Float := Float.round (x * 10) / 10
def round2 (x : Float) : Float := Float.round (x * 100) / 100

structure Ev where
  t : Nat
  label : String
  payload : List (String × Float)
  /-- The device that sent it: Arduino, Dispenser or Webcam (to the Hub). -/
  src : String := "Arduino"

/-- An event line as LeanFM's event log writes one: the marker first, then the event, numbered per
device (`arduino:3`) with its prev link to the device's previous event, all in one session. -/
def line (e : Ev) (n : Nat) : String :=
  let dev := e.src.toLower
  let rest := (Json.mkObj ([("id", Json.str s!"{dev}:{n}"), ("session", Json.str "cage"), ("from", Json.str e.src),
    ("to", Json.str "Hub"), ("label", Json.str e.label), ("ts", Json.str (toString ((t0 + e.t) * 1000000000))),
    ("payload", Json.mkObj (e.payload.map fun (k, v) => (k, num v)))] ++
    (if n > 1 then [("prev", Json.arr #[Json.str s!"{dev}:{n - 1}"])] else []))).compress
  "{\"type\":\"leanFM\"," ++ (rest.drop 1).toString

/-- Three days, a reading every ten minutes; a Dispense when the bowl drops below 20 g (five
minutes later, except once on the third day, when the dispenser sticks for 25 minutes). -/
def events : List Ev := Id.run do
  let mut out : Array Ev := #[]
  let mut food : Float := 52
  let mut pending : Option Nat := none
  let mut stuck := false
  for i in [0:432] do
    let t := 600 * i
    let h := (t % 86400).toFloat / 3600
    let day := t / 86400
    if let some at_ := pending then
      if at_ ≤ t then
        food := food + 35
        out := out.push { t := at_, label := "Dispense", payload := [("food", round1 food)], src := "Dispenser" }
        pending := none
    let spike := if day == 1 then max 0 (4.1 * (1 - Float.abs (h - 15) / 2.5)) else 0
    let temp := 21 + 2 * Float.sin (2 * pi * (h / 24 - 0.375)) + spike + 0.15 * noise i 1
    let water := 600 - 1.0 * i.toFloat + 2 * noise i 2
    let motion := 0.58 + 0.3 * Float.cos (2 * pi * (h - 6) / 12) + 0.04 * noise i 3
    food := food - 0.9 - 0.1 * noise i 4
    out := out.push { t, label := "Reading", payload := [("temp", round1 temp), ("water", round1 water), ("food", round1 food)] }
    out := out.push { t := t + 300, label := "Frame", payload := [("motion", round2 motion)], src := "Webcam" }
    if food < 20 && pending.isNone then
      -- the dispenser sticks once, at the first low bowl of the third day
      let sticks := day == 2 && !stuck
      if sticks then stuck := true
      pending := some (t + if sticks then 1500 else 300)
  -- in time order (a Dispense lands between a Reading and the next Frame)
  return (out.toList.mergeSort (fun a b => a.t ≤ b.t))

/-- The lines, each numbered within its device. -/
def lines : List String := Id.run do
  let mut seen : List (String × Nat) := []
  let mut out : Array String := #[]
  for e in events do
    let n := (seen.lookup e.src).getD 0 + 1
    seen := (e.src, n) :: seen.filter (·.1 != e.src)
    out := out.push (line e n)
  return out.toList

def logText : String := "\n".intercalate lines

structure Example where
  name : String
  english : String
  claim : String
  unit : String

def examples : List Example :=
  [ { name := "temp", english := "The temperature stays between 18 and 26\\,\\textdegree C.",
      claim := "(always (and (above temp 18) (below temp 26)))", unit := "\\,\\textdegree C" }
  , { name := "water", english := "The water bottle is never below 100\\,ml for half an hour.",
      claim := "(never (throughout 1800 (below water 100)))", unit := "\\,ml" }
  , { name := "food", english := "When the bowl drops below 20\\,g, the dispenser runs within 10 minutes.",
      claim := "(always (implies (below food 20) (within 600 (on Dispense))))", unit := "\\,g" }
  , { name := "motion", english := "The webcam sees the guinea pigs move at least every two hours.",
      claim := "(always (within 7200 (above motion 0.3)))", unit := "" } ]

def ask (claim theme : String) : Json :=
  match check (Json.mkObj [("claim", Json.str claim), ("log", Json.str logText), ("theme", Json.str theme)]) with
  | .ok j => j
  | .error e => panic! s!"check_signal refused {claim}: {e}"

def str (j : Json) (k : String) : String :=
  match j.getObjValD k with
  | .str s => s
  | v => v.compress

/-- A time as the owners would say it: day 2, 15:00. -/
def when (j : Json) : String :=
  match (j.getObjValD "firstFailure").getObjValD "t" with
  | .num n =>
    let s := n.toFloat.toUInt64.toNat - t0
    let m := (s % 86400) / 60
    let pad := fun (k : Nat) => if k < 10 then s!"0{k}" else toString k
    s!"day {s / 86400 + 1}, {pad (m / 60)}:{pad (m % 60)}"
  | _ => "never"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\footnotesize,breaklines=true]\n" ++ body ++ "\n\\end{lstlisting}\n"

def main : IO Unit := do
  let dir := "book/generated"
  IO.FS.writeFile "examples/guinea-pigs/cage.log" (logText ++ "\n")
  -- the order of the events, checked against the example's protocol by session_conform's function
  -- for a log the server reads itself (as with serverLog), so the 64 KiB bound on what a client
  -- sends does not apply to it
  let cageText ← IO.FS.readFile "examples/guinea-pigs/GuineaPigCage.leanfm"
  let order ← match LeanFM.SessionTools.conformLog (Json.mkObj [("lean", Json.str cageText), ("allowIncomplete", Json.bool true),
      ("logWindow", Json.mkObj [("log", Json.str "cage"), ("fromLine", toJson (1 : Nat)), ("logLines", toJson lines.length),
        ("nextLine", toJson (lines.length + 1)), ("logFingerprint", Json.str "")])]) logText LeanFM.SessionTools.conformEvents with
    | .ok j => pure j
    | .error e => throw (IO.userError s!"session_conform refused the cage log: {e}")
  unless str order "verdict" == "conforms" do throw (IO.userError s!"the cage log breaks GuineaPigCage: {str order "reading"}")
  IO.FS.writeFile s!"{dir}/sig-conform.tex" (listing s!"session_conform: {str order "verdict"}: {str order "reading"}")
  IO.FS.writeFile s!"{dir}/sig-log.tex" <| listing <| "\n".intercalate (lines.take 3 ++ ["..."] ++
    (lines.filter (fun (l : String) => (l.splitOn "Dispense").length > 1)).take 1)
  IO.FS.writeFile s!"{dir}/sig-claims.tex" <| listing <| "\n".intercalate (examples.map (·.claim))
  let mut rows : Array String := #[]
  for e in examples do
    let light := ask e.claim "light"
    let dark := ask e.claim "dark"
    IO.FS.writeFile s!"{dir}/sig-{e.name}-light.svg" (str light "svg")
    IO.FS.writeFile s!"{dir}/sig-{e.name}-dark.svg" (str dark "svg")
    let margin := str light "margin"
    let marginText := if margin == "unbounded" || margin == "-unbounded" then margin else margin ++ e.unit
    rows := rows.push s!"{e.english} & {str light "verdict"} & {marginText} & {when light} \\\\"
  IO.FS.writeFile s!"{dir}/sig-results.tex" <|
    "\\begin{tabular}{@{}p{.42\\textwidth}lrl@{}}\n\\toprule\nclaim & verdict & margin & first fails \\\\\n\\midrule\n" ++
    "\n".intercalate rows.toList ++ "\n\\bottomrule\n\\end{tabular}\n"
  IO.FS.writeFile s!"{dir}/sig-cut.tex" s!"{str (ask "(always (within 7200 (above motion 0.3)))" "light") "cutShort"}\\unskip"
  IO.FS.writeFile s!"{dir}/sig-counts.tex" s!"{lines.length} event lines, {(lines.filter (fun (l : String) => (l.splitOn "Dispense").length > 1)).length} of them from the dispenser\\unskip"
  IO.FS.writeFile s!"{dir}/sig-provenance.txt" <| "\n".intercalate
    [ "generator: SignalChapterExample.lean (lake env lean --run SignalChapterExample.lean)"
    , "function: LeanFM.Signal.check, the function the check_signal tool calls"
    , "input: a simulated three-day cage log, generated deterministically in the generator"
    , "outputs: sig-log.tex sig-claims.tex sig-results.tex sig-counts.tex sig-{temp,water,food,motion}-{light,dark}.svg" ]

end SignalChapterExample

def main : IO Unit := SignalChapterExample.main
