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

def emptyProjectTasksJson (source : String) : String :=
  "{\"source\":\"" ++ jsonEscape source ++
  "\",\"accepted\":false,\"validation\":{\"errors\":0,\"warnings\":0},\"tasks\":[]}"

def appendConversation (root role text : String) (usage : Option Provider.Completion := none) (responseTimeMs : Nat := 0) : IO Unit := do
  let path := root ++ "/conversations/main.log"
  let old ← readOr path ""
  let messageId ← randomHex 12
  let usageFields := match usage with
    | none => "0|0|0|0"
    | some u => s!"{u.inputTokens}|{u.cachedInputTokens}|{u.outputTokens}|{u.totalTokens}"
  writeAtomic path (old ++ messageId ++ "|" ++ role ++ "|" ++ base64Encode text ++ "|" ++ usageFields ++ "|" ++ toString responseTimeMs ++ "\n")

def truncateText (value : String) (limit : Nat) : String :=
  if value.length ≤ limit then value else String.ofList (value.toList.take limit) ++ "\n[truncated]\n"

def workspaceRelativePath? (value : String) : Bool :=
  !value.isEmpty && !value.startsWith "/" && value.length ≤ 4096 &&
    (value.splitOn "/" |>.all fun part => !part.isEmpty && part != "." && part != "..")

def underRoot (root candidate : String) : Bool :=
  candidate == root || candidate.startsWith (root ++ "/")

def resolveWorkspacePath (root relative : String) (allowMissing : Bool := false) : IO (Except String String) := do
  if !workspaceRelativePath? relative then return .error "Path must be a non-empty relative path without '.' or '..' segments."
  let candidate := root ++ "/" ++ relative
  try
    let resolved ← IO.FS.realPath (fp candidate)
    if underRoot root resolved.toString then return .ok resolved.toString
    return .error "Path escapes the server launch workspace."
  catch _ =>
    if !allowMissing then return .error "Path does not exist."
    let parent := (fp candidate).parent.getD (fp root)
    try
      let resolvedParent ← IO.FS.realPath parent
      if underRoot root resolvedParent.toString then return .ok candidate
      return .error "Path parent escapes the server launch workspace."
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
        if !underRoot root resolved.toString then return .error "Destination directory escapes the server launch workspace."
        ensureWorkspaceDestinationFrom root resolved.toString rest
      catch _ => return .error ("Destination component " ++ directory ++ " is not an accessible directory.")

def ensureWorkspaceDestination (root relative : String) : IO (Except String String) := do
  if !workspaceRelativePath? relative then return .error "Path must be a non-empty relative path without '.' or '..' segments."
  ensureWorkspaceDestinationFrom root root (relative.splitOn "/")

def toolArgument? (arguments key : String) : Option String := do
  let json ← (Lean.Json.parse arguments).toOption
  Provider.jsonStringField? json key

def compactToolResult (value : String) : String := truncateText value 30000

