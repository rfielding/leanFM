import LeanFM.Session.Layout
import LeanFM.SessionTools

/-! The layered layout of a role's state machine (selfhost.session.layout). -/

namespace LeanFM.Session.LayoutTests
open Lean LeanFM.Session.Layout

def edges (l : List (Nat × Nat)) : Array Edge := l.toArray.map fun (a, b) => { src := a, dst := b }
def overlap (a b : Box) : Bool :=
  (a.x - b.x).abs * 2 < a.w + b.w && (a.y - b.y).abs * 2 < a.h + b.h
def noOverlap (r : Result) : Bool :=
  (List.range r.boxes.size).all fun i => (List.range r.boxes.size).all fun j =>
    i == j || !overlap r.boxes[i]! r.boxes[j]!
def inside (r : Result) : Bool :=
  r.boxes.all fun b => b.x - b.w / 2 ≥ 0 && b.y - b.h / 2 ≥ 0 && b.x + b.w / 2 ≤ r.width && b.y + b.h / 2 ≤ r.height
-- a forward edge runs left to right, a back edge right to left
def directions (es : Array Edge) (r : Result) : Bool :=
  (List.range es.size).all fun i =>
    let p := r.routes[i]!
    if r.self[i]! || p.size < 2 then true
    else if r.back[i]! then p[0]!.1 > p[p.size - 1]!.1 else p[0]!.1 < p[p.size - 1]!.1

-- a chain with a loop back, a choice, and a long edge
def labels := #["start", "a", "b", "c", "d", "end"]
def es := edges [(0, 1), (1, 2), (2, 3), (3, 1), (1, 4), (4, 5), (3, 5), (0, 5)]
def r := layout labels es 0
#guard noOverlap r && inside r && directions es r
#guard r.back == #[false, false, false, true, false, false, false, false]
-- the long edge start → end passes through a point in each column between
#guard r.routes[7]!.size == 2 + 3
-- the same machine, the same layout
#guard toString (repr (layout labels es 0)) == toString (repr r)
-- crossings: two chains given crossed are uncrossed by the sweeps
def crossed := edges [(0, 1), (0, 2), (1, 4), (2, 3), (3, 5), (4, 6)]
def rc := layout #["s", "p", "q", "x", "y", "u", "v"] crossed 0
#guard (rc.boxes[3]!.y < rc.boxes[4]!.y) == (rc.boxes[2]!.y < rc.boxes[1]!.y)
-- rows: least squares under the gaps
#guard placeRows #[0, 0, 0] #[10, 10] == #[-10, 0, 10]
#guard placeRows #[0, 50] #[10] == #[0, 50]

-- names: what just happened
#guard stateLabel "S1" "S0" [("receive", "receive Initialize from Host")] == "Initialize ← Host"
#guard stateLabel "S2" "S0" [("send", "send Tools to Host"), ("send", "send TooLarge to Host")] == "Tools → Host | TooLarge → Host"
#guard stateLabel "S3" "S0" [("send", "send A to H"), ("send", "send B to H"), ("send", "send C to H")] == "S3"
#guard stateLabel "S6" "S0" [("serve", "each session")] == "S6"
#guard stateLabel "S0" "S0" [] == "start"
#guard stateLabel "End" "S0" [("send", "send Bye to H")] == "end"

-- negative: more than 400 states, a state missing, or an edge to an unknown state get no layout
#guard (machineJson ((List.range 401).map (s!"S{·}")) "S0" [] []).isNone
#guard (machineJson ["S0"] "S9" [] []).isNone
#guard (machineJson ["S0", "S1"] "S0" [] [("S0", "S7", "send A to B", "send")]).isNone

-- LeanFM's own Server: every state boxed, none overlapping, every forward edge left to right
def server : Json := match LeanFM.SessionTools.explore (Json.mkObj [("lean", Json.str (include_str "../LLMGenerated/LeanFM.leanfm")), ("states", Json.str "Server")]) with
  | .ok j => j | .error _ => Json.null
def lay := server.getObjValD "layout"
#guard (match lay.getObjValD "nodes", server.getObjValD "states" with
  | .arr ns, .arr ss => ns.size == ss.size && ns.size == 21 | _, _ => false)
#guard (match lay.getObjValD "nodes" with
  | .arr ns => ns.any (fun n => (n.getObjValAs? String "label").toOption == some "Initialize ← Host") &&
      ns.any (fun n => (n.getObjValAs? String "label").toOption == some "end" && (n.getObjValAs? Bool "ends").toOption == some true)
  | _ => false)

end LeanFM.Session.LayoutTests
