import LeanFM.ChatUI.Provider
import LeanFM.ChatUI.Web
import LeanFM.LLMGenerated.SharedProjects
import Std.Time

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

def errorAction (status : Nat) : String :=
  if status == 400 then "Correct the highlighted input and try again. If it already looks valid, copy the diagnostic and report it to Codex."
  else if status == 401 then "Sign in again, then retry the operation."
  else if status == 403 then "Use an editable project or an account authorized for this project."
  else if status == 404 then "Refresh the project list and verify that the selected project or file still exists."
  else if status == 409 then "Sign in with your password to unlock the API key, then retry."
  else if status == 413 then "Reduce the submitted file or text below the displayed size limit, then retry."
  else if status == 415 then "Convert the file to UTF-8 text, then retry."
  else if status == 422 then "Open the displayed compiler or validation diagnostic, correct that source, and retry."
  else if status >= 500 then "Retry once. If it fails again, copy the diagnostic below to Codex and include what you were doing; restarting the LeanFM server may recover a stale local process."
  else "Retry the operation. If it fails again, copy the diagnostic below to Codex."

def errorResponse (status : Nat) (message : String) : HttpResponse :=
  let localBudget := message.contains "local session token safety budget is exhausted"
  let action := if localBudget then
    "Review provider billing and usage before unlocking another local session. This local token safety limit does not report any provider credit balance."
    else errorAction status
  let code := if localBudget then "leanfm_session_token_budget_exhausted"
    else "leanfm_http_" ++ toString status
  jsonResponse status ("{\"error\":\"" ++ jsonEscape message ++
    "\",\"action\":\"" ++ jsonEscape action ++
    "\",\"code\":\"" ++ code ++ "\"}\n")

def requestBody (request : String) : String :=
  match request.splitOn "\r\n\r\n" with | _ :: body :: _ => body | _ => ""

def sessionUser? (request : String) : IO (Option String) := do
  match ← requestSessionToken? request with
  | none => pure none
  | some token => userForSession? token

def credentialKey (username request : String) (provider : String := "openai") : IO (Except String String) := do
  match ← requestSessionToken? request with
  | none => pure (.error "Password login is required to unlock the API key.")
  | some token =>
      match ← sessionBilling? token username with
      | none => pure (.error "Password login is required to unlock the API key.")
      | some billing =>
          if billing.tokensUsed >= billing.tokenBudget then
            pure (.error "The local session token safety budget is exhausted. Log in again only after reviewing the provider project's dollar spend limit and usage.")
          else match ← sessionCredential? token username provider with
            | none => pure (.error ("No unlocked " ++ Provider.providerName provider ++ " key is available. Open API keys and unlock that provider with your account password."))
            | some key => pure (.ok key)

def validModelId (model : String) : Bool :=
  !model.isEmpty && model.length ≤ 128 && model.toList.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.' || c == ':'

structure ModelSnapshot where
  cacheKey : String
  models : List Provider.ModelInfo
  warning : String := ""

initialize discoveredModels : IO.Ref (List ModelSnapshot) ← IO.mkRef []

def responseModelCandidate (model : String) : Bool :=
  let lower := model.toLower
  validModelId model &&
    !model.startsWith "anthropic:" &&
    !(model.startsWith "ft:") &&
    !["embedding", "moderation", "whisper", "transcribe", "tts", "realtime", "audio", "image", "dall-e", "search"].any
      (fun fragment => lower.contains fragment)

def uniqueModels (models : List String) : List String :=
  models.foldl (fun found model => if found.contains model then found else found ++ [model]) []

def providerModelSnapshot (credential : UnlockedCredential) : IO ModelSnapshot := do
  let cacheKey := credential.provider ++ ":" ++ credential.fingerprint
  if let some snapshot := (← discoveredModels.get).find? (·.cacheKey == cacheKey) then return snapshot
  let discovered ← Provider.listedModelInfos credential.apiKey credential.provider
  let (available, warning) : List Provider.ModelInfo × String := match discovered with
    | .ok models => (models.filter (fun model =>
        if credential.provider == "openai" then responseModelCandidate model.model else validModelId model.model), "")
    | .error message => ([], message)
  let configured ← IO.getEnv (if credential.provider == "openai" then "LEANFM_LLM_MODELS" else "LEANFM_ANTHROPIC_MODELS")
  let preferred ← if credential.provider == "openai" then
      pure ((← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini")
    else pure ((← IO.getEnv "LEANFM_ANTHROPIC_MODEL").getD "")
  let declared : List String := match configured with
    | some value => value.splitOn "," |>.map (fun (name : String) => name.trimAscii.toString) |>.filter validModelId
    | none => available.map (·.model)
  let names := uniqueModels ((if preferred.isEmpty then [] else [preferred]) ++ declared)
  let models : List Provider.ModelInfo := (names.filterMap fun model => do
    guard (validModelId model && !model.startsWith "anthropic:")
    pure ((available.find? (·.model == model)).getD
      { id := if credential.provider == "anthropic" then "anthropic:" ++ model else model
      , model, provider := credential.provider, label := model })) |>.take 80
  let snapshot := { cacheKey, models, warning : ModelSnapshot }
  discoveredModels.modify (fun snapshots => snapshot :: snapshots.take 255)
  return snapshot

def configuredModelOptions (credentials : List UnlockedCredential) : IO (List Provider.ModelInfo) := do
  let mut models := []
  for provider in ["openai", "anthropic"] do
    if let some credential := credentials.find? (·.provider == provider) then
      models := models ++ (← providerModelSnapshot credential).models
  return models

def billingJson (username request : String) : IO String := do
  match ← requestSessionToken? request with
  | none => pure "null"
  | some token =>
      match ← sessionBilling? token username with
      | none => pure "null"
      | some billing =>
          let credentials ← sessionCredentials token username
          let models ← configuredModelOptions credentials
          let model := models.head?.map (·.id) |>.getD ""
          let metadata := models.map fun info =>
            let credential := credentials.find? (·.provider == info.provider)
            Lean.Json.mkObj [("id", Lean.toJson info.id), ("model", Lean.toJson info.model),
              ("label", Lean.toJson info.label), ("provider", Lean.toJson info.provider),
              ("credential_ref", Lean.toJson ((credential.map (·.credentialRef)).getD "")),
              ("key_fingerprint", Lean.toJson ((credential.map (·.fingerprint)).getD "")),
              ("context_window_tokens", Lean.toJson info.contextWindowTokens)]
          let warnings := (← discoveredModels.get).filterMap fun snapshot =>
            if !snapshot.warning.isEmpty && credentials.any (fun credential =>
                snapshot.cacheKey == credential.provider ++ ":" ++ credential.fingerprint) then some snapshot.warning else none
          let remaining := billing.tokenBudget - billing.tokensUsed
          pure ("{\"provider\":\"" ++ jsonEscape billing.provider ++
            "\",\"credential_ref\":\"" ++ jsonEscape billing.credentialRef ++
            "\",\"key_fingerprint\":\"" ++ jsonEscape billing.credentialFingerprint ++
            "\",\"model\":\"" ++ jsonEscape model ++ "\",\"models\":" ++ (Lean.toJson (models.map (·.id))).compress ++
            ",\"model_details\":" ++ (Lean.toJson metadata).compress ++
            ",\"model_warnings\":" ++ (Lean.toJson warnings).compress ++
            ",\"tokens_used\":" ++ toString billing.tokensUsed ++
            ",\"token_budget\":" ++ toString billing.tokenBudget ++
            ",\"tokens_remaining\":" ++ toString remaining ++ "}")

def authorizedProjectRoot? (username projectId : String) : IO (Option String) := do
  if projectId == "leanfm-workspace" then
    -- A generated PDF may be absent while the book is rebuilding or after a
    -- failed LaTeX pass.  The checked-in project's identity must therefore
    -- depend on stable source markers, not on a disposable build output.
    if (← (fp "lakefile.toml").pathExists) &&
        (← (fp "LeanFM/LLMGenerated/Requirements.lean").pathExists) &&
        (← (fp "book/main.tex").pathExists) then
      return some "."
    else return none
  if !safeId projectId then return none
  let _ := username
  let out ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["workspace-resolve", ← workspaceRoot, projectId]}
  if out.exitCode == 0 then pure (some out.stdout.trimAscii.toString) else pure none

def pathSegments (path : String) : List String := path.splitOn "/" |>.filter (!·.isEmpty)

def jsonStrings (values : List String) : String :=
  "[" ++ String.intercalate "," (values.map fun value => "\"" ++ jsonEscape value ++ "\"") ++ "]"

def ctlAtom (expression : String) : String :=
  "atom(\"" ++ expression ++ "\")"

def propertyCtlFormula (mode : PropertyMode) (expression : String) : String :=
  match mode with
  | .always => "AG " ++ ctlAtom expression
  | .eventually => "AF " ++ ctlAtom expression
  | .never => "AG ¬" ++ ctlAtom expression
  | .preparedFor => "EF " ++ ctlAtom expression

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

def tasksJson (source : String) (requirements : RequirementSpec := Requirements.spec)
    (taskConstraints : List Requirements.TaskConstraint := []) : String :=
  let items := requirements.tasks.map fun task =>
    let constraints := taskConstraints.filter (·.task == task.id) |>.map fun constraint =>
      "{\"id\":\"" ++ jsonEscape constraint.id ++ "\",\"predicate\":\"" ++
      jsonEscape constraint.predicate ++ "\",\"formula\":\"" ++
      jsonEscape (propertyCtlFormula .always constraint.predicate) ++
      "\",\"origin\":\"Requirements.lean where_\"}"
    let properties := requirements.properties.filter (·.task == task.id) |>.map fun property =>
      "{\"name\":\"" ++ jsonEscape property.name ++ "\",\"mode\":\"" ++
      jsonEscape (propertyModeName property.mode) ++ "\",\"expression\":\"" ++
      jsonEscape property.expression ++ "\",\"formula\":\"" ++
      jsonEscape (propertyCtlFormula property.mode property.expression) ++
      "\",\"origin\":\"Requirements.lean property\"}"
    let states := task.states.map fun state =>
      "{\"id\":\"" ++ jsonEscape state.id ++ "\",\"label\":\"" ++ jsonEscape state.label ++
      "\",\"group\":\"" ++ jsonEscape state.group ++ "\",\"terminal\":" ++
      (if state.terminal then "true" else "false") ++ "}"
    let transitions := task.transitions.map fun transition =>
      let schema? := requirements.messages.find? (·.name == transition.message)
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
    let grammar? := requirements.grammars.find? (·.task == task.id)
    let entry := grammar?.map (·.entry) |>.getD task.initialState
    let terminals := grammar?.map (·.terminals) |>.getD []
    "{\"id\":\"" ++ jsonEscape task.id ++ "\",\"title\":\"" ++ jsonEscape task.title ++
    "\",\"entry\":\"" ++ jsonEscape entry ++ "\",\"terminals\":" ++ jsonStrings terminals ++
    ",\"actors\":" ++ jsonStrings task.actors ++ ",\"states\":[" ++ String.intercalate "," states ++
    "],\"transitions\":[" ++ String.intercalate "," transitions ++
    "],\"grammar\":" ++ (grammar?.map (fun grammar => grammarExprJson grammar.body) |>.getD "null") ++
    ",\"properties\":[" ++ String.intercalate "," properties ++
    "],\"interaction_mermaid\":\"" ++ jsonEscape (Requirements.interactionMermaid task requirements) ++
    "\",\"state_mermaid\":\"" ++ jsonEscape (Requirements.stateMachineMermaid task) ++
    "\",\"constraints\":[" ++ String.intercalate "," constraints ++ "]}"
  "{\"source\":\"" ++ jsonEscape source ++ "\",\"validation\":{\"errors\":" ++
    toString (validateRequirementSpec requirements).length ++ ",\"warnings\":0},\"tasks\":[" ++
    String.intercalate "," items ++ "]}"

def emptyProjectTasksJson (source : String) : String :=
  "{\"source\":\"" ++ jsonEscape source ++
  "\",\"accepted\":false,\"validation\":{\"errors\":0,\"warnings\":0},\"tasks\":[]}"

-- Refs: media, Multimodal round trip, Concurrent BYOK isolation.
def attachmentPath (id : String) : String := "artifacts/attachments/" ++ id ++ "/image.png"

def attachmentIdsFromText (text : String) : List String :=
  (text.splitOn "artifacts/attachments/" |>.drop 1).filterMap fun tail =>
    let id := (tail.splitOn "/").headD ""
    if id.length == 32 && id.toList.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')) &&
        tail.startsWith (id ++ "/image.png") then some id else none

def mediaOperation (operation root input : String) : IO (Except String Lean.Json) := do
  try
    let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["media-" ++ operation, root] } (some input)
    if out.exitCode != 0 then return .error "Image processing failed or exceeded its resource limit. Use a smaller image."
    let .ok json := Lean.Json.parse out.stdout | return .error "Image processing returned an invalid result."
    if let some error := Provider.jsonStringField? json "error" then return .error error
    return .ok json
  catch _ => return .error "Image processing could not start. Check the server's image dependencies."

def resolveChatImages (root : String) (ids : List String) : IO (Except String (List Provider.ImageInput)) := do
  if ids.isEmpty then return .ok []
  let input := (Lean.Json.mkObj [("attachment_ids", Lean.toJson ids)]).compress
  match ← mediaOperation "resolve" root input with
  | .error error => return .error error
  | .ok json =>
      let some items := Provider.jsonArrayField? json "images" | return .error "Image resolution failed."
      let images := items.toList.filterMap fun item => do
        let data ← Provider.jsonStringField? item "data"
        let label ← Provider.jsonStringField? item "label"
        pure ({ data, label } : Provider.ImageInput)
      if images.length != ids.length then return .error "Not every attached image could be loaded."
      return .ok images

def appendConversation (root role text : String) (usage : Option Provider.Completion := none)
    (responseTimeMs : Nat := 0) (model : String := "") : IO Unit := do
  let path := root ++ "/conversations/main.log"
  let old ← readOr path ""
  let messageId ← randomHex 12
  let usageFields := match usage with
    | none => "0|0|0|0"
    | some u => s!"{u.inputTokens}|{u.cachedInputTokens}|{u.outputTokens}|{u.totalTokens}"
  let sentAtMs := (← Std.Time.Timestamp.now).toMillisecondsSinceUnixEpoch.val
  writeAtomic path (old ++ messageId ++ "|" ++ role ++ "|" ++ base64Encode text ++ "|" ++ usageFields ++ "|" ++ toString responseTimeMs ++ "|" ++ toString sentAtMs ++ "|" ++ model ++ "\n")

def truncateText (value : String) (limit : Nat) : String :=
  if value.length ≤ limit then value else String.ofList (value.toList.take limit) ++ "\n[truncated]\n"

def truncateTailText (value : String) (limit : Nat) : String :=
  if value.length ≤ limit then value
  else "[earlier output truncated]\n" ++ (value.drop (value.length - limit)).toString

def diagnosticLogPath (root : String) : String := root ++ "/logs/runtime-diagnostics.jsonl"

def recentProjectDiagnostics (root : String) : IO String := do
  let body ← readOr (diagnosticLogPath root) ""
  let recent := body.splitOn "\n" |>.filter (!·.isEmpty) |>.reverse |>.take 20 |>.reverse
  pure (truncateText (String.intercalate "\n" recent) 8000)

