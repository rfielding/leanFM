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
  else if c.met && c.verdict == "proof" then "proved"
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

/-- The runs of a session_conform answer: a session nested in another (one of its events links, by
prior or cause, to an event of an earlier session) is part of that session's run, so a run is a root
session with its descendants, in log order; complete when its root is. Answers each run's root
session and its events. -/
def runGroups (answer : Json) (logged : Array Json := #[]) : List (String × Array Json) :=
  let evs := (((answer.getObjValD "events").getArr?).toOption.getD #[]).filter fun e => (e.getObjValD "act") != Json.bool true
  -- each logged event's session (as the answer places it), and the ids its prev and cause name
  let sessionOf (id : String) : Option String := (evs.find? (get · "logId" == id)).map (get · "session")
  let ids (j : Json) : List String := match j with
    | .str x => [x] | .arr a => a.toList.filterMap (·.getStr?.toOption) | _ => []
  let links (e : Json) : List String :=
    match logged.find? (fun l => get l "id" == get e "logId") with
    | some l => ids (l.getObjValD "prev") ++ ids (l.getObjValD "cause")
    | none => []
  let order := (evs.toList.map (get · "session")).eraseDups
  let parent (s : String) : Option String :=
    let mine := evs.toList.filter (get · "session" == s)
    let earlier := order.takeWhile (· != s)
    mine.findSome? fun e => (links e).findSome? fun i => (sessionOf i).filter fun t => t != s && earlier.contains t
  let rec root (s : String) (fuel : Nat) : String :=
    match fuel, parent s with
    | 0, _ | _, none => s
    | f + 1, some t => root t f
  let roots := (order.map fun s => root s order.length).eraseDups
  roots.map fun r => (r, evs.filter fun e => root (get e "session") order.length == r)

/-- The runs of a session_conform answer, each one's labels in log order and whether it is complete. -/
def runsOf (answer : Json) (logged : Array Json := #[]) : List RunCheck.Run :=
  let sessions := ((answer.getObjValD "sessions").getArr?).toOption.getD #[]
  (runGroups answer logged).map fun (r, es) =>
    let complete := (sessions.find? (get · "session" == r)).any fun x => (x.getObjValD "complete") == Json.bool true
    { labels := es.map (get · "label"), complete }

/-- The ids of the first `k` events of run `i` of a conform answer. -/
def prefixIds (answer : Json) (i k : Nat) (logged : Array Json := #[]) : List String :=
  match (runGroups answer logged)[i]? with
  | none => []
  | some (_, es) => (es.toList.take k).map (get · "logId")

/-- Judge a formula on a conforming log's runs: tested, pending (not shown yet) or refuted. -/
def judgeRuns (n φ : String) (answer : Json) (logged : Array Json := #[]) : Checked :=
  let compiled : Compiled := { name := n, ruleCount := 1, formulas := [("formula", φ)] }
  match LeanFM.Logic.parseSexpr φ with
  | .error e => { failed e with ctl := some compiled }
  | .ok f =>
    let runs := runsOf answer logged
    match RunCheck.judge f runs with
    | .error e => { sorryChecked e with verdict := "unjudged", ctl := some compiled }
    | .ok j =>
      let base := s!"{runs.length} run{if runs.length == 1 then "" else "s"} of the log conform to {n}; the formula is {j.value.name} on them"
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
          | some (i, k) => s!"; counterexample: the first {k} event{if k == 1 then "" else "s"} of run {i + 1} (" ++ ", ".intercalate (prefixIds answer i k logged) ++ ")"
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
      -- a session still running conforms as far as it goes; its end is judged by RunCheck (selfhost.requirements.standing)
      match LeanFM.SessionTools.conform (Json.mkObj [("lean", Json.str t), ("events", evs), ("allowIncomplete", true)]) with
      | .error e => failed e
      | .ok a =>
        let v := get a "verdict"
        if v != "conforms" then
          { verdict := v, failing := true, reading := s!"session_conform against {n}: {v}: {get a "reading"}" }
        else match req with
          | .formula _ φ => judgeRuns n φ a ((evs.getArr?).toOption.getD #[])
          | _ => { verdict := "conforms", met := true,
                   reading := s!"session_conform against {n}: conforms; the protocol's always properties hold on this run" }

/-- `proof "Name"` (selfhost.requirements.proofs): judged from proofs.json, which the build writes by
checking each theorem with Lean's kernel. The server never compiles or runs the theorem. -/
def proofChecked (name : String) (proofs : Option Json) : Checked :=
  match proofs with
  | none => { verdict := "sorry", usesSorry := true, reading := s!"proof {name}: the proofs were not checked (no proofs.json beside the implementation; make selfhost-check writes it)" }
  | some j =>
    match j.getObjVal? name with
    | .error _ => { verdict := "sorry", usesSorry := true, reading := s!"proof {name}: proofs.json has no line for it; make selfhost-check checks it" }
    | .ok line =>
      let exists_ := (line.getObjValD "exists") == Json.bool true
      let free := (line.getObjValD "sorryFree") == Json.bool true
      let axioms := ((line.getObjValD "axioms").getArr?).toOption.getD #[] |>.toList.filterMap (·.getStr?.toOption)
      if !exists_ then failed s!"proof {name}: no such theorem in LeanFM.Proofs"
      else if !free then failed s!"proof {name} rests on sorry (its axioms: {", ".intercalate axioms})"
      else { verdict := "proof", met := true,
             reading := s!"proof {name}: checked by Lean's kernel, free of sorry; its axioms: {if axioms.isEmpty then "none" else ", ".intercalate axioms}" }

/-- Pure evidence (selfhost.requirements.proofs): ProofCheck.lean's walk of what the function can reach,
read from proofs.json under `pure Name`. -/
def pureChecked (name : String) (proofs : Option Json) (kind : String := "pure") : Checked :=
  let what := if kind == "pure" then "take none of Lean's ways out of purity (no IO in a type, nothing unsafe, extern or implemented outside LeanFM)"
    else "write nothing: no file or directory written, created, renamed or removed, no permission changed, no process run, no file opened but to read"
  match proofs with
  | none => { verdict := "sorry", usesSorry := true, reading := s!"{kind} {name}: not checked (no proofs.json beside the implementation; make selfhost-check writes it)" }
  | some j =>
    match j.getObjVal? s!"{kind} {name}" with
    | .error _ => { verdict := "sorry", usesSorry := true, reading := s!"{kind} {name}: proofs.json has no line for it; make selfhost-check checks it" }
    | .ok line =>
      let strs (k : String) := ((line.getObjValD k).getArr?).toOption.getD #[] |>.toList.filterMap (·.getStr?.toOption)
      let reached := (line.getObjValD "reached").getNat?.toOption.getD 0
      if (line.getObjValD "exists") != Json.bool true then failed s!"{kind} {name}: no such function in the built environment"
      else if !(strs "problems").isEmpty then failed s!"{kind} {name}: {"; ".intercalate (strs "problems")}"
      else { verdict := "proof", met := true,
             reading := s!"{kind} {name}: the {reached} LeanFM definitions it can reach {what}" ++
               (if (strs "exceptions").isEmpty then "" else s!"; declared exceptions: {"; ".intercalate (strs "exceptions")}") }

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
  -- a theorem states the requirement, so passing proof evidence is proved whatever the requirement
  else if evPasses && (ev.map (·.verdict)) == some "proof" then "proved"
  else if req.met && evPasses then "proved"
  else if evPasses then "tested"
  else "sorry"

/-- The standings, strongest first. -/
def standings : List String := ["proved", "tested", "sorry", "failing"]

end LeanFM.RequirementCtl
