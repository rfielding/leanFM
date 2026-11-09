import LeanFM.SessionTools

/-! Tests for the MCP session tools (clause selfhost.mcp.session.tools). Built with the library, so
`lake build` runs every `#guard`. -/

namespace LeanFM.SessionToolsTests
open Lean LeanFM.SessionTools

def parse! (s : String) : Json := (Json.parse s).toOption.getD Json.null

def call (f : Json → Except String Json) (s : String) : Except String Json := f (parse! s)

def verdict (r : Except String Json) : String :=
  match r with
  | .ok j => (j.getObjValAs? String "verdict").toOption.getD "?"
  | .error _ => "rejected"

def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""

def field (r : Except String Json) (k : String) : Json :=
  match r with | .ok j => j.getObjValD k | .error _ => Json.null

def strs (j : Json) : List String :=
  match j with | .arr a => a.toList.filterMap (·.getStr?.toOption) | _ => []

/-- The reference's example protocol: the documentation's own JSON is what the test checks. -/
def placeOrder : String := ((reference.splitOn "```json\n")[1]!.splitOn "\n```")[0]!

def withProtocol (p : String) (extra : String := "") : String :=
  "{\"protocol\": " ++ p ++ extra ++ "}"

-- the documented example checks ok, with the client's typestate and the calls tree
def po := call check (withProtocol placeOrder)
#guard verdict po == "ok"
#guard strs (field po "issues") == []
#guard ((field po "projections").getObjValD "Client" |>.getObjValAs? String "typestate").toOption ==
  some ("start : S0\nS0.sendCreateOrder(m : CreateOrder) : S1    -- to Shop\n" ++
        "S1.receive() : Quote × S2 (from Shop) | SoldOut × End (from Shop)\n" ++
        "S2.sendPay(m : Pay) : S3    -- to Shop\n" ++
        "S3.receive() : Receipt × End (from Shop) | PaymentDeclined × End (from Shop)")
#guard (field po "callsText").getStr?.toOption ==
  some ("o: CreateOrder  Client → Shop  POST /orders\n  returns Quote 201 | SoldOut 409\n" ++
        "p: Pay  Client → Shop\n  returns Receipt 200 | PaymentDeclined 402\n" ++
        "    c: Charge  Shop → Bank\n      returns Charged | Declined")
-- the diagram comes as shapes: an alt frame names the shop as the role that selects
#guard ((field po "diagram").getObjValD "shapes").compress.contains "Shop selects; others offer"
-- the same arguments give the same answer
#guard (call check (withProtocol placeOrder)).toOption.map (·.compress) == po.toOption.map (·.compress)

-- the core rules report what SessionTests reports for the Lean versions
def race := call check (withProtocol r#"{"roles": ["Sender", "Receiver"], "steps": [
  {"rec": "Block", "steps": [
    {"msg": "Data", "id": "d", "from": "Sender", "to": "Receiver"},
    {"choice": [
      [{"event": "Timeout", "at": "Sender"}, {"continue": "Block"}],
      [{"msg": "Ack", "from": "Receiver", "to": "Sender", "cause": "d"}, {"continue": "Block"}]]}]}]}"#)
#guard verdict race == "issues"
#guard strs (field race "issues") ==
  ["no single role decides a choice, so it is a race: Sender starts Timeout; Receiver starts Ack"]

def hold := call check (withProtocol r#"{"roles": ["Client", "Shop", "Bank"], "steps": [
  {"msg": "Hold", "id": "h", "from": "Client", "to": "Bank"},
  {"msg": "Order", "id": "o", "from": "Client", "to": "Shop"},
  {"choice": [
    [{"msg": "Quote", "id": "q", "from": "Shop", "to": "Client", "cause": "o"},
     {"msg": "Pay", "id": "p", "from": "Client", "to": "Bank", "cause": "q"}],
    [{"msg": "SoldOut", "from": "Shop", "to": "Client", "cause": "o"}]]}]}"#)
#guard strs (field hold "issues") == ["Bank cannot tell which branch Shop chose"]
#guard (((field hold "projections").getObjValD "Bank").getObjValAs? String "error").toOption ==
  some "Bank cannot tell which branch Shop chose"

def borrowed := call check (withProtocol r#"{"roles": ["Client", "Shop", "Bank"], "steps": [
  {"msg": "Order", "id": "o", "from": "Client", "to": "Shop"},
  {"msg": "Paid", "from": "Bank", "to": "Shop", "cause": "o"}]}"#)
#guard (strs (field borrowed "issues")).contains "Paid: Bank never saw o"

