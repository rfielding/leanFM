import LeanFM.SessionTools
import LeanFM.RunCheck

/-! # Requirements and implementations converted to CTL
(clauses selfhost.requirements.list, selfhost.requirements.map, selfhost.implementations.map;
decision requirement-maps)

The rule: an entry is an object of a kind that has a transform into CTL. A protocol converts to its
faithful rules, `P ⊨ φ` to φ over P, a hint to true (it claims no behaviour), and `sorry` is the entry
that does not convert yet. Evidence for a requirement is checked the same way: `conform` runs
session_conform on a log and judges a formula requirement on its runs (RunCheck), and a bare `test`
name is sorry, since it gives no run to judge. Every requirement has a standing, strongest first:
proved, tested, sorry, failing (selfhost.requirements.standing). This module is pure: the
files and logs are read by ProjectView, inside the project root.

Requirements this module is held to:
* positive (AG): every verdict comes from the session tools' own answers over the text of the file
  that defines the protocol, and carries the CTL the entry converted to.
* negative (never): met for a protocol entry whose protocol does not check or wrote no rules, for a
  formula entry whose verdict is not proved, or for a conform whose log does not conform; a sorry
  met or failing; a hint counted as evidence; proved from a run; tested from a test name alone or
  from a log that does not conform. -/

namespace LeanFM.RequirementCtl
open Lean LeanFM.Session

/-- What an entry converts to: CTL formulas over one named protocol (at most `shownRules` shown). -/
structure Compiled where
  name : String
  ruleCount : Nat
  formulas : List (String × String)

def shownRules : Nat := 3

def Compiled.toJson (c : Compiled) : Json :=
  Json.mkObj [("protocol", Json.str c.name), ("ruleCount", c.ruleCount),
    ("formulas", Json.arr (c.formulas.toArray.map fun (n, f) => Json.mkObj [("name", Json.str n), ("formula", Json.str f)]))]

/-- A checked entry. `met`: its CTL holds or its evidence passes; `sorry`: it does not convert yet;
`failing`: an error (disproved, does not conform, refused); none of them for a hint. -/
structure Checked where
  verdict : String
  met : Bool := false
  usesSorry : Bool := false
  failing : Bool := false
  reading : String
  ctl : Option Compiled := none

/-- The standing an entry's check gives (selfhost.requirements.standing): a run that conforms or
meets its formula is tested, any other met entry proved; a hint has none. -/
def Checked.standing (c : Checked) : String :=
  if c.failing then "failing"
  else if c.met && (c.verdict == "tested" || c.verdict == "conforms") then "tested"
  else if c.met then "proved"
  else if c.verdict == "true" then "hint"
  else "sorry"

def Checked.toFields (c : Checked) : List (String × Json) :=
  [("verdict", Json.str c.verdict), ("standing", Json.str c.standing), ("met", toJson c.met), ("sorry", toJson c.usesSorry), ("failing", toJson c.failing),
   ("reading", Json.str c.reading), ("ctl", match c.ctl with | some x => x.toJson | none => Json.null)]

def failed (why : String) : Checked := { verdict := "error", failing := true, reading := why }

def sorryChecked (note : String) : Checked :=
  { verdict := "sorry", usesSorry := true,
    reading := "uses sorry: does not convert to CTL yet" ++ (if note.isEmpty then "" else s!" ({note})") }

def hintChecked : Checked :=
  { verdict := "true", reading := "a hint for the code: it claims no behaviour, so it converts to true" }

def get (a : Json) (k : String) : String := (a.getObjValAs? String k).toOption.getD ""

/-- The protocol a pointer names, if any. -/
def pointerProtocol : Text.Pointer → Option String
  | .protocol n | .formula n _ => some n | .sorry_ _ => none

/-- Convert a pointer to CTL and decide it, given the text of the file that defines its protocol. -/
def checkPointer (text : String) : Text.Pointer → Checked
  | .sorry_ note => sorryChecked note
  | .protocol n =>
    match Text.textThrough text n with
    | .error e => failed e
    | .ok t =>
      match LeanFM.SessionTools.ctl (Json.mkObj [("lean", Json.str t), ("faithful", "rules")]),
            LeanFM.SessionTools.check (Json.mkObj [("lean", Json.str t)]) with
      | .error e, _ | _, .error e => failed e
      | .ok r, .ok c =>
        let rules := ((r.getObjValD "rules").getArr?).toOption.getD #[]
        let count := (r.getObjValAs? Nat "ruleCount").toOption.getD rules.size
        let shown := (rules.toList.take shownRules).map fun x => (get x "name", get x "formula")
        let compiled : Compiled := { name := n, ruleCount := count, formulas := shown }
        let ok := get c "verdict" == "ok" && count > 0
        { verdict := get c "verdict", met := ok, failing := !ok, ctl := some compiled,
          reading := s!"{n}: {count} faithful CTL rules; session_check: {get c "verdict"}" }
  | .formula n φ =>
    match Text.textThrough text n with
    | .error e => failed e
    | .ok t =>
      let compiled : Compiled := { name := n, ruleCount := 1, formulas := [("formula", φ)] }
      match LeanFM.SessionTools.ctl (Json.mkObj [("lean", Json.str t), ("formula", Json.str φ)]) with
      | .error e => { failed e with ctl := some compiled }
      | .ok a =>
        let v := get a "verdict"
        { verdict := v, met := v == "proved", failing := v != "proved", reading := get a "reading", ctl := some compiled }

