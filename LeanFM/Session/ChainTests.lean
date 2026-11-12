import LeanFM.Session.DecisionTests

/-! Requirement selfhost.session.mdp.loops: expected visits, traversals and amounts of a session with
loops, solved exactly; the tree view agrees on loop-free sessions; fail-closed on everything else. -/
namespace LeanFM.Session.ChainTests
open Lean LeanFM.Session LeanFM.SessionTools GenerativeTests DecisionTests

def field (r : Except String Json) (k : String) : Json := (r.toOption.getD Json.null).getObjValD k
def visitsOf (r : Except String Json) (detail : String) : Json :=
  ((field r "states").getArr?.toOption.getD #[]).toList.find? (fun s => s.getObjValD "detail" == Json.str detail)
    |>.map (·.getObjValD "expectedVisits") |>.getD Json.null
def traversalsOf (r : Except String Json) (label : String) : Json :=
  ((field r "edges").getArr?.toOption.getD #[]).toList.find? (fun e => e.getObjValD "label" == Json.str label)
    |>.map (·.getObjValD "expectedTraversals") |>.getD Json.null

-- the limit-order example: each attempt fills 1/4, else is rejected and retried 2/3 of the time
def limitText := include_str "../../examples/sessions/LimitOrder.leanfm"
def limit := mdp (args limitText)
#guard ok limit "drawn"
#guard field limit "view" == Json.str "chain"
-- an attempt repeats with probability 3/4 · 2/3 = 1/2, so 2 expected attempts and P(fill) = 1/2
#guard visitsOf limit "next: Order" == Json.str "2"
#guard traversalsOf limit "Order: Trader -> Exchange" == Json.str "2"
#guard traversalsOf limit "Rejected: Exchange -> Trader" == Json.str "3/2"
#guard traversalsOf limit "Payment: Trader -> Exchange" == Json.str "1/2"
-- fees 2 × 2 USD and half a 1000 USD payment; half of 10 shares; every unit conserved
#guard field limit "expectedBalances" == toJson [
  Json.mkObj [("role", "Trader"), ("unit", "USD"), ("expected", "-504")], Json.mkObj [("role", "Exchange"), ("unit", "USD"), ("expected", "504")],
  Json.mkObj [("role", "Trader"), ("unit", "SHARE"), ("expected", "5")], Json.mkObj [("role", "Exchange"), ("unit", "SHARE"), ("expected", "-5")]]
#guard field limit "expectedMessages" == Json.str "13/2"
#guard ((field limit "report").getStr?.toOption.getD "").contains "Trader: -504 USD"
-- the loop's way back is drawn as a dashed back edge, and the end is visited exactly once
#guard ((field limit "svg").getStr?.toOption.getD "").contains "<path class=\"back\""
-- the session ends one of two ways; the outcomes' probabilities sum to 1
#guard field limit "terminalProbability" == Json.str "1"

-- a geometric loop that exits with probability 1/4 runs its body 4 times on average
def geometric := "protocol G (A,B) { rec L { R from A to B amount sample { 1 USD : 1/2; 3 USD : 1/2; }; choice at A using declared(\"stop\") { probability 1/4: Done from A to B; } or { probability 3/4: Again from A to B; continue L; } } }"
#guard traversalsOf (mdp (args geometric)) "R: A -> B" == Json.str "4"
-- an amount sample enters by its mean: 4 traversals × 2 USD
#guard field (mdp (args geometric)) "expectedBalances" == toJson [
  Json.mkObj [("role", "A"), ("unit", "USD"), ("expected", "-8")], Json.mkObj [("role", "B"), ("unit", "USD"), ("expected", "8")]]

-- on a loop-free session without obligations the chain agrees with the tree
def noObligation := (pricedText.splitOn "  obligation Act.Section2").headD "" ++ "  choice at Landlord" ++
  ((pricedText.splitOn "  choice at Landlord").getD 1 "")
#guard ok (mdp (args noObligation)) "drawn"
#guard field (mdp ((args noObligation).setObjVal! "view" "chain")) "expectedBalances" ==
  field (mdp (args noObligation)) "expectedBalances"
#guard field (mdp (args noObligation)) "expectedBalances" == toJson [
  Json.mkObj [("role", "Tenant"), ("unit", "USD"), ("expected", "1775/2")], Json.mkObj [("role", "Landlord"), ("unit", "USD"), ("expected", "-1775/2")]]
-- the chain says it does not use message times
#guard ((field (mdp ((args noObligation).setObjVal! "view" "chain")) "notes").compress).contains "not used"

-- the tree draws amounts on edges and expected visits on states
#guard ((priced.getObjValAs? String "svg").toOption.getD "").contains "p = 9/10 - Landlord -&gt; Tenant 1000 USD"
#guard ((priced.getObjValAs? String "svg").toOption.getD "").contains "expected visits 3/4"

