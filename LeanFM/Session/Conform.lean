import LeanFM.Session.Global
import LeanFM.Session.Where

/-!
# Conformance: does a recorded run follow the protocol? (clause selfhost.session.conform)

A program built from a session type logs one event per message it sends or event it performs:
an id, a session, the sender and receiver (or the role, for an event), the label, and the event that
caused it. `Global.conforms` checks every session of such a log against the protocol, by derivatives
of the global type: after each event, the set of protocol states that could explain the run so far.

* Order: an event must be one the protocol allows next; `par` branches interleave, a `choice` is
  settled by the first event that only one branch allows, `rec` repeats, `include` is inlined.
* Causes: when the protocol says `cause y`, the event's cause must be the event that was `y` in the
  same session.
* Completion: a session is complete when the protocol can end where its events stop; a log taken
  while sessions are running can ask for incomplete sessions to be allowed.
* `sessions { body }` at the top: each session id is one instance of the body.

Negative requirements: an event the protocol does not allow at that point, a wrong label, sender,
receiver or cause, a duplicated event id, or a cause that is not an earlier event of the same session
is reported, with the event and what the protocol allowed instead; a session that stops early is
reported unless incomplete sessions were asked for; the search is bounded (at most 512 states per
session) and says so rather than accepting when it overflows.
-/

namespace LeanFM.Session

/-- The same protocol over other role names, such as a typed protocol over the names of its roles. -/
partial def Global.mapRoles {R S : Type} (f : R → S) : Global R → Global S
  | .msg i k =>
    let j : Interaction S := { id := i.id, label := i.label, src := f i.src, dst := f i.dst, cause := i.cause, status := i.status, route := i.route, guard := i.guard }
    .msg j (k.mapRoles f)
  | .act r l k => .act (f r) l (k.mapRoles f)
  | .choice bs => .choice (bs.map (·.mapRoles f))
  | .par bs k => .par (bs.map (·.mapRoles f)) (k.mapRoles f)
  | .join n bs k => .join n (bs.map (·.mapRoles f)) (k.mapRoles f)
  | .loop n b => .loop n (b.mapRoles f)
  | .var n => .var n
  | .sessions b k => .sessions (b.mapRoles f) (k.mapRoles f)
  | .box n b k => .box n (b.mapRoles f) (k.mapRoles f)
  | .done => .done

/-- One logged event. `cause` is the id of the event that caused it. -/
structure LogEvent where
  id      : String
  session : String := "0"
  src     : String
  dst     : String
  label   : String
  cause   : Option String := none
  isAct   : Bool := false
  /-- the payload fields a where condition may read, nested keys dotted (selfhost.session.where) -/
  fields  : List (String × Where.Value) := []
  deriving Repr, Inhabited, BEq

namespace Conform

/-- A protocol state with the events bound to the protocol's message ids so far. -/
structure State where
  g    : Global String
  bind : List (String × String)
  /-- conditions that could not be decided on the way here: (event id, why); not part of the key -/
  unchecked : List (String × String) := []
  deriving Inhabited

partial def subst (n : String) (body : Global String) : Global String → Global String
  | .var m => if m == n then .loop n body else .var m
  | .loop m b => if m == n then .loop m b else .loop m (subst n body b)
  | .msg i k => .msg i (subst n body k)
  | .act r l k => .act r l (subst n body k)
  | .choice bs => .choice (bs.map (subst n body))
  | .par bs k => .par (bs.map (subst n body)) (subst n body k)
  | .join k bs c => .join k (bs.map (subst n body)) (subst n body c)
  | .sessions b k => .sessions (subst n body b) (subst n body k)
  | .box m b k => .box m (subst n body b) (subst n body k)
  | .done => .done

