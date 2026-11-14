import LeanFM.Session.InstanceTests

/-! Generates the book's section on instances from the systems of
LeanFM/Session/InstanceTests.lean: the system as written, the deadlock session_instances finds, the
fixed system's proofs, the number of states for each system and instance count, and a log whose
fresh actor appears in two sessions. Nothing here is written by hand: every listing is the checked
text or a tool's answer, and every number is the explorer's. Run from the LeanFM root:
`lake env lean --run InstancesChapterExample.lean`. -/

namespace InstancesChapterExample
open Lean LeanFM LeanFM.Session LeanFM.Session.Instances LeanFM.Session.InstanceTests

def out := "book/generated/"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\scriptsize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"

def s (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD "-"

def tool (name : String) (r : Except String Json) : IO Json :=
  match r with
  | .ok j => pure j
  | .error e => throw <| IO.userError s!"{name}: {e}"

def must {a : Type} (what : String) : Except String a -> IO a
  | .ok v => pure v
  | .error e => throw <| IO.userError s!"{what}: {e}"

def main : IO Unit := do
  -- the system as the tools read it (the same text the Lean command elaborates in the tests)
  IO.FS.writeFile (out ++ "instances-system.tex") (listing shopText)
  -- the deadlock, one instance of each accept
  let dead <- tool "session_instances" (InstanceTests.tool (args shopText [("instances", 1)]))
  let deadlocks := match dead.getObjValD "deadlocks" with
    | .arr a => a.toList.filterMap (fun (j : Json) => j.getStr?.toOption) | _ => []
  IO.FS.writeFile (out ++ "instances-deadlock.tex")
    (listing s!"{"\n".intercalate (deadlocks.map fun (d : String) => String.replace (String.replace d ": s1 waits" ":\n  s1 waits") "; s2 waits" ";\n  s2 waits")}")
  -- the fixed order: properties per instance and for the system, four instances in all
  let fixed <- must "OrderedShop" (run OrderedShop 2 (ordered.perInstance.map Prop'.toJson) (ordered.properties.map Prop'.toJson))
  let lines := fixed.verdicts.map fun v => s!"{v.scope}: {v.formula.compress} {v.verdict}"
  IO.FS.writeFile (out ++ "instances-fixed.tex")
    (listing (s!"{fixed.graph.insts.length} instances, {fixed.graph.keys.size} states, {fixed.deadlocks.length} deadlocks, {fixed.isolation.length} isolation problems\n" ++ "\n".intercalate lines))
  -- states and deadlocked states for each system and instance count
  let mut rows : Array String := #[]
  for (label, sys) in [("Shop: opposite orders, serial", Shop), ("OrderedShop: one order, serial", OrderedShop),
                       ("ConcurrentShop: not serial", ConcurrentShop)] do
    let mut cells : Array String := #[]
    for n in [1, 2] do
      let g <- must label (explore sys n)
      cells := cells.push s!"{g.keys.size} & {g.deadlocks.length}"
    rows := rows.push s!"{label} & {" & ".intercalate cells.toList} \\\\"
  let table := "\\begin{tabular}{@{}lrrrr@{}}\n\\toprule\n & \\multicolumn{2}{c}{1 of each} & \\multicolumn{2}{c}{2 of each} \\\\\nSystem & States & Deadlocked & States & Deadlocked \\\\\n\\midrule\n" ++
    "\n".intercalate rows.toList ++ "\n\\bottomrule\n\\end{tabular}\n"
  IO.FS.writeFile (out ++ "instances-counts.tex") table
  -- a log of the system: one client actor in two sessions
  let crossed <- tool "session_conform" (conformed (refreshLog "1" "Client/c1" ++ refreshLog "2" "Client/c1"))
  IO.FS.writeFile (out ++ "instances-log.tex") (listing s!"{s crossed "verdict"}: {s crossed "reading"}")
  IO.println s!"wrote book/generated/instances-*: {s dead "verdict"}; fixed {fixed.graph.keys.size} states; log {s crossed "verdict"}"

end InstancesChapterExample

def main : IO Unit := InstancesChapterExample.main
