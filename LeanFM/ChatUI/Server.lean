import LeanFM.ChatUI.Provider
import LeanFM.ChatUI.Web
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
  jsonResponse status ("{\"error\":\"" ++ jsonEscape message ++
    "\",\"action\":\"" ++ jsonEscape (errorAction status) ++
    "\",\"code\":\"leanfm_http_" ++ toString status ++ "\"}\n")

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
      match ← sessionBilling? token username with
      | none => pure (.error "Password login is required to unlock the API key.")
      | some billing =>
          if billing.tokensUsed >= billing.tokenBudget then
            pure (.error "The local session token safety budget is exhausted. Log in again only after reviewing the provider project's dollar spend limit and usage.")
          else match ← sessionCredential? token username with
            | none => pure (.error "Password login is required to unlock the API key.")
            | some key => pure (.ok key)

def validModelId (model : String) : Bool :=
  !model.isEmpty && model.length ≤ 128 && model.toList.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.' || c == ':'

initialize discoveredModels : IO.Ref (Option (List String)) ← IO.mkRef none

def responseModelCandidate (model : String) : Bool :=
  let lower := model.toLower
  validModelId model &&
    !(model.startsWith "ft:") &&
    !["embedding", "moderation", "whisper", "transcribe", "tts", "realtime", "audio", "image", "dall-e", "search"].any
      (fun fragment => lower.contains fragment)

def uniqueModels (models : List String) : List String :=
  models.foldl (fun found model => if found.contains model then found else found ++ [model]) []

def configuredModels (key : Option String := none) : IO (List String) := do
  let fallback := (← IO.getEnv "LEANFM_LLM_MODEL").getD "gpt-5-mini"
  match ← IO.getEnv "LEANFM_LLM_MODELS" with
  | some configured =>
      let models := configured.splitOn "," |>.map (·.trimAscii.toString) |>.filter validModelId
      pure (uniqueModels (fallback :: models))
  | none =>
      match ← discoveredModels.get with
      | some models => pure models
      | none =>
          let discovered ← match key with
            | none => pure []
            | some providerKey =>
                match ← Provider.listedModels providerKey with
                | .ok models => pure (models.filter responseModelCandidate)
                | .error _ => pure []
          let models := uniqueModels (fallback :: discovered) |>.take 40
          if !discovered.isEmpty then discoveredModels.set (some models)
          pure models