-- negative: refuse rather than report finite numbers for a session that can never end
#guard errorHas (mdp (args "protocol F (A,B) { rec L { R from A to B; continue L; } }")) "loop forever"
def neverFills := ((limitText.replace "probability 2/3:" "probability 1:").replace "probability 1/3:" "probability 0:").replace "probability 1/4:" "probability 0:" |>.replace "probability 3/4:" "probability 1:"
#guard errorHas (mdp (args neverFills)) "loop forever"
-- obligations depend on history: refused in the chain, with a pointer to the tree
#guard errorHas (mdp ((args pricedText).setObjVal! "view" "chain")) "tree view"
#guard errorHas (mdp (args "protocol P (A,B) { rec L { choice { R from A to B; continue L; } or { S from A to B; } } }")) "needs probabilities"
#guard errorHas (mdp (args "protocol P (A,B,C) { rec L { par { R from A to B; } and { S from A to C; } choice at A using declared(\"x\") { probability 1/2: T from A to B; continue L; } or { probability 1/2: U from A to B; } } }")) "par"
#guard errorHas (mdp ((args limitText).setObjVal! "view" "sideways")) "view must be"
def tooMany := "protocol P (A,B) { rec L { " ++ String.join (List.replicate 100 "R from A to B; ") ++
  "choice at A using declared(\"x\") { probability 1/2: S from A to B; continue L; } or { probability 1/2: T from A to B; } } }"
#guard errorHas (mdp (args tooMany)) "96 states"
-- protocol text is escaped in the drawing
def hostile := "protocol P (A,B) { rec L { «<b>x</b>» from A to B; choice at A using declared(\"x\") { probability 1/2: S from A to B; continue L; } or { probability 1/2: T from A to B; } } }"
#guard ((field (mdp (args hostile)) "svg").getStr?.toOption.getD "").contains "&lt;b&gt;"
#guard !((field (mdp (args hostile)) "svg").getStr?.toOption.getD "").contains "<b>"

