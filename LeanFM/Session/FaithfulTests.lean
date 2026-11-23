import LeanFM.SessionTools
import LeanFM.Session.Faithful

/-! Tests for selfhost.session.faithful (decision session-faithful), on LeanFM's own MCP protocol:
its typestates and rules, every rule proved by the CTL checker, and broken copies of its graph
decided by the walk exactly as the CTL checker decides the faithful rules over them: every changed
copy caught and no equivalent copy flagged. Built with the library, so `lake build` runs every
`#guard`. -/

namespace LeanFM.Session.FaithfulTests
open Lean LeanFM LeanFM.Logic LeanFM.Session.Faithful

def leanfmText : String := include_str "../LLMGenerated/LeanFM.leanfm"

def ctl (args : List (String × Json)) : Except String Json :=
  (LeanFM.SessionTools.run "session_ctl" (Json.mkObj (("lean", Json.str leanfmText) :: args))).getD (.error "no tool")

def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => "error: " ++ e
def nat (r : Except String Json) (k : String) : Nat :=
  match r with | .ok j => (j.getObjValAs? Nat k).toOption.getD 0 | .error _ => 0

def rulesAnswer := ctl [("faithful", Json.str "rules")]
#guard str rulesAnswer "verdict" == "rules"
#guard nat rulesAnswer "typestates" == 33
#guard nat rulesAnswer "lookahead" == 1
#guard nat rulesAnswer "ruleCount" == 34

/-- The protocol's draft, and its typestates. -/
def draft : Json := Id.run do
  match LeanFM.SessionTools.parseProtocol (Json.mkObj [("lean", Json.str leanfmText)]) with
  | .ok p => match p.global.draft p.name with
    | .ok (d, _) => return d
    | .error _ => return Json.null
  | .error _ => return Json.null
def spec : LGraph := (modelOfDraft draft).toOption.getD default
def ts : Typestates := typestates spec

-- every faithful rule is proved by session_ctl's checker over the protocol itself
#guard (rules ts).all fun (_, f) =>
  str (ctl [("formula", Json.str (Dag.ofFormula f).toSexpr)]) "verdict" == "proved"

/-- The faithful rules decided by the CTL checker over a draft: the reference the walk must agree with. -/
def rulesHold (d : Json) : Bool :=
  (rules ts).all fun (_, f) =>
    match checkCtl (Json.mkObj [("task", d), ("formula", Json.str (Dag.ofFormula f).toSexpr)]) LeanFM.Session.sessionBounds with
    | .ok j => (j.getObjValAs? String "verdict").toOption == some "proved"
    | .error _ => false

def transitions : Array Json := match draft.getObjValD "transitions" with | .arr a => a | _ => #[]
def states : Array Json := match draft.getObjValD "states" with | .arr a => a | _ => #[]
def withTransitions (ts' : Array Json) : Json := draft.setObjVal! "transitions" (Json.arr ts')

/-- Broken copies: each step dropped, a step sent to another state, a step relabelled, a step added. -/
def mutants : List Json :=
  let n := transitions.size
  let drops := (List.range n).map fun i => withTransitions (transitions.eraseIdxIfInBounds i)
  let pick := fun (k : Nat) => (k * 7919) % n
  let retargets := (List.range 12).map fun k =>
    let t := transitions[pick k]!
    withTransitions (transitions.set! (pick k) (t.setObjVal! "dst" (states[(k * 31) % states.size]!)))
  let relabels := (List.range 12).map fun k =>
    let t := transitions[pick k]!
    withTransitions (transitions.set! (pick k) (t.setObjVal! "message" (transitions[pick (k + 5)]!.getObjValD "message")))
  let adds := (List.range 12).map fun k =>
    let t := transitions[pick k]!
    withTransitions (transitions.push (t.setObjVal! "src" (states[(k * 17) % states.size]!)))
  drops ++ retargets ++ relabels ++ adds

def walkSays (d : Json) : Bool := match modelOfDraft d with
  | .ok c => (compare spec c).faithful
  | .error _ => false

#guard ts.deterministic
#guard mutants.length > 100
-- the walk and the CTL checker agree on every copy: faithful exactly when the rules hold
#guard mutants.all fun d => walkSays d == rulesHold d
-- and most copies do change the behaviour, so both catch them
#guard (mutants.filter (fun d => !walkSays d)).length > 90
-- the walk and the refinement agree too
#guard mutants.all fun d => match modelOfDraft d with
  | .ok c => (walk ts c).faithful == (byRefinement spec c).faithful
  | .error _ => true

-- the protocol is faithful to itself, by the walk; a dropped branch is reported with where it differs
#guard str (ctl [("faithful", Json.mkObj [("task", draft)])]) "verdict" == "faithful"
#guard str (ctl [("faithful", Json.mkObj [("task", draft)])]) "method" == "walk"
#guard str (ctl [("faithful", Json.mkObj [("lean", Json.str leanfmText)])]) "verdict" == "faithful"
def dropped := ctl [("faithful", Json.mkObj [("task", withTransitions (transitions.eraseIdxIfInBounds 3))])]
#guard str dropped "verdict" == "unfaithful"
#guard (str dropped "reading").length > 0 && ((str dropped "reading").splitOn "the protocol allows").length > 1

/-! ## Typestates that are not deterministic: decided by refinement -/

/-- a then b, or a then c, as two branches; against a then (b or c), one branch. -/
def twoBranches : String := "{\"id\": \"x\", \"states\": [\"s0\", \"s1\", \"s2\", \"s3\"], \"initial\": \"s0\", \"terminals\": [\"s3\"],
  \"transitions\": [{\"src\": \"s0\", \"dst\": \"s1\", \"message\": \"a\"}, {\"src\": \"s0\", \"dst\": \"s2\", \"message\": \"a\"},
  {\"src\": \"s1\", \"dst\": \"s3\", \"message\": \"b\"}, {\"src\": \"s2\", \"dst\": \"s3\", \"message\": \"c\"}]}"
def oneBranch : String := "{\"id\": \"y\", \"states\": [\"t0\", \"t1\", \"t3\"], \"initial\": \"t0\", \"terminals\": [\"t3\"],
  \"transitions\": [{\"src\": \"t0\", \"dst\": \"t1\", \"message\": \"a\"}, {\"src\": \"t1\", \"dst\": \"t3\", \"message\": \"b\"},
  {\"src\": \"t1\", \"dst\": \"t3\", \"message\": \"c\"}]}"
def g (s : String) : LGraph := (modelOfDraft ((Json.parse s).toOption.getD Json.null)).toOption.getD default
#guard !(typestates (g twoBranches)).deterministic
#guard (compare (g twoBranches) (g twoBranches)).faithful
#guard (compare (g twoBranches) (g twoBranches)).method == "refinement"
-- the same next messages everywhere, but the choice made at a different step: not faithful
#guard !(compare (g twoBranches) (g oneBranch)).faithful
#guard !(compare (g oneBranch) (g twoBranches)).faithful

end LeanFM.Session.FaithfulTests
