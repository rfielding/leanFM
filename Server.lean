import LeanFM
import Std.Internal.Async.TCP

open Std
open Std.Net

namespace LeanFM.Server

abbrev TcpServer := Std.Internal.IO.Async.TCP.Socket.Server
abbrev TcpClient := Std.Internal.IO.Async.TCP.Socket.Client

def bindAddr : SocketAddress :=
  SocketAddress.v4
    { addr := IPv4Addr.ofParts 127 0 0 1
    , port := 8080
    }

def requestPath (request : String) : String :=
  match request.splitOn "\r\n" with
  | firstLine :: _ =>
      match firstLine.splitOn " " with
      | _method :: path :: _ =>
          match path.splitOn "?" with
          | clean :: _ => clean
          | _ => path
      | _ => "/"
  | _ => "/"

def requestMethod (request : String) : String :=
  match request.splitOn "\r\n" with
  | firstLine :: _ =>
      match firstLine.splitOn " " with
      | method :: _ => method
      | _ => "GET"
  | _ => "GET"

def requestBody (request : String) : String :=
  match request.splitOn "\r\n\r\n" with
  | _headers :: body :: _ => body
  | _ => ""

def sessionChars : List Char :=
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".toList

def isSessionChar (c : Char) : Bool :=
  sessionChars.contains c

def sanitizeSessionId (s : String) : String :=
  String.ofList ((s.toList.filter isSessionChar).take 48)

partial def takeSessionPrefixLoop (cs acc : List Char) : String :=
  match cs with
  | [] => String.ofList acc.reverse
  | c :: rest =>
      if isSessionChar c then
        takeSessionPrefixLoop rest (c :: acc)
      else
        String.ofList acc.reverse

def takeSessionPrefix (s : String) : String :=
  takeSessionPrefixLoop s.toList []

def sessionId? (request : String) : Option String :=
  match request.splitOn "leanfm_session=" with
  | _ :: rest :: _ =>
      let sid := sanitizeSessionId (takeSessionPrefix rest)
      if sid.length == 0 then none else some sid
  | _ => none

def hasSession (request : String) : Bool :=
  (sessionId? request).isSome

def sessionsRoot : String :=
  "/tmp/leanfm-sessions"

def sessionWorkspaceString (sessionId : String) : String :=
  sessionsRoot ++ "/" ++ sessionId

def sessionGeneratedLeanString (sessionId : String) : String :=
  sessionWorkspaceString sessionId ++ "/Requirements.lean"

def sessionGeneratedProtoString (sessionId : String) : String :=
  sessionWorkspaceString sessionId ++ "/Requirements.proto"

def sessionGeneratedImplementationString (sessionId : String) : String :=
  sessionWorkspaceString sessionId ++ "/Implementation.lean"

def sessionWorkspace (sessionId : String) : System.FilePath :=
  System.FilePath.mk (sessionWorkspaceString sessionId)

def sessionGeneratedLeanPath (sessionId : String) : System.FilePath :=
  System.FilePath.mk (sessionGeneratedLeanString sessionId)

def sessionGeneratedProtoPath (sessionId : String) : System.FilePath :=
  System.FilePath.mk (sessionGeneratedProtoString sessionId)

def sessionGeneratedImplementationPath (sessionId : String) : System.FilePath :=
  System.FilePath.mk (sessionGeneratedImplementationString sessionId)

def ensureSessionWorkspace (sessionId : String) : IO Unit :=
  IO.FS.createDirAll (sessionWorkspace sessionId)

def newSessionId : IO String := do
  let a ← IO.rand 100000000 999999999
  let b ← IO.rand 100000000 999999999
  pure ("s" ++ toString a ++ "-" ++ toString b)

def loginPage : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM Login</title>" ++
  "<meta name=\"color-scheme\" content=\"dark only\">" ++
  "<style>html,body{background:#111;color:#f8f8f8;color-scheme:dark only}body{font-family:system-ui,sans-serif;margin:2rem}form{max-width:360px;border:1px solid #444;background:#090909;padding:1rem}input,button{box-sizing:border-box;width:100%;margin:.4rem 0;padding:.65rem;background:#000;color:#fff;border:1px solid #666}button{background:#1d4ed8;border-color:#93c5fd;font-weight:700}</style>" ++
  "</head><body><h1>LeanFM</h1><form method=\"post\" action=\"/login\"><label>Password <input name=\"password\" type=\"password\" autofocus></label><button type=\"submit\">Log in</button></form></body></html>"