/-! Requirement selfhost.session.mdp.rewards: time, accruals, trade vectors and outcomes. -/
def outcomesOf (r : Except String Json) : List Json := ((field r "outcomes").getArr?.toOption.getD #[]).toList
def balanceOf (o : Json) (role unit : String) : Json :=
  ((o.getObjValD "expectedBalances").getArr?.toOption.getD #[]).toList.find?
    (fun b => b.getObjValD "role" == Json.str role && b.getObjValD "unit" == Json.str unit)
    |>.map (·.getObjValD "expected") |>.getD Json.null
-- the limit order ends Filled or GaveUp, half each: 1004 USD paid given a fill, 4 given a give-up
#guard (outcomesOf limit).map (·.getObjValD "label") == [Json.str "End after Shares", Json.str "End after GiveUp"]
#guard (outcomesOf limit).map (·.getObjValD "probability") == [Json.str "1/2", Json.str "1/2"]
#guard (outcomesOf limit).map (balanceOf · "Trader" "USD") == [Json.str "-1004", Json.str "-4"]
#guard (outcomesOf limit).map (balanceOf · "Trader" "SHARE") == [Json.str "10", Json.str "0"]
-- the outcomes average back to the overall expectation: 1/2·(-1004) + 1/2·(-4) = -504

-- the loan: grace at 0 USD per week for two weeks, then 10 USD per week until repaid
def loanText := include_str "../../examples/sessions/Loan.leanfm"
def loan := mdp (args loanText)
#guard ok loan "drawn"
#guard field loan "view" == Json.str "chain"
-- half repay at week 2; the rest stay a geometric 4 weeks at 10 USD: 1/2 · 40 = 20 USD, 1/2·2 + 1/2·6 = 4 weeks
#guard field loan "expectedBalances" == toJson [
  Json.mkObj [("role", "Borrower"), ("unit", "USD"), ("expected", "-20")], Json.mkObj [("role", "Lender"), ("unit", "USD"), ("expected", "20")]]
#guard field loan "expectedDurationMs" == Json.str (toString (28 * 86400000))
#guard (outcomesOf loan).map (·.getObjValD "probability") == [Json.str "1"]
#guard ((field loan "report").getStr?.toOption.getD "").contains "Expected duration: 28 days"
-- each state carries the rates in force there; the grace state has none
#guard ((field loan "states").getArr?.toOption.getD #[]).toList.any fun st =>
  st.getObjValD "detail" == Json.str "next: Missed" && (st.getObjValD "ratesInForce").compress.contains "\"quantity\":10"
#guard ((field loan "states").getArr?.toOption.getD #[]).toList.any fun st =>
  st.getObjValD "detail" == Json.str "next: Extend" && st.getObjValD "ratesInForce" == toJson ([] : List Json)
-- a rate of 0 is the same as no rate: removing the grace line changes nothing
#guard field (mdp (args (loanText.replace "  accrue 0 USD per week from Borrower to Lender;\n" ""))) "expectedBalances" == field loan "expectedBalances"

-- a trade is a vector whose two sides cancel unit by unit, in the tree and in the chain
def swap2 := "protocol Swap (A, B) { Swap from A to B amount { 5 apple; 4 orange; -3 USD; }; }"
#guard ok (mdp (args swap2)) "drawn"
def swapExpected := toJson [
  Json.mkObj [("role", "A"), ("unit", "apple"), ("expected", "-5")], Json.mkObj [("role", "B"), ("unit", "apple"), ("expected", "5")],
  Json.mkObj [("role", "A"), ("unit", "orange"), ("expected", "-4")], Json.mkObj [("role", "B"), ("unit", "orange"), ("expected", "4")],
  Json.mkObj [("role", "A"), ("unit", "USD"), ("expected", "3")], Json.mkObj [("role", "B"), ("unit", "USD"), ("expected", "-3")]]
#guard field (mdp (args swap2)) "expectedBalances" == swapExpected
#guard field (mdp ((args swap2).setObjVal! "view" "chain")) "expectedBalances" == swapExpected
#guard errorHas (mdp (args "protocol S (A, B) { Swap from A to B amount { 5 apple; -3 apple; }; }")) "appears twice"

-- delays after the previous step drive the tree's clock too
def delayed := (mdp (args "protocol P (A,B) { r: R from A to B; S from A to B cause r after 2 days; }")).toOption.get!
#guard ((delayed.getObjValD "terminals").getArr?.toOption.get!.toList.map (·.getObjValD "timeMs")) == [toJson (172800000 : Nat)]
-- and they write back as they read
#guard (Text.write [{ name := "P", roles := ["A", "B"], body := (Text.parse "protocol P (A,B) { R from A to B after 2 days; }").toOption.get!.body }]).contains "after sample { 172800000 ms : 1; }"

-- negative: refuse rather than guess
#guard errorHas (mdp (args "protocol P (A,B) { choice at A using declared(\"x\") { probability 1/2: accrue 5 USD per day from A to B; R from A to B after 1 days; } or { probability 1/2: S from A to B after 1 days; } T from A to B after 1 days; }")) "differs between paths"
#guard errorHas (mdp (args "protocol P (A,B) { accrue 1 USD per day from A to B; r: R from A to B; S from A to B at time(r) + 1 days; }")) "absolute times"
#guard errorHas (mdp ((args loanText).setObjVal! "view" "tree")) "chain view"
#guard errorHas (mdp (args "protocol P (A,B) { accrue 5 USD per 0 days from A to B; R from A to B after 1 days; }")) "longer than zero"
#guard errorHas (mdp (args "protocol P (A,B) { accrue 5 USD per day from A to A; R from A to B after 1 days; }")) "not to its payer"
#guard errorHas (mdp (args "protocol P (A,B) { accrue -5 USD per day from A to B; R from A to B; }")) "accrue"
-- an outcome that never happens has no conditional expectation
def neverFill := ((limitText.replace "probability 1/4:" "probability 0:").replace "probability 3/4:" "probability 1:")
#guard (outcomesOf (mdp (args neverFill))).map (·.getObjValD "expectedBalances") |>.contains Json.null

-- a rental is a continuous trade: two rates in force together, cancelling unit by unit at every moment
def rentalText := include_str "../../examples/sessions/Rental.leanfm"
#guard field (mdp (args rentalText)) "expectedBalances" == toJson [
  Json.mkObj [("role", "Tenant"), ("unit", "USD"), ("expected", "-7000")], Json.mkObj [("role", "Landlord"), ("unit", "USD"), ("expected", "7000")],
  Json.mkObj [("role", "Tenant"), ("unit", "roomweek"), ("expected", "7")], Json.mkObj [("role", "Landlord"), ("unit", "roomweek"), ("expected", "-7")]]

/-! Requirement selfhost.session.mdp.walk: realized rewards of walks from an event stream. -/
def ev (session label src dst : String) (t : Nat) : Json :=
  Json.mkObj [("session", session), ("label", label), ("from", src), ("to", dst), ("timeMs", t)]
def hour := 3600000
def stream : Json := toJson [
  ev "1" "Order" "Trader" "Exchange" 0, ev "2" "Order" "Trader" "Exchange" 0,
  ev "1" "Rejected" "Exchange" "Trader" hour, ev "2" "Rejected" "Exchange" "Trader" hour,
  ev "1" "Retry" "Trader" "Exchange" hour, ev "2" "GiveUp" "Trader" "Exchange" (2 * hour),
  ev "1" "Order" "Trader" "Exchange" (2 * hour), ev "1" "Filled" "Exchange" "Trader" (3 * hour),
  ev "1" "Payment" "Trader" "Exchange" (3 * hour), ev "1" "Shares" "Exchange" "Trader" (3 * hour)]
