import LeanFM.Session.Calls

/-!
# Protocol evolution: which roles can change independently (clause selfhost.session.evolution)

When a protocol changes, a deployed system runs a mix of versions for a while. For each role in
both versions, `Global.compat` answers two questions on the composed system itself:

* Can it upgrade first? Its new local type runs with the old local type of every role of the old
  protocol.
* Can it stay behind? Its old local type runs with the new local type of every role of the new
  protocol.

The composed system is explored to every reachable state (`explore`): a message is taken when the
sender may send it and the receiver may receive it there, an event when its role may perform it,
and a role with several choices of its own may commit to one, so a choice nobody else accepts is
found. A state where nothing can happen and some role cannot stop is stuck; the answer is the path
to it and what each role still expects. This is the multiparty question itself, so it accepts
changes that a role-by-role subtyping check would refuse (a Desk that answers Refused at once is
fine when the old Member accepts Refused there).

Negative requirements: a deadlock, a message nobody will accept, and a role left waiting are each
reported with the path to them; only roles of the versions being composed take part; the search is
bounded (`maxStates` states) and says so rather than answering yes when it runs out.
-/

namespace LeanFM.Session
namespace Evolution

/-- A step of a local type: a send (`!`), a receive (`?`) or an event (`#`) of this role. -/
structure Step where
  kind  : Char
  peer  : String
  label : String
  deriving BEq, Inhabited, Repr

def Step.text (s : Step) : String :=
  match s.kind with
  | '!' => s!"send {s.label} to {s.peer}"
  | '?' => s!"receive {s.label} from {s.peer}"
  | _ => s!"{s.label}"

/-- Sends and events are this role's own choice; receives are the others'. -/
def Step.own (s : Step) : Bool := s.kind != '?'

partial def subst (n : String) (body : Local String) : Local String → Local String
  | .var m => if m == n then .loop n body else .var m
  | .loop m b => if m == n then .loop m b else .loop m (subst n body b)
  | .send t l k => .send t l (subst n body k)
  | .recv f l k => .recv f l (subst n body k)
  | .act l k => .act l (subst n body k)
  | .select bs => .select (bs.map (subst n body))
  | .offer bs => .offer (bs.map (subst n body))
  | .par bs k => .par (bs.map (subst n body)) (subst n body k)
  | .join m bs k => .join m (bs.map (subst n body)) (subst n body k)
  | .sessions b k => .sessions (subst n body b) (subst n body k)
  | .done => .done

/-- Whether the role may stop here. -/
partial def nullable : Local String → Bool
  | .done => true
  | .send .. | .recv .. | .act .. | .var _ => false
  | .select bs | .offer bs => bs.any nullable
  | .par bs k => bs.all nullable && nullable k
  | .join n bs k => (bs.filter nullable).length ≥ n && nullable k
  | .loop _ b => nullable b
  | .sessions b k => nullable b && nullable k

/-- Every step the role may take next, with what remains after it. -/
partial def moves (fuel : Nat := 32) : Local String → List (Step × Local String)
  | .send t l k => [({ kind := '!', peer := t, label := l }, k)]
  | .recv f l k => [({ kind := '?', peer := f, label := l }, k)]
  | .act l k => [({ kind := '#', peer := "", label := l }, k)]
  | .select bs | .offer bs => bs.flatMap (moves fuel)
  | .par bs k =>
    let inner := (List.range bs.length).flatMap fun i =>
      (moves fuel bs[i]!).map fun (s, r) => (s, Local.par (bs.set i r) k)
    inner ++ (if bs.all nullable then moves fuel k else [])
  | .join n bs k =>
    let inner := (List.range bs.length).flatMap fun i =>
      (moves fuel bs[i]!).map fun (s, r) => (s, Local.join n (bs.set i r) k)
    let fired := if (bs.filter nullable).length ≥ n then moves fuel (.par (k :: bs.filter (!nullable ·)) .done) else []
    inner ++ fired
  | .loop n b => if fuel == 0 then [] else moves (fuel - 1) (subst n (.loop n b) b)
  | .sessions b k => moves fuel (Typestate.append b k)
  | .var _ | .done => []

def key (l : Local String) : String := l.render

def maxStates : Nat := 5000

structure Failure where
  path   : List String
  reason : String
  deriving Inhabited

