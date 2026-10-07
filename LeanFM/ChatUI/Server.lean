import LeanFM.ChatUI.Provider
import LeanFM.ChatUI.Web

namespace LeanFM.ChatUI.Server

open LeanFM.ChatUI
open LeanFM.ChatUI.Store

structure HttpResponse where
  status : Nat
  contentType : String
  body : String
  headers : List String := []

def jsonResponse (status : Nat) (body : String) (headers : List String := []) : HttpResponse :=
  { status, contentType := "application/json; charset=utf-8", body, headers }

def errorResponse (status : Nat) (message : String) : HttpResponse :=
  jsonResponse status ("{\"error\":\"" ++ jsonEscape message ++ "\"}\n")

def requestBody (request : String) : String :=
  match request.splitOn "\r\n\r\n" with | _ :: body :: _ => body | _ => ""

def sessionUser? (request : String) : IO (Option String) := do
  match cookieValue? request "leanfm_session" with
  | none => pure none
  | some token => userForSession? token

def credentialKey (username : String) : IO (Except String String) := do
  let root ← accountRoot username
  let encoded ← readOr (root ++ "/credentials/default.b64") ""
  if encoded.trim.isEmpty then return .error "No user API key is configured."
  try pure (.ok (← base64Decode encoded.trim))
  catch _ => pure (.error "The stored API key is invalid.")

def authorizedProjectRoot? (username projectId : String) : IO (Option String) := do
  if !safeId projectId then return none
  let root ← projectRoot username projectId
  if ← (fp (root ++ "/manifest.json")).pathExists then pure (some root) else pure none

def pathSegments (path : String) : List String := path.splitOn "/" |>.filter (!·.isEmpty)

def tasksJson : String :=
  let items := Requirements.spec.tasks.map fun task =>
    let constraints := Requirements.taskConstraints.filter (·.task == task.id) |>.map (fun item => "\"" ++ jsonEscape item.predicate ++ "\"")
    "{\"id\":\"" ++ jsonEscape task.id ++ "\",\"title\":\"" ++ jsonEscape task.title ++
    "\",\"interaction_mermaid\":\"" ++ jsonEscape (Requirements.interactionMermaid task) ++
    "\",\"state_mermaid\":\"" ++ jsonEscape (Requirements.stateMachineMermaid task) ++
    "\",\"constraints\":[" ++ String.intercalate "," constraints ++ "]}"
  "[" ++ String.intercalate "," items ++ "]"

def appendConversation (root role text : String) (usage : Option Provider.Completion := none) : IO Unit := do
  let path := root ++ "/conversations/main.log"
  let old ← readOr path ""
  let usageFields := match usage with
    | none => "0|0|0|0"
    | some u => s!"{u.inputTokens}|{u.cachedInputTokens}|{u.outputTokens}|{u.totalTokens}"
  writeAtomic path (old ++ role ++ "|" ++ base64Encode text ++ "|" ++ usageFields ++ "\n")

def conversationContext (root : String) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let mut turns : List String := []
  for line in body.splitOn "\n" do
    match line.splitOn "|" with
    | role :: encoded :: _ =>
        try turns := (role ++ ": " ++ (← base64Decode encoded)) :: turns catch _ => pure ()
    | _ => pure ()
  pure (String.intercalate "\n\n" ((turns.take 24).reverse))

