import LeanFM.Session.Linked
import LeanFM.SessionTools

/-! Tests for linked logs (every prev and cause names an event) and for the HTTP shape of a
protocol (a status answers a request; a route is never a response). -/

open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def e (id src dst label : String) (cause prev : Option String := none) : LogEvent :=
  { id, src, dst, label, cause, prev }

def good : List LogEvent :=
  [e "1" "C" "S" "Q", e "2" "S" "C" "R" (cause := some "1"), e "3" "C" "S" "Q" (prev := some "1")]

def isOk : Except (List String) Linked → Bool | .ok _ => true | .error _ => false
def errs : Except (List String) Linked → List String | .ok _ => [] | .error ps => ps

#guard isOk (Linked.check good)
#guard isOk (Linked.check [])
-- a dangling link, of either kind, makes no Linked; each is named
#guard errs (Linked.check [e "1" "C" "S" "Q" (cause := some "9")]) == ["event 1: cause 9 is not an event of the log"]
#guard errs (Linked.check [e "1" "C" "S" "Q" (prev := some "0"), e "2" "S" "C" "R" (cause := some "7")]) ==
  ["event 1: prev 0 is not an event of the log", "event 2: cause 7 is not an event of the log"]

-- push takes a proof that the new event's links are already there
def l1 : Linked := Linked.empty.push (e "1" "C" "S" "Q") (by simp [LogEvent.links, e])
def l2 : Linked := l1.push (e "2" "S" "C" "R" (cause := some "1"))
  (by intro p hp; simp [LogEvent.links, e] at hp; subst hp; exact ⟨e "1" "C" "S" "Q", by simp [l1, Linked.push, Linked.empty], rfl⟩)
#guard l2.events.map (·.id) == ["1", "2"]

-- the cause of a linked event is an event, not an Option, and it is the one named
example : (l2.cause (e := e "2" "S" "C" "R" (cause := some "1"))
    (by simp [l2, l1, Linked.push, Linked.empty]) (c := "1") rfl).id = "1" :=
  Linked.cause_id _ _ _

-- a response with its request: cause is the request, and it goes back the way the request came
def lg : Linked := match Linked.check good with | .ok l => l | .error _ => Linked.empty
#guard (lg.events.attach.filterMap fun ⟨r, hr⟩ => (Answered.of? lg r hr).map fun a => (a.response.id, a.request.id)) == [("2", "1")]

-- session_conform does not replay a log with a dangling link: it names every one
def lookup : String := "protocol P (C, S) { q: Q from C to S; R from S to C cause q; }"
def conformArgs (evs : String) : Json :=
  Json.mkObj [("lean", Json.str lookup), ("events", (Json.parse evs).toOption.getD Json.null)]
def answer (evs : String) : Json := match conform (conformArgs evs) with | .ok j => j | .error m => Json.str m
#guard (answer "[{\"id\":\"1\",\"from\":\"C\",\"to\":\"S\",\"label\":\"Q\"},{\"id\":\"2\",\"from\":\"S\",\"to\":\"C\",\"label\":\"R\",\"cause\":\"1\"}]").getObjValD "verdict" == "conforms"
#guard (answer "[{\"id\":\"1\",\"from\":\"C\",\"to\":\"S\",\"label\":\"Q\"},{\"id\":\"2\",\"from\":\"S\",\"to\":\"C\",\"label\":\"R\",\"cause\":\"5\"}]").getObjValD "issues" ==
  Json.arr #["event 2: cause 5 is not an event of the log"]

-- the HTTP shape of a protocol
def issuesOf (t : String) : List String := match check (Json.mkObj [("lean", Json.str t)]) with
  | .ok j => match j.getObjValD "issues" with | .arr a => a.toList.filterMap (·.getStr?.toOption) | _ => []
  | .error m => [m]
#guard issuesOf "protocol P (C, S) { q: Q from C to S route \"GET /x\"; R from S to C cause q status 200; }" == []
-- a status with no request up its cause chain answers nothing
#guard issuesOf "protocol P (C, S) { q: Q from C to S route \"GET /x\"; R from S to C status 200; }" ==
  ["R has status 200, so it is a response, but no request from C to S is up its cause chain; give it the request it answers as its cause"]
-- a cause that goes the same way is not a request being answered
#guard issuesOf "protocol P (A, B, C) { q: Q from A to B; R from B to C cause q status 200; }" ==
  ["R has status 200, so it is a response, but no request from C to B is up its cause chain; give it the request it answers as its cause"]
-- a route marks a request, so a message its cause chain makes a response cannot have one
#guard issuesOf "protocol P (C, S) { q: Q from C to S route \"GET /x\"; R from S to C cause q route \"GET /y\"; }" ==
  ["R has route GET /y, so it is a request, but its cause chain makes it a response to Q"]
-- an answered request needs no route: a call over another transport
#guard issuesOf "protocol P (A, S) { s: SendCode from A to S; Queued from S to A cause s status 202; }" == []
