import LeanFM.Session.Global

/-!
# Event streams generated from a global type (clause selfhost.session.events)

`Global.simulate` runs a protocol as a server would: `sessions` starts instances at staggered
times, every `par` branch is a thread of its own, and at each step one runnable thread, picked by a
seeded pseudo-random generator, takes its next step. A choice takes a branch at random. The result
is one interleaved stream of events, each carrying

* `prior`: the events immediately before it on the timelines of the roles it involves, in its own
  session (an actor handles one message at a time, so its events are ordered), and, for the first
  event after a `par` or `join`, the last event of each branch it waited for. The links are a backwards linked list that records what happened before what; two events
  neither of which reaches the other through `prior` were concurrent.
* `cause`: the event of the message its `cause` names, in the same session.
* `answers`: for a response, the request event it answers: the first request up its cause chain
  from its receiver to its sender, the rule `Global.calls` and `Global.diagram` use.

Negative requirements: an event never links (through prior, cause or answers) to a later event or
to another session's event; a session never contains a message its protocol does not allow; a loop
never unrolls without bound (each thread has a fuel of loop iterations, then its loop ends as done).
-/

namespace LeanFM.Session

structure Event (R : Type) where
  id      : Nat
  session : Nat
  prior   : List Nat
  cause   : Option Nat
  answers : Option Nat
  src     : R
  dst     : R
  label   : String
  msgId   : Option String
  route   : Option String
  status  : Option Nat
  isAct   : Bool
  /-- The step of the run at which the event happened. -/
  time    : Nat
  deriving Repr

namespace Sim

structure Thread (R : Type) where
  session : Nat
  g       : Global R
  env     : List (String × Global R)
  join    : Option Nat
  start   : Nat
  fuel    : Nat
  /-- The last event this thread emitted. -/
  lastEv  : Option Nat := none
  /-- Events its next event must follow besides the roles' own timelines: the ends of the branches
  of a join it continues. -/
  after   : List Nat := []

instance : Inhabited (Thread R) := ⟨{ session := 0, g := .done, env := [], join := none, start := 0, fuel := 0 }⟩

/-- What a finished thread hands to its join: its last event, or what it was waiting on. -/
def Thread.ends (t : Thread R) : List Nat := match t.lastEv with | some e => [e] | none => t.after

structure Join (R : Type) where
  need    : Nat
  done    : Nat
  fired   : Bool
  k       : Global R
  session : Nat
  env     : List (String × Global R)
  parent  : Option Nat
  fuel    : Nat
  ends    : List Nat := []

structure St (R : Type) where
  seed     : Nat
  clock    : Nat := 0
  threads  : Array (Thread R) := #[]
  joins    : Array (Join R) := #[]
  events   : Array (Event R) := #[]
  ids      : List ((Nat × String) × Nat) := []
  last     : List ((Nat × String) × Nat) := []
  sessions : Nat := 1

abbrev M (R : Type) := StateM (St R)

def rand (n : Nat) : M R Nat := do
  let s ← get
  let seed := (s.seed * 6364136223846793005 + 1442695040888963407) % 18446744073709551616
  set { s with seed }
  return if n == 0 then 0 else (seed / 8589934592) % n

def spawn (t : Thread R) : M R Unit := modify fun s => { s with threads := s.threads.push t }

def newJoin (j : Join R) : M R Nat := do
  let s ← get
  set { s with joins := s.joins.push j }
  return s.joins.size

/-- The request event a response answers: up the cause chain, the first request (an event that is
not itself a response) from `dst` to `src`. -/
def answersOf [DecidableEq R] (evs : Array (Event R)) (src dst : R) (cause : Option Nat) :
    Option Nat :=
  let rec walk : Option Nat → Nat → Option Nat
    | _, 0 | none, _ => none
    | some c, fuel + 1 => match evs[c]? with
      | some e => if !e.isAct && e.answers.isNone && e.src == dst && e.dst == src then some c
                  else walk e.cause fuel
      | none => none
  walk cause 64

def emit [DecidableEq R] [ToString R] (session : Nat) (after : List Nat) (src dst : R) (label : String)
    (msgId cause route : Option String) (status : Option Nat) (isAct : Bool) : M R Nat := do
  let s ← get
  let key (r : R) := (session, toString r)
  let lastOf (r : R) := s.last.lookup (key r)
  let prior := (([lastOf src, if isAct then none else lastOf dst].filterMap id) ++ after).eraseDups.mergeSort
  let causeEv := cause.bind fun c => s.ids.lookup (session, c)
  let id := s.events.size
  let answers := if isAct then none else answersOf s.events src dst causeEv
  let e : Event R := { id, session, prior, cause := causeEv, answers, src, dst, label, msgId, route,
                       status, isAct, time := s.clock }
  let last := (key src, id) :: (if isAct then [] else [(key dst, id)]) ++
    s.last.filter fun (k, _) => k != key src && k != key dst
  let ids := match msgId with | some m => ((session, m), id) :: s.ids | none => s.ids
  set { s with events := s.events.push e, last, ids }
  return id

/-- A thread has finished: tell its join, and start the join's continuation when enough branches
have finished. -/
def finish (t : Thread R) : M R Unit := do
  let some j := t.join | pure ()
  let s ← get
  let some jn := s.joins[j]? | pure ()
  let jn := { jn with done := jn.done + 1, ends := jn.ends ++ t.ends }
  if jn.done ≥ jn.need && !jn.fired then
    set { s with joins := s.joins.set! j { jn with fired := true } }
    spawn { session := jn.session, g := jn.k, env := jn.env, join := jn.parent, start := s.clock,
            fuel := jn.fuel, after := jn.ends.eraseDups }
  else
    set { s with joins := s.joins.set! j jn }

