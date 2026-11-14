import LeanFM.SessionTools

/-! Tests for selfhost.session.actor-conformance, selfhost.session.timelines and
selfhost.session.critical-path (decision session-actors): a log's interleaving does not change a
verdict; every duration is a difference of one clock's readings. -/
namespace LeanFM.Session.ActorTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def lookup := "protocol Lookup (Browser, Api, Db, Cache) {
  q: GetUser from Browser to Api route \"GET /users\";
  par {
    d: Query from Api to Db cause q;
    Row from Db to Api cause d;
  } and {
    c: Get from Api to Cache cause q;
    Hit from Cache to Api cause c;
  }
  Ok from Api to Browser cause q status 200;
}"

/- The true times, in ms: the browser asks at 0 and the api has it at 2; the api asks the database
and the cache at 3; the database has the query at 4 and answers at 14, received at 15; the cache
has its request at 4 and answers at 6, received at 7; the api answers at 16, received at 18.
Each machine's clock is off by its own amount: the api's by +5 s, the database's by -3 s, the
cache's by +1 hour. No duration below depends on those offsets. -/
def ms (n : Int) : Json := Json.str (toString (n * 1000000).toNat)
def api (t : Int) : Json := ms (t + 5000)
def db (t : Int) : Json := ms (t + 100000 - 3000)
def cache (t : Int) : Json := ms (t + 3600000)

def ev (id label src dst : String) (cause prev : Option String) (sent recv : Json) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", "1"), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst),
    ("sentAt", sent), ("receivedAt", recv)] ++ (cause.map fun c => [("cause", Json.str c)]).getD [] ++
    (prev.map fun p => [("prev", Json.str p)]).getD [])

def logged (rowSent : Int := 14) : List Json :=
  [ ev "e1" "GetUser" "Browser" "Api/a1" none none (ms 0) (api 2)
  , ev "e2" "Query" "Api/a1" "Db/d1" (some "e1") none (api 3) (db 4)
  , ev "e3" "Get" "Api/a1" "Cache" (some "e1") (some "e2") (api 3) (cache 4)
  , ev "e4" "Row" "Db/d1" "Api/a1" (some "e2") none (db rowSent) (api 15)
  , ev "e5" "Hit" "Cache" "Api/a1" (some "e3") none (cache 6) (api 7)
  , ev "e6" "Ok" "Api/a1" "Browser" (some "e1") (some "e3") (api 16) (ms 18) ]

def args (evs : List Json) : Json := Json.mkObj [("lean", Json.str lookup), ("events", Json.arr evs.toArray)]
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def has (s part : String) : Bool := (s.splitOn part).length > 1
def issues (r : Except String Json) : String := match r with | .ok j => (j.getObjValD "issues").compress | .error e => e

/-! Interleaving carries no information -/

#guard str (conform (args (logged))) "verdict" == "conforms"
-- every order of the same events gives the same verdict: reversed, and the replies first
#guard str (conform (args (logged).reverse)) "verdict" == "conforms"
#guard str (conform (args ((logged).drop 3 ++ (logged).take 3))) "verdict" == "conforms"
#guard str (conform (args [(logged)[3]!, (logged)[5]!, (logged)[0]!, (logged)[4]!, (logged)[2]!, (logged)[1]!])) "verdict" == "conforms"
-- a real violation is found in every order too: the database answers with the cache's reply
def wrong := (logged).set 3 (ev "e4" "Hit" "Db/d1" "Api/a1" (some "e2") none (db 14) (api 15))
#guard str (conform (args wrong)) "verdict" == "violates" && str (conform (args wrong.reverse)) "verdict" == "violates"

/-! The links themselves are checked -/

