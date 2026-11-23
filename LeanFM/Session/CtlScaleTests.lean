import LeanFM.Logic
import LeanFM.Session.SpecCheck

/-! Tests for selfhost.session.ctl-scale (decision session-ctl-scale) and selfhost.session.ctl-sexpr
(decision session-ctl-sexpr): the shared evaluation gives the fixpoint evaluation's answer on every
operator, a formula far larger as a tree than as a DAG is checked as its DAG, the caller's bounds
apply, and s-expressions read as the JSON form does. Built with the library, so `lake build` runs
every `#guard`. -/

namespace LeanFM.Session.CtlScaleTests
open Lean LeanFM.Logic

def parse! (s : String) : Json := (Json.parse s).toOption.getD Json.null

/-- A draft with a loop, a choice, an ending and a state with no step (a deadlock). -/
def loopy : String := "{\"id\": \"loopy\", \"states\": [\"s0\", \"s1\", \"s2\", \"s3\", \"s4\"], \"initial\": \"s0\", \"terminals\": [\"s3\"],
  \"transitions\": [{\"src\": \"s0\", \"dst\": \"s1\", \"message\": \"a\"}, {\"src\": \"s1\", \"dst\": \"s0\", \"message\": \"b\"},
  {\"src\": \"s1\", \"dst\": \"s2\", \"message\": \"c\"}, {\"src\": \"s2\", \"dst\": \"s3\", \"message\": \"d\"},
  {\"src\": \"s2\", \"dst\": \"s1\", \"message\": \"a\"}, {\"src\": \"s0\", \"dst\": \"s4\", \"message\": \"e\"}]}"

def models : List Model :=
  ([loopy].filterMap fun d => match parseDraft (parse! d) with
    | .ok t => buildModel t
    | .error _ => none)
  ++ (canonicalTasks.filterMap fun t => buildModel (ofRequirement t))

/-- Every formula of depth at most two over these atoms and every operator. -/
def atoms : List Formula := [.after "a", .after "c", .terminal, .tt]
def ops1 : List (Formula → Formula) := [.not, .never, .ex, .ax, .ef, .af, .eg, .ag]
def ops2 : List (Formula → Formula → Formula) := [.implies, .stronglyImplies, .eu, .au, .ew, .aw,
  fun a b => .and [a, b], fun a b => .or [a, b]]
def level1 : List Formula := atoms ++ ops1.flatMap (fun o => atoms.map o) ++ ops2.flatMap (fun o => atoms.flatMap fun a => atoms.map (o a))
def level2 : List Formula := ops1.flatMap (fun o => level1.map o) ++ ops2.flatMap (fun o => (level1.take 12).flatMap fun a => (level1.take 12).map (o a))

-- the shared evaluation gives the fixpoint evaluation's answer at every node, on every operator
#guard models.length ≥ 3
#guard models.all fun m => level2.all fun f => Model.sat m f == Model.satTree m f

-- a formula of about 2^26 nodes as a tree and 76 as a DAG: built with its parts shared, it is checked as
-- its DAG, and its answer writes it as an s-expression with labels, never as the tree
def doubling : Nat → Formula
  | 0 => .after "a"
  | k + 1 => let f := doubling k; .or [.ex f, .ax f]
#guard (Dag.ofFormula (doubling 25)).size == 76
#guard (Dag.ofFormula (doubling 25)).treeSize 1000000 == 1000000
#guard match models.head? with
  | some m => (Model.satE m (doubling 25)).isOk
  | none => false
def bigCheck : ToolOutcome :=
  checkCtl (Json.mkObj [("task", parse! loopy), ("formula", Json.str (Dag.ofFormula (doubling 25)).toSexpr)])
    { bounds with maxFormulaNodes := 1000 }
#guard match bigCheck with
  | .ok j => (j.getObjValAs? String "verdict").toOption != some "rejected" &&
      ((j.getObjValAs? String "formula").toOption.getD "").startsWith "(or (EX #0="
  | .error _ => false

-- the caller's bounds apply: the distinct-subformula bound, the tree bound and the truth-set bound
#guard (parseShared (Json.str (Dag.ofFormula (doubling 25)).toSexpr) { bounds with maxFormulaNodes := 75 }).toOption.isNone
#guard (parseShared (Json.str (Dag.ofFormula (doubling 25)).toSexpr) { bounds with maxFormulaNodes := 76 }).toOption.isSome
#guard (parseBounded (parse! "{\"AG\": {\"EF\": \"terminal\"}}") { bounds with maxFormulaNodes := 2 }).toOption.isNone
#guard (parseBounded (parse! "{\"AG\": {\"EF\": \"terminal\"}}")).toOption.isSome
#guard (parseFormula (parse! "{\"AG\": {\"AG\": {\"AG\": \"terminal\"}}}") 0 { bounds with maxDepth := 2 }).toOption.isNone
#guard match models.head? with
  | some m => match Model.satE m (doubling 3) { bounds with maxTruthBytes := 2 } with
    | .error e => (e.splitOn "nothing was proved").length > 1
    | .ok _ => false
  | none => false
#guard match checkCtl (Json.mkObj [("task", parse! loopy), ("formula", parse! "{\"AG\": {\"EF\": \"terminal\"}}")]) { bounds with maxTruthBytes := 1 } with
  | .ok j => (j.getObjValAs? String "verdict").toOption == some "resource-limit"
  | .error _ => false

-- equal subformulas are one node, different ones two, however they were built
#guard (Dag.ofFormula (.and [.after "a", .after "a"])).size == 2
#guard (Dag.ofFormula (.and [.after "a", .after "b"])).size == 3
#guard (Dag.ofFormula (.or [.ex (.after "a"), .ax (.after "a"), .ex (.after "a")])).size == 4

/-! ## S-expressions -/

def same (s j : String) : Bool :=
  match parseFormula (Json.str s), parseFormula (parse! j) with
  | .ok a, .ok b => a == b
  | _, _ => false

#guard same "(AG (implies (after Ping) (AX (or (after Pong) (after SlowPong)))))"
  "{\"AG\": {\"implies\": [{\"after\": \"Ping\"}, {\"AX\": {\"or\": [{\"after\": \"Pong\"}, {\"after\": \"SlowPong\"}]}}]}}"
#guard same "(not (EU (not (after Charge)) (after Refund)))" "{\"not\": {\"EU\": [{\"not\": {\"after\": \"Charge\"}}, {\"after\": \"Refund\"}]}}"
#guard same "(AG (not (secret to Log)))" "{\"AG\": {\"not\": {\"secret\": {\"to\": \"Log\"}}}}"
#guard same "(and terminal true false (at s1) (claimed \"commit(B, A)\"))"
  "{\"and\": [\"terminal\", true, false, {\"at\": \"s1\"}, {\"claimed\": \"commit(B, A)\"}]}"
#guard same "(K terminal)" "{\"K\": \"terminal\"}"
-- a label writes a shared part once; the formula is the one with that part written out
#guard same "(and #1=(EF (after a)) (AG #1#))" "{\"and\": [{\"EF\": {\"after\": \"a\"}}, {\"AG\": {\"EF\": {\"after\": \"a\"}}}]}"
-- what the reader refuses: an undefined label, a label defined twice, a cycle, any other # form,
-- an unknown character, structure it does not carry, and the bounds
def refused (s : String) (b : Bounds := bounds) : Bool := (parseFormula (Json.str s) 0 b).toOption.isNone
#guard refused "(AG #1#)"
#guard refused "(and #1=terminal #1=true)"
#guard refused "#1=(and #1# terminal)"
#guard refused "(AG #.(launch))"
#guard refused "(AG [x])"
#guard refused "(knows A k)"
#guard refused "(AG (after))"
#guard refused "(AG terminal) (EF terminal)"
#guard refused "(AG (AG (AG terminal)))" { bounds with maxDepth := 2 }
-- the bound counts distinct subformulas: a repeated part, labelled or not, counts once
#guard (parseShared (Json.str "(and (after a) (after b) (after c))") { bounds with maxFormulaNodes := 3 }).toOption.isNone
#guard (parseShared (Json.str "(and #1=(EF terminal) #1# #1# (EF terminal))") { bounds with maxFormulaNodes := 3 }).toOption.isSome
#guard (parseBounded (Json.str "(and #1=(EF terminal) #1# #1#)") { bounds with maxFormulaNodes := 6 }).toOption.isNone
-- written back as an s-expression, a formula reads as itself
#guard [doubling 6, .ag (.implies (.after "x y") (.au (.not .terminal) (.secret (some "A") none (some "pw_secr"))))].all fun f =>
  (parseFormula (Json.str (Dag.ofFormula f).toSexpr)).toOption == some f
-- the same verdict and path for the JSON and the s-expression form
def verdictPath (formula : Json) : Option (String × String) :=
  match checkCtl (Json.mkObj [("task", parse! loopy), ("formula", formula)]) with
  | .ok j => some ((j.getObjValAs? String "verdict").toOption.getD "", ((j.getObjValD "evidence").getObjValD "path").compress)
  | .error _ => none
#guard verdictPath (Json.str "(AG (EF terminal))") == verdictPath (parse! "{\"AG\": {\"EF\": \"terminal\"}}")
#guard verdictPath (Json.str "(AF (after d))") == verdictPath (parse! "{\"AF\": {\"after\": \"d\"}}")
#guard (verdictPath (Json.str "(AG (EF terminal))")).map (·.1) == some "disproved"

end LeanFM.Session.CtlScaleTests
