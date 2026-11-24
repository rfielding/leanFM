import LeanFM.SessionTools

/-! # Requirements and implementations converted to CTL
(clauses selfhost.requirements.list, selfhost.requirements.map, selfhost.implementations.map;
decision requirement-maps)

The rule: an entry is an object of a kind that has a transform into CTL. A protocol converts to its
faithful rules, `P ⊨ φ` to φ over P, a hint to true (it claims no behaviour), and `sorry` is the entry
that does not convert yet. Evidence for a requirement is checked the same way: `conform` runs
session_conform on a log, `test` names a test the project's checks run. This module is pure: the
files and logs are read by ProjectView, inside the project root.

Requirements this module is held to:
* positive (AG): every verdict comes from the session tools' own answers over the text of the file
  that defines the protocol, and carries the CTL the entry converted to.
* negative (never): met for a protocol entry whose protocol does not check or wrote no rules, for a
  formula entry whose verdict is not proved, or for a conform whose log does not conform; a sorry
  met or failing; a hint counted as evidence. -/

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

def Checked.toFields (c : Checked) : List (String × Json) :=
  [("verdict", Json.str c.verdict), ("met", toJson c.met), ("sorry", toJson c.usesSorry), ("failing", toJson c.failing),
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

/-- `conform "log"`: the log's events checked by session_conform against the requirement's protocol. -/
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
        { verdict := v, met := v == "conforms", failing := v != "conforms",
          reading := s!"session_conform against {n}: {v}; the protocol's AG properties hold on this run (AF and EF also need covering guards)" }

def testChecked (name : String) : Checked :=
  { verdict := "tested", met := true,
    reading := s!"test {name}: the project's checks run it (counted as tested, not as CTL)" }

/-- The status of one requirement in one implementation, computed from the two verdicts. -/
def status (req : Checked) (ev : Option Checked) : String :=
  let evPasses := (ev.map (·.met)).getD false
  let evFails := (ev.map (·.failing)).getD false
  if req.failing || evFails then "failing"
  else if req.met && evPasses then "met"
  else if req.met then "specified"
  else if evPasses then "tested"
  else "sorry"

end LeanFM.RequirementCtl
