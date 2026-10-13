import LeanFM.Artifacts

namespace NestedRace
open LeanFM
structure Event where
  id : String
  prior : List String
  ms : Nat
  label : String
  x : String
  y : String
  requiredCount : Nat := 0
  branchCount : Nat := 0
  selectedTerminals : List String := []
deriving Repr
def events : List Event :=
  [ {id := "e0", prior := [], ms := 0, label := "Search started", x := "0", y := "0"}
  , {id := "e1", prior := ["e0"], ms := 1, label := "Race started", x := "-2", y := "-1.3"}
  , {id := "e2", prior := ["e0"], ms := 1, label := "Audit started", x := "3", y := "-1.3"}
  , {id := "e3", prior := ["e1"], ms := 2, label := "Job A started", x := "-4", y := "-2.7"}
  , {id := "e4", prior := ["e1"], ms := 2, label := "Job B started", x := "-1.5", y := "-2.7"}
  , {id := "e5", prior := ["e1"], ms := 2, label := "Job C started", x := "1", y := "-2.7"}
  , {id := "e6", prior := ["e2"], ms := 8, label := "Audit completed", x := "3", y := "-5.1"}
  , {id := "e7", prior := ["e3"], ms := 10, label := "A result accepted", x := "-4", y := "-4.1"}
  , {id := "e8", prior := ["e1", "e7"], ms := 11, label := "Choose A: 1 of 3", x := "-2", y := "-5.5", requiredCount := 1, branchCount := 3, selectedTerminals := ["e7"]}
  , {id := "e9", prior := ["e8", "e4"], ms := 11, label := "Cancel B requested", x := "-4", y := "-7"}
  , {id := "e10", prior := ["e8", "e5"], ms := 11, label := "Cancel C requested", x := "1", y := "-7"}
  , {id := "e11", prior := ["e0", "e8", "e6"], ms := 12, label := "Reply: race + audit", x := "3.5", y := "-7", requiredCount := 2, branchCount := 2, selectedTerminals := ["e8", "e6"]}
  , {id := "e12", prior := ["e9", "e4"], ms := 15, label := "B cancelled", x := "-4", y := "-8.5"}
  , {id := "e13", prior := ["e10", "e5"], ms := 17, label := "C cancelled", x := "1", y := "-8.5"}
  , {id := "e14", prior := ["e11", "e12", "e13"], ms := 18, label := "Cleanup joined", x := "-1", y := "-10"} ]
def output : DesiredOutput :=
  {id := "events.nested_race", prompt := "Show nested fork/join with first-result choice and cancellation in section 2.1.",
   question := "Which predecessors permit choosing, replying and reclaiming losing tasks?", kind := .interactionDiagram,
   eventSource := "NestedForkJoinExample.lean synthetic timestamped event DAG", reducer := "render transitively reduced predecessor edges; retain full backpointers and threshold metadata in provenance",
   unit := "events and synthetic milliseconds; illustrative search-style race, not a Google implementation claim"}
def ordered : List String → List Event → Bool
  | _, [] => true
  | seen, e :: rest => !seen.contains e.id && e.prior.all seen.contains && ordered (e.id :: seen) rest
example : ordered [] events = true := by native_decide
example : events.all (fun e => e.selectedTerminals.length == e.requiredCount && e.requiredCount <= e.branchCount && e.selectedTerminals.all e.prior.contains) = true := by native_decide
example : (events.find? (·.id == "e8")).map (·.prior) = some ["e1", "e7"] := by native_decide
example : ((events.find? (·.id == "e11")).map (·.ms)).getD 0 < ((events.find? (·.id == "e13")).map (·.ms)).getD 0 := by native_decide
def reaches : Nat → String → String → Bool
  | 0, _, _ => false
  | fuel+1, fromId, target =>
    fromId == target || match events.find? (·.id == fromId) with
      | none => false
      | some e => e.prior.any (fun p => reaches fuel p target)
def minimalPriors (e : Event) : List String :=
  e.prior.filter fun p => !(e.prior.any fun q => q != p && reaches events.length q p)
example : events.all (fun e => e.prior.all (fun p => (minimalPriors e).any (fun q => reaches events.length q p))) = true := by native_decide
def edge (e : Event) (p : String) : String :=
  if e.id == "e9" && p == "e4" then
    "\\draw[prior] (e9.west) -- (-5.5,-7) -- (-5.5,-3.35) -| (e4.south);\n"
  else if e.id == "e14" && p == "e11" then
    "\\draw[prior] (e14.east) -- (5.2,-10) -- (5.2,-7) -- (e11.east);\n"
  else "\\draw[prior] (" ++ e.id ++ ") -- (" ++ p ++ ");\n"
def drawing : String :=
  "% Generated from NestedForkJoinExample.lean; DesiredOutput events.nested_race.\n" ++
  "\\begin{tikzpicture}[event/.style={draw=diagramink,text=diagramink,rounded corners,fill=diagramsurface,align=center,font=\\scriptsize,text width=2.1cm,minimum height=.65cm},prior/.style={->,>=Stealth,draw=leanblue,thin}]\n" ++
  String.join (events.map fun e => "\\node[event] (" ++ e.id ++ ") at (" ++ e.x ++ "," ++ e.y ++ ") {" ++ e.id ++ ": " ++ e.label ++ "};\n") ++
  String.join (events.map fun e => String.join ((minimalPriors e).map (edge e))) ++ "\\end{tikzpicture}\n"
def tlaOutput : DesiredOutput :=
  { id := "tla.state_space", prompt := "Show how irrelevant internal state increases exploration time and space in an actual TLA+ queue example.",
    question := "How many distinct states does TLC enumerate with the same order protocol and varying irrelevant-state bounds?",
    kind := .scalar, eventSource := "TLC 1.7.4 exhaustive finite safety-check logs for OrderQueue.tla and four configurations",
    reducer := "parse distinct-state counts and verify independent cache/clock product factors",
    unit := "distinct model states; one client, one server, two orders, FIFO capacity two; not runtime memory or liveness" }
end NestedRace
def main : IO Unit := do
  IO.FS.writeFile "book/generated/nested-race.tex" NestedRace.drawing
  IO.FS.writeFile "book/generated/nested-race-provenance.txt" (reprStr NestedRace.output ++ "\n" ++ reprStr NestedRace.events ++ "\n")
  IO.FS.writeFile "book/generated/tla-state-space-provenance.txt" (reprStr NestedRace.tlaOutput ++ "\n")
  IO.println "ok: nested race event identity, predecessor order and reply-before-cleanup example"
