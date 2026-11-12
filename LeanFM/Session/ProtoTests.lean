import LeanFM.SessionTools
import LeanFM.Generated.PlaceOrder

/-! Tests for selfhost.session.proto and selfhost.session.lean (decision session-proto). The session
type is the source: from it LeanFM writes the .proto, the Lean module (payload types, events and
each role's states) and the OpenAPI document. An existing .proto can also be read in its place. -/
namespace LeanFM.Session.ProtoTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def order := include_str "../../examples/sessions/PlaceOrder.leanfm"
def args (extra : List (String × Json) := []) (text : String := order) : Json :=
  Json.mkObj ([("lean", Json.str text)] ++ extra)
def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def has (s part : String) : Bool := (s.splitOn part).length > 1

/-- The .proto LeanFM writes from the session type, without the envelope it appends. -/
def proto : String := ((str (types (args)) "proto").splitOn "// The event envelope").head!
/-- The protocol alone, its structures left out, for reading the types from the .proto instead. -/
def protocolOnly : String := "/-- Placing an order" ++ (order.splitOn "/-- Placing an order").getLast!

/-! Reading proto3 -/

def env := (Proto.ofProto proto).toOption.getD []
-- the written .proto reads back as the session type's structures: the round trip keeps names, fields, numbers and docs
#guard env.map (·.name) == ["CreateOrder", "Quote", "Pay", "Charge", "Receipt", "Charged", "Declined", "PaymentDeclined", "SoldOut"]
#guard (env.filter (!·.fields.isEmpty)).map (fun m => (m.name, m.fields.map (·.name), m.doc)) ==
  ((Text.parse order).toOption.map (·.types.map fun m => (m.name, m.fields.map (·.name), m.doc))).getD []
#guard (env.find? (·.name == "Pay")).map (·.fields.map fun f => (f.name, f.ty.render, f.number)) == some [("amount", "Nat", 1), ("card_secr", "String", 2)]
#guard (env.find? (·.name == "Quote")).map (·.doc) == some "The shop's price for the order, in cents."
-- numbers, repetition and options as protobuf writes them; the field numbers are kept
def mixed := "syntax = \"proto3\";\nmessage Ship {\n  int64 delta = 3;\n  repeated string items = 1;\n  optional uint32 floor = 7 [deprecated = true];\n  reserved 2;\n  Address to = 4;\n}\nmessage Address { string city = 1; }"
#guard ((Proto.ofProto mixed).toOption.map fun e => (e.head!.fields.map fun f => (f.name, f.ty.render, f.number))) ==
  some [("delta", "Int", 3), ("items", "List String", 1), ("floor", "Option Nat", 7), ("to", "Address", 4)]
#guard has ((Types.proto ((Proto.ofProto mixed).toOption.getD []) ["Ship"] "p").toOption.getD "") "  optional uint64 floor = 7;"

def refuses (text part : String) : Bool := match Proto.ofProto text with | .error e => has e part | .ok _ => false
-- negative: inexact, untyped or unread constructs, numbers outside protobuf's range, and anything
-- outside the given text are refused
#guard refuses "syntax = \"proto3\";\nmessage M { double x = 1; }" "not exact"
#guard refuses "syntax = \"proto3\";\nmessage M { bytes x = 1; }" "bytes"
#guard refuses "syntax = \"proto3\";\nimport \"other.proto\";" "imports are not followed"
#guard refuses "syntax = \"proto3\";\nmessage M { message N { } }" "inside a message is not read yet"
#guard refuses "syntax = \"proto3\";\nmessage M { oneof o { string a = 1; } }" "inside a message is not read yet"
#guard refuses "syntax = \"proto3\";\nmessage M { string a = 19500; }" "reserved 19000 to 19999"
#guard refuses "syntax = \"proto3\";\nmessage M { string a = 1; string b = 1; }" "two fields have number 1"
#guard refuses "syntax = \"proto2\";\nmessage M { }" "LeanFM reads proto3"
#guard refuses "message M { }" "syntax = \"proto3\""
#guard refuses "syntax = \"proto3\";\nmessage Event { }" "Event is the envelope"
#guard refuses "syntax = \"proto3\";\nmessage M { N n = 1; }" "N is not a declared structure"
#guard refuses "syntax = \"proto3\";\nmessage M { string class = 1; }" "keyword"

/-! The session type is the source; an existing .proto can stand in for its structures -/

#guard str (check (args)) "verdict" == "ok"
#guard has (reason (check (args [] (order.replace "where p.amount = q.price" "where p.total = q.price")))) "Pay has no field total"
-- the protocol alone with the .proto checks the same; with both, the types would have two sources
#guard str (check (args [("proto", Json.str proto)] protocolOnly)) "verdict" == "ok"
#guard has (reason (check (args [("proto", Json.str proto)]))) "the message types come from the .proto"
#guard has (reason (check (args [] protocolOnly))) "Pay has no field amount"

-- the OpenAPI document is the session type's HTTP calls with its messages as bodies
def shopApi := openapi (args [("role", "Shop")])
#guard (match shopApi with
  | .ok j => ((((j.getObjValD "openapi").getObjValD "components").getObjValD "schemas").getObjValD "Quote").compress ==
      "{\"additionalProperties\":false,\"description\":\"The shop's price for the order, in cents.\",\"properties\":{\"price\":{\"minimum\":0,\"type\":\"integer\"}},\"required\":[\"price\"],\"title\":\"Quote\",\"type\":\"object\"}"
  | .error _ => false)