def appendProjectDiagnostic (root category detail : String) : IO Unit := do
  IO.FS.createDirAll (fp (root ++ "/logs"))
  let path := diagnosticLogPath root
  let old ← readOr path ""
  let retained := if old.length > 1500000 then
      "{\"category\":\"rotation\",\"detail\":\"Earlier diagnostic entries were discarded at the 1.5 MB bound.\"}\n"
    else old
  let atMs := (← Std.Time.Timestamp.now).toMillisecondsSinceUnixEpoch.val
  let entry := "{\"at_ms\":" ++ toString atMs ++ ",\"category\":\"" ++
    jsonEscape category ++ "\",\"detail\":\"" ++ jsonEscape (truncateText detail 12000) ++ "\"}\n"
  writeAtomic path (retained ++ entry)
  let readme := root ++ "/logs/README.md"
  if !(← (fp readme).pathExists) then
    writeAtomic readme ("# LeanFM private diagnostics\n\n`runtime-diagnostics.jsonl` is a bounded, project-owned engineering journal for LeanFM and Codex. Read it before diagnosing a failed agent turn. It records sanitized stages, tool destinations, compiler output, exit decisions, and terminal failures. It intentionally excludes prompts, credentials, cookies, and arbitrary provider response bodies. Do not ask the user to copy this file into chat; inspect it directly from the project root.\n")

def safeDiagnosticQuestionId (id : String) : Bool :=
  !id.isEmpty && id.length ≤ 80 && id.toList.all fun character =>
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".toList.contains character

def structuredQuestionIds (text : String) : List String := Id.run do
  let marker := if text.contains "```leanfm-questions" then "```leanfm-questions"
    else if text.contains "```leanfm-qustions" then "```leanfm-qustions" else ""
  if marker.isEmpty then return []
  let blocks := text.splitOn marker
  let some block := blocks[1]? | return []
  let jsonText := (block.splitOn "```").headD ""
  let some json := (Lean.Json.parse jsonText).toOption | return []
  let questions := (Provider.jsonArrayField? json "questions").getD #[]
  return questions.toList.filterMap fun question => do
    let id ← Provider.jsonStringField? question "id"
    if safeDiagnosticQuestionId id then some id else none

def resolveProjectDiagnostics (root resolution : String) (signatures : List String)
    (preserveCheckFailures : Bool := false) : IO Unit := do
  let path := diagnosticLogPath root
  let old ← readOr path ""
  let kept := old.splitOn "\n" |>.filter fun line =>
    !line.isEmpty && ((preserveCheckFailures &&
      (line.contains "Check failed:" || line.contains "Failed check:")) ||
      !(signatures.any fun signature => line.contains signature))
  writeAtomic path (String.intercalate "\n" kept ++ if kept.isEmpty then "" else "\n")
  appendProjectDiagnostic root "resolved" resolution

def workspaceRelativePath? (value : String) : Bool :=
  !value.isEmpty && !value.startsWith "/" && value.length ≤ 4096 &&
    (value.splitOn "/" |>.all fun part => !part.isEmpty && part != "." && part != "..")

def underRoot (root candidate : String) : Bool :=
  candidate == root || candidate.startsWith (root ++ "/")

def projectPathIsPublic (selected candidate : String) : IO Bool := do
  let workspace ← workspaceRoot
  if underRoot (workspace ++ "/.leanfm") candidate then return false
  if underRoot selected workspace && underRoot (workspace ++ "/projects") candidate then return false
  return true

def resolveWorkspacePath (root relative : String) (allowMissing : Bool := false) : IO (Except String String) := do
  if !workspaceRelativePath? relative then return .error "Path must be a non-empty relative path without '.' or '..' segments."
  let canonicalRoot ← IO.FS.realPath (fp root)
  let canonical := canonicalRoot.toString
  let candidate := canonical ++ "/" ++ relative
  try
    let resolved ← IO.FS.realPath (fp candidate)
    if underRoot canonical resolved.toString && (← projectPathIsPublic canonical resolved.toString) then return .ok resolved.toString
    return .error "Path escapes the selected project root."
  catch _ =>
    if !allowMissing then return .error "Path does not exist."
    let parent := (fp candidate).parent.getD canonicalRoot
    try
      let resolvedParent ← IO.FS.realPath parent
      if underRoot canonical resolvedParent.toString then return .ok candidate
      return .error "Path parent escapes the selected project root."
    catch _ => return .error "The destination parent does not exist."

partial def ensureWorkspaceDestinationFrom (root current : String) (segments : List String) : IO (Except String String) := do
  match segments with
  | [] => return .error "A destination filename is required."
  | [file] => return .ok (current ++ "/" ++ file)
  | directory :: rest =>
      let next := current ++ "/" ++ directory
      if !(← (fp next).pathExists) then
        try IO.FS.createDir (fp next)
        catch _ => return .error ("Could not create destination directory " ++ directory ++ ".")
      try
        let resolved ← IO.FS.realPath (fp next)
        if !underRoot root resolved.toString then return .error "Destination directory escapes the selected project root."
        ensureWorkspaceDestinationFrom root resolved.toString rest
      catch _ => return .error ("Destination component " ++ directory ++ " is not an accessible directory.")

def ensureWorkspaceDestination (root relative : String) : IO (Except String String) := do
  if !workspaceRelativePath? relative then return .error "Path must be a non-empty relative path without '.' or '..' segments."
  let canonicalRoot ← IO.FS.realPath (fp root)
  ensureWorkspaceDestinationFrom canonicalRoot.toString canonicalRoot.toString (relative.splitOn "/")

def toolArgument? (arguments key : String) : Option String := do
  let json ← (Lean.Json.parse arguments).toOption
  Provider.jsonStringField? json key

def projectRelativeToolPath (root value : String) : IO String := do
  let realRoot ← IO.FS.realPath (fp root)
  let canonical := realRoot.toString
  if value == root || value == canonical then return "."
  if value.startsWith (root ++ "/") then return (value.drop (root.length + 1)).toString
  if value.startsWith (canonical ++ "/") then return (value.drop (canonical.length + 1)).toString
  return value

def compactToolResult (value : String) : String := truncateText value 30000

-- Keep the exact exit-code line while ignoring line-number drift when deciding
-- whether another failed check has made progress. Original output is retained.
def checkFailureKey (result : String) : String :=
  (result.splitOn "\n").headD "" ++ "\n" ++
    String.ofList (result.toList.map fun c => if c.isDigit then '#' else c)

def liveTracePath (root : String) : String := root ++ "/.leanfm/operational-trace.json"

def writeLiveTrace (root : String) (entries : List String) : IO Unit := do
  IO.FS.createDirAll (fp (root ++ "/.leanfm"))
  let bounded := entries.take 100
  let encoded := bounded.map fun entry => "\"" ++ jsonEscape (truncateText entry 1000) ++ "\""
  writeAtomic (liveTracePath root) ("{\"entries\":[" ++ String.intercalate "," encoded ++ "]}\n")

def liveTraceJson (root : String) : IO String := do
  let trace ← readOr (liveTracePath root) ""
  match Lean.Json.parse trace with
  | .ok _ => pure trace
  | .error _ => pure "{\"entries\":[]}\n"

def appendLiveTrace (root : String) (trace : IO.Ref (List String)) (message : String) : IO Unit := do
  trace.modify (message :: ·)
  writeLiveTrace root (← trace.get).reverse
  appendProjectDiagnostic root "operational_trace" message

def runWorkspaceTool (root name arguments : String) (trace : IO.Ref (List String)) : IO String := do
  let record (message : String) : IO Unit := appendLiveTrace root trace message
  let fail (message : String) : IO String := do record (name ++ " rejected: " ++ message); pure ("ERROR: " ++ message)
  match name with
  | "leanfm_reference" =>
      let some referenceKind := toolArgument? arguments "section" | fail "Missing section."
      let reference := match referenceKind with
        | "requirements" => LeanFM.leanFMRequirementsReference
        | "implementation" => LeanFM.leanFMImplementationReference
        | "interrogation" => LeanFM.requirementsInterrogationChecklist
        | "code-generation" => LeanFM.codeGenerationSystemPrompt
        | _ => ""
      if reference.isEmpty then return ← fail "Unknown LeanFM reference."
      record ("Read live LeanFM reference: " ++ referenceKind)
      pure reference
  | "leanfm_check" =>
      let some requirement := toolArgument? arguments "requirement" | fail "Missing RequirementSpec constant."
      let implementation := (toolArgument? arguments "implementation").getD ""
      let constraints := (toolArgument? arguments "constraints").getD ""
      record "Started canonical project specification check and task-view generation"
      let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["check-specification", root, requirement, implementation, constraints] }
      if out.exitCode != 0 then return ← fail ("Specification check failed: exit_code=" ++ toString out.exitCode ++
        "\n" ++ compactToolResult (out.stdout ++ out.stderr))
      record "Validated canonical project specification; regenerated spec/tasks.json"
      pure ("exit_code=0\n" ++ compactToolResult out.stdout)
  | "workspace_list" =>
      let relative ← projectRelativeToolPath root ((toolArgument? arguments "path").getD ".")
      let normalized := if relative == "." then "" else relative
      let resolved ← if normalized.isEmpty then pure (.ok root) else resolveWorkspacePath root normalized
      match resolved with
      | .error message => fail message
      | .ok path =>
          record ("Listed " ++ (if normalized.isEmpty then "." else normalized))
          let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["list-files", path] }
          if out.exitCode > 1 then return ← fail ("File listing failed: exit_code=" ++ toString out.exitCode ++ "\n" ++ compactToolResult out.stderr)
          let body := out.stdout.splitOn "\n" |>.map (fun line =>
            if line.startsWith (root ++ "/") then (line.drop (root.length + 1)).toString else line) |>.intersperse "\n" |> String.join
          pure (compactToolResult body)
  | "workspace_read" =>
      let some supplied := toolArgument? arguments "path" | fail "Missing path."
      let relative ← projectRelativeToolPath root supplied
      match ← resolveWorkspacePath root relative with
      | .error message => fail message
      | .ok path =>
          record ("Read " ++ relative)
          try pure (compactToolResult (← IO.FS.readFile (fp path)))
          catch _ => fail "File is not readable UTF-8 text."
  | "workspace_search" =>
      let some query := toolArgument? arguments "query" | fail "Missing query."
      let relative ← projectRelativeToolPath root ((toolArgument? arguments "path").getD ".")
      let normalized := if relative == "." then "" else relative
      let resolved ← if normalized.isEmpty then pure (.ok root) else resolveWorkspacePath root normalized
      match resolved with
      | .error message => fail message
      | .ok path =>
          record ("Searched " ++ (if normalized.isEmpty then "." else normalized) ++ " for a literal query")
          let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["search-literal", query, path] }
          if out.exitCode > 1 then return ← fail ("Search failed: exit_code=" ++ toString out.exitCode ++ "\n" ++ compactToolResult out.stderr)
          pure (compactToolResult (if out.stdout.isEmpty then "No matches." else out.stdout))
  | "workspace_patch" =>
      let some patch := toolArgument? arguments "patch" | fail "Missing patch."
      if patch.length > 2000000 then return ← fail "Patch exceeds the 2 MB limit."
      record "Applying a workspace patch"
      let checked ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["git-apply-check", root] } (some patch)
      if checked.exitCode != 0 then return ← fail ("Patch check failed: exit_code=" ++ toString checked.exitCode ++ "\n" ++ compactToolResult checked.stderr ++
        "\nDo not retry workspace_patch during this turn. Read the affected file with workspace_read, then use workspace_write with the complete corrected content, preserving unrelated work. A second patch attempt will stop the turn before another paid request.")
      let applied ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["git-apply", root] } (some patch)
      if applied.exitCode != 0 then return ← fail ("Patch apply failed: exit_code=" ++ toString applied.exitCode ++ "\n" ++ compactToolResult applied.stderr)
      record "Applied workspace patch"
      pure "OK"
  | "workspace_write" =>
      let some supplied := toolArgument? arguments "path" | fail "Missing path."
      let relative ← projectRelativeToolPath root supplied
      let some content := toolArgument? arguments "content" | fail "Missing content."
      let authorization ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["project-authorize", root, relative]}
      if authorization.exitCode != 0 then return ← fail (compactToolResult authorization.stdout)
      let trimmed := content.trimAscii.toString
      let contentKind := if trimmed.startsWith "<svg" || trimmed.startsWith "<?xml" && trimmed.contains "<svg" then "SVG document"
        else if trimmed.startsWith "{" || trimmed.startsWith "[" then "JSON/text document"
        else if relative.toLower.endsWith ".lean" then "Lean source"
        else if relative.toLower.endsWith ".tex" then "LaTeX source"
        else "text file"
      record ("Attempting write to " ++ relative ++ " (" ++ contentKind ++ ", " ++
        toString content.length ++ " characters)")
      let failWrite (message : String) := fail ("Write to " ++ relative ++ " rejected: " ++ message)
      if content.length > 2000000 then return ← failWrite "File exceeds the 2 MB write limit."
      match ← ensureWorkspaceDestination root relative with
      | .error message => failWrite message
      | .ok path =>
          try
            writeAtomic path content
            record ("Wrote " ++ relative ++ " (" ++ toString content.length ++ " characters)")
            resolveProjectDiagnostics root ("Successful write superseded earlier file-access failures for " ++ relative) [relative] true
            pure "OK"
          catch error => failWrite ("Write failed: " ++ toString error)
  | "workspace_check" =>
      let some target := toolArgument? arguments "target" | fail "Missing target."
      let operation := match target with
        | "build" => "check-build"
        | "check" => "check-check"
        | "book" => "check-book"
        | "http-check" => "check-http"
        | "go-test" => "check-go"
        | _ => ""
      if operation.isEmpty then return ← fail "Unknown check target."
      record ("Started check: " ++ target)
      let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #[operation, root] }
      let result := compactToolResult (out.stdout ++ out.stderr)
      record ((if out.exitCode == 0 then "Finished check: " else "Failed check: ") ++ target ++ " (exit " ++ toString out.exitCode ++ ")")
      if out.exitCode != 0 then return ← fail ("Check failed: target=" ++ target ++
        " exit_code=" ++ toString out.exitCode ++ "\n" ++ result)
      pure ("exit_code=" ++ toString out.exitCode ++ "\n" ++ result)
  | "workspace_run_gif_generator" =>
      let some scriptRelative := toolArgument? arguments "script_path" | fail "Missing script_path."
      let some outputRelative := toolArgument? arguments "output_path" | fail "Missing output_path."
      if !scriptRelative.toLower.endsWith ".py" then return ← fail "The generator must be a .py file."
      if !outputRelative.toLower.endsWith ".gif" then return ← fail "The output must be a .gif file."
      match ← resolveWorkspacePath root scriptRelative with
      | .error message => fail message
      | .ok _ =>
          match ← ensureWorkspaceDestination root outputRelative with
          | .error message => fail message
          | .ok outputPath =>
              record ("Started sandboxed GIF generator " ++ scriptRelative)
              let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["generate-gif", root, scriptRelative, outputRelative] }
              if out.exitCode != 0 then return ← fail ("GIF generator failed: exit_code=" ++ toString out.exitCode ++ "\n" ++ compactToolResult (out.stdout ++ out.stderr))
              let bytes ← IO.FS.readBinFile (fp outputPath)
              let signature := String.fromUTF8? (bytes.extract 0 (min 6 bytes.size))
              if signature != some "GIF87a" && signature != some "GIF89a" then return ← fail "Generator output is not a GIF87a or GIF89a file."
              if bytes.size > 33554432 then return ← fail "Generated GIF exceeds the 32 MB display limit."
              record ("Generated " ++ outputRelative ++ " (" ++ toString bytes.size ++ " bytes)")
              pure ("OK: " ++ outputRelative)
  | "workspace_transcode_mp4" =>
      let some inputRelative := toolArgument? arguments "input_path" | fail "Missing input_path."
      let some outputRelative := toolArgument? arguments "output_path" | fail "Missing output_path."
      let lowerInput := inputRelative.toLower
      if !lowerInput.endsWith ".gif" && !lowerInput.endsWith ".webm" then
        return ← fail "The MP4 input must be a project-local .gif or .webm file."
      if !outputRelative.toLower.endsWith ".mp4" then return ← fail "The output must be a .mp4 file."
      match ← resolveWorkspacePath root inputRelative with
      | .error message => fail message
      | .ok inputPath =>
          match ← ensureWorkspaceDestination root outputRelative with
          | .error message => fail message
          | .ok outputPath =>
              record ("Started MP4 transcode from " ++ inputRelative)
              let out ← try IO.Process.output {
                  cmd := "scripts/chatui_command.sh"
                  args := #["transcode-mp4", root, inputPath, outputPath]
                } catch error => return ← fail ("Could not run MP4 whitelist command: " ++ toString error)
              if out.exitCode != 0 then return ← fail ("MP4 transcode failed: exit_code=" ++ toString out.exitCode ++ "\n" ++ compactToolResult (out.stdout ++ out.stderr))
              let bytes ← IO.FS.readBinFile (fp outputPath)
              let header := String.fromUTF8? (bytes.extract 4 (min 12 bytes.size))
              if bytes.size < 12 || !(header.getD "").startsWith "ftyp" then return ← fail "Transcoder output is not an ISO base media MP4 file."
              if bytes.size > 536870912 then return ← fail "Generated MP4 exceeds the 512 MB project media limit."
              record ("Generated " ++ outputRelative ++ " (" ++ toString bytes.size ++ " bytes)")
              pure ("OK: " ++ outputRelative)
  | _ => fail "Unknown workspace tool."