structure Response where
  status : Nat
  contentType : String
  body : ByteArray
  headers : List String := []

def response (status : Nat) (contentType body : String) (headers : List String := []) : Response :=
  { status, contentType, body := body.toUTF8, headers }

def byteResponse (status : Nat) (contentType : String) (body : ByteArray) (headers : List String := []) : Response :=
  { status, contentType, body, headers }

def jsonEscape (s : String) : String :=
  String.join <| s.toList.map fun c =>
    if c == '"' then "\\\""
    else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n"
    else if c == '\r' then "\\r"
    else if c == '\t' then "\\t"
    else c.toString

partial def takeJsonStringLoop (cs : List Char) (acc : List Char) (escaped : Bool) : String :=
  match cs with
  | [] => String.ofList acc.reverse
  | c :: rest =>
      if escaped then
        let decoded :=
          if c == 'n' then '\n'
          else if c == 'r' then '\r'
          else if c == 't' then '\t'
          else c
        takeJsonStringLoop rest (decoded :: acc) false
      else if c == '\\' then
        takeJsonStringLoop rest acc true
      else if c == '"' then
        String.ofList acc.reverse
      else
        takeJsonStringLoop rest (c :: acc) false

def takeJsonString (s : String) : String :=
  takeJsonStringLoop s.toList [] false

def responseOutputText (json : String) : Option String :=
  match json.splitOn "\"output_text\":\"" with
  | _ :: rest :: _ => some (takeJsonString rest)
  | _ =>
      match json.splitOn "\"text\":\"" with
      | _ :: rest :: _ => some (takeJsonString rest)
      | _ =>
          match json.splitOn "\"content\":\"" with
          | _ :: rest :: _ => some (takeJsonString rest)
          | _ => none

def llmSystemPrompt : String :=
  "You are LeanFM's requirements interviewer. Do not invent facts needed to calculate a requested property. Ask focused questions until scenario boundaries, event backpointers, actors and instances, bytes, clocks, work, observation windows, probabilities, distributions, outages, and tolerances make the requested results identifiable. Separate observed distributions from expected assumptions. Then emit durable Lean requirements, protobuf values, implementation choices, reducers, and acceptance checks. Assume this conversation will be lost: the generated files must contain the complete current understanding. Every sufficiently identified event stream should yield per-scenario interaction diagrams and state machines, XY line metrics, pie-chart histograms, uptime/reliability, throughput, and latency. To synthesize a similar scenario, characterize the source, generate a candidate, replay the same reducers, and require metric agreement within declared tolerances."

def openAIRequestJson (model prompt : String) : String :=
  "{\"model\":\"" ++ jsonEscape model ++
  "\",\"input\":[{\"role\":\"system\",\"content\":\"" ++ jsonEscape llmSystemPrompt ++
  "\"},{\"role\":\"user\",\"content\":\"" ++ jsonEscape prompt ++ "\"}]}"

def callLLM (prompt : String) : IO Response := do
  match (← IO.getEnv "OPENAI_API_KEY") with
  | none =>
      pure <| response 503 "text/plain; charset=utf-8" "OPENAI_API_KEY is not set; using deterministic LeanFM tools instead.\n"
  | some key =>
      let model ←
        match (← IO.getEnv "LEANFM_LLM_MODEL") with
        | some m => pure m
        | none => pure "gpt-5-mini"
      let payload := openAIRequestJson model prompt
      let out ← IO.Process.output {
        cmd := "curl"
        args := #[
          "-sS", "--max-time", "6", "https://api.openai.com/v1/responses",
          "-H", "Content-Type: application/json",
          "-H", "Authorization: Bearer " ++ key,
          "-d", payload
        ]
      }
      if out.exitCode == 0 then
        match responseOutputText out.stdout with
        | some text => pure <| response 200 "text/plain; charset=utf-8" text
        | none => pure <| response 502 "text/plain; charset=utf-8" ("LLM response did not include output_text; raw response follows.\n" ++ out.stdout)
      else
        pure <| response 502 "text/plain; charset=utf-8" ("LLM request failed.\n" ++ out.stderr)

