import LeanFM

/-!
# The session-type panel of the GoServer browser

Generates the files the game tab's closed-by-default "Session type" panel shows, from the
current `spec/Session.lean` and LeanFM's own sequence-diagram renderer, never by hand:

* `source/cmd/demo/static/session/goserver.leanfm`: the session-type regions of
  `spec/Session.lean` (`--@begin Types`, the message structures, through `--@end GoServer`),
  verbatim, so the parser types every `where` condition against the structures;
* `source/cmd/demo/static/session/goserver.svg`: LeanFM's sequence diagram of protocol
  `GoServer` with every protocol it includes, in the dark theme;
* `source/cmd/demo/static/session/provenance.json`: what the picture answers and how.

Run from the LeanFM root after changing `spec/Session.lean`:
`lake env lean --run projects/GoServer/spec/SessionPanel.lean`.
`TestSessionPanelMatchesTheSpec` in `source/cmd/demo` fails until it is rerun.
-/

open Lean LeanFM LeanFM.SessionTools

namespace Project.SessionPanel

def root := "projects/GoServer"
def out := root ++ "/source/cmd/demo/static/session"

/-- The text between `--@begin Name` and `--@end Name`, for every region in order, verbatim. -/
partial def regions (lines : List String) (acc : Array String := #[]) (inside : Bool := false) : Array String :=
  match lines with
  | [] => acc
  | l :: rest =>
    if l.startsWith "--@begin " then regions rest acc true
    else if l.startsWith "--@end " then regions rest acc false
    else if inside then regions rest (acc.push l) true
    else regions rest acc false

/-- Doc comments (`/-- ... -/`) are for readers; the session-type parser reads the rest. -/
partial def stripDocs (s : String) : String :=
  match s.splitOn "/--" with
  | [] => s
  | first :: more => more.foldl (fun acc part =>
      match part.splitOn "-/" with
      | _ :: after =>
        let rest := "-/".intercalate after
        acc ++ (if rest.startsWith "\n" then (rest.drop 1).toString else rest)
      | [] => acc) first

def main : IO Unit := do
  let src ← IO.FS.readFile (root ++ "/spec/Session.lean")
  let text := "\n".intercalate (regions (src.splitOn "\n")).toList ++ "\n"
  let args := Json.mkObj [("lean", Json.str (stripDocs text)), ("theme", "dark")]
  let p ← IO.ofExcept (parseProtocol args)
  let svg := (annotatedModel p).svg (themeOf args)
  IO.FS.createDirAll out
  IO.FS.writeFile (out ++ "/goserver.leanfm") text
  IO.FS.writeFile (out ++ "/goserver.svg") svg
  let provenance := Json.mkObj
    [ ("prompt", "let's show the session type for the game in a hidden panel")
    , ("question", "What is the session type of GoServer: who sends which message to whom, in which order, and where the choices, loops and independent sessions are?")
    , ("eventSource", "spec/Session.lean, the regions from --@begin Types to --@end GoServer")
    , ("reducer", "LeanFM SessionTools.parseProtocol of those regions without doc comments, then annotatedModel drawn as SVG in the dark theme")
    , ("unit", "messages and local events on the Person, Server and Bot lifelines")
    , ("boundary", s!"protocol {p.name} with every protocol it includes")
    , ("protocol", p.name), ("roles", toJson p.roles)
    , ("generator", root ++ "/spec/SessionPanel.lean") ]
  IO.FS.writeFile (out ++ "/provenance.json") (provenance.pretty ++ "\n")
  IO.println s!"wrote {out}: {p.name}, {text.length} characters of session types, {svg.length} bytes of SVG"

end Project.SessionPanel

def main : IO Unit := Project.SessionPanel.main