def walked := mdp ((args limitText).setObjVal! "events" stream)
def walksOf (r : Except String Json) : List Json := ((field r "walks").getArr?.toOption.getD #[]).toList
#guard ok walked "walked"
-- session 1: rejected once, retried, filled; P = 3/4 · 2/3 · 1/4 = 1/8; two fees and the fill
#guard (walksOf walked).map (·.getObjValD "probability") == [Json.str "1/8", Json.str "1/4"]
#guard (walksOf walked).map (·.getObjValD "ended") == [Json.bool true, Json.bool true]
#guard ((walksOf walked).headD Json.null).getObjValD "balances" ==
  Json.mkObj [("Trader", Json.mkObj [("USD", "-1004"), ("SHARE", "10")]), ("Exchange", Json.mkObj [("USD", "1004"), ("SHARE", "-10")])]
-- the times are the stream's: session 2 lasted two hours
#guard ((walksOf walked).getD 1 Json.null).getObjValD "durationMs" == Json.str (toString (2 * hour))
-- totals sum the sessions
#guard (field walked "total").getObjValD "balances" ==
  Json.mkObj [("Trader", Json.mkObj [("USD", "-1006"), ("SHARE", "10")]), ("Exchange", Json.mkObj [("USD", "1006"), ("SHARE", "-10")])]
-- a loan stream pays interest for exactly the weeks it spent after grace: 3 weeks at 10 USD
def day := 86400000
def loanStream : Json := toJson [Json.mkObj [("label", "Advance"), ("timeMs", 0)], Json.mkObj [("label", "Extend"), ("timeMs", toJson (14 * day))],
  Json.mkObj [("label", "Missed"), ("timeMs", toJson (21 * day))], Json.mkObj [("label", "Missed"), ("timeMs", toJson (28 * day))],
  Json.mkObj [("label", "Repay"), ("timeMs", toJson (35 * day))]]
def loanWalk := mdp ((args loanText).setObjVal! "events" loanStream)
#guard ((walksOf loanWalk).headD Json.null).getObjValD "balances" ==
  Json.mkObj [("Borrower", Json.mkObj [("USD", "-30")]), ("Lender", Json.mkObj [("USD", "30")])]
#guard ((walksOf loanWalk).headD Json.null).getObjValD "probability" == Json.str "9/128"
-- a hand-written walk without times takes each edge's mean delay
#guard ((walksOf (mdp ((args loanText).setObjVal! "walk" (toJson [Json.mkObj [("label", "Advance")], Json.mkObj [("label", "Repay")]])))).headD Json.null).getObjValD "durationMs"
  == Json.str (toString (14 * day))
-- negative: a step that does not fit, a time that goes backwards, mixed timing, too many events
#guard errorHas (mdp ((args limitText).setObjVal! "walk" (toJson [Json.mkObj [("label", "Filled")]]))) "what could come next: Order"
#guard errorHas (mdp ((args limitText).setObjVal! "events" (toJson [ev "1" "Order" "Trader" "Exchange" 10, ev "1" "Rejected" "Exchange" "Trader" 5]))) "backwards"
#guard errorHas (mdp ((args limitText).setObjVal! "events" (toJson [ev "1" "Order" "Trader" "Exchange" 10, Json.mkObj [("session", "1"), ("label", "Rejected")]]))) "every event needs timeMs"
#guard errorHas (mdp ((args limitText).setObjVal! "walk" (toJson (List.replicate 513 (Json.mkObj [("label", "Order")]))))) "at most 512"
-- a stream too large for one call is refused at the argument limit
#guard errorHas (mdp ((args limitText).setObjVal! "events" (toJson (List.replicate 5001 (ev "1" "Order" "Trader" "Exchange" 0))))) "exceed"

/-! Requirement selfhost.session.mdp.horizon: whole periods behind a periodic gate. -/
def weeklyText := include_str "../../examples/sessions/WeeklyRent.leanfm"
def weekly := mdp ((args weeklyText).setObjVal! "horizon" "52 weeks")
#guard ok weekly "drawn"
#guard field weekly "view" == Json.str "horizon"
#guard field weekly "periods" == toJson (52 : Nat)
#guard field weekly "gatePassages" == Json.str "52"
-- exactly 52 rents and 52 roomweeks, and the 52 periods fill exactly 52 weeks
#guard field weekly "expectedByRole" == Json.mkObj [
  ("Tenant", Json.mkObj [("roomweek", "52"), ("USD", "-52000")]), ("Landlord", Json.mkObj [("roomweek", "-52"), ("USD", "52000")])]
