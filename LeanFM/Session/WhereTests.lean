import LeanFM.SessionTools
import Lean.Data.Json.Elab

/-! Tests for selfhost.session.where (decision session-where): where conditions are run. -/
namespace LeanFM.Session.WhereTests
open Lean LeanFM LeanFM.Session LeanFM.Session.Where LeanFM.SessionTools

def env (xs : List (String × List (String × Value))) : Lookup := fun x => xs.lookup x
def n (k : Int) : Value := .num k

-- the operators, precedence and exact arithmetic
#guard run "p.amount = q.price" (env [("p", [("amount", n 10)]), ("q", [("price", n 10)])]) == .yes
#guard run "p.amount = q.price" (env [("p", [("amount", n 12)]), ("q", [("price", n 10)])]) == .no
#guard run "a.x + 2 * 3 = 7" (env [("a", [("x", n 1)])]) == .yes
#guard run "(a.x + 2) * 3 = 9" (env [("a", [("x", n 1)])]) == .yes
#guard run "a.x / 3 * 3 = 1" (env [("a", [("x", n 1)])]) == .yes
#guard run "a.x = 0.25" (env [("a", [("x", .num (1/4 : Rat))])]) == .yes
#guard run "-a.x < 0 and not (a.x >= 5) or false" (env [("a", [("x", n 1)])]) == .yes
#guard run "a.s = \"ok\" && a.b != false" (env [("a", [("s", .str "ok"), ("b", .bool true)])]) == .yes
#guard run "a.card.last4 = \"4242\"" (env [("a", [("card.last4", .str "4242")])]) == .yes
-- Lean's symbols are accepted as input, as Lean accepts them
#guard run "a.x ≤ 3 ∧ ¬ (a.x ≠ 1) ∨ false" (env [("a", [("x", n 1)])]) == .yes
-- undecidable is unknown, with the reason, never true
#guard run "p.amount = q.price" (env [("p", [("amount", n 10)]), ("q", [])]) == .unknown "q.price is not in the log"
#guard run "p.amount = q.price" (env [("p", [("amount", n 10)])]) == .unknown "q has not happened in this session"
#guard run "a.x = \"10\"" (env [("a", [("x", n 10)])]) == .unknown "10 and \"10\" are different types"
#guard run "a.x / 0 = 1" (env [("a", [("x", n 1)])]) == .unknown "division by zero"
#guard run "IO.Process.exit 1" (env []) matches .unknown _
-- and/or decide on the left: a false guard is not hidden by a missing field
#guard run "a.x = 2 and a.missing = 1" (env [("a", [("x", n 1)])]) == .no
#guard (parse "p.amount = q.price").toOption.map Expr.paths == some [("p", "amount"), ("q", "price")]

/-! Conformance runs the conditions -/

def order := include_str "../../examples/sessions/PlaceOrder.leanfm"

