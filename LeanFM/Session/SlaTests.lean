import LeanFM.SessionTools

/-! Tests for selfhost.session.sla and selfhost.session.execution. Expected values are worked by
hand from the stated probabilities and delays. -/
namespace LeanFM.Session.SlaTests
open Lean LeanFM LeanFM.SessionTools LeanFM.Session

def userLookup := include_str "../../examples/sessions/UserLookup.leanfm"

def run (text : String) (extra : List (String × Json) := []) : Except String Json :=
  sla (Json.mkObj ([("lean", Json.str text)] ++ extra))

def design (r : Except String Json) (i : Nat) (k : String) : Json :=
  match r with
  | .ok j => match j.getObjVal? "design" with
    | .ok (.arr a) => ((a[i]?).map fun d => (d.getObjVal? k).toOption.getD Json.null).getD Json.null
    | _ => Json.null
  | .error _ => Json.null

def prob (r : Except String Json) (i : Nat) (k : String) : String :=
  match design r i "probability" with
  | .obj _ => ((design r i "probability").getObjValAs? String k).toOption.getD ""
  | _ => ""

def errorHas (r : Except String Json) (s : String) : Bool :=
  match r with | .error e => (e.splitOn s).length > 1 | .ok _ => false

/-! Design time: the requirements against the assumptions. -/

-- the Proxy's 504 timer answers every lookup within 2 seconds: 2 ms + 1900 ms on the lost forward
#guard design (run userLookup) 0 "verdict" == Json.str "met"
-- 0.999 × (0.97 × 0.999 + 0.02) of lookups answer Ok or NotFound within 300 ms; at least 98/100 holds
#guard prob (run userLookup) 1 "lo" == "98804097/100000000" && design (run userLookup) 1 "verdict" == Json.str "met"
-- 0.999 × 1/100 failures plus 1/1000 lost forwards = 1099/100000 server errors, over the 1/200 budget
#guard prob (run userLookup) 2 "lo" == "1099/100000" && design (run userLookup) 2 "verdict" == Json.str "violated"
#guard design (run userLookup) 2 "assumptions" == toJson ["[forward-delivered → Forward: 999/1000]", "[lookup → Failure: 1/100]"]
-- the rule of three: ln(20)/0.02 → 150 entries; ln(20)/0.005 → 600, more than an hour at 500 an hour holds
#guard design (run userLookup) 1 "windowNeeds" == toJson (some 150) && design (run userLookup) 1 "windowHoldsThem" == toJson (some true)
#guard design (run userLookup) 2 "windowNeeds" == toJson (some 600) && design (run userLookup) 2 "windowHoldsThem" == toJson (some false)
#guard Sla.windowNeed { entry := "q", bound := .atLeast (Overlay.Q.norm 99 100), targets := [] } == some 300

-- a hard deadline that a silent branch breaks: the path ends where the session ends
def silent := "protocol Ask (A, B) { q: Ask from A to B; choice at B using declared(\"answers\") { probability 9/10: Answer from B to A cause q after 1 second; } or { probability 1/10: Shrug from B to A; } }
require per q { every q reaches Answer within 2 seconds; }"
#guard design (run silent) 0 "verdict" == Json.str "violated" && prob (run silent) 0 "lo" == "9/10"
#guard design (run silent) 0 "path" == toJson ["Ask", "[answers → Shrug: 1/10]", "Shrug", "(the session ends)"]
-- a late answer misses the deadline
def late := "protocol Ask (A, B) { q: Ask from A to B; Answer from B to A cause q after 3 seconds; }
require per q { every q reaches Answer within 2 seconds; }"
#guard design (run late) 0 "verdict" == Json.str "violated" && prob (run late) 0 "lo" == "0"
#guard design (run late) 0 "path" == toJson ["Ask", "Answer", "(at 3 seconds, past the 2 seconds deadline)"]

-- an assumption names the question and the answer taken: the same choice reads differently on each branch
def busy := "protocol Ping (C, S) { q: Ping from C to S; choice at S using declared(\"IsBusy\") { probability 9/10: Pong from S to C cause q after 50 ms; } or { probability 1/10: SlowPong from S to C cause q after 800 ms; } }
require per q { at least 95/100 of q reach Pong, SlowPong within 100 ms over 1000 entries; at most 1/2 of q reach Pong over 100 entries; }"
#guard design (run busy) 0 "path" == toJson ["Ping", "[IsBusy → SlowPong: 1/10]", "SlowPong", "(at 800 ms, past the 100 ms deadline)"]
#guard design (run busy) 1 "assumptions" == toJson ["[IsBusy → Pong: 9/10]"]

-- refusals: a fraction needs a window, every takes none, names must exist, assumptions must be stated
#guard errorHas (run "protocol P (A, B) { q: X from A to B; Y from B to A; }\nrequire per q { at least 99/100 of q reach Y within 1 second; }") "observation window"
#guard errorHas (run "protocol P (A, B) { q: X from A to B; Y from B to A; }\nrequire per q { every q reaches Y over 1 hour; }") "takes no observation window"
#guard errorHas (run "protocol P (A, B) { q: X from A to B; Y from B to A; }\nrequire per z { every z reaches Y; }") "not a message id"
#guard errorHas (run "protocol P (A, B) { q: X from A to B; Y from B to A; }\nrequire per q { every q reaches Zed; }") "not a message or event"
#guard errorHas (run "protocol P (A, B) { q: X from A to B; choice { Y from B to A; } or { Z from B to A; } }\nrequire per q { every q reaches Y; }") "an assumption is missing"
#guard errorHas (run "protocol P (A, B) { q: X from A to B; Y from B to A; }") "states no requirements"