#guard field weekly "expectedDurationMs" == Json.str (toString (52 * 604800000))
-- the graph does not depend on the horizon: a year of 365 days is 52 whole weeks and one uncounted day
def year := mdp ((args weeklyText).setObjVal! "horizon" "365 days")
#guard field year "gatePassages" == Json.str "52"
#guard field year "uncountedMs" == toJson (86400000 : Nat)
#guard field (mdp ((args weeklyText).setObjVal! "horizon" "4 weeks")) "gatePassages" == Json.str "4"
-- with a 1/4 chance of notice after each rent, 4 weeks give 1 + 3/4 + 9/16 + 27/64 = 175/64 rents
def noticeText := weeklyText.replace "    continue Week;\n" "    choice at Tenant using declared(\"stay\") {\n      probability 3/4: Stay from Tenant to Landlord; continue Week;\n    } or {\n      probability 1/4: Notice from Tenant to Landlord;\n    }\n"
def notice := mdp ((args noticeText).setObjVal! "horizon" "4 weeks")
#guard ok notice "drawn"
#guard field notice "gatePassages" == Json.str "175/64"
#guard field notice "stillRunning" == Json.str "27/64"
#guard ((field notice "expectedByRole").getObjValD "Landlord").getObjValD "USD" == Json.str "21875/8"
-- the tree times a gated step at the period boundary
#guard ((((mdp ((args "protocol P (A,B) { R from A to B after 1 hour; S from A to B at next 1 week; }").setObjVal! "view" "tree")).toOption.get!.getObjValD "terminals").getArr?.toOption.get!.toList.map (·.getObjValD "timeMs"))) == [toJson (604800000 : Nat)]
-- negative: refuse rather than guess
#guard errorHas (mdp (args weeklyText)) "needs a horizon"
#guard errorHas (mdp ((args loanText).setObjVal! "horizon" "52 weeks")) "exactly one periodic gate"
#guard errorHas (mdp ((args (weeklyText.replace "after 1 hour" "after 8 days")).setObjVal! "horizon" "52 weeks")) "longer than the period"
#guard errorHas (mdp ((args weeklyText).setObjVal! "horizon" "3 days")) "shorter than one period"
#guard errorHas (mdp ((args (weeklyText.replace "Check from Landlord to Tenant after 1 hour;" "Check from Landlord to Tenant after 1 hour at next 1 week;")).setObjVal! "horizon" "52 weeks")) "';'"
def innerLoop := "protocol P (A,B) { rec Week { rec Poll { choice at A using declared(\"p\") { probability 1/2: Again from A to B after 1 hour; continue Poll; } or { probability 1/2: Ready from A to B after 1 hour; } } Pay from A to B at next 1 week; continue Week; } }"
#guard errorHas (mdp ((args innerLoop).setObjVal! "horizon" "52 weeks")) "does not pass the gate"
def twoGates := "protocol P (A,B) { rec W { X from A to B at next 1 week; Y from A to B at next 1 week; continue W; } }"
#guard errorHas (mdp ((args twoGates).setObjVal! "horizon" "52 weeks")) "several"
#guard errorHas (mdp ((args weeklyText).setObjVal! "horizon" "200000 weeks")) "at most 10000"

-- a nested choice behind the gate, checked against a hand calculation: each week continues with
-- q = 3/4 + 1/4 · 2/3 = 11/12; over 4 weeks the gate passes 1 + q + q² + q³ = 6095/1728 times and the
-- cycle runs 1 + q + q² = 397/144 times; Repair happens 1/6 of cycles, Terminate 1/12
def repairsText := include_str "../../examples/sessions/RentWithRepairs.leanfm"
def repairs := mdp ((args repairsText).setObjVal! "horizon" "4 weeks")
#guard field repairs "gatePassages" == Json.str "6095/1728"
#guard field repairs "stillRunning" == Json.str "1331/1728"
#guard traversalsOf repairs "Repair: Landlord -> Tenant" == Json.str "397/864"
#guard traversalsOf repairs "Terminate: Landlord -> Tenant" == Json.str "397/1728"
-- rent minus repair credits: -1000 · 6095/1728 + 200 · 397/864 = -742025/216 USD
#guard ((field repairs "expectedByRole").getObjValD "Tenant").getObjValD "USD" == Json.str "-742025/216"
-- every passage fills a week; a terminated cycle adds its hour and day: 7 · 6095/1728 + 397/1728 · 25/24 days
#guard field repairs "expectedDurationMs" == Json.str "6461781250/3"
-- the legend says where each role's balance came from, and the effective price
#guard ((field repairs "svg").getStr?.toOption.getD "").contains "Landlord: -3.56 roomweek (accrue 1 roomweek/week -3.56) - +3435.30 USD (Rent +3527.20, Repair -91.90) - 964.60 USD per roomweek"
#guard (((field repairs "breakdown").getObjValD "Landlord").getObjValD "USD") == Json.mkObj [("Rent", "761875/216"), ("Repair", "-9925/108")]

