import LeanFM.Session.Physics

/-!
# Interfaces and the deployment tree

Optional. Interfaces give actors typed entry points whose kinds form a hierarchy; the deployment
tree places actors in islands and names every interface by its path
(`us.alice.ingress.https`). From the tree alone LeanFM can say which channels may exist (scopes)
and which conditions placement adds (partition across islands, hostility from outside, rejection
into a replicated group, per-key order into a shard).
-/

namespace LeanFM.Session

/-- An interface kind is a channel plus its lineage. New kinds refine old ones, so a library can
add `grpc` or `mqtt` as a refinement without editing this file. -/
structure IfaceKind where
  name    : String
  lineage : List String := []
  channel : Channel
  deriving Inhabited

def IfaceKind.refine (base : IfaceKind) (name : String)
    (adds : List Condition := []) (removes : List Condition := []) : IfaceKind :=
  { name, lineage := base.lineage ++ [base.name], channel := (base.channel.surface adds).hide removes }

namespace IfaceKind
def call         : IfaceKind := { name := "call", channel := reliable }
def queue        : IfaceKind := { name := "queue", channel := reliable 16 }
def stream       : IfaceKind := { name := "stream", channel := Session.stream }
def http         : IfaceKind := { name := "http", lineage := ["stream"], channel := Session.http }
def api          : IfaceKind := http.refine "api"
def ingressHttp  : IfaceKind := http.refine "ingressHttp" (adds := [.hostile, .readable])
def ingressHttps : IfaceKind := ingressHttp.refine "ingressHttps" (removes := [.readable])
def datagram     : IfaceKind := { name := "datagram", channel := udp }
def topic (key : String) : IfaceKind := { name := "topic", channel := kafka key }
end IfaceKind

inductive Scope | ingress | peering | internal | «local»
  deriving BEq, Repr, Inhabited

def Scope.name : Scope → String
  | .ingress => "ingress" | .peering => "peering" | .internal => "internal" | .local => "local"

structure Iface where
  scope : Scope
  name  : String
  kind  : IfaceKind

def ingress  (name : String) (kind : IfaceKind) : Iface := ⟨.ingress, name, kind⟩
def peering  (name : String) (kind : IfaceKind) : Iface := ⟨.peering, name, kind⟩
def internal (name : String) (kind : IfaceKind) : Iface := ⟨.internal, name, kind⟩
def «local»  (name : String) (kind : IfaceKind) : Iface := ⟨.local, name, kind⟩

inductive Place | world | outside | island | datacenter | machine | replicated | sharded
  deriving BEq, Repr, Inhabited

inductive Node (R : Type) where
  | group (name : String) (place : Place) (children : List (Node R))
  | actor (role : R) (ifaces : List Iface)

namespace Node
variable {R : Type}
def outside (cs : List (Node R)) : Node R := group "outside" .outside cs
def island (n : String) (cs : List (Node R)) : Node R := group n .island cs
def datacenter (n : String) (cs : List (Node R)) : Node R := group n .datacenter cs
def machine (n : String) (cs : List (Node R)) : Node R := group n .machine cs
def replicated (n : String) (cs : List (Node R)) : Node R := group n .replicated cs
def sharded (n : String) (cs : List (Node R)) : Node R := group n .sharded cs
end Node

structure Placed (R : Type) where
  role  : R
  path  : List (String × Place)
  iface : Option Iface

partial def flatten {R : Type} (above : List (String × Place)) : Node R → List (Placed R)
  | .group n p cs => cs.flatMap (flatten (above ++ [(n, p)]))
  | .actor r is => if is.isEmpty then [⟨r, above, none⟩] else is.map (fun i => ⟨r, above, some i⟩)

structure Topology (R : Type) where
  world : List (Node R)

namespace Topology
variable {R : Type} [DecidableEq R] [ToString R]

def placed (t : Topology R) : List (Placed R) := t.world.flatMap (flatten [])

def _root_.LeanFM.Session.Placed.island (p : Placed R) : String := (p.path.head?.map (·.1)).getD "world"

/-- The implicit name: island, actor, scope, interface; containers in between are left out. -/
def _root_.LeanFM.Session.Placed.implicitName (p : Placed R) : String :=
  match p.iface with
  | some i => s!"{p.island}.{p.role}.{i.scope.name}.{i.name}"
  | none => s!"{p.island}.{p.role}"

def pathOf (t : Topology R) (r : R) : List (String × Place) :=
  ((t.placed.find? (·.role == r)).map (·.path)).getD []

def find (t : Topology R) (name : String) : Option (Placed R) :=
  t.placed.find? (·.implicitName == name)

def commonPrefix : List (String × Place) → List (String × Place) → List (String × Place)
  | a :: as, b :: bs => if a.1 == b.1 then a :: commonPrefix as bs else []
  | _, _ => []

/-- Scopes: ingress from anyone, peering from any island, internal from the same island, local
from the same machine. -/
def reachable (t : Topology R) (src : R) (dst : Placed R) : Bool :=
  let s := t.pathOf src
  let c := commonPrefix s dst.path
  let fromOutside := (s.head?.map (·.2)) == some .outside
  match (dst.iface.map (·.scope) : Option Scope) with
  | none | some .ingress => true
  | some .peering => !fromOutside
  | some .internal => !fromOutside && !c.isEmpty
  | some .local => c.any (·.2 == .machine)

/-- The channel from `src` to the interface, after placement adds its conditions. -/
def channel (t : Topology R) (src : R) (dst : Placed R) : Channel :=
  let s := t.pathOf src
  let base := (dst.iface.map (·.kind.channel)).getD reliable
  let outside := (s.head?.map (·.2)) == some .outside || (dst.path.head?.map (·.2)) == some .outside
  let crossing := (commonPrefix s dst.path).isEmpty
  base.surface (
    (if crossing && !outside then [Condition.partition] else []) ++
    (if outside then [Condition.hostile] else []) ++
    (if dst.path.any (·.2 == .replicated) then [Condition.reject] else []) ++
    (if dst.path.any (·.2 == .sharded) then [Condition.perKeyOrder] else []))

end Topology
end LeanFM.Session
