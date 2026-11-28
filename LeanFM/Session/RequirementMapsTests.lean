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
#guard (mapOf (withMap "  \"placed\" => PlaceOrder;\n  \"pay\" => PlaceOrder ⊨ (AG (implies (on Pay) (AX (on Charge))));\n  \"refunds\" => sorry \"later\";\n  \"bare\" => sorry;\n")).toOption ==
  some [("placed", .protocol "PlaceOrder"), ("pay", .formula "PlaceOrder" "(AG (implies (on Pay) (AX (on Charge))))"),
       ("refunds", .sorry_ "later"), ("bare", .sorry_ "")]
-- refused: an unknown protocol (an error, not a sorry), a duplicate, an empty or long name, an
-- unbalanced formula, a second map, an item after the map
#guard refused (withMap "  \"x\" => placeOrder;\n") "no protocol placeOrder is defined in this file"
#guard refused (withMap "  \"x\" => sorry;\n  \"x\" => sorry;\n") "is in the map twice"
#guard refused (withMap "  \"\" => sorry;\n") "must not be empty"
#guard refused (withMap ("  \"" ++ "".pushn 'n' 201 ++ "\" => sorry;\n")) "at most 200 characters"
#guard refused (withMap "  \"x\" => PlaceOrder ⊨ (AG (on Pay);\n") "parentheses close"
#guard refused (withMap "  \"x\" => sorry;\n" ++ "requirements {\n}\n") "the requirements map is the file's last item"
#guard refused (withMap "  \"x\" => sorry;\n" ++ "protocol Q (A, B) { M from A to B; }\n") "the requirements map is the file's last item"

-- an implementation block: refinements, evidence, own CTL and hints
def impl := "import LeanFM.Session.Syntax\nimplementation Go of Orders.Requirements {\n  refines PlaceOrder by ShopImpl;\n  \"placed\" => conform \"logs/o.jsonl\";\n  \"pay\" => test \"PayTests.ok\";\n  \"refunds\" => sorry;\n  \"own\" => ShopImpl ⊨ (AG (EF stop));\n  hint \"Implement as Go\";\n}\n"
#guard match Text.readMaps impl with
  | .ok (_, a) => match a.impls.toList with
    | [d] => d.name == "Go" && d.of == "Orders.Requirements" && d.refines == [("PlaceOrder", "ShopImpl")] &&
        d.entries == [("placed", .conform "logs/o.jsonl"), ("pay", .test "PayTests.ok"), ("refunds", .pointer (.sorry_ "")),
          ("own", .pointer (.formula "ShopImpl" "(AG (EF stop))"))] && d.hints == ["Implement as Go"]
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
#guard (checkPointer two (.formula "PlaceOrder" "(AG (EF stop))")).met
#guard let c := checkPointer two (.formula "PlaceOrder" "(AG (not (on Pay)))"); !c.met && c.failing && c.verdict == "disproved"
#guard (checkPointer two (.formula "PlaceOrder" "(AG (bogus")).failing
#guard let c := checkPointer two (.sorry_ "why"); c.usesSorry && !c.met && !c.failing
#guard (checkPointer two (.protocol "Nope")).failing
#guard let h := hintChecked; !h.met && !h.failing && !h.usesSorry && h.verdict == "true"
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
-- a formula requirement judged on the run: tested, pending (not shown yet) or refuted with its counterexample
#guard let c := checkConform two (.formula "PlaceOrder" "(stronglyImplies (on Pay) (inevitably (on Receipt)))") (.ok (run 10))
  c.met && c.verdict == "tested" && c.standing == "tested"
#guard let c := checkConform two (.formula "PlaceOrder" "(possibly (on Refund))") (.ok (run 10))
  !c.met && !c.failing && c.verdict == "pending"
#guard let c := checkConform two (.formula "PlaceOrder" "(never (on Charge))") (.ok (run 10))
  c.failing && c.verdict == "refuted" && (c.reading.splitOn "counterexample: the first 4 events").length > 1 && (c.reading.splitOn "c1").length > 1
#guard let c := checkConform two (.formula "PlaceOrder" "(always (at s1))") (.ok (run 10))
  c.usesSorry && c.verdict == "unjudged"

-- the computed standing: proved, tested, sorry, failing; a bare test name is sorry
#guard status (checkPointer two (.protocol "PlaceOrder")) (some (checkConform two (.protocol "PlaceOrder") (.ok (run 10)))) == "proved"
#guard status (checkPointer two (.protocol "PlaceOrder")) (some (testChecked "t")) == "sorry"
#guard (testChecked "t").usesSorry && !(testChecked "t").met
#guard status (checkPointer two (.protocol "PlaceOrder")) none == "sorry"
#guard status (sorryChecked "") (some (checkConform two (.protocol "PlaceOrder") (.ok (run 10)))) == "tested"
#guard status (sorryChecked "") none == "sorry"
#guard status (checkPointer two (.formula "PlaceOrder" "(AG (not (on Pay)))")) (some (sorryChecked "")) == "failing"
#guard (checkPointer two (.protocol "PlaceOrder")).standing == "proved"
#guard (sorryChecked "").standing == "sorry"