/-! Requirement selfhost.session.generate.chain: generating walks of a session with loops. -/
deriving instance Inhabited for LeanFM.SessionTools.Protocol
def rideText := include_str "../../examples/sessions/Ride.leanfm"
def rideChain : Chain.Chain :=
  let p := (parseProtocol (args rideText)).toOption.get!
  (Chain.analyse p.generative.get! (solveAll := false)).toOption.get!
def rideGen := (Chain.generate rideChain 1 200).toOption.get!
-- a compact stream of the first 30 sessions goes through the tool and walks back
def compact (e : Event String) (ms : List Chain.Move) : Json :=
  Json.mkObj [("session", e.session), ("label", e.label), ("from", e.src), ("to", e.dst), ("timeMs", e.time),
    ("amounts", toJson (ms.map fun ((f, t, u, q) : Chain.Move) =>
      Json.mkObj [("from", f), ("to", t), ("unit", u), ("quantity", toJson q.num.toNat)]))]
def pairs := (rideGen.events.zip rideGen.amounts).toList
def first30 := pairs.filter (·.1.session ≤ 30)
def rideWalked := mdp ((args rideText).setObjVal! "events" (toJson (first30.map fun (e, ms) => compact e ms)))
#guard ok rideWalked "walked"
def drawn (ps : List (Event String × List Chain.Move)) (role : String) : Int :=
  ps.foldl (fun acc (_, ms) => ms.foldl (fun acc ((f, t, _, q) : Chain.Move) =>
    acc + (if t == role then q.num else 0) - (if f == role then q.num else 0)) acc) 0
-- realized rewards are exactly the amounts drawn
#guard (((field rideWalked "total").getObjValD "balances").getObjValD "Rider").getObjValD "USD" == Json.str (toString (drawn first30 "Rider"))
-- every one of the 200 sessions walks back, and the realized total is close to 200 · (-37/2): within 10 percent
def steps (sid : Nat) : List Chain.Step := Id.run do
  let mut prev := 0
  let mut out := []
  for (e, ms) in pairs.filter (·.1.session == sid) do
    out := out ++ [{ label := e.label, sender := some e.src, receiver := some e.dst,
                     afterMs := some ((e.time - prev : Nat) : Rat), amounts := some ms }]
    prev := e.time
  return out
def walkedAll : List Chain.Walked := (List.range 200).filterMap fun i => (Chain.walk rideChain (steps (i + 1))).toOption
#guard walkedAll.length == 200 && walkedAll.all (·.ended)
def realizedRider : Rat := walkedAll.foldl (fun acc w =>
  acc + ((w.balances.find? fun (r, u, _) => r == "Rider" && u == "USD").map (·.2.2)).getD 0) 0
#guard realizedRider == (drawn pairs "Rider" : Rat)
#guard realizedRider ≤ -3330 && realizedRider ≥ -4070
-- the expected Ride balances, checked by hand: Rider pays 9/10 · 20 + 1/10 · 5
#guard field (mdp (args rideText)) "expectedByRole" == Json.mkObj [
  ("Rider", Json.mkObj [("USD", "-37/2")]), ("Platform", Json.mkObj [("USD", "37/10")]), ("Driver", Json.mkObj [("USD", "74/5")])]
-- an amount that the protocol's step cannot move is refused
#guard errorHas (mdp ((args rideText).setObjVal! "walk" (toJson [Json.mkObj [("label", "Request"),
  ("amounts", toJson [Json.mkObj [("from", "Rider"), ("to", "Platform"), ("unit", "USD"), ("quantity", toJson (5 : Nat))]])]]))) "does not"
-- a session that never ends is cut at 512 events and marked not ended
def spin := (parseProtocol (args "protocol P (A,B) { rec L { choice at A using declared(\"x\") { probability 1/2: R from A to B; continue L; } or { probability 1/2: S from A to B; continue L; } } }")).toOption.get!
#guard ((Chain.generate (Chain.analyse spin.generative.get! (solveAll := false)).toOption.get! 1 1).toOption.get!).ended == [(1, false)]

