import LeanFM.SessionTools
import Lean.Data.Json.Elab

/-! Tests for selfhost.session.types (decision session-types): every message has a Lean structure
type; conditions are typed against them before anything runs; logs are checked against them; the
generated forms are written from them. -/
namespace LeanFM.Session.TypesTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def order := include_str "../../examples/sessions/PlaceOrder.leanfm"

def args (text : String) (extra : List (String × Json) := []) : Json := Json.mkObj ([("lean", Json.str text)] ++ extra)
def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""
def refuses (text part : String) : Bool := (reason (check (args text))).contains part
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def has (s part : String) : Bool := (s.splitOn part).length > 1

/-! The declarations: Lean structures, read as written -/

def parsed := (Text.parse order).toOption.get!
#guard parsed.types.map (·.name) == ["CreateOrder", "Quote", "Pay", "Charge", "Receipt"]
#guard (parsed.types.find? (·.name == "Pay")).map (·.fields.map fun f => (f.name, f.ty.render)) ==
  some [("amount", "Nat"), ("card_secr", "String")]
-- the doc comment before a structure documents it
#guard (parsed.types.find? (·.name == "Quote")).map (·.doc) == some "The shop's price for the order, in cents."
-- one line, as GoServer's specs write them, with deriving accepted and ignored
#guard ((Text.parse "structure Ask where id : Nat deriving TypeName, Repr\nprotocol P (A, B) { a: Ask from A to B where a.id > 0; }").toOption.map (·.types.length)) == some 1
-- a move in a game: Play carries a point, Pass carries nothing; x y : Nat declares both, as in Lean
def go := "structure Play where x y : Nat\nstructure Pass\nprotocol Move (Black, White) { choice { m: Play from Black to White where m.x < 19 and m.y < 19; } or { Pass from Black to White; } }"
#guard ((Text.parse go).toOption.map fun p => p.types.map fun m => (m.name, m.fields.map (·.name))) == some [("Play", ["x", "y"]), ("Pass", [])]
#guard has (str (types (args go)) "proto") "message Play {\n  uint64 x = 1;\n  uint64 y = 2;\n}"
-- List, Option and nested structures
def nested := "structure Address where\n  city : String\nstructure Ship where\n  to : Address\n  notes : Option String\n  items : List String\nprotocol P (A, B) { s: Ship from A to B where s.to.city = \"Oslo\"; }"
#guard (check (args nested)) matches .ok _

-- negative: names that resolve to nothing, cycles, repeats, keywords, no protobuf form, limits
#guard refuses "structure X where y : Missing\nprotocol P (A, B) { X from A to B; }" "Missing is not a declared structure"
#guard refuses "structure X where y : Y\nstructure Y where x : X\nprotocol P (A, B) { X from A to B; }" "contains itself"
#guard refuses "structure X where y : Nat\nstructure X where z : Nat\nprotocol P (A, B) { X from A to B; }" "declared twice"
#guard refuses "structure X where\n  y : Nat\n  y : Int\nprotocol P (A, B) { X from A to B; }" "two fields named y"
#guard refuses "structure X where class : Nat\nprotocol P (A, B) { X from A to B; }" "keyword"
#guard refuses "structure X where y : List List\nprotocol P (A, B) { X from A to B; }" "holds one plain type"
#guard refuses "structure X where y : Option (List Nat)\nprotocol P (A, B) { X from A to B; }" "holds one plain type"
#guard refuses "structure Nat where y : Int\nprotocol P (A, B) { X from A to B; }" "built-in type"
#guard refuses "structure X where y : Nat := 3\nprotocol P (A, B) { X from A to B; }" "default values"
#guard refuses "protocol P (A, B) { X from A to B; }\nstructure X where y : Nat" "structures come before the protocols"
#guard refuses (String.join ((List.range 257).map fun i => s!"structure T{i}\n") ++ "protocol P (A, B) { X from A to B; }") "at most 256 structures"

