import LeanFM.Session

/-!
# PaxosKV as a session type across two islands

The write path of PaxosKV as a global type, the physics of its channels, and the deployment tree
it runs on: replicas `kv0` and `kv1` in island `us`, replica `kv2` in island `eu`. Replicas talk
to each other over UDP (as QUIC datagrams would); the islands may be partitioned.

The `#guard` lines run when the file is elaborated and record the structural verdicts. The
temporal verdicts over the product of the replicas and their UDP channels come from the LeanFM
MCP server (`check_ctl`), on the model in `PaxosUdp.lean`; see `reports/mcp/`.

Run from the LeanFM root: `lake env lean projects/PaxosKV/spec/Session.lean`.
-/

namespace Project.Session
open LeanFM.Session

/-! ## Roles and vocabulary -/

inductive Role | browser | web | kv0 | kv1 | kv2
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun
  | .browser => "Browser" | .web => "Web" | .kv0 => "kv0" | .kv1 => "kv1" | .kv2 => "kv2"⟩

def roles : List Role := [.browser, .web, .kv0, .kv1, .kv2]

structure PutRequest where
  requestId : String
  key : String
  value : String
  deriving TypeName
structure Propose where
  requestId : String
  key : String
  value : String
  deriving TypeName
structure Prepare         where ballot : Nat deriving TypeName
structure Promise where
  ballot : Nat
  acceptedBallot : Nat
  acceptedValue : String
  deriving TypeName
structure Accept where
  ballot : Nat
  value : String
  deriving TypeName
structure DurableAccepted where ballot : Nat deriving TypeName
structure Commit          where value : String deriving TypeName
structure PutResult where
  requestId : String
  success : Bool
  deriving TypeName
structure PutResponse where
  requestId : String
  success : Bool
  deriving TypeName
structure Fsync           where deriving TypeName

/-! ## The write, as the stable leader `kv0` runs it

`kv0` holds a ballot that every replica has already promised (Multi-Paxos), so a write is phase 2
only: accept on two of three replicas, durably, then answer. `kv0`'s own acceptance is a local
fsync, an event at `kv0` alone. -/

protocol QuorumWrite (Browser, Web, Kv0, Kv1, Kv2) {
  put:  PutRequest from Browser to Web;
  prop: Propose from Web to Kv0 cause put where prop.requestId = put.requestId;
  join 2 of {
    Fsync at Kv0;
  } and {
    a1: Accept from Kv0 to Kv1 cause prop;
        DurableAccepted from Kv1 to Kv0 cause a1;
  } and {
    a2: Accept from Kv0 to Kv2 cause prop;
        DurableAccepted from Kv2 to Kv0 cause a2;
  }
  res: PutResult from Kv0 to Web cause prop where res.requestId = prop.requestId;
       PutResponse from Web to Browser cause res;
}

/-- A replica that lost touch with the leader takes over with a higher ballot: phase 1, then the
value the promises report (or its own), then phase 2. -/
protocol Takeover (New, OldA, OldB) {
  p: Prepare from New to OldA;
  join 1 of {
    Promise from OldA to New cause p;
  } and {
    q: Prepare from New to OldB;
       Promise from OldB to New cause q;
  }
  a: Accept from New to OldA;
     DurableAccepted from OldA to New cause a;
}

def write : Global Role := QuorumWrite .browser .web .kv0 .kv1 .kv2
def takeover : Global Role := Takeover .kv2 .kv0 .kv1

#guard write.issues roles == []
#guard takeover.issues [.kv2, .kv0, .kv1] == []

/-! ## Physics: UDP between replicas, HTTP at the edges -/

def kvChannel : Channel := udp 8

def physics : Physics Role :=
  { channels :=
      [ (.browser, .web, http), (.web, .browser, http)
      , (.web, .kv0, http), (.kv0, .web, http) ] ++
      [Role.kv0, .kv1, .kv2].flatMap (fun a => [Role.kv0, .kv1, .kv2].filterMap (fun b =>
        if a == b then none else some (a, b, kvChannel))) }

/-- What each channel's protocol handles. Paxos tolerates loss, reordering and duplicates of its
own messages by ballot numbers and retransmission; `requestId` makes a retried `PutRequest`
idempotent. -/
def handles : List (Role × Role × List Condition) :=
  [ (.browser, .web, [.timeout, .duplicate, .close, .reject, .reorder])
  , (.web, .browser, [.timeout, .duplicate, .close, .reject, .reorder])
  , (.web, .kv0, [.timeout, .duplicate, .close, .reject, .reorder])
  , (.kv0, .web, [.timeout, .duplicate, .close, .reject, .reorder]) ] ++
  [Role.kv0, .kv1, .kv2].flatMap (fun a => [Role.kv0, .kv1, .kv2].filterMap (fun b =>
    if a == b then none else some (a, b, [.loss, .reorder, .duplicate])))

def spec : Spec Role :=
  { global := write, roles, physics, handles
    properties := [ .AG (.EF .terminal), sent% DurableAccepted ]
    assumptions := [.fairDelivery .kv0 .kv1, .fairDelivery .kv1 .kv0] }

#guard spec.issues == []

/-! ## The deployment: two islands -/

open Node in
def deployment : Topology Role :=
  { world := [
      outside [ .actor .browser [] ],
      island "us" [ datacenter "dc1" [
        machine "m0" [ .actor .web [ ingress "https" .ingressHttps ],
                       .actor .kv0 [ internal "api" .api, peering "paxos" .datagram ] ],
        machine "m1" [ .actor .kv1 [ peering "paxos" .datagram ] ] ] ],
      island "eu" [ datacenter "dc1" [
        machine "m2" [ .actor .kv2 [ peering "paxos" .datagram ] ] ] ] ] }

def conditionsTo (src : Role) (name : String) : List String :=
  ((deployment.find name).map (fun p => (deployment.channel src p).conditions.map (·.name))).getD ["unreachable"]

-- Inside one island the replicas see the UDP conditions only; across islands, partition too.
#guard conditionsTo .kv0 "us.kv1.peering.paxos" == ["loss", "reorder", "duplicate"]
#guard conditionsTo .kv0 "eu.kv2.peering.paxos" == ["loss", "reorder", "duplicate", "partition"]
-- The web tier reaches the leader's internal API inside us; the browser cannot.
#guard ((deployment.find "us.kv0.internal.api").map (deployment.reachable .web ·)) == some true
#guard ((deployment.find "us.kv0.internal.api").map (deployment.reachable .browser ·)) == some false
-- kv2 is in another island: the leader's internal API is closed to it, its peering port is open.
#guard ((deployment.find "us.kv0.internal.api").map (deployment.reachable .kv2 ·)) == some false
#guard ((deployment.find "us.kv0.peering.paxos").map (deployment.reachable .kv2 ·)) == some true

/-- The requirements say the replica channels handle loss, reordering and duplicates. Placed in
two islands, the `us`–`eu` channels also surface partition, which no requirement mentions yet.
The MCP checks in `reports/mcp/` say what a partition does: `us` keeps a quorum, `eu` does not. -/
def unhandledAcrossIslands : List String :=
  [Role.kv0, .kv1].flatMap (fun a =>
    let cs := conditionsTo a "eu.kv2.peering.paxos"
    cs.filter (fun c => !((handles.find? (fun (x, y, _) => x == a && y == .kv2)).map
      (fun (_, _, hs) => hs.any (·.name == c))).getD false))

#guard unhandledAcrossIslands == ["partition", "partition"]

end Project.Session