def billingJson (username request : String) : IO String := do
  match cookieValue? request "leanfm_session" with
  | none => pure "null"
  | some token =>
      match ← sessionBilling? token username with
      | none => pure "null"
      | some billing =>
          let key ← sessionCredential? token username
          let models ← configuredModels key
          let model := models.headD "gpt-5-mini"
          let modelJson := "[" ++ String.intercalate "," (models.map fun value => "\"" ++ jsonEscape value ++ "\"") ++ "]"
          let remaining := billing.tokenBudget - billing.tokensUsed
          pure ("{\"provider\":\"" ++ jsonEscape billing.provider ++
            "\",\"credential_ref\":\"" ++ jsonEscape billing.credentialRef ++
            "\",\"key_fingerprint\":\"" ++ jsonEscape billing.credentialFingerprint ++
            "\",\"model\":\"" ++ jsonEscape model ++ "\",\"models\":" ++ modelJson ++
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
  if projectId == "go-server-example" then
    if ← (fp "projects/go-server/project.json").pathExists then return some "projects/go-server" else return none
  if !safeId projectId then return none
  let root ← projectRoot username projectId
  if ← (fp (root ++ "/manifest.json")).pathExists then pure (some root) else pure none

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

def tasksJson (source : String) : String :=
  let items := Requirements.spec.tasks.map fun task =>
    let constraints := Requirements.taskConstraints.filter (·.task == task.id) |>.map fun constraint =>
      "{\"id\":\"" ++ jsonEscape constraint.id ++ "\",\"predicate\":\"" ++
      jsonEscape constraint.predicate ++ "\",\"formula\":\"" ++
      jsonEscape (propertyCtlFormula .always constraint.predicate) ++
      "\",\"origin\":\"Requirements.lean where_\"}"
    let properties := Requirements.spec.properties.filter (·.task == task.id) |>.map fun property =>
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
    "\",\"constraints\":[" ++ String.intercalate "," constraints ++ "]}"
  "{\"source\":\"" ++ jsonEscape source ++ "\",\"validation\":{\"errors\":0,\"warnings\":0},\"tasks\":[" ++
    String.intercalate "," items ++ "]}"

def emptyProjectTasksJson (source : String) : String :=
  "{\"source\":\"" ++ jsonEscape source ++
  "\",\"accepted\":false,\"validation\":{\"errors\":0,\"warnings\":0},\"tasks\":[]}"

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

def resolveProjectDiagnostics (root resolution : String) (signatures : List String) : IO Unit := do
  let path := diagnosticLogPath root
  let old ← readOr path ""
  let kept := old.splitOn "\n" |>.filter fun line =>
    !line.isEmpty && !(signatures.any fun signature => line.contains signature)
  writeAtomic path (String.intercalate "\n" kept ++ if kept.isEmpty then "" else "\n")
  appendProjectDiagnostic root "resolved" resolution

def workspaceRelativePath? (value : String) : Bool :=
  !value.isEmpty && !value.startsWith "/" && value.length ≤ 4096 &&
    (value.splitOn "/" |>.all fun part => !part.isEmpty && part != "." && part != "..")

def underRoot (root candidate : String) : Bool :=
  candidate == root || candidate.startsWith (root ++ "/")

def resolveWorkspacePath (root relative : String) (allowMissing : Bool := false) : IO (Except String String) := do
  if !workspaceRelativePath? relative then return .error "Path must be a non-empty relative path without '.' or '..' segments."
  let canonicalRoot ← IO.FS.realPath (fp root)
  let canonical := canonicalRoot.toString
  let candidate := canonical ++ "/" ++ relative
  try
    let resolved ← IO.FS.realPath (fp candidate)
    if underRoot canonical resolved.toString then return .ok resolved.toString
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
  | "workspace_list" =>
      let relative ← projectRelativeToolPath root ((toolArgument? arguments "path").getD ".")
      let normalized := if relative == "." then "" else relative
      let resolved ← if normalized.isEmpty then pure (.ok root) else resolveWorkspacePath root normalized
      match resolved with
      | .error message => fail message
      | .ok path =>
          record ("Listed " ++ (if normalized.isEmpty then "." else normalized))
          let out ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["list-files", path] }
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
          pure (compactToolResult (if out.stdout.isEmpty then "No matches." else out.stdout))
  | "workspace_patch" =>
      let some patch := toolArgument? arguments "patch" | fail "Missing patch."
      if patch.length > 2000000 then return ← fail "Patch exceeds the 2 MB limit."
      record "Applying a workspace patch"
      let checked ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["git-apply-check", root] } (some patch)
      if checked.exitCode != 0 then return ← fail ("Patch check failed: " ++ compactToolResult checked.stderr)
      let applied ← IO.Process.output { cmd := "scripts/chatui_command.sh", args := #["git-apply", root] } (some patch)
      if applied.exitCode != 0 then return ← fail ("Patch apply failed: " ++ compactToolResult applied.stderr)
      record "Applied workspace patch"
      pure "OK"
  | "workspace_write" =>
      let some supplied := toolArgument? arguments "path" | fail "Missing path."
      let relative ← projectRelativeToolPath root supplied
      let some content := toolArgument? arguments "content" | fail "Missing content."
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
            resolveProjectDiagnostics root ("Successful write superseded earlier failures for " ++ relative) [relative]
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
              if out.exitCode != 0 then return ← fail ("GIF generator failed: " ++ compactToolResult (out.stdout ++ out.stderr))
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
                  args := #["transcode-mp4", inputPath, outputPath]
                } catch error => return ← fail ("Could not run MP4 whitelist command: " ++ toString error)
              if out.exitCode != 0 then return ← fail ("MP4 transcode failed: " ++ compactToolResult (out.stdout ++ out.stderr))
              let bytes ← IO.FS.readBinFile (fp outputPath)
              let header := String.fromUTF8? (bytes.extract 4 (min 12 bytes.size))
              if bytes.size < 12 || !(header.getD "").startsWith "ftyp" then return ← fail "Transcoder output is not an ISO base media MP4 file."
              if bytes.size > 536870912 then return ← fail "Generated MP4 exceeds the 512 MB project media limit."
              record ("Generated " ++ outputRelative ++ " (" ++ toString bytes.size ++ " bytes)")
              pure ("OK: " ++ outputRelative)
  | _ => fail "Unknown workspace tool."

