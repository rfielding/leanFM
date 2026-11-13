import LeanFM.Session.GenerativeTests

/-! Requirement selfhost.session.mdp: checked mass, graph identity and fail-closed rendering. -/
namespace LeanFM.Session.DecisionTests
open Lean LeanFM.Session LeanFM.SessionTools LeanFM.Overlay GenerativeTests
set_option maxRecDepth 4096
set_option maxHeartbeats 8000000

def result := (mdp (args sampleText)).toOption.get!
def graph := (Decision.build layer parsed.roles).toOption.get!
#guard ok (mdp (args sampleText)) "drawn"
#guard result.getObjValD "terminalProbability" == Json.str "1"
#guard result.getObjValD "violationProbability" == Json.str "3/40"
#guard ((result.getObjValD "terminals").getArr?).toOption.get!.toList.map
  (fun t => t.getObjValD "probability") == [Json.str "27/40",Json.str "3/40",Json.str "1/4"]
#guard (graph.filter (·.kind == "terminal")).size == 3
#guard (graph.filter (·.kind == "action")).size == 2
#guard (graph.filter (·.kind == "terminal")).foldl (fun q n => Q.add q n.mass) Q.zero == Q.one
#guard ((graph.filter (·.kind == "terminal")).map (·.timeMs)).toList == [604800000,2160000000,518400000]
#guard result.getObjValD "provenance" != Json.null

def external := (mdp (Json.mkObj [("lean",sampleText),("overlay",overlay)])).toOption.get!
#guard external.getObjValD "terminalProbability" == Json.str "1"
#guard external.getObjValD "violationProbability" == Json.str "0"
#guard (external.getObjValD "terminals").getArr?.toOption.get!.size == 3
#guard external.getObjValD "overlay" == overlay
#guard errorHas (mdp (args unknownWeights)) "complete policy"
#guard errorHas (mdp (args concurrent)) "scheduling"
#guard errorHas (mdp (args (sampleText.replace "3/4" "1/4"))) "not 1"
#guard errorHas (mdp (args (sampleText.replace "choice at Landlord" "choice at Tenant"))) "decider"

-- Duplicate visible labels are not sufficient to merge states or terminal histories.
def duplicate := "protocol P (A,B) { choice at A using declared(\"x\") { probability 1/2: R from A to B; } or { probability 1/2: S from A to B; } Done from B to A; }"
def duplicateText := duplicate
#guard ok (mdp (args duplicateText)) "drawn"
#guard ((mdp (args duplicateText)).toOption.get!.getObjValD "terminals").getArr?.toOption.get!.size == 2

-- Any violation is a union, not a sum over obligations.
def twoObligations := sampleText.replace "choice at Landlord"
  "obligation Also on Landlord { trigger settlement; require DepositReturned or DeductionsItemized within 14 days; on breach record AnotherViolation; } choice at Landlord"
#guard (mdp (args twoObligations)).toOption.get!.getObjValD "violationProbability" == Json.str "3/40"

-- An unmet future deadline at the last event is pending, not fulfilled or violated.
def pendingText := "protocol P (A,B) { r: R from A to B; clock c = time(r); obligation O on B { trigger c; require Yes within 1 days; on breach record Bad; } choice at B using declared(\"x\") { probability 1/2: Yes from B to A; } or { probability 1/2: No from B to A; } }"
def pendingResult := (mdp (args pendingText)).toOption.get!
#guard pendingResult.getObjValD "violationProbability" == Json.str "0"
#guard pendingResult.compress.contains "pending"

-- State and string bounds reject complete-looking truncation; text is escaped.
def tooBig := "protocol P (A,B) { " ++ String.join (List.replicate 100 "R from A to B; ") ++ "}"
#guard errorHas (mdp (args tooBig)) "96 nodes"
def malicious := "protocol P (A,B) { «<script>alert(1)</script>» from A to B; }"
def escaped := ((mdp (args malicious)).toOption.get!.getObjValAs? String "svg").toOption.get!
#guard escaped.contains "&lt;script&gt;"
#guard !escaped.contains "<script>"
#guard ok (mdp (args "protocol Empty (A,B) {}")) "drawn"
#guard (mdp (args "protocol Empty (A,B) {}")).toOption.get!.getObjValD "terminalProbability" == Json.str "1"

