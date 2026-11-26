import Lean.Data.Json
import Std.Time

/-! Event lines in an ordinary log (clause selfhost.session.event-log).

An event line is one compact JSON object that begins `{"type":"leanFM",`, so a log stays one JSON
object per line for any tool and `grep '^{"type":"leanFM"'` takes its events out. The object is the
event as `session_conform` reads it (`id`, `session`, `label`, and `from`/`to` for a message or `at`
with `act: true` for a role's own event), with `ts` (nanoseconds, a decimal string), `prev`, `cause`
and `protocol`. One event is one line, written in one write of at most `maxLine` bytes, so lines from
threads and processes sharing a file never interleave. `extract` takes the events back out of a log. -/

namespace LeanFM.EventLog
open Lean

/-- The marker field every event line carries, and its value. -/
def typeName : String := "leanFM"

/-- How every event line LeanFM writes begins: the marker first, so a fixed prefix finds it. -/
def prefix_ : String := "{\"type\":\"leanFM\""

/-- The largest event line, newline included: what the operating system writes atomically. -/
def maxLine : Nat := 4096

/-- Where this process writes its event lines: set by a server's main (standard output, or standard
error where standard output carries a protocol), empty elsewhere, so tests write none. -/
initialize sink : IO.Ref (Option IO.FS.Stream) ← IO.mkRef none

/-- This process's events so far, for ids and prev. -/
initialize counter : IO.Ref Nat ← IO.mkRef 0
initialize lastId : IO.Ref (Option String) ← IO.mkRef none
/-- Host events refused and not written (selfhost.session.real-events). -/
initialize droppedHostEvents : IO.Ref Nat ← IO.mkRef 0

/-- Nanoseconds since the Unix epoch now. -/
def nowNs : IO Nat := do
  return (← Std.Time.Timestamp.now).toNanosecondsSinceUnixEpoch.val.toNat

/-- An object written with the marker first: `{"type":"leanFM",` and then its other fields. -/
def withMarker (j : Json) : String :=
  let rest := ((j.getObj?.toOption.map fun o => Json.obj (o.erase "type")).getD j).compress
  if rest == "{}" then prefix_ ++ "}" else prefix_ ++ "," ++ (rest.drop 1).toString

/-- One event line, without the newline: the envelope's fields, then the payload, cut and marked
`truncated` when the line would pass `maxLine`. -/
def line (fields : List (String × Json)) (payload : Json := Json.null) : String :=
  let head := Json.mkObj fields
  let whole := if payload == Json.null then head else head.setObjVal! "payload" payload
  let text := withMarker whole
  if text.utf8ByteSize + 1 ≤ maxLine then text
  else withMarker (head.setObjVal! "truncated" (Json.bool true))

/-- Write one event of `protocol` (and its version, only when the protocol declares versions) on `h`
with a single write, and return its id. `kind` is either a message `(from, to)` or a role's own event
`at`. `ts` defaults to now. -/
def emit (h : IO.FS.Stream) (actor session protocol label : String)
    (kind : Sum (String × String) String) (ts : Option Nat := none) (cause : Option String := none)
    (payload : Json := Json.null) (version : Option Nat := none) : IO String := do
  let n ← counter.modifyGet fun c => (c + 1, c + 1)
  let id := s!"{actor}:{n}"
  let prev ← lastId.get
  let ts ← match ts with | some t => pure t | none => nowNs
  let roles : List (String × Json) := match kind with
    | .inl (f, t) => [("from", Json.str f), ("to", Json.str t)]
    | .inr r => [("at", Json.str r), ("act", Json.bool true)]
  let fields : List (String × Json) :=
    [("ts", Json.str (toString ts)), ("id", Json.str id), ("session", Json.str session), ("label", Json.str label)] ++ roles ++
    (match prev with | some p => [("prev", Json.arr #[Json.str p])] | none => []) ++
    (match cause with | some c => [("cause", Json.str c)] | none => []) ++
    [("protocol", Json.str protocol)] ++ (match version with | some v => [("version", toJson v)] | none => []) ++
    [("actor", Json.str actor)]
  h.putStr (line fields payload ++ "\n")
  h.flush
  lastId.set (some id)
  return id

/-- The events of a log: every line that is a JSON object whose `type` is `leanFM`; every other line,
JSON or not, is not a LeanFM event and is counted and ignored. A line that begins with the marker
prefix but is not such an object with `id` and `label` is an error naming its line number, never
skipped. The marker is dropped from each event, as `session_conform` reads events without it. -/
def extract (log : String) : Except String (Array Json × Nat) := do
  let mut events := #[]
  let mut other := 0
  let mut n := 0
  for raw in log.splitOn "\n" do
    n := n + 1
    let l := (if raw.endsWith "\r" then (raw.dropEnd 1).toString else raw).trimAscii.toString
    if l.isEmpty then continue
    let marked := l.startsWith prefix_
    match Json.parse l with
    | .ok j@(.obj o) =>
      if j.getObjValD "type" == Json.str typeName then
        unless (j.getObjVal? "id").isOk && (j.getObjVal? "label").isOk do
          throw s!"line {n}: a LeanFM event line needs at least id and label"
        events := events.push (Json.obj (o.erase "type"))
      else if marked then throw s!"line {n}: a line that begins {prefix_} must be a LeanFM event"
      else other := other + 1
    | .ok _ =>
      if marked then throw s!"line {n}: a LeanFM event line must be one JSON object"
      other := other + 1
    | .error e =>
      if marked then throw s!"line {n}: a LeanFM event line must be one JSON object: {e}"
      other := other + 1
  return (events, other)

/-- The lines `fromLine` to `fromLine + count - 1` of a log (1-based; all the rest when `count` is
none), with how many lines the whole log has and the line after the window: logs are read by lines,
never by bytes. -/
def window (log : String) (fromLine : Nat) (count : Option Nat) : String × Nat × Nat :=
  let ls := (log.splitOn "\n").toArray
  -- a final newline ends the last line; it does not start another
  let ls := if ls.back? == some "" then ls.pop else ls
  let start := fromLine - 1
  let stop := match count with | some c => min ls.size (start + c) | none => ls.size
  let picked := if start ≥ ls.size then #[] else ls.extract start stop
  ("\n".intercalate picked.toList, ls.size, max fromLine (stop + 1))

end LeanFM.EventLog