def workspaceAgentInstructions (root : String) : String :=
  "When a workspace tool returns ERROR or a check fails, inspect that concrete diagnostic, change the input or strategy, exhaust safe reversible alternatives, rerun validation, and continue the original requested task. For every generated or substantially rewritten text file, preserve the last revision that passed its proportional check and work on a project-local scratch candidate. Promote it only after validation. On any validation failure, retain the complete bounded diagnostic, restore the last known-good file, divide the intended delta into small ordered independently checkable pieces, apply and validate one piece at a time, and immediately back out the first failing piece. Never resubmit the complete failing candidate, repeat an unchanged failure class, or spend another model request before narrowing the change or failure location. Running a project-local compiler, test, or named check is already authorized reversible work: run it directly and never ask whether the user wants it run. Do not ask the user to retry an authorized reversible operation and do not repeat the identical failing call. Ask only when recovery needs new authority, a destructive or expensive choice, or an unavailable dependency. " ++
  Provider.hostedChatInstructions ++ " The authenticated user explicitly authorizes you to inspect and edit files only beneath the selected project root " ++ root ++ ". Use the supplied workspace tools to do requested engineering work, not merely describe a plan. All final implementation code, build files, generated language bindings, and implementation tests belong beneath source/. Specification artifacts remain beneath spec/. Never present implementation source as a chat code fence or prose substitute: write each file with workspace_write or workspace_patch, run a proportional check, and reply with a concise artifact summary. Use the hosted web_search tool when the user asks you to search the public internet, and cite the selected source URL. When the user asks to find or show an internet image, show the selected image immediately using Markdown image syntax with a direct HTTPS image URL, followed by its source-page URL; do not ask whether to show, preview, import, encode, or register it. workspace_write creates missing parent directories safely. Read relevant AGENTS.md and SKILL.md files before edits. Preserve unrelated changes. Never try to access a path outside this workspace. A descriptive Lean file containing lists of strings is not a LeanFM grammar: candidate requirements must define and validate a typed RequirementSpec with TaskRequirement and TaskGrammar values, and must derive spec/tasks.json for the Grammar and Tasks UI. If that grammar is absent or invalid, create or repair it before implementation files. Never implement source, generate language bindings, or cross either acceptance gate unless the durable project state records the user's explicit acceptance. Immediately before any source-generation pass, critique the accepted design for security. Identify trust boundaries protected assets attacker capabilities and abuse cases, then encode applicable security requirements as durable MUST NOT constraints covering authorization tenant and project isolation secrets logs injection path or symlink escape executable content resource exhaustion replay request confusion privilege expansion and fail-open behavior. Map each negative requirement to an implementation control plus a negative test or proof obligation. If a material threat lacks an accepted mitigation, return to the implementation-specification gate instead of generating source or inventing policy. Immediately before recommending or performing a commit, inspect the exact candidate diff and generated artifacts rather than relying on the earlier design critique. Check for secrets, authorization or isolation failures, injection, path or symlink escape, executable content, unbounded or unsafe generated artifacts, replay, request confusion, privilege expansion, and fail-open behavior; state the positive invariant and map each material forbidden behavior to a control and negative test or proof. Never commit or claim commit readiness while a material finding is unresolved. Never imitate generated output: invoke the real generator or report the exact missing executable. When you create or discuss media below the selected project root, cite its project-relative path; the host renders supported image and video paths inline automatically. For an explicit animated GIF request, write a project-local Python/Pillow generator, run workspace_run_gif_generator, cite the resulting .gif path, and do not substitute canvas WebM or another format or ask whether a substitute is acceptable. For an explicit MP4 request, create or locate the project-local GIF or WebM source, run workspace_transcode_mp4, and cite the resulting project-relative .mp4 path so the remote chat renders an inline video. Never substitute WebM GIF canvas HTML a conversion script or file:// instructions for a requested MP4, and never claim MP4 completion until the transcoder has validated the actual file. Do not ask about data URIs, manifests, HTML tags, encodings, or download mechanisms, and do not create alternate compact media unless the user explicitly requests one. The user is operating the served UI remotely: provide authenticated served project artifacts, never directions to open server-local file:// paths. Question policy is strict: act instead of asking whenever a request is identifiable and reversible; choose a conventional or recommended default unless it changes an observable requirement, crosses an acceptance gate, is destructive, or is expensive and irreversible. When the user explicitly asks whether the project has enough detail to one-shot the software, inspect the durable book requirements implementation mapping and source, identify decisions whose absence prevents a conforming one-pass implementation, and ask at most the two highest-impact unresolved questions in the structured question form; this readiness request is a question-triggering instruction, not an implementation command. The words do it, generate, proceed, continue, now, show, or accept defaults prohibit another clarification round for that requested result. A structured answer includes Question ID and permanently closes both that ID and the same semantic question. After receiving any structured answer, produce a material result or durable edit before asking anything new. A requested result gets at most one clarification turn; afterward state reasonable assumptions and produce the best reversible result. Do not ask a follow-up question when the requested reversible action is already identifiable. Do not claim a file changed unless workspace_write or workspace_patch succeeded. Run a proportional named check after edits. Summarize the outcome, changed files, and validation concisely. Tool activity is shown separately, so do not invent or narrate hidden reasoning."

