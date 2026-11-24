import LeanFM.RequirementCtl

/-! Tests for selfhost.requirements.map and selfhost.implementations.map (decision requirement-maps):
the maps read as written, every forbidden shape is refused, and each kind converts to CTL. -/
namespace LeanFM.Session.RequirementMapsTests
open Lean LeanFM.Session LeanFM.RequirementCtl

def order := include_str "../../examples/sessions/PlaceOrder.leanfm"
def withMap (body : String) : String := order ++ "\nrequirements {\n" ++ body ++ "}\n"
def mapOf (t : String) : Except String (List (String × Text.Pointer)) :=
  (Text.readText t).map fun (_, a) => (a.reqMap.getD #[]).toList
def refused (t part : String) : Bool := match Text.readText t with
  | .error e => (e.splitOn part).length > 1 | .ok _ => false

-- a map with each pointer kind
#guard (mapOf (withMap "  \"placed\" => PlaceOrder;\n  \"pay\" => PlaceOrder ⊨ (AG (implies (after Pay) (AX (after Charge))));\n  \"refunds\" => sorry \"later\";\n  \"bare\" => sorry;\n")).toOption ==
  some [("placed", .protocol "PlaceOrder"), ("pay", .formula "PlaceOrder" "(AG (implies (after Pay) (AX (after Charge))))"),
       ("refunds", .sorry_ "later"), ("bare", .sorry_ "")]
-- refused: an unknown protocol (an error, not a sorry), a duplicate, an empty or long name, an
-- unbalanced formula, a second map, an item after the map
#guard refused (withMap "  \"x\" => placeOrder;\n") "no protocol placeOrder is defined in this file"
#guard refused (withMap "  \"x\" => sorry;\n  \"x\" => sorry;\n") "is in the map twice"
#guard refused (withMap "  \"\" => sorry;\n") "must not be empty"
#guard refused (withMap ("  \"" ++ "".pushn 'n' 201 ++ "\" => sorry;\n")) "at most 200 characters"
#guard refused (withMap "  \"x\" => PlaceOrder ⊨ (AG (after Pay);\n") "parentheses close"
#guard refused (withMap "  \"x\" => sorry;\n" ++ "requirements {\n}\n") "the requirements map is the file's last item"
#guard refused (withMap "  \"x\" => sorry;\n" ++ "protocol Q (A, B) { M from A to B; }\n") "the requirements map is the file's last item"

-- an implementation block: refinements, evidence, own CTL and hints
def impl := "import LeanFM.Session.Syntax\nimplementation Go of Orders.Requirements {\n  refines PlaceOrder by ShopImpl;\n  \"placed\" => conform \"logs/o.jsonl\";\n  \"pay\" => test \"PayTests.ok\";\n  \"refunds\" => sorry;\n  \"own\" => ShopImpl ⊨ (AG (EF terminal));\n  hint \"Implement as Go\";\n}\n"
#guard match Text.readMaps impl with
  | .ok (_, a) => match a.impls.toList with
    | [d] => d.name == "Go" && d.of == "Orders.Requirements" && d.refines == [("PlaceOrder", "ShopImpl")] &&
        d.entries == [("placed", .conform "logs/o.jsonl"), ("pay", .test "PayTests.ok"), ("refunds", .pointer (.sorry_ "")),
          ("own", .pointer (.formula "ShopImpl" "(AG (EF terminal))"))] && d.hints == ["Implement as Go"]
    | _ => false
  | .error _ => false
-- a file of only an implementation reads for its maps, never as a protocol for the session tools
#guard (Text.readText impl).toOption.isNone
#guard match Text.readMaps (impl.replace "  \"refunds\" => sorry;\n" "  \"pay\" => sorry;\n") with
  | .error e => (e.splitOn "is in implementation Go twice").length > 1 | .ok _ => false
#guard match Text.readMaps (impl.replace "hint \"Implement as Go\"" "hint \"  \"") with
  | .error e => (e.splitOn "a hint must say something").length > 1 | .ok _ => false

-- textThrough cuts after the named protocol, so the session tools check that one
def two := order ++ "\nprotocol Ping (A, B) { M from A to B; }\nrequirements {\n  \"x\" => PlaceOrder;\n}\n"
#guard match Text.textThrough two "PlaceOrder" with
  | .ok t => (t.splitOn "protocol Ping").length == 1 && (t.splitOn "requirements {").length == 1 | .error _ => false
#guard (Text.textThrough two "Nope").toOption.isNone

-- each kind converts to CTL and is decided over the protocol it names
#guard (checkPointer two (.protocol "PlaceOrder")).met
#guard (checkPointer two (.formula "PlaceOrder" "(AG (EF terminal))")).met
#guard let c := checkPointer two (.formula "PlaceOrder" "(AG (not (after Pay)))"); !c.met && c.failing && c.verdict == "disproved"
#guard (checkPointer two (.formula "PlaceOrder" "(AG (bogus")).failing
#guard let c := checkPointer two (.sorry_ "why"); c.usesSorry && !c.met && !c.failing
#guard (checkPointer two (.protocol "Nope")).failing
#guard let h := hintChecked; !h.met && !h.failing && !h.usesSorry && h.verdict == "true"
-- the computed status
#guard status (checkPointer two (.protocol "PlaceOrder")) (some (testChecked "t")) == "met"
#guard status (checkPointer two (.protocol "PlaceOrder")) (some (sorryChecked "")) == "specified"
#guard status (checkPointer two (.protocol "PlaceOrder")) none == "specified"
#guard status (sorryChecked "") (some (testChecked "t")) == "tested"
#guard status (sorryChecked "") none == "sorry"
#guard status (checkPointer two (.formula "PlaceOrder" "(AG (not (after Pay)))")) (some (testChecked "t")) == "failing"
-- conform: a run that keeps the protocol meets it, one that breaks a where clause fails
def ev (i l s d : String) (c : Option String) (body : List (String × Json)) : Json :=
  Json.mkObj ([("id", Json.str i), ("label", Json.str l), ("from", Json.str s), ("to", Json.str d), ("body", Json.mkObj body)] ++
    (match c with | some x => [("cause", Json.str x)] | none => []))
def run (amount : Nat) : Json := Json.arr #[ev "o1" "CreateOrder" "Client" "Shop" none [("item", "tea"), ("quantity", (1 : Nat))],
  ev "q1" "Quote" "Shop" "Client" (some "o1") [("price", (10 : Nat))], ev "p1" "Pay" "Client" "Shop" (some "q1") [("amount", amount)],
  ev "c1" "Charge" "Shop" "Bank" (some "p1") [("amount", amount)], ev "d1" "Charged" "Bank" "Shop" (some "c1") [],
  ev "r1" "Receipt" "Shop" "Client" (some "d1") [("amount", amount)]]
#guard (checkConform two (.protocol "PlaceOrder") (.ok (run 10))).met
#guard (checkConform two (.protocol "PlaceOrder") (.ok (run 12))).failing
#guard (checkConform two (.sorry_ "") (.ok (run 10))).failing

end LeanFM.Session.RequirementMapsTests
