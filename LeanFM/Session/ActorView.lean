import LeanFM.Session.Global
import LeanFM.Session.Calls
import LeanFM.Session.Diagram
import LeanFM.Session.Types

/-! One role's view of a protocol (clause selfhost.session.actor): the part of the global type the
role takes part in, drawn as a sequence diagram with only the role and the peers it talks to, and
the role's messages with their direction, peer, route, status and payload field number.

The restricted global type is for people only. Every check still runs on the whole protocol and on
the role's projection (`Global.project`), which is the role's local type; the restriction never
replaces either. -/

namespace LeanFM.Session

/-- Whether a global type has no message and no event: nothing anyone could observe. -/
partial def Global.silent {R : Type} : Global R → Bool
  | .msg _ _ | .act _ _ _ => false
  | .choice bs => bs.all Global.silent
  | .par bs k | .join _ bs k => bs.all Global.silent && Global.silent k
  | .loop _ b => Global.silent b
  | .sessions b k | .box _ b k => Global.silent b && Global.silent k
  | .var _ | .done => true

/-- The steps of `g` that `r` takes part in: its messages (sent or received) and its own events, in
the same frames (choice, parallel, join, loop, sessions, include boxes). A frame left with nothing the role
sees is dropped; a choice keeps its other branches, an empty one standing for "the role sees nothing
on this branch", unless every branch is empty. -/
partial def Global.restrict {R : Type} [DecidableEq R] (r : R) : Global R → Global R
  | .msg i k => if i.src == r || i.dst == r then .msg i (Global.restrict r k) else Global.restrict r k
  | .act a l k => if a == r then .act a l (Global.restrict r k) else Global.restrict r k
  | .choice bs =>
      let bs' := bs.map (Global.restrict r)
      if bs'.all Global.silent then .done else .choice bs'
  | .par bs k =>
      let bs' := (bs.map (Global.restrict r)).filter (!·.silent)
      let k' := Global.restrict r k
      if bs'.isEmpty then k' else .par bs' k'
  | .join n bs k =>
      let bs' := bs.map (Global.restrict r)
      let k' := Global.restrict r k
      if bs'.all Global.silent then k' else .join n bs' k'
  | .loop n b =>
      let b' := Global.restrict r b
      if b'.silent then .done else .loop n b'
  | .var n => .var n
  | .sessions b k =>
      let b' := Global.restrict r b
      let k' := Global.restrict r k
      if b'.silent then k' else .sessions b' k'
  | .box n b k =>
      let b' := Global.restrict r b
      let k' := Global.restrict r k
      if b'.silent then k' else .box n b' k'
  | .done => .done

namespace ActorView

/-- One of a role's messages, as the role sees it. -/
structure Row where
  label     : String
  /-- sends, receives, or event (the role's own) -/
  direction : String
  peer      : String
  route     : Option String := none
  status    : Option Nat := none
  /-- the payload's field number in the envelope's oneof -/
  field     : Option Nat := none
  deriving Repr, BEq, Inhabited

/-- The lifelines of the role's diagram: the role and every role it exchanges a message with, in the
protocol's order. -/
def lanes (roles : List String) (role : String) (g : Global String) : List String :=
  let peers := (g.restrict role).messages.flatMap fun i => [i.src, i.dst]
  roles.filter fun x => x == role || peers.contains x

/-- The role's messages and events, each once, in order of first appearance, with the payload field
numbers of the whole protocol (`Types.payloadNumbers`, as the proto file numbers them). -/
partial def rows (g : Global String) (role : String) (history : List String := []) : List Row :=
  let labels := (g.messages.map (·.label)).eraseDups
  let numbers := Types.payloadNumbers labels history
  let rec acts : Global String → List String
    | .act a l k => (if a == role then [l] else []) ++ acts k
    | .msg _ k => acts k
    | .choice bs => bs.flatMap acts
    | .par bs k | .join _ bs k => bs.flatMap acts ++ acts k
    | .loop _ b => acts b
    | .sessions b k | .box _ b k => acts b ++ acts k
    | .var _ | .done => []
  let msgRows := g.messages.filterMap fun i =>
    -- positional: status and route are words of the protocol grammar, which may be loaded here
    if i.src == role then some (Row.mk i.label "sends" i.dst i.route i.status (numbers.lookup i.label))
    else if i.dst == role then some (Row.mk i.label "receives" i.src i.route i.status (numbers.lookup i.label))
    else none
  let actRows := (acts g).map fun l => Row.mk l "event" role none none none
  (msgRows ++ actRows).eraseDups

/-- The requests the role sends that carry a route: what it calls on other roles. -/
def calls (rs : List Row) : List Row := rs.filter fun r => r.direction == "sends" && r.route.isSome

/-- The requests the role receives that carry a route: what it serves. -/
def serves (rs : List Row) : List Row := rs.filter fun r => r.direction == "receives" && r.route.isSome

end ActorView
end LeanFM.Session