/-- Whether the protocol can end here without another event. -/
partial def nullable : Global String → Bool
  | .done => true
  | .msg _ _ | .act _ _ _ | .var _ => false
  | .choice bs => bs.any nullable
  | .par bs k => bs.all nullable && nullable k
  | .join n bs k => (bs.filter nullable).length ≥ n && nullable k
  | .loop _ b => nullable b
  | .sessions _ k => nullable k
  | .box _ b k => nullable b && nullable k

/-- A text key for a state, to drop duplicates. -/
partial def key : Global String → String
  | .done => "."
  | .msg i k => s!"m({i.id.getD ""},{i.label},{i.src},{i.dst},{i.cause.getD ""}){key k}"
  | .act r l k => s!"a({r},{l}){key k}"
  | .choice bs => "c[" ++ ",".intercalate (bs.map key) ++ "]"
  | .par bs k => "p[" ++ ",".intercalate (bs.map key) ++ "]" ++ key k
  | .join n bs k => s!"j{n}[" ++ ",".intercalate (bs.map key) ++ "]" ++ key k
  | .loop n b => s!"l({n})" ++ key b
  | .var n => s!"v({n})"
  | .sessions b k => "s[" ++ key b ++ "]" ++ key k
  | .box n b k => s!"b({n})[" ++ key b ++ "]" ++ key k

def stateKey (s : State) : String := key s.g ++ "|" ++ toString (s.bind.map fun (a, b) => a ++ "=" ++ b)

/-- What the protocol allows next, for messages. -/
partial def heads (fuel : Nat := 32) : Global String → List String
  | .msg i _ => [s!"{i.label} from {i.src} to {i.dst}"]
  | .act r l _ => [s!"{l} at {r}"]
  | .choice bs => bs.flatMap (heads fuel)
  | .par bs k => bs.flatMap (heads fuel) ++ (if bs.all nullable then heads fuel k else [])
  | .join n bs k => bs.flatMap (heads fuel) ++ (if (bs.filter nullable).length ≥ n then heads fuel k else [])
  | .loop n b => if fuel == 0 then [] else heads (fuel - 1) (subst n (.loop n b) b)
  | .sessions _ k => heads fuel k
  | .box _ b k => heads fuel (Global.andThen b k)
  | .var _ | .done => []

/-- The states after one event. With `ignoreCause`, causes are not compared (used only to say
whether an event fits apart from its cause). -/
partial def step (e : LogEvent) (fuel : Nat) (ignoreCause : Bool) (s : State)
    (look : String → Option (List (String × Where.Value)) := fun _ => none) (ignoreGuard : Bool := true) : List State :=
  let causeOk (c : Option String) : Bool :=
    match c with
    | none => true
    | some y => ignoreCause || match s.bind.lookup y with
      | some ev => e.cause == some ev
      | none => false
  let bindId (id : Option String) : List (String × String) :=
    match id with | some x => (x, e.id) :: s.bind.filter (·.1 != x) | none => s.bind
  let go := fun st => step e fuel ignoreCause st look ignoreGuard
  match s.g with
  | .done | .var _ => []
  | .msg i k =>
    if !e.isAct && i.label == e.label && i.src == e.src && i.dst == e.dst && causeOk i.cause then
      let moved : State := { s with g := k, bind := bindId i.id }
      match i.guard, ignoreGuard with
      | some gd, false =>
        -- the message itself and the session's earlier named messages, with their logged fields
        let scope : String → Option (List (String × Where.Value)) := fun x =>
          if i.id == some x then some e.fields else (s.bind.lookup x).bind look
        match Where.run gd.text scope with
        | .yes => [moved]
        | .no => []
        | .unknown why => [{ moved with unchecked := s.unchecked ++ [(e.id, s!"where {gd.text}: {why}")] }]
      | _, _ => [moved]
    else []
  | .act r l k => if e.isAct && l == e.label && r == e.src then [{ s with g := k }] else []
  | .choice bs => bs.flatMap fun b => go { s with g := b }
  | .par bs k =>
    let moves := (List.range bs.length).flatMap fun idx =>
      (go { s with g := bs[idx]! }).map fun r => { r with g := .par (bs.set idx r.g) k }
    moves ++ (if bs.all nullable then go { s with g := k } else [])
  | .join n bs k =>
    let moves := (List.range bs.length).flatMap fun idx =>
      (go { s with g := bs[idx]! }).map fun r => { r with g := .join n (bs.set idx r.g) k }
    -- once n branches are done, what follows runs beside the branches still going: nothing cancels
    let fired := if (bs.filter nullable).length ≥ n
      then go { s with g := .par (k :: bs.filter (!nullable ·)) .done } else []
    moves ++ fired
  | .loop n b => if fuel == 0 then [] else step e (fuel - 1) ignoreCause { s with g := subst n (.loop n b) b } look ignoreGuard
  | .sessions _ k => go { s with g := k }  -- nested instances belong to other session ids
  | .box _ b k => go { s with g := Global.andThen b k }