def readTextOrElse (path : System.FilePath) (fallback : IO String) : IO String := do
  try
    IO.FS.readFile path
  catch _ =>
    fallback

def defaultGeneratedRequirementsLean : IO String :=
  readTextOrElse (System.FilePath.mk "LeanFM/LLMGenerated/Requirements.lean") (pure LeanFM.workerLeanFile)

def defaultGeneratedImplementationLean : IO String :=
  readTextOrElse (System.FilePath.mk "LeanFM/LLMGenerated/Implementation.lean")
    (pure "import LeanFM.LLMGenerated.Requirements\n\n-- Supply an ImplementationSpec here.\n")

def sessionRequiredResponse (request : String) : IO Response := do
  match sessionId? request with
  | some sessionId =>
      ensureSessionWorkspace sessionId
      pure <| response 200 "application/json; charset=utf-8"
        ("{\"session\":\"" ++ jsonEscape sessionId ++
          "\",\"workspace\":\"" ++ jsonEscape (sessionWorkspaceString sessionId) ++
          "\",\"files\":{\"requirementsLean\":\"/api/session/generated/requirements.lean\",\"requirementsProto\":\"/api/session/generated/requirements.proto\",\"implementationLean\":\"/api/session/generated/implementation.lean\"}}\n")
  | none =>
      pure <| response 401 "application/json; charset=utf-8" "{\"error\":\"missing session\"}\n"

def saveSessionArtifactResponse (sessionId path contentType body : String) : IO Response := do
  ensureSessionWorkspace sessionId
  IO.FS.writeFile (System.FilePath.mk path) body
  pure <| response 200 "application/json; charset=utf-8"
    ("{\"session\":\"" ++ jsonEscape sessionId ++
      "\",\"path\":\"" ++ jsonEscape path ++
      "\",\"contentType\":\"" ++ jsonEscape contentType ++
      "\",\"bytes\":" ++ toString body.toUTF8.size ++ "}\n")

def sessionGeneratedLeanResponse (request : String) : IO Response := do
  match sessionId? request with
  | none => pure <| response 401 "text/plain; charset=utf-8" "missing session\n"
  | some sessionId =>
      if requestMethod request == "POST" then
        saveSessionArtifactResponse sessionId (sessionGeneratedLeanString sessionId) "text/plain; charset=utf-8" (requestBody request)
      else
        ensureSessionWorkspace sessionId
        let body ← readTextOrElse (sessionGeneratedLeanPath sessionId) defaultGeneratedRequirementsLean
        pure <| response 200 "text/plain; charset=utf-8" body

def sessionGeneratedProtoResponse (request : String) : IO Response := do
  match sessionId? request with
  | none => pure <| response 401 "text/plain; charset=utf-8" "missing session\n"
  | some sessionId =>
      if requestMethod request == "POST" then
        saveSessionArtifactResponse sessionId (sessionGeneratedProtoString sessionId) "text/x-protobuf; charset=utf-8" (requestBody request)
      else
        ensureSessionWorkspace sessionId
        let body ← readTextOrElse (sessionGeneratedProtoPath sessionId) (pure LeanFM.LLMGenerated.Requirements.workerProtoFile)
        pure <| response 200 "text/x-protobuf; charset=utf-8" body

def sessionGeneratedImplementationResponse (request : String) : IO Response := do
  match sessionId? request with
  | none => pure <| response 401 "text/plain; charset=utf-8" "missing session\n"
  | some sessionId =>
      if requestMethod request == "POST" then
        saveSessionArtifactResponse sessionId (sessionGeneratedImplementationString sessionId) "text/plain; charset=utf-8" (requestBody request)
      else
        ensureSessionWorkspace sessionId
        let body ← readTextOrElse (sessionGeneratedImplementationPath sessionId) defaultGeneratedImplementationLean
        pure <| response 200 "text/plain; charset=utf-8" body

