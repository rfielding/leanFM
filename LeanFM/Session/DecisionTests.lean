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
end LeanFM.Session.DecisionTests
