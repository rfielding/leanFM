import LeanFM.Session.ActorTests

/-! Generates the book's section on actors and timing from the lookup log of
LeanFM/Session/ActorTests.lean: the log as it was written (four machines, four clocks), the
verdict in two orders, and session_spans' answer. Nothing here is written by hand: every number is
a tool's answer. Run from the LeanFM root: `lake env lean --run SpansChapterExample.lean`. -/

namespace SpansChapterExample
open Lean LeanFM LeanFM.SessionTools LeanFM.Session.ActorTests

def out := "book/generated/"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\scriptsize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"

def s (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD "-"

def tool (name : String) (r : Except String Json) : IO Json :=
  match r with
  | .ok j => pure j
  | .error e => throw <| IO.userError s!"{name}: {e}"

def msText (ns : String) : String :=
  match ns.toNat? with
  | some n => s!"{n / 1000000}.{(n % 1000000) / 100000} ms"
  | none => "-"

def main : IO Unit := do
  -- the log, one event per line, as the machines wrote it
  let lines := (logged).map fun e =>
    s!"{s e "id"}  {s e "from"} -> {s e "to"}  {s e "label"}  cause {s e "cause"}  prev {s e "prev"}  sentAt {s e "sentAt"}  receivedAt {s e "receivedAt"}"
  IO.FS.writeFile (out ++ "spans-log.tex") (listing ("\n".intercalate lines))
  let inOrder ← tool "conform" (conform (args (logged)))
  let reversed ← tool "conform" (conform (args (logged).reverse))
  IO.FS.writeFile (out ++ "spans-conform.tex") (listing s!"{s inOrder "verdict"}: {s inOrder "reading"}\nreversed log, {s reversed "verdict"}: {s reversed "reading"}")
  let sp ← tool "spans" (spans (args (logged)))
  let rows := match sp.getObjValD "spans" with
    | .arr a => a.toList.map fun x =>
      s!"{s x "label"} & {s x "caller"} & {s x "callee"} & {msText (s x "callerViewNs")} & {msText (s x "calleeViewNs")} & {msText (s x "networkNs")} \\\\"
    | _ => []
  let table := "\\begin{tabular}{@{}llllll@{}}\n\\toprule\nCall & Caller & Callee & Caller waited & Callee took & Network \\\\\n\\midrule\n" ++
    "\n".intercalate rows ++ "\n\\bottomrule\n\\end{tabular}\n"
  IO.FS.writeFile (out ++ "spans-table.tex") table
  let timeline := match sp.getObjValD "timelines" with
    | .arr #[t] => match t.getObjValD "events" with
      | .arr a => a.toList.map fun x =>
        let ev := s x "event"
        let id := (ev.splitOn " ").head!
        let lbl := ((logged).find? (fun e => s e "id" == id)).map (s · "label") |>.getD ""
        let what := if ev.endsWith " received" then s!"receives {lbl} ({id})" else s!"sends {lbl} ({id})"
        s!"{msText (s x "atNs")}  {s x "actor"}  {what}"
      | _ => []
    | _ => []
  IO.FS.writeFile (out ++ "spans-timeline.tex") (listing ("\n".intercalate timeline))
  IO.FS.writeFile (out ++ "spans-reading.tex") (listing s!"{s sp "verdict"}: {s sp "reading"}")
  let skewed ← tool "spans" (spans (args (logged (rowSent := 17))))
  let issue := match skewed.getObjValD "issues" with | .arr a => (a[0]?.bind (·.getStr?.toOption)).getD "" | _ => ""
  IO.FS.writeFile (out ++ "spans-skewed.tex") (listing s!"{s skewed "verdict"}: {issue}")
  IO.println s!"wrote book/generated/spans-*: {s sp "verdict"}; reversed log {s reversed "verdict"}"

end SpansChapterExample

def main : IO Unit := SpansChapterExample.main
