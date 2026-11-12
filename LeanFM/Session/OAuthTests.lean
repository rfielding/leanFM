import LeanFM.SessionTools
import Lean.Data.Json.Elab

/-! Tests for the OAuth example (examples/oauth, decision session-files): sign-in with an identity
provider as plain HTTP, keyed by OAuth's state, with typed messages; and the files its session type
generates (selfhost.session.files). -/
namespace LeanFM.Session.OAuthTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def signIn := include_str "../../examples/oauth/SessionType.leanfm"
def args (extra : List (String × Json) := []) : Json := Json.mkObj ([("lean", Json.str signIn)] ++ extra)
def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def has (s part : String) : Bool := (s.splitOn part).length > 1

-- plain HTTP: every request has a route and gets a response with a status, and the review is clean
#guard str (check (args)) "verdict" == "ok"
#guard str (review (args)) "verdict" == "clean"
#guard ((Text.parse signIn).toOption.map (·.keys)) == some [("r", "state")]

/-! A sign-in as the running services log it: one session, named by its state -/

def ev (id label src dst : String) (cause : Option String) (fields : Json) (session : String := "st-81") : Json :=
  Json.mkObj ([("id", Json.str id), ("session", Json.str session), ("from", Json.str src), ("to", Json.str dst),
    ("label", Json.str label), ("fields", fields)] ++ (cause.map fun c => [("cause", Json.str c)]).getD [])
def redirect := json% {state: "st-81", redirect_uri: "https://app.example/callback", client_id: "app", code_challenge: "E9Me"}
def good (callbackState : String := "st-81") (code : String := "c-5") (exchangeCode : String := "c-5") : List Json :=
  [ ev "e1" "Start" "Browser" "App" none (json% {})
  , ev "e2" "RedirectToIdp" "App" "Browser" (some "e1") redirect
  , ev "e3" "Authorize" "Browser" "Idp" none redirect
  , ev "e4" "LoginPage" "Idp" "Browser" (some "e3") (json% {})
  , ev "e5" "Credentials" "Browser" "Idp" none (json% {state: "st-81"})
  , ev "e6" "RedirectBack" "Idp" "Browser" (some "e5") (json% {state: "st-81", code: "c-5"})
  , ev "e7" "Callback" "Browser" "App" none (Json.mkObj [("state", Json.str callbackState), ("code", Json.str code)])
  , ev "e8" "ExchangeCode" "App" "Idp" (some "e7") (Json.mkObj [("code", Json.str exchangeCode), ("redirect_uri", "https://app.example/callback"), ("client_id", "app")])
  , ev "e9" "Tokens" "Idp" "App" (some "e8") (json% {expires_in: "3600"})
  , ev "e10" "SignedIn" "App" "Browser" (some "e7") (json% {}) ]
def conformed (evs : List Json) : Except String Json := conform (args [("events", Json.arr evs.toArray)])
#guard str (conformed (good "st-81" "c-5")) "verdict" == "conforms"
-- a callback whose state is not the one the app sent is a forged or replayed callback (CSRF): it breaks the protocol
#guard str (conformed (good "st-99" "c-5")) "verdict" == "violates"
#guard has (str (conformed (good "st-99" "c-5")) "reading") "where cb.state = r.state"
-- the app must exchange the code it was given, not another
#guard has (str (conformed (good "st-81" "c-5" "c-6")) "reading") "where t.code = cb.code"
-- the session is named by the state: a log that files the sign-in under another name does not conform
def renamed := (good).map fun e => e.setObjVal! "session" (Json.str "s1")
#guard (match conformed renamed with
  | .ok j => str (.ok j) "verdict" == "violates" && has (j.getObjValD "issues").compress "the session key r.state is st-81, so this session's events must name session st-81, not s1"
  | .error _ => false)
-- secrets are never logged: a token or the PKCE verifier in a log is refused
#guard has (reason (conformed ((good).set 8 (ev "e9" "Tokens" "Idp" "App" (some "e8") (json% {access_token_secr: "ya29", expires_in: "3600"}))))) "secrets are never logged"
-- the denied path goes to the same callback route with the error message
def denied : List Json :=
  (good).take 5 ++
  [ ev "e6" "DeniedBack" "Idp" "Browser" (some "e5") (json% {state: "st-81", error: "access_denied"})
  , ev "e7" "ErrorCallback" "Browser" "App" none (json% {state: "st-81", error: "access_denied"})
  , ev "e8" "SignInFailed" "App" "Browser" (some "e7") (json% {}) ]
#guard str (conformed denied) "verdict" == "conforms"

/-! The generated files -/

def files := (sessionFiles (args)).toOption.getD []
#guard files.map (·.1) == ["Payload.proto", "Payload.lean", "actors/app-openapi.yaml", "actors/idp-openapi.yaml"]
-- the checked-in files are what the session type generates
#guard files.lookup "Payload.proto" == some (include_str "../../examples/oauth/generated/Payload.proto")
#guard files.lookup "Payload.lean" == some (include_str "../../examples/oauth/generated/Payload.lean")
#guard files.lookup "actors/app-openapi.yaml" == some (include_str "../../examples/oauth/generated/actors/app-openapi.yaml")
#guard files.lookup "actors/idp-openapi.yaml" == some (include_str "../../examples/oauth/generated/actors/idp-openapi.yaml")
-- as HTTP is normally used: GET carries query parameters, a redirect carries its message in Location,
-- and the callback route takes either message
def app := (files.lookup "actors/app-openapi.yaml").getD ""
#guard has app "operationId: \"CallbackErrorCallback\""
#guard has app "name: \"state\"\n          required: true"
#guard has app "name: \"code\"\n          required: false"
#guard has app "the Location URL carries state, client_id, redirect_uri, code_challenge as query parameters"
-- every role has its states in the Lean module: each serves one machine per sign-in
#guard (["namespace Browser", "namespace App", "namespace Idp"].all fun n => has ((files.lookup "Payload.lean").getD "") n)

-- the diagram captions the keyed block with its key
#guard has (str (diagram (args)) "svg") "one session per r.state"

-- negative: a role that cannot name a file is refused, so no role can name a path outside generated/
def badRole : String := match sessionFiles (Json.mkObj [("lean", Json.str "protocol P («../x», B) { Ask from B to «../x» route \"GET /a\"; Ok from «../x» to B status 200; }")]) with
  | .error e => e | .ok _ => ""
#guard has badRole "cannot name a file"

end LeanFM.Session.OAuthTests