def workspaceAgentInstructions (root : String) : String :=
  "Do not rewrite the book merely to log implementation steps or acceptance; source evidence and the protected gate records already persist those facts. " ++
  "Use the explicit acceptance controls in Project memory for formal gates. Read project specification status when needed; never fabricate acceptance by editing a manifest or a gate file. Source writes are enforced against both current checked gates by the server. Do not reopen a gate already accepted for its current revision. " ++
  "Never claim or link that a project media file was created unless this turn's successful tool output or a workspace read confirms the exact path exists. For a PDF image, prefer a self-contained vector drawing over a guessed external image path. When a referenced path fails existence validation, inspect that exact diagnostic and use one bounded correction without replaying completed mutations; a repeated missing path stops immediately. When a workspace tool returns ERROR or a check fails, inspect that concrete diagnostic, change the input or strategy, exhaust safe reversible alternatives, rerun validation, and continue the original requested task. For every generated or substantially rewritten text file, preserve the last revision that passed its proportional check and work on a project-local scratch candidate. Promote it only after validation. On any validation failure, retain the complete bounded diagnostic, restore the last known-good file, divide the intended delta into small ordered independently checkable pieces, apply and validate one piece at a time, and immediately back out the first failing piece. Never resubmit the complete failing candidate, repeat an unchanged failure class, or spend another model request before narrowing the change or failure location. Running a project-local compiler, test, or named check is already authorized reversible work: run it directly and never ask whether the user wants it run. Do not ask the user to retry an authorized reversible operation and do not repeat the identical failing call. Ask only when recovery needs new authority, a destructive or expensive choice, or an unavailable dependency. " ++
  Provider.hostedChatInstructions ++ " The authenticated user explicitly authorizes you to inspect and edit files only beneath the selected project root " ++ root ++ ". Use the supplied workspace tools to do requested engineering work, not merely describe a plan. All final implementation code, build files, generated language bindings, and implementation tests belong beneath source/. Specification artifacts remain beneath spec/. Never present implementation source as a chat code fence or prose substitute: write each file with workspace_write or workspace_patch, run a proportional check, and reply with a concise artifact summary. Use the hosted web_search tool when the user asks you to search the public internet, and cite the selected source URL. When the user asks to find or show an internet image, show the selected image immediately using Markdown image syntax with a direct HTTPS image URL, followed by its source-page URL; do not ask whether to show, preview, import, encode, or register it. workspace_write creates missing parent directories safely. Read relevant AGENTS.md and SKILL.md files before edits. Preserve unrelated changes. Never try to access a path outside this workspace. A descriptive Lean file containing lists of strings is not a LeanFM grammar: candidate requirements must define and validate a typed RequirementSpec with TaskRequirement and TaskGrammar values, and must derive spec/tasks.json for the Grammar and Tasks UI. Use LeanFM.ChatUI.Server.tasksJson with the current project RequirementSpec and that project's constraints (or an empty list), and pass the same RequirementSpec as the second argument to LeanFM.ChatUI.Requirements.interactionMermaid. Never call the host-default renderer on foreign tasks or copy an old specification into a generator; import the current canonical project specification. A missing-task-grammar placeholder is a failed view, not successful validation. If that grammar is absent or invalid, create or repair it before implementation files. Never implement source, generate language bindings, or cross either acceptance gate unless the durable project state records the user's explicit acceptance. Immediately before any source-generation pass, critique the accepted design for security. Identify trust boundaries protected assets attacker capabilities and abuse cases, then encode applicable security requirements as durable MUST NOT constraints covering authorization tenant and project isolation secrets logs injection path or symlink escape executable content resource exhaustion replay request confusion privilege expansion and fail-open behavior. Map each negative requirement to an implementation control plus a negative test or proof obligation. If a material threat lacks an accepted mitigation, return to the implementation-specification gate instead of generating source or inventing policy. Immediately before recommending or performing a commit, inspect the exact candidate diff and generated artifacts rather than relying on the earlier design critique. Check for secrets, authorization or isolation failures, injection, path or symlink escape, executable content, unbounded or unsafe generated artifacts, replay, request confusion, privilege expansion, and fail-open behavior; state the positive invariant and map each material forbidden behavior to a control and negative test or proof. Never commit or claim commit readiness while a material finding is unresolved. Never imitate generated output: invoke the real generator or report the exact missing executable. When you create or discuss media below the selected project root, cite its project-relative path; the host renders supported image and video paths inline automatically. For an explicit animated GIF request, write a project-local Python/Pillow generator, run workspace_run_gif_generator, cite the resulting .gif path, and do not substitute canvas WebM or another format or ask whether a substitute is acceptable. For an explicit MP4 request, create or locate the project-local GIF or WebM source, run workspace_transcode_mp4, and cite the resulting project-relative .mp4 path so the remote chat renders an inline video. Never substitute WebM GIF canvas HTML a conversion script or file:// instructions for a requested MP4, and never claim MP4 completion until the transcoder has validated the actual file. Do not ask about data URIs, manifests, HTML tags, encodings, or download mechanisms, and do not create alternate compact media unless the user explicitly requests one. The user is operating the served UI remotely: provide authenticated served project artifacts, never directions to open server-local file:// paths. Follow the shared consequential decisions policy. The words do it, generate, proceed, continue, now, show, or accept defaults reinforce the instruction to choose authorized reversible defaults and produce the requested result. They do not accept a missing formal gate or grant new authority. A structured answer includes Question ID and closes that ID and the same semantic question unless explicitly reopened. Do not claim a file changed unless workspace_write or workspace_patch succeeded. Run a proportional named check after edits. Summarize the outcome, changed files, and validation concisely. Tool activity is shown separately, so do not invent or narrate hidden reasoning."

structure BookChatEdit where
  reply : String
  source : String
  repairedEscapes : Bool := false
  unwrapped : Bool := false

/-- Repair only illegal JSON escapes for LaTeX math delimiters. Already escaped
    backslashes and all other JSON escapes pass through unchanged. -/
def escapeJsonMathDelimiters (text : String) : String :=
  let rec go : List Char → List Char → List Char
    | [], acc => acc.reverse
    | '\\' :: c :: rest, acc =>
        if ['(', ')', '[', ']'].contains c then go rest (c :: '\\' :: '\\' :: acc)
        else go rest (c :: '\\' :: acc)
    | c :: rest, acc => go rest (c :: acc)
  String.ofList (go text.toList [])

def looksLikeBookEnvelope (text : String) : Bool :=
  let text := text.trimAscii.toString
  let hasSource := text.contains "\"book_source\""
  let hasReply := text.contains "\"reply\""
  (hasSource && hasReply) ||
    ((text.startsWith "{" || text.startsWith "```json" || text.startsWith "```\n") &&
      (hasSource || hasReply))

def bookEnvelopeJsonText (text : String) : String :=
  let trimmed := text.trimAscii.toString
  if trimmed.startsWith "```json" && trimmed.endsWith "```" then
    ((trimmed.drop 7).dropEnd 3 |>.trimAscii).toString
  else if trimmed.startsWith "```\n" && trimmed.endsWith "```" then
    ((trimmed.drop 3).dropEnd 3 |>.trimAscii).toString
  else trimmed

/-- Extract one whole top-level object, never a nested fragment, an array member,
    a truncated object, or a choice between multiple proposed revisions. JSON
    string escaping, including TeX braces inside strings, is preserved verbatim. -/
def uniqueBookObject? (text : String) : Option String := Id.run do
  let mut depth := 0
  let mut quoted := false
  let mut escaped := false
  let mut chars : List Char := []
  let mut result : Option String := none
  for c in text.toList do
    if depth == 0 then
      if c == '{' then
        if result.isSome then return none
        depth := 1
        chars := [c]
      else if c == '}' || c == '[' || c == ']' then return none
    else
      chars := c :: chars
      if quoted then
        if escaped then escaped := false
        else if c == '\\' then escaped := true
        else if c == '"' then quoted := false
      else if c == '"' then quoted := true
      else if c == '{' then depth := depth + 1
      else if c == '}' then
        depth := depth - 1
        if depth == 0 then result := some (String.ofList chars.reverse)
  if depth != 0 then return none
  return result

def bookEnvelopeCandidate (text : String) : String :=
  let framed := bookEnvelopeJsonText text
  if (Lean.Json.parse framed).isOk then framed
  else (uniqueBookObject? framed).getD framed

def bookChatEdit? (text : String) : Option BookChatEdit := do
  guard (text.length ≤ 2000000)
  let jsonText := bookEnvelopeCandidate text
  let (json, repairedEscapes) ← match Lean.Json.parse jsonText with
    | .ok json => some (json, false)
    | .error _ => do
        let repaired := escapeJsonMathDelimiters jsonText
        guard (repaired != jsonText)
        let json ← (Lean.Json.parse repaired).toOption
        pure (json, true)
  let reply ← Provider.jsonStringField? json "reply"
  let source ← Provider.jsonStringField? json "book_source"
  guard (!reply.trimAscii.isEmpty && !source.trimAscii.isEmpty)
  pure { reply, source, repairedEscapes, unwrapped := jsonText != bookEnvelopeJsonText text }

def bookReplyShape (text : String) : String :=
  let leading := match text.trimAscii.toString.toList.head? with
    | none => "empty"
    | some '{' => "object"
    | some '[' => "array"
    | some '`' => "fence"
    | some _ => "other"
  "response_chars=" ++ toString text.length ++ " leading_token=" ++ leading ++
    " unique_complete_object=" ++ toString (uniqueBookObject? text).isSome

def bookEnvelopeDiagnostic (text : String) : String :=
  match Lean.Json.parse (escapeJsonMathDelimiters (bookEnvelopeCandidate text)) with
  | .error message =>
      -- Lean's JSON parser emits a byte offset and grammar expectation, not an
      -- excerpt of the untrusted response. Keep that specific failure location.
      "JSON parser: " ++ truncateText message 200
  | .ok json =>
      if (Provider.jsonStringField? json "reply").all (·.trimAscii.isEmpty) then
        "The reply field must be a nonempty string."
      else "The book_source field must be a nonempty string."

def bookVisibleText (text : String) : String :=
  match bookChatEdit? text with
  | some edit => edit.reply
  | none => if looksLikeBookEnvelope text then "" else text

def readProjectCanonical (root relative : String) : IO String := do
  match ← resolveWorkspacePath root relative with
  | .error _ => return "[Missing or outside the selected project: " ++ relative ++ "]"
  | .ok path =>
      try IO.FS.readFile (fp path)
      catch error => do
        appendProjectDiagnostic root "durable_context_read_failed"
          ("file=" ++ relative ++ " error=" ++ truncateText error.toString 1000)
        return "[Unreadable durable file: " ++ relative ++ "; diagnostic category=durable_context_read_failed]"

def durableResumeContext (root : String) : IO String := do
  let manifest ← readProjectCanonical root "manifest.json"
  let project ← readProjectCanonical root "project.json"
  let proto ← readProjectCanonical root "spec/Requirements.proto"
  let gateStatus ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["project-status", root]}
  let realRoot ← IO.FS.realPath (fp root)
  let inventory ← match ← resolveWorkspacePath realRoot.toString "source" with
    | .error _ => pure "No in-project implementation source directory is available."
    | .ok sourceRoot => do
        let files ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["list-files", sourceRoot]}
        pure (if files.exitCode == 0 then truncateText files.stdout 8000 else "No implementation source files are recorded.")
  return "DURABLE RESUME INPUTS. Conversation history is disposable and may be empty. Resume from the selected project's recorded book, requirements, protobuf, implementation mapping and source files; do not ask the user to reconstruct earlier chats. Missing artifacts are explicit gaps, never evidence of acceptance or a reason to substitute another project's files. Read listed source files with workspace_read before changing them. Record any new resolved requirement or implementation decision in the appropriate durable artifact before relying on it in a later turn.\n\nProject manifests (acceptance may be absent; never infer it):\n" ++
    truncateText (manifest ++ "\n" ++ project) 12000 ++
    "\n\nVerified current acceptance status (authoritative over historical manifest placeholders):\n" ++
      (if gateStatus.exitCode == 0 then truncateText gateStatus.stdout 12000 else "No current checked gate status is available; do not infer acceptance.") ++
    "\n\nCanonical spec/Requirements.proto:\n" ++ truncateText proto 40000 ++
    "\n\nCurrent implementation source inventory (paths, not source contents):\n" ++ inventory ++ "\n\n"