/-! Requirement selfhost.session.diagram.annotations: probabilities and rewards on the sequence diagram. -/
def rideSvg := ((diagram (args rideText)).toOption.get!.getObjValAs? String "svg").toOption.getD ""
#guard rideSvg.contains "p 4/5 - after 10 seconds - x1"
#guard rideSvg.contains "after 30 seconds - x5/4"
-- each Fare keeps its own amount though both are Rider → Platform Fare
#guard rideSvg.contains "15 USD - x9/20" && rideSvg.contains "25 USD - x9/20"
#guard rideSvg.contains "Platform: +3.70 USD (Cancel +0.50, CancelFee -0.40, Fare +18.00, Payout -14.40)"
-- the matching tag never reaches the reader
#guard !(rideSvg.contains "\u0001") && !((diagram (args rideText)).toOption.get!.compress.contains "\\u0001")
-- a protocol without annotations draws exactly as the plain model
def plainText := "protocol P (A,B) { r: R from A to B; choice { S from B to A cause r; } or { T from B to A cause r; } }"
#guard ((diagram (args plainText)).toOption.get!.getObjValAs? String "svg").toOption ==
  some (((parseProtocol (args plainText)).toOption.get!).global.diagramModel ["A", "B"] "P").svg

/-! Requirement selfhost.session.rec.bounded: a bounded loop is expanded into explicit passes. -/
def boundedText := include_str "../../examples/sessions/BoundedRide.leanfm"
def bounded := mdp (args boundedText)
-- no loop is left, so the tree view (with deadlines and the timed generator) handles it
#guard ok bounded "drawn" && field bounded "view" == Json.null
-- three offers at most: no driver with probability (1/5)³; every balance is the unbounded ride's × 124/125
#guard ((field bounded "report").getStr?.toOption.getD "").contains "- 1/125: End, 120000 ms - no obligations"
#guard field bounded "expectedBalances" == toJson [
  Json.mkObj [("role", "Rider"), ("unit", "USD"), ("expected", "-2294/125")],
  Json.mkObj [("role", "Platform"), ("unit", "USD"), ("expected", "2294/625")],
  Json.mkObj [("role", "Driver"), ("unit", "USD"), ("expected", "9176/625")]]
-- each pass is its own state with its own count: 1, 1/5, 1/25 offers
def boundedChain := mdp ((args boundedText).setObjVal! "view" "chain")
def boundedReport := (field boundedChain "report").getStr?.toOption.getD ""
#guard ["x1", "x1/5", "x1/25"].all fun c => boundedReport.contains s!"- Offer: Platform -> Driver: {c}\n"
-- this answer is large: it says what it left out to fit the response limit
#guard (field boundedChain "omitted") != Json.null && boundedReport.contains "To fit the response limit"
#guard ((field boundedChain "report").getStr?.toOption.getD "").contains "End after NoDriver: probability 1/125"
-- copies rename their ids and named choices, so causes and names stay unambiguous
def unrolled := (Text.parse boundedText).toOption.get!.body
#guard (Text.write [{ name := "B", roles := ["Rider", "Platform", "Driver"], body := unrolled }]).contains "o_2: Offer"
#guard (Text.write [{ name := "B", roles := ["Rider", "Platform", "Driver"], body := unrolled }]).contains "cause o_3"
#guard (Text.write [{ name := "B", roles := ["Rider", "Platform", "Driver"], body := unrolled }]).contains "acceptance_3"
-- bounds are 1..32
#guard errorHas (mdp (args (boundedText.replace "at most 3" "at most 0"))) "between 1 and 32"
#guard errorHas (mdp (args (boundedText.replace "at most 3" "at most 33"))) "between 1 and 32"

/-! Requirement selfhost.session.mdp.distribution: full distributions where they are finite. -/
-- the bounded ride's terminals grouped by balance: by hand, 9/25 + 9/125 + 9/625 = 279/625 for each trip length
#guard ((field bounded "report").getStr?.toOption.getD "").contains "- Rider USD: -25 (279/625), -15 (279/625), -5 (62/625), 0 (1/125); mean -2294/125"
-- rent with repairs over 4 weeks: ten outcomes for the Landlord, summing to 1, with the expected mean
def repairsDist := ((field repairs "distribution").getObjValD "Landlord").getObjValD "USD"
def repairsVals : List (Rat × Rat) := (repairsDist.getArr?.toOption.getD #[]).toList.map fun j =>
  let rd (k : String) : Rat := match ((j.getObjValAs? String k).toOption.getD "0").splitOn "/" with
    | [n] => (n.toInt?.getD 0 : Rat)
    | [n, d] => (n.toInt?.getD 0 : Rat) / (d.toNat?.getD 1 : Rat)
    | _ => 0
  (rd "value", rd "probability")
#guard repairsVals.length == 10
#guard repairsVals.foldl (fun acc (_, p) => acc + p) 0 == 1
#guard repairsVals.foldl (fun acc (x, p) => acc + x * p) 0 == (742025 : Rat) / 216
-- four quiet weeks: (3/4)³ after the first three rents
#guard repairsVals.contains ((4000 : Rat), (27 : Rat) / 64)
-- the passages: q0 q^(k-1)(1 - q), and all four with (11/12)³
#guard field repairs "passagesDistribution" == toJson [
  Json.mkObj [("passages", toJson (0 : Nat)), ("probability", "0")], Json.mkObj [("passages", toJson (1 : Nat)), ("probability", "1/12")],
  Json.mkObj [("passages", toJson (2 : Nat)), ("probability", "11/144")], Json.mkObj [("passages", toJson (3 : Nat)), ("probability", "121/1728")],
  Json.mkObj [("passages", toJson (4 : Nat)), ("probability", "1331/1728")]]
