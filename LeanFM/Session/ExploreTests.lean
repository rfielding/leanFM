import LeanFM.Session.ActorView
import LeanFM.Session.Dataset
import LeanFM.SessionTools

/-! Tests for selfhost.session.actor and selfhost.session.dataset (decision session-explorer): one
role's view keeps exactly that role's steps and the whole protocol's payload numbers; a dataset's
walks all conform, end or are counted as not ended, are bounded, and a probability layer's weights
show up in the frequencies. -/
namespace LeanFM.Session.ExploreTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

deriving instance Inhabited for LeanFM.SessionTools.Protocol

def shopText : String := "protocol Shop (Client, Shop, Bank) {
  o: Order from Client to Shop route \"POST /orders\";
  choice {
    c: Charge from Shop to Bank route \"POST /charges\";
    choice {
      Paid from Bank to Shop cause c status 200;
      Confirmed from Shop to Client cause o status 201;
    } or {
      Declined from Bank to Shop cause c status 402;
      Rejected from Shop to Client cause o status 402;
    }
  } or {
    OutOfStock from Shop to Client cause o status 409;
  }
}"

def args (text : String) (extra : List (String × Json) := []) : Json := Json.mkObj ([("lean", Json.str text)] ++ extra)
def shop : Protocol := (parseProtocol (args shopText)).toOption.get!
def labelsOf (g : Global String) : List String := g.messages.map (·.label)
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => "error: " ++ e
def nat (r : Except String Json) (k : String) : Nat :=
  match r with | .ok j => (j.getObjValAs? Nat k).toOption.getD 0 | .error _ => 0
def refused (r : Except String Json) (needle : String) : Bool :=
  match r with | .error e => (e.splitOn needle).length > 1 | .ok _ => false

/-! ## One role's view -/

-- the role's steps, exactly: every message it sends or receives, and no other
#guard labelsOf (shop.global.restrict "Bank") == ["Charge", "Paid", "Declined"]
#guard labelsOf (shop.global.restrict "Client") == ["Order", "Confirmed", "Rejected", "OutOfStock"]
#guard shop.roles.all fun r => (shop.global.restrict r).messages.all fun i => i.src == r || i.dst == r
#guard shop.roles.all fun r =>
  (shop.global.messages.filter fun i => i.src == r || i.dst == r).map (·.label) == labelsOf (shop.global.restrict r)
-- lifelines: the role and its peers, in the protocol's order
#guard ActorView.lanes shop.roles "Bank" shop.global == ["Shop", "Bank"]
#guard ActorView.lanes shop.roles "Shop" shop.global == ["Client", "Shop", "Bank"]
-- a frame the role sees nothing of is dropped; a choice keeps an empty branch for "nothing here"
#guard match shop.global.restrict "Bank" with
  | .choice [.msg _ _, .done] => true
  | _ => false

-- directions, peers and routes, with the payload numbers the proto file uses
#guard (ActorView.rows shop.global "Bank").map (fun r => (r.label, r.direction, r.peer, r.field)) ==
  [("Charge", "receives", "Shop", some 17), ("Paid", "sends", "Shop", some 18), ("Declined", "sends", "Shop", some 20)]
#guard (ActorView.serves (ActorView.rows shop.global "Shop")).map (·.route) == [some "POST /orders"]
#guard (ActorView.calls (ActorView.rows shop.global "Shop")).map (·.route) == [some "POST /charges"]
#guard match Session.Types.proto shop.types (labelsOf shop.global).eraseDups "shop" with
  | .ok t => (t.splitOn "Charge charge = 17;").length == 2 && (t.splitOn "Declined declined = 20;").length == 2
  | .error _ => false

-- the tool
#guard str (actor (args shopText [("role", "Bank")])) "verdict" == "projected"
#guard str (actor (args shopText [("role", "Shop")])) "reading" ==
  "Shop as Shop sees it: sends 4 messages, receives 3; serves 1 route, calls 1 route; peers: Client, Bank"
#guard match actor (args shopText [("role", "Shop")]) with
  | .ok j => match j.getObjValAs? String "openapiYaml" with
    | .ok y => (y.splitOn "/orders").length > 1 && (y.splitOn "/charges").length == 1
    | .error _ => false
  | .error _ => false
-- never: a role the protocol does not have, or no role
#guard refused (actor (args shopText [("role", "Mallory")])) "Mallory is not a role of Shop"
#guard refused (actor (args shopText)) "role is required"

/-! ## Datasets -/

def walks (text : String) (n : Nat) (seed : Nat := 1) : Array Dataset.Run :=
  match parseProtocol (args text) with
  | .ok p => (Dataset.walkMany p.global seed n).toOption.getD #[]
  | .error _ => #[]

-- every walk is a session the protocol allows, from start to end (conformance by construction)
#guard (walks shopText 300).size == 300
#guard (walks shopText 300).all (·.ended)
#guard ((walks shopText 300).toList.zipIdx.all fun (r, i) =>
  (shop.global.conforms (r.log (toString i))).all (·.problem.isNone))
-- the same seed gives the same dataset; another seed another one
#guard (walks shopText 50).toList.map Dataset.pathKey == (walks shopText 50).toList.map Dataset.pathKey
#guard (walks shopText 50 1).toList.map Dataset.pathKey != (walks shopText 50 2).toList.map Dataset.pathKey

