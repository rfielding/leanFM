import LeanFM.Session.LeanGen
import LeanFM.Session.Conform

/-! What a deployment can do (selfhost.session.buffers): each role runs its own projection, every
actor has a FIFO inbox that loses nothing, of the size its protocol gives it (0, a rendezvous, when
it gives none), and the orders of deliveries that produces are compared with the orders the
protocol allows.

Requirements this module is held to:
* positive (AG): every answer names the inbox sizes and the guarantees it assumed, and a problem
  comes with the deliveries that lead to it.
* negative (never): a message taken out of order or lost, or put into a full inbox; with size 0
  sending and delivery are one step.
* negative (never): a role that runs parallel branches or serves sessions explored as if it did
  not; it is refused, naming the role.
* negative (never): the state bound exceeded silently.
Tested in LeanFM/Session/RealizableTests.lean. -/

namespace LeanFM.Session.Realizable
open Lean LeanFM.Session

/-- One role's machine from its projection: each state's edges and whether it may end there. -/
structure RoleM where
  name  : String
  start : String
  table : Std.HashMap String (List LeanGen.Edge × Bool)
  deriving Inhabited

def roleMachine (g : Global String) (r : String) : Except String RoleM := do
  let l ← match g.project r with
    | .ok l => pure l
    | .error e => throw s!"{r} has no projection: {e}"
  let (start, ms) := l.machine
  if ms.any (fun (_, m) => match m with | .fork .. | .serve .. => true | _ => false) then
    throw s!"{r} runs parallel branches or serves sessions; session_realizable explores roles that run one step at a time"
  let states := ((ms.map fun (p : Nat × Method String) => Typestate.nm p.1) ++ [start, "End"]).eraseDups
  let mut table : Std.HashMap String (List LeanGen.Edge × Bool) := {}
  for s in states do
    table := table.insert s (← LeanGen.closure ms r s)
  return { name := r, start, table }

/-- A deployment state: each role's machine state and each role's inbox, oldest first. -/
structure St where
  at_   : Array String
  inbox : Array (List (String × String))
  deriving BEq, Hashable, Inhabited

def St.key (s : St) : String :=
  "|".intercalate s.at_.toList ++ "#" ++ "|".intercalate (s.inbox.toList.map fun q => ",".intercalate (q.map fun (a, b) => a ++ ":" ++ b))

/-- One step of the deployment: what happened, whether the protocol sees it (a delivery or an act,
not a message waiting in an inbox), and where it leads. -/
structure Move where
  text      : String
  seen      : Option (String × String × String × Bool)   -- label, sender, receiver, act
  next      : St

def moves (ms : Array RoleM) (size : String → Nat) (s : St) : List Move := Id.run do
  let idx (r : String) : Option Nat := ms.findIdx? (·.name == r)
  let mut out : List Move := []
  for i in [0:ms.size] do
    let m := ms[i]!
    let (es, _) := m.table.getD s.at_[i]! ([], false)
    for e in es do
      if e.src == m.name && e.dst == m.name then
        out := out ++ [{ text := s!"{e.label} at {m.name}", seen := some (e.label, m.name, m.name, true),
                         next := { s with at_ := s.at_.set! i e.next } }]
      else if e.src == m.name then
        match idx e.dst with
        | none => pure ()
        | some j =>
          if size e.dst == 0 then
            -- a rendezvous: the receiver takes it in the same step, when it can
            if s.inbox[j]!.isEmpty then
              let (rs, _) := ms[j]!.table.getD s.at_[j]! ([], false)
              for re in rs do
                if re.src == m.name && re.dst == e.dst && re.label == e.label then
                  out := out ++ [{ text := s!"{e.label} from {m.name} to {e.dst}", seen := some (e.label, m.name, e.dst, false),
                                   next := { s with at_ := (s.at_.set! i e.next).set! j re.next } }]
          else if s.inbox[j]!.length < size e.dst then
            out := out ++ [{ text := s!"{m.name} puts {e.label} in {e.dst}'s inbox", seen := none,
                             next := { at_ := s.at_.set! i e.next, inbox := s.inbox.set! j (s.inbox[j]! ++ [(m.name, e.label)]) } }]
      else if e.dst == m.name && size m.name > 0 then
        match s.inbox[i]! with
        | (fr, l) :: rest =>
          if fr == e.src && l == e.label then
            out := out ++ [{ text := s!"{m.name} takes {e.label} from {fr}", seen := some (e.label, fr, m.name, false),
                             next := { at_ := s.at_.set! i e.next, inbox := s.inbox.set! i rest } }]
        | [] => pure ()
  return out

