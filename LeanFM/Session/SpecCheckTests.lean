import LeanFM.Session
import LeanFM.SessionTools

/-! Tests for selfhost.session.properties (decision session-properties): properties stated in Lean
are proved over the protocol's state graph, with the checker session_ctl uses. -/
namespace LeanFM.Session.SpecCheckTests
open Lean LeanFM LeanFM.Session

inductive Role | client | shop | bank deriving DecidableEq, Repr
instance : ToString Role := ⟨fun | .client => "Client" | .shop => "Shop" | .bank => "Bank"⟩

structure Quote where price : Nat
structure Pay where amount : Nat

protocol Order (Client, Shop, Bank) {
  o: Place from Client to Shop;
  choice {
    q: Quote from Shop to Client cause o;
    p: Pay from Client to Shop cause q where p.amount = q.price;
    c: Charge from Shop to Bank cause p;
    choice {
      d: Charged from Bank to Shop cause c;
      Receipt from Shop to Client cause d;
    } or {
      x: Declined from Bank to Shop cause c;
      PaymentDeclined from Shop to Client cause x;
    }
  } or {
    SoldOut from Shop to Client cause o;
  }
}

def spec (ps : List Prop') : Spec Role :=
  { global := Order .client .shop .bank, roles := [.client, .shop, .bank], properties := ps }

-- every payment ends in a receipt or a decline; no receipt before the bank says Charged; a purchase
-- can complete; from anywhere the session can still finish: all proved, so the spec has no findings
def promises : List Prop' :=
  [ .AG (.or (.not (sent% Pay)) (.AF (.or (sent% Receipt) (sent% PaymentDeclined))))
  , .not (.someUntil (.not (sent% Charged)) (sent% Receipt))
  , .EF (sent% Receipt)
  , .AG (.EF .terminal) ]
#guard ((spec promises).verdicts "Order").map (·.2.1) == ["proved", "proved", "proved", "proved"]
#guard (spec promises).check "Order" == []

-- negative: a false property is a finding with its counterexample, never reported as holding
#guard (spec [.AF (sent% Charge)]).check "Order" ==
  ["property disproved: Order: on every path, eventually Charge was just delivered; counterexample: Place -> SoldOut (and stays there)"]
-- negative: a property about an event the protocol never has is not checked, and says so (sent%
-- refuses a label that is not a type when the file compiles; a raw label gets this finding)
#guard (match (spec [.EF (.sent "Refund")]).check "Order" with
  | [e, n] => (e.splitOn "property mentions Refund, which the protocol never sends").length > 1 &&
      (n.splitOn "property not checked").length > 1 | _ => false)
#guard (match ((spec [.EF (.sent "Refund")]).verdicts "Order") with
  | [(_, v, _)] => v == "not checked" | _ => false)

-- the same property through session_ctl gets the same verdict and the same path: one checker
def orderText : String := "structure Quote where price : Nat
structure Pay where amount : Nat
protocol Order (Client, Shop, Bank) {
  o: Place from Client to Shop;
  choice {
    q: Quote from Shop to Client cause o;
    p: Pay from Client to Shop cause q where p.amount = q.price;
    c: Charge from Shop to Bank cause p;
    choice {
      d: Charged from Bank to Shop cause c;
      Receipt from Shop to Client cause d;
    } or {
      x: Declined from Bank to Shop cause c;
      PaymentDeclined from Shop to Client cause x;
    }
  } or {
    SoldOut from Shop to Client cause o;
  }
}"
def viaMcp (p : Prop') : String × String :=
  match LeanFM.SessionTools.ctl (Json.mkObj [("lean", Json.str orderText), ("formula", p.toJson)]) with
  | .ok j => ((j.getObjValAs? String "verdict").toOption.getD "", (j.getObjValAs? String "report").toOption.getD "")
  | .error e => (e, "")
#guard (promises ++ [Prop'.AF (sent% Charge)]).all fun p =>
  let (v, _) := viaMcp p
  ((spec [p]).verdicts "Order").map (·.2.1) == [v]
#guard (viaMcp (Prop'.AF (sent% Charge))).2 == "counterexample: Place -> SoldOut (and stays there)"

end LeanFM.Session.SpecCheckTests
