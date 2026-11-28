import LeanFM.Reduce

/-! Tests for selfhost.mcp.logic.reduce (decision logic-reduce) and the reduce.* hazards of
LeanFM/LLMGenerated/Hazards.lean: exact answers over a run, charts with their data, and every bound
named when it is hit. -/
namespace LeanFM.ReduceTests
open Lean LeanFM.Reduce

def ev (id label : String) (t : Nat) (body : List (String × Json)) (cause : Option String := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("label", Json.str label), ("t", toJson t), ("body", Json.mkObj body)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [])

/-- A shop's run: three orders, two paid, one refunded. -/
def shop : Json := Json.arr #[
  ev "o1" "Order" 0 [("item", "tea")], ev "p1" "Pay" 1 [("amount", (10 : Nat))] (some "o1"),
  ev "r1" "Receipt" 2 [("amount", (10 : Nat))] (some "p1"),
  ev "o2" "Order" 3 [("item", "cake")], ev "p2" "Pay" 4 [("amount", (25 : Nat))] (some "o2"),
  ev "r2" "Receipt" 5 [("amount", (25 : Nat))] (some "p2"), ev "f2" "Refund" 6 [("amount", (25 : Nat))] (some "p2"),
  ev "o3" "Order" 7 [("item", "tea")]]

def ask (program : String) (extra : List (String × Json) := []) : Except String Json :=
  check (Json.mkObj ([("program", Json.str program), ("events", shop)] ++ extra))

def outputs (program : String) : List Json :=
  match ask program with
  | .ok j => ((j.getObjValD "outputs").getArr?).toOption.getD #[] |>.toList.map (·.getObjValD "value")
  | .error _ => []

def exact (j : Json) : String := (j.getObjValAs? String "exact").toOption.getD "?"
def refused (program : String) (part : String) (extra : List (String × Json) := []) : Bool :=
  match ask program extra with
  | .error e => (e.splitOn part).length > 1
  | .ok _ => false

-- defines name values and functions; reducers give exact rationals
def money := "(define (amount e) (field e \"amount\"))\n(define revenue (sum (map amount (events \"Pay\"))))\n(define refunds (sum (map amount (events \"Refund\"))))\nrevenue\n(- revenue refunds)\n(/ (count (events \"Refund\")) (count (events \"Order\")))"
#guard (outputs money).map exact == ["35", "10", "1/3"]
-- the book's example, as printed (book/examples/shop.reduce)
def bookExample := include_str "../book/examples/shop.reduce"
#guard ((outputs bookExample).take 2).map exact == ["10", "1/3"]
#guard match (outputs bookExample).drop 2 with
  | [c] => c.getObjValD "kind" == "pie" && ((c.getObjValD "data").getArr?.toOption.map (·.size)) == some 2 | _ => false
-- fold, filter, countBy, sumBy
#guard (outputs "(fold (lambda (acc e) (+ acc 1)) 0 (filter (lambda (e) (= (label e) \"Order\")) (events)))").map exact == ["3"]
#guard (outputs "(countBy (lambda (e) (field e \"item\")) (events \"Order\"))").map (·.compress) ==
  ["[[\"tea\",{\"exact\":\"2\",\"value\":2}],[\"cake\",{\"exact\":\"1\",\"value\":1}]]"]
#guard (outputs "(sumBy label (lambda (e) (field e \"amount\")) (filter (lambda (e) (has? e \"amount\")) (events)))").map (·.compress) ==
  ["[[\"Pay\",{\"exact\":\"35\",\"value\":35}],[\"Receipt\",{\"exact\":\"35\",\"value\":35}],[\"Refund\",{\"exact\":\"25\",\"value\":25}]]"]
