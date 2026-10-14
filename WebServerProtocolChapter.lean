import LeanFM.ChatUI.Requirements
import LeanFM.ChatUI.Implementation
import LeanFM.MDPDiagram

namespace WebServerProtocolChapter

open LeanFM
open LeanFM.ChatUI

def texEscape (s : String) : String :=
  let replacements := [("\\", "\\textbackslash{}"), ("_", "\\_"), ("%", "\\%"),
    ("&", "\\&"), ("#", "\\#"), ("{", "\\{"), ("}", "\\}")]
  replacements.foldl (fun out pair => out.replace pair.1 pair.2) s

def scalarName : ProtoScalar → String
  | .string => "string" | .bytes => "bytes" | .bool => "bool"
  | .uint32 => "uint32" | .uint64 => "uint64"

partial def grammarLines (indent : String) : GrammarExpr → List String
  | .empty => [indent ++ "empty"]
  | .event atom => [indent ++ atom.src ++ " ! " ++ atom.dst ++ " : " ++ atom.message]
  | .seq left right => grammarLines indent left ++ [indent ++ "then"] ++ grammarLines indent right
  | .choice branches =>
      (branches.zipIdx.flatMap fun (branch, i) =>
        (if i == 0 then [indent ++ "choose"] else [indent ++ "or"]) ++ grammarLines (indent ++ "  ") branch)
  | .parallel left right =>
      [indent ++ "fork"] ++ grammarLines (indent ++ "  ") left ++
      [indent ++ "and"] ++ grammarLines (indent ++ "  ") right ++ [indent ++ "join all"]
  | .thresholdJoin required branches =>
      (branches.zipIdx.flatMap fun (branch, i) =>
        (if i == 0 then [indent ++ s!"fork; join first {required}"] else [indent ++ "and"]) ++
          grammarLines (indent ++ "  ") branch) ++ [indent ++ "cancel unneeded branches"]
  | .guard predicate body =>
      [indent ++ "when " ++ predicate] ++ grammarLines (indent ++ "  ") body
  | .ref task => [indent ++ "include " ++ task]
  | .repeat body => [indent ++ "repeat"] ++ grammarLines (indent ++ "  ") body

def grammarTex : String :=
  String.join <| Requirements.spec.grammars.map fun grammar =>
    let task := Requirements.spec.tasks.find? (·.id == grammar.task)
    let title := task.map (·.title) |>.getD grammar.task
    "\\section{" ++ texEscape title ++ "}\n" ++
    "\\noindent\\textbf{Task:} \\texttt{" ++ texEscape grammar.task ++ "}. " ++
    "Entry: \\texttt{" ++ texEscape grammar.entry ++ "}; terminals: \\texttt{" ++
    texEscape (String.intercalate ", " grammar.terminals) ++ "}.\n" ++
    "\\begin{verbatim}\n" ++ String.intercalate "\n" (grammarLines "" grammar.body) ++
    "\n\\end{verbatim}\n"

def responsesFor (request : String) : List String :=
  let named := Requirements.messages.filterMap fun message =>
    if Implementation.responseRequest message.name == some request then some message.name else none
  if named.isEmpty && request == "MarkerboardPatchRejected" then ["HTTP 204 (no payload)"] else named

def codeCell (s : String) : String := "\\nolinkurl{" ++ s ++ "}"

def acceptedHttpTex : String :=
  let rows := Requirements.messages.filterMap fun message => do
    let (method, path) ← Implementation.browserRequestTransport message.name
    let responses := responsesFor message.name
    some <| "\\item[" ++ texEscape method ++ " " ++ codeCell path ++ "] Request: " ++
      codeCell message.name ++ ". Response: " ++ String.intercalate ", " (responses.map codeCell) ++ ".\n"
  "\\begin{description}[style=nextline,leftmargin=0pt]\n" ++ String.join rows ++ "\\end{description}\n"

def protobufTex : String :=
  let rows := Requirements.messages.map fun message =>
    let fields := message.fields.map fun field => s!"{field.number}: {field.name} ({scalarName field.scalar})"
    "\\item[" ++ codeCell message.name ++ "] " ++ texEscape message.src ++
      " sends to " ++ texEscape message.dst ++ ". Tagged fields: " ++
      texEscape (String.intercalate "; " fields) ++ ".\n"
  "\\begin{description}[style=nextline,leftmargin=0pt]\n" ++ String.join rows ++ "\\end{description}\n"

structure RunningRoute where
  method : String
  path : String
  request : String
  response : String
  requestEncoding : String
  deriving Repr