/-- The where conditions of the messages at the head of `g` that `e` matches by label, roles and
cause: the guards that turned it away when nothing else matched. -/
partial def guardsAt (e : LogEvent) (fuel : Nat) (s : State) : List (String × Option String) :=
  let go := fun (g : Global String) => guardsAt e fuel { s with g }
  match s.g with
  | .msg i _ =>
    if !e.isAct && i.label == e.label && i.src == e.src && i.dst == e.dst then
      match i.guard with | some gd => [(gd.text, i.id)] | none => []
    else []
  | .choice bs => bs.flatMap go
  | .par bs k => bs.flatMap go ++ (if bs.all nullable then go k else [])
  | .join n bs k => bs.flatMap go ++ (if (bs.filter nullable).length ≥ n then go k else [])
  | .loop n b => if fuel == 0 then [] else guardsAt e (fuel - 1) { s with g := subst n (.loop n b) b }
  | .sessions _ k => go k
  | .box _ b k => go (Global.andThen b k)
  | _ => []

def maxStates : Nat := 512

structure SessionResult where
  session  : String
  events   : Nat
  complete : Bool
  /-- the first problem: the event's id and what went wrong -/
  problem  : Option (String × String)
  /-- where conditions that could not be decided: (event id, why) -/
  unchecked : List (String × String) := []
  deriving Repr

def checkSession (g : Global String) (sid : String) (evs : List LogEvent) (allowIncomplete : Bool) :
    SessionResult := Id.run do
  let mut states : List State := [{ g, bind := [] }]
  let mut seen : List String := []
  let mut count := 0
  for e in evs do
    if seen.contains e.id then
      return { session := sid, events := count, complete := false, problem := some (e.id, s!"event id {e.id} appears twice") }
    if let some c := e.cause then
      if !seen.contains c then
        return { session := sid, events := count, complete := false,
                 problem := some (e.id, s!"{e.label}'s cause {c} is not an earlier event of session {sid}") }
    let look : String → Option (List (String × Where.Value)) := fun x => (evs.find? (·.id == x)).map (·.fields)
    let next := states.flatMap fun st => step e 64 false st look false
    let next := next.foldl (fun acc st => if acc.any (stateKey · == stateKey st) then acc else acc ++ [st]) []
    if next.isEmpty && !(states.flatMap (step e 64 false)).isEmpty then
      -- it fits a message whose where condition is false: name the condition and what it read
      let why := (states.flatMap fun st => (guardsAt e 64 st).map fun (text, mid) =>
        let scope : String → Option (List (String × Where.Value)) := fun x =>
          if mid == some x then some e.fields else (st.bind.lookup x).bind look
        let read := Where.readings text scope
        s!"where {text} is false" ++ (if read.isEmpty then "" else s!": {read}")).eraseDups
      return { session := sid, events := count, complete := false,
               problem := some (e.id, s!"{e.label} from {e.src} to {e.dst} breaks its condition: " ++ "; ".intercalate why) }
    if next.isEmpty then
      let allowed := (states.flatMap fun st => heads 32 st.g).eraseDups
      let what := if e.isAct then s!"{e.label} at {e.src}" else s!"{e.label} from {e.src} to {e.dst}"
      let causeNote := if (states.flatMap (step e 64 true)).isEmpty
        then "" else " (its label and roles fit, but its cause does not)"
      let allowedText := if allowed.isEmpty then "nothing: the protocol has ended" else ", ".intercalate allowed
      return { session := sid, events := count, complete := false,
               problem := some (e.id, s!"{what} is not allowed here{causeNote}; the protocol allows {allowedText}") }
    if next.length > maxStates then
      return { session := sid, events := count, complete := false,
               problem := some (e.id, s!"more than {maxStates} protocol states explain this run; the check stopped without accepting it") }
    states := next
    seen := e.id :: seen
    count := count + 1
  let complete := states.any (nullable ·.g)
  let unchecked := ((states.find? (nullable ·.g)).getD (states.headD default)).unchecked
  if complete || allowIncomplete then
    return { session := sid, events := count, complete, problem := none, unchecked }
  let allowed := (states.flatMap fun st => heads 32 st.g).eraseDups
  return { session := sid, events := count, complete := false,
           problem := some ((evs.getLast?.map (·.id)).getD "", s!"the session stops early; the protocol still expects {", ".intercalate allowed}") }