structure BookChatEdit where
  reply : String
  source : String

def bookChatEdit? (text : String) : Option BookChatEdit := do
  let trimmed := text.trimAscii.toString
  let jsonText :=
    if trimmed.startsWith "```json" && trimmed.endsWith "```" then
      ((trimmed.drop 7).dropEnd 3 |>.trimAscii).toString
    else trimmed
  let json ← (Lean.Json.parse jsonText).toOption
  let reply ← Provider.jsonStringField? json "reply"
  let source ← Provider.jsonStringField? json "book_source"
  guard (!reply.trimAscii.isEmpty && !source.trimAscii.isEmpty)
  pure { reply, source }

def chatLayerContext (root layer : String) : IO (Except String String) := do
  let book ← readOr (root ++ "/book/main.tex") ""
  let requirements ← readOr (root ++ "/spec/Requirements.lean") ""
  let implementation ← readOr (root ++ "/spec/Implementation.lean") ""
  let diagramGuidance := "Diagram input is intentionally permissive. The user may supply prose, simplified interaction pseudocode, Mermaid, PlantUML, or refer to an attached sketch or public-web image. Infer the intended semantics and ask only when a material ambiguity remains. When a diagram is useful, return corrected renderable Mermaid in a fenced mermaid block. When motion or simulation materially answers the request, return an actual triple-backtick leanfm-canvas fence containing a literal accessible canvas element and self-contained inline script with no external resources; never spell out the words fenced leanfm-canvas and never print its source as ordinary chat prose. For MCP, model the Model Context Protocol JSON-RPC lifecycle between host/client and MCP server (initialize, notifications/initialized, capability discovery such as tools/list, and invocation such as tools/call with their results), not MQTT broker traffic. Preserve the user's original as provenance; do not claim that an informal sketch is an accepted derived LeanFM view.\n\n"
  match layer with
  | "guided" => return .ok (diagramGuidance ++ "Working mode: GUIDED PROJECT CONVERSATION. Begin with the user's informal problem and continuously revise the durable book. Do not front-load an exhaustive questionnaire. Ask focused questions only when the answer changes an observable requirement, proof, derived view, or later implementation decision. When the book is specific enough to identify actors, scenarios, messages, outcomes, failure behavior, and requested measurements, say so and ask the remaining focused questions needed to prepare the observable-requirements acceptance gate. Never accept that gate for the user. Only after explicit requirements acceptance, approach the implementation-specification gate by asking unresolved choices such as programming language, process and deployment model, HTTP or another transport, persistence, concurrency, reliability, and tests. Never silently cross either acceptance gate. Return ONLY one JSON object with exactly these string fields: {\"reply\":\"the conversational response, including at most the focused questions needed now\",\"book_source\":\"the complete revised book/main.tex\"}. Current complete book source:\n\n" ++ truncateText book 70000 ++ "\n\nCurrent project Requirements.lean:\n\n" ++ truncateText requirements 40000 ++ "\n\nCurrent project Implementation.lean:\n\n" ++ truncateText implementation 40000)
  | "book" => return .ok (diagramGuidance ++ "Working layer: BOOK. The user's ordinary request is an instruction to edit the durable project book, not merely advice about how they could edit it. Revise book/main.tex while preserving valid LaTeX and the user's existing material. Do not present generated requirements or code as accepted merely because they are discussed. Return ONLY one JSON object with exactly these string fields: {\"reply\":\"a concise description of the edit\",\"book_source\":\"the complete revised book/main.tex\"}. Do not wrap the JSON in prose or Markdown. If the user is only asking a question and no source change is appropriate, return a normal prose answer instead. Current complete book source:\n\n" ++ truncateText book 70000)
  | "requirements" => return .ok (diagramGuidance ++ "Working layer: REQUIREMENTS. Derive observable requirements from the book, preserve unresolved design as unresolved, and prepare the requirements acceptance gate. Current book:\n\n" ++ truncateText book 50000 ++ "\n\nCurrent Requirements.lean:\n\n" ++ truncateText requirements 50000)
  | "implementation_spec" => return .ok (diagramGuidance ++ "Working layer: IMPLEMENTATION SPECIFICATION. Map accepted requirements to languages, transports, runtime APIs, source files, tests, and explicit implementation issues such as Go services or HTTP projection. Do not implement before the separate implementation-specification acceptance gate. Current Requirements.lean:\n\n" ++ truncateText requirements 50000 ++ "\n\nCurrent Implementation.lean:\n\n" ++ truncateText implementation 50000)
  | "implementation" => return .ok (diagramGuidance ++ "Working layer: IMPLEMENTATION. Implement only from accepted book, requirements, and implementation-specification revisions; preserve traceability and run checks. Current Implementation.lean:\n\n" ++ truncateText implementation 70000)
  | _ => return .error "Unknown chat working layer."