/-! Run time: the execution is the event stream. -/

def ev (ts : Nat) (label : String) (cause : Option Nat := none) (prev : Option Nat := none) (src dst : String := "") (reward : Option Json := none) : Json :=
  Json.mkObj ([("ts", toJson ts), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst)] ++
    (cause.map (fun c => [("cause", toJson c)])).getD [] ++ (prev.map (fun p => [("prev", toJson p)])).getD [] ++
    (reward.map (fun r => [("reward", r)])).getD [])

def usd (role : String) (n : Int) : Json := Json.mkObj [(role, Json.mkObj [("USD", toJson n)])]

def simple := "protocol Ask (A, B) { q: Ask from A to B; Answer from B to A cause q after 100 ms; }
require per q { at least 99/100 of q reach Answer within 300 ms over 300 entries; }"

/-- n asks a second apart, each answered 100 ms later except the given ones -/
def stream (n : Nat) (missed : List Nat) : List Json :=
  (List.range n).flatMap fun i =>
    let t := 1000 * (i + 1)
    if missed.contains i then [ev t "Ask" none none "A" "B"] else [ev t "Ask" none none "A" "B", ev (t + 100) "Answer" (some t) none "B" "A"]

def observed (r : Except String Json) (k : String) : Json :=
  match r with
  | .ok j => match j.getObjVal? "observed" with
    | .ok o => match o.getObjVal? "requirements" with
      | .ok (.arr a) => ((a[0]?).map fun d => (d.getObjVal? k).toOption.getD Json.null).getD Json.null
      | _ => (o.getObjVal? k).toOption.getD Json.null
    | _ => Json.null
  | .error _ => Json.null

def withStream (evs : List Json) (extra : List (String × Json) := []) : Except String Json :=
  run simple ([("events", Json.arr evs.toArray)] ++ extra)

-- 300 entries all answered: met at 95/100 (0.99^300 ≈ 0.049 ≤ 0.05)
#guard observed (withStream (stream 300 [])) "verdict" == Json.str "met"
-- 290 of 300: far below 99/100, violated
#guard observed (withStream (stream 300 ((List.range 10).map (· * 30)))) "verdict" == Json.str "violated"
-- 299 of 300: neither shown met nor shown violated
#guard observed (withStream (stream 300 [5])) "verdict" == Json.str "undecided"
-- the first ask missed, but the 300-entry observation period has not closed: open, not violated
#guard observed (withStream (stream 20 [0])) "verdict" == Json.str "open"
-- the last ask's deadline outlives the stream: pending, not a miss
#guard observed (withStream [ev 1000 "Ask" none none "A" "B", ev 1100 "Answer" (some 1000) none "B" "A", ev 1200 "Ask" none none "A" "B"]) "pending" == toJson 1
-- an answer outside the entry's causal future does not count for it
#guard observed (withStream [ev 1000 "Ask" none none "A" "B", ev 1100 "Answer" none none "B" "A", ev 5000 "Ask" none none "A" "B"]) "misses" == toJson 1

-- timestamps are identities; links go to earlier events of the stream
#guard errorHas (withStream [ev 1 "Ask", ev 1 "Answer"]) "two events have timestamp 1"
#guard errorHas (withStream [ev 1 "Ask" (some 2), ev 2 "Answer"]) "not earlier"
#guard errorHas (withStream [ev 1 "Ask" (some 9)]) "not an event of the stream"

-- reward vectors: written where they change, found by walking prev back to the latest one
def rewards := [ev 1 "Ask" none none "A" "B" (some (usd "A" 5)), ev 2 "Answer" (some 1) (some 1) "B" "A",
                ev 3 "Ask" none (some 2) "A" "B" (some (usd "A" 8)), ev 4 "Ask" none none "A" "B",
                ev 5 "Answer" (some 3) (some 3) "B" "A"]
def rewardAt (ts : Nat) : Json :=
  match withStream rewards [("at", toJson ts)] with
  | .ok j => ((j.getObjVal? "at").toOption.bind fun a => (a.getObjVal? "reward").toOption).getD Json.null
  | .error e => Json.str e
#guard rewardAt 2 == Json.arr #[Json.mkObj [("role", "A"), ("unit", "USD"), ("amount", "5")]]
#guard rewardAt 5 == Json.arr #[Json.mkObj [("role", "A"), ("unit", "USD"), ("amount", "8")]]
-- event 4 has no prev: a concurrent event's vector is not taken
#guard rewardAt 4 == Json.arr #[]
-- an unchanged vector is not written again
#guard errorHas (withStream [ev 1 "Ask" none none "A" "B" (some (usd "A" 5)), ev 2 "Answer" (some 1) (some 1) "B" "A" (some (usd "A" 5))]) "only when it changes"
-- a role's state is its view: its events and their causal past
#guard (match withStream rewards [("at", toJson 5)] with
  | .ok j => ((j.getObjVal? "at").toOption.bind fun a => (a.getObjVal? "causalPast").toOption) == some (toJson [1, 2, 3, 5])
  | .error _ => false)

end LeanFM.Session.SlaTests
