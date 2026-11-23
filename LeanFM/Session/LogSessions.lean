import Lean.Data.Json
import LeanFM.Session.Conform
import LeanFM.Session.Derived
import LeanFM.Session.Types

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
  /-- the session whose id the text binds into this one (selfhost.session.identity.children) -/
  parent      : Option String := none
  /-- every parent: one for a child, two or more for a join (selfhost.session.identity.joins) -/
  parents     : List String := []
  deriving Repr, Inhabited

structure Result where
  sessions     : Array Session
  omitted      : Nat
  unattributed : Array Nat
  /-- each position's derived session name, or none when unattributed -/
  sessionOf    : Array (Option String)
  /-- per-value problems with the identity marks (selfhost.session.identity.checks) -/
  problems     : Array String := #[]
  deriving Repr, Inhabited

/-- A marked field: the label whose structure carries it, its name, and its mark. -/
structure Marked where
  label : String
  field : String
  mark  : Types.Mark
  /-- the Fresh field a Link names: its own name, or the field an include binds it to
  (selfhost.session.identity.scopes) -/
  target : String := field
  /-- a Link the field's protocol is given by an include: it names the parent session, never joins it
  (selfhost.session.identity.children) -/
  parent : Bool := false
  deriving Repr, Inhabited

/-- The key labels (field=value) an event carries. -/
def keyLabels (keys : List Key) (e : LogEvent) : List (Nat × String × String) :=
  keys.zipIdx.filterMap fun (k, i) =>
    if !k.labels.contains e.label then none
    else (e.fields.lookup k.field).map fun v => (i, k.field, shown v)

