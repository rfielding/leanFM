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

/-! The secret atom (selfhost.session.properties): secrecy is a question a protocol test asks. -/
def orderSecret : String := orderText.replace "structure Pay where amount : Nat"
  "structure Pay where\n  amount : Nat\n  card_secr : String\nstructure Charge where\n  amount : Nat\n  card_secr : String"
def ask (text : String) (f : Json) : String × String × String :=
  match LeanFM.SessionTools.ctl (Json.mkObj [("lean", Json.str text), ("formula", f)]) with
  | .ok j => ((j.getObjValAs? String "verdict").toOption.getD "", (j.getObjValAs? String "report").toOption.getD "",
      (j.getObjValAs? String "notation").toOption.getD "")
  | .error e => ("error", e, "")
def has (s part : String) : Bool := (s.splitOn part).length > 1
-- a secret is sent: the counterexample names the step that sends it
#guard ask orderSecret (json% {AG: {not: {secret: {}}}}) == ("disproved", "counterexample: Place -> Quote -> Pay", "always ¬secret")
#guard ask orderSecret (json% {AG: {not: {secret: {"from": "Shop", to: "Bank", field: "card_secr"}}}}) ==
  ("disproved", "counterexample: Place -> Quote -> Pay -> Charge", "always ¬secret(card_secr) Shop→Bank")
-- a role that never receives a secret is answered, not rejected
#guard (ask orderSecret (json% {AG: {not: {secret: {to: "Client"}}}})).1 == "proved"
#guard (ask orderSecret (json% {AG: {not: {secret: {"from": "Bank"}}}})).2.2 == "always ¬secret Bank→"
-- no secret before Pay, Pay carrying one included; the naive form is disproved by Pay itself
#guard (ask orderSecret (Json.mkObj [("not", Json.mkObj [("EU", Json.arr #[json% {not: {on: "Pay"}},
  json% {and: [{secret: {}}, {not: {on: "Pay"}}]}])])])).1 == "proved"
#guard (ask orderSecret (Json.mkObj [("not", Json.mkObj [("EU", Json.arr #[json% {not: {on: "Pay"}}, json% {secret: {}}])])])).1 == "disproved"
-- negative: a secret atom that would pass vacuously is an input error naming what is missing
#guard has (ask orderSecret (json% {AG: {not: {secret: {field: "pin_secr"}}}})).2.1 "carries a secret field pin_secr"
#guard has (ask orderSecret (json% {AG: {not: {secret: {to: "Log"}}}})).2.1 "has no role Log"
#guard has (ask orderText (json% {AG: {not: {secret: {}}}})).2.1 "carries a secret field (a field path ending in _secr)"

/-! Suggestions: session_ctl without a formula asks questions built from the protocol, each decided. -/
def suggested (text : String) : List (String × String × String) :=
  match LeanFM.SessionTools.ctl (Json.mkObj [("lean", Json.str text)]) with
  | .ok j => ((j.getObjValD "suggestions").getArr?.toOption.getD #[]).toList.map fun (r : Json) =>
      ((r.getObjValAs? String "name").toOption.getD "", (r.getObjValAs? String "notation").toOption.getD "",
       (r.getObjValAs? String "verdict").toOption.getD "")
  | .error e => [(e, "", "")]
#guard (suggested orderText).length ≤ 12
#guard ((suggested orderText).map (·.2.1)).take 4 == ["always possibly stop", "inevitably stop", "someAlways ¬stop", "allNext Place"]
#guard ((suggested orderText).map (·.2.2)).take 4 == ["proved", "proved", "disproved", "proved"]
#guard (suggested orderText).any (· == ("Every Place is answered (Quote or SoldOut) before the session ends",
  "always (Place → (¬stop allUntil (Quote ∨ SoldOut)))", "proved"))
#guard (suggested orderText).any (·.2.1 == "Place ⇒ inevitably (Quote ∨ SoldOut)")
#guard (suggested orderText).any (·.2.1 == "¬(¬Place someUntil (Quote ∨ SoldOut))")
-- secret suggestions only when a secret exists
#guard !(suggested orderText).any (has ·.1 "secret")
#guard (suggested orderSecret).any (· == ("No secret is ever sent", "always ¬secret", "disproved"))
#guard (suggested orderSecret).any (· == ("No secret ever reaches Client", "always ¬secret →Client", "proved"))

end LeanFM.Session.SpecCheckTests
