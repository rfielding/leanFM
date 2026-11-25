import LeanFM.ProjectView

/-! Every listing of LeanFM input text in the book passes the checker as the reader sees it
(clause selfhost.book.listings).

A listing is input when one of its lines starts a structure, protocol, requirements,
implementation or deployment block. A whole listing is checked as printed. A listing whose first
line is `-- from <path>` is an excerpt: its text must occur verbatim in that repository file, and
the file is checked instead. Checking: session_check must not reject the text (a protocol shown to
teach a mistake may have issues), and requirement and implementation entries must not fail.

Usage: lake env lean --run BookListingsCheck.lean            (the book)
       lake env lean --run BookListingsCheck.lean --self-test -/

open Lean LeanFM.ProjectView

namespace BookListingsCheck

def chaptersDir : System.FilePath := "book/chapters"

/-- The bodies of the lstlisting blocks in a TeX text. -/
def listings (tex : String) : List String :=
  ((tex.splitOn "\\begin{lstlisting}").drop 1).filterMap fun part =>
    match part.splitOn "\\end{lstlisting}" with
    | body :: _ :: _ =>
      -- drop the [options] line
      let lines := body.splitOn "\n"
      some ("\n".intercalate (lines.drop 1))
    | _ => none

/-- The generated files a chapter inputs, as paths. -/
def inputs (tex : String) : List String :=
  ((tex.splitOn "\\input{generated/").drop 1).filterMap fun part =>
    match part.splitOn "}" with
    | name :: _ => some ("book/generated/" ++ (if name.endsWith ".tex" then name else name ++ ".tex"))
    | [] => none

/-- A line that starts a block of LeanFM text, as the language writes it. -/
def startsBlock (l : String) : Bool :=
  (l.startsWith "structure " && l.trimAsciiEnd.toString.endsWith " where") ||
  (l.startsWith "protocol " && l.contains '(' && l.trimAsciiEnd.toString.endsWith "{") ||
  l.startsWith "requirements {" ||
  ((l.startsWith "implementation " || l.startsWith "deployment ") && (l.splitOn " of ").length > 1)

def isInput (body : String) : Bool :=
  (body.splitOn "\n").any startsBlock

def hasLists (text : String) : Bool :=
  (text.splitOn "\n").any fun l => l.startsWith "requirements " || l.startsWith "requirements{" || l.startsWith "implementation "

/-- `-- from <path>` on the first line: the path, and the rest of the listing. -/
def excerpt (body : String) : Option (String × String) :=
  match (body.trimAscii.toString).splitOn "\n" with
  | first :: rest =>
    if first.startsWith "-- from " then some ((first.drop 8).trimAscii.toString, "\n".intercalate rest)
    else none
  | [] => none

def safePath (p : String) : Bool :=
  p != "" && !p.startsWith "/" && !(p.splitOn "/").contains ".." && !p.contains '\\'

def contains (hay needle : String) : Bool := (hay.splitOn needle).length > 1

/-- session_check must not reject the text; issues are allowed. -/
def sessionCheck (text : String) : Except String Unit :=
  match LeanFM.SessionTools.check (Json.mkObj [("lean", Json.str text)]) with
  | .ok _ => .ok ()
  | .error e => .error s!"session_check rejects it: {e}"

/-- The requirements gate over one file of the LeanFM project: no entry fails. -/
def gate (file : String) : IO (Except String Unit) := do
  let ps ← projects
  let some p := ps.find? (·.isLeanFM) | return .error "no LeanFM project"
  let (listed, _) ← protocolFiles p
  unless listed.contains file do
    return .error s!"{file} holds requirement or implementation entries but is not a LeanFM protocol file the gate reads"
  -- the file's neighbours too: an implementation block names the requirements map it implements
  let dir := (System.FilePath.mk file).parent.map (·.toString ++ "/") |>.getD ""
  let (files, errs) ← readMapFiles p (listed.filter (·.startsWith dir))
  let mine := files.filter (·.path == file)
  let rows := requirementRows p mine (errs.filter fun e => (e.getObjValAs? String "file").toOption == some file) (withClauses := false) ++
    implementationRows mine
  for r in rows do
    let c ← checkRow p listed files r
    if c.getObjValD "failing" == Json.bool true then
      let g (k : String) := (c.getObjValAs? String k).toOption.getD ""
      return .error s!"entry \"{g "id"}\" fails: {g "verdict"}: {g "reading"}"
  return .ok ()

