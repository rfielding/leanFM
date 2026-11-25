import LeanFM.SessionTools

/-! Tests for selfhost.session.log-sessions (decision session-log-sessions): a log that names no
sessions is split by identity the protocol declares (causes and the session key), never by prev or a
where equation, and an event the log cannot place is reported, never guessed. -/
namespace LeanFM.Session.LogSessionsTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def ping := "protocol Ping (A, B) {\n  m: Msg from A to B;\n  Resp from B to A cause m;\n}"
def pingNoCause := "protocol Ping (A, B) {\n  Msg from A to B;\n  Resp from B to A;\n}"

/-- An event; `session` none leaves the field out. -/
def ev (id label src dst : String) (cause : Option String := none) (session : Option String := none)
    (prev : Option String := none) (fields : Option Json := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("from", Json.str src), ("to", Json.str dst), ("label", Json.str label)] ++
    (session.map fun s => [("session", Json.str s)]).getD [] ++ (cause.map fun c => [("cause", Json.str c)]).getD [] ++
    (prev.map fun p => [("prev", Json.str p)]).getD [] ++ (fields.map fun f => [("fields", f)]).getD [])

def run (text : String) (evs : List Json) (extra : List (String × Json) := []) : Except String Json :=
  conform (Json.mkObj ([("lean", Json.str text), ("events", Json.arr evs.toArray)] ++ extra))
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def has (s part : String) : Bool := (s.splitOn part).length > 1
def issues (r : Except String Json) : String := match r with | .ok j => (j.getObjValD "issues").compress | .error e => e
/-- The derived sessions: each key with its event positions. -/
def derived (r : Except String Json) : List (String × List Nat) :=
  match r with
  | .ok j => match (j.getObjValD "derivedSessions").getObjValD "sessions" with
    | .arr a => a.toList.map fun s => ((s.getObjValAs? String "key").toOption.getD "",
        ((s.getObjValD "events").getArr?.toOption.getD #[]).toList.filterMap (·.getNat?.toOption))
    | _ => []
  | .error _ => []

/-! Two parallel copies of Ping, interleaved msg 1, msg 0, resp 0, resp 1, with no session ids -/

def interleaved : List Json :=
  [ ev "m1" "Msg" "A" "B", ev "m0" "Msg" "A" "B"
  , ev "r0" "Resp" "B" "A" (some "m0"), ev "r1" "Resp" "B" "A" (some "m1") ]
#guard str (run ping interleaved) "verdict" == "conforms"
#guard derived (run ping interleaved) == [("chain from m1", [0, 3]), ("chain from m0", [1, 2])]
-- every interleaving gives the same sessions and the same verdict
#guard str (run ping interleaved.reverse) "verdict" == "conforms"
#guard str (run ping [interleaved[1]!, interleaved[2]!, interleaved[0]!, interleaved[3]!]) "verdict" == "conforms"
-- negative: as one session the same log would not conform (that is what a missing id did before)
#guard str (run ping (interleaved.map fun e => e.setObjVal! "session" (Json.str "0"))) "verdict" == "violates"

/-! Without causes the resps cannot be placed: either pairing fits, so neither is guessed -/

def noCauses : List Json := [ev "m1" "Msg" "A" "B", ev "m0" "Msg" "A" "B", ev "r0" "Resp" "B" "A", ev "r1" "Resp" "B" "A"]
#guard str (run pingNoCause noCauses) "verdict" == "violates"
#guard has (issues (run pingNoCause noCauses)) "event r0 (Resp from B to A) cannot be placed in a session"
#guard has (issues (run pingNoCause noCauses)) "name the message it answers as its cause in the protocol, declare a session key, or log session ids"
-- negative: prev does not join sessions: one server instance B/b1 answers both, its second resp
-- naming its first as prev, yet the sessions stay apart (an actor named by its role alone is that
-- role in its own session, so a server shared by sessions is named as an instance)
def withPrev : List Json :=
  [ ev "m1" "Msg" "A" "B/b1", ev "m0" "Msg" "A" "B/b1"
  , ev "r0" "Resp" "B/b1" "A" (some "m0"), ev "r1" "Resp" "B/b1" "A" (some "m1") none (some "r0") ]
#guard str (run ping withPrev) "verdict" == "conforms"
#guard (derived (run ping withPrev)).length == 2
#guard has (issues (run pingNoCause (noCauses.set 3 (ev "r1" "Resp" "B" "A" none none (some "r0"))))) "event r1 (Resp from B to A) cannot be placed"

/-! A log that names sessions: checked as before, the derived sessions a cross-check -/

def named (s0 s1 : String) : List Json :=
  [ ev "m1" "Msg" "A" "B" none (some s1), ev "m0" "Msg" "A" "B" none (some s0)
  , ev "r0" "Resp" "B" "A" (some "m0") (some s0), ev "r1" "Resp" "B" "A" (some "m1") (some s1) ]
#guard str (run ping (named "0" "1")) "verdict" == "conforms"
#guard (match run ping (named "0" "1") with
  | .ok j => ((j.getObjValD "derivedSessions").getObjValD "sessions").compress.contains "\"logSessions\":[\"1\"]"
  | _ => false)
-- negative: session ids that split a cause chain are a problem naming both events and the cause
def split : List Json := (named "0" "1").set 2 (ev "r0" "Resp" "B" "A" (some "m0") (some "1"))
#guard str (run ping split) "verdict" == "violates"
#guard has (issues (run ping split)) "events m0 and r0 are one session, because r0 names m0 as its cause, but the log puts them in sessions 0 and 1"
-- negative: a session named on some events only is refused
#guard has (str (run ping ((named "0" "1").set 0 (ev "m1" "Msg" "A" "B"))) "verdict") "name a session on every event or on none"

/-! The declared session key joins; a where equation does not -/

def keyedLoop := "structure Ask where\n  caller : String\n\nprotocol K (A, B) {\n  sessions by a.caller {\n    loop L {\n      choice {\n        a: Ask from A to B;\n        Reply from B to A cause a;\n        continue L;\n      } or {\n        Bye from A to B;\n      }\n    }\n  }\n}"
def ask (id caller : String) : Json := ev id "Ask" "A" "B" none none none (some (Json.mkObj [("caller", Json.str caller)]))
-- two asks of alice, no cause between them, are one session by the key; bob's is another
def keyedEvents : List Json :=
  [ ask "a1" "alice", ask "b1" "bob", ev "r1" "Reply" "B" "A" (some "a1"), ask "a2" "alice", ev "r2" "Reply" "B" "A" (some "a2"), ev "rb" "Reply" "B" "A" (some "b1") ]
#guard derived (run keyedLoop keyedEvents [("allowIncomplete", Json.bool true)]) == [("caller=alice", [0, 2, 3, 4]), ("caller=bob", [1, 5])]
#guard str (run keyedLoop keyedEvents [("allowIncomplete", Json.bool true)]) "verdict" == "conforms"

def priced := "structure Quote where\n  price : Nat\nstructure Pay where\n  amount : Nat\nprotocol Buy (C, S) {\n  q: Quote from S to C;\n  p: Pay from C to S cause q where p.amount = q.price;\n}"
def quote (id : String) : Json := ev id "Quote" "S" "C" none none none (some (json% {price: 10}))
def pay (id cause : String) : Json := ev id "Pay" "C" "S" (some cause) none none (some (json% {amount: 10}))
-- two sessions that both pay 10 stay two: an equation is a condition, not an identity
#guard derived (run priced [quote "q1", quote "q2", pay "p2" "q2", pay "p1" "q1"]) == [("chain from q1", [0, 3]), ("chain from q2", [1, 2])]
#guard str (run priced [quote "q1", quote "q2", pay "p2" "q2", pay "p1" "q1"]) "verdict" == "conforms"

/-! Every answer carries the log as a stream numbered from 1, for the view's session buttons -/

#guard (match run ping interleaved with
  | .ok j => match j.getObjValD "events" with
    | .arr a => a.size == 4 && (a[3]!.getObjValD "id") == toJson (4 : Nat) && (a[3]!.getObjValD "cause") == toJson (1 : Nat) &&
        (a[3]!.getObjValD "logId") == Json.str "r1" && (a[3]!.getObjValD "session") == Json.str "chain from m1"
    | _ => false
  | _ => false)

end LeanFM.Session.LogSessionsTests
