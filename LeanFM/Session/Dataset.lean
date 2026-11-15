import Lean.Data.Json
import Std.Data.HashMap
import LeanFM.Session.Conform

/-! Large generated datasets of a protocol, summarized (clause selfhost.session.dataset): many
sessions are generated, and what comes back is how they are distributed (over paths, messages,
roles, lengths and durations) rather than every event.

A protocol without probabilities is walked by `walk`: at each step it takes one of the steps the
protocol allows next, or ends where the protocol may end, each equally likely under a seeded
generator. Those frequencies describe the walker, not the system; only a protocol with a
probability layer has frequencies that estimate its stated probabilities, and the summary says
which of the two it is. -/

namespace LeanFM.Session.Dataset
open Lean

/-- Bounds: sessions per request, events in all, and events in one session. -/
def maxSessions : Nat := 10000
def maxEvents : Nat := 200000
def maxSessionEvents : Nat := 600
/-- Rows kept in each distribution of the answer; the rest are counted. -/
def maxPaths : Nat := 12
def maxRows : Nat := 32
def maxBuckets : Nat := 12
/-- Labels written in one path's key before the rest are counted. -/
def maxPathLabels : Nat := 16

/-- One step of a generated session. -/
structure Step where
  label : String
  src   : String
  dst   : String
  isAct : Bool := false
  /-- session-relative time: milliseconds from a probability layer, else the step's index -/
  time  : Nat := 0
  /-- the event's id in its session and the id it names as its cause, for walks -/
  id    : String := ""
  cause : Option String := none
  deriving Repr, BEq, Inhabited

/-- One generated session. -/
structure Run where
  steps     : Array Step
  /-- the session reached a point where the protocol may end, and ended there -/
  ended     : Bool
  /-- generation stopped at `maxSessionEvents` -/
  truncated : Bool := false
  deriving Repr, Inhabited

/-- The generator `Session.Sim` uses, so a seed means the same in both. -/
def nextSeed (s : Nat) : Nat := (s * 6364136223846793005 + 1442695040888963407) % 18446744073709551616
def pick (s n : Nat) : Nat := if n == 0 then 0 else (s / 8589934592) % n