/-- One step a protocol allows next: a message, with the event its cause must name, or an event. -/
structure NextStep where
  label : String
  src   : String
  /-- the receiver; for an event, the role that performs it -/
  dst   : String
  isAct : Bool := false
  /-- the id of the earlier event this step must give as its cause, when the protocol names one -/
  cause : Option String := none
  deriving Repr, BEq, Inhabited

/-- The steps a protocol state allows next, with causes resolved through the run's bindings. -/
partial def nextOf (bind : List (String × String)) (fuel : Nat := 32) : Global String → List NextStep
  | .msg i _ => [{ label := i.label, src := i.src, dst := i.dst, cause := i.cause.bind (fun y => bind.lookup y) }]
  | .act r l _ => [{ label := l, src := r, dst := r, isAct := true }]
  | .choice bs => bs.flatMap (nextOf bind fuel)
  | .par bs k => bs.flatMap (nextOf bind fuel) ++ (if bs.all nullable then nextOf bind fuel k else [])
  | .join n bs k => bs.flatMap (nextOf bind fuel) ++ (if (bs.filter nullable).length ≥ n then nextOf bind fuel k else [])
  | .loop n b => if fuel == 0 then [] else nextOf bind (fuel - 1) (subst n (.loop n b) b)
  | .sessions _ k => nextOf bind fuel k
  | .box _ b k => nextOf bind fuel (Global.andThen b k)
  | .var _ | .done => []

/-- Nested `sessions` blocks taken as one instance each, in place. -/
partial def inlineNested : Global String → Global String
  | .msg i k => .msg i (inlineNested k)
  | .act a l k => .act a l (inlineNested k)
  | .choice bs => .choice (bs.map inlineNested)
  | .par bs k => .par (bs.map inlineNested) (inlineNested k)
  | .join n bs k => .join n (bs.map inlineNested) (inlineNested k)
  | .loop n b => .loop n (inlineNested b)
  | .var n => .var n
  | .sessions b k => Global.andThen (inlineNested b) (inlineNested k)
  | .box n b k => .box n (inlineNested b) (inlineNested k)
  | .done => .done

/-- The protocol states that explain a run of one session, or the first problem with it. -/
def statesAfter (g : Global String) (evs : List LogEvent) : Except String (List State) := do
  let r := checkSession g "walk" evs true
  if let some (e, why) := r.problem then throw s!"event {e}: {why}"
  let mut states : List State := [{ g, bind := [] }]
  for e in evs do
    let next := states.flatMap (step e 64 false)
    states := next.foldl (fun acc st => if acc.any (stateKey · == stateKey st) then acc else acc ++ [st]) []
  return states