def runWorkspaceTool (root name arguments : String) (trace : IO.Ref (List String)) : IO String := do
  let record (message : String) := trace.modify (message :: ·)
  let fail (message : String) : IO String := do record (name ++ " rejected: " ++ message); pure ("ERROR: " ++ message)
  match name with
  | "workspace_list" =>
      let relative := (toolArgument? arguments "path").getD "."
      let normalized := if relative == "." then "" else relative
      let resolved ← if normalized.isEmpty then pure (.ok root) else resolveWorkspacePath root normalized
      match resolved with
      | .error message => fail message
      | .ok path =>
          record ("Listed " ++ (if normalized.isEmpty then "." else normalized))
          let out ← IO.Process.output { cmd := "rg", args := #["--files", path] }
          let body := out.stdout.splitOn "\n" |>.map (fun line =>
            if line.startsWith (root ++ "/") then (line.drop (root.length + 1)).toString else line) |>.intersperse "\n" |> String.join
          pure (compactToolResult body)
  | "workspace_read" =>
      let some relative := toolArgument? arguments "path" | fail "Missing path."
      match ← resolveWorkspacePath root relative with
      | .error message => fail message
      | .ok path =>
          record ("Read " ++ relative)
          try pure (compactToolResult (← IO.FS.readFile (fp path)))
          catch _ => fail "File is not readable UTF-8 text."
  | "workspace_search" =>
      let some query := toolArgument? arguments "query" | fail "Missing query."
      let relative := (toolArgument? arguments "path").getD "."
      let normalized := if relative == "." then "" else relative
      let resolved ← if normalized.isEmpty then pure (.ok root) else resolveWorkspacePath root normalized
      match resolved with
      | .error message => fail message
      | .ok path =>
          record ("Searched " ++ (if normalized.isEmpty then "." else normalized) ++ " for " ++ truncateText query 80)
          let out ← IO.Process.output { cmd := "rg", args := #["-n", "-F", "--", query, path] }
          pure (compactToolResult (if out.stdout.isEmpty then "No matches." else out.stdout))
  | "workspace_patch" =>
      let some patch := toolArgument? arguments "patch" | fail "Missing patch."
      if patch.length > 2000000 then return ← fail "Patch exceeds the 2 MB limit."
      record "Applying a workspace patch"
      let checked ← IO.Process.output { cmd := "git", args := #["-C", root, "apply", "--check", "--whitespace=nowarn", "-"] } (some patch)
      if checked.exitCode != 0 then return ← fail ("Patch check failed: " ++ compactToolResult checked.stderr)
      let applied ← IO.Process.output { cmd := "git", args := #["-C", root, "apply", "--whitespace=nowarn", "-"] } (some patch)
      if applied.exitCode != 0 then return ← fail ("Patch apply failed: " ++ compactToolResult applied.stderr)
      record "Applied workspace patch"
      pure "OK"
  | "workspace_write" =>
      let some relative := toolArgument? arguments "path" | fail "Missing path."
      let some content := toolArgument? arguments "content" | fail "Missing content."
      if content.length > 2000000 then return ← fail "File exceeds the 2 MB write limit."
      match ← ensureWorkspaceDestination root relative with
      | .error message => fail message
      | .ok path =>
          try
            writeAtomic path content
            record ("Wrote " ++ relative ++ " (" ++ toString content.length ++ " characters)")
            pure "OK"
          catch error => fail ("Write failed: " ++ toString error)
  | "workspace_check" =>
      let some target := toolArgument? arguments "target" | fail "Missing target."
      let (cmd, args) := match target with
        | "build" => ("make", #["-C", root, "build"])
        | "check" => ("make", #["-C", root, "check"])
        | "book" => ("make", #["-C", root, "book"])
        | "http-check" => ("make", #["-C", root, "http-check"])
        | "go-test" => ("go", #["-C", root, "test", "./..."])
        | _ => ("", #[])
      if cmd.isEmpty then return ← fail "Unknown check target."
      record ("Started check: " ++ target)
      let out ← IO.Process.output { cmd, args }
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
              let out ← IO.Process.output {
                cmd := "timeout"
                args := #["60", "bwrap", "--die-with-parent", "--new-session",
                  "--unshare-pid", "--unshare-ipc", "--unshare-uts",
                  "--ro-bind", "/usr", "/usr", "--ro-bind", "/usr/local", "/usr/local",
                  "--ro-bind", "/lib", "/lib", "--ro-bind", "/lib64", "/lib64",
                  "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                  "--bind", root, "/work", "--chdir", "/work",
                  "/usr/bin/python3", "/work/" ++ scriptRelative, "/work/" ++ outputRelative]
              }
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
                  cmd := "timeout"
                  args := #["120", "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", inputPath, "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                    "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                    "-profile:v", "high", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                    outputPath]
                  env := #[("LD_LIBRARY_PATH", none), ("LD_PRELOAD", none)]
                } catch error => return ← fail ("Could not run ffmpeg: " ++ toString error)
              if out.exitCode != 0 then return ← fail ("MP4 transcode failed: " ++ compactToolResult (out.stdout ++ out.stderr))
              let bytes ← IO.FS.readBinFile (fp outputPath)
              let header := String.fromUTF8? (bytes.extract 4 (min 12 bytes.size))
              if bytes.size < 12 || !(header.getD "").startsWith "ftyp" then return ← fail "Transcoder output is not an ISO base media MP4 file."
              if bytes.size > 536870912 then return ← fail "Generated MP4 exceeds the 512 MB project media limit."
              record ("Generated " ++ outputRelative ++ " (" ++ toString bytes.size ++ " bytes)")
              pure ("OK: " ++ outputRelative)
  | _ => fail "Unknown workspace tool."

def workspaceAgentInstructions (root : String) : String :=
  Provider.hostedChatInstructions ++ " The authenticated user explicitly authorizes you to inspect and edit files beneath the web server launch directory " ++ root ++ ". Use the supplied workspace tools to do requested engineering work, not merely describe a plan. Use the hosted web_search tool when the user asks you to search the public internet, and cite the selected source URL. When the user asks to find or show an internet image, show the selected image immediately using Markdown image syntax with a direct HTTPS image URL, followed by its source-page URL; do not ask whether to show, preview, import, encode, or register it. workspace_write creates missing parent directories safely. Read relevant AGENTS.md and SKILL.md files before edits. Preserve unrelated changes. Never try to access a path outside this workspace. A descriptive Lean file containing lists of strings is not a LeanFM grammar: candidate requirements must define and validate a typed RequirementSpec with TaskRequirement and TaskGrammar values, and must derive spec/tasks.json for the Grammar and Tasks UI. If that grammar is absent or invalid, create or repair it before implementation files. Never implement source, generate language bindings, or cross either acceptance gate unless the durable project state records the user's explicit acceptance. Never imitate generated output: invoke the real generator or report the exact missing executable. When you create or discuss media below the selected project root, cite its project-relative path; the host renders supported image and video paths inline automatically. For an explicit animated GIF request, write a project-local Python/Pillow generator, run workspace_run_gif_generator, cite the resulting .gif path, and do not substitute canvas WebM or another format or ask whether a substitute is acceptable. For an explicit MP4 request, create or locate the project-local GIF or WebM source, run workspace_transcode_mp4, and cite the resulting project-relative .mp4 path so the remote chat renders an inline video. Never substitute WebM GIF canvas HTML a conversion script or file:// instructions for a requested MP4, and never claim MP4 completion until the transcoder has validated the actual file. Do not ask about data URIs, manifests, HTML tags, encodings, or download mechanisms, and do not create alternate compact media unless the user explicitly requests one. The user is operating the served UI remotely: provide authenticated served project artifacts, never directions to open server-local file:// paths. Question policy is strict: act instead of asking whenever a request is identifiable and reversible; choose a conventional or recommended default unless it changes an observable requirement, crosses an acceptance gate, is destructive, or is expensive and irreversible. The words do it, generate, proceed, continue, now, show, or accept defaults prohibit another clarification round for that requested result. A structured answer includes Question ID and permanently closes both that ID and the same semantic question. After receiving any structured answer, produce a material result or durable edit before asking anything new. A requested result gets at most one clarification turn; afterward state reasonable assumptions and produce the best reversible result. Do not ask a follow-up question when the requested reversible action is already identifiable. Do not claim a file changed unless workspace_write or workspace_patch succeeded. Run a proportional named check after edits. Summarize the outcome, changed files, and validation concisely. Tool activity is shown separately, so do not invent or narrate hidden reasoning."

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
  let diagramGuidance := "Diagram input is intentionally permissive. The user may supply prose, simplified interaction pseudocode, Mermaid, PlantUML, or refer to an attached sketch or public-web image. Infer the intended semantics and ask only when a material ambiguity remains. When a diagram is useful, return corrected renderable Mermaid in a fenced mermaid block. When motion or simulation materially answers the request, return a fenced leanfm-canvas block containing a literal accessible canvas element and self-contained inline script with no external resources. Preserve the user's original as provenance; do not claim that an informal sketch is an accepted derived LeanFM view.\n\n"
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
  let out ← IO.Process.output {
    cmd := "bwrap"
    args := #["--die-with-parent", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--ro-bind", "/usr", "/usr",
      "--ro-bind", "/bin", "/bin", "--ro-bind", "/lib", "/lib", "--ro-bind", "/lib64", "/lib64",
      "--ro-bind", "/etc", "/etc", "--ro-bind", "/var/lib/texmf", "/var/lib/texmf", "--proc", "/proc", "--dev", "/dev",
      "--tmpfs", "/tmp", "--bind", realBook.toString, "/work", "--chdir", "/work",
      "--setenv", "HOME", "/tmp", "--", "/usr/bin/make"] }
  if out.exitCode == 0 then return .ok ()
  return .error ("Book build failed:\n" ++ truncateText (out.stdout ++ "\n" ++ out.stderr) 10000)

def buildErrorSummary (message : String) : String :=
  (message.splitOn "\n").find? (fun line => line.startsWith "!") |>.getD
    "The generated LaTeX did not compile."

def addCompletionUsage (first second : Provider.Completion) (text : String) : Provider.Completion :=
  { text
  , inputTokens := first.inputTokens + second.inputTokens
  , cachedInputTokens := first.cachedInputTokens + second.cachedInputTokens
  , outputTokens := first.outputTokens + second.outputTokens
  , totalTokens := first.totalTokens + second.totalTokens }

def repairBookEdit (key candidate diagnostic : String) : IO (Except String (BookChatEdit × Provider.Completion)) := do
  let instructions := "You repair a complete pdfLaTeX document after a compiler failure. Return ONLY valid JSON with exactly two string fields: reply and book_source. book_source is the complete corrected document, not a patch. Preserve the intended prose and change only what is needed to compile. Pay particular attention to unescaped prose characters: write \\& for ampersand, \\% for percent, \\_ for underscore, \\# for hash, and \\$ for dollar. Do not discuss LeanFM requirements, do not ask questions, and do not emit Markdown fences."
  let prompt := "An internal validation step rejected the candidate book revision below. Repair only the technical defect while preserving its intended content. Return ONLY one JSON object with exactly the string fields reply and book_source; book_source must be the complete corrected LaTeX document. Do not ask the user to debug this internal failure.\n\nCompiler diagnostic:\n" ++
    truncateText diagnostic 5000 ++ "\n\nRejected candidate book/main.tex:\n" ++ truncateText candidate 100000
  match ← Provider.completeWithInstructions key instructions prompt with
  | .error message => return .error message
  | .ok completion =>
      match bookChatEdit? completion.text with
      | none => return .error "The automatic repair did not return a complete book revision."
      | some edit => return .ok (edit, completion)

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
    | [_messageId, role, encoded, _input, _cached, _output, _total, _responseTimeMs] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | [_messageId, role, encoded, _input, _cached, _output, _total] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | [role, encoded, _input, _cached, _output, _total] =>
        try turns := (role ++ ": " ++ excerpt (← base64Decode encoded)) :: turns catch _ => pure ()
    | _ => pure ()
  pure (String.intercalate "\n\n" ((turns.take 8).reverse))

def referencedAnimationSource? (root context : String) : IO (Option String) := do
  let out ← IO.Process.output { cmd := "rg", args := #["--files", root ++ "/spec/images", root ++ "/spec/media", root ++ "/artifacts", root ++ "/renders"] }
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
      let title := if id.startsWith "figure-" then
          match id.drop "figure-".length |>.toString |>.splitOn "-" with
          | number :: _ => "Figure " ++ number
          | _ => id
        else id
      artifacts := ("{\"artifact_id\":\"" ++ jsonEscape id ++ "\",\"title\":\"" ++ jsonEscape title ++
        "\",\"kind\":\"mermaid\",\"status\":\"current\",\"revision\":1}") :: artifacts
  pure ("{\"artifacts\":[" ++ String.intercalate "," artifacts.reverse ++ "]}\n")

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
  if path == "/api/me" then return some (jsonResponse 200 ("{\"username\":\"" ++ jsonEscape username ++ "\"}\n"))
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
              return some (jsonResponse 200 ("{\"source\":\"" ++ jsonEscape source ++ "\"}\n"))
          | ["book"], "POST" =>
              if projectId == "leanfm-workspace" then return some (errorResponse 403 "The LeanFM workspace book is read-only.")
              let source := (formValue? (requestBody request) "source").getD ""
              if source.isEmpty then return some (errorResponse 400 "Book source cannot be empty.")
              if source.length > 2000000 then return some (errorResponse 413 "Book source exceeds the 2 MB editor limit.")
              writeAtomic (root ++ "/book/main.tex") source
              return some (jsonResponse 200 "{\"saved\":true}\n")
          | ["book", "build"], "POST" =>
              if projectId == "leanfm-workspace" then return some (errorResponse 403 "The LeanFM workspace book is read-only.")
              match ← buildProjectBook root with
              | .ok _ => return some (jsonResponse 200 "{\"built\":true}\n")
              | .error message => return some (errorResponse 422 message)
          | ["artifacts"], "GET" => return some (jsonResponse 200 (← artifactListJson root))
          | ["chat"], "POST" =>
              let prompt := (formValue? (requestBody request) "prompt").getD ""
              if prompt.trimAscii.isEmpty then return some (errorResponse 400 "A prompt is required.")
              let responseStarted ← IO.monoMsNow
              match ← credentialKey username request with
              | .error message => return some (errorResponse 409 message)
              | .ok key =>
                  let prior ← conversationContext root
                  let figureContext ← referencedFigureContext root prompt
                  let launchRoot ← IO.FS.realPath (← IO.currentDir)
                  let launchRoot := launchRoot.toString
                  let contextualPrompt := "Selected LeanFM project root: " ++ root ++
                    "\nAuthorized source workspace: " ++ launchRoot ++ "\n\n" ++
                    (if prior.isEmpty then "" else "Project conversation so far:\n\n" ++ prior ++ "\n\n") ++
                    (if figureContext.isEmpty then "" else figureContext ++ "\n\n") ++
                    "Current user message:\n" ++ prompt
                  appendConversation root "user" prompt
                  let trace ← IO.mkRef ([] : List String)
                  let runner : Provider.ToolRunner := fun name arguments => runWorkspaceTool launchRoot name arguments trace
                  match ← Provider.completeAgent key (workspaceAgentInstructions launchRoot) contextualPrompt runner with
                  | .error message => return some (errorResponse 502 message)
                  | .ok answer =>
                      let mp4Requested := prompt.toLower.contains "mp4"
                      let mut activity := (← trace.get).reverse
                      if mp4Requested && !(activity.any fun item => item.startsWith "Generated " && item.toLower.contains ".mp4") then
                        match ← referencedAnimationSource? root (prior ++ "\n" ++ prompt) with
                        | none => trace.modify ("workspace_transcode_mp4 rejected: No project GIF or WebM source was found." :: ·)
                        | some source =>
                            let stem := if source.toLower.endsWith ".webm" then source.dropEnd 5 else source.dropEnd 4
                            let destination := stem.toString ++ ".mp4"
                            let _ ← runner "workspace_transcode_mp4"
                              ("{\"input_path\":\"" ++ jsonEscape (root ++ "/" ++ source) ++
                                "\",\"output_path\":\"" ++ jsonEscape (root ++ "/" ++ destination) ++ "\"}")
                      activity := (← trace.get).reverse
                      let mp4Artifact := activity.find? fun item => item.startsWith "Generated " && item.toLower.contains ".mp4"
                      let missingRequiredArtifact := mp4Requested && mp4Artifact.isNone
                      let warned := (answer.text.splitOn "```leanfm-questions").length > 1 || activity.any fun item => (item.splitOn "rejected").length > 1 || (item.splitOn "Failed check:").length > 1
                      let status := if missingRequiredArtifact then "fail" else if warned then "warn" else "success"
                      let statusMarker := "```leanfm-result\n{\"status\":\"" ++ status ++ "\"}\n```\n\n"
                      let mp4Failure := activity.find? fun item => item.startsWith "workspace_transcode_mp4 rejected:"
                      let visibleAnswer := if missingRequiredArtifact then
                        match mp4Failure with
                        | some failure => "The requested MP4 was not produced. " ++ failure
                        | none => "The requested MP4 was not produced because the MP4 transcoder was not invoked. LeanFM rejected the response instead of presenting another substitute or follow-up question."
                        else match mp4Artifact with
                          | some generated =>
                              let path := String.ofList ((generated.drop 10).toString.toList.takeWhile (· != ' '))
                              answer.text ++ "\n\nInline MP4: " ++ path
                          | none => answer.text
                      let responseText := statusMarker ++ visibleAnswer ++ (if activity.isEmpty then "" else
                        "\n\nOperational trace:\n" ++ String.intercalate "\n" (activity.map ("- " ++ ·)))
                      let figureLabels ← saveMermaidArtifacts root responseText
                      let responseText := if figureLabels.isEmpty then responseText else
                        responseText ++ "\n\nFigures created: " ++ String.intercalate ", " figureLabels ++ "."
                      let responseFinished ← IO.monoMsNow
                      let responseTimeMs := responseFinished - responseStarted
                      appendConversation root "assistant" responseText (some answer) responseTimeMs
                      let context := (← IO.getEnv "LEANFM_CONTEXT_WINDOW_TOKENS").getD "128000"
                      return some (jsonResponse 200 ("{\"text\":\"" ++ jsonEscape responseText ++ "\",\"book_updated\":false,\"usage\":{\"input_tokens\":" ++
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
        | some username => handleAuthenticated username path method request
      else pure none

end LeanFM.ChatUI.Server