def responseBody (path : String) (request : String) : IO Response := do
  match path with
  | "/" => pure <| response 200 "text/html; charset=utf-8" LeanFM.htmlPage
  | "/examples" => pure <| response 200 "text/html; charset=utf-8" LeanFM.examplesPage
  | "/diagrams/" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "all")
  | "/renders/" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "all")
  | "/renders/auth" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "auth")
  | "/renders/worker" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "worker")
  | "/renders/get_docs" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "get_docs")
  | "/renders/post_review" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "post_review")
  | "/renders/tasks" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "tasks")
  | "/renders/assembled" => pure <| response 200 "text/html; charset=utf-8" (LeanFM.diagramRenderPage "assembled")
  | "/metrics" => pure <| response 200 "text/plain; version=0.0.4; charset=utf-8" LeanFM.prometheusMetrics
  | "/openapi.yaml" => pure <| response 200 "application/yaml; charset=utf-8" LeanFM.openApiYaml
  | "/report" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.textReport
  | "/tools/scenarios" => pure <| response 200 "application/json; charset=utf-8" LeanFM.scenarioCatalogJson
  | "/tools/protocol-sketches" => pure <| response 200 "application/json; charset=utf-8" LeanFM.protocolSketchCatalogJson
  | "/tools/conversations" => pure <| response 200 "application/json; charset=utf-8" LeanFM.conversationCatalogJson
  | "/tools/static-assets/validate" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.StaticAssets.validationReport
  | "/tools/generated-requirements/prompt" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.generatedRequirementSystemPrompt
  | "/tools/llm-generated/requirements/prompt" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.generatedRequirementSystemPrompt
  | "/tools/requirements/interrogation" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.requirementsInterrogationChecklist
  | "/tools/code-generation/prompt" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.codeGenerationSystemPrompt
  | "/tools/generated-requirements/validate" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.LLMGenerated.Requirements.validationReport
  | "/tools/llm-generated/requirements/validate" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.LLMGenerated.Requirements.validationReport
  | "/tools/llm-generated/implementation/validate" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.LLMGenerated.Implementation.validationReport
  | "/tools/generated-artifacts/validate" => pure <| response 200 "text/plain; charset=utf-8" (LeanFM.LLMGenerated.Requirements.validationReport ++ LeanFM.LLMGenerated.Implementation.validationReport)
  | "/tools/aggregate-graph/validate" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.aggregateGraphDataValidationReport
  | "/api/session" => sessionRequiredResponse request
  | "/api/session/files" => sessionRequiredResponse request
  | "/api/session/generated/requirements.lean" => sessionGeneratedLeanResponse request
  | "/api/session/generated/requirements.proto" => sessionGeneratedProtoResponse request
  | "/api/session/generated/implementation.lean" => sessionGeneratedImplementationResponse request
  | "/generated/worker.proto" => pure <| response 200 "text/x-protobuf; charset=utf-8" LeanFM.LLMGenerated.Requirements.workerProtoFile
  | "/llm-generated/requirements.proto" => pure <| response 200 "text/x-protobuf; charset=utf-8" LeanFM.LLMGenerated.Requirements.workerProtoFile
  | "/llm-generated/implementation.lean" => defaultGeneratedImplementationLean >>= fun body => pure <| response 200 "text/plain; charset=utf-8" body
  | "/api/llm" => callLLM (requestBody request)
  | "/lean/auth.lean" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.authLeanFile
  | "/lean/get_docs.lean" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.getDocsLeanFile
  | "/lean/post_review.lean" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.postReviewLeanFile
  | "/lean/worker.lean" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.workerLeanFile
  | "/lean/assembled.lean" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.assembledLeanFile
  | "/lean/sketch/kerberos.lean" => pure <| response 200 "text/plain; charset=utf-8" LeanFM.kerberosLeanSketch
  | "/docs/" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.docsIndex
  | "/docs/index.md" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.docsIndex
  | "/docs/auth.md" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.authDoc
  | "/docs/worker.md" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.workerDoc
  | "/docs/get_docs.md" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.getDocsDoc
  | "/docs/post_review.md" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.postReviewDoc
  | "/docs/assembled.md" => pure <| response 200 "text/markdown; charset=utf-8" LeanFM.assembledDoc
  | "/graph.dot" => pure <| response 200 "text/vnd.graphviz; charset=utf-8" LeanFM.groupedGraphDot
  | "/auth.dot" => pure <| response 200 "text/vnd.graphviz; charset=utf-8" LeanFM.authGraphDot
  | "/get_docs.dot" => pure <| response 200 "text/vnd.graphviz; charset=utf-8" LeanFM.getDocsGraphDot
  | "/post_review.dot" => pure <| response 200 "text/vnd.graphviz; charset=utf-8" LeanFM.postReviewGraphDot
  | "/tasks.dot" => pure <| response 200 "text/vnd.graphviz; charset=utf-8" LeanFM.taskGraphDot
  | "/assembled.dot" => pure <| response 200 "text/vnd.graphviz; charset=utf-8" LeanFM.assembledGraphDot
  | "/health" => pure <| response 200 "text/plain; charset=utf-8" "ok\n"
  | _ => pure <| response 404 "text/plain; charset=utf-8" "not found\n"