def chatLayerContext (root layer : String) : IO (Except String String) := do
  let book ← readProjectCanonical root "book/main.tex"
  let requirements ← readProjectCanonical root "spec/Requirements.lean"
  let implementation ← readProjectCanonical root "spec/Implementation.lean"
  let canvasContrastHardRule := "Canvas text contrast is mandatory: never draw black text on a black/dark background or white text on a white/light background. Set a contrasting foreground immediately before each fillText call, based on the pixels behind that label in the canvas; recompute the choice each animation frame if its background changes. Keep user-specified text colors only when the user explicitly requests them.\n\n"
  let diagramGuidance := "Diagram input is intentionally permissive. The user may supply prose, simplified interaction pseudocode, Mermaid, PlantUML, or refer to an attached sketch or public-web image. Infer the intended semantics and ask only when a material ambiguity remains. When a diagram is useful, return corrected renderable Mermaid in a fenced mermaid block. When motion or simulation materially answers the request, return an actual triple-backtick leanfm-canvas fence containing a literal accessible canvas element and self-contained inline script with no external resources; never spell out the words fenced leanfm-canvas and never print its source as ordinary chat prose. For canvas animations, default text foregrounds to white or near-white over dark canvas drawing backgrounds and black or near-black over light canvas drawing backgrounds. Choose against the actual background painted in the canvas, not the surrounding page theme; preserve a text color only when the user specifically requests it. Check every label, legend, and annotation for contrast. For MCP, model the Model Context Protocol JSON-RPC lifecycle between host/client and MCP server (initialize, notifications/initialized, capability discovery such as tools/list, and invocation such as tools/call with their results), not MQTT broker traffic. Preserve the user's original as provenance; do not claim that an informal sketch is an accepted derived LeanFM view.\n\n"
  match layer with
  | "guided" => return .ok (canvasContrastHardRule ++ diagramGuidance ++ "Working mode: GUIDED PROJECT CONVERSATION. Infer the working layer from the current request: book discovery, typed requirements and derived views, implementation mapping, or accepted implementation source. Apply the shared consequential decisions policy: choose and record reasonable defaults, advance the actual artifacts, and ask only for a concrete consequential blocker or missing explicit acceptance gate. Routine file edits, image references, compilation and regeneration are already authorized; do not offer a menu asking permission to perform them. A readiness review may report no blockers and no questions. Never silently cross either acceptance gate. Use leanfm_reference before authoring LeanFM values; use workspace_read/write/patch to update spec/Requirements.lean, spec/Requirements.proto and spec/Implementation.lean as needed, then leanfm_check with the actual RequirementSpec constant to validate and regenerate Grammar and Tasks. An implementation mapping must contain a typed ImplementationSpec with requirement justifications; prose comments alone are not a validated mapping. Do not report specification or implementation success merely because a PDF compiled. For specification and source work, call the workspace tools and finish with a concise artifact and validation summary. When this turn actually revises the book, return a JSON object with string fields reply and book_source containing the complete revised book/main.tex; the server builds and commits that book revision. A full-book JSON rewrite is not required for other turns. Preserve the last validated book, and do not write book/main.tex directly through workspace tools. Current complete book source:\n\n" ++ truncateText book 70000 ++ "\n\nCurrent project Requirements.lean:\n\n" ++ truncateText requirements 40000 ++ "\n\nCurrent project Implementation.lean:\n\n" ++ truncateText implementation 40000)
  | "book" => return .ok (canvasContrastHardRule ++ diagramGuidance ++ "Working layer: BOOK. The user's ordinary request is an instruction to edit the durable project book, not merely advice about how they could edit it. Revise book/main.tex while preserving valid LaTeX and the user's existing material. Do not present generated requirements or code as accepted merely because they are discussed. Return ONLY one JSON object with exactly these string fields: {\"reply\":\"a concise description of the edit\",\"book_source\":\"the complete revised book/main.tex\"}. Do not wrap the JSON in prose or Markdown. If the user is only asking a question and no source change is appropriate, return a normal prose answer instead. Current complete book source:\n\n" ++ truncateText book 70000)
  | "requirements" => return .ok (canvasContrastHardRule ++ diagramGuidance ++ "Working layer: REQUIREMENTS. Derive observable requirements from the book, preserve unresolved design as unresolved, and prepare the requirements acceptance gate. Current book:\n\n" ++ truncateText book 50000 ++ "\n\nCurrent Requirements.lean:\n\n" ++ truncateText requirements 50000)
  | "implementation_spec" => return .ok (canvasContrastHardRule ++ diagramGuidance ++ "Working layer: IMPLEMENTATION SPECIFICATION. Map accepted requirements to languages, transports, runtime APIs, source files, tests, and explicit implementation issues such as Go services or HTTP projection. Do not implement before the separate implementation-specification acceptance gate. Current Requirements.lean:\n\n" ++ truncateText requirements 50000 ++ "\n\nCurrent Implementation.lean:\n\n" ++ truncateText implementation 50000)
  | "implementation" => return .ok (canvasContrastHardRule ++ diagramGuidance ++ "Working layer: IMPLEMENTATION. Implement only from accepted book, requirements, and implementation-specification revisions; preserve traceability and run checks. Current Implementation.lean:\n\n" ++ truncateText implementation 70000)
  | _ => return .error "Unknown chat working layer."

/- Make plain-text underscores safe before the first pdfLaTeX build. The
   underscore package leaves `_` as a math subscript and permits it in text. -/
def ensureTextUnderscoreSupport (source : String) : String := Id.run do
  if source.contains "\\usepackage{underscore}" || source.contains "\\usepackage[nohyphen]{underscore}" ||
      source.contains "\\usepackage[strings]{underscore}" then
    return source
  let lines := source.splitOn "\n"
  let some index := (List.range lines.length).find? (fun index => (lines[index]!).trimAscii.toString.startsWith "\\documentclass")
    | return source
  return String.intercalate "\n" <| (lines.take (index + 1)) ++ ["\\usepackage{underscore}"] ++ (lines.drop (index + 1))

-- property:book_palette_selection_is_real_and_stable: model-generated source
-- may omit the template's palette. A second filename alone is not a dark PDF.
def ensureBookPaletteSupport (source : String) : String := Id.run do
  if source.contains "\\darkmode" && source.contains "\\pagecolor" then return source
  let parts := source.splitOn "\\begin{document}"
  match parts with
  | preamble :: body :: rest =>
      return preamble ++ "\\usepackage{xcolor}\n\\makeatletter\n" ++
        "\\AtBeginDocument{%\n\\ifdefined\\darkmode\n" ++
        "\\pagecolor[HTML]{091117}\\color[HTML]{F0EDE4}\n" ++
        "\\global\\let\\default@color\\current@color\n" ++
        "\\ifdefined\\hypersetup\\hypersetup{linkcolor=cyan,urlcolor=cyan,citecolor=cyan}\\fi\n" ++
        "\\else\n\\pagecolor{white}\\color{black}\n\\fi}\n\\makeatother\n" ++
        "\\begin{document}" ++ String.intercalate "\\begin{document}" (body :: rest)
  | _ => return source

def normalizeBookSource (source : String) : String :=
  ensureBookPaletteSupport (ensureTextUnderscoreSupport source)

def buildProjectBook (root : String) : IO (Except String Unit) := do
  try
    let bookPath := fp (root ++ "/book")
    let sourcePath := fp (root ++ "/book/main.tex")
    if !(← sourcePath.pathExists) then return .error "book/main.tex does not exist in this project."
    let source ← IO.FS.readFile sourcePath
    let normalized := normalizeBookSource source
    if normalized != source then writeAtomic (root ++ "/book/main.tex") normalized
    cleanProjectBookIntermediates root
    let realBook ← IO.FS.realPath bookPath
    let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["build-book", realBook.toString] }
    if out.exitCode == 0 then return .ok ()
    let processTail := truncateTailText (out.stdout ++ "\n" ++ out.stderr) 12000
    let latexLog ← readOr (root ++ "/book/main.log") ""
    let logTail := if latexLog.isEmpty then "" else
      "\n\nTail of book/main.log:\n" ++ truncateTailText latexLog 12000
    return .error ("Book build failed: exit_code=" ++ toString out.exitCode ++ "\n" ++ processTail ++ logTail)
  catch error =>
    return .error ("Book worker failed before returning compiler output: " ++ toString error)

def buildErrorSummary (message : String) : String :=
  let lines := message.splitOn "\n" |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  (lines.find? (fun line => line.startsWith "!")).orElse (fun _ =>
    lines.find? (fun line =>
      !line.startsWith "Book build failed:" && !line.startsWith "make[" &&
      !line.startsWith "make:" && !line.startsWith "Entering directory" &&
      !line.startsWith "Leaving directory")) |>.getD
    "The book worker failed before producing a compiler diagnostic. Inspect logs/runtime-diagnostics.jsonl."

def addCompletionUsage (first second : Provider.Completion) (text : String) : Provider.Completion :=
  { text
  , inputTokens := first.inputTokens + second.inputTokens
  , cachedInputTokens := first.cachedInputTokens + second.cachedInputTokens
  , outputTokens := first.outputTokens + second.outputTokens
  , totalTokens := first.totalTokens + second.totalTokens }

def mediaReferencePath? (token : String) : Option String := do
  let markers := ["spec/images/", "spec/media/", "renders/", "artifacts/"]
  let marker ← markers.find? (fun value => token.contains value)
  let pieces := token.splitOn marker
  let leading := pieces.headD ""
  guard (!leading.contains "://")
  let tail := (pieces.drop 1).headD ""
  let path := marker ++ String.ofList (tail.toList.takeWhile fun character =>
    character.isAlphanum || character == '_' || character == '-' || character == '.' || character == '/')
  guard (path.startsWith marker && !path.contains "..")
  guard ([".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf", ".mp4", ".webm"] |>.any (fun extension => path.toLower.endsWith extension))
  some path

def mediaReferences (text : String) : List String :=
  text.splitOn " " |>.flatMap fun token =>
    token.splitOn "\n" |>.filterMap mediaReferencePath? |>.foldl
      (fun found path => if found.contains path then found else found ++ [path]) []

def missingMediaReferences (root text : String) : IO (List String) := do
  let mut missing := []
  for path in mediaReferences text do
    match ← resolveWorkspacePath root path with
    | .error _ => missing := missing ++ [path]
    | .ok resolved => if !(← (fp resolved).pathExists) then missing := missing ++ [path]
  return missing

def bookRepairTimeoutSeconds : IO Nat := do
  let configured := (← IO.getEnv "LEANFM_BOOK_REPAIR_TIMEOUT_SECONDS").bind String.toNat?
  pure (max 10 (min 60 (configured.getD 30)))

def chatStatusPath (root : String) : String := root ++ "/.leanfm/chat-status.json"
def chatCancellationPath (root : String) : String := root ++ "/.leanfm/cancel-requested"
def bookRecoveryPath (root : String) : String := root ++ "/.leanfm/book-recovery.tex"

def retainBookRecovery (root candidate : String) : IO Unit := do
  IO.FS.createDirAll (fp (root ++ "/.leanfm"))
  writeAtomic (bookRecoveryPath root) candidate

def clearBookRecovery (root : String) : IO Unit := do
  let path := fp (bookRecoveryPath root)
  if ← path.pathExists then IO.FS.removeFile path

def bookRecoveryContext (root : String) : IO String := do
  if ← (fp (bookRecoveryPath root)).pathExists then
    pure ("An earlier proposed book revision failed compilation and is retained at .leanfm/book-recovery.tex. " ++
      "The active book/main.tex is the last compiling revision. Continue the requested work autonomously: inspect the retained compiler diagnostic, compare the retained target with book/main.tex, reapply it in small independently compilable pieces, run the book check after every piece, and immediately back out the first failing piece. Do not ask the user to perform these steps.\n\n")
  else pure ""

def clearChatCancellation (root : String) : IO Unit := do
  let path := fp (chatCancellationPath root)
  if ← path.pathExists then IO.FS.removeFile path

def chatCancellationRequested (root : String) : IO Bool :=
  (fp (chatCancellationPath root)).pathExists

def writeChatStatus (root stage detail : String) (attempt : Nat := 0) : IO Unit := do
  IO.FS.createDirAll (fp (root ++ "/.leanfm"))
  writeAtomic (chatStatusPath root) ("{\"stage\":\"" ++ jsonEscape stage ++
    "\",\"detail\":\"" ++ jsonEscape (truncateText detail 1000) ++
    "\",\"attempt\":" ++ toString attempt ++ "}\n")
  appendProjectDiagnostic root "stage" (stage ++ " attempt=" ++ toString attempt ++ ": " ++ detail)

def chatStatusJson (root : String) : IO String := do
  let status ← readOr (chatStatusPath root) ""
  match Lean.Json.parse status with
  | .ok _ => pure status
  | .error _ => pure "{\"stage\":\"idle\",\"detail\":\"No agent turn is active.\",\"attempt\":0}\n"

structure BookLineRepair where
  lineNumber : Nat
  replacement : String

def diagnosticLineNumber? (diagnostic : String) : Option Nat := do
  let line ← diagnostic.splitOn "\n" |>.map (·.trimAscii.toString) |>.find? (fun value => value.startsWith "l.")
  let digits := (line.drop 2).toString.toList.takeWhile Char.isDigit |> String.ofList
  digits.toNat?

def escapeBareUnderscores (source : String) : String :=
  let rec loop (previousBackslash : Bool) : List Char → List Char
    | [] => []
    | character :: rest =>
        if character == '_' && !previousBackslash then
          '\\' :: '_' :: loop false rest
        else
          character :: loop (character == '\\' && !previousBackslash) rest
  String.ofList (loop false source.toList)

def deterministicMissingMathRepair? (candidate diagnostic : String) : Option String := do
  guard (buildErrorSummary diagnostic == "! Missing $ inserted.")
  let lineNumber ← diagnosticLineNumber? diagnostic
  guard (lineNumber > 0)
  let lines := candidate.splitOn "\n"
  let original ← lines[lineNumber - 1]?
  let repaired := escapeBareUnderscores original
  guard (repaired != original)
  pure <| String.intercalate "\n" <| lines.zipIdx.map fun (line, index) =>
    if index == lineNumber - 1 then repaired else line

def sameBuildFailure (first second : String) : Bool :=
  buildErrorSummary first == buildErrorSummary second

def numberedBookExcerpt (candidate : String) (lineNumber : Nat) : String :=
  let lines := candidate.splitOn "\n"
  let first := lineNumber - 8
  let excerpt := lines.drop first |>.take 17
  String.intercalate "\n" <| (List.range excerpt.length |>.zip excerpt).map fun (index, line) =>
    toString (first + index + 1) ++ ": " ++ line

def replaceBookLine? (candidate : String) (lineNumber : Nat) (replacement : String) : Option String := do
  guard (lineNumber > 0 && !replacement.contains "\n")
  let lines := candidate.splitOn "\n"
  guard (lineNumber ≤ lines.length)
  pure (String.intercalate "\n" (lines.set (lineNumber - 1) replacement))

def repairBookEdit (key candidate diagnostic model : String) (provider : String := "openai")
    (cancelled : Provider.CancelCheck := pure false) (hooks : Provider.AgentHooks := {}) : IO (Except String (String × Provider.Completion)) := do
  let some lineNumber := diagnosticLineNumber? diagnostic
    | return .error "The compiler did not identify a source line, so no safe bounded line repair was possible."
  let instructions := "You repair exactly one failing line in the supplied numbered neighborhood of a pdfLaTeX document. The compiler's terminal line may follow the actual malformed construct. Return ONLY JSON with numeric line_number and string replacement. Preserve meaning. Never return the full document. Escape LaTeX prose characters such as &, %, _, #, and $ when they are literal."
  let prompt := "Repair the compiler failure using the numbered excerpt. Return only {\"line_number\":N,\"replacement\":\"complete replacement for that one line\"}.\n\nCompiler diagnostic:\n" ++
    truncateText diagnostic 3000 ++ "\n\nNumbered excerpt:\n" ++ numberedBookExcerpt candidate lineNumber
  match ← Provider.completeWithInstructionsTimeout (← bookRepairTimeoutSeconds) 2000 key instructions prompt model provider cancelled hooks with
  | .error message => return .error message
  | .ok completion =>
      let some json := (Lean.Json.parse completion.text.trimAscii.toString).toOption
        | return .error "The automatic repair did not return valid line-repair JSON."
      let some repairedLine := Provider.jsonNatField? json "line_number"
        | return .error "The automatic repair omitted line_number."
      let some replacement := Provider.jsonStringField? json "replacement"
        | return .error "The automatic repair omitted replacement."
      let firstAllowed := lineNumber - 8
      let lastAllowed := lineNumber + 8
      if repairedLine < firstAllowed || repairedLine > lastAllowed then
        return .error "The automatic repair targeted a line outside the bounded diagnostic neighborhood and was rejected."
      let some repaired := replaceBookLine? candidate repairedLine replacement
        | return .error "The automatic repair returned an invalid single-line replacement."
      return .ok (repaired, completion)

structure AppliedChatResult where
  text : String
  completion : Provider.Completion
  bookUpdated : Bool
  notice : Option String

