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

def credentialKey (username request : String) : IO (Except String String) := do
  match cookieValue? request "leanfm_session" with
  | none => pure (.error "Password login is required to unlock the API key.")
  | some token =>
      match ← sessionCredential? token username with
      | none => pure (.error "Password login is required to unlock the API key.")
      | some key => pure (.ok key)

def authorizedProjectRoot? (username projectId : String) : IO (Option String) := do
  if projectId == "leanfm-workspace" then
    if ← (fp "book/main.pdf").pathExists then return some "." else return none
  if !safeId projectId then return none
  let root ← projectRoot username projectId
  if ← (fp (root ++ "/manifest.json")).pathExists then pure (some root) else pure none

def pathSegments (path : String) : List String := path.splitOn "/" |>.filter (!·.isEmpty)

def jsonStrings (values : List String) : String :=
  "[" ++ String.intercalate "," (values.map fun value => "\"" ++ jsonEscape value ++ "\"") ++ "]"

partial def grammarExprJson : GrammarExpr -> String
  | .empty => "{\"kind\":\"empty\"}"
  | .event atom =>
      "{\"kind\":\"event\",\"task\":\"" ++ jsonEscape atom.task ++
      "\",\"src\":\"" ++ jsonEscape atom.src ++ "\",\"dst\":\"" ++ jsonEscape atom.dst ++
      "\",\"message\":\"" ++ jsonEscape atom.message ++ "\"}"
  | .seq left right =>
      "{\"kind\":\"seq\",\"children\":[" ++ grammarExprJson left ++ "," ++ grammarExprJson right ++ "]}"
  | .choice branches =>
      "{\"kind\":\"choice\",\"children\":[" ++ String.intercalate "," (branches.map grammarExprJson) ++ "]}"
  | .parallel left right =>
      "{\"kind\":\"parallel\",\"children\":[" ++ grammarExprJson left ++ "," ++ grammarExprJson right ++ "]}"
  | .thresholdJoin required branches =>
      "{\"kind\":\"thresholdJoin\",\"required\":" ++ toString required ++
      ",\"children\":[" ++ String.intercalate "," (branches.map grammarExprJson) ++ "]}"
  | .guard predicate body =>
      "{\"kind\":\"guard\",\"predicate\":\"" ++ jsonEscape predicate ++
      "\",\"children\":[" ++ grammarExprJson body ++ "]}"
  | .ref task => "{\"kind\":\"ref\",\"task\":\"" ++ jsonEscape task ++ "\"}"
  | .repeat body => "{\"kind\":\"repeat\",\"children\":[" ++ grammarExprJson body ++ "]}"