-- Clock/deadline states retain shifted event times instead of assuming day zero.
def shifted := sampleText.replace "address: ForwardingAddress from Tenant to Landlord;"
  "address: ForwardingAddress from Tenant to Landlord at time(ended) + 1 days;"
def shiftedNodes := (mdp (args shifted)).toOption.get!.getObjValD "nodes" |>.getArr? |>.toOption.get!
#guard shiftedNodes.any (fun n => n.getObjValD "kind" == Json.str "clock" &&
  n.getObjValD "timeMs" == toJson (86400000 : Nat) && n.getObjValD "detail" == Json.str "trigger = day 1")
#guard shiftedNodes.any (fun n => n.getObjValD "kind" == Json.str "obligation" &&
  n.getObjValD "detail" == Json.str "Landlord: due day 15")

/-! Requirement selfhost.session.amounts: amounts on states, balances at terminals, exact expectations. -/
def pricedText := include_str "../../examples/sessions/PricedDepositSettlement.leanfm"
def priced := (mdp (args pricedText)).toOption.get!
def pricedTerminals := ((priced.getObjValD "terminals").getArr?).toOption.get!.toList
def netOf (t : Json) (role : String) : Int :=
  (((t.getObjValD "balances").getArr?).toOption.get!.toList.find? (fun b => b.getObjValD "role" == Json.str role)).map
    (fun b => (b.getObjValAs? Int "net").toOption.getD 0) |>.getD 0
#guard ok (mdp (args pricedText)) "drawn"
#guard priced.getObjValD "terminalProbability" == Json.str "1"
-- the amount sample splits the deductions branch: four terminals, masses still exact
#guard pricedTerminals.map (·.getObjValD "probability") == [Json.str "27/40", Json.str "3/40", Json.str "1/8", Json.str "1/8"]
-- balances: the deposit returned, plus the 2000 USD penalty only where the deadline was missed
#guard pricedTerminals.map (netOf · "Tenant") == [1000, 3000, 700, 400]
-- value is moved, not created: each terminal's balances sum to zero
#guard pricedTerminals.all fun t => netOf t "Tenant" + netOf t "Landlord" == 0
-- exact expectations: 27/40·1000 + 3/40·3000 + 1/8·700 + 1/8·400 = 2075/2
#guard priced.getObjValD "expectedBalances" == toJson [
  Json.mkObj [("role", "Tenant"), ("unit", "USD"), ("expected", "2075/2")],
  Json.mkObj [("role", "Landlord"), ("unit", "USD"), ("expected", "-2075/2")]]
#guard priced.getObjValD "expectedPenalties" == toJson [
  Json.mkObj [("payer", "Landlord"), ("unit", "USD"), ("expected", "150")]]
#guard ((priced.getObjValAs? String "report").toOption.getD "").contains "Tenant: 2075/2 USD"
#guard ((priced.getObjValAs? String "svg").toOption.getD "").contains "Expected: Tenant +2075/2 USD"
-- the violated terminal names its penalty; the others do not
#guard pricedTerminals.map (fun t => ((t.getObjValAs? String "detail").toOption.getD "").contains "pays 2000 USD") == [false, true, false, false]
-- erasure: amounts and penalties leave the global type and its checks unchanged
def unpriced := ((pricedText.replace " amount 1000 USD" "").replace "\n        amount sample { 700 USD : 1/2; 400 USD : 1/2; }" "").replace " pays 2000 USD to Tenant" ""
#guard (Text.parse pricedText).toOption.map (reprStr ·.global) == (Text.parse unpriced).toOption.map (reprStr ·.global)
-- amounts compose with time samples in one message: 2 times × 2 amounts
def both := "protocol P (A,B) { r: R from A to B; Pay from B to A cause r amount sample { 10 USD : 1/2; 20 USD : 1/2; } at time(r) + sample { 1 days : 1/4; 2 days : 3/4; }; }"
#guard ((mdp (args both)).toOption.get!.getObjValD "terminals").getArr?.toOption.get!.size == 4
#guard (mdp (args both)).toOption.get!.getObjValD "expectedBalances" == toJson [
  Json.mkObj [("role", "A"), ("unit", "USD"), ("expected", "15")], Json.mkObj [("role", "B"), ("unit", "USD"), ("expected", "-15")]]