/-! Conditions are typed before anything runs -/

def typed (cond : String) : String :=
  reason (check (args (order.replace "where p.amount = q.price" s!"where {cond}")))
#guard typed "p.amount = q.price" == ""
#guard typed "p.amount + 1 > q.price * 2 and not (p.amount = 0)" == ""
#guard has (typed "p.total = q.price") "Pay has no field total; the fields of Pay are amount, card_secr"
#guard has (typed "p.amount = \"ten\"") "p.amount is a number and \"ten\" is a string"
#guard has (typed "p.amount + q.price") "the condition is a number, not true or false"
#guard has (typed "p = q") "p is a whole message"
#guard has (typed "z.amount = 1") "z is not a message id"
#guard has (typed "o.item > 3") "compares two numbers or two strings"
-- a message whose label names no structure carries nothing
#guard has (typed "p.amount = d.amount") "Charged carries no fields"
-- the fields conditions read are logged, so a condition may not read a secret
#guard has (typed "p.card_secr = \"4242\"") "may not read a secret"
-- a list, or a whole nested structure, is not a single value
#guard refuses (nested.replace "s.to.city = \"Oslo\"" "s.items = \"x\"") "is a list"
#guard refuses (nested.replace "s.to.city = \"Oslo\"" "s.to = \"x\"") "is a Address"
-- copies of a bounded loop read their own ids
def retry := "structure Try where n : Nat\nprotocol R (A, B) { rec Again at most 2 { t: Try from A to B where t.n > 0; choice { Ok from B to A cause t; } or { No from B to A cause t; continue Again; } } otherwise { GiveUp from A to B; } }"
#guard (check (args retry)) matches .ok _

/-! Logs are checked against the types -/

def ev (id label src dst : String) (cause : Option String := none) (fields : Option Json := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", "1"), ("from", Json.str src), ("to", Json.str dst), ("label", Json.str label)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [] ++ (fields.map fun f => [("fields", f)]).getD [])
def log (quote pay : Json) : Except String Json := conform (args order [("allowIncomplete", Json.bool true), ("events", Json.arr #[
  ev "e1" "CreateOrder" "Client" "Shop", ev "e2" "Quote" "Shop" "Client" (some "e1") (some quote),
  ev "e3" "Pay" "Client" "Shop" (some "e2") (some pay)])])
#guard str (log (json% {price: 10}) (json% {amount: 10})) "verdict" == "conforms"
#guard has (reason (log (json% {price: 10}) (json% {amount: 10, tip: 2}))) "event e3: Pay has no field tip"
#guard has (reason (log (json% {price: "ten"}) (json% {amount: 10}))) "event e2: Quote.price is Nat, and \"ten\" is not a decimal integer"
-- integers travel as decimal strings (selfhost.session.envelope): exact past 2^53, where doubles are not
#guard str (log (json% {price: "10"}) (json% {amount: "10"})) "verdict" == "conforms"
#guard str (log (json% {price: "9007199254740993"}) (json% {amount: "9007199254740993"})) "verdict" == "conforms"
#guard str (log (json% {price: "9007199254740993"}) (json% {amount: "9007199254740992"})) "verdict" == "violates"
#guard has (reason (log (json% {price: 9007199254740993}) (json% {amount: 10}))) "beyond 2^53 - 1, where JSON numbers are not exact; send it as a decimal string"
#guard has (reason (log (json% {price: 10.5}) (json% {amount: 10}))) "is not a whole number"
#guard has (reason (log (json% {price: -1}) (json% {amount: 10}))) "Quote.price is a Nat, and the log has -1"
#guard has (reason (log (json% {price: 10}) (json% {amount: 10, card_secr: "4242"}))) "the log carries the secret Pay.card_secr"
#guard has (reason (conform (args order [("allowIncomplete", Json.bool true), ("events", Json.arr #[
  ev "e1" "CreateOrder" "Client" "Shop" none (some (json% {item: "tea", quantity: 2})),
  ev "e2" "SoldOut" "Shop" "Client" (some "e1") (some (json% {why: "none"}))])]))) "SoldOut has no field why; SoldOut carries no fields"

