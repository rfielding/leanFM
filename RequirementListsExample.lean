import LeanFM.ProjectView

/-!
Generates the listings, diagram and tables of the book's chapter on requirement and implementation
lists (book/chapters/requirement-lists.tex) through the functions project_view and the session tools
call. The example is examples/orders: a requirements file (PlaceOrder and its map) and a Go
implementation (ShopImpl, evidence, its own CTL and hints, and where ShopImpl runs); LeanFM's own lists are summarized at the
end. Every entry is converted to CTL and decided by ProjectView.checkRow, and every formula is
shown with the notation and plain reading session_ctl gives. Nothing in that chapter is typed by hand.

Run from the LeanFM root: lake env lean --run RequirementListsExample.lean
then: python3 scripts/svg_to_pdf.py book/generated/req-*.svg
-/

namespace RequirementListsExample
open Lean LeanFM.ProjectView

def out := "book/generated/"
def write (name body : String) : IO Unit := IO.FS.writeFile (out ++ name) body
def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\footnotesize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"
def g (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD ""
def yes (j : Json) (k : String) : Bool := j.getObjValD k == Json.bool true

/-- The lines of `text` from the first that starts with `start`, up to (not including) the first
after it that starts with `stop` (or to the end). -/
def between (text start : String) (stop : Option String := none) : String :=
  let ls := (text.splitOn "\n").dropWhile (!·.startsWith start)
  let ls := match stop with
    | some s => (ls.take 1) ++ ((ls.drop 1).takeWhile (!·.startsWith s))
    | none => ls
  "\n".intercalate ls

/-- The protocol text up to `upto` (the protocols the session tools check). -/
def through (text upto : String) : String := (text.splitOn upto).headD text

def reqFile := "examples/orders/Requirements.leanfm"
def implFile := "examples/orders/Implementation.leanfm"

/-- What one checked entry requires, in CTL and in words, with its verdict. -/
def explain (proto : String) (r : Json) : String :=
  let name := g r "id"
  let kind := g r "kind"
  let verdict := if g r "status" != "" then g r "status" else g r "verdict"
  match kind with
  | "formula" =>
    let a := (LeanFM.SessionTools.ctl (Json.mkObj [("lean", Json.str proto), ("formula", Json.str (g r "formula"))])).toOption.getD Json.null
    let reading := (g a "reading").splitOn ": " |>.drop 1 |> ": ".intercalate
    s!"\"{name}\"\n    {g a "notation"}\n    {reading}\n    -> {verdict}"
  | "protocol" =>
    let n := ((r.getObjValD "ctl").getObjValAs? Nat "ruleCount").toOption.getD 0
    s!"\"{name}\"\n    the conversation is exactly {g r "name"}'s: {n} faithful CTL rules, one per typestate and one for the start\n    -> {verdict}"
  | "sorry" => s!"\"{name}\"\n    sorry{if g r "text" != "" then s!": {g r "text"}" else ""}\n    -> {verdict}"
  | "conform" => s!"\"{name}\"\n    evidence: the log {g r "log"} conforms to the requirement's protocol\n    -> {verdict}"
  | "test" => s!"\"{name}\"\n    evidence: the test {g r "test"}\n    -> {verdict}"
  | "refines" => s!"refines {g r "from"} by {g r "by"}\n    every formula requirement over {g r "from"} decided again over {g r "by"}: {g r "reading"}\n    -> {verdict}"
  | "hint" => s!"{name}: {g r "text"}\n    claims no behaviour, converts to true\n    -> {verdict}"
  | _ => s!"\"{name}\" -> {verdict}"

def main : IO Unit := do
  let ps ← projects
  let some p := ps.find? (·.isLeanFM) | throw (IO.userError "no LeanFM project")
  let (listed, _) ← protocolFiles p
  -- the example, checked as `make requirements-check --files` checks it
  let exFiles := listed.filter ([reqFile, implFile].contains ·)
  unless exFiles.size == 2 do throw (IO.userError "examples/orders is not listed")
  let (files, errs) ← readMapFiles p exFiles
  unless errs.isEmpty do throw (IO.userError s!"example files that do not read: {errs.size}")
  let reqText ← IO.FS.readFile reqFile
  let implText ← IO.FS.readFile implFile
  -- every listing passes the checker as printed, or says which file it is an excerpt of (selfhost.book.listings)
  write "req-orders-protocol.tex" (listing (between reqText "/-- What the client orders. -/" (some "requirements {")))
  write "req-orders-map.tex" (listing (s!"-- from {reqFile}\n" ++ between reqText "requirements {"))
  write "req-shopimpl.tex" (listing (between implText "protocol ShopImpl" (some "implementation ")))
  write "req-orders-impl.tex" (listing (s!"-- from {implFile}\n" ++ between implText "implementation " (some "-- Where ShopImpl runs")))
  -- where ShopImpl runs: the deployment block, its view and a refused variant (selfhost.session.deployment)
  write "req-orders-deployment.tex" (listing (s!"-- from {implFile}\n" ++ between implText "deployment Production"))
  for theme in ["light", "dark"] do
    let d ← IO.ofExcept (LeanFM.SessionTools.deployment (Json.mkObj [("lean", Json.str implText), ("theme", Json.str theme)]))
    unless g d "verdict" == "placed" do throw (IO.userError s!"the Orders deployment is not placed: {g d "reading"}")
    write s!"req-deployment-{theme}.svg" (g d "svg")
  -- each link with the interface it uses and the conditions it adds, as the view's legend lists them
  let placed ← IO.ofExcept (LeanFM.SessionTools.deployment (Json.mkObj [("lean", Json.str implText)]))
  let strs (j : Json) (k : String) : List String := ((j.getObjValD k).getArr?.toOption.getD #[]).toList.filterMap (·.getStr?.toOption)
  let linkLine (l : Json) : String :=
    let via := match (l.getObjValAs? String "via").toOption with | some v => v | none => "no interface declared"
    let via := if (g l "note").startsWith "replies" then s!"{via} (replies)" else via
    let cs := strs l "conditions"
    s!"{g l "from"} -> {g l "to"} ({", ".intercalate (strs l "labels")})\n    {via}; {if cs.isEmpty then "adds nothing" else s!"adds {", ".intercalate cs}"}"
  write "req-deployment-links.tex" (listing ("\n".intercalate (((placed.getObjValD "links").getArr?.toOption.getD #[]).toList.map linkLine)))
  let bankLine := "      Bank { peering api : api; internal admin : api; }"
  let narrowed := "      Bank { internal admin : api; }"
  unless (implText.splitOn bankLine).length == 2 do throw (IO.userError "the Orders deployment no longer has the Bank line the book narrows")
  let refused ← IO.ofExcept (LeanFM.SessionTools.deployment (Json.mkObj [("lean", Json.str (implText.replace bankLine narrowed))]))
  let issues := ((refused.getObjValD "issues").getArr?.toOption.getD #[]).toList.map (g · "issue")
  write "req-deployment-refused.tex" (listing s!"{narrowed.trimAscii}\n\nsession_deployment: {g refused "verdict"}\n{"\n".intercalate (issues.map ("  " ++ ·))}")
  for theme in ["light", "dark"] do
    let d ← IO.ofExcept (LeanFM.SessionTools.diagram (Json.mkObj [("lean", Json.str (through implText "implementation ")), ("theme", Json.str theme)]))
    write s!"req-shopimpl-{theme}.svg" (g d "svg")
  let rrows ← (requirementRows p files errs (withClauses := false)).mapM (checkRow p exFiles files)
  let irows ← (implementationRows files).mapM (checkRow p exFiles files)
  let reqProto := through reqText "requirements {"
  let shopProto := through implText "implementation "
  write "req-orders-explained.tex" (listing ("\n\n".intercalate (rrows.toList.map (explain reqProto))))
  write "req-orders-impl-explained.tex" (listing ("\n\n".intercalate (irows.toList.map fun r =>
    explain (if g r "kind" == "formula" then shopProto else reqProto) r)))
  let (_, implsJ) ← listSummariesOf p exFiles (withClauses := false)
  let st := ((implsJ.getObjValD "implementations").getArr?.toOption.getD #[])[0]?.getD Json.null
  let n (k : String) := ((st.getObjValD "status").getObjValAs? Nat k).toOption.getD 0
  write "req-orders-summary.tex" (listing s!"examples/orders: {rrows.size + irows.size} entries; {(rrows ++ irows).toList.filter (yes · "failing") |>.length} failing; {(rrows ++ irows).toList.filter (yes · "sorry") |>.length} use sorry\nrequirements: {(rrows.toList.filter (g · "kind" != "sorry")).length} convert to CTL, {(rrows.toList.filter (yes · "met")).length} met\nimplementation Go: {n "met"} met, {n "specified"} specified, {n "tested"} tested, {n "sorry"} sorry, {n "failing"} failing")
  -- LeanFM's own lists, from its specification directory
  let spec := specProtocols p listed
  let (sfiles, serrs) ← readMapFiles p spec
  let srows ← (requirementRows p sfiles serrs).mapM (checkRow p spec sfiles)
  let sirows ← (implementationRows sfiles).mapM (checkRow p spec sfiles)
  let (_, simpls) ← listSummaries p listed
  let sst := ((simpls.getObjValD "implementations").getArr?.toOption.getD #[])[0]?.getD Json.null
  let sn (k : String) := ((sst.getObjValD "status").getObjValAs? Nat k).toOption.getD 0
  let formal := srows.toList.filter (g · "kind" != "sorry")
  write "req-leanfm-summary.tex" (listing s!"LeanFM: {srows.size + sirows.size} entries; {(srows ++ sirows).toList.filter (yes · "failing") |>.length} failing; {(srows ++ sirows).toList.filter (yes · "sorry") |>.length} use sorry\nrequirements (LeanFM/LLMGenerated/LeanFM.leanfm): {formal.length} convert to CTL, {(formal.filter (yes · "met")).length} met; {(srows.toList.filter (yes · "sorry")).length} use sorry (the clauses of SelfHosting.lean)\nimplementation Lean (LeanFM/LLMGenerated/LeanFMImplementation.leanfm): {sn "met"} met, {sn "specified"} specified, {sn "tested"} tested, {sn "sorry"} sorry, {sn "failing"} failing")
  write "req-provenance.txt" <| "\n".intercalate
    [ "prompt: every requirements file ends in a map from requirement names to pointers; implementations import requirements, add their own CTL and hints; requirements and implementations are things that convert to CTL, and sorry is what does not yet; the book's examples must say what is required"
    , "question: what does each requirement of a small shop require, in CTL and in words, what does an implementation of it add, and which entries are met, sorry or failing?"
    , "eventSource: examples/orders/Requirements.leanfm, examples/orders/Implementation.leanfm (with its deployment block), examples/orders/logs/order-1.json; LeanFM/LLMGenerated/LeanFM.leanfm and LeanFMImplementation.leanfm for LeanFM's own summary"
    , "reducer: LeanFM.ProjectView.readMapFiles, requirementRows, implementationRows, checkRow, listSummaries; LeanFM.SessionTools.ctl (notation, reading), diagram and deployment"
    , "unit: entries; verdicts proved, ok, sorry, true, tested, conforms; statuses met, specified, tested, sorry, failing"
    , "boundary: the two example files; LeanFM's specification directory"
    , "generator: RequirementListsExample.lean, then scripts/svg_to_pdf.py book/generated/req-*.svg" ] ++ "\n"
  IO.println s!"wrote {out}req-*: orders {rrows.size} requirements, {irows.size} implementation entries"

end RequirementListsExample

def main : IO Unit := RequirementListsExample.main