end Conform

/-- What may happen next in one session after `log` (its events, in order): every step some state
that explains the run allows, and whether the session may end here. With `sessions { body }` at the
top the session is one instance of the body; nested `sessions` blocks are played once, in place. A run the protocol does not allow is an error naming
its first problem. -/
def Global.next (g : Global String) (log : List LogEvent) : Except String (List Conform.NextStep × Bool) := do
  let body := match g with | .sessions b _ => b | other => other
  -- a walk plays one instance of each nested sessions block where it happens (a service's own
  -- session, such as sending a text), so the steps of services appear in the walk too
  let body := Conform.inlineNested body
  let states ← Conform.statesAfter body log
  let steps := (states.flatMap fun st => Conform.nextOf st.bind 32 st.g).eraseDups
  return (steps, states.any (Conform.nullable ·.g))

/-- One session of a protocol as a state graph, for temporal properties: the states conformance
explores (residual global types with their bindings, nested `sessions` played once in place), every
step between them, and the states where the session may end. At most `maxNodes` states. -/
structure StateGraph where
  states    : List String
  terminals : List String
  /-- source, target, step -/
  edges     : List (String × String × Conform.NextStep)

def Global.stateGraph (g : Global String) (maxNodes : Nat := 2000) : Except String StateGraph := Id.run do
  let body := Conform.inlineNested (match g with | .sessions b _ => b | other => other)
  let keyOf (st : Conform.State) := Conform.key st.g ++ "|" ++ toString (st.bind.map (·.1))
  let mut names : List (String × String) := [(keyOf { g := body, bind := [] }, "s0")]
  let mut queue : List Conform.State := [{ g := body, bind := [] }]
  let mut edges : List (String × String × Conform.NextStep) := []
  let mut terminals : List String := []
  let mut fresh := 0
  while !queue.isEmpty do
    let st := queue.head!
    queue := queue.tail!
    let src := (names.lookup (keyOf st)).getD "?"
    if Conform.nullable st.g then terminals := terminals ++ [src]
    for n in (Conform.nextOf st.bind 32 st.g).eraseDups do
      fresh := fresh + 1
      let e : LogEvent := { id := s!"g{fresh}", src := n.src, dst := n.dst, label := n.label, cause := n.cause, isAct := n.isAct }
      for st' in Conform.step e 64 false st do
        let k := keyOf st'
        let dst ← match names.lookup k with
          | some d => pure d
          | none =>
            if names.length ≥ maxNodes then
              return .error s!"more than {maxNodes} protocol states; the property was not checked"
            let d := s!"s{names.length}"
            names := names ++ [(k, d)]
            queue := queue ++ [st']
            pure d
        if !edges.any (fun (a, b, m) => a == src && b == dst && m == n) then
          edges := edges ++ [(src, dst, n)]
  return .ok { states := names.map (·.2), terminals, edges }

/-- Check a log against the protocol, session by session, in the order sessions first appear.
With `sessions { body }` at the top, each session is checked against the body, or, when it does
not fit the body, against a `sessions` block nested in it (a service's own session). -/
def Global.conforms (g : Global String) (log : List LogEvent) (allowIncomplete := false) :
    List Conform.SessionResult :=
  let body := match g with | .sessions b _ => b | other => other
  -- a session of a nested sessions block (a service's own session) is checked against that block
  let nested := Global.nestedSessions body
  let ids := (log.map (·.session)).eraseDups
  ids.map fun sid =>
    let evs := log.filter (·.session == sid)
    let top := Conform.checkSession body sid evs allowIncomplete
    if top.problem.isNone then top else
      match nested.findSome? (fun b =>
          let r := Conform.checkSession b sid evs allowIncomplete
          if r.problem.isNone then some r else none) with
      | some r => r
      | none => top

end LeanFM.Session
