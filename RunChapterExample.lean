import LeanFM.Reduce
import LeanFM.RunCheck
import LeanFM.RequirementCtl
import LeanFM.LLMGenerated.Hazards

/-! Generates the book's run and reducer outputs: reduce_run over the shop's run
    (book/examples/shop.reduce over book/examples/shop-run.json), the judgement of three
    requirements on runs (RunCheck, the function checkConform calls), and the hazard registry.
    Everything printed is what the tools answer. Run from the LeanFM root:
    `lake env lean --run RunChapterExample.lean`. -/

namespace RunChapterExample
open Lean LeanFM.Reduce LeanFM.RunCheck

def out (name text : String) : IO Unit := IO.FS.writeFile s!"book/generated/{name}" text

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\footnotesize,breaklines=true]\n" ++ body ++ "\n\\end{lstlisting}\n"

def texEsc (s : String) : String :=
  s.replace "\\" "\\textbackslash{}" |>.replace "_" "\\_" |>.replace "&" "\\&" |>.replace "%" "\\%" |>.replace "#" "\\#"

partial def show_ (j : Json) : String :=
  match j.getObjValAs? String "exact" with
  | .ok e => e
  | .error _ => match j with
    | .arr a => "(" ++ " ".intercalate (a.toList.map show_) ++ ")"
    | .str s => s
    | j => j.compress

def run (labels : List String) (complete : Bool) : Run := { labels := labels.toArray, complete }

def judged (name formula : String) (runs : List (String × Run)) : String := Id.run do
  let f := match LeanFM.Logic.parseSexpr formula with | .ok x => x | .error _ => .ff
  let mut lines : Array String := #[s!"{name}: {formula}"]
  for (what, r) in runs do
    match judge f [r] with
    | .error e => lines := lines.push s!"  {what}: refused: {e}"
    | .ok j =>
      let cx := match j.counterexample with
        | some (_, k) => s!"; counterexample: the first {k} events ({", ".intercalate (r.labels.toList.take k)})"
        | none => ""
      let vac := if j.untriggered.isEmpty then "" else "; its trigger never happened"
      let standing := match j.value with
        | .true_ | .presumablyTrue => "tested" | .presumablyFalse => "not shown yet" | .false_ => "failing"
      lines := lines.push s!"  {what} [{", ".intercalate r.labels.toList}{if r.complete then "; complete" else "; running"}]: {j.value.name}, {standing}{cx}{vac}"
  return "\n".intercalate lines.toList

def main : IO Unit := do
  let program ← IO.FS.readFile "book/examples/shop.reduce"
  let events ← IO.ofExcept (Json.parse (← IO.FS.readFile "book/examples/shop-run.json"))
  for theme in ["light", "dark"] do
    let a ← IO.ofExcept (check (Json.mkObj [("program", Json.str program), ("events", events), ("theme", Json.str theme)]))
    let outs := ((a.getObjValD "outputs").getArr?.toOption.getD #[]).toList
    if theme == "light" then
      let shown := outs.filter fun o => (o.getObjValD "value").getObjValD "kind" == Json.null
      let lines := shown.map fun o => s!"{(o.getObjValAs? String "form").toOption.getD ""}  =>  {show_ (o.getObjValD "value")}"
      out "run-shop-outputs.tex" (listing ("\n".intercalate lines ++ s!"\n\nreduce_run: {(a.getObjValAs? String "reading").toOption.getD ""}"))
    for o in outs do
      if let .ok svg := o.getObjValAs? String "svg" then out s!"run-shop-pie-{theme}.svg" svg
  let feature := judged "a feature" "(stronglyImplies (on Call) (inevitably (on Answer)))"
    [("no Call", run ["Hello"] true), ("answered", run ["Call", "Answer"] true),
     ("unanswered", run ["Hello", "Call", "Bye"] true), ("still running", run ["Call"] false)]
  let guard := judged "a guarantee" "(weaklyImplies (on Withdraw) (eventually (on Audit)))"
    [("no withdrawal", run ["Login", "Logout"] true), ("audited", run ["Withdraw", "Audit"] true),
     ("never audited", run ["Withdraw", "Logout"] true)]
  let possible := judged "a possibility" "(possibly (on Refund))"
    [("with a refund", run ["Pay", "Refund"] true), ("without", run ["Pay"] true)]
  out "run-judgements.tex" (listing ("\n\n".intercalate [feature, guard, possible]))
  let rows := LeanFM.LLMGenerated.Hazards.hazards.map fun h =>
    s!"\\texttt\{{texEsc h.id}} & {h.status} & {texEsc h.never} \\\\"
  out "run-hazards.tex" ("\\begin{longtable}{@{}p{.27\\textwidth}p{.12\\textwidth}p{.55\\textwidth}@{}}\n\\toprule\nhazard & status & never \\\\\n\\midrule\n\\endhead\n" ++
    "\n".intercalate rows ++ "\n\\bottomrule\n\\end{longtable}\n")
  IO.println "wrote book/generated/run-*: shop outputs and pie, judgements, hazards"

end RunChapterExample

def main : IO Unit := RunChapterExample.main