def applyBookChatEdit (key root model : String) (answer : Provider.Completion)
    (trace : IO.Ref (List String)) (provider : String := "openai")
    (cancelled : Provider.CancelCheck := pure false) (hooks : Provider.AgentHooks := {}) : IO AppliedChatResult := do
  if ← cancelled then return AppliedChatResult.mk "The turn stopped before a book update because its session ended or cancellation was requested." answer false (some "No book revision was applied.")
  if let some failure := answer.failure then
    appendProjectDiagnostic root "provider_response_failure" failure
    appendLiveTrace root trace failure
    return { text := failure, completion := answer, bookUpdated := false, notice := none }
  let some edit := bookChatEdit? answer.text
    | do
      if looksLikeBookEnvelope answer.text then
        let diagnostic := bookEnvelopeDiagnostic answer.text
        let failure := "leanfm_malformed_book_reply: The model returned an invalid JSON book reply. " ++ diagnostic ++
          " The hidden source was not displayed or applied. This is a response-format failure, not a reported credit exhaustion. No automatic paid retry was attempted."
        appendProjectDiagnostic root "provider_response_format"
          (diagnostic ++ " " ++ bookReplyShape answer.text)
        appendLiveTrace root trace failure
        return { text := failure, completion := answer, bookUpdated := false, notice := none }
      return AppliedChatResult.mk answer.text answer false none
  if edit.unwrapped then
    appendLiveTrace root trace "Recovered one complete book JSON object from surrounding prose or fences; no paid retry was needed"
    appendProjectDiagnostic root "book_reply_framing" (bookReplyShape answer.text)
  if edit.repairedEscapes then
    appendLiveTrace root trace "Recovered JSON escaping of LaTeX math delimiters deterministically; no paid retry was needed"
    appendProjectDiagnostic root "book_reply_json_escaping" "Recovered illegal JSON math-delimiter escapes before validating the book candidate"
  if edit.source.length > 2000000 then
    return AppliedChatResult.mk edit.reply answer false
      (some "The proposed book revision exceeded the 2 MB editor limit and was not applied.")
  let path := root ++ "/book/main.tex"
  let previous ← readOr path ""
  let source := normalizeBookSource edit.source
  writeAtomic path source
  writeChatStatus root "book-build" "Compiling the proposed book revision."
  appendLiveTrace root trace "Started book build for the proposed revision"
  match ← buildProjectBook root with
  | .ok _ =>
      clearBookRecovery root
      appendLiveTrace root trace "Finished book build for the proposed revision"
      resolveProjectDiagnostics root "Successful book build superseded earlier compiler and repair failures"
        ["book_compiler", "Failed book build", "automatic book repair"]
      return AppliedChatResult.mk edit.reply answer true none
  | .error diagnostic =>
      writeAtomic path previous
      retainBookRecovery root source
      appendProjectDiagnostic root "book_compiler" diagnostic
      appendLiveTrace root trace ("Failed book build: " ++ buildErrorSummary diagnostic ++
        " Full compiler diagnostic: logs/runtime-diagnostics.jsonl")
      let mut candidate := source
      let mut latestDiagnostic := diagnostic
      let mut combined := answer
      let mut latestRepairError : Option String := none
      match deterministicMissingMathRepair? candidate latestDiagnostic with
      | some deterministicCandidate =>
          candidate := deterministicCandidate
          retainBookRecovery root candidate
          writeAtomic path candidate
          appendLiveTrace root trace "Applied deterministic escaping to unescaped underscores on the compiler-reported line"
          match ← buildProjectBook root with
          | .ok _ =>
              clearBookRecovery root
              appendLiveTrace root trace "Finished book build after deterministic LaTeX path escaping; no paid repair was needed"
              resolveProjectDiagnostics root "Deterministic LaTeX path escaping fixed the compiler failure"
                ["book_compiler", "Failed book build", "automatic book repair"]
              return AppliedChatResult.mk edit.reply combined true none
          | .error deterministicDiagnostic =>
              writeAtomic path previous
              appendProjectDiagnostic root "book_compiler" deterministicDiagnostic
              appendLiveTrace root trace ("Deterministic underscore escaping did not complete the build: " ++
                buildErrorSummary deterministicDiagnostic ++ " Full compiler diagnostic: logs/runtime-diagnostics.jsonl")
              latestDiagnostic := deterministicDiagnostic
      | none => pure ()
      for index in List.range 3 do
        if (← chatCancellationRequested root) || (← cancelled) then
          writeAtomic path previous
          appendLiveTrace root trace "Cancelled automatic book repair; restored the previous book"
          return AppliedChatResult.mk edit.reply combined false
            (some ("Book repair was cancelled at a safe boundary, so the original book was restored. " ++
              buildErrorSummary latestDiagnostic))
        let attempt := index + 1
        if (diagnosticLineNumber? latestDiagnostic).isNone then
          appendLiveTrace root trace
            "Skipped automatic book repair because no concrete source line was available; retained the last compiling book"
          return AppliedChatResult.mk edit.reply combined false
            (some ("The proposed revision was restored to the last compiling book. The compiler diagnostic had no safe source location, so no blind paid repair was attempted. LeanFM retained the failed target and full diagnostic for autonomous incremental recovery."))
        appendLiveTrace root trace ("Started automatic book repair " ++ toString attempt ++ " of 3")
        writeChatStatus root "book-repair" (buildErrorSummary latestDiagnostic ++
          " Requesting bounded automatic repair " ++ toString attempt ++ " of 3.") attempt
        match ← repairBookEdit key candidate latestDiagnostic model provider cancelled hooks with
        | .error repairError =>
            latestRepairError := some repairError
            appendLiveTrace root trace ("Automatic book repair " ++ toString attempt ++ " failed: " ++ repairError)
            return AppliedChatResult.mk edit.reply combined false
              (some ("The proposed book revision was restored after the bounded repair request failed. " ++
                buildErrorSummary latestDiagnostic ++ " LeanFM retained the failed target and diagnostic for autonomous recovery. Repair detail: " ++ repairError))
        | .ok (repairedSource, repairCompletion) =>
            combined := addCompletionUsage combined repairCompletion edit.reply
            if repairedSource == candidate then
              latestRepairError := some "The repair repeated the unchanged failing line, so retries stopped to avoid wasting tokens."
              appendLiveTrace root trace "Stopped book repair because the candidate did not change"
              return AppliedChatResult.mk edit.reply combined false
                (some ("The proposed book revision was restored because repair made no progress. " ++
                  buildErrorSummary latestDiagnostic ++ " LeanFM retained the failed target and diagnostic for autonomous recovery."))
            if repairedSource.length > 2000000 then
              return AppliedChatResult.mk edit.reply combined false
                (some "The repaired book revision exceeded the 2 MB editor limit and was not applied.")
            candidate := repairedSource
            retainBookRecovery root candidate
            writeAtomic path candidate
            writeChatStatus root "book-build" ("Compiling automatic repair " ++ toString attempt ++ " of 3.") attempt
            match ← buildProjectBook root with
            | .ok _ =>
                clearBookRecovery root
                appendLiveTrace root trace ("Finished book build after automatic repair " ++ toString attempt ++ " of 3")
                resolveProjectDiagnostics root "Successful repaired book build superseded earlier compiler and repair failures"
                  ["book_compiler", "Failed book build", "automatic book repair"]
                return AppliedChatResult.mk edit.reply combined true none
            | .error repairedDiagnostic =>
                writeAtomic path previous
                appendProjectDiagnostic root "book_compiler" repairedDiagnostic
                appendLiveTrace root trace ("Failed book build after automatic repair " ++
                  toString attempt ++ " of 3: " ++ buildErrorSummary repairedDiagnostic ++
                  " Full compiler diagnostic: logs/runtime-diagnostics.jsonl")
                if sameBuildFailure latestDiagnostic repairedDiagnostic then
                  appendLiveTrace root trace
                    "Stopped book repair because the compiler repeated the same diagnostic class"
                  return AppliedChatResult.mk edit.reply combined false
                    (some ("The proposed book revision was restored because repair repeated the same compiler failure. " ++
                      buildErrorSummary repairedDiagnostic ++
                      " Full diagnostic: logs/runtime-diagnostics.jsonl. No further paid repair was attempted."))
                latestDiagnostic := repairedDiagnostic
      return AppliedChatResult.mk edit.reply combined false
        (some ("The proposed book revision remained invalid after three automatic syntax-repair attempts, so the original book was restored. " ++
          buildErrorSummary latestDiagnostic ++ match latestRepairError with
            | some message => " Last repair request: " ++ message
            | none => ""))

def conversationExcerpt (text : String) : String :=
  let withoutTrace := (text.splitOn "\n\nOperational trace:\n").headD text
  let references := String.join ((attachmentIdsFromText withoutTrace).eraseDups.take 4 |>.map fun id =>
    "\nAttached image: " ++ attachmentPath id)
  -- Reserve room for stable references and the truncation marker inside the
  -- existing per-turn context limit, including images after a long caption.
  truncateText withoutTrace (3400 - references.length) ++ references

def conversationContext (root : String) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let mut turns : List String := []
  let excerpt := conversationExcerpt
  for line in body.splitOn "\n" do
    match line.splitOn "|" with
    | [_messageId, role, encoded, _input, _cached, _output, _total, _responseTimeMs, _sentAtMs, _model] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | [_messageId, role, encoded, _input, _cached, _output, _total, _responseTimeMs, _sentAtMs] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | [_messageId, role, encoded, _input, _cached, _output, _total, _responseTimeMs] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | [_messageId, role, encoded, _input, _cached, _output, _total] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | [role, encoded, _input, _cached, _output, _total] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | _ => pure ()
  pure (String.intercalate "\n\n" ((turns.take 8).reverse))

def referencedAnimationSource? (root context : String) : IO (Option String) := do
  let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["list-files", root] }
  let candidates := out.stdout.splitOn "\n" |>.filterMap fun path =>
    if path.startsWith (root ++ "/") then
      let relative := (path.drop (root.length + 1)).toString
      let lower := relative.toLower
      if lower.endsWith ".gif" || lower.endsWith ".webm" then some relative else none
    else none
  let rec mostRecentlyReferenced : List String → Option String
    | [] => none
    | line :: rest => match candidates.find? (fun candidate => line.contains candidate) with
      | some candidate => some candidate
      | none => mostRecentlyReferenced rest
  pure (mostRecentlyReferenced (context.splitOn "\n" |>.reverse) |>.orElse fun _ => candidates.head?)

def referencedFigureContext (root prompt : String) : IO String := do
  let mut references : List String := []
  for tail in prompt.toLower.splitOn "figure " |>.drop 1 do
    let number := String.ofList (tail.toList.takeWhile Char.isDigit)
    if !number.isEmpty then
      for entry in (← entries (root ++ "/artifacts")) do
        if entry.fileName.startsWith ("figure-" ++ number ++ "-") && entry.fileName.endsWith ".mermaid" then
          let source ← readOr entry.path.toString ""
          references := ("Figure " ++ number ++ " resolves to artifact " ++ entry.fileName ++
            " revision 1:\n```mermaid\n" ++ truncateText source 30000 ++ "\n```") :: references
  if references.isEmpty then pure "" else
    pure ("Resolved figure backreferences:\n\n" ++ String.intercalate "\n\n" references.reverse)

def conversationJson (root : String) (models : List Provider.ModelInfo := []) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let contextWindow := (← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS").getD "128000"
  let mut messages : List String := []
  let mut lineNumber := 0
  for line in body.splitOn "\n" do
    let legacyId := "legacy-" ++ toString lineNumber
    match line.splitOn "|" with
    | [messageId, role, encoded, input, cached, output, total, responseTimeMs, sentAtMs, model] =>
        try
          let text ← base64Decode encoded
          let modelContext := (models.find? (·.id == model)).map (·.contextWindowTokens) |>.getD 0
          let contextWindow := if modelContext > 0 then toString modelContext else contextWindow
          let usage := if role == "assistant" then
              ",\"usage\":{\"input_tokens\":" ++ input ++ ",\"cached_input_tokens\":" ++ cached ++
              ",\"output_tokens\":" ++ output ++ ",\"total_tokens\":" ++ total ++ ",\"context_window_tokens\":" ++
              contextWindow ++ "}"
            else ""
          let responseTime := if role == "assistant" then ",\"response_time_ms\":" ++ responseTimeMs else ""
          let modelField := if role == "assistant" && !model.isEmpty then ",\"model\":\"" ++ jsonEscape model ++ "\"" else ""
          messages := ("{\"message_id\":\"" ++ jsonEscape messageId ++ "\",\"role\":\"" ++ role ++ "\",\"text\":\"" ++ jsonEscape text ++ "\",\"sent_at_ms\":" ++ sentAtMs ++ responseTime ++ usage ++ modelField ++ "}") :: messages
        catch _ => pure ()
    | [messageId, role, encoded, input, cached, output, total, responseTimeMs, sentAtMs] =>
        try
          let text ← base64Decode encoded
          let usage := if role == "assistant" then
              ",\"usage\":{\"input_tokens\":" ++ input ++ ",\"cached_input_tokens\":" ++ cached ++
              ",\"output_tokens\":" ++ output ++ ",\"total_tokens\":" ++ total ++ ",\"context_window_tokens\":" ++
              contextWindow ++ "}"
            else ""
          let responseTime := if role == "assistant" then ",\"response_time_ms\":" ++ responseTimeMs else ""
          messages := ("{\"message_id\":\"" ++ jsonEscape messageId ++ "\",\"role\":\"" ++ role ++ "\",\"text\":\"" ++ jsonEscape text ++ "\",\"sent_at_ms\":" ++ sentAtMs ++ responseTime ++ usage ++ "}") :: messages
        catch _ => pure ()
    | [messageId, role, encoded, input, cached, output, total, responseTimeMs] =>
        try
          let text ← base64Decode encoded
          let usage := if role == "assistant" then
              ",\"usage\":{\"input_tokens\":" ++ input ++ ",\"cached_input_tokens\":" ++ cached ++
              ",\"output_tokens\":" ++ output ++ ",\"total_tokens\":" ++ total ++ ",\"context_window_tokens\":" ++
              contextWindow ++ "}"
            else ""
          let responseTime := if role == "assistant" then ",\"response_time_ms\":" ++ responseTimeMs else ""
          messages := ("{\"message_id\":\"" ++ jsonEscape messageId ++ "\",\"role\":\"" ++ role ++ "\",\"text\":\"" ++ jsonEscape text ++ "\"" ++ responseTime ++ usage ++ "}") :: messages
        catch _ => pure ()
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
        | id :: _role :: _encoded :: _input :: _cached :: _output :: _total :: _rest => id
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
      let title := if id.startsWith "figure-" then
          match id.drop "figure-".length |>.toString |>.splitOn "-" with
          | number :: _ => "Figure " ++ number
          | _ => id
        else id
      artifacts := ("{\"artifact_id\":\"" ++ jsonEscape id ++ "\",\"title\":\"" ++ jsonEscape title ++
        "\",\"kind\":\"mermaid\",\"status\":\"current\",\"revision\":1}") :: artifacts
  pure ("{\"artifacts\":[" ++ String.intercalate "," artifacts.reverse ++ "]}\n")

def sourceFileNames (root projectId : String) : IO (List String) := do
  let sourceRoot := if projectId == "leanfm-workspace" then root else root ++ "/source"
  if !(← (fp sourceRoot).pathExists) then return []
  let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["list-files", sourceRoot] }
  if out.exitCode != 0 then return []
  let sourcePrefix := sourceRoot ++ "/"
  return out.stdout.splitOn "\n" |>.filterMap (fun path =>
    if path.isEmpty then none
    else if path.startsWith sourcePrefix then some (path.drop sourcePrefix.length).toString
    else some path) |>.mergeSort

def sourceFilesJson (root projectId : String) : IO String := do
  pure ("{\"files\":" ++ jsonStrings (← sourceFileNames root projectId) ++ "}\n")

def memoryFilePath? (root projectId id : String) : Option (String × String × String) :=
  let specificationRoot := if projectId == "leanfm-workspace" then "LeanFM/LLMGenerated" else root ++ "/spec"
  match id with
  | "book" => some (root ++ "/book/main.tex", "book/main.tex", "Book")
  | "requirements" => some (specificationRoot ++ "/Requirements.lean", "spec/Requirements.lean", "Requirements")
  | "proto" => some (specificationRoot ++ "/Requirements.proto", "spec/Requirements.proto", "Message schema")
  | "implementation" => some (specificationRoot ++ "/Implementation.lean", "spec/Implementation.lean", "Implementation specification")
  | _ => none

def memoryStatus (id source : String) : String :=
  if source.isEmpty then "missing"
  else if (id == "book" && source.contains "It begins as a sketch") ||
      (id == "requirements" && source.contains "has not yet produced an accepted specification") ||
      (id == "proto" && source.contains "Generated after this project's observable requirements") ||
      (id == "implementation" && source.contains "This remains empty until requirements acceptance") then "bootstrap"
  else "current"