-- with mayCall every channel is HTTP: Paid answers the client's call but goes to the shop
def purchase : String := r#"{"roles": ["Client", "Shop", "Bank"], "steps": [
  {"msg": "Order", "id": "o", "from": "Client", "to": "Shop"},
  {"choice": [
    [{"msg": "Quote", "id": "q", "from": "Shop", "to": "Client", "cause": "o"},
     {"msg": "Pay", "id": "p", "from": "Client", "to": "Bank", "cause": "q", "where": "p.amount = q.price"},
     {"msg": "Paid", "from": "Bank", "to": "Shop", "cause": "p"},
     {"msg": "Shipped", "from": "Shop", "to": "Client"}],
    [{"msg": "SoldOut", "from": "Shop", "to": "Client", "cause": "o"}]]}]}"#
def http := call check (withProtocol purchase r#", "mayCall": [["Client", "Shop"], ["Client", "Bank"], ["Shop", "Bank"]]"#)
#guard strs (field http "httpCuts") ==
  [ "Paid answers p, which Client sent to Bank, but goes to Shop"
  , "Shipped is a request from Shop to Client, which Shop may not call" ]
#guard verdict http == "issues"
-- a where text is shown in the diagram, never evaluated
#guard ((field (call diagram (withProtocol purchase)) "svg").getStr?.toOption.getD "").contains "[p.amount = q.price]"

-- rejections name the step
def rejects (p : String) (needle : String) : Bool :=
  let r := call check (withProtocol p)
  verdict r == "rejected" && (reason r).contains needle
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X", "from": "A", "to": "C"}]}"# "steps[0]: to names C"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X", "from": "A", "to": "B", "colour": "red"}]}"# "unknown keys [colour]"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"send": "X"}]}"# "unknown step"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X", "event": "Y", "from": "A", "to": "B"}]}"# "exactly one kind"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"choice": [[{"continue": "L"}]]}]}"# "steps[0].choice[0].steps[0]: continue L is not inside rec L"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"rec": "L", "steps": [{"continue": "L"}, {"msg": "X", "from": "A", "to": "B"}]}]}"# "must be the last step"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"join": 3, "of": [[], []]}]}"# "out of range"
#guard rejects r#"{"roles": ["A", "A"], "steps": []}"# "distinct"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X\u0007", "from": "A", "to": "B"}]}"# "control character"
#guard rejects r#"{"roles": [], "steps": []}"# "at least one role"
#guard rejects r#"{"roles": ["A", "B"], "steps": [], "code": "rm -rf /"}"# "unknown keys [code]"
#guard verdict (call check "{}") == "rejected"
-- the limits hold
def manyRoles : String := "{\"roles\": [" ++ ",".intercalate ((List.range 13).map fun i => s!"\"R{i}\"") ++ "], \"steps\": []}"
#guard rejects manyRoles "at most 12 roles"
def manySteps : String := "{\"roles\": [\"A\", \"B\"], \"steps\": [" ++
  ",".intercalate ((List.range 201).map fun _ => "{\"msg\": \"X\", \"from\": \"A\", \"to\": \"B\"}") ++ "]}"
#guard rejects manySteps "more than 200 steps"
def deep : Nat → String
  | 0 => "[]"
  | n + 1 => "[{\"par\": [" ++ deep n ++ "]}]"
#guard rejects ("{\"roles\": [\"A\"], \"steps\": " ++ deep 30 ++ "}") "nested more than 24 deep"

-- a simulation is bounded, deterministic, and fits the result limit, saying what it left out
def sim (extra : String) := call simulate (withProtocol placeOrder extra)
#guard verdict (sim r#", "seed": 7, "instances": 20"#) == "generated"
#guard (field (sim r#", "seed": 7, "instances": 20"#) "sessions") == toJson 20
#guard (sim r#", "seed": 7"#).toOption.map (·.compress) == (sim r#", "seed": 7"#).toOption.map (·.compress)
#guard verdict (sim r#", "instances": 201"#) == "rejected"
#guard verdict (sim r#", "maxEvents": 601"#) == "rejected"
def big := sim r#", "seed": 3, "instances": 200, "maxEvents": 600, "spread": 400"#
#guard (big.toOption.map (·.compress.length)).getD 0 ≤ limits.maxResult
#guard !(strs (field big "omitted")).isEmpty || (big.toOption.map (·.compress.length)).getD 0 ≤ limits.maxResult

-- the light theme is a real theme
#guard ((field (call diagram (withProtocol placeOrder r#", "theme": "light""#)) "svg").getStr?.toOption.getD "").contains "#ffffff"

end LeanFM.SessionToolsTests