def buildProjectBook (root : String) : IO (Except String Unit) := do
  let bookPath := fp (root ++ "/book")
  if !(← (fp (root ++ "/book/main.tex")).pathExists) then return .error "book/main.tex does not exist in this project."
  cleanProjectBookIntermediates root
  let realBook ← IO.FS.realPath bookPath
  let testOnlyUnsandboxed := (← IO.getEnv "LEANFM_TEST_UNSANDBOXED_BOOK_BUILD") == some "1" &&
    realBook.toString.startsWith "/tmp/leanfm-chatui-check."
  let out ← if testOnlyUnsandboxed then
      IO.Process.output { cmd := "/usr/bin/make", args := #["-C", realBook.toString] }
    else
      IO.Process.output {
        cmd := "bwrap"
        args := #["--die-with-parent", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--ro-bind", "/usr", "/usr",
          "--ro-bind", "/bin", "/bin", "--ro-bind", "/lib", "/lib", "--ro-bind", "/lib64", "/lib64",
          "--ro-bind", "/etc", "/etc", "--ro-bind", "/var/lib/texmf", "/var/lib/texmf", "--proc", "/proc", "--dev", "/dev",
          "--tmpfs", "/tmp", "--bind", realBook.toString, "/work", "--chdir", "/work",
          "--setenv", "HOME", "/tmp", "--", "/usr/bin/make"] }
  if out.exitCode == 0 then return .ok ()
  let processTail := truncateTailText (out.stdout ++ "\n" ++ out.stderr) 12000
  let latexLog ← readOr (root ++ "/book/main.log") ""
  let logTail := if latexLog.isEmpty then "" else
    "\n\nTail of book/main.log:\n" ++ truncateTailText latexLog 12000
  return .error ("Book build failed:\n" ++ processTail ++ logTail)

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

def repairBookEdit (key candidate diagnostic model : String) : IO (Except String (String × Provider.Completion)) := do
  let some lineNumber := diagnosticLineNumber? diagnostic
    | return .error "The compiler did not identify a source line, so no safe bounded line repair was possible."
  let instructions := "You repair exactly one failing line in the supplied numbered neighborhood of a pdfLaTeX document. The compiler's terminal line may follow the actual malformed construct. Return ONLY JSON with numeric line_number and string replacement. Preserve meaning. Never return the full document. Escape LaTeX prose characters such as &, %, _, #, and $ when they are literal."
  let prompt := "Repair the compiler failure using the numbered excerpt. Return only {\"line_number\":N,\"replacement\":\"complete replacement for that one line\"}.\n\nCompiler diagnostic:\n" ++
    truncateText diagnostic 3000 ++ "\n\nNumbered excerpt:\n" ++ numberedBookExcerpt candidate lineNumber
  match ← Provider.completeWithInstructionsTimeout (← bookRepairTimeoutSeconds) 2000 key instructions prompt model with
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
    (trace : IO.Ref (List String)) : IO AppliedChatResult := do
  let some edit := bookChatEdit? answer.text
    | return AppliedChatResult.mk answer.text answer false none
  if edit.source.length > 2000000 then
    return AppliedChatResult.mk edit.reply answer false
      (some "The proposed book revision exceeded the 2 MB editor limit and was not applied.")
  let path := root ++ "/book/main.tex"
  let previous ← readOr path ""
  writeAtomic path edit.source
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
      retainBookRecovery root edit.source
      appendProjectDiagnostic root "book_compiler" diagnostic
      appendLiveTrace root trace ("Failed book build: " ++ buildErrorSummary diagnostic ++
        " Full compiler diagnostic: logs/runtime-diagnostics.jsonl")
      let mut candidate := edit.source
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
        if ← chatCancellationRequested root then
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
        match ← repairBookEdit key candidate latestDiagnostic model with
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