-- an event's time, label and the event it answers: every receipt equals its payment
#guard outputs "(map (lambda (r) (= (field r \"amount\") (field (cause r) \"amount\"))) (events \"Receipt\"))" ==
  [Json.arr #[Json.bool true, Json.bool true]]
#guard (outputs "(map time (events \"Pay\"))").map (·.compress) == ["[{\"exact\":\"1\",\"value\":1},{\"exact\":\"4\",\"value\":4}]"]
#guard (outputs "(+ 0.25 1/20)").map exact == ["3/10"]
-- charts carry their data, and draw with escaped titles
#guard match ask "(pie \"<outcomes>\" \"events\" (countBy label (events)))" [("theme", "dark")] with
  | .ok j => let o := ((j.getObjValD "outputs").getArr?.toOption.getD #[])[0]!
    let svg := (o.getObjValAs? String "svg").toOption.getD ""
    (o.getObjValD "value").getObjValD "kind" == "pie" && (svg.splitOn "&lt;outcomes&gt;").length > 1 && (svg.splitOn "<outcomes>").length == 1 &&
      (((o.getObjValD "value").getObjValD "data").getArr?.toOption.getD #[]).size == 4
  | .error _ => false
#guard match ask "(xy \"revenue\" \"s\" \"$\" (map (lambda (e) (list (time e) (field e \"amount\"))) (events \"Pay\")))" [("theme", "light")] with
  | .ok j => let o := ((j.getObjValD "outputs").getArr?.toOption.getD #[])[0]!
    ((o.getObjValAs? String "svg").toOption.getD "").startsWith "<svg" && (((o.getObjValD "value").getObjValD "data").getArr?.toOption.getD #[]).size == 2
  | .error _ => false
#guard match outputs "(histogram \"amounts\" \"$\" 10 (map (lambda (e) (field e \"amount\")) (events \"Pay\")))" with
  | [c] => ((c.getObjValD "data").getArr?.toOption.getD #[]).size == 2 | _ => false
-- division by zero is refused; zero? finds an exact zero
#guard refused "(/ 1 0)" "divides by zero"
#guard outputs "(zero? (- 1/3 1/3))" == [Json.bool true]
-- names outside the list are refused before anything runs
#guard refused "(readFile \"/etc/passwd\")" "readFile is not a primitive"
#guard refused "(eval \"(+ 1 2)\")" "eval is not a primitive"
#guard refused "(define (sum xs) 0)\n1" "is a primitive and cannot be redefined"
-- the bounds, each named
-- a loop that stays shallow but never ends runs into the tick budget; a deep one into the depth bound
#guard refused "(define (twice n) (if (zero? n) 0 (+ (twice (- n 1)) (twice (- n 1)))))\n(twice 40)" "tick budget"
#guard refused "(define (loop n) (loop n))\n(loop 1)" "more than 10000 deep"
#guard refused "(define (deep n) (if (zero? n) 0 (+ 1 (deep (- n 1)))))\n(deep 20000)" "more than 10000 deep"
#guard (outputs "(define (deep n) (if (zero? n) 0 (+ 1 (deep (- n 1)))))\n(deep 1000)").map exact == ["1000"]
#guard refused "(define (sq x n) (if (zero? n) x (sq (* x x) (- n 1))))\n(sq 2 13)" "over 4096 bits"
#guard refused "1" "over reduceEvents 3" [("limits", Json.mkObj [("reduceEvents", (3 : Nat))])]
#guard match check (Json.mkObj [("program", "(xy \"n\" \"i\" \"i\" (map (lambda (i) (list i i)) (rng 3000)))\n(define (rng n) (if (zero? n) (list) (cons n (rng (- n 1)))))"), ("events", Json.arr #[])]) with
  | .ok j => let v := ((j.getObjValD "outputs").getArr?.toOption.getD #[])[0]!.getObjValD "value"
    (v.getObjValD "data").getArr?.toOption.map (·.size) == some 2000 && v.getObjValD "cut" == toJson (1000 : Nat)
  | .error _ => false
-- the operator's budget applies; the answer reports ticks
#guard match check (Json.mkObj [("program", "(+ 1 2)"), ("events", shop)]) 4 with
  | .ok j => j.getObjValD "ticks" == toJson (4 : Nat) | .error _ => false
#guard (check (Json.mkObj [("program", "(+ 1 (+ 2 3))"), ("events", shop)]) 3).toOption.isNone
#guard [fmt 28.571428, fmt 50, fmt 0.5, fmt 1240] == ["28.57", "50", "0.5", "1240"]
#guard parseTicks (some "abc") |>.toOption |>.isNone
#guard match parseTicks none with | .ok n => n == defaultTicks | .error _ => false
#guard match parseTicks (some "5000") with | .ok n => n == 5000 | .error _ => false

end LeanFM.ReduceTests
