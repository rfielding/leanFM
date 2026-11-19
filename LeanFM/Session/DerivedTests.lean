import LeanFM.Session.Derived

/-! Tests for derived sessions (clause selfhost.session.derived-sessions, decision
session-derived-sessions): events are grouped by where-clause equations and cause/prior links,
never by the session numbers a simulated stream carries. -/

namespace LeanFM.Session.DerivedTests
open LeanFM.Session.Derived Lean

def ev (id : Nat) (msg : String) (fields : List (String × String)) (cause : Option Nat := none)
    (prior : List Nat := []) (session : Nat := 0) : Ev :=
  { id, msgId := some msg, fields, cause, prior, session }

-- a join message and moves in two rooms; Moved answers a move and carries no field
def roomEqs : List Equation := equations ["m.roomId = j.roomId"]
#guard roomEqs.map (·.text) == ["m.roomId = j.roomId"]
def rooms : Array Ev := #[
  ev 0 "j" [("roomId", "r1")] (session := 1),
  ev 1 "j" [("roomId", "r2")] (session := 2),
  ev 2 "m" [("roomId", "r1")] (session := 1),
  ev 3 "m" [("roomId", "r2")] (session := 2),
  ev 4 "ok" [] (cause := some 2) (session := 1),
  ev 5 "ping" [] (session := 3)]
def roomsR := group roomEqs rooms
#guard roomsR.sessions.toList.map (fun s => (s.key, s.events.toList, s.simulated)) ==
  [("roomId=r1", [0, 2, 4], [1]), ("roomId=r2", [1, 3], [2])]
-- the response with no field joins its request through cause; the ping no clause or link reaches
#guard roomsR.unattributed.toList == [5]
#guard roomsR.matching == 2
-- an equation under or need not hold, so it is not a join; under and it is
#guard equations ["m.roomId = j.roomId or m.x = 1"] == []
#guard (equations ["m.roomId = j.roomId and m.user = j.user"]).length == 2
#guard equations ["not (m.roomId = j.roomId)"] == []
-- equations over different fields that share an event merge the groups and say which event did
def mixed : Array Ev := #[
  ev 0 "j" [("roomId", "r1")],
  ev 1 "u" [("userId", "u7")],
  ev 2 "m" [("roomId", "r1"), ("userId", "u7")]]
def mixedR := group (equations ["m.roomId = j.roomId and m.userId = u.userId"]) mixed
#guard mixedR.sessions.size == 1
#guard mixedR.sessions[0]!.key == "roomId=r1, userId=u7"
#guard mixedR.sessions[0]!.joinedBy == some "e002 carries roomId=r1 and userId=u7"
-- groups partition the attributed events: no event is in two sessions
def partitions (r : Result) (n : Nat) : Bool :=
  let all := r.sessions.toList.flatMap (·.events.toList) ++ r.unattributed.toList
  all.length == n && (List.range n).all all.contains
#guard partitions roomsR rooms.size
#guard partitions mixedR mixed.size
-- a group joined only by links is named by its chain's first event
#guard (group [] #[ev 0 "a" [], ev 1 "b" [] (prior := [0])]).sessions.toList.map (·.key) == ["chain from e000"]
-- the simulated session numbers never group: two runs sharing a room are one session
#guard (group roomEqs #[ev 0 "j" [("roomId", "r1")] (session := 1), ev 1 "m" [("roomId", "r1")] (session := 2)]).sessions.toList.map
  (fun s => (s.events.toList, s.simulated)) == [([0, 1], [1, 2])]
-- links name events by id, not position: a stream numbered from 1 is one chain, nothing unattributed
#guard (group [] #[ev 1 "a" [], ev 2 "b" [] (cause := some 1) (prior := [1]), ev 3 "c" [] (prior := [2])]).sessions.toList.map
  (fun s => (s.key, s.events.toList)) == [("chain from e001", [0, 1, 2])]
-- read from session_simulate's JSON
#guard (Ev.ofJson (Json.parse "{\"id\":3,\"session\":2,\"msgId\":\"m\",\"cause\":1,\"prior\":[0],\"fields\":{\"room\":{\"id\":\"r9\"},\"n\":4}}" |>.toOption.get!)).fields ==
  [("n", "4"), ("room.id", "r9")]

end LeanFM.Session.DerivedTests