def conversationContext (root : String) : IO String := do
  let body ← readOr (root ++ "/conversations/main.log") ""
  let mut turns : List String := []
  let excerpt := fun text =>
    let withoutTrace := match text.splitOn "\n\nOperational trace:\n" with
      | first :: _ => first
      | [] => text
    truncateText withoutTrace 3500
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

def conversationJson (root : String) : IO String := do
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
  let sourceRoot := if projectId == "leanfm-workspace" || projectId == "go-server-example" then root else root ++ "/source"
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
  let sourceRoot := if projectId == "leanfm-workspace" || projectId == "go-server-example" then root else root ++ "/source"
  let mut sourceBytes := 0
  for name in sourceNames do
    sourceBytes := sourceBytes + (← readOr (sourceRoot ++ "/" ++ name) "").length
  pure ("{\"files\":[" ++ String.intercalate "," files.reverse ++
    "],\"source_files\":" ++ toString sourceNames.length ++
    ",\"source_bytes\":" ++ toString sourceBytes ++ "}\n")

def requestsImplementationSource (prompt : String) : Bool :=
  let lower := prompt.toLower
  lower.contains "implement" || lower.contains "generate source" ||
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
            if projectId == "leanfm-workspace" || projectId == "go-server-example" then
              return some (errorResponse 403 "Checked-in projects are read-only and cannot be deleted.")
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
                return some (jsonResponse 200 (tasksJson "LeanFM/ChatUI/Requirements.lean (live workspace)" ++ "\n"))
              let manifest ← readOr (root ++ "/manifest.json") ""
              let name := (jsonStringValue? manifest "display_name").getD projectId
              discard <| repairSelfHostingSpecificationLeak root name
              let derived ← readOr (root ++ "/spec/tasks.json") ""
              if !derived.trimAscii.isEmpty then
                match Lean.Json.parse derived with
                | .ok _ => return some (jsonResponse 200 (derived ++ "\n"))
                | .error _ => return some (errorResponse 422 "spec/tasks.json is not valid derived task JSON.")
              return some (jsonResponse 200 (emptyProjectTasksJson (root ++ "/spec/Requirements.lean") ++ "\n"))
          | ["book"], "GET" =>
              if projectId != "leanfm-workspace" then
                let sourcePath := root ++ "/book/main.tex"
                let source ← readOr sourcePath ""
                let leanFMSource ← readOr "book/main.tex" ""
                if source.isEmpty || (!leanFMSource.isEmpty && source == leanFMSource) then
                  let manifest ← readOr (root ++ "/manifest.json") ""
                  let name := (jsonStringValue? manifest "display_name").getD "Untitled project"
                  provisionProjectBook root name
                  match ← buildProjectBook root with
                  | .error message => return some (errorResponse 500 message)
                  | .ok _ => pure ()
              let source ← readOr (root ++ "/book/main.tex") ""
              if source.isEmpty then return some (errorResponse 404 "This project has no editable book/main.tex source.")
              let revision ← keyFingerprint source
              return some (jsonResponse 200 ("{\"source\":\"" ++ jsonEscape source ++
                "\",\"source_revision\":\"" ++ revision ++ "\"}\n"))
          | ["book"], "POST" =>
              if projectId == "leanfm-workspace" || projectId == "go-server-example" then return some (errorResponse 403 "The checked-in project book is read-only.")
              let source := (formValue? (requestBody request) "source").getD ""
              let expectedRevision := (formValue? (requestBody request) "source_revision").getD ""
              if source.isEmpty then return some (errorResponse 400 "Book source cannot be empty.")
              if source.length > 2000000 then return some (errorResponse 413 "Book source exceeds the 2 MB editor limit.")
              let current ← readOr (root ++ "/book/main.tex") ""
              if !expectedRevision.isEmpty && expectedRevision != (← keyFingerprint current) then
                return some (errorResponse 409 "The project book changed after this editor loaded. Reloaded source is required before saving so a newer compiling revision is not overwritten.")
              writeAtomic (root ++ "/book/main.tex") source
              return some (jsonResponse 200 ("{\"saved\":true,\"source_revision\":\"" ++
                (← keyFingerprint source) ++ "\"}\n"))
          | ["book", "build"], "POST" =>
              if projectId == "leanfm-workspace" || projectId == "go-server-example" then return some (errorResponse 403 "The checked-in project book is read-only.")
              match ← buildProjectBook root with
              | .ok _ => return some (jsonResponse 200 "{\"built\":true}\n")
              | .error message => return some (errorResponse 422 message)
          | ["artifacts"], "GET" => return some (jsonResponse 200 (← artifactListJson root))
          | ["memory"], "GET" => return some (jsonResponse 200 (← projectMemoryJson root projectId))
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
              if !(← chatCancellationRequested root) then
                IO.FS.createDirAll (fp (root ++ "/.leanfm"))
                writeAtomic (chatCancellationPath root) "cancel requested\n"
              return some (jsonResponse 202 "{\"cancel_requested\":true}\n")
          | ["source"], "GET" => return some (jsonResponse 200 (← sourceFilesJson root projectId))
          | "source" :: fileParts, "GET" =>
              let sourceRoot := if projectId == "leanfm-workspace" || projectId == "go-server-example" then root else root ++ "/source"
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
              let prompt := (formValue? (requestBody request) "prompt").getD ""
              if prompt.trimAscii.isEmpty then return some (errorResponse 400 "A prompt is required.")
              let responseStarted ← IO.monoMsNow
              match ← credentialKey username request with
              | .error message => return some (errorResponse 409 message)
              | .ok key =>
                  let models ← configuredModels (some key)
                  let selectedModel := (formValue? (requestBody request) "model").getD (models.headD "gpt-5-mini")
                  if !models.contains selectedModel then return some (errorResponse 400 "The selected model is not in this server-start model snapshot.")
                  clearChatCancellation root
                  writeChatStatus root "model" ("Waiting for " ++ selectedModel ++ " to respond.")
                  writeLiveTrace root []
                  let prior ← conversationContext root
                  let figureContext ← referencedFigureContext root prompt
                  let guidedContext ← match ← chatLayerContext root "guided" with
                    | .ok context => pure context
                    | .error message => return some (errorResponse 500 message)
                  let diagnosticContext ← recentProjectDiagnostics root
                  let recoveryContext ← bookRecoveryContext root
                  let contextualPrompt := "Selected LeanFM project root: " ++ root ++
                    "\nAuthorized project workspace: " ++ root ++ "\nImplementation artifacts must be written below source/ and will be displayed from there.\n\n" ++
                    "Implementation-result policy: an explicit implementation request must either write and check the complete implementation beneath the selected project's source/ directory after both acceptance gates and the security critique, or return focused structured leanfm-questions naming the missing gate or material decision. Never claim implementation success while source/ is empty.\n\n" ++
                    guidedContext ++ "\n\n" ++
                    (if diagnosticContext.isEmpty then "" else
                      "LeanFM private diagnostic memory from recent project failures. Use it to avoid repeating a failed path or strategy; do not quote it unless it changes the user-facing remedy:\n" ++ diagnosticContext ++ "\n\n") ++
                    recoveryContext ++
                    (if prior.isEmpty then "" else "Project conversation so far:\n\n" ++ prior ++ "\n\n") ++
                    (if figureContext.isEmpty then "" else figureContext ++ "\n\n") ++
                    "Current user message:\n" ++ prompt
                  appendConversation root "user" prompt
                  let trace ← IO.mkRef ([] : List String)
                  let failedToolCalls ← IO.mkRef ([] : List String)
                  let runner : Provider.ToolRunner := fun name arguments => do
                    let fingerprint := name ++ "\n" ++ arguments
                    if (← failedToolCalls.get).contains fingerprint then
                      appendLiveTrace root trace (name ++ " stopped: identical failed call was not executed again")
                      return "FATAL: repeated_failed_tool_call:" ++ name
                    writeChatStatus root "tool" ("Running workspace tool: " ++ name ++ ".")
                    let result ← runWorkspaceTool root name arguments trace
                    if result.startsWith "ERROR:" then failedToolCalls.modify (fingerprint :: ·)
                    writeChatStatus root "model" ("Workspace tool " ++ name ++ " completed; waiting for " ++ selectedModel ++ ".")
                    pure result
                  match ← Provider.completeAgent key (workspaceAgentInstructions root) contextualPrompt selectedModel runner
                      (cancelled := chatCancellationRequested root) with
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
                  | .ok answer =>
                      writeChatStatus root "validation" "Validating durable outputs from the model response."
                      let applied ← if projectId == "leanfm-workspace" || projectId == "go-server-example" then
                          pure (AppliedChatResult.mk answer.text answer false none)
                        else applyBookChatEdit key root selectedModel answer trace
                      clearChatCancellation root
                      let answer := applied.completion
                      match cookieValue? request "leanfm_session" with
                      | some token => recordSessionUsage token username answer.totalTokens
                      | none => pure ()
                      let mp4Requested := prompt.toLower.contains "mp4"
                      let mut activity := (← trace.get).reverse
                      if mp4Requested && !(activity.any fun item => item.startsWith "Generated " && item.toLower.contains ".mp4") then
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
                      let returnedQuestions := (applied.text.splitOn "```leanfm-questions").length > 1
                      let missingRequiredSource := implementationRequested && sourceFiles.isEmpty && !returnedQuestions
                      let warned := returnedQuestions || applied.notice.isSome || activity.any fun item => (item.splitOn "rejected").length > 1 || (item.splitOn "Failed check:").length > 1
                      let status := if missingRequiredArtifact || missingRequiredSource then "fail" else if warned then "warn" else "success"
                      if status != "success" then
                        let reason := if missingRequiredArtifact then "required MP4 artifact missing"
                          else if missingRequiredSource then "requested implementation source missing"
                          else if returnedQuestions then "agent returned blocking questions"
                          else if applied.notice.isSome then "book update warning"
                          else "workspace operation or check reported a failure"
                        appendProjectDiagnostic root "chat_result_warning"
                          ("status=" ++ status ++ " model=" ++ selectedModel ++ " reason=" ++ reason)
                      let statusMarker := "```leanfm-result\n{\"status\":\"" ++ status ++ "\"}\n```\n\n"
                      let mp4Failure := activity.find? fun item => item.startsWith "workspace_transcode_mp4 rejected:"
                      let visibleAnswer := if missingRequiredSource then
                        "The requested implementation was not produced: no files exist beneath the selected project's source/ directory. LeanFM rejected the prose or pasted-code substitute. Accept the missing specification gate or answer the focused blocking questions, then resend the implementation request."
                        else if missingRequiredArtifact then
                        match mp4Failure with
                        | some failure => "The requested MP4 was not produced. " ++ failure
                        | none => "The requested MP4 was not produced because the MP4 transcoder was not invoked. LeanFM rejected the response instead of presenting another substitute or follow-up question."
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
                      writeChatStatus root "complete" (if applied.bookUpdated then "Agent turn completed; the book revision compiled." else "Agent turn completed.")
                      let figureLabels ← saveMermaidArtifacts root responseText
                      let responseText := if figureLabels.isEmpty then responseText else
                        responseText ++ "\n\nFigures created: " ++ String.intercalate ", " figureLabels ++ "."
                      let responseFinished ← IO.monoMsNow
                      let responseTimeMs := responseFinished - responseStarted
                      appendConversation root "assistant" responseText (some answer) responseTimeMs selectedModel
                      let context := (← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS").getD "128000"
                      return some (jsonResponse 200 ("{\"text\":\"" ++ jsonEscape responseText ++ "\",\"model\":\"" ++ jsonEscape selectedModel ++ "\",\"book_updated\":" ++ (if applied.bookUpdated then "true" else "false") ++ ",\"usage\":{\"input_tokens\":" ++
                        toString answer.inputTokens ++ ",\"cached_input_tokens\":" ++ toString answer.cachedInputTokens ++
                        ",\"output_tokens\":" ++ toString answer.outputTokens ++ ",\"total_tokens\":" ++ toString answer.totalTokens ++
                        ",\"context_window_tokens\":" ++ context ++ "},\"response_time_ms\":" ++ toString responseTimeMs ++ "}\n"))
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
        | some username =>
            let result ← handleAuthenticated username path method request
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