def configuredPassword : IO String := do
  match (← IO.getEnv "LEANFM_PASSWORD") with
  | some password => pure password
  | none => pure "leanfm"

def redirectResponse (location : String) (headers : List String := []) : Response :=
  response 303 "text/plain; charset=utf-8" "see other\n" (("Location: " ++ location) :: headers)

def responseForRequest (request : String) : IO Response := do
  let path := requestPath request
  if path == "/health" then
    responseBody path request
  else if path == "/login" then
    if requestMethod request == "POST" then
      let password ← configuredPassword
      if (requestBody request).contains ("password=" ++ password) then
        let sessionId ← newSessionId
        ensureSessionWorkspace sessionId
        pure <| redirectResponse "/" ["Set-Cookie: leanfm_session=" ++ sessionId ++ "; Path=/; HttpOnly; SameSite=Lax"]
      else
        pure <| response 403 "text/html; charset=utf-8" loginPage
    else
      pure <| response 200 "text/html; charset=utf-8" loginPage
  else if hasSession request then
    responseBody path request
  else
    pure <| redirectResponse "/login"

def statusText : Nat -> String
  | 200 => "OK"
  | 303 => "See Other"
  | 403 => "Forbidden"
  | 401 => "Unauthorized"
  | 404 => "Not Found"
  | 502 => "Bad Gateway"
  | 503 => "Service Unavailable"
  | _ => "OK"

def httpHeader (status : Nat) (contentType : String) (body : ByteArray) (extraHeaders : List String := []) : String :=
  "HTTP/1.1 " ++ toString status ++ " " ++ statusText status ++ "\r\n" ++
  "Content-Type: " ++ contentType ++ "\r\n" ++
  "Content-Length: " ++ toString body.size ++ "\r\n" ++
  "Cache-Control: no-store\r\n" ++
  "X-Content-Type-Options: nosniff\r\n" ++
  (String.join (extraHeaders.map fun h => h ++ "\r\n")) ++
  "Connection: close\r\n\r\n"

def handleClient (client : TcpClient) : IO Unit := do
  let requestBytes? ← (client.recv? 1048576).block
  let request :=
    match requestBytes? with
    | some bytes => String.fromUTF8! bytes
    | none => ""
  let res ← responseForRequest request
  (client.sendAll #[(httpHeader res.status res.contentType res.body res.headers).toUTF8, res.body]).block

partial def serveLoop (server : TcpServer) : IO Unit := do
  let client ← (server.accept).block
  try
    handleClient client
  catch err =>
    IO.eprintln s!"request failed: {err}"
  serveLoop server

def main : IO Unit := do
  let server ← Std.Internal.IO.Async.TCP.Socket.Server.mk
  server.bind bindAddr
  server.listen 128
  IO.println "LeanFM server listening on http://127.0.0.1:8080"
  serveLoop server

end LeanFM.Server

def main : IO Unit :=
  LeanFM.Server.main
