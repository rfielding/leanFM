import LeanFM.CTL
import LeanFM.Session.Physics

/-!
# Requirements: properties, assumptions and what each channel handles

A `Spec` bundles a protocol with the requirements stated about it. Every field but the protocol
is optional, so the simplest spec is just a protocol, checked by the core rules alone.
-/

namespace LeanFM.Session

/-- What a CTL atom can see at a state of the product: the message just delivered, and whether
the run has finished. -/
structure Obs where
  last     : Option String
  terminal : Bool

/-- Temporal properties whose atoms name messages of the protocol. -/
inductive Prop' where
  | sent (label : String)
  | terminal
  | not (p : Prop')
  | and (p q : Prop')
  | or (p q : Prop')
  | AG (p : Prop') | AF (p : Prop') | EF (p : Prop') | EG (p : Prop')
  /-- `[p AU q]` -/
  | allUntil (p q : Prop')
  /-- `[p EU q]` -/
  | someUntil (p q : Prop')
  deriving Repr, Inhabited

namespace Prop'

def atoms : Prop' → List String
  | sent l => [l]
  | terminal => []
  | not p | AG p | AF p | EF p | EG p => atoms p
  | and p q | or p q | allUntil p q | someUntil p q => atoms p ++ atoms q

/-- The same formula for LeanFM's existing CTL checker. -/
def toCTL : Prop' → CTL Obs
  | sent l => .atom (fun o => o.last == some l)
  | terminal => .atom (·.terminal)
  | not p => .neg (toCTL p)
  | and p q => .and (toCTL p) (toCTL q)
  | or p q => .or (toCTL p) (toCTL q)
  | AG p => .ag (toCTL p) | AF p => .af (toCTL p) | EF p => .ef (toCTL p) | EG p => .eg (toCTL p)
  | allUntil p q => .au (toCTL p) (toCTL q) | someUntil p q => .eu (toCTL p) (toCTL q)

end Prop'

/-- Assumptions a liveness claim depends on, stated as requirements rather than hidden. -/
inductive Assumption (R : Type) where
  /-- A message sent infinitely often on this channel is delivered infinitely often. -/
  | fairDelivery (src dst : R)
  /-- A timer fires only after the declared delay. -/
  | timerNotEarly (role : R)
  deriving Repr

structure Spec (R : Type) where
  global      : Global R
  roles       : List R
  physics     : Physics R := {}
  /-- What the protocol on each channel handles; conditions not listed are findings. -/
  handles     : List (R × R × List Condition) := []
  properties  : List Prop' := []
  assumptions : List (Assumption R) := []

namespace Spec
variable {R : Type} [DecidableEq R] [ToString R]

def handled (s : Spec R) (a b : R) : List Condition :=
  ((s.handles.find? (fun (x, y, _) => x == a && y == b)).map (·.2.2)).getD []

/-- Everything wrong with the spec: core rules, unknown atoms, and channel conditions that the
protocol on that channel does not handle. -/
def issues (s : Spec R) : List String :=
  -- atoms may name messages of the protocol or events its physics adds, such as timers
  let labels := s.global.labels ++ s.physics.timers.map (·.label)
  s.global.issues s.roles ++
  (s.properties.flatMap Prop'.atoms |>.filter (fun a => !labels.contains a)).map
    (fun a => s!"property mentions {a}, which the protocol never sends") ++
  ((s.physics.used s.global).flatMap (fun (a, b, cs) =>
    (cs.filter (fun c => !(s.handled a b).contains c)).map
      (fun c => s!"channel {a} -> {b} surfaces {c}, which its protocol does not handle")))

end Spec
end LeanFM.Session
