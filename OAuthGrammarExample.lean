import LeanFM.Artifacts
import LeanFM.MDPDiagram

namespace OAuthGrammarExample
open LeanFM

def actors := ["Browser", "Application", "Authorization", "Resource"]

def granted : List MDPDiagram.InteractionMessage :=
  [ { src := "Browser", dst := "Application", label := "ApplicationRequest(resource)" }
  , { src := "Application", dst := "Browser", label := "AuthorizationRedirect(state; callback)" }
  , { src := "Browser", dst := "Authorization", label := "AuthorizationRequest(state; callback)" }
  , { src := "Authorization", dst := "Browser", label := "AuthorizationCodeReturned(state; code)" }
  , { src := "Browser", dst := "Application", label := "AuthorizationCallback(state; code)" }
  , { src := "Application", dst := "Authorization", label := "TokenRequest(code)" }
  , { src := "Authorization", dst := "Application", label := "AccessTokenIssued(token)" }
  , { src := "Application", dst := "Resource", label := "ResourceRequest(token)" }
  , { src := "Resource", dst := "Application", label := "ResourceReturned(profile)" }
  , { src := "Application", dst := "Browser", label := "ApplicationResponse(profile)" } ]

def denied : List MDPDiagram.InteractionMessage :=
  [ { src := "Browser", dst := "Application", label := "ApplicationRequest(resource)" }
  , { src := "Application", dst := "Browser", label := "AuthorizationRedirect(state; callback)" }
  , { src := "Browser", dst := "Authorization", label := "AuthorizationRequest(state; callback)" }
  , { src := "Authorization", dst := "Browser", label := "AuthorizationErrorReturned(state; denied)" }
  , { src := "Browser", dst := "Application", label := "AuthorizationErrorCallback(state; denied)" } ]

def acceptedTrace : List MDPDiagram.InteractionMessage :=
  [ { src := "Browser", dst := "Application", label := "e1: applicationRequest" }
  , { src := "Application", dst := "Browser", label := "e2: authorizationRedirect" }
  , { src := "Browser", dst := "Authorization", label := "e3: authorizationRequest" }
  , { src := "Browser", dst := "Authorization", label := "e4: credentialsSubmitted" }
  , { src := "Authorization", dst := "Browser", label := "e5: authenticationResult(true)" }
  , { src := "Authorization", dst := "Browser", label := "e6: authorizationCodeReturned" }
  , { src := "Browser", dst := "Application", label := "e7: authorizationCallback" }
  , { src := "Application", dst := "Authorization", label := "e8: tokenRequest" }
  , { src := "Authorization", dst := "Application", label := "e9: accessTokenIssued" }
  , { src := "Application", dst := "Resource", label := "e10: protectedResourceRequest" }
  , { src := "Resource", dst := "Application", label := "e11: protectedResourceReturned" }
  , { src := "Application", dst := "Browser", label := "e12: applicationResponse" } ]

def acceptedEvents : List MDPDiagram.PriorEvent :=
  [ { id := "e1", label := "applicationRequest", x := 0, y := 0, priorIds := [] }
  , { id := "e2", label := "authorizationRedirect", x := 0, y := -2, priorIds := ["e1"] }
  , { id := "e3", label := "authorizationRequest", x := 0, y := -4, priorIds := ["e2"] }
  , { id := "e4", label := "credentialsSubmitted", x := 0, y := -6, priorIds := ["e3"] }
  , { id := "e5", label := "authenticationResult(true)", x := 0, y := -8, priorIds := ["e4"] }
  , { id := "e6", label := "authorizationCodeReturned", x := 0, y := -10, priorIds := ["e5"] }
  , { id := "e7", label := "authorizationCallback", x := 7, y := -10, priorIds := ["e6"] }
  , { id := "e8", label := "tokenRequest", x := 7, y := -8, priorIds := ["e7"] }
  , { id := "e9", label := "accessTokenIssued", x := 7, y := -6, priorIds := ["e8"] }
  , { id := "e10", label := "protectedResourceRequest", x := 7, y := -4, priorIds := ["e9"] }
  , { id := "e11", label := "protectedResourceReturned", x := 7, y := -2, priorIds := ["e10"] }
  , { id := "e12", label := "applicationResponse", x := 7, y := 0, priorIds := ["e11"] } ]

def output : DesiredOutput :=
  { id := "oauth.grammar.interactions"
  , prompt := "Replace actor arrow text such as Browser to Application with interaction diagrams."
  , question := "Which actors exchange the messages on the granted and denied OAuth branches?"
  , kind := .interactionDiagram
  , eventSource := "the named OAuth productions and correlated fields in book/chapters/oauth-example.tex"
  , reducer := "expand the granted and denied productions into their ordered actor-message projections"
  , unit := "messages on one OAuth session branch" }

def main : IO Unit := do
  IO.FS.writeFile "book/generated/oauth-granted-interaction.tex"
    (MDPDiagram.renderInteractionTeX actors granted)
  IO.FS.writeFile "book/generated/oauth-denied-interaction.tex"
    (MDPDiagram.renderInteractionTeX actors denied)
  IO.FS.writeFile "book/generated/oauth-accepted-trace.tex"
    (MDPDiagram.renderInteractionTeX actors acceptedTrace)
  IO.FS.writeFile "book/generated/oauth-accepted-prior-graph.tex"
    (MDPDiagram.renderPriorGraphTeX acceptedEvents)
  IO.FS.writeFile "book/generated/oauth-grammar-provenance.txt" (reprStr output ++ "\n")
  IO.println "ok: OAuth granted and denied interaction diagrams generated"

end OAuthGrammarExample

def main : IO Unit := OAuthGrammarExample.main
