import Lean.Data.Json
import LeanFM.Session.Conform
import LeanFM.Session.Derived

/-!
# Sessions of a real log (clause selfhost.session.log-sessions)

Sessions are parallel copies of the protocol, and their events interleave in any order: two
sessions of `A -> B: msg; B -> A: resp` may be logged msg, msg, resp, resp. A log does not have to
name its sessions; when it does not, they are derived from identity the protocol declares, as
Wireshark follows a TCP stream by its addresses and ports:

* a cause: an answer belongs to its request's session;
* the declared session key (`sessions by a.caller`): events carrying one value of it are one session.

Nothing else joins. A where-clause equation is a condition, not an identity (two unrelated payments
of 10 are not one session), and `prev` orders an actor's own events across every session it takes
part in (B's second resp names its first as prev). An event no join reaches starts a session when
the protocol lets a session start with its message; otherwise the log cannot place it, and it is
unattributed, never guessed.

When every event names a session, the derived sessions are a cross-check: a cause or key value that
joins two events the log puts in different sessions is a problem.
-/

namespace LeanFM.Session.LogSessions
open Lean

def maxSessions : Nat := 200

/-- A key value as text, as conformance compares it with a session name. -/
def shown : Where.Value → String
  | .str t => t
  | .num q => if q.den == 1 then toString q.num else s!"{q.num}/{q.den}"
  | .bool b => toString b

/-- A declared session key: the labels its message id can carry, and its field path. -/
structure Key where
  labels : List String
  field  : String
  deriving Repr, Inhabited

structure Session where
  name        : String
  /-- the positions of its events in the log, in log order -/
  events      : Array Nat
  /-- the session names its events carry in the log (a cross-check; empty when the log names none) -/
  logSessions : List String
  deriving Repr, Inhabited

structure Result where
  sessions     : Array Session
  omitted      : Nat
  unattributed : Array Nat
  /-- each position's derived session name, or none when unattributed -/
  sessionOf    : Array (Option String)
  deriving Repr, Inhabited

/-- The key labels (field=value) an event carries. -/
def keyLabels (keys : List Key) (e : LogEvent) : List (Nat × String × String) :=
  keys.zipIdx.filterMap fun (k, i) =>
    if !k.labels.contains e.label then none
    else (e.fields.lookup k.field).map fun v => (i, k.field, shown v)

/-- Derive the sessions of `evs` (in log order) from causes and declared keys. `starts` are the
labels a session can begin with. `named` says whether the log names sessions (then each session
lists the log sessions its events carry). -/
def derive (evs : Array LogEvent) (keys : List Key) (starts : List String) (named : Bool) : Result := Id.run do
  let n := evs.size
  let mut parent := Array.range n
  let mut first : List ((Nat × String) × Nat) := []
  let mut grown : Array Bool := Array.replicate n false
  for i in [0:n] do
    let e := evs[i]!
    if let some c := e.cause then
      if let some j := evs.findIdx? (·.id == c) then
        if j != i then
          parent := Derived.union parent i j
          grown := (grown.set! i true).set! j true
    for (k, _, v) in keyLabels keys e do
      grown := grown.set! i true
      match first.lookup (k, v) with
      | some j => parent := Derived.union parent i j
      | none => first := ((k, v), i) :: first
  -- groups in order of their first event
  let mut groups : Array (Nat × Array Nat) := #[]
  for i in [0:n] do
    let (r, p') := Derived.find parent i
    parent := p'
    match groups.findIdx? (·.1 == r) with
    | some g => groups := groups.modify g fun (r, xs) => (r, xs.push i)
    | none => groups := groups.push (r, #[i])
  let mut sessions : Array Session := #[]
  let mut unattributed : Array Nat := #[]
  let mut sessionOf : Array (Option String) := Array.replicate n none
  let mut used : List String := []
  for (_, xs) in groups do
    let lone := xs.size == 1 && !grown[xs[0]!]!
    if lone && !starts.contains evs[xs[0]!]!.label then
      unattributed := unattributed.push xs[0]!
      continue
    let labels := (xs.toList.flatMap fun i => (keyLabels keys evs[i]!).map fun (_, f, v) => s!"{f}={v}").eraseDups
    let base := if labels.isEmpty then s!"chain from {evs[xs[0]!]!.id}" else ", ".intercalate labels
    let name := if used.contains base then s!"{base} #{sessions.size + 1}" else base
    used := name :: used
    for i in xs do sessionOf := sessionOf.set! i (some name)
    let logs := if named then (xs.toList.map fun i => evs[i]!.session).eraseDups else []
    sessions := sessions.push { name, events := xs, logSessions := logs }
  return { sessions := sessions.extract 0 maxSessions, omitted := sessions.size - min sessions.size maxSessions,
           unattributed, sessionOf }

/-- For a log that names its sessions: each cause or key value joining two events the log puts in
different sessions, as a problem naming both events, their sessions and the link. -/
def crossCheck (evs : Array LogEvent) (keys : List Key) : List String := Id.run do
  let mut out : List String := []
  let mut first : List ((Nat × String) × Nat) := []
  for i in [0:evs.size] do
    let e := evs[i]!
    if let some c := e.cause then
      if let some d := evs.find? (·.id == c) then
        if d.session != e.session then
          out := out ++ [s!"events {d.id} and {e.id} are one session, because {e.id} names {d.id} as its cause, but the log puts them in sessions {d.session} and {e.session}"]
    for (k, f, v) in keyLabels keys e do
      match first.lookup (k, v) with
      | some j =>
        let d := evs[j]!
        if d.session != e.session then
          out := out ++ [s!"events {d.id} and {e.id} are one session, because both carry the session key {f}={v}, but the log puts them in sessions {d.session} and {e.session}"]
      | none => first := ((k, v), i) :: first
  return out

/-- Each unattributed event as a problem saying why the log cannot place it and how to fix that. -/
def unattributedProblems (evs : Array LogEvent) (r : Result) : List String :=
  r.unattributed.toList.map fun i =>
    let e := evs[i]!
    s!"event {e.id} ({e.label} from {e.src}{if e.isAct then "" else s!" to {e.dst}"}) cannot be placed in a session: it names no cause, carries no session key, and a session cannot start with {e.label}; sessions interleave in any order, so name the message it answers as its cause in the protocol, declare a session key, or log session ids"

/-- The log as session_simulate's stream (events numbered from 1 in log order, links as those
numbers), each event's session its log session or else its derived one. -/
def stream (evs : Array LogEvent) (r : Result) (named : Bool) : Array Json :=
  let pos (id : String) : Option Nat := (evs.findIdx? (·.id == id)).map (· + 1)
  evs.zipIdx.map fun (e, i) =>
    Json.mkObj [("id", toJson (i + 1)), ("logId", Json.str e.id),
      ("session", Json.str (if named then e.session else (r.sessionOf[i]!).getD "unattributed")),
      ("prior", Json.arr ((e.prev.bind pos).toList.map toJson).toArray), ("cause", toJson (e.cause.bind pos)),
      ("src", Json.str e.src), ("dst", Json.str e.dst), ("label", Json.str e.label), ("act", Json.bool e.isAct)]

/-- derivedSessions in session_simulate's shape. -/
def Result.json (r : Result) (named : Bool) : Json :=
  Json.mkObj [
    ("sessions", Json.arr (r.sessions.map fun s => Json.mkObj ([("key", Json.str s.name), ("count", toJson s.events.size),
      ("events", toJson s.events)] ++ (if named then [("logSessions", toJson s.logSessions)] else [])))),
    ("omitted", toJson r.omitted), ("unattributed", toJson r.unattributed),
    ("reading", Json.str (s!"{r.sessions.size + r.omitted} sessions derived from causes and the declared session key" ++
      (if r.unattributed.isEmpty then "" else s!"; {r.unattributed.size} events the log cannot place") ++
      (if named then "; the log's session ids are checked against them" else "; the log names no sessions")))]

end LeanFM.Session.LogSessions
