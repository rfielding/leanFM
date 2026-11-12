/-!
# SignIn: implementation choices

What an implementation of `SessionType.leanfm` must also decide, that is not a requirement of the
protocol: the transport binding, the encodings, and where state is kept. Written by hand, beside the
session type; the generated files are in `generated/` (`lake env lean --run SessionFiles.lean
examples/oauth` from the LeanFM root rewrites them).
-/

namespace OAuthExample.Implementation

structure Choice where
  subject : String
  choice  : String
  reason  : String
  deriving Repr

def choices : List Choice :=
  [ { subject := "transport"
      choice := "HTTPS for every route; the routes and statuses are the protocol's"
      reason := "OAuth 2.0 requires TLS on the authorization and token endpoints (RFC 6749, 3.1 and 3.2)" }
  , { subject := "request encoding"
      choice := "GET requests carry their fields as query parameters; POST /login and POST /token are application/x-www-form-urlencoded"
      reason := "browsers follow redirects with GET, and RFC 6749, 4.1.3 fixes the token request's encoding; the generated OpenAPI shows JSON bodies, which this choice overrides" }
  , { subject := "redirects"
      choice := "a 302 carries its message in the Location URL's query"
      reason := "the browser is the carrier between App and Idp, and it only follows URLs" }
  , { subject := "the session key"
      choice := "App keeps pending sign-ins in a table keyed by state, with the PKCE verifier and return_to, for at most 10 minutes"
      reason := "state ties the callback to its start (sessions by r.state); an unknown or expired state is answered SignInFailed" }
  , { subject := "PKCE"
      choice := "code_challenge = BASE64URL(SHA256(code_verifier)), code_challenge_method S256"
      reason := "RFC 7636; the protocol carries the challenge, and the secret verifier only on the token request" }
  , { subject := "secrets"
      choice := "password_secr, code_verifier_secr and access_token_secr are never logged; the generated code logs only the fields conditions and the key read"
      reason := "selfhost.session.where and selfhost.mcp.logic.secrets" } ]

end OAuthExample.Implementation