def conversationJson (root : String) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let contextWindow := (← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS").getD "128000"
  let mut messages : List String := []
  for line in body.splitOn "\n" do
    match line.splitOn "|" with
    | [role, encoded, input, cached, output, total] =>
        try
          let text ← base64Decode encoded
          let usage := if role == "assistant" then
              ",\"usage\":{\"input_tokens\":" ++ input ++ ",\"cached_input_tokens\":" ++ cached ++
              ",\"output_tokens\":" ++ output ++ ",\"total_tokens\":" ++ total ++ ",\"context_window_tokens\":" ++
              contextWindow ++ "}"
            else ""
          messages := ("{\"role\":\"" ++ role ++ "\",\"text\":\"" ++ jsonEscape text ++ "\"" ++ usage ++ "}") :: messages
        catch _ => pure ()
    | _ => pure ()
  pure ("{\"messages\":[" ++ String.intercalate "," messages.reverse ++ "]}\n")

def artifactListJson (root : String) : IO String := do
  let mut artifacts : List String := []
  for entry in (← entries (root ++ "/artifacts")) do
    if entry.fileName.endsWith ".mermaid" then
      let id := (entry.fileName.dropEnd ".mermaid".length).toString
      artifacts := ("{\"artifact_id\":\"" ++ jsonEscape id ++ "\",\"title\":\"" ++ jsonEscape id ++
        "\",\"kind\":\"mermaid\",\"status\":\"current\",\"revision\":1}") :: artifacts
  pure ("{\"artifacts\":[" ++ String.intercalate "," artifacts.reverse ++ "]}\n")

def saveMermaidArtifacts (root responseText : String) : IO Unit := do
  let chunks := responseText.splitOn "```mermaid"
  match chunks with
  | _ :: diagram :: _ =>
      let source := (diagram.splitOn "```").headD ""
      if !source.trim.isEmpty then
        let id ← randomHex 8
        writeAtomic (root ++ "/artifacts/" ++ id ++ ".mermaid") source.trim
  | _ => pure ()

def handlePublic (path method request : String) : IO (Option HttpResponse) := do
  if path == "/" && method == "GET" then
    return some { status := 200, contentType := "text/html; charset=utf-8", body := Web.page }
  if path == "/assets/chatui.css" then
    return some { status := 200, contentType := "text/css; charset=utf-8", body := Web.css }
  if path == "/assets/chatui.js" then
    return some { status := 200, contentType := "application/javascript; charset=utf-8", body := Web.javascript }
  if path == "/api/accounts" && method == "POST" then
    let body := requestBody request
    let username := (formValue? body "username").getD ""
    let password := (formValue? body "password").getD ""
    let provider := (formValue? body "provider").getD "openai"
    let apiKey := (formValue? body "api_key").getD ""
    if provider != "openai" then return some (errorResponse 400 "Only the OpenAI provider is currently supported.")
    match ← Provider.verifyKey apiKey with
    | .error message => return some (errorResponse 403 message)
    | .ok _ =>
        match ← createAccount username password provider apiKey with
        | .error message => return some (errorResponse 400 message)
        | .ok _ =>
            match ← login username password with
            | .error message => return some (errorResponse 500 message)
            | .ok token => return some (jsonResponse 201 ("{\"username\":\"" ++ jsonEscape username ++ "\"}\n")
                ["Set-Cookie: leanfm_session=" ++ token ++ "; Path=/; HttpOnly; SameSite=Strict"])
  if path == "/api/login" && method == "POST" then
    let body := requestBody request
    let username := (formValue? body "username").getD ""
    let password := (formValue? body "password").getD ""
    match ← login username password with
    | .error message => return some (errorResponse 403 message)
    | .ok token => return some (jsonResponse 200 ("{\"username\":\"" ++ jsonEscape username ++ "\"}\n")
        ["Set-Cookie: leanfm_session=" ++ token ++ "; Path=/; HttpOnly; SameSite=Strict"])
  pure none

def handleAuthenticated (username path method request : String) : IO (Option HttpResponse) := do
  if path == "/api/me" then return some (jsonResponse 200 ("{\"username\":\"" ++ jsonEscape username ++ "\"}\n"))
  if path == "/api/projects" && method == "GET" then
    return some (jsonResponse 200 ("{\"projects\":" ++ (← projectListJson username) ++ "}\n"))
  if path == "/api/projects" && method == "POST" then
    let name := (formValue? (requestBody request) "display_name").getD ""
    if name.trim.isEmpty then return some (errorResponse 400 "Project name is required.")
    match ← createProject username name.trim with
    | .error message => return some (errorResponse 400 message)
    | .ok projectId => return some (jsonResponse 201 ("{\"project_id\":\"" ++ projectId ++ "\"}\n"))
  match pathSegments path with
  | "api" :: "projects" :: projectId :: rest =>
      match ← authorizedProjectRoot? username projectId with
      | none => return some (errorResponse 404 "Project not found.")
      | some root =>
          match rest, method with
          | ["conversation"], "GET" => return some (jsonResponse 200 (← conversationJson root))
          | ["tasks"], "GET" => return some (jsonResponse 200 ("{\"tasks\":" ++ tasksJson ++ "}\n"))
          | ["artifacts"], "GET" => return some (jsonResponse 200 (← artifactListJson root))
          | ["chat"], "POST" =>
              let prompt := (formValue? (requestBody request) "prompt").getD ""
              if prompt.trim.isEmpty then return some (errorResponse 400 "A prompt is required.")
              match ← credentialKey username with
              | .error message => return some (errorResponse 409 message)
              | .ok key =>
                  let prior ← conversationContext root
                  let contextualPrompt := if prior.isEmpty then prompt else
                    "Project conversation so far:\n\n" ++ prior ++ "\n\nCurrent user message:\n" ++ prompt
                  appendConversation root "user" prompt
                  match ← Provider.complete key contextualPrompt with
                  | .error message => return some (errorResponse 502 message)
                  | .ok answer =>
                      appendConversation root "assistant" answer.text (some answer)
                      saveMermaidArtifacts root answer.text
                      let context := (← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS").getD "128000"
                      return some (jsonResponse 200 ("{\"text\":\"" ++ jsonEscape answer.text ++ "\",\"usage\":{\"input_tokens\":" ++
                        toString answer.inputTokens ++ ",\"cached_input_tokens\":" ++ toString answer.cachedInputTokens ++
                        ",\"output_tokens\":" ++ toString answer.outputTokens ++ ",\"total_tokens\":" ++ toString answer.totalTokens ++
                        ",\"context_window_tokens\":" ++ context ++ "}}\n"))
          | _, _ => pure ()
  | _ => pure ()
  pure none

def handle? (path method request : String) : IO (Option HttpResponse) := do
  match ← handlePublic path method request with
  | some response => pure (some response)
  | none =>
      if path.startsWith "/api/" then
        match ← sessionUser? request with
        | none => pure (some (errorResponse 401 "Authentication required."))
        | some username => handleAuthenticated username path method request
      else pure none

end LeanFM.ChatUI.Server
