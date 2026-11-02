import LeanFM.Session.Global

/-!
# Channel physics

What happens to a message between its send and its receive. A protocol that imports nothing from
here is checked as if every channel were `reliable`, which is also the default for any channel a
`Physics` value does not mention.

A channel is a plain structure whose defaults *are* the reliable channel, so a declaration names
only what differs: `{ udp 2 with duplication := false }`. Presets are ordinary definitions, and a
library can add its own (a vendor's message bus, a radio link) without touching this file.
-/

namespace LeanFM.Session

/-- A condition a channel can surface to the protocol on top of it, which that protocol must
handle. Conditions are an open set: libraries define new ones as values. -/
structure Condition where
  name : String
  deriving BEq, Repr, Inhabited

namespace Condition
def timeout     : Condition := ⟨"timeout"⟩
def duplicate   : Condition := ⟨"duplicate"⟩
def reject      : Condition := ⟨"reject"⟩
def loss        : Condition := ⟨"loss"⟩
def reorder     : Condition := ⟨"reorder"⟩
def perKeyOrder : Condition := ⟨"per-key order"⟩
def partition   : Condition := ⟨"partition"⟩
def hostile     : Condition := ⟨"hostile"⟩
def readable    : Condition := ⟨"readable"⟩
def close       : Condition := ⟨"close"⟩
end Condition

instance : ToString Condition := ⟨Condition.name⟩

inductive WhenFull | block | reject | dropNewest | dropOldest
  deriving BEq, Repr, Inhabited

inductive Sequencing | fifo | any
  deriving BEq, Repr, Inhabited

structure Sharding where
  key        : String
  partitions : Nat := 3
  deriving BEq, Repr

/-- Every field defaults to the reliable channel. -/
structure Channel where
  capacity    : Nat := 16
  whenFull    : WhenFull := .block
  order       : Sequencing := .fifo
  sharding    : Option Sharding := none
  loss        : Bool := false
  duplication : Bool := false
  /-- What a lower layer hides by retrying: it reaches the protocol only as latency. -/
  masked      : List Condition := []
  /-- Conditions surfaced by layers a library adds (deadlines, closes, hostile networks). -/
  extra       : List Condition := []
  deriving Repr, Inhabited

namespace Channel

def conditions (c : Channel) : List Condition :=
  let base :=
    (if c.loss || c.whenFull == .dropNewest || c.whenFull == .dropOldest then [Condition.loss] else []) ++
    (if c.order == .any then [Condition.reorder] else []) ++
    (if c.duplication then [Condition.duplicate] else []) ++
    (if c.sharding.isSome then [Condition.perKeyOrder] else []) ++
    (if c.whenFull == .reject then [Condition.reject] else []) ++ c.extra
  base.foldl (fun acc x => if acc.contains x || c.masked.contains x then acc else acc ++ [x]) []

/-- Add conditions, as a refinement does; used by interface kinds and by placement. -/
def surface (c : Channel) (xs : List Condition) : Channel :=
  { c with extra := c.extra ++ xs.filter (fun x => !c.extra.contains x) }

/-- Remove conditions, as TLS removes `readable`. -/
def hide (c : Channel) (xs : List Condition) : Channel :=
  { c with extra := c.extra.filter (fun x => !xs.contains x) }

end Channel

/-! ## Presets -/

/-- Internal APIs, in-process calls, Go channels. -/
def reliable (capacity : Nat := 16) : Channel := { capacity }

/-- Datagrams: nothing is hidden. -/
def udp (capacity : Nat := 2) : Channel :=
  { capacity, whenFull := .dropNewest, order := .any, loss := true, duplication := true }

/-- TCP, TLS, websockets: loss and reordering become latency; the stream can close. -/
def stream : Channel := { masked := [.loss, .reorder], extra := [.close] }

/-- Calls between services: a deadline, retries that can arrive twice, rejection when busy. -/
def http : Channel :=
  { stream with order := .any, duplication := true, whenFull := .reject, extra := [.close, .timeout] }

/-- A topic sharded by `key`, delivered at least once, loss hidden within retention. -/
def kafka (key : String) (partitions : Nat := 3) : Channel :=
  { duplication := true, sharding := some { key, partitions }, masked := [.loss] }

/-! ## Physics of a protocol -/

structure Timer (R : Type) where
  role         : R
  label        : String := "Timeout"
  mayFireEarly : Bool := true
  deriving Repr

structure Physics (R : Type) where
  default  : Channel := reliable
  channels : List (R × R × Channel) := []
  timers   : List (Timer R) := []

namespace Physics
variable {R : Type} [DecidableEq R]

def channel (p : Physics R) (a b : R) : Channel :=
  ((p.channels.find? (fun (x, y, _) => x == a && y == b)).map (·.2.2)).getD p.default

/-- The channels a protocol actually uses, with the conditions each surfaces. -/
def used (p : Physics R) (g : Global R) : List (R × R × List Condition) :=
  let pairs := (g.runs.flatMap id).filterMap (fun s => match s with
    | .msg i => some (i.src, i.dst) | .act _ _ => none)
  pairs.eraseDups.map (fun (a, b) => (a, b, (p.channel a b).conditions))

end Physics
end LeanFM.Session