/-- Derive the sessions of `evs` (in log order) from causes and declared keys. `starts` are the
labels a session can begin with. `named` says whether the log names sessions (then each session
lists the log sessions its events carry). -/
def derive (evs : Array LogEvent) (keys : List Key) (starts : List String) (named : Bool)
    (marked : List Marked := []) (terminated : List LogEvent → Bool := fun _ => false) : Result := Id.run do
  let n := evs.size
  let mut parent := Array.range n
  let mut first : List ((Nat × String) × Nat) := []
  let mut grown : Array Bool := Array.replicate n false
  -- each live (field, value) and the position that minted it (selfhost.session.identity.checks)
  let mut live : List ((String × String) × Nat) := []
  let mut problems : Array String := #[]
  -- each parent Link: (position, the position that minted its value, field, value)
  let mut parentRefs : Array (Nat × Nat × String × String) := #[]
  for i in [0:n] do
    let e := evs[i]!
    if let some c := e.cause then
      if let some j := evs.findIdx? (·.id == c) then
        if j != i then
          parent := Derived.union parent i j
          grown := (grown.set! i true).set! j true
    -- the events of the session holding position j, before position i
    let sessionBefore (parent : Array Nat) (j : Nat) : List LogEvent :=
      let r := (Derived.find parent j).1
      ((List.range i).filter fun k => (Derived.find parent k).1 == r).map (evs[·]!)
    -- a key value is an id its session minted: once that session has terminated it is freed, and
    -- the next event carrying it starts a new session (selfhost.session.identity.scopes)
    for (k, _, v) in keyLabels keys e do
      grown := grown.set! i true
      match first.lookup (k, v) with
      | some j =>
        if terminated (sessionBefore parent j) then first := ((k, v), i) :: first.filter (·.1 != (k, v))
        else parent := Derived.union parent i j
      | none => first := ((k, v), i) :: first
    let valuesOf (m : Types.Mark) : List (String × String) :=
      (marked.filter fun x => x.label == e.label && x.mark == m && !x.parent).filterMap fun x =>
        (e.fields.lookup x.field).map fun v => (if m == .link then x.target else x.field, shown v)
    -- a given Link names the parent: checked live as every Link is, recorded, never joined
    for x in marked.filter fun x => x.label == e.label && x.mark == .link && x.parent do
      if let some val := e.fields.lookup x.field then
        let v := shown val
        grown := grown.set! i true
        match live.lookup (x.target, v) with
        | some j =>
          if terminated (sessionBefore parent j) then
            live := live.filter (·.1 != (x.target, v))
            problems := problems.push s!"event {e.id} ({e.label}) carries the Link {x.target}={v}, but no live session minted {x.target}={v}: it was never minted, or its session has ended and freed it"
          else parentRefs := parentRefs.push (i, j, x.field, v)
        | none => problems := problems.push s!"event {e.id} ({e.label}) carries the Link {x.target}={v}, but no live session minted {x.target}={v}: it was never minted, or its session has ended and freed it"
    -- a Link joins the live session that minted its value; two different sessions are a join;
    -- a session that has terminated has freed its value, so it no longer names it
    let mut roots : List (Nat × String × String) := []
    for (f, v) in valuesOf .link do
      grown := grown.set! i true
      match live.lookup (f, v) with
      | some j =>
        if terminated (sessionBefore parent j) then
          live := live.filter (·.1 != (f, v))
          problems := problems.push s!"event {e.id} ({e.label}) carries the Link {f}={v}, but no live session minted {f}={v}: it was never minted, or its session has ended and freed it"
        else
          let (r, p') := Derived.find parent j
          parent := p'
          unless roots.any (·.1 == r) do roots := roots ++ [(r, f, v)]
      | none => problems := problems.push s!"event {e.id} ({e.label}) carries the Link {f}={v}, but no live session minted {f}={v}: it was never minted, or its session has ended and freed it"
    match roots with
    | [(r, _, _)] => parent := Derived.union parent i r
    | (_ :: _ :: _) => problems := problems.push s!"event {e.id} ({e.label}) links {" and ".intercalate (roots.map fun (_, f, v) => s!"{f}={v}")}, which are different live sessions: a join, which the session graph represents (selfhost.session.identity.graph), so it is not merged into either"
    | [] => pure ()
    -- a Fresh value starts a session; minted again while that session is live, it is a problem;
    -- once its session has terminated the value is freed and starts a new one
    for (f, v) in valuesOf .fresh do
      grown := grown.set! i true
      match live.lookup (f, v) with
      | some j =>
        if terminated (sessionBefore parent j) then live := ((f, v), i) :: live.filter (·.1 != (f, v))
        else problems := problems.push s!"event {e.id} ({e.label}) mints {f}={v} again while the session {evs[j]!.id} minted it is still live: a session id is unique among open sessions"
      | none => live := ((f, v), i) :: live
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
  let mut nameOf : List (Nat × String) := []
  for (root, xs) in groups do
    let lone := xs.size == 1 && !grown[xs[0]!]!
    if lone && !starts.contains evs[xs[0]!]!.label then
      unattributed := unattributed.push xs[0]!
      continue
    let labels := (xs.toList.flatMap fun i => (keyLabels keys evs[i]!).map fun (_, f, v) => s!"{f}={v}").eraseDups
    let base := if labels.isEmpty then s!"chain from {evs[xs[0]!]!.id}" else ", ".intercalate labels
    let name := if used.contains base then s!"{base} #{sessions.size + 1}" else base
    used := name :: used
    nameOf := (root, name) :: nameOf
    for i in xs do sessionOf := sessionOf.set! i (some name)
    let logs := if named then (xs.toList.map fun i => evs[i]!.session).eraseDups else []
    sessions := sessions.push { name, events := xs, logSessions := logs }
  -- each session's parent: the sessions its given Links name (selfhost.session.identity.children)
  let rootOf (p : Array Nat) (i : Nat) : Nat := (Derived.find p i).1
  for si in [0:sessions.size] do
    let s := sessions[si]!
    let refs := parentRefs.toList.filter fun (i, _, _, _) => s.events.contains i
    let named := refs.map fun (i, j, f, v) => (i, (nameOf.lookup (rootOf parent j)).getD evs[j]!.id, f, v)
    -- one field naming two sessions is a problem; different fields naming different sessions are a
    -- join, which the include wrote by binding both (selfhost.session.identity.joins)
    let fieldsInOrder := (named.map fun (_, _, f, _) => f).eraseDups
    let mut parents : List String := []
    for fld in fieldsInOrder do
      let mine := named.filter fun (_, _, f, _) => f == fld
      match mine with
      | [] => pure ()
      | (_, p, _, _) :: _ =>
        unless parents.contains p do parents := parents ++ [p]
        for (i, q, f, v) in mine do
          if q != p then
            problems := problems.push s!"event {evs[i]!.id} ({evs[i]!.label}) carries {f}={v}, naming session {q} as its parent, but its session {s.name} is a child of {p}: a task's parent is the session whose id the include binds, so one task cannot belong to two"
    unless parents.isEmpty do
      sessions := sessions.set! si { s with parent := parents.head?, parents }
  return { sessions := sessions.extract 0 maxSessions, omitted := sessions.size - min sessions.size maxSessions,
           unattributed, sessionOf, problems }

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
    let session := if named then e.session else (r.sessionOf[i]!).getD "unattributed"
    Json.mkObj [("id", toJson (i + 1)), ("logId", Json.str e.id),
      ("session", Json.str session),
      -- the thread: the actor that sent it, whose own order its prev links make (selfhost.mcp.session.view)
      ("thread", Json.str (if e.srcActor.isEmpty then s!"{e.src}@{session}" else e.srcActor)),
      -- the actors, so each instance is its own lifeline (selfhost.mcp.session.view)
      ("srcActor", Json.str (if e.srcActor.isEmpty then e.src else e.srcActor)),
      ("dstActor", Json.str (if e.dstActor.isEmpty then e.dst else e.dstActor)),
      ("prior", Json.arr ((e.prev.bind pos).toList.map toJson).toArray), ("cause", toJson (e.cause.bind pos)),
      ("src", Json.str e.src), ("dst", Json.str e.dst), ("label", Json.str e.label), ("act", Json.bool e.isAct)]

/-- derivedSessions in session_simulate's shape. -/
def Result.json (r : Result) (named : Bool) : Json :=
  Json.mkObj [
    ("sessions", Json.arr (r.sessions.map fun s => Json.mkObj ([("key", Json.str s.name), ("count", toJson s.events.size),
      ("events", toJson s.events)] ++ (if named then [("logSessions", toJson s.logSessions)] else []) ++
      (s.parent.map fun p => [("parent", Json.str p)]).getD [] ++
      (if s.parents.length > 1 then [("parents", toJson s.parents)] else [])))),
    ("omitted", toJson r.omitted), ("unattributed", toJson r.unattributed),
    ("reading", Json.str (s!"{r.sessions.size + r.omitted} sessions derived from causes and the declared session key" ++
      (if r.unattributed.isEmpty then "" else s!"; {r.unattributed.size} events the log cannot place") ++
      (if named then "; the log's session ids are checked against them" else "; the log names no sessions")))]

end LeanFM.Session.LogSessions