def projectMemoryJson (root projectId : String) : IO String := do
  let definitions := [("book", "discovery"), ("requirements", "requirements"),
    ("proto", "requirements"), ("implementation", "implementation")]
  let mut files : List String := []
  for (id, stage) in definitions do
    if let some (path, displayPath, label) := memoryFilePath? root projectId id then
      let source ← readOr path ""
      files := ("{\"id\":\"" ++ id ++ "\",\"path\":\"" ++ jsonEscape displayPath ++
        "\",\"label\":\"" ++ jsonEscape label ++ "\",\"stage\":\"" ++ stage ++
        "\",\"bytes\":" ++ toString source.length ++ ",\"status\":\"" ++ memoryStatus id source ++ "\"}") :: files
  let sourceNames ← sourceFileNames root projectId
  let sourceRoot := if projectId == "leanfm-workspace" then root else root ++ "/source"
  let mut sourceBytes := 0
  for name in sourceNames do
    sourceBytes := sourceBytes + (← readOr (sourceRoot ++ "/" ++ name) "").length
  pure ("{\"files\":[" ++ String.intercalate "," files.reverse ++
    "],\"source_files\":" ++ toString sourceNames.length ++
    ",\"source_bytes\":" ++ toString sourceBytes ++ "}\n")

def requestsImplementationSource (prompt : String) : Bool :=
  let lower := prompt.toLower
  let words := (String.ofList (lower.toList.map fun c => if c.isAlphanum then c else ' ')).splitOn " "
  words.contains "implement" || lower.contains "generate source" ||
    lower.contains "write the code" || lower.contains "write code" ||
    lower.contains "create the source" || lower.contains "build the server" ||
    lower.contains "build the app" || lower.contains "generate go" ||
    lower.contains "create go"

def saveMermaidArtifacts (root responseText : String) : IO (List String) := do
  let chunks := responseText.splitOn "```mermaid"
  let existing := (← entries (root ++ "/artifacts")).toList.filter fun entry =>
    entry.fileName.endsWith ".mermaid"
  let mut figureNumber := existing.length + 1
  let mut labels : List String := []
  for diagram in chunks.drop 1 do
      let source := (diagram.splitOn "```").headD ""
      let trimmedSource := source.trimAscii.toString
      if !trimmedSource.isEmpty then
        let id ← randomHex 8
        let label := "Figure " ++ toString figureNumber
        writeAtomic (root ++ "/artifacts/figure-" ++ toString figureNumber ++ "-" ++ id ++ ".mermaid") trimmedSource
        labels := label :: labels
        figureNumber := figureNumber + 1
  pure labels.reverse

def submittedProviderKeys (body : String) : Except String (List (String × String)) := do
  let provider := (formValue? body "provider").getD "openai"
  if !supportedProvider provider then throw "Choose OpenAI or Anthropic."
  let legacy := (formValue? body "api_key").getD "" |>.trimAscii.toString
  let mut pairs := []
  for name in ["openai", "anthropic"] do
    let supplied := (formValue? body (name ++ "_api_key")).getD "" |>.trimAscii.toString
    if !supplied.isEmpty && provider == name && !legacy.isEmpty && supplied != legacy then
      throw "Two different keys were supplied for the same provider."
    let key := if !supplied.isEmpty then supplied else if provider == name then legacy else ""
    if !key.isEmpty then pairs := pairs ++ [(name, key)]
  if !pairs.isEmpty && !validCredentialPairs pairs then
    throw "Provider keys must contain at most 4096 visible ASCII characters."
  return pairs

def verifySubmittedKeys (pairs : List (String × String)) : IO (Except String Unit) := do
  for (provider, key) in pairs do
    match ← Provider.verifyKey key provider with
    | .error message => return .error message
    | .ok _ => pure ()
  return .ok ()

def handlePublic (path method request : String) : IO (Option HttpResponse) := do
  if path == "/" && method == "GET" then
    return some (HttpResponse.mk 200 "text/html; charset=utf-8" Web.reactPage ["Cache-Control: no-store"])
  if path == "/assets/chatui-react1.css" || path == "/assets/chatui.css" || path == "/assets/chatui-20261016.css" || path == "/assets/chatui-20261016b.css" || path == "/assets/chatui-20261016c.css" || path == "/assets/chatui-20261016d.css" || path == "/assets/chatui-20261016e.css" || path == "/assets/chatui-20261016f.css" || path == "/assets/chatui-20261016g.css" || path == "/assets/chatui-20261017a.css" || path == "/assets/chatui-20261017b.css" || path == "/assets/chatui-20261017c.css" || path == "/assets/chatui-20261017d.css" || path == "/assets/chatui-20261017e.css" || path == "/assets/chatui-20261017f.css" || path == "/assets/chatui-20261017g.css" || path == "/assets/chatui-20261017h.css" || path == "/assets/chatui-20261017i.css" then
    return some (HttpResponse.mk 200 "text/css; charset=utf-8" Web.css ["Cache-Control: no-store"])
  if path == "/assets/chatui-react1.js" then
    return some (HttpResponse.mk 200 "application/javascript; charset=utf-8" Web.reactJavascript ["Cache-Control: no-store"])
  if path == "/assets/chatui.js" || path == "/assets/chatui-20261016.js" || path == "/assets/chatui-20261016b.js" || path == "/assets/chatui-20261016c.js" || path == "/assets/chatui-20261016d.js" || path == "/assets/chatui-20261016e.js" || path == "/assets/chatui-20261016f.js" || path == "/assets/chatui-20261016g.js" || path == "/assets/chatui-20261017a.js" || path == "/assets/chatui-20261017b.js" || path == "/assets/chatui-20261017c.js" || path == "/assets/chatui-20261017d.js" || path == "/assets/chatui-20261017e.js" || path == "/assets/chatui-20261017f.js" || path == "/assets/chatui-20261017g.js" || path == "/assets/chatui-20261017h.js" || path == "/assets/chatui-20261017i.js" then
    return some (HttpResponse.mk 200 "application/javascript; charset=utf-8" Web.javascript ["Cache-Control: no-store"])
  if path == "/api/accounts" && method == "POST" then
    let body := requestBody request
    let username := (formValue? body "username").getD ""
    let password := (formValue? body "password").getD ""
    if !safeId username || password.length < 8 then return some (errorResponse 400 "Supply a valid username and a password of at least 8 characters.")
    let .ok pairs := submittedProviderKeys body | return some (errorResponse 400 "Supply valid OpenAI and/or Anthropic keys.")
    let (provider, apiKey) :: additionalKeys := pairs | return some (errorResponse 400 "At least one provider API key is required.")
    match ← verifySubmittedKeys pairs with
    | .error message => return some (errorResponse 403 message)
    | .ok _ =>
        match ← createAccount username password provider apiKey additionalKeys with
        | .error message => return some (errorResponse 400 message)
        | .ok _ =>
            match ← login username password with
            | .error message => return some (errorResponse 500 message)
            | .ok token => return some (jsonResponse 201 ("{\"username\":\"" ++ jsonEscape username ++ "\"}\n")
                [← sessionCookieHeader token])
  if path == "/api/login" && method == "POST" then
    let body := requestBody request
    let username := (formValue? body "username").getD ""
    let password := (formValue? body "password").getD ""
    let .ok additions := submittedProviderKeys body | return some (errorResponse 400 "Supply valid OpenAI and/or Anthropic keys.")
    if !additions.isEmpty then
      if !safeId username then return some (errorResponse 403 "Invalid username or password.")
      let record ← readOr ((← accountRoot username) ++ "/password.json") ""
      if record.isEmpty || !(← verifyPassword password record) then
        return some (errorResponse 403 "Invalid username or password.")
      match ← verifySubmittedKeys additions with
      | .error message => return some (errorResponse 403 message)
      | .ok _ => pure ()
      match ← updateCredentialBundle username password additions with
      | .error message => return some (errorResponse 403 message)
      | .ok _ => pure ()
    match ← login username password with
    | .error message => return some (errorResponse 403 message)
    | .ok token => return some (jsonResponse 200 ("{\"username\":\"" ++ jsonEscape username ++ "\"}\n")
        [← sessionCookieHeader token])
  pure none

initialize projectWriterRegistry : IO.Ref (List (String × String)) ← IO.mkRef []
initialize projectWriterRegistryLock : Std.BaseMutex ← Std.BaseMutex.new

def acquireProjectWriter (key owner : String) : IO Bool := do
  projectWriterRegistryLock.lock
  try
    let active ← projectWriterRegistry.get
    if active.any (fun entry => entry.1 == key) then return false
    projectWriterRegistry.set ((key, owner) :: active)
    return true
  finally projectWriterRegistryLock.unlock

def releaseProjectWriter (key : String) : IO Unit := do
  projectWriterRegistryLock.lock
  try projectWriterRegistry.modify (List.filter (fun entry => entry.1 != key))
  finally projectWriterRegistryLock.unlock

def projectWriterOwnedBy (key owner : String) : IO Bool := do
  projectWriterRegistryLock.lock
  try return (← projectWriterRegistry.get).any (fun entry => entry.1 == key && entry.2 == owner)
  finally projectWriterRegistryLock.unlock


