import LeanFM.Logic
import LeanFM.Session.Conform
import LeanFM.Session.Spec

/-!
# Properties stated in Lean are proved (clause selfhost.session.properties)

A `Spec` states temporal properties of its protocol. `Spec.check` decides every one of them over
the protocol's state graph (`Global.stateGraph`, the states conformance explores) with the same
CTL checker the `session_ctl` tool uses, so a property written in Lean and the same property asked
through MCP get the same answer and the same path. A property that is disproved is a finding with
its counterexample; one the protocol graph cannot decide (it names an event only the physics adds,
such as a timer, or the graph exceeds its bound) is a finding that says it was not checked. A
property is never reported as holding without being proved.

Assumptions such as fair delivery are stated on the spec but not yet used by the checker: a
property that needs one is reported disproved, with the path that breaks it.
-/

namespace LeanFM.Session
open Lean

namespace Prop'

/-- The formula as the logic tools read it. -/
def toJson : Prop' → Json
  | sent l => Json.mkObj [("after", Json.str l)]
  | terminal => Json.str "terminal"
  | not p => Json.mkObj [("not", toJson p)]
  | and p q => Json.mkObj [("and", Json.arr #[toJson p, toJson q])]
  | or p q => Json.mkObj [("or", Json.arr #[toJson p, toJson q])]
  | AG p => Json.mkObj [("AG", toJson p)]
  | AF p => Json.mkObj [("AF", toJson p)]
  | EF p => Json.mkObj [("EF", toJson p)]
  | EG p => Json.mkObj [("EG", toJson p)]
  | allUntil p q => Json.mkObj [("AU", Json.arr #[toJson p, toJson q])]
  | someUntil p q => Json.mkObj [("EU", Json.arr #[toJson p, toJson q])]

end Prop'

/-- The checker's bounds for a protocol's own state graph: Global.stateGraph already stopped at
Conform.graphMaxStates states, so the draft and its model may be as large as that graph. The public
check_ctl tool keeps its smaller bounds for drafts a client sends. -/
def sessionBounds : LeanFM.Logic.Bounds :=
  { maxDraftStates := Conform.graphMaxStates, maxDraftTransitions := 20 * Conform.graphMaxStates,
    maxModelNodes := 20 * Conform.graphMaxStates }

/-- A CTL formula (the logic tools' JSON) decided over an inline task (their draft form: states,
initial, terminals, transitions): the checker's answer, with `report` naming the path's messages in
order. -/
def checkDraft (name : String) (draft formula : Json) : Except String Json := do
  let answer <- LeanFM.Logic.checkCtl (Json.mkObj [("task", draft), ("formula", formula)]) sessionBounds
  let reading := (answer.getObjValAs? String "reading").toOption.getD ""
  -- the path in words: the messages in order, and where a lasso repeats
  let evidence := (answer.getObjVal? "evidence").toOption.getD Json.null
  let steps := match evidence.getObjVal? "path" with
    | .ok (.arr a) => a.toList.filterMap fun st => (st.getObjValAs? String "message").toOption
    | _ => []
  let kind := (evidence.getObjValAs? String "kind").toOption.getD "path"
  -- loopsBackTo indexes the path, whose first entry is the start state (no message)
  let loop := match (evidence.getObjValAs? Nat "loopsBackTo").toOption with
    | some 0 => " (then repeats from the start)"
    | some i => if i >= steps.length then " (and stays there)" else s!" (then repeats from {steps.getD i ""})"
    | none => ""
  let report := if steps.isEmpty then "" else s!"{kind}: {" -> ".intercalate steps}{loop}"
  return answer |>.setObjVal! "report" (Json.str report)
    |>.setObjVal! "reading" (Json.str s!"{name}: {reading}")

/-- One session of a protocol as the logic tools' inline task (their draft form): one transition per
step of Global.stateGraph, with its message, roles and the secret field paths `secretsOf` gives its
label (none unless asked: the secret atom is a question a project's tests ask, not a rule). -/
def Global.draft (g : Global String) (name : String) (secretsOf : String → List String := fun _ => []) :
    Except String (Json × Nat) := do
  let graph ← g.stateGraph
  let transition (e : String × String × Conform.NextStep) : Json :=
    let (a, b, n) := e
    let secrets := if n.isAct then [] else secretsOf n.label
    Json.mkObj ([("src", Json.str a), ("dst", Json.str b), ("message", Json.str n.label), ("from", Json.str n.src)] ++
      (if n.isAct then [] else [("to", Json.str n.dst)]) ++
      (if secrets.isEmpty then [] else [("secrets", Json.arr (secrets.map Json.str).toArray)]))
  let draft := Json.mkObj [("id", Json.str name), ("states", Json.arr (graph.states.map Json.str).toArray),
    ("initial", "s0"), ("terminals", Json.arr (graph.terminals.map Json.str).toArray),
    ("transitions", Json.arr (graph.edges.map transition).toArray)]
  return (draft, graph.states.length)

/-- A CTL formula (the logic tools' JSON) decided over one session of a protocol: the checker's
answer, with `report` naming the path's messages in order and `states` the graph's size. -/
def Global.checkFormula (g : Global String) (name : String) (formula : Json)
    (secretsOf : String → List String := fun _ => []) : Except String Json := do
  let (draft, states) ← g.draft name secretsOf
  let answer ← checkDraft name draft formula
  return answer.setObjVal! "states" (toJson states)

/-- Several formulas over one session, the state graph built once; each answer as checkFormula's,
or the error that formula gave. -/
def Global.checkFormulas (g : Global String) (name : String) (formulas : List Json)
    (secretsOf : String → List String := fun _ => []) : Except String (List (Except String Json)) := do
  let (draft, states) ← g.draft name secretsOf
  return formulas.map fun f => (checkDraft name draft f).map (·.setObjVal! "states" (toJson states))

namespace Spec
variable {R : Type} [DecidableEq R] [ToString R]

/-- Each property with its verdict: `proved`, `disproved` (with the path in `report`), or the reason
it was not checked. -/
def verdicts (s : Spec R) (name : String := "the protocol") : List (Prop' × String × String) :=
  let g := s.global.mapRoles toString
  s.properties.map fun p =>
    match g.checkFormula name p.toJson with
    | .ok a =>
      let verdict := (a.getObjValAs? String "verdict").toOption.getD "unknown"
      let reading := (a.getObjValAs? String "reading").toOption.getD ""
      let report := (a.getObjValAs? String "report").toOption.getD ""
      (p, verdict, if report.isEmpty then reading else s!"{reading}; {report}")
    | .error e => (p, "not checked", e)

/-- Everything wrong with the spec: the structural issues, and every property that is not proved. -/
def check (s : Spec R) (name : String := "the protocol") : List String :=
  s.issues ++ (s.verdicts name).filterMap fun (_, verdict, why) =>
    if verdict == "proved" then none
    else if verdict == "disproved" then some s!"property disproved: {why}"
    else some s!"property not checked ({verdict}): {why}"

end Spec
end LeanFM.Session
