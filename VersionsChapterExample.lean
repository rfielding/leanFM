import LeanFM.Session.VersionTests

/-! Generates the book's section on versions from LeanFM/Session/VersionTests.lean: the versions as
written, the upgrade order the tools find for each, the refusal of a version without a clean path,
the envelope with its stable payload numbers, and a log event that names no version. Nothing here
is written by hand: every listing is the checked text or a tool's answer. Run from the LeanFM root:
`lake env lean --run VersionsChapterExample.lean`. -/

namespace VersionsChapterExample
open Lean LeanFM LeanFM.Session LeanFM.SessionTools LeanFM.Session.VersionTests

def out := "book/generated/"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\scriptsize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"

def main : IO Unit := do
  let kept := lookupText [v1, v2, v4]
  -- written back by LeanFM's own writer, one statement per line
  let (defs, _) <- IO.ofExcept (Text.readText kept)
  IO.FS.writeFile (out ++ "versions-text.tex") (listing (Text.write defs))
  -- the orders found, version by version
  let p <- IO.ofExcept (parseProtocol (args kept))
  let lines := p.upgrades.map fun u => s!"{u.protocolName} {u.fromVersion} -> {u.toVersion}: upgrade {" then ".intercalate u.order}"
  IO.FS.writeFile (out ++ "versions-orders.tex") (listing ("\n".intercalate lines))
  -- a version without a clean path: the same refusal Lean gives at compile time
  let refused := reason (check (args (lookupText [v1, v2, v3bad])))
  IO.FS.writeFile (out ++ "versions-refused.tex")
    (listing (String.replace (String.replace refused ": with " ":\nwith ") "; with " ";\nwith "))
  -- the envelope of the newest version: header fields, then payloads that keep their numbers
  let proto := protoOf kept
  let envelope := match proto.splitOn "message Event {" with
    | [_, rest] => "message Event {" ++ rest
    | _ => proto
  IO.FS.writeFile (out ++ "versions-envelope.tex") (listing envelope)
  -- a log event without a version
  let unnamed := str (conformed [ev "a" "1" "Get" "Client" "Server" none]) "reading"
  IO.FS.writeFile (out ++ "versions-log.tex") (listing unnamed)
  IO.println s!"wrote book/generated/versions-*: {lines.length} upgrades"

end VersionsChapterExample

def main : IO Unit := VersionsChapterExample.main