def tasksJson (source : String) : String :=
  let items := Requirements.spec.tasks.map fun task =>
    let constraints := Requirements.taskConstraints.filter (·.task == task.id) |>.map (·.predicate)
    let properties := Requirements.spec.properties.filter (·.task == task.id) |>.map fun property =>
      "{\"name\":\"" ++ jsonEscape property.name ++ "\",\"mode\":\"" ++
      jsonEscape (propertyModeName property.mode) ++ "\",\"expression\":\"" ++
      jsonEscape property.expression ++ "\"}"
    let states := task.states.map fun state =>
      "{\"id\":\"" ++ jsonEscape state.id ++ "\",\"label\":\"" ++ jsonEscape state.label ++
      "\",\"group\":\"" ++ jsonEscape state.group ++ "\",\"terminal\":" ++
      (if state.terminal then "true" else "false") ++ "}"
    let transitions := task.transitions.map fun transition =>
      let schema? := Requirements.messages.find? (·.name == transition.message)
      let src := schema?.map (·.src) |>.getD "Actor"
      let dst := schema?.map (·.dst) |>.getD "Actor"
      let fields := schema?.map (fun schema => schema.fields.map fun field =>
        "{\"number\":" ++ toString field.number ++ ",\"name\":\"" ++ jsonEscape field.name ++
        "\",\"type\":\"" ++ jsonEscape field.scalar.protoName ++ "\"}") |>.getD []
      "{\"src\":\"" ++ jsonEscape transition.src ++ "\",\"dst\":\"" ++
      jsonEscape transition.dst ++ "\",\"message\":\"" ++ jsonEscape transition.message ++
      "\",\"source_actor\":\"" ++ jsonEscape src ++ "\",\"destination_actor\":\"" ++
      jsonEscape dst ++ "\",\"probability\":\"" ++ toString transition.probabilityNum ++ "/" ++
      toString transition.probabilityDen ++ "\",\"dwell_ms\":" ++ toString transition.dwellMs ++
      ",\"fields\":[" ++ String.intercalate "," fields ++ "]}"
    let grammar? := Requirements.spec.grammars.find? (·.task == task.id)
    let entry := grammar?.map (·.entry) |>.getD task.initialState
    let terminals := grammar?.map (·.terminals) |>.getD []
    "{\"id\":\"" ++ jsonEscape task.id ++ "\",\"title\":\"" ++ jsonEscape task.title ++
    "\",\"entry\":\"" ++ jsonEscape entry ++ "\",\"terminals\":" ++ jsonStrings terminals ++
    ",\"actors\":" ++ jsonStrings task.actors ++ ",\"states\":[" ++ String.intercalate "," states ++
    "],\"transitions\":[" ++ String.intercalate "," transitions ++
    "],\"grammar\":" ++ (grammar?.map (fun grammar => grammarExprJson grammar.body) |>.getD "null") ++
    ",\"properties\":[" ++ String.intercalate "," properties ++
    "],\"interaction_mermaid\":\"" ++ jsonEscape (Requirements.interactionMermaid task) ++
    "\",\"state_mermaid\":\"" ++ jsonEscape (Requirements.stateMachineMermaid task) ++
    "\",\"constraints\":" ++ jsonStrings constraints ++ "}"
  "{\"source\":\"" ++ jsonEscape source ++ "\",\"validation\":{\"errors\":0,\"warnings\":0},\"tasks\":[" ++
    String.intercalate "," items ++ "]}"

def appendConversation (root role text : String) (usage : Option Provider.Completion := none) : IO Unit := do
  let path := root ++ "/conversations/main.log"
  let old ← readOr path ""
  let messageId ← randomHex 12
  let usageFields := match usage with
    | none => "0|0|0|0"
    | some u => s!"{u.inputTokens}|{u.cachedInputTokens}|{u.outputTokens}|{u.totalTokens}"
  writeAtomic path (old ++ messageId ++ "|" ++ role ++ "|" ++ base64Encode text ++ "|" ++ usageFields ++ "\n")

def conversationContext (root : String) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let mut turns : List String := []
  for line in body.splitOn "\n" do
    match line.splitOn "|" with
    | [_messageId, role, encoded, _input, _cached, _output, _total] =>
        try turns := (role ++ ": " ++ (← base64Decode encoded)) :: turns catch _ => pure ()
    | [role, encoded, _input, _cached, _output, _total] =>
        try turns := (role ++ ": " ++ (← base64Decode encoded)) :: turns catch _ => pure ()
    | _ => pure ()
  pure (String.intercalate "\n\n" ((turns.take 24).reverse))