/-- The seed of session `i` of a dataset seeded `seed`: SplitMix64, so the sessions' streams do not
overlap. (Seeding session i + 1 with the next state of session i's generator would replay that
session's stream shifted by one draw, and correlate neighbouring sessions.) -/
def sessionSeed (seed i : Nat) : Nat :=
  let m := 18446744073709551616
  let z := (seed + (i + 1) * 0x9E3779B97F4A7C15) % m
  let z := ((z ^^^ (z >>> 30)) * 0xBF58476D1CE4E5B9) % m
  let z := ((z ^^^ (z >>> 27)) * 0x94D049BB133111EB) % m
  z ^^^ (z >>> 31)

/-- Walk one session of a protocol without probabilities: from the start, take one of the steps the
protocol allows next, or end where it may end, each equally likely; a step is taken with
`Conform.step`, the same transition conformance uses, so every walk conforms by construction. A
state with no step where the protocol may not end is stuck, and the run is not ended. -/
def walk (g : Global String) (seed : Nat) (cap : Nat := maxSessionEvents) : Run × Nat := Id.run do
  let body := match g with | .sessions b _ => b | other => other
  let body := Conform.inlineNested body
  let mut states : List Conform.State := [{ g := body, bind := [] }]
  let mut rng := seed
  let mut out : Array Step := #[]
  for n in [0:cap] do
    let steps := (states.flatMap fun st => Conform.nextOf st.bind 32 st.g).eraseDups
    let canEnd := states.any (Conform.nullable ·.g)
    let options := steps.length + (if canEnd then 1 else 0)
    if options == 0 then return ({ steps := out, ended := false }, rng)
    rng := nextSeed rng
    let i := pick rng options
    if i == steps.length then return ({ steps := out, ended := true }, rng)
    let s := steps[i]!
    let ev : LogEvent := { id := s!"e{n}", src := s.src, dst := s.dst, label := s.label, cause := s.cause, isAct := s.isAct }
    let next := states.flatMap (Conform.step ev 64 false)
    states := next.foldl (fun acc st => if acc.any (Conform.stateKey · == Conform.stateKey st) then acc else acc ++ [st]) []
    out := out.push { label := s.label, src := s.src, dst := s.dst, isAct := s.isAct, time := n, id := ev.id, cause := s.cause }
  -- the cap is reached: the session may still end here, but it was not ended by the walk
  return ({ steps := out, ended := false, truncated := true }, rng)

/-- A run as the events a program would log for it, for conformance. -/
def Run.log (r : Run) (session : String) : List LogEvent :=
  r.steps.toList.map fun s => { id := s.id, session, src := s.src, dst := s.dst, label := s.label, cause := s.cause, isAct := s.isAct }

/-- `sessions` walks with seeds following from `seed`, refusing more than `maxEvents` in all. -/
def walkMany (g : Global String) (seed sessions : Nat) : Except String (Array Run) := do
  if sessions == 0 || sessions > maxSessions then throw s!"sessions must be 1 to {maxSessions}"
  let mut runs : Array Run := #[]
  let mut total := 0
  for i in [0:sessions] do
    let (r, _) := walk g (sessionSeed seed i)
    total := total + r.steps.size
    if total > maxEvents then
      throw s!"the dataset would exceed {maxEvents} events after {runs.size} sessions; ask for fewer sessions"
    runs := runs.push r
  return runs

/-! ## The summary -/

/-- A session's path: its labels in order, the first `maxPathLabels` written out. -/
def pathKey (r : Run) : String :=
  let ls := r.steps.toList.map (·.label)
  let shown := " -> ".intercalate (ls.take maxPathLabels)
  let more := if ls.length > maxPathLabels then s!" -> ... ({ls.length - maxPathLabels} more)" else ""
  let tail := if r.truncated then " [cut at the event limit]" else if r.ended then "" else " [stuck]"
  (if ls.isEmpty then "(no steps)" else shown) ++ more ++ tail

/-- Counts sorted by count, most first, then by key. -/
def ranked (m : Std.HashMap String Nat) : List (String × Nat) :=
  (m.toList.toArray.qsort fun (a, x) (b, y) => x > y || (x == y && a < b)).toList

/-- A decimal with two places, rounded down: `num / den`. -/
def decimal2 (num den : Nat) : String :=
  if den == 0 then "0" else
  let h := num * 100 / den
  let frac := h % 100
  s!"{h / 100}.{if frac < 10 then "0" else ""}{frac}"

/-- Values counted into at most `maxBuckets` ranges of equal width; each value once. -/
def histogram (vals : List Nat) : List Json :=
  match vals.min?, vals.max? with
  | some lo, some hi =>
    let distinct := vals.eraseDups.length
    if distinct ≤ maxBuckets then
      let ks := (vals.eraseDups.toArray.qsort (· < ·)).toList
      ks.map fun k => Json.mkObj [("from", toJson k), ("to", toJson k), ("count", toJson (vals.filter (· == k)).length)]
    else
      let width := (hi - lo) / maxBuckets + 1
      (List.range maxBuckets).filterMap fun b =>
        let a := lo + b * width
        let z := a + width - 1
        if a > hi then none else
        some (Json.mkObj [("from", toJson a), ("to", toJson (min z hi)),
          ("count", toJson (vals.filter fun v => a ≤ v && v ≤ z).length)])
  | _, _ => []

/-- How the runs are distributed: over paths, messages, roles, lengths and durations. `timeUnit` is
"ms" for runs from a probability layer and "steps" for walks. -/
def summary (runs : Array Run) (timeUnit : String) : Json := Id.run do
  let mut paths : Std.HashMap String Nat := {}
  let mut labels : Std.HashMap String Nat := {}
  let mut labelSessions : Std.HashMap String Nat := {}
  let mut sent : Std.HashMap String Nat := {}
  let mut received : Std.HashMap String Nat := {}
  let mut events := 0
  for r in runs do
    let key := pathKey r
    paths := paths.insert key (paths.getD key 0 + 1)
    let mut seen : List String := []
    for s in r.steps do
      events := events + 1
      let lk := if s.isAct then s!"{s.label} at {s.src}" else s!"{s.label} from {s.src} to {s.dst}"
      labels := labels.insert lk (labels.getD lk 0 + 1)
      if !seen.contains lk then
        seen := lk :: seen
        labelSessions := labelSessions.insert lk (labelSessions.getD lk 0 + 1)
      sent := sent.insert s.src (sent.getD s.src 0 + 1)
      if !s.isAct then received := received.insert s.dst (received.getD s.dst 0 + 1)
  let n := runs.size
  let ended := (runs.filter (·.ended)).size
  let truncated := (runs.filter (·.truncated)).size
  let stuck := n - ended - truncated
  let lengths := runs.toList.map (·.steps.size)
  let durations := runs.toList.map fun r => match r.steps.toList.map (·.time) with
    | [] => 0
    | ts => (ts.max?.getD 0) - (ts.min?.getD 0)
  let pathRows := ranked paths
  let roles := (sent.toList.map (·.1) ++ received.toList.map (·.1)).eraseDups
  let roleRows := (roles.toArray.qsort (· < ·)).toList.map fun r =>
    Json.mkObj [("role", Json.str r), ("sent", toJson (sent.getD r 0)), ("received", toJson (received.getD r 0))]
  let labelRows := ranked labels
  let sumD := durations.foldl (· + ·) 0
  return Json.mkObj
    [ ("sessions", toJson n), ("events", toJson events)
    , ("ended", toJson ended), ("truncated", toJson truncated), ("stuck", toJson stuck)
    , ("distinctPaths", toJson pathRows.length)
    , ("paths", Json.arr ((pathRows.take maxPaths).map fun (k, c) =>
        Json.mkObj [("path", Json.str k), ("count", toJson c)]).toArray)
    , ("pathsOmitted", toJson (pathRows.length - min pathRows.length maxPaths))
    , ("messages", Json.arr ((labelRows.take maxRows).map fun (k, c) =>
        Json.mkObj [("message", Json.str k), ("count", toJson c), ("sessions", toJson (labelSessions.getD k 0))]).toArray)
    , ("messagesOmitted", toJson (labelRows.length - min labelRows.length maxRows))
    , ("load", Json.arr (roleRows.take maxRows).toArray)
    , ("lengths", Json.mkObj [("unit", "events per session"), ("min", toJson (lengths.min?.getD 0)),
        ("max", toJson (lengths.max?.getD 0)), ("mean", Json.str (decimal2 events n)),
        ("histogram", Json.arr (histogram lengths).toArray)])
    , ("durations", Json.mkObj [("unit", Json.str timeUnit), ("min", toJson (durations.min?.getD 0)),
        ("max", toJson (durations.max?.getD 0)), ("mean", Json.str (decimal2 sumD n)),
        ("histogram", Json.arr (histogram durations).toArray)]) ]

end LeanFM.Session.Dataset