/-- Advance a thread to its next event, or to its end. Returns true when it emitted an event. -/
partial def step [DecidableEq R] [ToString R] (instances spread : Nat) (t : Thread R) : M R Bool := do
  match t.g with
  | .done => finish t; return false
  | .msg i k =>
      let id ← emit t.session t.after i.src i.dst i.label i.id i.cause i.route i.status false
      spawn { t with g := k, lastEv := some id, after := [] }
      return true
  | .act r l k =>
      let id ← emit t.session t.after r r l none none none none true
      spawn { t with g := k, lastEv := some id, after := [] }
      return true
  | .choice bs =>
      let i ← rand bs.length
      step instances spread { t with g := bs.getD i .done }
  | .box _ b k => step instances spread { t with g := Global.andThen b k }
  | .loop n b => step instances spread { t with g := b, env := (n, .loop n b) :: t.env }
  | .var n =>
      match t.env.lookup n, t.fuel with
      | some l, f + 1 => step instances spread { t with g := l, fuel := f }
      | _, _ => step instances spread { t with g := .done }
  | .par bs k | .join _ bs k =>
      let need := match t.g with | .join n _ _ => n | _ => bs.length
      let j ← newJoin { need, done := 0, fired := false, k, session := t.session, env := t.env,
                        parent := t.join, fuel := t.fuel }
      if bs.isEmpty then finish { t with join := some j }
      let s ← get
      for b in bs do
        spawn { t with g := b, join := some j, start := s.clock, lastEv := none, after := t.ends }
      return false
  | .sessions b k =>
      let j ← newJoin { need := instances, done := 0, fired := false, k, session := t.session,
                        env := t.env, parent := t.join, fuel := t.fuel }
      if instances == 0 then finish { t with join := some j }
      for _ in [0:instances] do
        let delay ← rand (spread + 1)
        let s ← get
        set { s with sessions := s.sessions + 1 }
        spawn { t with session := s.sessions, g := b, join := some j, start := s.clock + delay,
                       lastEv := none, after := [] }
      return false

/-- Run until no thread is left or `maxEvents` events have happened. -/
partial def run [DecidableEq R] [ToString R] (instances spread maxEvents : Nat) : M R Unit := do
  let s ← get
  if s.events.size ≥ maxEvents || s.threads.isEmpty then return
  let ready := (List.range s.threads.size).filter fun i => (s.threads[i]!).start ≤ s.clock
  if ready.isEmpty then
    let next := s.threads.foldl (fun m t => min m t.start) s.threads[0]!.start
    set { s with clock := next }
    run instances spread maxEvents
  else
    let pick ← rand ready.length
    let i := ready.getD pick 0
    let s ← get
    let t := s.threads[i]!
    set { s with threads := s.threads.eraseIdxIfInBounds i }
    let emitted ← step instances spread t
    if emitted then modify fun s => { s with clock := s.clock + 1 }
    run instances spread maxEvents

end Sim

/-- An event stream of `g`. `instances` is how many sessions each `sessions` block starts, `spread`
how many steps their starts are spread over, `loops` how many times a thread may repeat a loop. -/
def Global.simulate [DecidableEq R] [ToString R] (g : Global R) (seed : Nat := 1)
    (instances : Nat := 8) (spread : Nat := 40) (loops : Nat := 4) (maxEvents : Nat := 10000) :
    Array (Event R) :=
  let t : Sim.Thread R := { session := 0, g, env := [], join := none, start := 0, fuel := loops }
  let evs := ((Sim.run instances spread maxEvents).run { seed, threads := #[t] }).2.events
  -- number sessions in the order their first events happened (0 stays the top level)
  let order := (evs.toList.map (·.session)).eraseDups.filter (· != 0)
  evs.map fun e => { e with session := if e.session == 0 then 0 else order.idxOf e.session + 1 }

/-! ## JSON -/

def jsonString (s : String) : String :=
  "\"" ++ String.join (s.toList.map fun c =>
    if c == '"' then "\\\"" else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n"
    else if c.toNat < 32 then
      let h := Nat.toDigits 16 c.toNat
      "\\u" ++ String.ofList (List.replicate (4 - h.length) '0' ++ h)
    else c.toString) ++ "\""

def Event.toJson [ToString R] (e : Event R) : String :=
  let opt {α} (f : α → String) : Option α → String := fun o => match o with | some x => f x | none => "null"
  "{" ++ s!"\"id\":{e.id},\"session\":{e.session},\"time\":{e.time}," ++
  s!"\"prior\":[{",".intercalate (e.prior.map toString)}]," ++
  s!"\"cause\":{opt toString e.cause},\"answers\":{opt toString e.answers}," ++
  s!"\"src\":{jsonString (toString e.src)},\"dst\":{jsonString (toString e.dst)}," ++
  s!"\"label\":{jsonString e.label},\"msgId\":{opt jsonString e.msgId}," ++
  s!"\"route\":{opt jsonString e.route},\"status\":{opt toString e.status}," ++
  s!"\"act\":{if e.isAct then "true" else "false"}" ++ "}"

/-- The stream as a JSON array, one event per line. -/
def eventsJson [ToString R] (evs : Array (Event R)) : String :=
  "[\n" ++ ",\n".intercalate (evs.toList.map Event.toJson) ++ "\n]"

end LeanFM.Session