structure Answer where
  verdict  : String
  problem  : String := ""
  path     : List String := []
  inboxes  : List (String × List String) := []
  waiting  : List (String × List String) := []
  states   : Nat := 0

/-- Explore every deployment state, breadth first, alongside the protocol states its deliveries can
be at; stop at the first order the protocol does not allow or the first stuck state. -/
def explore (g : Global String) (roles : List String) (sizes : List (String × Nat)) (maxStates : Nat) :
    Except String Answer := do
  let ms ← (roles.mapM (roleMachine g)).map List.toArray
  let spec ← g.stateGraph maxStates
  let size (r : String) : Nat := (sizes.lookup r).getD 0
  -- the protocol's steps from each of its states, and where it may stop
  let mut specNext : Std.HashMap String (List (Conform.NextStep × String)) := {}
  for (a, b, n) in spec.edges do
    specNext := specNext.insert a ((specNext.getD a []) ++ [(n, b)])
  let advance (set : List String) (seen : String × String × String × Bool) : List String :=
    let (l, src, dst, act) := seen
    (set.flatMap fun x => (specNext.getD x []).filterMap fun (n, y) =>
      if n.label == l && n.isAct == act && (if act then n.dst == dst else n.src == src && n.dst == dst) then some y else none).eraseDups
  let start : St := { at_ := ms.map (·.start), inbox := ms.map fun _ => [] }
  let mut queue : Array (St × List String × List String) := #[(start, ["s0"], [])]
  let mut seen : Std.HashSet String := {}
  seen := seen.insert (start.key ++ "@s0")
  let mut head := 0
  while head < queue.size do
    let (s, set, path) := queue[head]!
    head := head + 1
    let mv := moves ms size s
    if mv.isEmpty then
      let allFinal := (List.range ms.size).all fun i => (ms[i]!.table.getD s.at_[i]! ([], false)).2 && s.inbox[i]!.isEmpty
      if allFinal then
        unless set.any spec.terminals.contains do
          return { verdict := "unrealizable", problem := "the deployment stops where the protocol does not allow it to", path, states := seen.size }
      else
        let inboxes := (List.range ms.size).filterMap fun i =>
          if s.inbox[i]!.isEmpty then none else some (ms[i]!.name, s.inbox[i]!.map fun (a, b) => s!"{b} from {a}")
        let waiting := (List.range ms.size).filterMap fun i =>
          let (es, fin) := ms[i]!.table.getD s.at_[i]! ([], false)
          if es.isEmpty then none else
          some (ms[i]!.name, es.map (fun e => if e.dst == ms[i]!.name && e.src != ms[i]!.name then s!"receive {e.label} from {e.src}"
              else if e.src == e.dst then s!"{e.label}" else s!"send {e.label} to {e.dst}") ++ (if fin then ["or stop"] else []))
        return { verdict := "unrealizable", problem := "deadlock: no role can take a step and the conversation may not stop",
                 path, inboxes, waiting, states := seen.size }
    for m in mv do
      let set' := match m.seen with
        | some e => advance set e
        | none => set
      if set'.isEmpty then
        return { verdict := "unrealizable",
                 problem := (if path.isEmpty then s!"{m.text} can happen first" else s!"{m.text} can happen next") ++ ", which the protocol does not allow",
                 path, states := seen.size }
      let k := m.next.key ++ "@" ++ ",".intercalate (set'.toArray.qsort (· < ·)).toList
      if !seen.contains k then
        if seen.size ≥ maxStates then
          throw s!"more than {maxStates} deployment states; nothing was decided; {LeanFM.CallLimits.raise "states" maxStates}"
        seen := seen.insert k
        queue := queue.push (m.next, set', path ++ [m.text])
  return { verdict := "realizable", states := seen.size }

end LeanFM.Session.Realizable