/-! The generated forms -/

def ty := types (args order)
#guard has (str ty "proto") "message Pay {\n  uint64 amount = 1;\n  string card_secr = 2;\n}"
#guard has (str ty "proto") "// The shop's price for the order, in cents.\nmessage Quote {"
#guard has (str ty "proto") "message SoldOut {\n}"
#guard has (str ty "leanTypes") "structure Pay where\n  amount : Nat\n  card_secr : String\n  deriving Repr, BEq, Lean.ToJson, Lean.FromJson"
#guard has (str ty "leanTypes") "structure SoldOut\n  deriving"
#guard has (str (types (args nested)) "proto") "message Ship {\n  Address to = 1;\n  optional string notes = 2;\n  repeated string items = 3;\n}"
-- a structure comes before the structures that use it, as Lean needs
#guard has (str (types (args nested)) "leanTypes") "structure Address where\n  city : String\n  deriving Repr, BEq, Lean.ToJson, Lean.FromJson\n\nstructure Ship where"
#guard (match ty with
  | .ok j => (((j.getObjValD "schemas").getObjValD "Pay").getObjValD "additionalProperties") == Json.bool false
  | .error _ => false)
-- OpenAPI bodies are the message types, closed
def shopApi := openapi (args order [("role", "Shop")])
#guard (match shopApi with
  | .ok j => ((((j.getObjValD "openapi").getObjValD "components").getObjValD "schemas").getObjValD "CreateOrder").compress ==
      "{\"additionalProperties\":false,\"description\":\"What the client orders.\",\"properties\":{\"item\":{\"type\":\"string\"},\"quantity\":{\"minimum\":0,\"type\":\"integer\"}},\"required\":[\"item\",\"quantity\"],\"title\":\"CreateOrder\",\"type\":\"object\"}"
  | .error _ => false)
-- skeletons: a dataclass or interface per message, and send methods take it
def code (lang : String) : String := str (skeleton (args order [("language", Json.str lang)])) "code"
#guard has (code "python") "@dataclass\nclass Pay:\n    \"\"\"The client pays; the card number is a secret, never logged.\"\"\"\n    amount: int\n    card_secr: str"
#guard has (code "python") "def send_pay(self, body: Pay):"
#guard has (code "python") "def send_sold_out(self, body: Optional[SoldOut] = None):"
#guard has (code "typescript") "export interface Pay {\n  amount: bigint;\n  card_secr: string;\n}"
#guard has (code "typescript") "sendPay(body: Pay): "
#guard has (code "typescript") "export type SoldOut = Record<string, never>;"
-- a message type may not take the name of a class the module defines
#guard has (reason (skeleton (args "structure Endpoint where n : Nat\nprotocol P (A, B) { Endpoint from A to B; }"))) "same Python name as a class"

/-! The JSON form declares types too, and carries nothing else through them -/

def jsonForm (types : String) : Except String Json :=
  check ((Json.parse ("{\"protocol\": {\"roles\": [\"A\", \"B\"], \"types\": " ++ types ++
    ", \"steps\": [{\"msg\": \"Ask\", \"id\": \"a\", \"from\": \"A\", \"to\": \"B\", \"where\": \"a.n > 0\"}]}}")).toOption.getD Json.null)
#guard (jsonForm "[{\"name\": \"Ask\", \"fields\": [\"n : Nat\"]}]") matches .ok _
#guard has (reason (jsonForm "[]")) "Ask has no field n"
#guard has (reason (jsonForm "[{\"name\": \"Ask\", \"fields\": [\"n : Nat\\nprotocol Q (A) { }\"]}]")) "a field is written"

end LeanFM.Session.TypesTests