-- the .proto keeps every field's number and adds the envelope
#guard has (str (types (args)) "proto") "message Pay {\n  uint64 amount = 1;\n  string card_secr = 2;\n}"
#guard has (str (types (args)) "proto") "message Event {"

/-! The session as a Lean module: checked in, compiled with the library, and run here -/

-- the checked-in module is what session_types generates from the session type
#guard (match types (args) with
  | .ok j => j.getObjValD "leanModule" == Json.str (include_str "../Generated/PlaceOrder.lean")
  | .error _ => false)

open PlaceOrder in
def run : List PlaceOrder.Event :=
  [ { ts := 1, session := "7", src := .client, dst := .shop, payload := .createOrder { item := "tea", quantity := 2 } },
    { ts := 2, session := "7", src := .shop, dst := .client, cause := some 1, payload := .quote { price := 10 } },
    { ts := 3, session := "7", src := .client, dst := .shop, cause := some 2, payload := .pay { amount := 10, card_secr := "4242" } },
    { ts := 4, session := "7", src := .shop, dst := .bank, cause := some 3, payload := .charge { amount := 10, card_secr := "4242" } },
    { ts := 5, session := "7", src := .bank, dst := .shop, cause := some 4, payload := .charged {} },
    { ts := 6, session := "7", src := .shop, dst := .client, cause := some 5, payload := .receipt { amount := 10 } } ]
-- every role accepts the whole session, each through its own view of it
#guard PlaceOrder.Client.accepts run && PlaceOrder.Shop.accepts run && PlaceOrder.Bank.accepts run
-- the client's run stops short of the end, and the shop cannot charge before it is paid
#guard !PlaceOrder.Client.accepts (run.take 3)
#guard !PlaceOrder.Shop.accepts ((run.take 2) ++ (run.drop 3))
-- the bank takes no part when the shop is sold out, so its empty run is complete
#guard PlaceOrder.Bank.accepts [{ ts := 1, session := "8", src := .client, dst := .shop, payload := .createOrder { item := "tea", quantity := 1 } },
  { ts := 2, session := "8", src := .shop, dst := .client, payload := .soldOut {} }]
-- the step function is the projection: from the client's start, only CreateOrder to the shop moves it
#guard (run[1]?.bind (PlaceOrder.Client.step .s0)) == none && (run[0]?.bind (PlaceOrder.Client.step .s0)) == some .s1

-- roles whose projection serves sessions or runs branches in parallel are refused, with the reason
def lending := include_str "../../examples/vibecode/lending/Lending.protocol"
#guard has (str (types (Json.mkObj [("lean", Json.str lending)])) "leanModuleNote") "serves sessions"

end LeanFM.Session.ProtoTests