/-- The sessions of a session_conform answer, each one's labels in log order and whether it is complete. -/
def runsOf (answer : Json) : List RunCheck.Run :=
  let evs := ((answer.getObjValD "events").getArr?).toOption.getD #[]
  let sessions := ((answer.getObjValD "sessions").getArr?).toOption.getD #[]
  let ids := (evs.toList.map (get · "session")).eraseDups
  ids.map fun sid =>
    let mine := evs.filter fun e => get e "session" == sid && (e.getObjValD "act") != Json.bool true
    let complete := (sessions.find? (get · "session" == sid)).any fun x => (x.getObjValD "complete") == Json.bool true
    { labels := mine.map (get · "label"), complete }

/-- The ids of the first `k` events of session `i` of a conform answer. -/
def prefixIds (answer : Json) (i k : Nat) : List String :=
  let evs := ((answer.getObjValD "events").getArr?).toOption.getD #[]
  let ids := (evs.toList.map (get · "session")).eraseDups
  match ids[i]? with
  | none => []
  | some sid => ((evs.toList.filter fun e => get e "session" == sid && (e.getObjValD "act") != Json.bool true).take k).map (get · "logId")

/-- Judge a formula on a conforming log's runs: tested, pending (not shown yet) or refuted. -/
def judgeRuns (n φ : String) (answer : Json) : Checked :=
  let compiled : Compiled := { name := n, ruleCount := 1, formulas := [("formula", φ)] }
  match LeanFM.Logic.parseSexpr φ with
  | .error e => { failed e with ctl := some compiled }
  | .ok f =>
    let runs := runsOf answer
    match RunCheck.judge f runs with
    | .error e => { sorryChecked e with verdict := "unjudged", ctl := some compiled }
    | .ok j =>
      let base := s!"{runs.length} session{if runs.length == 1 then "" else "s"} of the run conform to {n}; the formula is {j.value.name} on them"
      let weak := if j.untriggered.isEmpty then "" else
        "; tested only vacuously for " ++ ", ".intercalate (j.untriggered.map fun a => a.toJson.compress) ++ ", which no run makes happen"
      match j.value with
      | .true_ | .presumablyTrue =>
        { verdict := "tested", met := true, ctl := some compiled, reading := base ++ weak }
      | .presumablyFalse =>
        let open_ := (j.parts.filter (·.2 == .presumablyFalse)).map fun (c, _) => c.toJson.compress
        { verdict := "pending", usesSorry := true, ctl := some compiled,
          reading := base ++ "; not shown yet: " ++ ", ".intercalate open_ }
      | .false_ =>
        let cx := match j.counterexample with
          | some (i, k) => s!"; counterexample: the first {k} event{if k == 1 then "" else "s"} of session {i + 1} (" ++ ", ".intercalate (prefixIds answer i k) ++ ")"
          | none => ""
        { verdict := "refuted", failing := true, ctl := some compiled, reading := base ++ cx }

/-- `conform "log"`: the log's events checked by session_conform against the requirement's protocol,
and a formula requirement judged on the log's runs. -/
def checkConform (text : String) (req : Text.Pointer) (events : Except String Json) : Checked :=
  match pointerProtocol req, events with
  | none, _ => failed "conform needs a requirement that names a protocol; this one uses sorry"
  | _, .error e => failed e
  | some n, .ok evs =>
    match Text.textThrough text n with
    | .error e => failed e
    | .ok t =>
      match LeanFM.SessionTools.conform (Json.mkObj [("lean", Json.str t), ("events", evs)]) with
      | .error e => failed e
      | .ok a =>
        let v := get a "verdict"
        if v != "conforms" then
          { verdict := v, failing := true, reading := s!"session_conform against {n}: {v}: {get a "reading"}" }
        else match req with
          | .formula _ φ => judgeRuns n φ a
          | _ => { verdict := "conforms", met := true,
                   reading := s!"session_conform against {n}: conforms; the protocol's always properties hold on this run" }

/-- A named test with no run: sorry, since only a run judged against the requirement counts as tested. -/
def testChecked (name : String) : Checked :=
  { verdict := "sorry", usesSorry := true,
    reading := s!"names test {name} but gives no run to judge; give the run's log with conform" }

/-- The standing of one requirement in one implementation, strongest first: proved (its CTL holds
over the protocol and its run conforms), tested (a conforming run meets it), sorry, failing. -/
def status (req : Checked) (ev : Option Checked) : String :=
  let evPasses := (ev.map (·.met)).getD false
  let evFails := (ev.map (·.failing)).getD false
  if req.failing || evFails then "failing"
  else if req.met && evPasses then "proved"
  else if evPasses then "tested"
  else "sorry"

/-- The standings, strongest first. -/
def standings : List String := ["proved", "tested", "sorry", "failing"]

end LeanFM.RequirementCtl