def list (ss : List Step) : String := ", ".intercalate (ss.map Step.text)

/-- A role commits to one of its own steps: its local type narrowed to that step. -/
def commit (s : Step) (k : Local String) : Local String :=
  if s.kind == '!' then .send s.peer s.label k else .act s.label k

/-- The steps the composed system can take from `st` (one local type per role), each with a text
for the path: a message both sides take together, an event, or a role committing to one of its
own choices. -/
def transitions (roles : List String) (st : List (Local String)) : List (String × List (Local String)) :=
  (List.range roles.length).flatMap fun i =>
    let me := roles[i]!
    let ms := moves 32 st[i]!
    let own := ms.filter (·.1.own)
    let steps := own.flatMap fun (s, k) =>
      if s.kind == '#' then [(s!"{me}: {s.label}", st.set i k)]
      else match roles.idxOf? s.peer with
        | none => []
        | some j =>
          (moves 32 st[j]!).filterMap fun (r, k2) =>
            if r.kind == '?' && r.peer == me && r.label == s.label
            then some (s!"{me} -> {s.peer}: {s.label}", (st.set i k).set j k2) else none
    let commits := if (own.map (·.1)).eraseDups.length > 1 || (own.length ≥ 1 && own.length < ms.length)
      then own.map fun (s, k) => (s!"{me} chooses to {s.text}", st.set i (commit s k)) else []
    steps ++ commits

/-- Why a state with nothing left to do is stuck: what each role still expects. -/
def stuck (roles : List String) (st : List (Local String)) : String :=
  let parts := (List.range roles.length).filterMap fun i =>
    if nullable st[i]! then none else
    let ms := (moves 32 st[i]!).map (·.1)
    let own := ms.filter (·.own)
    let rest := ms.filter (!·.own)
    let what := (if own.isEmpty then [] else [s!"is stuck trying to {list own.eraseDups}"]) ++
      (if rest.isEmpty then [] else [s!"waits to {list rest.eraseDups}"])
    some s!"{roles[i]!} {" and ".intercalate what}"
  "; ".intercalate parts

/-- Explore every state the composed system can reach; the first stuck one, with its path. -/
partial def explore (roles : List String) (start : List (Local String)) : Except String (Option Failure) := Id.run do
  let keyOf (st : List (Local String)) := "‖".intercalate (st.map key)
  let mut seen : List String := [keyOf start]
  let mut frontier : List (List String × List (Local String)) := [([], start)]
  while !frontier.isEmpty do
    let mut next := []
    for (path, st) in frontier do
      let ts := transitions roles st
      if ts.isEmpty && !(st.all nullable) then
        return .ok (some { path := path.reverse, reason := stuck roles st })
      for (label, st') in ts do
        let k := keyOf st'
        if !seen.contains k then
          if seen.length ≥ maxStates then
            return .error s!"more than {maxStates} states to explore; the check stopped without an answer"
          seen := k :: seen
          next := (label :: path, st') :: next
    frontier := next.reverse
  return .ok none

end Evolution

/-- For one role of two versions of a protocol. -/
structure RoleCompat where
  role : String
  /-- the new version of this role runs with the others' old versions without getting stuck -/
  upgradeFirst : Except String (Option Evolution.Failure)
  /-- the old version of this role runs with the others' new versions without getting stuck -/
  stayBehind : Except String (Option Evolution.Failure)

/-- Each role present in both versions: can it upgrade before the others, and can it stay on the
old version after the others upgrade? Upgrading first runs its new version with the old version of
every role of the old protocol; staying behind runs its old version with the new version of every
role of the new protocol. Each composed system is explored to every reachable state. -/
def Global.compat (new old : Global String) (newRoles oldRoles : List String) : Except String (List RoleCompat) := do
  let ln ← newRoles.mapM fun r => (new.project r).mapError (s!"the new {r}: " ++ ·)
  let lo ← oldRoles.mapM fun r => (old.project r).mapError (s!"the old {r}: " ++ ·)
  let shared := newRoles.filter oldRoles.contains
  pure <| shared.map fun r =>
    let i := oldRoles.idxOf r
    let j := newRoles.idxOf r
    { role := r
      upgradeFirst := Evolution.explore oldRoles (lo.set i ln[j]!)
      stayBehind := Evolution.explore newRoles (ln.set j lo[i]!) }

end LeanFM.Session