def handleAuthenticated (username path method request : String) : IO (Option HttpResponse) := do
  if path == "/api/logout" && method == "POST" then
    let token := (← requestSessionToken? request).getD ""
    unlockedSessions.modify (List.filter (fun session => session.token != token))
    return some (jsonResponse 200 "{\"locked\":true}\n")
  if path == "/api/me" then return some (jsonResponse 200 ("{\"username\":\"" ++ jsonEscape username ++ "\",\"billing\":" ++ (← billingJson username request) ++ "}\n"))
  if path == "/api/client-errors" && method == "POST" then
    let body := requestBody request
    let projectId := (formValue? body "project_id").getD ""
    let description := truncateText ((formValue? body "description").getD "Unspecified browser operation") 1000
    let errorName := truncateText ((formValue? body "error_name").getD "Error") 200
    let message := truncateText ((formValue? body "message").getD "No browser error message") 4000
    let stack := truncateText ((formValue? body "stack").getD "Stack unavailable") 12000
    let page := truncateText ((formValue? body "page").getD "") 1000
    let occurredAt := truncateText ((formValue? body "occurred_at").getD "") 100
    let detail := "operation=" ++ description ++ " error=" ++ errorName ++ ": " ++ message ++
      " page=" ++ page ++ " occurred_at=" ++ occurredAt ++ "\nstack:\n" ++ stack
    match ← authorizedProjectRoot? username projectId with
    | some root =>
        appendProjectDiagnostic root "browser_error" detail
        return some (jsonResponse 202 "{\"recorded\":true}\n")
    | none => return some (errorResponse 404 "Project not found.")
  if path == "/api/projects" && method == "GET" then
    return some (jsonResponse 200 ("{\"projects\":" ++ (← projectListJson username) ++ "}\n"))
  if path == "/api/projects" && method == "POST" then
    let name := (formValue? (requestBody request) "display_name").getD ""
    if name.trimAscii.isEmpty then return some (errorResponse 400 "Project name is required.")
    match ← createProject username name.trimAscii.toString with
    | .error message => return some (errorResponse 400 message)
    | .ok projectId => return some (jsonResponse 201 ("{\"project_id\":\"" ++ projectId ++ "\"}\n"))
  match pathSegments path with
  | "api" :: "projects" :: projectId :: rest =>
      match ← authorizedProjectRoot? username projectId with
      | none => return some (errorResponse 404 "Project not found.")
      | some root =>
          if rest.isEmpty && method == "DELETE" then
            if projectId == "leanfm-workspace" then
              return some (errorResponse 403 "Checked-in projects are read-only and cannot be deleted.")
            let confirmation := (formValue? (requestBody request) "confirmation").getD ""
            match ← deleteProject username projectId confirmation with
            | .error message => return some (errorResponse 400 message)
            | .ok _ => return some (jsonResponse 200 ("{\"deleted_project_id\":\"" ++ jsonEscape projectId ++ "\"}\n"))
          match rest, method with
          | ["markerboard", "media"], "POST" =>
              if !(headerValue? request "Content-Type" |>.getD "").startsWith "application/json" then
                return some (errorResponse 400 "Image uploads require application/json with base64 content.")
              match ← mediaOperation "upload" root (requestBody request) with
              | .error error => return some (errorResponse 400 error)
              | .ok result => return some (jsonResponse 201 (result.compress ++ "\n"))
          | ["conversation"], "GET" =>
              let credentials ← sessionCredentials ((← requestSessionToken? request).getD "") username
              return some (jsonResponse 200 (← conversationJson root (← configuredModelOptions credentials)))
          | ["conversation", "messages", messageId], "DELETE" =>
              if ← deleteConversationMessage root messageId then
                return some (jsonResponse 200 ("{\"deleted_message_id\":\"" ++ jsonEscape messageId ++ "\"}\n"))
              else return some (errorResponse 404 "Message not found.")
          | "files" :: fileParts, "GET" =>
              let relative := String.intercalate "/" (fileParts.map urlDecode)
              if !relative.startsWith "spec/images/" || !relative.toLower.endsWith ".svg" then
                return some (errorResponse 404 "Only project SVG images are available from this route.")
              let realRoot ← IO.FS.realPath (fp root)
              match ← resolveWorkspacePath realRoot.toString relative with
              | .error _ => return some (errorResponse 404 "Project image not found.")
              | .ok imagePath =>
                  let source ← readOr imagePath ""
                  if source.isEmpty then return some (errorResponse 404 "Project image not found.")
                  if source.length > 2000000 then return some (errorResponse 413 "Project SVG exceeds the 2 MB display limit.")
                  return some ({
                    status := 200
                    contentType := "image/svg+xml; charset=utf-8"
                    body := source
                    headers := ["X-Content-Type-Options: nosniff", "Content-Security-Policy: sandbox; default-src 'none'; style-src 'unsafe-inline'"]
                  } : HttpResponse)
          | ["tasks"], "GET" =>
              if projectId == "leanfm-workspace" then
                return some (jsonResponse 200 (tasksJson "LeanFM/LLMGenerated/SharedProjects.lean (accepted workspace revision)"
                  LeanFM.LLMGenerated.SharedProjects.spec
                  ((Requirements.taskConstraints.filter fun constraint => !LeanFM.LLMGenerated.SharedProjects.replacedConstraints.contains constraint.id) ++ LeanFM.LLMGenerated.SharedProjects.constraints) ++ "\n"))
              let derived ← readOr (root ++ "/spec/tasks.json") ""
              if !derived.trimAscii.isEmpty then
                match Lean.Json.parse derived with
                | .ok _ => return some (jsonResponse 200 (derived ++ "\n"))
                | .error _ => return some (errorResponse 422 "spec/tasks.json is not valid derived task JSON.")
              return some (jsonResponse 200 (emptyProjectTasksJson (root ++ "/spec/Requirements.lean") ++ "\n"))
          | ["book"], "GET" =>
              let source ← readOr (root ++ "/book/main.tex") ""
              if source.isEmpty then return some (errorResponse 404 "This project has no editable book/main.tex source.")
              let revision ← keyFingerprint source
              return some (jsonResponse 200 ("{\"source\":\"" ++ jsonEscape source ++
                "\",\"source_revision\":\"" ++ revision ++ "\"}\n"))
          | ["book"], "POST" =>
              if projectId == "leanfm-workspace" then return some (errorResponse 403 "The checked-in project book is read-only.")
              let source := (formValue? (requestBody request) "source").getD ""
              let expectedRevision := (formValue? (requestBody request) "source_revision").getD ""
              if source.isEmpty then return some (errorResponse 400 "Book source cannot be empty.")
              if source.length > 2000000 then return some (errorResponse 413 "Book source exceeds the 2 MB editor limit.")
              let current ← readOr (root ++ "/book/main.tex") ""
              if !expectedRevision.isEmpty && expectedRevision != (← keyFingerprint current) then
                return some (errorResponse 409 "The project book changed after this editor loaded. Reloaded source is required before saving so a newer compiling revision is not overwritten.")
              let normalized := normalizeBookSource source
              writeAtomic (root ++ "/book/main.tex") normalized
              return some (jsonResponse 200 ("{\"saved\":true,\"source_revision\":\"" ++
                (← keyFingerprint normalized) ++ "\"}\n"))
          | ["book", "build"], "POST" =>
              if projectId == "leanfm-workspace" then return some (errorResponse 403 "The checked-in project book is read-only.")
              match ← buildProjectBook root with
              | .ok _ => return some (jsonResponse 200 "{\"built\":true}\n")
              | .error message => return some (errorResponse 422 message)
          | ["artifacts"], "GET" => return some (jsonResponse 200 (← artifactListJson root))
          | ["memory"], "GET" => return some (jsonResponse 200 (← projectMemoryJson root projectId))
          | ["specification"], "GET" =>
              let out ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["project-status", root]}
              if out.exitCode != 0 then return some (errorResponse 422 "Project specification state could not be read.")
              return some (jsonResponse 200 out.stdout)
          | ["specification", gate, revision, "accept"], "POST" =>
              if projectId == "leanfm-workspace" then return some (errorResponse 403 "The self-hosting review is managed from its canonical specifications.")
              let out ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["project-accept", root, gate, revision]}
              if out.exitCode != 0 then return some (errorResponse 409 "This gate is stale, unchecked, or missing its earlier acceptance. Refresh Project memory and review the current checked revision.")
              return some (jsonResponse 200 out.stdout)
          | ["chat", "status"], "GET" => return some (jsonResponse 200 (← chatStatusJson root))
          | ["chat", "trace"], "GET" => return some (jsonResponse 200 (← liveTraceJson root))
          | ["memory", memoryId], "GET" =>
              match memoryFilePath? root projectId memoryId with
              | none => return some (errorResponse 404 "Project memory file not found.")
              | some (memoryPath, _, _) =>
                  let source ← readOr memoryPath ""
                  if source.isEmpty then return some (errorResponse 404 "Project memory file not found.")
                  if source.length > 2000000 then return some (errorResponse 413 "Project memory file exceeds the 2 MB viewer limit.")
                  return some (jsonResponse 200 ("{\"source\":\"" ++ jsonEscape source ++ "\"}\n"))
          | ["chat", "cancel"], "POST" =>
              let callerToken := (← requestSessionToken? request).getD ""
              if callerToken.isEmpty || !(← sessionActive? callerToken username) then
                return some (errorResponse 401 "Unlock the initiating credential session to cancel its model work.")
              if !(← projectWriterOwnedBy root callerToken) then
                return some (errorResponse 403 "Only the initiating credential session can cancel this model turn.")
              if !(← chatCancellationRequested root) then
                IO.FS.createDirAll (fp (root ++ "/.leanfm"))
                writeAtomic (chatCancellationPath root) "cancel requested\n"
              return some (jsonResponse 202 "{\"cancel_requested\":true}\n")
          | ["source"], "GET" => return some (jsonResponse 200 (← sourceFilesJson root projectId))
          | "source" :: fileParts, "GET" =>
              let sourceRoot := if projectId == "leanfm-workspace" then root else root ++ "/source"
              let relative := String.intercalate "/" (fileParts.map urlDecode)
              if !(← sourceFileNames root projectId).contains relative then
                return some (errorResponse 404 "Source file not found.")
              let realSourceRoot ← IO.FS.realPath (fp sourceRoot)
              match ← resolveWorkspacePath realSourceRoot.toString relative with
              | .error _ => return some (errorResponse 404 "Source file not found.")
              | .ok sourcePath =>
                  try
                    let source ← IO.FS.readFile (fp sourcePath)
                    if source.length > 2000000 then return some (errorResponse 413 "Source file exceeds the 2 MB viewer limit.")
                    return some (jsonResponse 200 ("{\"path\":\"" ++ jsonEscape relative ++ "\",\"source\":\"" ++ jsonEscape source ++ "\"}\n"))
                  catch _ => return some (errorResponse 415 "Source file is not readable UTF-8 text.")
          | ["chat"], "POST" =>
              if username.isEmpty then return some (errorResponse 401 "Sign in to unlock your provider keys before sending a model prompt.")
              let submittedPrompt := (formValue? (requestBody request) "prompt").getD ""
              let encodedIds := (formValue? (requestBody request) "attachment_ids").getD "[]"
              let .ok idJson := Lean.Json.parse encodedIds | return some (errorResponse 400 "Invalid attachment IDs.")
              let .ok idValues := idJson.getArr? | return some (errorResponse 400 "Attachment IDs must be a list.")
              let .ok explicitIds := idValues.toList.mapM Lean.Json.getStr?
                | return some (errorResponse 400 "Attachment IDs must be strings.")
              let ids := (explicitIds ++ attachmentIdsFromText submittedPrompt).eraseDups
              if ids.length > 4 then return some (errorResponse 400 "Attach at most four images per message.")
              if submittedPrompt.trimAscii.isEmpty && ids.isEmpty then return some (errorResponse 400 "A prompt or image is required.")
              let text := if submittedPrompt.trimAscii.isEmpty then "Please examine the attached image." else submittedPrompt
              let prompt := text ++ String.join (ids.filter (fun id => !text.contains (attachmentPath id)) |>.map fun id =>
                "\n\n![Attached image](" ++ attachmentPath id ++ ")")
              let prior ← conversationContext root
              let imageIds := (ids ++ (attachmentIdsFromText prior).reverse).eraseDups.take 4
              let images ← match ← resolveChatImages root imageIds with
                | .error error => return some (errorResponse 400 error)
                | .ok images => pure images
              let responseStarted ← IO.monoMsNow
              let token := (← requestSessionToken? request).getD ""
              let credentials ← sessionCredentials token username
              let models ← configuredModelOptions credentials
              let selectedModel := (formValue? (requestBody request) "model").getD (models.head?.map (·.id) |>.getD "")
              if selectedModel.startsWith "anthropic:" && !(credentials.any (·.provider == "anthropic")) then
                return some (errorResponse 409 "No unlocked Anthropic key is available. Open API keys and unlock it with your account password.")
              let some modelInfo := models.find? (·.id == selectedModel)
                | return some (errorResponse 400 "The selected model is not in this server-start model snapshot.")
              match ← credentialKey username request modelInfo.provider with
              | .error message => return some (errorResponse 409 message)
              | .ok key =>
                  clearChatCancellation root
                  writeChatStatus root "model" ("Waiting for " ++ selectedModel ++ " to respond.")
                  writeLiveTrace root []
                  let trace ← IO.mkRef ([] : List String)
                  let composerQuestionId := (formValue? (requestBody request) "composer_question_id").getD ""
                  if !composerQuestionId.isEmpty then
                    let knownQuestion := (structuredQuestionIds prior).contains composerQuestionId
                    let loggedQuestionId := if knownQuestion then composerQuestionId else "unverified"
                    let questionPromptLength := (((formValue? (requestBody request) "composer_question_prompt_length").getD "").toNat?.getD 0).min 4000
                    let composerTextLength := (((formValue? (requestBody request) "composer_text_length").getD "").toNat?.getD 0).min 4000
                    let detail := "source=ordinary_chat_composer question_id=" ++ loggedQuestionId ++
                      " question_known_in_recent_conversation=" ++ (if knownQuestion then "true" else "false") ++
                      " question_prompt_chars=" ++ toString questionPromptLength ++
                      " composer_text_chars=" ++ toString composerTextLength ++
                      " submitted_via_answer_form=false"
                    appendLiveTrace root trace ("Operator continued via ordinary chat composer while structured question was pending: " ++ detail)
                    appendProjectDiagnostic root "structured_question_composer_submission" detail
                  let figureContext ← referencedFigureContext root prompt
                  let guidedContext ← match ← chatLayerContext root "guided" with
                    | .ok context => pure context
                    | .error message => return some (errorResponse 500 message)
                  let diagnosticContext ← recentProjectDiagnostics root
                  let recoveryContext ← bookRecoveryContext root
                  let durableContext ← durableResumeContext root
                  let contextualPrompt := "Selected LeanFM project root: " ++ root ++
                    "\nAuthorized project workspace: " ++ root ++ "\nImplementation artifacts must be written below source/ and will be displayed from there.\n\n" ++
                    "Implementation-result policy: an explicit implementation request must either write and check the complete implementation beneath the selected project's source/ directory after both acceptance gates and the security critique, or return focused structured leanfm-questions naming the missing gate or material decision. Never claim implementation success while source/ is empty.\n\n" ++
                    durableContext ++ guidedContext ++ "\n\n" ++
                    (if diagnosticContext.isEmpty then "" else
                      "LeanFM private diagnostic memory from recent project failures. Use it to avoid repeating a failed path or strategy; do not quote it unless it changes the user-facing remedy:\n" ++ diagnosticContext ++ "\n\n") ++
                    recoveryContext ++
                    (if prior.isEmpty then "" else "Project conversation so far:\n\n" ++ prior ++ "\n\n") ++
                    (if figureContext.isEmpty then "" else figureContext ++ "\n\n") ++
                    "Current user message:\n" ++ prompt
                  appendConversation root "user" prompt
                  let requirementsBefore ← readProjectCanonical root "spec/Requirements.lean"
                  let protoBefore ← readProjectCanonical root "spec/Requirements.proto"
                  let implementationBefore ← readProjectCanonical root "spec/Implementation.lean"
                  let checkedRequirements ← IO.mkRef (none : Option (String × String × String))
                  let checkedImplementation ← IO.mkRef (none : Option String)
                  let lastSpecificationCheck ← IO.mkRef (none : Option String)
                  let failedToolCalls ← IO.mkRef ([] : List String)
                  let workspaceRevision ← IO.mkRef (0 : Nat)
                  let failedCheckDiagnostics ← IO.mkRef ([] : List (String × String))
                  let runner : Provider.ToolRunner := fun name arguments => do
                    if !(← sessionActive? token username) then return "FATAL: initiating credential session ended; no further tool operation is authorized"
                    -- property:recoverable_failures_are_fixed_before_return:
                    -- Different malformed diffs are the same failed strategy.
                    let revision ← workspaceRevision.get
                    let fingerprint := if name == "workspace_patch" then name else
                      name ++ "\n" ++ arguments ++ "\nrevision=" ++ toString revision
                    if (← failedToolCalls.get).contains fingerprint then
                      appendLiveTrace root trace (name ++ " stopped: rejected workspace operation was not executed again; use a different recovery tool")
                      return "FATAL: repeated_failed_tool_call:" ++ name
                    writeChatStatus root "tool" ("Running workspace tool: " ++ name ++ ".")
                    let result ← try runWorkspaceTool root name arguments trace catch error => do
                      let diagnostic := "workspace_tool_exception: " ++ toString error
                      appendLiveTrace root trace (name ++ " rejected: " ++ diagnostic)
                      pure ("ERROR: " ++ diagnostic)
                    if result.startsWith "ERROR:" then
                      failedToolCalls.modify (fingerprint :: ·)
                      if name == "workspace_check" then
                        let diagnostic := checkFailureKey result
                        if (← failedCheckDiagnostics.get).contains (arguments, diagnostic) then
                          appendLiveTrace root trace "workspace_check stopped: correction reproduced the same failure; exact exit code and diagnostic are retained in logs/runtime-diagnostics.jsonl"
                          return "FATAL: repeated_failed_tool_call:workspace_check"
                        failedCheckDiagnostics.modify ((arguments, diagnostic) :: ·)
                    else
                      if name == "leanfm_check" then
                        lastSpecificationCheck.set (some arguments)
                        checkedRequirements.set (some (← readProjectCanonical root "spec/Requirements.lean", ← readProjectCanonical root "spec/Requirements.proto", ← readProjectCanonical root "book/main.tex"))
                        if !((toolArgument? arguments "implementation").getD "").isEmpty then
                          checkedImplementation.set (some (← readProjectCanonical root "spec/Implementation.lean"))
                      if name == "workspace_write" || name == "workspace_patch" then
                        workspaceRevision.modify (· + 1)
                      if name == "workspace_check" then
                        if (← failedCheckDiagnostics.get).any (·.1 == arguments) then
                          appendProjectDiagnostic root "resolved" ("Successful workspace_check verified recovery: " ++ arguments)
                        failedCheckDiagnostics.modify (List.filter (·.1 != arguments))
                    writeChatStatus root "model" ("Workspace tool " ++ name ++ " completed; waiting for " ++ selectedModel ++ ".")
                    pure result
                  let cancelled : Provider.CancelCheck := do
                    if ← chatCancellationRequested root then return true
                    return !(← sessionActive? token username)
                  let reportedUsage ← IO.mkRef
                    ({ text := "", inputTokens := 0, cachedInputTokens := 0, outputTokens := 0, totalTokens := 0 } : Provider.Completion)
                  let hooks : Provider.AgentHooks := {
                    beforeRequest := do
                      let some billing ← sessionBilling? token username
                        | return some "The login session ended; no further provider request was sent."
                      if billing.tokensUsed >= billing.tokenBudget then
                        let failure := "leanfm_session_token_budget_exhausted: The local session token safety budget is exhausted. Stopped before another provider request. Earlier completed edits remain in Project memory; this is not a reported provider credit exhaustion."
                        appendLiveTrace root trace failure
                        return some failure
                      return none
                    onResponse := fun report => do
                      reportedUsage.modify (fun usage => Provider.addUsage usage report.usage)
                      recordSessionUsage token username report.usage.totalTokens
                      let total ← reportedUsage.get
                      appendLiveTrace root trace ("Provider round " ++ toString report.round ++
                        " (" ++ modelInfo.provider ++ ", " ++ modelInfo.model ++ "): " ++ report.outcome ++
                        "; input=" ++ toString report.usage.inputTokens ++
                        " cached=" ++ toString report.usage.cachedInputTokens ++
                        " output=" ++ toString report.usage.outputTokens ++
                        " cumulative_total=" ++ toString total.totalTokens ++
                        " request_chars=" ++ toString report.requestChars ++
                        " text_chars=" ++ toString report.textChars ++
                        " tool_calls=" ++ toString report.toolCalls)
                  }
                  match ← Provider.completeAgent key (workspaceAgentInstructions root) contextualPrompt modelInfo.model runner
                      (cancelled := cancelled) (provider := modelInfo.provider)
                      (maxOutputTokens := modelInfo.maxOutputTokens) (webSearch := modelInfo.webSearch) (hooks := hooks) (images := images) with
                  | .error "agent_cancelled" =>
                      clearChatCancellation root
                      writeChatStatus root "cancelled" "Agent turn cancelled at a safe boundary."
                      let responseFinished ← IO.monoMsNow
                      let responseTimeMs := responseFinished - responseStarted
                      let responseText := "```leanfm-result\n{\"status\":\"warn\"}\n```\n\nAgent turn cancelled. Durable edits completed before cancellation remain in Project memory."
                      appendConversation root "assistant" responseText none responseTimeMs selectedModel
                      return some (jsonResponse 200 ("{\"text\":\"" ++ jsonEscape responseText ++ "\",\"model\":\"" ++ jsonEscape selectedModel ++ "\",\"cancelled\":true,\"book_updated\":false,\"response_time_ms\":" ++ toString responseTimeMs ++ "}\n"))
                  | .error message =>
                      clearChatCancellation root
                      writeChatStatus root "failed" message
                      appendProjectDiagnostic root "terminal_agent_error" message
                      return some (errorResponse 502 message)
                  | .ok initialAnswer =>
                      let mut answer := initialAnswer
                      let initialVisibleText := if answer.failure.isSome then "" else bookVisibleText answer.text
                      let missingBeforeRecovery ← missingMediaReferences root initialVisibleText
                      if !missingBeforeRecovery.isEmpty then
                        appendProjectDiagnostic root "missing_project_artifact_reference"
                          ("Assistant completion referenced project media that does not exist: " ++
                            String.intercalate ", " missingBeforeRecovery)
                        appendLiveTrace root trace ("Detected nonexistent project media before returning a completion: " ++
                          String.intercalate ", " missingBeforeRecovery ++ "; starting one bounded output-only recovery")
                        let recoveryPrompt := contextualPrompt ++
                          "\n\nYour previous completion referenced project media that LeanFM verified does not exist: " ++
                          String.intercalate ", " missingBeforeRecovery ++
                          ". This is the single bounded recovery attempt. Do not repeat those paths or claim they were created. For a PDF illustration, replace external image dependencies with a self-contained vector drawing in the book source. Return the corrected result now; use verified artifacts only."
                        let noRepeatTool : Provider.ToolRunner := fun name _ => do
                          appendLiveTrace root trace ("Blocked workspace tool " ++ name ++ " during bounded missing-artifact response repair to prevent replaying completed operations")
                          pure ("FATAL: repeated_failed_tool_call:" ++ name)
                        match ← Provider.completeAgent key (workspaceAgentInstructions root) recoveryPrompt modelInfo.model noRepeatTool
                            (cancelled := cancelled) (provider := modelInfo.provider)
                            (maxOutputTokens := modelInfo.maxOutputTokens) (webSearch := modelInfo.webSearch) (hooks := hooks) with
                        | .error recoveryError =>
                            appendLiveTrace root trace ("Missing-artifact recovery did not complete: " ++ recoveryError)
                        | .ok recovered =>
                            if let some failure := recovered.failure then
                              answer := addCompletionUsage answer recovered answer.text
                              appendLiveTrace root trace ("Missing-artifact recovery failed: " ++ failure)
                            else
                              let recoveredVisibleText := bookVisibleText recovered.text
                              answer := addCompletionUsage answer recovered recovered.text
                              let stillMissing ← missingMediaReferences root recoveredVisibleText
                              if stillMissing.isEmpty && !recoveredVisibleText.isEmpty then
                                appendLiveTrace root trace "Bounded missing-artifact recovery returned only verified project media references"
                                resolveProjectDiagnostics root "Bounded media-reference recovery verified the corrected project artifact response"
                                  ["missing_project_artifact_reference"]
                              else if recoveredVisibleText.isEmpty then
                                appendLiveTrace root trace "Bounded missing-artifact recovery returned an invalid book envelope"
                              else
                                appendLiveTrace root trace ("Bounded missing-artifact recovery still references nonexistent media: " ++ String.intercalate ", " stillMissing)
                      writeChatStatus root "validation" "Validating durable outputs from the model response."
                      let invalidAnswer := answer.failure.isSome ||
                        (looksLikeBookEnvelope answer.text && (bookChatEdit? answer.text).isNone)
                      let applied ← if !invalidAnswer && (projectId == "leanfm-workspace") then
                          pure (AppliedChatResult.mk (bookVisibleText answer.text) answer false none)
                        else applyBookChatEdit key root modelInfo.model answer trace modelInfo.provider cancelled hooks
                      clearChatCancellation root
                      answer := applied.completion
                      if applied.bookUpdated then
                        if let some arguments ← lastSpecificationCheck.get then
                          appendLiveTrace root trace "Rechecking the canonical specification against this turn's committed book revision without another provider request"
                          discard <| runner "leanfm_check" arguments
                          writeChatStatus root "validation" "Validating the final book and specification revisions."
                      let observed ← reportedUsage.get
                      -- A rejected repair may have consumed tokens before its
                      -- line-repair JSON failed validation. Never lose that usage.
                      if observed.totalTokens > answer.totalTokens then
                        answer := { observed with text := answer.text, failure := answer.failure }
                      match ← requestSessionToken? request with
                      | some token => recordSessionUsage token username (answer.totalTokens - observed.totalTokens)
                      | none => pure ()
                      let mp4Requested := prompt.toLower.contains "mp4"
                      let mut activity := (← trace.get).reverse
                      if !invalidAnswer && mp4Requested && !(activity.any fun item => item.startsWith "Generated " && item.toLower.contains ".mp4") then
                        match ← referencedAnimationSource? root (prior ++ "\n" ++ prompt) with
                        | none =>
                            trace.modify ("workspace_transcode_mp4 rejected: No project GIF or WebM source was found." :: ·)
                            writeLiveTrace root (← trace.get).reverse
                        | some source =>
                            let stem := if source.toLower.endsWith ".webm" then source.dropEnd 5 else source.dropEnd 4
                            let destination := stem.toString ++ ".mp4"
                            let _ ← runner "workspace_transcode_mp4"
                              ("{\"input_path\":\"" ++ jsonEscape (root ++ "/" ++ source) ++
                                "\",\"output_path\":\"" ++ jsonEscape (root ++ "/" ++ destination) ++ "\"}")
                      activity := (← trace.get).reverse
                      let mp4Artifact := activity.find? fun item => item.startsWith "Generated " && item.toLower.contains ".mp4"
                      let missingRequiredArtifact := mp4Requested && mp4Artifact.isNone
                      let implementationRequested := requestsImplementationSource prompt
                      let sourceFiles ← sourceFileNames root projectId
                      let missingMedia := ← missingMediaReferences root applied.text
                      if !missingMedia.isEmpty then
                        let detail := "Assistant output referenced project media that does not exist: " ++
                          String.intercalate ", " missingMedia
                        appendLiveTrace root trace ("Rejected false project-media reference: " ++ String.intercalate ", " missingMedia)
                        appendProjectDiagnostic root "missing_project_artifact_reference" detail
                      activity := (← trace.get).reverse
                      let returnedQuestions := !invalidAnswer &&
                        (applied.text.contains "```leanfm-questions" || applied.text.contains "```leanfm-qustions")
                      if returnedQuestions then
                        let ids := structuredQuestionIds applied.text
                        let idSummary := if ids.isEmpty then "question_ids=unavailable" else
                          "question_ids=" ++ String.intercalate "," ids
                        appendLiveTrace root trace
                          ("Assistant returned structured question(s): " ++ idSummary ++
                            "; see logs/runtime-diagnostics.jsonl category=structured_question_asked")
                        appendProjectDiagnostic root "structured_question_asked"
                          (idSummary ++ " question_count=" ++ toString ids.length ++
                            " parsed=" ++ (if ids.isEmpty then "false" else "true"))
                      let missingRequiredSource := implementationRequested && sourceFiles.isEmpty && !returnedQuestions
                      let requirementsAfter ← readProjectCanonical root "spec/Requirements.lean"
                      let protoAfter ← readProjectCanonical root "spec/Requirements.proto"
                      let implementationAfter ← readProjectCanonical root "spec/Implementation.lean"
                      let bookAfter ← readProjectCanonical root "book/main.tex"
                      let uncheckedRequirements := (requirementsBefore != requirementsAfter || protoBefore != protoAfter || implementationBefore != implementationAfter ||
                        (applied.bookUpdated && (← lastSpecificationCheck.get).isSome)) &&
                        (← checkedRequirements.get) != some (requirementsAfter, protoAfter, bookAfter)
                      let uncheckedImplementation := implementationBefore != implementationAfter &&
                        (← checkedImplementation.get) != some implementationAfter
                      let uncheckedSpecification := uncheckedRequirements || uncheckedImplementation
                      let warned := returnedQuestions || applied.notice.isSome || activity.any fun item => (item.splitOn "rejected").length > 1 || (item.splitOn "Failed check:").length > 1
                      let status := if invalidAnswer || missingRequiredArtifact || missingRequiredSource || uncheckedSpecification || !missingMedia.isEmpty then "fail" else if warned then "warn" else "success"
                      if status != "success" then
                        let reason := if invalidAnswer then "provider response or book envelope failed"
                          else if missingRequiredArtifact then "required MP4 artifact missing"
                          else if missingRequiredSource then "requested implementation source missing"
                          else if uncheckedSpecification then "changed specification has no successful current canonical check"
                          else if !missingMedia.isEmpty then "assistant referenced project media that does not exist"
                          else if returnedQuestions then "agent returned blocking questions"
                          else if applied.notice.isSome then "book update warning"
                          else "workspace operation or check reported a failure"
                        appendProjectDiagnostic root "chat_result_warning"
                          ("status=" ++ status ++ " model=" ++ selectedModel ++ " reason=" ++ reason)
                      let statusMarker := "```leanfm-result\n{\"status\":\"" ++ status ++ "\"}\n```\n\n"
                      let mp4Failure := activity.find? fun item => item.startsWith "workspace_transcode_mp4 rejected:"
                      let visibleAnswer := if invalidAnswer then applied.text else if uncheckedSpecification then
                        "The specification edits have not passed their current canonical check. LeanFM rejected the completion claim and kept the last validated task views. Use leanfm_check with the project's actual RequirementSpec constant and, when changing implementation mappings, its typed ImplementationSpec constant. Compiler details are in the Operational trace and reports/specification-check/compiler.log."
                        else if missingRequiredSource then
                        "The requested implementation was not produced: no files exist beneath the selected project's source/ directory. LeanFM rejected the prose or pasted-code substitute. Accept the missing specification gate or answer the focused blocking questions, then resend the implementation request."
                        else if missingRequiredArtifact then
                        match mp4Failure with
                        | some failure => "The requested MP4 was not produced. " ++ failure
                        | none => "The requested MP4 was not produced because the MP4 transcoder was not invoked. LeanFM rejected the response instead of presenting another substitute or follow-up question."
                        else if !missingMedia.isEmpty then
                        "The response still references project media that was never created, so LeanFM rejected the completion claim after one bounded correction attempt. Missing file(s): " ++
                          String.intercalate ", " missingMedia ++ ". The exact failure is saved to logs/runtime-diagnostics.jsonl; no further paid retry will run."
                        else match mp4Artifact with
                          | some generated =>
                              let path := String.ofList ((generated.drop 10).toString.toList.takeWhile (· != ' '))
                              applied.text ++ "\n\nInline MP4: " ++ path
                          | none => applied.text
                      let visibleAnswer := match applied.notice with
                        | some warning => visibleAnswer ++ "\n\n" ++ warning
                        | none => visibleAnswer
                      let responseText := statusMarker ++ visibleAnswer ++ (if activity.isEmpty then "" else
                        "\n\nOperational trace:\n" ++ String.intercalate "\n" (activity.map ("- " ++ ·)))
                      writeChatStatus root (if invalidAnswer then "failed" else "complete")
                        (if invalidAnswer then applied.text else if applied.bookUpdated then "Agent turn completed; the book revision compiled." else "Agent turn completed.")
                      let figureLabels ← saveMermaidArtifacts root responseText
                      let responseText := if figureLabels.isEmpty then responseText else
                        responseText ++ "\n\nFigures created: " ++ String.intercalate ", " figureLabels ++ "."
                      let responseFinished ← IO.monoMsNow
                      let responseTimeMs := responseFinished - responseStarted
                      appendConversation root "assistant" responseText (some answer) responseTimeMs selectedModel
                      let fallbackContext ← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS"
                      let context := if modelInfo.contextWindowTokens > 0 then toString modelInfo.contextWindowTokens
                        else fallbackContext.getD "128000"
                      return some (jsonResponse 200 ("{\"text\":\"" ++ jsonEscape responseText ++ "\",\"model\":\"" ++ jsonEscape selectedModel ++
                        "\",\"provider\":\"" ++ jsonEscape modelInfo.provider ++ "\",\"book_updated\":" ++ (if applied.bookUpdated then "true" else "false") ++ ",\"usage\":{\"input_tokens\":" ++
                        toString answer.inputTokens ++ ",\"cached_input_tokens\":" ++ toString answer.cachedInputTokens ++
                        ",\"output_tokens\":" ++ toString answer.outputTokens ++ ",\"total_tokens\":" ++ toString answer.totalTokens ++
                        ",\"context_window_tokens\":" ++ context ++ "},\"response_time_ms\":" ++ toString responseTimeMs ++ "}\n"))
          | _, _ => pure ()
  | _ => pure ()
  pure none

