import LeanFM.SessionTools
import Lean.Data.Json.Elab

/-! Generates the book's OAuth chapter from examples/oauth: the session type, its diagram, a forged
callback caught by conformance, the generated OpenAPI for the callback and the App's states.
Nothing here is written by hand: every listing is a file or a tool's answer.
Run from the LeanFM root: `lake env lean --run OAuthChapterExample.lean`. -/

namespace OAuthChapterExample
open Lean LeanFM LeanFM.SessionTools

def out := "book/generated/"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\scriptsize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"

def str (j : Json) (k : String) : String := (j.getObjValD k).getStr?.toOption.getD ""

def tool (name : String) (r : Except String Json) : IO Json :=
  match r with
  | .ok j => pure j
  | .error e => throw <| IO.userError s!"{name}: {e}"

def write (name body : String) : IO Unit := IO.FS.writeFile (out ++ name) body

def ev (id label src dst : String) (cause : Option String) (fields : Json) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", "st-81"), ("from", Json.str src), ("to", Json.str dst),
    ("label", Json.str label), ("fields", fields)] ++ (cause.map fun c => [("cause", Json.str c)]).getD [])

def main : IO Unit := do
  let text ← IO.FS.readFile "examples/oauth/SessionType.leanfm"
  let args (more : List (String × Json) := []) := Json.mkObj ([("lean", Json.str text)] ++ more)
  -- the protocol, without the structures above it
  let lines := text.splitOn "\n"
  write "oauth-signin.tex" (listing ("\n".intercalate (lines.dropWhile (!·.startsWith "protocol SignIn"))))
  for theme in ["light", "dark"] do
    let d ← tool "session_diagram" (diagram (args [("theme", Json.str theme)]))
    write s!"oauth-signin-{theme}.svg" (str d "svg")
  -- a callback carrying a state the app never sent: a forged or replayed callback
  let redirect := json% {state: "st-81", redirect_uri: "https://app.example/callback", client_id: "app", code_challenge: "E9Me"}
  let forged := [
    ev "e1" "Start" "Browser" "App" none (json% {}),
    ev "e2" "RedirectToIdp" "App" "Browser" (some "e1") redirect,
    ev "e3" "Authorize" "Browser" "Idp" none redirect,
    ev "e4" "LoginPage" "Idp" "Browser" (some "e3") (json% {}),
    ev "e5" "Credentials" "Browser" "Idp" none (json% {state: "st-81"}),
    ev "e6" "RedirectBack" "Idp" "Browser" (some "e5") (json% {state: "st-81", code: "c-5"}),
    ev "e7" "Callback" "Browser" "App" none (json% {state: "st-99", code: "c-5"})]
  let cf ← tool "session_conform" (conform (args [("events", Json.arr forged.toArray), ("allowIncomplete", Json.bool true)]))
  write "oauth-forged-log.tex" (listing ("\n".intercalate (forged.map Json.compress)))
  write "oauth-forged.tex" (listing (str cf "reading"))
  -- the generated files
  let files ← IO.ofExcept (sessionFiles (args))
  let appYaml := (files.lookup "actors/app-openapi.yaml").getD ""
  let pathLines := ((appYaml.splitOn "\n").dropWhile (· != "paths:")).take 40
  write "oauth-callback-openapi.tex" (listing ("\n".intercalate pathLines))
  let leanLines := ((files.lookup "Payload.lean").getD "").splitOn "\n"
  let appStates := (leanLines.dropWhile (· != "namespace App")).takeWhile (!·.startsWith "/-- Whether the session may end here")
  write "oauth-app-states.tex" (listing ("\n".intercalate appStates))
  write "oauth-files.tex" (listing ("\n".intercalate (files.map fun (p, b) => s!"generated/{p}  ({(b.splitOn "\n").length} lines)")))
  write "oauth-provenance.txt" <| "\n".intercalate
    [ "prompt: the oauth example should be straight-up http, as normally implemented."
    , "question: How does sign-in with an identity provider read as a typed session type over plain HTTP, and what does it generate?"
    , "eventSource: examples/oauth/SessionType.leanfm and a log written in OAuthChapterExample.lean"
    , "reducer: session_diagram, session_conform and sessionFiles (Payload.proto, Payload.lean, actors/*-openapi.yaml)"
    , "unit: messages of one sign-in session, keyed by state"
    , "boundary: protocol SignIn" ]
  IO.println s!"wrote book/generated/oauth-*: forged callback {str cf "verdict"}; {files.length} generated files"

end OAuthChapterExample

def main : IO Unit := OAuthChapterExample.main