-- a year: P(at least 13 rents) = (11/12)^12, read as a decimal
#guard ((field (mdp ((args repairsText).setObjVal! "horizon" "52 weeks")) "report").getStr?.toOption.getD "").contains "P(at least 13) ~0.3520"
-- loops without a horizon: no distribution, and the tool says why
#guard ((field limit "report").getStr?.toOption.getD "").contains "No distribution: with loops and no horizon its support is infinite"

/-! Requirement selfhost.session.mdp.optimize: the best branch at each open choice, exactly. -/
def dispatchText := include_str "../../examples/sessions/Dispatch.leanfm"
def opt (role unit goal : String) : Except String Json :=
  mdp ((args dispatchText).setObjVal! "optimize" (Json.mkObj [("role", role), ("unit", unit), ("goal", goal)]))
def chosen (r : Except String Json) : String :=
  match field r "policy" with
  | .arr a => ((a[0]!).getObjValAs? String "chosen").toOption.getD ""
  | _ => ""
def branchValue (r : Except String Json) (first : String) : String :=
  match field r "policy" with
  | .arr a => (((a[0]!).getObjValD "branches").getArr?.toOption.getD #[]).toList.findSome? (fun b =>
      if (b.getObjValAs? String "first").toOption == some first then (b.getObjValAs? String "value").toOption else none) |>.getD ""
  | _ => ""
-- by hand: the standard offer earns the Platform 25 - (3/4)·16 - (1/4)·25 = 27/4; the boost only 152/39
#guard chosen (opt "Platform" "USD" "max") == "Offer"
#guard field (opt "Platform" "USD" "max") "optimalValue" == "27/4"
-- the Driver is better off with the boost: 21 · 38/39 = 266/13, against 12
#guard chosen (opt "Driver" "USD" "max") == "Boost"
#guard field (opt "Driver" "USD" "max") "optimalValue" == "266/13"
-- branch values follow the policy afterwards: an offer now, boosts later, gives the Driver 3/5·16 + 1/5·266/13 = 178/13
#guard branchValue (opt "Driver" "USD" "max") "Offer" == "178/13"
-- the chain is solved again under the policy: the Platform's balance under the Driver's choice
#guard ((field (opt "Driver" "USD" "max") "report").getStr?.toOption.getD "").contains "- Platform: 152/39 USD"
-- time: the standard offer ends sooner on average
#guard chosen (opt "Rider" "time" "min") == "Offer"
#guard field (opt "Rider" "time" "min") "optimalValue" == "725000"
-- without optimize, a choice without probabilities is still refused
#guard errorHas (mdp (args dispatchText)) "pass optimize"
-- refusals: the role, the goal, the unit, and a session without open choices
#guard errorHas (opt "Passenger" "USD" "max") "not a role"
#guard errorHas (opt "Platform" "USD" "best") "max or min"
#guard errorHas (opt "Platform" "EUR" "max") "no step or rate gives Platform any EUR"
#guard errorHas (mdp ((args rideText).setObjVal! "optimize" (Json.mkObj [("role", "Rider"), ("unit", "USD"), ("goal", "max")]))) "at least one open choice"
-- a policy that never ends is never chosen, however much it would pay
def forever := "protocol P (A,B) { rec L { choice { More from A to B amount 1 USD; continue L; } or { Stop from A to B; } } }"
def foreverOpt := mdp ((args forever).setObjVal! "optimize" (Json.mkObj [("role", "B"), ("unit", "USD"), ("goal", "max")]))
#guard chosen foreverOpt == "Stop" && field foreverOpt "excludedNonEnding" == toJson true
-- a session where no open choice can end is refused
def trapped := "protocol P (A,B) { Go from A to B; rec L { choice { X from A to B; continue L; } or { Y from A to B; continue L; } } }"
#guard errorHas (mdp ((args trapped).setObjVal! "optimize" (Json.mkObj [("role", "B"), ("unit", "time"), ("goal", "min")]))) "never reach an end"
end LeanFM.Session.ChainTests
