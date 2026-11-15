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
def maxEvents : Nat := 1000000
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

/-- Values counted into at most `maxBuckets` ranges of equal width; each value once. Counted with a
table, so 10000 values cost 10000 steps, not their square. -/
def histogram (vals : Array Nat) : List Json := Id.run do
  if vals.isEmpty then return []
  let lo := vals.foldl min vals[0]!
  let hi := vals.foldl max vals[0]!
  let mut counts : Std.HashMap Nat Nat := {}
  for v in vals do counts := counts.insert v (counts.getD v 0 + 1)
  if counts.size ≤ maxBuckets then
    let ks := (counts.toList.map (·.1)).toArray.qsort (· < ·)
    return ks.toList.map fun k => Json.mkObj [("from", toJson k), ("to", toJson k), ("count", toJson (counts.getD k 0))]
  let width := (hi - lo) / maxBuckets + 1
  let mut buckets : Array Nat := Array.replicate maxBuckets 0
  for v in vals do
    let b := min (maxBuckets - 1) ((v - lo) / width)
    buckets := buckets.modify b (· + 1)
  return (List.range maxBuckets).filterMap fun b =>
    let a := lo + b * width
    if a > hi then none else
    some (Json.mkObj [("from", toJson a), ("to", toJson (min (a + width - 1) hi)), ("count", toJson buckets[b]!)])

/-- The counts of a dataset so far: each session is added as it is generated and then dropped, so
memory grows with the distinct paths and messages, not with the events. -/
structure Acc where
  sessions : Nat := 0
  events : Nat := 0
  ended : Nat := 0
  truncated : Nat := 0
  paths : Std.HashMap String Nat := {}
  labels : Std.HashMap String Nat := {}
  labelSessions : Std.HashMap String Nat := {}
  sent : Std.HashMap String Nat := {}
  received : Std.HashMap String Nat := {}
  lengths : Array Nat := #[]
  durations : Array Nat := #[]

def Acc.add (a : Acc) (r : Run) : Acc := Id.run do
  let mut a := a
  let key := pathKey r
  a := { a with paths := a.paths.insert key (a.paths.getD key 0 + 1) }
  let mut seen : Std.HashMap String Unit := {}
  let mut lo := 0
  let mut hi := 0
  let mut first := true
  for s in r.steps do
    let lk := if s.isAct then s!"{s.label} at {s.src}" else s!"{s.label} from {s.src} to {s.dst}"
    a := { a with events := a.events + 1, labels := a.labels.insert lk (a.labels.getD lk 0 + 1),
                  sent := a.sent.insert s.src (a.sent.getD s.src 0 + 1) }
    if !s.isAct then a := { a with received := a.received.insert s.dst (a.received.getD s.dst 0 + 1) }
    if !seen.contains lk then
      seen := seen.insert lk ()
      a := { a with labelSessions := a.labelSessions.insert lk (a.labelSessions.getD lk 0 + 1) }
    if first then lo := s.time; hi := s.time; first := false
    else lo := min lo s.time; hi := max hi s.time
  return { a with sessions := a.sessions + 1, ended := a.ended + (if r.ended then 1 else 0),
                  truncated := a.truncated + (if r.truncated then 1 else 0),
                  lengths := a.lengths.push r.steps.size, durations := a.durations.push (hi - lo) }

/-- How the sessions are distributed: over paths, messages, roles, lengths and durations.
`timeUnit` is "ms" for sessions from a probability layer and "steps" for walks. -/
def Acc.summary (a : Acc) (timeUnit : String) : Json :=
  let n := a.sessions
  let pathRows := ranked a.paths
  let roles := (a.sent.toList.map (·.1) ++ a.received.toList.map (·.1)).eraseDups
  let roleRows := (roles.toArray.qsort (· < ·)).toList.map fun r =>
    Json.mkObj [("role", Json.str r), ("sent", toJson (a.sent.getD r 0)), ("received", toJson (a.received.getD r 0))]
  let labelRows := ranked a.labels
  let sumD := a.durations.foldl (· + ·) 0
  let mn (xs : Array Nat) : Nat := xs.foldl min (xs[0]?.getD 0)
  let mx (xs : Array Nat) : Nat := xs.foldl max 0
  -- with parallel branches nearly every session interleaves in its own order: say so, so the
  -- path chart is not read as a distribution of outcomes
  let pathsNote := if n > 1 && pathRows.length * 10 ≥ n * 9
    then "almost every session took its own order (parallel branches interleave), so compare the messages rather than the paths"
    else ""
  Json.mkObj
    [ ("sessions", toJson n), ("events", toJson a.events)
    , ("ended", toJson a.ended), ("truncated", toJson a.truncated), ("stuck", toJson (n - a.ended - a.truncated))
    , ("distinctPaths", toJson pathRows.length), ("pathsNote", Json.str pathsNote)
    , ("paths", Json.arr ((pathRows.take maxPaths).map fun (k, c) =>
        Json.mkObj [("path", Json.str k), ("count", toJson c)]).toArray)
    , ("pathsOmitted", toJson (pathRows.length - min pathRows.length maxPaths))
    , ("messages", Json.arr ((labelRows.take maxRows).map fun (k, c) =>
        Json.mkObj [("message", Json.str k), ("count", toJson c), ("sessions", toJson (a.labelSessions.getD k 0))]).toArray)
    , ("messagesOmitted", toJson (labelRows.length - min labelRows.length maxRows))
    , ("load", Json.arr (roleRows.take maxRows).toArray)
    , ("lengths", Json.mkObj [("unit", "events per session"), ("min", toJson (mn a.lengths)),
        ("max", toJson (mx a.lengths)), ("mean", Json.str (decimal2 a.events n)),
        ("histogram", Json.arr (histogram a.lengths).toArray)])
    , ("durations", Json.mkObj [("unit", Json.str timeUnit), ("min", toJson (mn a.durations)),
        ("max", toJson (mx a.durations)), ("mean", Json.str (decimal2 sumD n)),
        ("histogram", Json.arr (histogram a.durations).toArray)]) ]

def summary (runs : Array Run) (timeUnit : String) : Json :=
  (runs.foldl Acc.add {}).summary timeUnit

/-- `sessions` walks, each added to the counts as it is made and then dropped, refusing more than
`maxEvents` in all. -/
def walkCounts (g : Global String) (seed sessions : Nat) (bound : Nat := maxEvents) : Except String Acc := do
  if sessions == 0 || sessions > maxSessions then throw s!"sessions must be 1 to {maxSessions}"
  let mut a : Acc := {}
  for i in [0:sessions] do
    let (r, _) := walk g (sessionSeed seed i)
    if a.events + r.steps.size > bound then
      throw s!"the dataset would exceed {bound} events after {a.sessions} sessions; ask for fewer sessions"
    a := a.add r
  return a

end LeanFM.Session.Dataset