def conversationJson (root : String) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let contextWindow := (← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS").getD "128000"
  let mut messages : List String := []
  let mut lineNumber := 0
  for line in body.splitOn "\n" do
    let legacyId := "legacy-" ++ toString lineNumber
    match line.splitOn "|" with
    | [messageId, role, encoded, input, cached, output, total] =>
        try
          let text ← base64Decode encoded
          let usage := if role == "assistant" then
              ",\"usage\":{\"input_tokens\":" ++ input ++ ",\"cached_input_tokens\":" ++ cached ++
              ",\"output_tokens\":" ++ output ++ ",\"total_tokens\":" ++ total ++ ",\"context_window_tokens\":" ++
              contextWindow ++ "}"
            else ""
          messages := ("{\"message_id\":\"" ++ jsonEscape messageId ++ "\",\"role\":\"" ++ role ++ "\",\"text\":\"" ++ jsonEscape text ++ "\"" ++ usage ++ "}") :: messages
        catch _ => pure ()
    | [role, encoded, input, cached, output, total] =>
        try
          let text ← base64Decode encoded
          let usage := if role == "assistant" then
              ",\"usage\":{\"input_tokens\":" ++ input ++ ",\"cached_input_tokens\":" ++ cached ++
              ",\"output_tokens\":" ++ output ++ ",\"total_tokens\":" ++ total ++ ",\"context_window_tokens\":" ++
              contextWindow ++ "}"
            else ""
          messages := ("{\"message_id\":\"" ++ legacyId ++ "\",\"role\":\"" ++ role ++ "\",\"text\":\"" ++ jsonEscape text ++ "\"" ++ usage ++ "}") :: messages
        catch _ => pure ()
    | _ => pure ()
    lineNumber := lineNumber + 1
  pure ("{\"messages\":[" ++ String.intercalate "," messages.reverse ++ "]}\n")

def deleteConversationMessage (root messageId : String) : IO Bool := do
  let path := root ++ "/conversations/main.log"
  let body ← readOr path ""
  let mut kept : List String := []
  let mut found := false
  let mut lineNumber := 0
  for line in body.splitOn "\n" do
    if !line.isEmpty then
      let storedId := match line.splitOn "|" with
        | id :: _role :: _encoded :: _input :: _cached :: _output :: _total :: [] => id
        | _ => "legacy-" ++ toString lineNumber
      if storedId == messageId then found := true else kept := line :: kept
    lineNumber := lineNumber + 1
  if found then writeAtomic path (String.intercalate "\n" kept.reverse ++ if kept.isEmpty then "" else "\n")
  pure found

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
    return some (HttpResponse.mk 200 "text/html; charset=utf-8" Web.page ["Cache-Control: no-store"])
  if path == "/assets/chatui.css" || path == "/assets/chatui-20261016.css" || path == "/assets/chatui-20261016b.css" || path == "/assets/chatui-20261016c.css" || path == "/assets/chatui-20261016d.css" || path == "/assets/chatui-20261016e.css" || path == "/assets/chatui-20261016f.css" || path == "/assets/chatui-20261016g.css" then
    return some (HttpResponse.mk 200 "text/css; charset=utf-8" Web.css ["Cache-Control: no-store"])
  if path == "/assets/chatui.js" || path == "/assets/chatui-20261016.js" || path == "/assets/chatui-20261016b.js" || path == "/assets/chatui-20261016c.js" || path == "/assets/chatui-20261016d.js" || path == "/assets/chatui-20261016e.js" || path == "/assets/chatui-20261016f.js" || path == "/assets/chatui-20261016g.js" then
    return some (HttpResponse.mk 200 "application/javascript; charset=utf-8" Web.javascript ["Cache-Control: no-store"])
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
          if rest.isEmpty && method == "DELETE" then
            if projectId == "leanfm-workspace" then
              return some (errorResponse 403 "The LeanFM workspace project is read-only and cannot be deleted.")
            let confirmation := (formValue? (requestBody request) "confirmation").getD ""
            match ← deleteProject username projectId confirmation with
            | .error message => return some (errorResponse 400 message)
            | .ok _ => return some (jsonResponse 200 ("{\"deleted_project_id\":\"" ++ jsonEscape projectId ++ "\"}\n"))
          match rest, method with
          | ["conversation"], "GET" => return some (jsonResponse 200 (← conversationJson root))
          | ["conversation", "messages", messageId], "DELETE" =>
              if ← deleteConversationMessage root messageId then
                return some (jsonResponse 200 ("{\"deleted_message_id\":\"" ++ jsonEscape messageId ++ "\"}\n"))
              else return some (errorResponse 404 "Message not found.")
          | ["tasks"], "GET" =>
              let source := if projectId == "leanfm-workspace" then "LeanFM/ChatUI/Requirements.lean (live workspace)"
                else root ++ "/spec/Requirements.lean"
              return some (jsonResponse 200 (tasksJson source ++ "\n"))
          | ["artifacts"], "GET" => return some (jsonResponse 200 (← artifactListJson root))
          | ["chat"], "POST" =>
              if projectId == "leanfm-workspace" then
                return some (errorResponse 403 "The LeanFM workspace project is read-only.")
              let prompt := (formValue? (requestBody request) "prompt").getD ""
              if prompt.trim.isEmpty then return some (errorResponse 400 "A prompt is required.")
              match ← credentialKey username request with
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