def admittedWorkspaceRequest (method request : String) : IO Bool := do
  let port := ((← IO.getEnv "LEANFM_PORT").getD "8080")
  let host := (headerValue? request "Host").getD ""
  let configured := ((← IO.getEnv "LEANFM_PUBLIC_ORIGIN").getD "")
  let localHosts := ["127.0.0.1:" ++ port, "localhost:" ++ port, "[::1]:" ++ port] ++
    (if port == "80" then ["127.0.0.1", "localhost", "[::1]"] else [])
  let configuredHost := (configured.splitOn "://" |>.drop 1).headD ""
  if !localHosts.contains host && (configured.isEmpty || host != configuredHost) then return false
  if method == "GET" || method == "HEAD" || method == "OPTIONS" then return true
  if (headerValue? request "Sec-Fetch-Site").getD "" == "cross-site" then return false
  match headerValue? request "Origin" with
  | none => return true
  | some origin => return origin == "http://" ++ host || (!configured.isEmpty && origin == configured)

def dispatchWorkspaceRequest (username path method request : String) : IO (Option HttpResponse) := do
  let mutation := method != "GET" && method != "HEAD" && method != "OPTIONS" && !path.endsWith "/chat/cancel"
  if mutation && (path == "/api/projects/leanfm-workspace" || path.startsWith "/api/projects/leanfm-workspace/") then
    return some (errorResponse 403 "The self-hosting LeanFM workspace is read-only through the project API.")
  let writerKey ← if mutation then
      match pathSegments path with
      | ["api", "projects"] => pure (some ((← workspaceRoot) ++ "/projects"))
      | "api" :: "projects" :: projectId :: _ => authorizedProjectRoot? username projectId
      | _ => pure none
    else pure none
  if let some key := writerKey then
    if !(← acquireProjectWriter key ((← requestSessionToken? request).getD "")) then return some (errorResponse 409 "This project already has an active writer. Wait for that operation to finish; this request made no edit or provider call.")
  try handleAuthenticated username path method request
  finally
    if let some key := writerKey then releaseProjectWriter key

def handle? (path method request : String) : IO (Option HttpResponse) := do
  if path.startsWith "/api/" && !(← admittedWorkspaceRequest method request) then
    return some (errorResponse 403 "The request Host or browser Origin is not admitted for this local workspace.")
  match ← handlePublic path method request with
  | some response => pure (some response)
  | none =>
      if path.startsWith "/api/" then
        let user ← sessionUser? request
        let shared := path == "/api/projects" || path.startsWith "/api/projects/" || path == "/api/client-errors"
        if !shared && user.isNone then return some (errorResponse 401 "Authentication required.")
        let username := user.getD ""
        do
            let result ← dispatchWorkspaceRequest username path method request
            match result with
            | some response =>
                if response.status >= 400 then
                  match pathSegments path with
                  | "api" :: "projects" :: projectId :: _ =>
                      match ← authorizedProjectRoot? username projectId with
                      | some root =>
                          appendProjectDiagnostic root "http_error"
                            (method ++ " " ++ path ++ " status=" ++ toString response.status ++
                              " response=" ++ truncateText response.body 8000)
                      | none => pure ()
                  | _ => pure ()
                pure (some response)
            | none => pure none
      else pure none

def logUnhandledProjectFailure (path requestId request detail : String) : IO Unit := do
  match pathSegments path with
  | "api" :: "projects" :: projectId :: _ =>
      match ← sessionUser? request with
      | none => pure ()
      | some username =>
          match ← authorizedProjectRoot? username projectId with
          | none => pure ()
          | some root =>
              appendProjectDiagnostic root "unhandled_http_500"
                ("request_id=" ++ requestId ++ " path=" ++ path ++ " detail=" ++ detail)
  | _ => pure ()

end LeanFM.ChatUI.Server
