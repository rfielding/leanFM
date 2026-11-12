import LeanFM.Logic
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

/-- A password login: the client sends the hash of its password, in clear or sealed for the server. -/
def login (sealed : Bool) (extra : List (String × Json) := []) : Json :=
  let h := json% {hash: {atom: "passwd_secr"}}
  let msg := if sealed then json% {enc: {key: {pk: "Server"}, body: $h}} else h
  Json.mkObj ([("roles", json% [
      {name: "Client", steps: [{send: {to: {atom: "Server"}, message: $msg}}, {claim: {name: "sent", args: [{atom: "Client"}]}}]},
      {name: "Server", steps: [{recv: $msg}, {claim: {name: "login", args: [{atom: "Client"}]}}]}]),
    ("attacker", attacker)] ++ extra)

def hashListed : List (String × Json) := [("secrets", json% [{hash: {atom: "passwd_secr"}}])]

-- in clear: the hash hides the password, so passwd_secr is kept; the marked hash is replayable and leaks
#guard secretVerdict (check (login false hashListed)) "passwd_secr" == "kept"
#guard secretVerdict (check (login false hashListed)) "h(passwd_secr)" == "leaked"
#guard field (check (login false hashListed)) "verdict" == Json.str "disproved"
-- the leak comes with the message that crossed the wire
#guard (match field (check (login false hashListed)) "secrets" with
  | .arr a => a.toList.any fun s => (s.getObjValD "wire").compress.contains "h(passwd_secr)"
  | _ => false)
-- sealed for the server: both are kept, and sk(Server) is named as what protects them
#guard secretVerdict (check (login true hashListed)) "h(passwd_secr)" == "kept"
#guard field (check (login true hashListed)) "verdict" == Json.str "proved"
#guard (field (check (login true hashListed)) "protectors").compress.contains "\"protector\":\"sk(Server)\""
#guard (field (check (login true hashListed)) "protectors").compress.contains "\"sentBy\":\"Client, step 1\""
#guard (field (check (login true hashListed)) "protectors").compress.contains "\"protects\":[\"passwd_secr\",\"h(passwd_secr)\"]"
-- the name alone marks passwd_secr; with no formula the secrets are the question
#guard field (check (login false)) "verdict" == Json.str "proved"
#guard secretVerdict (check (login false)) "h(passwd_secr)" == "absent"
-- a formula keeps its own verdict and the secrets come beside it
#guard field (check (login false (hashListed ++ [("formula", json% {EF: {claimed: "login(Client)"}})]))) "verdict" == Json.str "proved"
#guard secretVerdict (check (login false (hashListed ++ [("formula", json% {EF: {claimed: "login(Client)"}})]))) "h(passwd_secr)" == "leaked"

-- refusals: a listed secret the protocol never mentions would pass vacuously; at most 16 secrets; something to ask
#guard errorHas (check (login false [("secrets", json% [{atom: "nothere"}])])) "would pass vacuously"
#guard errorHas (check (login false [("secrets", Json.arr ((List.range 17).map fun i => Json.mkObj [("atom", Json.str s!"s{i}")]).toArray)])) "the bound is 16"
#guard errorHas (check (Json.mkObj [("roles", json% [{name: "A", steps: [{send: {to: {atom: "B"}, message: {atom: "hello"}}}]}]), ("attacker", attacker)])) "needs a formula or a secret"

-- a name that looks secret but is not marked is a warning, not silence
def plain : Json := Json.mkObj [("roles", json% [{name: "A", steps: [{send: {to: {atom: "B"}, message: {atom: "password"}}}]}]),
  ("attacker", attacker), ("formula", json% {EF: {after: "A → B: password"}})]
#guard (field (check plain) "warnings").compress.contains "password looks secret but is not marked"

-- a model cut off at the state bound never reports a secret kept (the tool's bound is 4096; here 3)
#guard (checkProtocolWith 3 (login false hashListed) |>.toOption.map (·.getObjValD "verdict")) == some (Json.str "resource-limit")
#guard secretVerdict (checkProtocolWith 3 (login false hashListed)) "passwd_secr" == "resource-limit"
#guard secretVerdict (checkProtocolWith 3 (login false hashListed)) "h(passwd_secr)" == "resource-limit"

end LeanFM.SecretsTests
