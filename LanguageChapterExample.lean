import LeanFM.SessionTools
import LeanFM.MCP
import LeanFM.Logic
import Lean.Data.Json.Elab

/-!
Generates every listing, diagram and verdict in Part I and Part II of the book (the LeanFM
language) from two example protocols, examples/sessions/PlaceOrder.leanfm and
examples/sessions/Ping.leanfm, through the same functions the MCP tools call. Nothing in those
chapters is drawn or typed by hand.

Run from the LeanFM root:
  lake env lean --run LanguageChapterExample.lean
  python3 scripts/svg_to_pdf.py book/generated/lang-*.svg
The second step turns each SVG (LeanFM's own renderer, light and dark themes) into a PDF the
book includes; the light PDF goes in book/main.pdf and the dark one in book/main-dark.pdf.
-/

namespace LanguageChapterExample
open Lean LeanFM.SessionTools

def out := "book/generated/"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\footnotesize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"

def str (j : Json) (k : String) : String := (j.getObjValD k).getStr?.toOption.getD ""

def strs (j : Json) (k : String) : List String :=
  match j.getObjValD k with
  | .arr a => a.toList.filterMap fun (x : Json) => x.getStr?.toOption
  | _ => []

def withLean (text : String) (more : List (String × Json) := []) : Json :=
  Json.mkObj ([("lean", Json.str text)] ++ more)

/-- Run a tool; a refusal is a generator failure, never a silent gap in the book. -/
def tool (name : String) (r : Except String Json) : IO Json :=
  match r with
  | .ok j => pure j
  | .error e => throw <| IO.userError s!"{name}: {e}"

def write (name body : String) : IO Unit := IO.FS.writeFile (out ++ name) body

def ctlRow (text : String) (english : String) (formula : Json) : IO String := do
  let r ← tool "session_ctl" (ctl (withLean text [("formula", formula)]))
  let report := str r "report"
  return s!"{english}\n  {formula.compress}\n  {str r "verdict"}" ++ (if report.isEmpty then "" else s!": {report}")

def main : IO Unit := do
  let order ← IO.FS.readFile "examples/sessions/PlaceOrder.leanfm"
  let ping ← IO.FS.readFile "examples/sessions/Ping.leanfm"
  IO.FS.createDirAll out

  -- Chapter: the protocol is the program
  write "lang-placeorder.tex" (listing order)
  for theme in ["light", "dark"] do
    let d ← tool "session_diagram" (diagram (withLean order [("theme", Json.str theme)]))
    write s!"lang-placeorder-{theme}.svg" (str d "svg")

  -- Chapter: what a protocol means
  let c ← tool "session_check" (check (withLean order))
  let proj := c.getObjValD "projections"
  let locals := ["Client", "Shop", "Bank"].map fun r => s!"-- {r}\n" ++ str (proj.getObjValD r) "local"
  write "lang-placeorder-locals.tex" (listing ("\n\n".intercalate locals))
  write "lang-placeorder-typestate.tex" (listing (str (proj.getObjValD "Client") "typestate"))
  write "lang-placeorder-calls.tex" (listing (str c "callsText"))
  write "lang-placeorder-check.tex" (listing (str c "reading"))
  let race := "protocol Race (Client, Shop) {\n  choice {\n    Cancel from Client to Shop;\n  } or {\n    Ship from Shop to Client;\n  }\n}"
  let blind := "protocol Blind (Client, Shop, Bank) {\n  h: Hold from Client to Bank;\n  choice {\n    Capture from Shop to Bank;\n    Ship from Shop to Client;\n  } or {\n    SoldOut from Shop to Client;\n  }\n}"
  let issuesOf : String → IO String := fun t => do
    let r ← tool "session_check" (check (withLean t))
    pure ("\n".intercalate (strs r "issues"))
  write "lang-race.tex" (listing race)
  write "lang-race-issues.tex" (listing (← issuesOf race))
  write "lang-blind.tex" (listing blind)
  write "lang-blind-issues.tex" (listing (← issuesOf blind))
  let unanswered := "protocol Lookup (Browser, Api) {\n  q: GetUser from Browser to Api route \"GET /users/{id}\";\n}"
  let rv ← tool "session_review" (review (withLean unanswered))
  write "lang-review.tex" (listing unanswered)
  write "lang-review-report.tex" (listing (str rv "report"))

  -- Chapter: assumptions and promises
  write "lang-ping.tex" (listing ping)
  for theme in ["light", "dark"] do
    let m ← tool "session_mdp" (mdp (withLean ping [("theme", Json.str theme)]))
    write s!"lang-ping-tree-{theme}.svg" (str m "svg")
  let s ← tool "session_sla" (sla (withLean ping))
  write "lang-ping-sla.tex" (listing (str s "report"))

  -- Chapter: questions you ask a protocol
  let rows ← [ ("Every session ends.", json% {AF: "terminal"})
             , ("A receipt is possible.", json% {EF: {after: "Receipt"}})
             , ("Never charge after sold out.", json% {AG: {implies: [{after: "SoldOut"}, {AG: {not: {after: "Charge"}}}]}})
             , ("Every charge ends in a receipt.", json% {AG: {implies: [{after: "Charge"}, {AF: {after: "Receipt"}}]}}) ].mapM
    fun (e, f) => ctlRow order e f
  write "lang-ctl.tex" (listing ("\n\n".intercalate rows))
  let newer := order.replace "    SoldOut from Shop to Client cause o status 409;" "    SoldOut from Shop to Client cause o status 409;\n  } or {\n    Backorder from Shop to Client cause o status 202;"
  let cp ← tool "session_compat" (compat (withLean newer [("old", Json.str order)]))
  write "lang-compat.tex" (listing ("\n".intercalate ([str cp "reading"] ++ strs cp "issues")))

  -- Chapter: an execution is an event stream
  -- the first seed whose single session ends in a receipt, so the run shows the whole conversation
  let runs ← (List.range 40).mapM fun i => do
    let sim ← tool "session_simulate" (simulate (withLean order [("seed", toJson (i + 1)), ("instances", toJson 1)]))
    pure (i + 1, match sim.getObjValD "events" with | .arr a => a.toList | _ => [])
  let (seed, evs) := (runs.find? fun (_, es) => es.any fun e => str e "label" == "Receipt").getD (runs.headD (1, []))
  let line := fun (e : Json) =>
    let cause := match e.getObjValD "cause" with | .null => "" | j => s!" cause {j.compress}"
    s!"id {(e.getObjValD "id").compress}  t={(e.getObjValD "time").compress} ms  {str e "label"}: {str e "src"} -> {str e "dst"}{cause}"
  write "lang-simulate.tex" (listing ("\n".intercalate (evs.map line)))
  -- a log whose shop charges before the client pays
  let bad := json% [
    {id: "e1", session: "42", «from»: "Client", to: "Shop", label: "CreateOrder"},
    {id: "e2", session: "42", «from»: "Shop", to: "Client", label: "Quote", cause: "e1"},
    {id: "e3", session: "42", «from»: "Shop", to: "Bank", label: "Charge", cause: "e2"}]
  let cf ← tool "session_conform" (conform (withLean order [("events", bad)]))
  write "lang-conform-log.tex" (listing ("\n".intercalate ((match bad with | .arr a => a.toList | _ => []).map Json.compress)))
  write "lang-conform.tex" (listing ("\n".intercalate ([str cf "reading"] ++ strs cf "issues")))

  -- Part II: what a protocol generates
  let api ← tool "session_openapi" (openapi (withLean order [("role", "Shop")]))
  write "lang-openapi.tex" (listing ("\n".intercalate ((str api "code").splitOn "\n" |>.take 40)))
  let sk ← tool "session_skeleton" (skeleton (withLean order [("language", "typescript")]))
  let code := (str sk "code").splitOn "\n"
  let start := (code.findIdx? (fun l => (l.splitOn "class Client").length > 1)).getD 0
  write "lang-skeleton.tex" (listing ("\n".intercalate ((code.drop start).take 36)))

  -- Appendix: every tool the MCP server lists, with its title and its arguments (required ones starred)
  let tex := fun (t : String) => t.foldl (fun acc ch => acc ++ match ch with
    | '_' => "\\_" | '&' => "\\&" | '#' => "\\#" | '%' => "\\%" | '{' => "\\{" | '}' => "\\}" | ch => ch.toString) ""
  let rowsT := LeanFM.MCP.tools.toList.map fun t =>
    let req := match (t.getObjValD "inputSchema").getObjValD "required" with
      | .arr a => a.toList.filterMap fun (x : Json) => x.getStr?.toOption | _ => []
    let args := match (t.getObjValD "inputSchema").getObjValD "properties" with
      | .obj kvs => kvs.toList.map fun (k, _) => if req.contains k then k ++ "*" else k | _ => []
    s!"\\texttt\{{(tex (str t "name")).replace "\\_" "\\_\\allowbreak{}"}} & {tex (str t "title")} & \\texttt\{{tex (", ".intercalate args)}} \\\\"
  write "lang-mcp-tools.tex" ("\n".intercalate (["\\begin{tabular}{@{}p{.25\\textwidth}p{.33\\textwidth}p{.36\\textwidth}@{}}",
    "\\toprule", "Tool & What it does & Arguments (* required) \\\\", "\\midrule"] ++ rowsT ++ ["\\bottomrule", "\\end{tabular}"]) ++ "\n")

  write "lang-provenance.txt" <| "\n".intercalate
    [ "prompt: the book could use some very major simplifications. this whole software engineering method is about the leanFM language."
    , "question: what does a LeanFM protocol say, what does it mean, and what is generated from it?"
    , "eventSource: examples/sessions/PlaceOrder.leanfm and examples/sessions/Ping.leanfm, plus the small protocols and logs written in LanguageChapterExample.lean"
    , "reducer: LeanFM.SessionTools (check, diagram, review, mdp, sla, ctl, compat, simulate (the first seed from 1 whose session ends in a receipt), conform, openapi, skeleton): the functions the MCP tools call"
    , "unit: messages, sessions, events (ms), probabilities as exact fractions"
    , "boundary: one session of each protocol, except simulate (one instance) and sla (per entry)"
    , "generator: LanguageChapterExample.lean, then scripts/svg_to_pdf.py for the diagrams" ] ++ "\n"
  write "lang-simulate-seed.tex" s!"{seed}"
  IO.println s!"wrote {out}lang-*: {evs.length} simulated events (seed {seed}); compat {str cp "verdict"}"

end LanguageChapterExample

def main : IO Unit := LanguageChapterExample.main
