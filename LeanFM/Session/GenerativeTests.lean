import LeanFM.SessionTools

/-! Regression and negative evidence for selfhost.session.generative{,.execution,.monitor}. -/
namespace LeanFM.Session.GenerativeTests
open Lean LeanFM.Session LeanFM.SessionTools LeanFM.Overlay

set_option maxRecDepth 4096
set_option maxHeartbeats 4000000

def sampleText := include_str "../../examples/sessions/DepositSettlement.leanfm"
def args (text : String := sampleText) : Json := Json.mkObj [("lean",text)]
def ok (r : Except String Json) (v : String) : Bool :=
  (r.toOption.bind fun j => (j.getObjValAs? String "verdict").toOption) == some v
def errorHas (r : Except String α) (part : String) : Bool :=
  match r with | .error e => (e.splitOn part).length > 1 | _ => false

def parsed := (Text.parse sampleText).toOption.get!
def layer := (Generative.resolve parsed.body).toOption.get!
def paths := (Generative.compile layer parsed.roles).toOption.get!
#guard ok (check (args sampleText)) "ok"
#guard ok (review (args sampleText)) "clean"
#guard paths.length == 3
#guard paths.map (fun (p,_) => p.probability.text) == ["27/40", "3/40", "1/4"]
#guard paths.map (fun (_,s) => s.now) == [604800000,2160000000,518400000]
#guard paths.map (fun (_,s) => ((Generative.reports s s.now).head!.getObjValAs? String "status").toOption) ==
  [some "fulfilled",some "violated",some "fulfilled"]

def core := "protocol DepositSettlement (Tenant, Landlord) { ended: LeaseEnded from Tenant to Landlord; address: ForwardingAddress from Tenant to Landlord; choice { DepositReturned from Landlord to Tenant cause address; } or { itemised: DeductionsItemized from Landlord to Tenant cause address; DepositReturned from Landlord to Tenant cause address; } }"
#guard (Text.parse core).toOption.get!.global.labels == parsed.global.labels
#guard (Text.parse core).toOption.get!.global.callsText == parsed.global.callsText
#guard ((Text.parse core).toOption.get!.global.stateGraph.toOption.map (·.states.length)) ==
  (parsed.global.stateGraph.toOption.map (·.states.length))

def generated := simulate <| Json.mkObj [("lean",sampleText),("seed",11),("instances",10)]
#guard ok generated "generated"
#guard generated.toOption == (simulate (Json.mkObj [("lean",sampleText),("seed",11),("instances",10)])).toOption
def roundTrip := conform <| Json.mkObj [("lean",sampleText),("events", generated.toOption.get!.getObjValD "events")]
#guard ok roundTrip "conforms"
#guard ((roundTrip.toOption.get!.getObjValD "deadlineReports").getArr?).toOption.get!.size == 10

-- External weights replace inline weights explicitly; zero never removes the branch from Global.
def overlay : Json := Json.mkObj [("name","all-itemised"), ("choices", toJson [Json.mkObj
  [("choice","illustrative-settlement-v1"),("weights",toJson ["0","1"])]])]
def replaced := (Generative.resolve parsed.body (some overlay)).toOption.get!
#guard ((Generative.compile replaced parsed.roles).toOption.get!.map (fun (p,_) => p.probability.text)) == ["0","0","1"]
#guard ok (simulate (Json.mkObj [("lean",sampleText),("overlay",overlay),("instances",2)])) "generated"
def externalOnly := "protocol P (A,B) { r: Request from A to B; choice { Yes from B to A cause r; } or { No from B to A cause r; } }"
def externalWeights := Json.mkObj [("name","external-v1"),("choices",toJson [Json.mkObj
  [("choice","choice:0"),("weights",toJson ["3/4","1/4"])]]),
  ("timings",toJson [Json.mkObj [("message","Yes"),("at","time(r) + 2 seconds")]])]
#guard ok (simulate (Json.mkObj [("lean",externalOnly),("overlay",externalWeights),("instances",4)])) "generated"
#guard errorHas (check (Json.mkObj [("lean",externalOnly),("overlay",overlay)])) "unknown choice"
#guard errorHas (check (Json.mkObj [("lean",sampleText),("overlay",Json.mkObj [("name","bad"),("typo",1)])])) "unknown overlay keys"
#guard errorHas (simulate (Json.mkObj [("lean",sampleText),("instances",200),("maxEvents",1)])) "event limit"
#guard errorHas (simulate (Json.mkObj [("lean",sampleText),("spread",5)])) "session-relative"
#guard errorHas (check (args (sampleText.replace "3/4" "3/0"))) "nonzero denominator"
#guard errorHas (check (args (sampleText.replace "3/4" "5/4"))) "between 0 and 1"
#guard errorHas (check (args (sampleText.replace "3/4" "1/4"))) "not 1"
#guard errorHas (check (args (sampleText.replace "9/10" "8/10"))) "not 1"
#guard errorHas (check (args (sampleText.replace "25 days : 1/10" "7 days : 1/10"))) "duplicate delay"
#guard errorHas (check (args (sampleText.replace "probability 1/4:" ""))) "every branch"
#guard errorHas (check (args (sampleText.replace "choice at Landlord" "choice at Tenant"))) "decider"
#guard errorHas (check (args (sampleText.replace "time(address)" "time(future)"))) "unknown or future"
#guard errorHas (check (args (sampleText.replace "trigger settlement" "trigger missing"))) "unknown clock"
#guard errorHas (check (args (sampleText.replace "on Landlord" "on Nobody"))) "unknown actor"
#guard errorHas (check (args (sampleText.replace "require DepositReturned" "require Typo"))) "unknown message label"
#guard errorHas (check (args (sampleText.replace "at time(itemised)" "at time(ended)"))) "backwards"
#guard errorHas (check (args (sampleText.replace "itemised:" "address:"))) "duplicate message id"
#guard errorHas (check (args (sampleText.replace "at time(itemised)" "at time(address)"))) "backwards"
#guard errorHas (check (args (sampleText.replace "14 days" "14 months"))) "unknown time unit"
#guard errorHas (check (args (sampleText.replace "14 days" "-1 days"))) "expected a number"