-- proof evidence, judged from proofs.json (selfhost.requirements.proofs)
def proofs : Json := Json.mkObj [
  ("Good", Json.mkObj [("exists", true), ("axioms", Json.arr #["propext"]), ("sorryFree", true)]),
  ("Bad", Json.mkObj [("exists", true), ("axioms", Json.arr #["sorryAx"]), ("sorryFree", false)]),
  ("Gone", Json.mkObj [("exists", false), ("axioms", Json.arr #[]), ("sorryFree", false)])]
#guard let c := proofChecked "Good" (some proofs); c.met && c.verdict == "proof" && c.standing == "proved"
#guard let c := proofChecked "Bad" (some proofs); c.failing && (c.reading.splitOn "rests on sorry").length > 1
#guard (proofChecked "Gone" (some proofs)).failing
#guard let c := proofChecked "Unlisted" (some proofs); c.usesSorry && !c.met && !c.failing
#guard (proofChecked "Good" none).usesSorry
-- pure evidence: a walk with no problem is proved and names its exceptions; a problem is failing
def purity : Lean.Json := Lean.Json.mkObj
  [("pure A.f", Lean.Json.mkObj [("exists", true), ("reached", (12 : Nat)), ("problems", Lean.Json.arr #[]), ("exceptions", Lean.Json.arr #["X: a cache"])]),
   ("pure A.g", Lean.Json.mkObj [("exists", true), ("reached", (3 : Nat)), ("problems", Lean.Json.arr #["A.h has IO in its type"]), ("exceptions", Lean.Json.arr #[])])]
#guard let c := pureChecked "A.f" (some purity); c.met && c.standing == "proved" && (c.reading.splitOn "X: a cache").length > 1
#guard let c := pureChecked "A.g" (some purity); c.failing && (c.reading.splitOn "has IO in its type").length > 1
#guard (pureChecked "A.k" (some purity)).usesSorry
-- readonly evidence reads its own lines
def ro : Lean.Json := Lean.Json.mkObj
  [("readonly A.f", Lean.Json.mkObj [("exists", true), ("reached", (9 : Nat)), ("problems", Lean.Json.arr #["reaches IO.FS.writeFile"]), ("exceptions", Lean.Json.arr #[])])]
#guard let c := pureChecked "A.f" (some ro) (kind := "readonly"); c.failing && (c.reading.splitOn "IO.FS.writeFile").length > 1
#guard (pureChecked "A.f" (some purity) (kind := "readonly")).usesSorry
#guard status (sorryChecked "") (some (proofChecked "Good" (some proofs))) == "proved"
#guard status (sorryChecked "") (some (proofChecked "Bad" (some proofs))) == "failing"
#guard match Text.readMaps "import LeanFM.Session.Syntax\nimplementation Go of Orders.Requirements {\n  \"pay\" => proof \"Orders.payProof\";\n}\n" with
  | .ok (_, a) => a.impls.toList.any fun d => d.entries == [("pay", .proof "Orders.payProof")]
  | .error _ => false

-- short names: an identifier before the sentence, unique in the map
#guard match Text.readText (withMap "  Placed \"placed\" => PlaceOrder;\n  \"pay\" => PlaceOrder ⊨ (AG (EF stop));\n") with
  | .ok (_, a) => a.reqShort.toList == [("Placed", "placed")] && (a.reqMap.getD #[]).size == 2
  | .error _ => false
#guard refused (withMap "  A \"x\" => sorry;\n  A \"y\" => sorry;\n") "the short name A is in the map twice"

-- a nested session is judged with the session around it (selfhost.requirements.standing)
def nest := "protocol Nest (A, B) {\n  i: Init from A to B;\n  sessions {\n    q: Q from A to B;\n    R from B to A cause q;\n  }\n}\n"
def nested : Json := Json.arr #[
  Json.mkObj [("id", "i1"), ("session", "s"), ("from", "A"), ("to", "B"), ("label", "Init")],
  Json.mkObj [("id", "q1"), ("session", "s-1"), ("from", "A"), ("to", "B"), ("label", "Q"), ("prev", Json.arr #["i1"])],
  Json.mkObj [("id", "r1"), ("session", "s-1"), ("from", "B"), ("to", "A"), ("label", "R"), ("cause", "q1")]]
#guard let c := checkConform nest (.formula "Nest" "(precedes (on Init) (on Q))") (.ok nested)
  c.met && c.verdict == "tested" && (c.reading.splitOn "1 run of the log").length > 1
end LeanFM.Session.RequirementMapsTests

-- the two block words stay identifiers in a module that imports the library, so a project's own
-- Project.Requirements.requirements and Project.Implementation.implementation still elaborate
namespace Project.Requirements
def requirements : Nat := 1
end Project.Requirements
namespace Project.Implementation
def implementation : Nat := 2
end Project.Implementation
#guard Project.Requirements.requirements + Project.Implementation.implementation == 3
