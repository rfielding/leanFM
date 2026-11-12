import LeanFM.Logic
import Lean.Data.Json.Elab

/-! Generates the book's "Marking secrets" table: check_protocol on a password login, with the
password marked by name (passwd_secr) and its hash marked by listing, sent in clear and sealed for
the server. Every verdict, protector and warning comes from LeanFM.Logic.checkProtocol.
Run from the LeanFM root: `lake env lean --run SecretsChapterExample.lean`. -/

namespace SecretsChapterExample
open Lean LeanFM.Logic

def attacker : Json := json% {name: "Ivo", knows: [{atom: "Client"}, {atom: "Server"}, {atom: "Ivo"}, {pk: "Server"}, {pk: "Ivo"}, {sk: "Ivo"}]}

def login (sealed : Bool) : Json :=
  let h := json% {hash: {atom: "passwd_secr"}}
  let msg := if sealed then json% {enc: {key: {pk: "Server"}, body: $h}} else h
  Json.mkObj [("roles", json% [
      {name: "Client", steps: [{send: {to: {atom: "Server"}, message: $msg}}]},
      {name: "Server", steps: [{recv: $msg}, {claim: {name: "login", args: [{atom: "Client"}]}}]}]),
    ("attacker", attacker), ("secrets", json% [{hash: {atom: "passwd_secr"}}])]

def plain : Json := Json.mkObj [("roles", json% [{name: "Client", steps: [{send: {to: {atom: "Server"}, message: {atom: "session_token"}}}]}]),
  ("attacker", attacker), ("formula", json% {EF: true})]

def tex (s : String) : String :=
  s.foldl (fun acc c => acc ++ match c with
    | '_' => "\\_" | '{' => "\\{" | '}' => "\\}" | '#' => "\\#" | '&' => "\\&" | c => c.toString) ""

def str (j : Json) (k : String) : String := (j.getObjValD k).getStr?.toOption.getD ""

def rows (variant : String) (r : Json) : List String :=
  match r.getObjValD "secrets" with
  | .arr a => a.toList.map fun s =>
    s!"{variant} & \\texttt\{{tex (str s "term")}} & {str s "marked"} & {str s "verdict"} \\\\"
  | _ => []

def main : IO Unit := do
  let clear ← IO.ofExcept (checkProtocol (login false))
  let sealed ← IO.ofExcept (checkProtocol (login true))
  let warned ← IO.ofExcept (checkProtocol plain)
  let protectors := match sealed.getObjValD "protectors" with
    | .arr a => a.toList.map fun p =>
      s!"\\texttt\{{tex (str p "protector")}} protects " ++
        ", ".intercalate ((match p.getObjValD "protects" with | .arr xs => xs.toList | _ => []).map fun (x : Json) => s!"\\texttt\{{tex (x.getStr?.toOption.getD "")}}") ++
        s!" ({tex (str p "sentBy")})"
    | _ => []
  let warnings := match warned.getObjValD "warnings" with
    | .arr a => a.toList.filterMap fun (w : Json) => w.getStr?.toOption
    | _ => []
  let table := "\n".intercalate (["\\begin{tabular}{llll}", "\\hline", "Login & Secret & Marked & Verdict \\\\", "\\hline"] ++
    rows "in clear" clear ++ rows "sealed for Server" sealed ++ ["\\hline", "\\end{tabular}"])
  IO.FS.writeFile "book/generated/secrets-login.tex" (table ++ "\n")
  IO.FS.writeFile "book/generated/secrets-protectors.tex" ("\n\n".intercalate (protectors.map (· ++ ".") ++ warnings.map (fun w => s!"Warning: {tex w}.")) ++ "\n")
  IO.FS.writeFile "book/generated/secrets-provenance.txt" <| "\n".intercalate
    [ "prompt: and knows... could be helped by marking variables as secrets; because we dont care about anyone knowing anything that is not secret. maybe a naming convention for secrets. passwd_secr, hpasswd_secr = H(passwd_secr), etc. if not by naming convention, then some marker."
    , "question: in a password login, which marked secrets can the attacker derive, sent in clear and sealed for the server, and what protects them?"
    , "eventSource: the login declarations in SecretsChapterExample.lean"
    , "reducer: LeanFM.Logic.checkProtocol: one check_ctl question AG not knows(Ivo, secret) per secret over the generated model; protectors from the send patterns; warnings from names"
    , "unit: secrets (terms); verdicts kept, leaked or resource-limit"
    , "boundary: one session of each role; Ivo is the network"
    , "generator: SecretsChapterExample.lean" ] ++ "\n"
  IO.println s!"wrote book/generated/secrets-*: in clear {str clear "verdict"}, sealed {str sealed "verdict"}"

end SecretsChapterExample

def main : IO Unit := SecretsChapterExample.main