-- Clock declarations do not make an otherwise unspecified branch uniform.
def unknownWeights := sampleText.replace "probability 3/4:" "" |>.replace "probability 1/4:" ""
#guard ok (check (args unknownWeights)) "ok"
#guard errorHas (simulate (args unknownWeights)) "no probabilities"
def concurrent := "protocol P (A,B,C) { r: R from A to B; clock start = time(r); par { X from B to A; } and { Y from B to C; } }"
#guard ok (check (args concurrent)) "ok"
#guard errorHas (simulate (args concurrent)) "scheduling semantics"

-- Actual observations need not match the illustrative generation distribution.
def event (id : Nat) (src dst label : String) (time : Nat) (cause : Option Nat := none) : Json :=
  Json.mkObj ([("id",toJson id),("session",Json.str "one"),("src",toJson src),("dst",toJson dst),("label",toJson label),("time",toJson time)] ++
    (cause.toList.map fun c => ("cause",toJson c)))
def observedPrefix := [event 0 "Tenant" "Landlord" "LeaseEnded" 0,
               event 1 "Tenant" "Landlord" "ForwardingAddress" 86400000]
def observedAt (day : Nat) := observedPrefix ++ [event 2 "Landlord" "Tenant" "DepositReturned" (day*86400000) (some 1)]
def observed (es : List Json) (extra : List (String × Json) := []) :=
  conform (Json.mkObj ([("lean",toJson sampleText),("events",toJson es)] ++ extra))
def reportStatus (r : Except String Json) : Option String := do
  let j ← r.toOption
  let rs ← (j.getObjValD "deadlineReports").getArr?.toOption
  let os ← ((rs[0]!).getObjValD "report" |>.getObjValD "obligations").getArr?.toOption
  ((os[0]!).getObjValAs? String "status").toOption
#guard ok (observed (observedAt 15)) "conforms"
#guard reportStatus (observed (observedAt 15)) == some "fulfilled"
#guard reportStatus (observed (observedAt 16)) == some "violated"
#guard reportStatus (observed observedPrefix [("allowIncomplete",true)]) == some "pending"
#guard reportStatus (observed observedPrefix [("allowIncomplete",true),("horizonMs",toJson (16*86400000))]) == some "violated"
#guard reportStatus (observed (observedPrefix.take 1) [("allowIncomplete",true)]) == some "not-triggered"
#guard errorHas (observed observedPrefix [("allowIncomplete",true),("horizonMs",1)]) "horizon"
#guard errorHas (observed (observedAt 0)) "backwards"
#guard errorHas (observed [Json.mkObj [("id",0),("from","Tenant"),("to","Landlord"),("label","LeaseEnded")]] [("allowIncomplete",true)]) "requires timeMs"
#guard ok (observed (observedPrefix ++ [event 2 "Tenant" "Landlord" "DepositReturned" 86400000 (some 1)])) "violates"
-- Zero mass is not a conformance prohibition.
#guard ok (conform (Json.mkObj [("lean",sampleText),("overlay",overlay),("events",toJson (observedAt 16))])) "conforms"

-- Round-trip the extended text writer, including a timed message's guard.
def written := Text.write [{name := parsed.name, roles := parsed.roles, body := parsed.body}]
#guard ok (check (args written)) "ok"
#guard (Generative.compile ((Generative.resolve (Text.parse written).toOption.get!.body).toOption.get!) parsed.roles).toOption.get!.length == 3
#guard errorHas (Text.parse ("protocol P (A,B) { " ++ String.join (List.replicate 26 "par { ") ++ "X from A to B;" ++ String.join (List.replicate 26 " }") ++ " }")) "deeply"

#guard errorHas (Generative.appendPaths (List.replicate 65 {}) (List.replicate 65 {})) "4096"
#guard errorHas (check (args (sampleText.replace "clock settlement =" "clock settlement = time(ended); clock settlement ="))) "duplicate clock"
#guard errorHas (observed observedPrefix [("allowIncomplete",true),("horizonMs",toJson (9007199254740992 : Nat))]) "safe integer"
#guard (check (Json.mkObj [("lean",sampleText),("overlay",overlay)])).toOption.get!.getObjValD "overlay" == overlay
#guard ok (check (Json.mkObj [("lean",sampleText),("overlay",Json.null)])) "ok"
def guarded := "structure DeductionsItemized where\n  amount : Nat\n" ++
  sampleText.replace "at time(itemised);" "at time(itemised) where (itemised.amount > 0);"
def guardedParsed := (Text.parse guarded).toOption.get!
#guard ok (check (args (Text.writeAll guardedParsed.types [{name := guardedParsed.name, roles := guardedParsed.roles, body := guardedParsed.body}]))) "ok"
#guard ok (check (args "protocol P (A,B) { clock from A to B; obligation from B to A; probability from A to B; }")) "ok"
#guard errorHas (Text.parse ("protocol P (A,B) { " ++ String.join (List.replicate 100 "probability 1: ") ++ "X from A to B; }")) "deeply"
end LeanFM.Session.GenerativeTests