/-- Check one listing body; `none` when it passes. -/
def checkListing (body : String) : IO (Option String) := do
  match excerpt body with
  | some (path, rest) =>
    unless safePath path do return some s!"-- from {path}: not a relative repository path"
    unless ← System.FilePath.pathExists path do return some s!"-- from {path}: no such file"
    let fileText ← IO.FS.readFile path
    unless contains fileText rest.trimAscii.toString do
      return some s!"the excerpt is not verbatim in {path}"
    if let .error e := sessionCheck fileText then return some s!"{path}: {e}"
    if hasLists fileText then
      if let .error e ← gate path then return some s!"{path}: {e}"
    return none
  | none =>
    if let .error e := sessionCheck body then return some e
    if hasLists body then
      return some "requirement lists and implementation blocks are shown as excerpts (-- from <file>) of a project file the requirements gate decides"
    return none

def runBook : IO UInt32 := do
  let entries ← chaptersDir.readDir
  let chapters : Array String := (entries.filter fun e => e.path.extension == some "tex").map fun e => e.path.toString
  let mut seen : Array String := #[]
  let mut sources : Array (String × String) := #[]
  for ch in chapters.qsort (fun a b => decide (a < b)) do
    let tex ← IO.FS.readFile ch
    sources := sources.push (ch, tex)
    for g in inputs tex do
      if !seen.contains g && (← System.FilePath.pathExists g) then
        seen := seen.push g
        sources := sources.push (g, ← IO.FS.readFile g)
  let mut checked := 0
  let mut failed := 0
  for (file, tex) in sources do
    for body in (listings tex).filter isInput do
      checked := checked + 1
      match ← checkListing body with
      | none => IO.println s!"ok: {file}"
      | some why =>
        failed := failed + 1
        IO.eprintln s!"error: {file}: {why}"
  IO.println s!"book listings: {checked} LeanFM input listings, {failed} failing"
  return if failed == 0 then 0 else 1

def selfTest : IO UInt32 := do
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  let proto := "protocol P (A, B) {\n  r: Req from A to B;\n  Ans from B to A cause r where a.n = r.n;\n}"
  expect "a listing naming an undeclared field is refused" ((← checkListing proto).isSome)
  let declared := "structure Req where\n  n : Nat\nstructure Ans where\n  n : Nat\n" ++
    "protocol P (A, B) {\n  r: Req from A to B;\n  a: Ans from B to A cause r where a.n = r.n;\n}"
  expect "the same protocol with its structures passes" ((← checkListing declared).isNone)
  let race := "protocol Race (Client, Shop) {\n  o: Order from Client to Shop;\n  choice {\n    Cancel from Client to Shop;\n  } or {\n    Ship from Shop to Client;\n  }\n}"
  expect "a teaching protocol with a race passes (issues are allowed)" ((← checkListing race).isNone)
  let fromOrders := "-- from examples/orders/Requirements.leanfm\nstructure Quote where\n  price : Nat"
  expect "a verbatim excerpt of a passing file passes" ((← checkListing fromOrders).isNone)
  expect "an excerpt not verbatim in its file is refused"
    ((← checkListing "-- from examples/orders/Requirements.leanfm\nstructure Quote where\n  cost : Nat").isSome)
  expect "an excerpt path with .. is refused" ((← checkListing "-- from ../etc/passwd\nprotocol X (A, B) { M from A to B; }").isSome)
  expect "an excerpt without -- from is checked whole and refused"
    ((← checkListing "protocol Q (A, B) {\n  include Missing A B;\n}").isSome)
  expect "a requirements list shown whole is refused" ((← checkListing "requirements {\n  \"x\" => sorry \"y\";\n}").isSome)
  expect "an answer listing is not input" (!isInput "faithful: false\nmethod: refinement\nprotocol next: [b]\nrequirements: 5 convert to CTL")
  expect "a chapter's inputs are found" (inputs "a \\input{generated/ctl-x.tex} b \\input{generated/y}" == ["book/generated/ctl-x.tex", "book/generated/y.tex"])
  return 0

end BookListingsCheck

def main (args : List String) : IO UInt32 :=
  if args.contains "--self-test" then BookListingsCheck.selfTest else BookListingsCheck.runBook
