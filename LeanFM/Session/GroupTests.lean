import LeanFM.SessionTools
import LeanFM.Session.Faithful

/-! Tests for groups (selfhost.session.group): a bracket for people that no answer sees, drawn as a
group frame, foldable only where nothing interleaves with it. -/

namespace LeanFM.Session.GroupTests
open Lean LeanFM LeanFM.SessionTools LeanFM.Session

def plain := "protocol Upload (Client, Server, Log) {
  q: Headers from Client to Server;
  Data from Client to Server;
  End from Client to Server;
  Saved from Server to Client cause q;
  parallel {
    Note from Server to Log;
    Ack from Log to Server;
  } and {
    Done from Server to Client;
  }
}"

def grouped := "protocol Upload (Client, Server, Log) {
  group Request {
    q: Headers from Client to Server;
    Data from Client to Server;
    End from Client to Server;
  }
  Saved from Server to Client cause q;
  parallel {
    group Audit {
      Note from Server to Log;
      Ack from Log to Server;
    }
  } and {
    Done from Server to Client;
  }
}"

def call (f : Json → Except String Json) (text : String) (extra : List (String × Json) := []) : Json :=
  match f (Json.mkObj (("lean", Json.str text) :: extra)) with | .ok j => j | .error e => Json.str e
def drop (keys : List String) (j : Json) : Json :=
  match j with
  | .obj kvs => Json.mkObj (kvs.toList.filter fun (k, _) => !keys.contains k)
  | other => other
/-- An answer with the fields that echo the text or draw it removed. -/
def answer (f : Json → Except String Json) (text : String) (extra : List (String × Json) := []) : String :=
  (drop ["lean", "diagram", "svg", "outline", "protocol"] (call f text extra)).compress

def protocolOf? (text : String) : Option Protocol := (parseProtocol (Json.mkObj [("lean", Json.str text)])).toOption
def labelsOf (text : String) : List String := ((protocolOf? text).map (·.global.labels)).getD ["?"]
def projectionsOf (text : String) : List String :=
  ((protocolOf? text).map fun p => p.roles.map fun r => toString (repr (p.global.project r))).getD ["?"]
def modelOf? (text : String) : Option DiagramModel := (protocolOf? text).map fun p => p.global.diagramModel p.roles

-- the brackets change no answer: labels, projections, typestates, faithful rules, CTL, simulation
#guard labelsOf grouped == labelsOf plain && labelsOf plain != ["?"]
#guard projectionsOf grouped == projectionsOf plain && projectionsOf plain != ["?"]
#guard answer ctl grouped [("faithful", Json.str "rules")] == answer ctl plain [("faithful", Json.str "rules")]
#guard answer ctl grouped [("formula", Json.mkObj [("inevitably", Json.mkObj [("on", Json.str "Saved")])])] ==
       answer ctl plain [("formula", Json.mkObj [("inevitably", Json.mkObj [("on", Json.str "Saved")])])]
#guard ((call simulate grouped [("seed", toJson (7 : Nat))]).getObjValD "events").compress ==
       ((call simulate plain [("seed", toJson (7 : Nat))]).getObjValD "events").compress
-- the diagram: a group frame captioned with its name; the model lists both groups
def shapesOf (text : String) : List Shape := ((modelOf? text).map (·.shapes.toList)).getD []
#guard (shapesOf grouped).any fun s => match s with | .rect c .. => c == "frame group" | _ => false
#guard (shapesOf grouped).any fun s => match s with | .text _ _ _ _ _ _ _ t => t == "[Request]" | _ => false
#guard (((modelOf? grouped).map (·.groups.toList)).getD [] |>.map fun g => (g.name, g.foldable, g.ends)) ==
  [("Request", true, some ("Client", "Server", true)), ("Audit", false, some ("Server", "Log", false))]
-- inside sessions, and after a join of fewer than all, a group does not fold; three roles have no ends
def groupsOf (text : String) := (((modelOf? text).map (·.groups.toList)).getD []).map fun g => (g.name, g.foldable, g.ends.isSome)
#guard groupsOf "protocol S (A, B) { sessions { group G { X from A to B; Y from B to A; } } }" == [("G", false, true)]
#guard groupsOf "protocol J (A, B, C) { join 1 of { P from A to B; } and { Q from A to C; } group G { X from A to B; } }" == [("G", false, true)]
#guard groupsOf "protocol T (A, B, C) { group G { X from A to B; Y from B to C; } }" == [("G", true, false)]
-- the writer writes a group back, and the text reads again to the same protocol
def defsOf (text : String) : List Text.Def := match Text.readText text with | .ok (ds, _) => ds | .error e => panic! e
#guard (Text.write (defsOf grouped)).contains "group Request {"
#guard Text.write (defsOf (Text.write (defsOf grouped))) == Text.write (defsOf grouped)
-- refused: a continue leaving a group, two groups with one name, a name that is not an identifier
def refused (text : String) (part : String) : Bool := match parseProtocol (Json.mkObj [("lean", Json.str text)]) with
  | .ok _ => false | .error e => part.isEmpty || (e.splitOn part).length > 1
#guard refused "protocol L (A, B) { loop R { group G { X from A to B; continue R; } } }" "continue R would leave the group"
#guard refused "protocol D (A, B) { group G { X from A to B; } group G { Y from B to A; } }" "two groups named G"
#guard refused "protocol N (A, B) { group 3 { X from A to B; } }" ""
-- a loop inside a group may continue itself
#guard !refused "protocol I (A, B) { group G { loop R { choice { X from A to B; continue R; } or { Y from A to B; } } } }" ""
-- the explorer's tree has a node for the group with its steps under it
#guard ((call explore grouped).compress.splitOn "\"group Request\"").length > 1

end LeanFM.Session.GroupTests