def shopData : Except String Json := dataset (args shopText [("sessions", toJson (2000 : Nat))])
#guard str shopData "verdict" == "generated"
#guard nat shopData "sessions" == 2000 && nat shopData "ended" == 2000 && nat shopData "distinctPaths" == 3
#guard str shopData "basis" == "walk"
-- an unweighted protocol's frequencies are said to describe the walker, never the system
#guard ((str shopData "reading").splitOn "these frequencies describe the walker, not the system").length == 2

-- never: a session reported ended when it was cut at the event limit
def forever : String := "protocol Forever (A, B) { rec L { Ping from A to B; continue L; } }"
#guard (walks forever 2).all fun r => r.truncated && !r.ended && r.steps.size == Dataset.maxSessionEvents
#guard ((str (dataset (args forever [("sessions", toJson (3 : Nat))])) "reading").splitOn "3 did not end").length == 2
-- never: an unbounded request (sessions, or events in all)
#guard refused (dataset (args shopText [("sessions", toJson (0 : Nat))])) "sessions must be 1 to 10000"
#guard refused (dataset (args shopText [("sessions", toJson (10001 : Nat))])) "sessions is at most 10000"
-- the event bound refuses rather than truncates (the tool's 1000000 is checked in MCPTests, compiled)
#guard match parseProtocol (args forever) with
  | .ok p => match Dataset.walkCounts p.global 1 3 (bound := 1000) with
    | .error e => (e.splitOn "would exceed 1000 events after 1 sessions").length == 2
    | .ok _ => false
  | .error _ => false
-- counting as the sessions are made gives the same summary as counting them afterwards
#guard match parseProtocol (args shopText) with
  | .ok p => match Dataset.walkCounts p.global 1 200 with
    | .ok a => a.summary "steps" == Dataset.summary (walks shopText 200) "steps"
    | .error _ => false
  | .error _ => false
-- a protocol whose parallel branches interleave says its paths are orders, not outcomes
-- three branches of three messages: 9!/(3!^3) = 1680 orders, so 12 sessions all but surely differ
def interleave : String := "protocol I (A, B, C, D) { par { A1 from A to D; A2 from A to D; A3 from A to D; } and { B1 from B to D; B2 from B to D; B3 from B to D; } and { C1 from C to D; C2 from C to D; C3 from C to D; } }"
#guard ((str (dataset (args interleave [("sessions", toJson (12 : Nat))])) "reading").splitOn "parallel branches interleave").length == 2
-- never: a dataset of a protocol with issues
#guard refused (dataset (args "protocol Bad (A, B, C) { choice { X from A to B; } or { Y from C to B; } }")) "fix protocol issues"

/-! ## A probability layer's weights show in the frequencies -/

def coin : String := "protocol Coin (A, B) {
  Flip from A to B;
  choice at B using declared(\"coin\") {
    probability 1/2:
      Heads from B to A;
  } or {
    probability 1/2:
      Tails from B to A;
  }
}"

def tosses : String := "protocol Tosses (A, B) {
  rec Toss {
    Flip from A to B;
    choice at B using declared(\"coin\") {
      probability 1/2:
        Heads from B to A;
        continue Toss;
    } or {
      probability 1/2:
        Tails from B to A;
    }
  }
}"

def countOf (r : Except String Json) (message : String) : Nat :=
  match r with
  | .ok j => match j.getObjValD "messages" with
    | .arr a => (a.toList.find? fun m => (m.getObjValAs? String "message").toOption == some message).bind
        (fun m => (m.getObjValAs? Nat "count").toOption) |>.getD 0
    | _ => 0
  | .error _ => 0

-- 4000 fair tosses: heads within four standard deviations (about 32) of 2000
def coinData : Except String Json := dataset (args coin [("sessions", toJson (4000 : Nat))])
#guard str coinData "basis" == "weighted"
#guard let h := countOf coinData "Heads from B to A"; 1872 <= h && h <= 2128
-- a geometric loop: one Tails per session, and heads per session averaging 1 (sd of the total about 89)
def tossData : Except String Json := dataset (args tosses [("sessions", toJson (4000 : Nat))])
#guard countOf tossData "Tails from B to A" == 4000
#guard let h := countOf tossData "Heads from B to A"; 3640 <= h && h <= 4360

-- the sampler itself: a fair choice drawn 20000 times in a row is fair and does not alternate
-- (a ticket from an LCG's low bits would alternate, so a 1/2 choice repeated would never repeat)
def draws : List Nat := Id.run do
  let mut s := 7
  let mut out : Array Nat := #[]
  for _ in [0:20000] do
    match Generative.choose [Overlay.Q.mk 1 2, Overlay.Q.mk 1 2] s with
    | .ok (i, s') => out := out.push i; s := s'
    | .error _ => pure ()
  return out.toList
#guard draws.length == 20000
#guard let z := (draws.filter (· == 0)).length; 9717 <= z && z <= 10283
#guard let same := ((draws.zip draws.tail).filter fun (a, b) => a == b).length; 9717 <= same && same <= 10283

end LeanFM.Session.ExploreTests