-- prev names the previous event its sender sent, not another actor's
#guard has (issues (conform (args ((logged).set 5 (ev "e6" "Ok" "Api/a1" "Browser" (some "e1") (some "e4") (api 16) (ms 18)))))) "prev e4 was sent by Db/d1, not by Api/a1"
-- a cause its sender never saw
#guard has (issues (conform (args ((logged).set 4 (ev "e5" "Hit" "Cache" "Api/a1" (some "e2") none (cache 6) (api 7)))))) "is an event its sender Cache@1 never sent or received"
-- an actor's own order is one chain
#guard has (issues (conform (args ((logged).set 5 (ev "e6" "Ok" "Api/a1" "Browser" (some "e1") (some "e2") (api 16) (ms 18)))))) "Api/a1's own order forks"
-- links that form a cycle
#guard has (issues (conform (args ((logged).set 1 (ev "e2" "Query" "Api/a1" "Db/d1" (some "e1") (some "e3") (api 3) (db 4)))))) "form a cycle"
-- on one clock, a reply received before its request was sent is a cycle too: the browser's clock
-- says it sent the request at 30 ms and had the answer at 18 ms
#guard has (issues (conform (args ((logged).set 0 (ev "e1" "GetUser" "Browser" "Api/a1" none none (ms 30) (api 2)))))) "form a cycle"
-- a prev that names nothing, and an actor name with two slashes
#guard has (issues (conform (args ((logged).set 2 (ev "e3" "Get" "Api/a1" "Cache" (some "e1") (some "e9") (api 3) (cache 4)))))) "prev e9 is not an event of the log"
#guard has (str (conform (args ((logged).set 0 (ev "e1" "GetUser" "Browser/x/y" "Api/a1" none none (ms 0) (api 2))))) "verdict") "an actor is Role/instance, with one /"

/-! Durations from one clock each; the tree on the root's timeline -/

def spansOf (evs : List Json) : Json := ((spans (args evs)).toOption.getD Json.null)
def span (j : Json) (id : String) : Json :=
  match j.getObjValD "spans" with
  | .arr a => (a.find? fun s => s.getObjValD "request" == Json.str id).getD Json.null
  | _ => Json.null
def field (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD "?"

def good := spansOf (logged)
#guard field good "verdict" == "measured"
-- the browser waited 18 ms; the api took 14 ms by its own clock; 4 ms were network, both ways together
#guard [field (span good "e1") "callerViewNs", field (span good "e1") "calleeViewNs", field (span good "e1") "networkNs"] ==
  ["18000000", "14000000", "4000000"]
-- the database took 10 ms by its clock, the api waited 12 ms for it; the cache took 2 ms, waited 4 ms
#guard [field (span good "e2") "callerViewNs", field (span good "e2") "calleeViewNs"] == ["12000000", "10000000"]
#guard [field (span good "e3") "callerViewNs", field (span good "e3") "calleeViewNs"] == ["4000000", "2000000"]
-- the query and the cache overlapped on the api's clock: concurrent, so the critical path is the query
-- alone (12 ms), not their total (16 ms)
#guard (span good "e1").getObjValD "subcalls" == Json.arr #["e2", "e3"]
#guard (span good "e1").getObjValD "criticalPath" == Json.arr #["e2"]
#guard field (span good "e1") "criticalNs" == "12000000"
-- on the browser's timeline the api answers at 14 ms and the browser has it at 18 ms, whatever the
-- clocks said; the database's reply is placed by the database's own 10 ms after the query was sent
def atOf (j : Json) (e : String) : String :=
  match j.getObjValD "timelines" with
  | .arr #[t] => match t.getObjValD "events" with
    | .arr a => ((a.find? fun x => x.getObjValD "event" == Json.str e).map fun x => field x "atNs").getD "?"
    | _ => "?"
  | _ => "?"
#guard [atOf good "e1", atOf good "e6", atOf good "e6 received", atOf good "e4"] == ["0", "14000000", "18000000", "11000000"]
#guard has (field good "reading") "GetUser: Browser@1 waited 18.000 ms, critical path Query (12.000 ms)"

-- negative: the database claims 13 ms by its clock, but the api waited only 12 ms for it
def skewed := spansOf (logged (rowSent := 17))
#guard field skewed "verdict" == "inconsistent"
#guard has (skewed.getObjValD "issues").compress "Db/d1 took 13000000 ns by its own clock, longer than Api/a1 waited for it (12000000 ns by its clock)"

-- a reply the api never waited for (it answered before the reply came back) is listed, not counted
def late := spansOf ((logged).set 4 (ev "e5" "Hit" "Cache" "Api/a1" (some "e3") none (cache 6) (api 17)))
#guard (span late "e1").getObjValD "notAwaited" == Json.arr #["e3"]
-- no clock readings: the calls are found, their durations are not invented
#guard field (span (spansOf ((logged).map fun e => (e.setObjVal! "sentAt" Json.null).setObjVal! "receivedAt" Json.null)) "e1") "callerViewNs" == "?"

end LeanFM.Session.ActorTests