def runningRoutes : List RunningRoute :=
  [ ⟨"POST", "/api/accounts", "AccountCreateSubmitted", "AccountCreated or AccountCreateRejected", "application/x-www-form-urlencoded"⟩
  , ⟨"POST", "/api/login", "LoginSubmitted", "LoginAccepted or LoginRejected", "application/x-www-form-urlencoded"⟩
  , ⟨"GET", "/api/me", "authenticated session", "user identity JSON", "cookie only"⟩
  , ⟨"GET", "/api/projects", "ProjectListRequested", "ProjectListReturned", "cookie plus path"⟩
  , ⟨"POST", "/api/projects", "ProjectCreateRequested", "ProjectCreated", "application/x-www-form-urlencoded"⟩
  , ⟨"GET", "/api/projects/{project_id}/conversation", "project identifier", "conversation JSON", "path field plus cookie"⟩
  , ⟨"GET", "/api/projects/{project_id}/tasks", "project identifier", "task model JSON", "path field plus cookie"⟩
  , ⟨"GET", "/api/projects/{project_id}/artifacts", "ArtifactListRequested", "ArtifactListReturned", "path field plus cookie"⟩
  , ⟨"POST", "/api/projects/{project_id}/chat", "ChatPromptSubmitted", "ChatResponseRendered or ChatTurnFailed", "application/x-www-form-urlencoded"⟩ ]

def runningHttpTex : String :=
  let rows := runningRoutes.map fun route =>
    "\\item[" ++ texEscape route.method ++ " " ++ codeCell route.path ++ "] Request: " ++
    texEscape route.request ++ ". Response: " ++ texEscape route.response ++
    ". Encoding: " ++ texEscape route.requestEncoding ++ ".\n"
  "\\begin{description}[style=nextline,leftmargin=0pt]\n" ++ String.join rows ++ "\\end{description}\n"

def overviewMessages : List MDPDiagram.InteractionMessage :=
  [ { src := "Browser", dst := "LeanFM Server", label := "HTTP request(method, path, fields, session cookie)" }
  , { src := "LeanFM Server", dst := "Grammar", label := "construct typed request payload" }
  , { src := "Grammar", dst := "Event Journal", label := "append EventEnvelope(payload, priorIds)" }
  , { src := "Grammar", dst := "LeanFM Server", label := "typed response payload or rejection" }
  , { src := "LeanFM Server", dst := "Browser", label := "HTTP status, JSON projection, Set-Cookie if applicable" } ]

def overviewOutput : DesiredOutput :=
  { id := "web.protocol.adapter.interaction"
  , prompt := "Fully document the LeanFM web-server protocol in LeanFM grammar and explain protobuf-to-HTTP conversion."
  , question := "Where does an HTTP exchange enter the typed message grammar and become a journaled protobuf event?"
  , kind := .interactionDiagram
  , eventSource := "ChatUI RequirementSpec grammars, protobuf MessageSchema values, and Implementation HTTP bindings"
  , reducer := "project the HTTP adapter, grammar transition, EventEnvelope append, and response projection onto actor lifelines"
  , unit := "messages per HTTP exchange" }

def errors : List String :=
  let acceptedRequests := Requirements.messages.filterMap fun message =>
    (Implementation.browserRequestTransport message.name).map fun _ => message.name
  let missingResponses := acceptedRequests.filter fun request => (responsesFor request).isEmpty
  (missingResponses.map fun request => "HTTP request has no response mapping: " ++ request) ++
  (runningRoutes.filterMap fun route =>
    if route.method.isEmpty || route.path.isEmpty || route.request.isEmpty || route.response.isEmpty then
      some "running route has an empty protocol field" else none)

def main : IO Unit := do
  if !errors.isEmpty then throw <| IO.userError (String.intercalate "\n" errors)
  IO.FS.writeFile "book/generated/web-protocol-grammar.tex" grammarTex
  IO.FS.writeFile "book/generated/web-protocol-accepted-http.tex" acceptedHttpTex
  IO.FS.writeFile "book/generated/web-protocol-running-http.tex" runningHttpTex
  IO.FS.writeFile "book/generated/web-protocol-protobuf.tex" protobufTex
  IO.FS.writeFile "book/generated/web-protocol-overview.tex"
    (MDPDiagram.renderInteractionTeX ["Browser", "LeanFM Server", "Grammar", "Event Journal"] overviewMessages)
  IO.FS.writeFile "book/generated/web-protocol-provenance.txt" (reprStr overviewOutput ++ "\n")
  IO.println s!"ok: generated {Requirements.spec.grammars.length} grammars, {Requirements.messages.length} protobuf payloads, and {runningRoutes.length} running HTTP routes"

end WebServerProtocolChapter

def main : IO Unit := WebServerProtocolChapter.main