def ev (id label src dst : String) (cause : Option String := none) (fields : Option Json := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", "42"), ("from", Json.str src), ("to", Json.str dst), ("label", Json.str label)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [] ++ (fields.map fun f => [("fields", f)]).getD [])

def paid (price amount : Nat) (withFields : Bool := true) : List Json :=
  [ ev "e1" "CreateOrder" "Client" "Shop"
  , ev "e2" "Quote" "Shop" "Client" (some "e1") (if withFields then some (Json.mkObj [("price", toJson price)]) else none)
  , ev "e3" "Pay" "Client" "Shop" (some "e2") (if withFields then some (Json.mkObj [("amount", toJson amount)]) else none)
  , ev "e4" "Charge" "Shop" "Bank" (some "e3"), ev "e5" "Charged" "Bank" "Shop" (some "e4")
  , ev "e6" "Receipt" "Shop" "Client" (some "e5") ]

def conformed (evs : List Json) : Json :=
  (conform (Json.mkObj [("lean", Json.str order), ("events", Json.arr evs.toArray)])).toOption.getD Json.null

def verdict (j : Json) : String := (j.getObjValD "verdict").getStr?.toOption.getD ""
def has (j : Json) (k s : String) : Bool := ((j.getObjValD k).compress.splitOn s).length > 1

#guard verdict (conformed (paid 10 10)) == "conforms" && (conformed (paid 10 10)).getObjValD "unchecked" == Json.arr #[]
#guard verdict (conformed (paid 10 12)) == "violates"
#guard has (conformed (paid 10 12)) "issues" "where p.amount = q.price is false: p.amount = 12, q.price = 10"
-- without fields it is not satisfied, it is unchecked, and the reading says so
#guard verdict (conformed (paid 10 10 false)) == "conforms" && has (conformed (paid 10 10 false)) "unchecked" "p.amount is not in the log"
#guard has (conformed (paid 10 10 false)) "reading" "1 where condition unchecked"

-- a guard selects between branches by data
def tiers := "structure Order where\n  total : Nat\n\nprotocol Tier (C, S) {\n  o: Order from C to S;\n  choice {\n    Gold from S to C cause o where o.total >= 100;\n  } or {\n    Plain from S to C cause o where o.total < 100;\n  }\n}"
def tier (total : Nat) (label : String) : Json :=
  (conform (Json.mkObj [("lean", Json.str tiers), ("events", Json.arr #[
    ev "e1" "Order" "C" "S" none (some (Json.mkObj [("total", toJson total)])), ev "e2" label "S" "C" (some "e1")])])).toOption.getD Json.null
#guard verdict (tier 150 "Gold") == "conforms" && verdict (tier 50 "Plain") == "conforms"
#guard verdict (tier 50 "Gold") == "violates" && has (tier 50 "Gold") "issues" "where o.total >= 100 is false: o.total = 50"

-- logged fields: nested objects are dotted paths; at most 64
#guard (logEvent (Json.mkObj [("id", "e"), ("from", "A"), ("to", "B"), ("label", "L"),
    ("fields", json% {card: {last4: "4242"}, n: 3})])).toOption.map (·.fields) ==
  some [("card.last4", .str "4242"), ("n", .num 3)]
#guard ((logEvent (Json.mkObj [("id", "e"), ("from", "A"), ("to", "B"), ("label", "L"),
    ("fields", Json.mkObj ((List.range 65).map fun i => (s!"f{i}", toJson i)))])) matches .error _)

-- a condition outside the language, or about a message id the protocol does not have, is an error
-- when the text is read (selfhost.session.types types every condition before anything runs)
def refused (text : String) : String := match check (Json.mkObj [("lean", Json.str text)]) with
  | .error e => e | .ok _ => ""
#guard (refused "structure X where n : Nat\nprotocol P (A, B) { x: X from A to B where x.n = zz.m; }").contains "zz is not a message id"
#guard (refused "structure X where n : Nat\nprotocol P (A, B) { x: X from A to B where List.length x.items > 2; }").contains "where List.length x.items > 2"

-- generated code logs exactly the fields conditions read: amount and price, nothing else of a body
def code (lang : String) : String :=
  (((skeleton (Json.mkObj [("lean", Json.str order), ("language", Json.str lang)])).toOption.getD Json.null).getObjValD "code").getStr?.toOption.getD ""
#guard ((code "python").splitOn "READS = {\"p\": [\"amount\"], \"q\": [\"price\"]}").length > 1
#guard ((code "typescript").splitOn "const READS: Record<string, string[]> = {\"p\": [\"amount\"], \"q\": [\"price\"]};").length > 1
#guard ((code "python").splitOn "logged[\"fields\"] = _project(").length > 1

-- the diagram draws a branch's condition as its alt operand's guard, before the branch, once
def tierSvg : String := (((diagram (Json.mkObj [("lean", Json.str tiers)])).toOption.getD Json.null).getObjValD "svg").getStr?.toOption.getD ""
def after (s a b : String) : Bool := match s.splitOn a with | _ :: rest :: _ => (rest.splitOn b).length > 1 | _ => false
#guard after tierSvg "[o.total &gt;= 100]" ">Gold<" && after tierSvg "[o.total &lt; 100]" ">Plain<"
#guard (tierSvg.splitOn "[o.total &gt;= 100]").length == 2

end LeanFM.Session.WhereTests