-- an exchange in two units: each unit is conserved on its own
def swap := "protocol Swap (Buyer, Seller) { o: Order from Buyer to Seller amount 1000 USD; Goods from Seller to Buyer cause o amount 3 Widget; }"
#guard (mdp (args swap)).toOption.get!.getObjValD "expectedBalances" == toJson [
  Json.mkObj [("role", "Buyer"), ("unit", "USD"), ("expected", "-1000")], Json.mkObj [("role", "Seller"), ("unit", "USD"), ("expected", "1000")],
  Json.mkObj [("role", "Buyer"), ("unit", "Widget"), ("expected", "3")], Json.mkObj [("role", "Seller"), ("unit", "Widget"), ("expected", "-3")]]
-- the protocol text writes amounts and penalties back as it read them
def pricedParsed := (Text.parse pricedText).toOption.get!
def rewritten := Text.write [{ name := pricedParsed.name, roles := pricedParsed.roles, body := pricedParsed.body }]
#guard rewritten.contains "amount 1000 USD at settlement"
#guard rewritten.contains "amount sample { 700 USD : 1/2; 400 USD : 1/2; }"
#guard rewritten.contains "pays 2000 USD to Tenant"
#guard ((mdp (args rewritten)).toOption.get!.getObjValD "expectedBalances") == priced.getObjValD "expectedBalances"
-- negative: malformed amounts and penalties are rejected, never guessed
#guard errorHas (mdp (args "protocol P (A,B) { R from A to B amount sample { 1 USD : 1/2; 2 EUR : 1/2; }; }")) "one unit"
#guard errorHas (mdp (args "protocol P (A,B) { R from A to B amount sample { 1 USD : 1/2; 2 USD : 1/3; }; }")) "not 1"
#guard errorHas (mdp (args "protocol P (A,B) { R from A to B amount sample { 1 USD : 1/2; 1 USD : 1/2; }; }")) "duplicate quantity"
#guard errorHas (mdp (args "protocol P (A,B) { R from A to B amount 1234567890123 USD; }")) "too large"
#guard errorHas (mdp (args "protocol P (A,B) { R from A to B amount -5 USD; }")) "a single amount is not negative"
#guard errorHas (mdp (args "protocol P (A,B) { R from A to B amount 5.5 USD; }")) "numeral"
#guard errorHas (mdp (args "protocol P (A,B) { R at A amount 5 USD; }")) "';'"
#guard errorHas (mdp (args (pricedText.replace "pays 2000 USD to Tenant" "pays 2000 USD to Landlord"))) "not to its payer"
#guard errorHas (mdp (args (pricedText.replace "pays 2000 USD to Tenant" "pays 2000 USD to Bank"))) "unknown role Bank"
-- a pending obligation's penalty is not counted
def pendingPriced := "protocol P (A,B) { r: R from A to B; clock c = time(r); obligation O on B { trigger c; require Yes within 1 days; on breach record Bad pays 50 USD to A; } choice at B using declared(\"x\") { probability 1/2: Yes from B to A; } or { probability 1/2: No from B to A; } }"
#guard (mdp (args pendingPriced)).toOption.get!.getObjValD "expectedPenalties" == toJson ([] : List Json)
end LeanFM.Session.DecisionTests
