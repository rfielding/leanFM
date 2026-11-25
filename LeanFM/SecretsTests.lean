import LeanFM.Logic
import LeanFM.MDPDiagram
import Lean.Data.Json.Elab

/-! Tests for selfhost.mcp.logic.secrets (decision logic-secrets): marking a secret asks whether the
attacker can ever derive it. -/
namespace LeanFM.SecretsTests
open Lean LeanFM.Logic

def check (j : Json) : Except String Json := checkProtocol j

def field (r : Except String Json) (k : String) : Json :=
  match r with | .ok j => j.getObjValD k | .error _ => Json.null

def secretVerdict (r : Except String Json) (term : String) : String :=
  match field r "secrets" with
  | .arr a => (a.toList.find? (fun s => (s.getObjValD "term").getStr?.toOption == some term)).bind
      (fun s => (s.getObjValD "verdict").getStr?.toOption) |>.getD "absent"
  | _ => "absent"

def errorHas (r : Except String Json) (s : String) : Bool :=
  match r with | .error e => (e.splitOn s).length > 1 | .ok _ => false

def attacker : Json := json% {name: "Ivo", knows: [{atom: "Client"}, {atom: "Server"}, {atom: "Ivo"}, {pk: "Server"}, {pk: "Ivo"}, {sk: "Ivo"}]}

/-- A password login. The client sends `msg` to the server, in clear or sealed for the server. -/
def loginWith (msg0 : Json) (sealed : Bool) (extra : List (String × Json) := []) : Json :=
  let msg := if sealed then json% {enc: {key: {pk: "Server"}, body: $msg0}} else msg0
  Json.mkObj ([("roles", json% [
      {name: "Client", steps: [{send: {to: {atom: "Server"}, message: $msg}}, {claim: {name: "sent", args: [{atom: "Client"}]}}]},
      {name: "Server", steps: [{recv: $msg}, {claim: {name: "login", args: [{atom: "Client"}]}}]}]),
    ("attacker", attacker)] ++ extra)

/-- The client sends the hash of its password: the hash hides it. -/
def hashed (sealed : Bool) (extra : List (String × Json) := []) : Json := loginWith (json% {hash: {atom: "passwd_secr"}}) sealed extra
/-- The server accepts the hash in place of the password, so the hash is its own secret, named so: the
client sends hpasswd_secr where H(passwd_secr) would be. -/
def login (sealed : Bool) (extra : List (String × Json) := []) : Json := loginWith (json% {atom: "hpasswd_secr"}) sealed extra

-- the name alone marks passwd_secr: a hash hides its input, so it is kept even sent in clear
#guard secretVerdict (check (hashed false)) "passwd_secr" == "kept"
#guard field (check (hashed false)) "verdict" == Json.str "proved"
-- in clear: the accepted hash, named hpasswd_secr, is replayable and leaks
#guard secretVerdict (check (login false)) "hpasswd_secr" == "leaked"
#guard field (check (login false)) "verdict" == Json.str "disproved"
-- the leak comes with the message that crossed the wire
#guard (match field (check (login false)) "secrets" with
  | .arr a => a.toList.any fun s => (s.getObjValD "wire").compress.contains "hpasswd_secr"
  | _ => false)
-- sealed for the server: kept, and sk(Server) is named as what protects it
#guard secretVerdict (check (login true)) "hpasswd_secr" == "kept"
#guard field (check (login true)) "verdict" == Json.str "proved"
#guard (field (check (login true)) "protectors").compress.contains "\"protector\":\"sk(Server)\""
#guard (field (check (login true)) "protectors").compress.contains "\"sentBy\":\"Client, step 1\""
#guard (field (check (login true)) "protectors").compress.contains "\"protects\":[\"hpasswd_secr\"]"
-- a formula keeps its own verdict and the secrets come beside it
#guard field (check (login false [("formula", json% {EF: {claimed: "login(Client)"}})])) "verdict" == Json.str "proved"
#guard secretVerdict (check (login false [("formula", json% {EF: {claimed: "login(Client)"}})])) "hpasswd_secr" == "leaked"
-- a formula asks knows about a secret by its name; an unmarked term is refused
#guard field (check (login false [("formula", json% {never: {knows: {actor: "Ivo", term: {atom: "hpasswd_secr"}}}})])) "verdict" == Json.str "disproved"
#guard errorHas (check (hashed false [("formula", json% {EF: {knows: {actor: "Ivo", term: {atom: "Client"}}}})])) "Client, which is not marked secret: name it with _secr (Client_secr)"

-- refusals: naming is the only mark, so there is no secrets list; at most 16 secrets; something to ask
#guard errorHas (check (login false [("secrets", json% [{hash: {atom: "passwd_secr"}}])])) "secrets is not an argument: name each secret with _secr"
#guard errorHas (check (loginWith (Json.mkObj [("tuple", Json.arr ((List.range 17).map fun i => Json.mkObj [("atom", Json.str s!"s{i}_secr")]).toArray)]) false)) "the bound is 16"
#guard errorHas (check (Json.mkObj [("roles", json% [{name: "A", steps: [{send: {to: {atom: "B"}, message: {atom: "hello"}}}]}]), ("attacker", attacker)])) "needs a formula or a secret"

-- a name that looks secret but is not marked is a warning, not silence
def plain : Json := Json.mkObj [("roles", json% [{name: "A", steps: [{send: {to: {atom: "B"}, message: {atom: "password"}}}]}]),
  ("attacker", attacker), ("formula", json% {EF: {on: "A -> B: password"}})]
#guard (field (check plain) "warnings").compress.contains "password looks secret but is not marked"

-- a model cut off at the state bound never reports a secret kept (the tool's bound is 4096; here 3)
#guard (checkProtocolWith 3 (login false) |>.toOption.map (·.getObjValD "verdict")) == some (Json.str "resource-limit")
#guard secretVerdict (checkProtocolWith 3 (login false)) "hpasswd_secr" == "resource-limit"
#guard secretVerdict (checkProtocolWith 3 (hashed false)) "passwd_secr" == "resource-limit"

end LeanFM.SecretsTests

-- a secret's name carries an underscore, and the generated interaction diagram escapes it for TeX
-- (callers escape braces; an underscore already written \_ is kept)
#guard LeanFM.MDPDiagram.escapeUnderscores "\\{na, nb_secr\\}pk(A) a\\_b" == "\\{na, nb\\_secr\\}pk(A) a\\_b"
#guard (LeanFM.MDPDiagram.renderInteractionTeX ["Alice", "Bob"] [{ src := "Alice", dst := "Bob", label := "nb_secr" }]).contains "nb\\_secr"
