import Lean
import LeanFM.Artifacts
import LeanFM.ServerLogs
import LeanFM.LLMGenerated.SelfHosting
import LeanFM.LLMGenerated.McpLogicImplementation
import LeanFM.LLMGenerated.SessionImplementation

/-! The distillation chain of a project, as the session view's navigator shows it: chat, book,
requirements, code (clause selfhost.mcp.session.navigator, decision session-navigator).

Requirements this module is held to:
* positive (AG): every answer names the project, the stage and the file it read, and shows that
  stage of exactly that project.
* negative (never): a write, rename or delete (the book's page cache is in memory); a process other
  than pdfinfo and pdftoppm with fixed arguments on the selected project's PDF, or one that runs
  longer than `renderTimeoutMs` (it is killed).
* negative (never): a project named by anything but a listed name; a read whose real path is outside
  the project's root; a `file` that is not in that project's listing.
* negative (never): a message argument (the conversation happens in the agent, not in the view).
* negative (never): an unredacted bearer token, sk- key or token= value from a conversation log.
* negative (never): an answer over its bounds (`maxMessages`, `maxFiles`, `maxFileBytes`,
  `maxImageBytes`, `maxReadBytes`), or longer than `maxAnswerChars`, well under the host's
  100000-character result limit: requirements, code and file text come a page at a time.
* negative (never): served where `enabled` is off (the hosted HTTP endpoint, unless LEANFM_MCP_LOGS=1).
Tested in LeanFM/MCPTests.lean. -/

namespace LeanFM.ProjectView
open Lean

/-- On exactly where server_logs is: leanfm-mcp --stdio and leanfm-server on 127.0.0.1, and the
hosted HTTP endpoint only when its operator sets LEANFM_MCP_LOGS=1. One switch, so they cannot differ. -/
def enabled : IO.Ref Bool := LeanFM.ServerLogs.enabled

def disabledMessage : String :=
  "project_view is off on this host: it is served by leanfm-mcp --stdio and by leanfm-server on 127.0.0.1, " ++
  "and by the hosted HTTP endpoint only when LEANFM_MCP_LOGS=1"

def maxMessages : Nat := 200
def maxMessageChars : Nat := 8000
def maxFiles : Nat := 2000
def maxFileBytes : Nat := 256 * 1024
def maxImageBytes : Nat := 48000
def maxReadBytes : Nat := 4 * 1024 * 1024
def maxDepth : Nat := 12
/-- Text and structured content of one answer together, well under the host's 100000. -/
def maxAnswerChars : Nat := 70000
/-- One page of items: at most this many, and at most `pageChars` of JSON (always at least one). -/
def pageItems : Nat := 100
def pageChars : Nat := 40000
/-- A string in an item longer than this is cut, and the item marked cut. -/
def itemChars : Nat := 8000
/-- One page of a file's text, in characters. -/
def textPageChars : Nat := 40000
def renderTimeoutMs : Nat := 10000
def cacheSize : Nat := 64

def stages : List String := ["chat", "book", "requirements", "impl", "code"]

def chatWhere : String :=
  "The conversation happens in the agent connected to this MCP server (Claude Desktop, Claude Code, Codex), " ++
  "not in this view. This project has no saved conversation log (conversations/main.log)."

structure Project where
  name : String
  /-- the root as given: "." for LeanFM, projects/<dir> otherwise -/
  root : System.FilePath
  /-- the root with symlinks resolved; every read must stay below it -/
  real : System.FilePath
  manifest : Json
  isLeanFM : Bool

/-! ## Projects and the root boundary -/

def projectsDir : System.FilePath := "projects"

/-- LeanFM first, then each immediate child of projects/ with a manifest.json, by display name. -/
def projects : IO (Array Project) := do
  let leanReal ← IO.FS.realPath "."
  let mut out : Array Project := #[{ name := "LeanFM", root := ".", real := leanReal, manifest := Json.mkObj [], isLeanFM := true }]
  if !(← projectsDir.isDir) then return out
  let entries ← projectsDir.readDir
  let entries := entries.qsort (fun a b => a.fileName < b.fileName)
  for e in entries do
    let root := projectsDir / e.fileName
    if !(← root.isDir) then continue
    let m := root / "manifest.json"
    if !(← m.pathExists) then continue
    let real ← IO.FS.realPath root
    -- a project directory that is a symlink out of projects/ is not a project of this checkout
    unless real.toString.startsWith (leanReal.toString ++ "/") do continue
    let manifest := match Json.parse (← IO.FS.readFile m) with
      | .ok j => j
      | .error _ => Json.mkObj []
    let name := (manifest.getObjValAs? String "display_name").toOption.getD e.fileName
    if out.any (·.name == name) then continue
    out := out.push { name, root, real, manifest, isLeanFM := false }
  return out

/-- The real path of `rel` (relative to the project root) when it lies inside the root. -/
def inside (p : Project) (rel : String) : IO (Option System.FilePath) := do
  if rel.isEmpty || rel.startsWith "/" || (rel.splitOn "/").contains ".." || (rel.splitOn "\\").length > 1 then
    return none
  let path := p.root / rel
  if !(← path.pathExists) then return none
  let real ← IO.FS.realPath path
  let r := real.toString
  if r == p.real.toString || r.startsWith (p.real.toString ++ "/") then return some real
  return none

def manifestPath (p : Project) (key fallback : String) : String :=
  (p.manifest.getObjValAs? String key).toOption.getD fallback

/-! ## Implementations (clause selfhost.project.implementations)

A project's manifest may list several implementations of its one specification; the code stage
shows one of them at a time, the default unless the caller names another with impl. -/

structure Impl where
  name : String
  /-- the implementation mapping, e.g. impl/rust/Implementation.lean -/
  mapping : String
  /-- the source directory, e.g. impl/rust/source/ -/
  source : String
deriving Repr

def validImplName (n : String) : Bool :=
  n.length ≥ 1 && n.length ≤ 32 && (n.toList.headD ' ').isLower &&
    n.toList.all (fun c => c.isLower || c.isDigit || c == '_')

/-- The listed implementations with a valid name and source, in manifest order; none for LeanFM
or a project without the list. -/
def implementationsOf (p : Project) : List Impl :=
  if p.isLeanFM then [] else
  match p.manifest.getObjVal? "implementations" with
  | .ok (.arr xs) => xs.toList.filterMap fun x =>
      match (x.getObjValAs? String "name").toOption, (x.getObjValAs? String "source").toOption with
      | some name, some source =>
        if validImplName name then
          some { name, source, mapping := (x.getObjValAs? String "implementation").toOption.getD "" }
        else none
      | _, _ => none
  | _ => []

/-- The manifest's default_implementation when it is listed, else the first listed. -/
def defaultImplementation (p : Project) : Option Impl :=
  let xs := implementationsOf p
  match (p.manifest.getObjValAs? String "default_implementation").toOption.bind (fun d => xs.find? (·.name == d)) with
  | some i => some i
  | none => xs.head?

/-- The implementation an answer shows: the one named by impl, or the default. -/
def chooseImplementation (p : Project) (arg : Option String) : Except String (Option Impl) :=
  let xs := implementationsOf p
  match arg with
  | none => .ok (defaultImplementation p)
  | some n =>
    if xs.isEmpty then .error s!"{p.name} lists no implementations; impl is only for a project whose manifest lists them"
    else match xs.find? (·.name == n) with
      | some i => .ok (some i)
      | none => .error s!"impl must be one of {", ".intercalate (xs.map (·.name))}"

/-! ## Reading -/

def decodeLossy (bytes : ByteArray) : String := LeanFM.ServerLogs.decodeLossy bytes

/-- At most the first `limit` bytes of a file, and whether there was more. -/
def headBytes (path : System.FilePath) (limit : Nat) : IO (ByteArray × Bool) := do
  let h ← IO.FS.Handle.mk path .read
  let mut buf := ByteArray.empty
  repeat
    if buf.size > limit then break
    let chunk ← h.read 1048576
    if chunk.isEmpty then break
    buf := buf ++ chunk
  if buf.size > limit then return (buf.extract 0 limit, true)
  return (buf, false)

private def b64alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

def base64Encode (bytes : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i < bytes.size do
    let a := bytes[i]!.toNat
    let b := if i + 1 < bytes.size then bytes[i + 1]!.toNat else 0
    let c := if i + 2 < bytes.size then bytes[i + 2]!.toNat else 0
    out := out.push b64alphabet[a >>> 2]!
    out := out.push b64alphabet[((a &&& 3) <<< 4) ||| (b >>> 4)]!
    out := out.push (if i + 1 < bytes.size then b64alphabet[((b &&& 15) <<< 2) ||| (c >>> 6)]! else '=')
    out := out.push (if i + 2 < bytes.size then b64alphabet[c &&& 63]! else '=')
    i := i + 3
  return out

def b64value (c : Char) : Option Nat :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat)
  else if 'a' ≤ c && c ≤ 'z' then some (c.toNat - 'a'.toNat + 26)
  else if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat + 52)
  else if c == '+' || c == '-' then some 62
  else if c == '/' || c == '_' then some 63
  else none

/-- Standard or URL-safe base64; characters that are not base64 (padding, newlines) are skipped. -/
def base64Decode (s : String) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  let mut acc := 0
  let mut bits := 0
  for c in s.toList do
    match b64value c with
    | none => pure ()
    | some v =>
      acc := ((acc <<< 6) ||| v) &&& 0xFFFFFF
      bits := bits + 6
      if bits ≥ 8 then
        bits := bits - 8
        out := out.push ((acc >>> bits) &&& 0xFF).toUInt8
  return out

def cut (s : String) (n : Nat) : String :=
  if s.length ≤ n then s else (s.take n).toString ++ " …"

/-! ## Walking a project's files -/

def skipDirs : List String := [".git", ".lake", ".cache", "node_modules", "dist", "build", "__pycache__", ".venv"]

def sourceExtensions : List String :=
  ["lean", "ts", "tsx", "js", "py", "go", "sh", "html", "css", "proto", "leanfm", "protocol", "rs", "c", "h", "java", "md", "json", "toml"]

def protocolExtensions : List String := ["leanfm", "protocol"]

/-- Files below `start` (relative to the project root) with one of `exts`, sorted, at most
`maxFiles`; symlinks out of the root are left out. LeanFM's walk leaves out projects/. -/
partial def walk (p : Project) (start : String) (exts : List String) (extraSkip : List String := []) : IO (Array String × Bool) := do
  let found ← IO.mkRef (#[] : Array String)
  let full ← IO.mkRef false
  let rec go (rel : String) (depth : Nat) : IO Unit := do
    if depth > maxDepth || (← full.get) then return
    let dir := if rel.isEmpty then p.root else p.root / rel
    let entries ← try dir.readDir catch _ => pure #[]
    for e in entries.qsort (fun a b => a.fileName < b.fileName) do
      if (← full.get) then return
      let name := e.fileName
      let childRel := if rel.isEmpty then name else rel ++ "/" ++ name
      if (← e.path.isDir) then
        if skipDirs.contains name || name.startsWith "." || extraSkip.contains childRel then continue
        -- a directory reached through a symlink out of the root is not walked
        if (← inside p childRel).isNone then continue
        go childRel (depth + 1)
      else
        let ext := (System.FilePath.mk name).extension.getD ""
        if !exts.contains ext then continue
        if (← inside p childRel).isNone then continue
        let n := (← found.get).size
        if n ≥ maxFiles then full.set true; return
        found.modify (·.push childRel)
  go start 0
  return (← found.get, ← full.get)

/-! ## chat -/

def chat (p : Project) (offset : Nat := 0) : IO Json := do
  let rel := "conversations/main.log"
  let some path ← inside p rel
    | return Json.mkObj [("stage", "chat"), ("file", rel), ("found", false), ("where", chatWhere), ("messages", Json.arr #[])]
  let (bytes, partialRead) ← LeanFM.ServerLogs.tailBytes path maxReadBytes
  let lines := (decodeLossy bytes).splitOn "\n" |>.filter (!·.isEmpty) |>.toArray
  let lines := if partialRead && lines.size > 1 then lines.extract 1 lines.size else lines
  let picked := lines.extract (lines.size - min lines.size maxMessages) lines.size
  let messages := picked.filterMap fun line =>
    match line.splitOn "|" with
    | id :: role :: text :: rest =>
      let decoded := decodeLossy (base64Decode text)
      let redacted := "\n".intercalate ((decoded.splitOn "\n").map LeanFM.ServerLogs.redactLine)
      let timeMs := (rest.drop 5).head?.getD ""
      let model := (rest.drop 6).head?.getD ""
      some (Json.mkObj [("id", id), ("role", role), ("text", cut redacted maxMessageChars),
        ("timeMs", timeMs), ("model", model)])
    | _ => none
  -- a page counted back from the newest: skip offset, then as many as fit, shown oldest first
  let mut page : Array Json := #[]
  let mut size := 0
  let mut i := messages.size - min messages.size offset
  while i > 0 && page.size < pageItems do
    let m := messages[i - 1]!
    let n := m.compress.length
    if !page.isEmpty && size + n > pageChars then break
    page := page.push m
    size := size + n
    i := i - 1
  return Json.mkObj [("stage", "chat"), ("file", rel), ("found", true), ("total", lines.size),
    ("shown", messages.size), ("offset", offset), ("older", if i > 0 then toJson (messages.size - i) else Json.null),
    ("partialRead", partialRead), ("messages", Json.arr page.reverse),
    ("where", "The conversation continues in the agent connected to this MCP server (Claude Desktop, Claude Code, Codex); this is the saved log, read-only.")]

/-! ## book -/

/-- A child process with fixed arguments, no shell, killed after `timeoutMs`. -/
def runBounded (cmd : String) (args : Array String) (timeoutMs : Nat := renderTimeoutMs) :
    IO (Except String (UInt32 × ByteArray × String)) := do
  let child ← IO.Process.spawn { cmd, args, stdin := .null, stdout := .piped, stderr := .piped }
  -- drained while it runs, so a full pipe never stalls it
  let out ← IO.asTask child.stdout.readBinToEnd
  let err ← IO.asTask child.stderr.readToEnd
  let start ← IO.monoMsNow
  let mut code : Option UInt32 := none
  repeat
    code ← child.tryWait
    if code.isSome then break
    if (← IO.monoMsNow) - start > timeoutMs then
      child.kill
      let _ ← child.wait
      return .error s!"{cmd} ran longer than {timeoutMs / 1000} s and was stopped"
    IO.sleep 5
  let bytes ← match out.get with | .ok b => pure b | .error e => throw e
  let text ← match err.get with | .ok t => pure t | .error _ => pure ""
  return .ok (code.getD 1, bytes, text)

/-- Rendered pages and page counts, keyed by the PDF's real path, modification time and page;
memory only, at most `cacheSize` entries, the oldest dropped first. -/
initialize pageCache : IO.Ref (Array (String × Json)) ← IO.mkRef #[]

def cacheGet (key : String) : IO (Option Json) := do
  return ((← pageCache.get).find? (·.1 == key)).map (·.2)

def cachePut (key : String) (v : Json) : IO Unit :=
  pageCache.modify fun c =>
    let c := (c.filter (·.1 != key)).push (key, v)
    if c.size > cacheSize then c.extract (c.size - cacheSize) c.size else c

/-- The renders tried for a page, in order, until one fits `maxImageBytes`: as wide as the view
shows a page, then smaller and as JPEG. -/
def ladder : List (String × Array String) :=
  [("image/png", #["-png", "-scale-to", "900"]),
   ("image/jpeg", #["-jpeg", "-jpegopt", "quality=70", "-scale-to", "900"]),
   ("image/jpeg", #["-jpeg", "-jpegopt", "quality=60", "-scale-to", "760"]),
   ("image/jpeg", #["-jpeg", "-jpegopt", "quality=55", "-scale-to", "640"]),
   ("image/jpeg", #["-jpeg", "-jpegopt", "quality=45", "-scale-to", "520"])]

def book (p : Project) (page : Nat) (dark : Bool) : IO (Except String Json) := do
  let rel := if dark then manifestPath p "dark_book" "book/main-dark.pdf" else manifestPath p "book" "book/main.pdf"
  let some path ← inside p rel
    | do
        -- a missing PDF whose source is missing too has not been written, not merely not built
        let src := manifestPath p "book_source" "book/main.tex"
        let written := (← inside p src).isSome
        return .ok <| Json.mkObj [("stage", "book"), ("file", rel), ("found", false), ("source", src), ("written", written),
          ("reason", if written then s!"{p.name} has no {rel} yet: build the book from {src} with make book"
            else s!"{p.name} has no book: neither {rel} nor its source {src} exists, so the book has not been written yet")]
  let md ← path.metadata
  let stamp := s!"{path}|{md.modified.sec}.{md.modified.nsec}"
  let pages ← match ← cacheGet (stamp ++ "|pages") with
    | some (.num n) => pure n.mantissa.toNat
    | _ =>
      let info ← try runBounded "pdfinfo" #[path.toString]
        catch _ => return .error "pdfinfo is not installed (poppler-utils): it is needed to count the book's pages"
      let (code, info, err) ← match info with | .ok r => pure r | .error e => return .error e
      if code != 0 then return .error s!"pdfinfo could not read {rel}: {cut err 400}"
      let pagesLine := ((decodeLossy info).splitOn "\n").find? (·.startsWith "Pages:")
      let n := (pagesLine.map (fun l => ((l.drop 6).toString.trimAscii.toString).toNat?)).join.getD 0
      if n == 0 then return .error s!"pdfinfo found no pages in {rel}"
      cachePut (stamp ++ "|pages") (toJson n)
      pure n
  let page := max 1 (min page pages)
  let key := s!"{stamp}|{page}"
  let base := Json.mkObj [("stage", "book"), ("file", rel), ("found", true), ("dark", dark),
    ("page", page), ("pages", pages)]
  if let some image ← cacheGet key then
    return .ok (base.setObjVal! "image" image |>.setObjVal! "cached" true)
  let mut renders := 0
  for (mime, opts) in ladder do
    renders := renders + 1
    let args := opts ++ #["-singlefile", "-f", toString page, "-l", toString page, path.toString]
    let r ← try runBounded "pdftoppm" args
      catch _ => return .error "pdftoppm is not installed (poppler-utils): it is needed to show the book's pages"
    let (code, img, err) ← match r with
      | .ok r => pure r
      | .error e => return .error s!"page {page} of {rel}: {e}"
    if code != 0 then return .error s!"pdftoppm could not render page {page} of {rel}: {cut err 400}"
    if img.size ≤ maxImageBytes then
      let image := Json.mkObj [("mimeType", Json.str mime), ("data", Json.str (base64Encode img)),
        ("renders", toJson renders)]
      cachePut key image
      return .ok (base.setObjVal! "image" image |>.setObjVal! "cached" false)
  return .error s!"page {page} of {rel} does not fit in {maxImageBytes} bytes even at the smallest of {ladder.length} renders"

/-! ## Pages of items -/

/-- Every string longer than `itemChars` cut to that length; whether any was. -/
partial def cutStrings (j : Json) : Json × Bool :=
  match j with
  | .str t => if t.length > itemChars then (Json.str ((t.take itemChars).toString ++ " …"), true) else (j, false)
  | .arr a =>
    let xs := a.map cutStrings
    (Json.arr (xs.map (·.1)), xs.any (·.2))
  | .obj kvs =>
    let xs := kvs.toArray.map fun (k, v) => (k, cutStrings v)
    (Json.mkObj (xs.toList.map fun (k, (v, _)) => (k, v)), xs.any (·.2.2))
  | _ => (j, false)

def fitItem (j : Json) : Json :=
  if j.compress.length ≤ itemChars then j else
  let (c, any) := cutStrings j
  if any then match c with | .obj _ => c.setObjVal! "cut" true | _ => c else c

/-- One page of `items` from `offset`: at most `pageItems` items and `pageChars` characters of
JSON, at least one item; with the offset of the next page (null on the last). -/
def pageOf (items : Array Json) (offset : Nat) : Json := Id.run do
  let mut out : Array Json := #[]
  let mut size := 0
  let mut i := offset
  while i < items.size && out.size < pageItems do
    let it := fitItem items[i]!
    let n := it.compress.length
    if !out.isEmpty && size + n > pageChars then break
    out := out.push it
    size := size + n
    i := i + 1
  return Json.mkObj [("offset", offset), ("total", items.size), ("next", if i < items.size then toJson i else Json.null),
    ("items", Json.arr out)]

/-! ## requirements -/

def proofFormula (mode : RequiredProofMode) (predicate : String) : String × String :=
  match mode with
  | .never => ("never", s!"AG ¬({predicate})")
  | .always => ("always", s!"AG ({predicate})")
  | .eventually => ("eventually", s!"AF ({predicate})")
  | .possibly => ("possibly", s!"EF ({predicate})")

def formula (mode : PropertyMode) (expression : String) : String :=
  match mode with
  | .always => s!"AG ({expression})"
  | .eventually => s!"AF ({expression})"
  | .never => s!"AG ¬({expression})"
  | .preparedFor => s!"EF ({expression})"

/-- LeanFM's own tasks: SelfHosting.spec, as the old chat UI's tasks route showed them. -/
def leanfmTasks : Json :=
  let spec := LeanFM.LLMGenerated.SelfHosting.spec
  let constraints := (LeanFM.ChatUI.Requirements.taskConstraints.filter fun c =>
      !LeanFM.LLMGenerated.SharedProjects.replacedConstraints.contains c.id) ++ LeanFM.LLMGenerated.SharedProjects.constraints
  Json.arr <| spec.tasks.toArray.map fun task =>
    let transitions := task.transitions.toArray.map fun t =>
      let m := spec.messages.find? (·.name == t.message)
      Json.mkObj [("src", t.src), ("dst", t.dst), ("message", t.message),
        ("source_actor", (m.map (·.src)).getD ""), ("destination_actor", (m.map (·.dst)).getD "")]
    let properties := (spec.properties.filter (·.task == task.id)).toArray.map fun pr =>
      Json.mkObj [("name", pr.name), ("mode", propertyModeName pr.mode), ("expression", pr.expression),
        ("formula", formula pr.mode pr.expression), ("origin", "SelfHosting.spec property")]
    let proofs := (spec.requiredProofs.filter (·.task == task.id)).toArray.map fun pr =>
      let (mode, f) := proofFormula pr.mode pr.predicate
      Json.mkObj [("name", pr.name), ("mode", mode), ("expression", pr.predicate),
        ("formula", f), ("origin", "SelfHosting.spec required proof")]
    let cs := (constraints.filter (·.task == task.id)).toArray.map fun c =>
      Json.mkObj [("id", c.id), ("predicate", c.predicate), ("formula", formula .always c.predicate),
        ("origin", "where_")]
    Json.mkObj [("id", task.id), ("title", task.title), ("actors", toJson task.actors),
      ("states", task.states.length), ("transitions", Json.arr transitions),
      ("properties", Json.arr (properties ++ proofs)), ("constraints", Json.arr cs)]

def leanfmClauses : Json :=
  Json.arr <| LeanFM.LLMGenerated.SelfHosting.clauses.toArray.map fun c =>
    Json.mkObj [("id", c.id), ("area", c.area), ("status", c.status), ("requirement", c.requirement)]

/-- A project's spec/tasks.json, keeping only the fields the view shows. -/
def projectTasks (j : Json) : Json :=
  let keep (o : Json) (ks : List String) : Json :=
    Json.mkObj (ks.filterMap fun k => match o.getObjVal? k with | .ok v => some (k, v) | .error _ => none)
  let tasks := ((j.getObjValD "tasks").getArr?).toOption.getD #[]
  Json.arr <| tasks.map fun t =>
    let states := ((t.getObjValD "states").getArr?).toOption.getD #[]
    let arr (k : String) := ((t.getObjValD k).getArr?).toOption.getD #[]
    keep t ["id", "title", "actors"] |>.setObjVal! "states" (toJson states.size)
      |>.setObjVal! "transitions" (Json.arr ((arr "transitions").map (keep · ["src", "dst", "message", "source_actor", "destination_actor"])))
      |>.setObjVal! "properties" (Json.arr ((arr "properties").map (keep · ["name", "mode", "expression", "formula", "origin"])))
      |>.setObjVal! "constraints" (Json.arr ((arr "constraints").map (keep · ["id", "predicate", "formula", "origin"])))

def protocolFiles (p : Project) : IO (Array String × Bool) :=
  walk p "" protocolExtensions (if p.isLeanFM then ["projects"] else [])

def readTasks (p : Project) (rel : String) : IO (Except String Json) := do
  match ← inside p rel with
  | none => return .ok (Json.arr #[])
  | some path =>
    let (bytes, over) ← headBytes path maxReadBytes
    if over then return .error s!"{rel} is larger than {maxReadBytes / 1048576} MiB"
    match Json.parse (decodeLossy bytes) with
    | .error e => return .error s!"{rel} is not JSON: {cut e 200}"
    | .ok j => return .ok (projectTasks j)

def sections : List String := ["tasks", "clauses", "protocols", "transitions", "properties", "constraints"]

def arrOf (j : Json) (k : String) : Array Json := ((j.getObjValD k).getArr?).toOption.getD #[]

/-- A task without its lists: what the tasks section pages. -/
def taskSummary (t : Json) : Json :=
  Json.mkObj [("id", t.getObjValD "id"), ("title", t.getObjValD "title"), ("actors", t.getObjValD "actors"),
    ("states", t.getObjValD "states"), ("transitions", (arrOf t "transitions").size),
    ("properties", (arrOf t "properties").size), ("constraints", (arrOf t "constraints").size)]

/-- The specification's own files, shown as text: LeanFM's self-hosting requirements and their
protobuf; for a project, its manifest's requirements and protobuf files, when they exist. -/
def specFiles (p : Project) : IO (List String) := do
  let candidates := if p.isLeanFM then ["LeanFM/LLMGenerated/SelfHosting.lean", "LeanFM/LLMGenerated/SelfHosting.proto"]
    else [manifestPath p "requirements" "spec/Requirements.lean", manifestPath p "protobuf" "spec/Requirements.proto"]
  let mut out := []
  for f in candidates do
    if (← inside p f).isSome && !out.contains f then out := out ++ [f]
  return out

/-- A page of one file's text from a character offset: text, offset, total, next and cut. -/
def textPage (p : Project) (f : String) (offset : Nat) : IO (Except String Json) := do
  let some path ← inside p f | return .error "file must stay inside the project root"
  let (bytes, over) ← headBytes path maxFileBytes
  let chars := (decodeLossy bytes).toList
  let text := String.ofList ((chars.drop offset).take textPageChars)
  let next := offset + textPageChars
  return .ok <| Json.mkObj [("path", f), ("text", text), ("offset", offset), ("total", chars.length),
    ("next", if next < chars.length then toJson next else Json.null), ("cut", over)]

/-- The specification's primary protocol, the one the spec stage opens in the explorer: for LeanFM
its own protocol; for a project the manifest's protocol when listed, else the first listed protocol
file under spec/, else the first listed; none without protocol files. -/
def primaryProtocol (p : Project) (protocols : Array String) : Option String :=
  let listed (f : String) : Option String := if protocols.contains f then some f else none
  if p.isLeanFM then listed "LeanFM/LLMGenerated/LeanFM.leanfm" <|> protocols[0]?
  else
    ((p.manifest.getObjValAs? String "protocol").toOption.bind listed)
      <|> protocols.find? (·.startsWith "spec/") <|> protocols[0]?

/-- Without a section, the sections with their counts; with one, a page of its items from
`offset`. transitions, properties and constraints are one task's, named by `task`. -/
def requirements (p : Project) (sectionArg : Option String) (task : Option String) (offset : Nat) :
    IO (Except String Json) := do
  let (protocols, more) ← protocolFiles p
  let rel := if p.isLeanFM then "LeanFM/LLMGenerated/SelfHosting.lean" else manifestPath p "tasks" "spec/tasks.json"
  let tasks ← if p.isLeanFM then pure (.ok leanfmTasks) else readTasks p rel
  let .ok ts := tasks | return tasks
  let tasks := (ts.getArr?).toOption.getD #[]
  let clauses := ((if p.isLeanFM then leanfmClauses else Json.arr #[]).getArr?).toOption.getD #[]
  let head := Json.mkObj [("stage", "requirements"), ("file", rel)]
  let paged (name : String) (items : Array Json) (extra : List (String × Json) := []) : Json :=
    let pg := pageOf items offset
    extra.foldl (fun acc (k, v) => acc.setObjVal! k v)
      (head.setObjVal! "section" name |>.setObjVal! "page" pg)
  match sectionArg with
  | none =>
    -- the overview names the specification's files and its first protocols directly, so the
    -- person reaches the text in one click; the long lists stay behind their sections
    let files ← specFiles p
    return .ok <| head.setObjVal! "sections" (Json.arr #[
      Json.mkObj [("name", "tasks"), ("count", tasks.size)],
      Json.mkObj [("name", "clauses"), ("count", clauses.size)],
      Json.mkObj [("name", "protocols"), ("count", protocols.size), ("cut", more)]])
      |>.setObjVal! "files" (toJson files)
      |>.setObjVal! "protocolFiles" (toJson (protocols.toList.take 20))
      |>.setObjVal! "primary" (match primaryProtocol p protocols with | some f => Json.str f | none => Json.null)
  | some "tasks" => return .ok (paged "tasks" (tasks.map taskSummary))
  | some "clauses" => return .ok (paged "clauses" clauses)
  | some "protocols" => return .ok (paged "protocols" (protocols.map Json.str) [("protocolsCut", toJson more)])
  | some sec =>
    unless ["transitions", "properties", "constraints"].contains sec do
      return .error s!"section must be one of {", ".intercalate sections}, not {sec}"
    let some id := task | return .error s!"section {sec} needs task, the id of one of the {tasks.size} tasks"
    let some t := tasks.find? (fun t => (t.getObjValAs? String "id").toOption == some id)
      | return .error s!"task must be the id of one of the {p.name} tasks listed by section tasks"
    return .ok (paged sec (arrOf t sec) [("task", Json.str id)])

/-! ## code -/

structure Mapping where
  name : String
  requirements : List String
  files : List String
  symbols : List String
  tests : List String

def Mapping.json (m : Mapping) : Json :=
  Json.mkObj [("name", m.name), ("requirements", Lean.toJson m.requirements), ("files", Lean.toJson m.files),
    ("symbols", Lean.toJson m.symbols), ("tests", Lean.toJson m.tests)]

/-- A file a mapping names, or a test file a test names (the text before its first colon). -/
def Mapping.names (m : Mapping) (file : String) : Bool :=
  m.files.contains file || m.tests.any (fun t => (t.splitOn ":").head? == some file)

def leanfmMappings : List Mapping :=
  (LeanFM.LLMGenerated.McpLogicImplementation.decisions ++ LeanFM.LLMGenerated.SessionImplementation.decisions).map fun d =>
    { name := d.id, requirements := d.requirementRefs, files := d.files, symbols := [], tests := d.conformanceTests }

def projectMappings (j : Json) : List Mapping :=
  let strs (o : Json) (k : String) : List String :=
    (((o.getObjValD k).getArr?).toOption.getD #[]).toList.filterMap (·.getStr?.toOption)
  let ms := ((j.getObjValD "mappings").getArr?).toOption.getD #[]
  ms.toList.zipIdx.map fun (m, i) =>
    { name := s!"mapping {i + 1}", requirements := strs m "requirements", files := strs m "files",
      symbols := strs m "symbols", tests := strs m "tests" }

def sourceRoot (p : Project) (impl : Option Impl := none) : String :=
  if p.isLeanFM then "" else
    let s := match impl with
      | some i => i.source
      | none => manifestPath p "source" "source/"
    if s.endsWith "/" then (s.dropEnd 1).toString else s

def mappings (p : Project) (impl : Option Impl := none) : IO (String × List Mapping) := do
  if p.isLeanFM then return ("LeanFM/LLMGenerated/McpLogicImplementation.lean, LeanFM/LLMGenerated/SessionImplementation.lean", leanfmMappings)
  let rel := (if (sourceRoot p impl).isEmpty then "" else sourceRoot p impl ++ "/") ++ "traceability.json"
  let some path ← inside p rel | return (rel, [])
  let (bytes, over) ← headBytes path maxReadBytes
  if over then return (rel, [])
  match Json.parse (decodeLossy bytes) with
  | .ok j => return (rel, projectMappings j)
  | .error _ => return (rel, [])

/-- The source files a page at a time, each with the indices of the mappings that name it, and
the mappings by name and requirements; with `file`, a page of that file's text and its full
mappings instead of the listing. -/
def implementationCheckNamed (p : Project) (name : String) (withErrors : Bool := false) : IO Json := do
  let rel := "reports/specification-check/validation.json"
  let some path ← inside p rel | return Json.mkObj [("status", "not checked"), ("file", rel)]
  let (bytes, over) ← headBytes path maxReadBytes
  if over then return Json.mkObj [("status", "not checked"), ("file", rel)]
  match Json.parse (decodeLossy bytes) with
  | .error _ => return Json.mkObj [("status", "not checked"), ("file", rel)]
  | .ok j =>
    match (j.getObjValD "implementations").getObjVal? name with
    | .ok r =>
      let errs := ((r.getObjValD "errors").getArr?).toOption.getD #[]
      let base := Json.mkObj [("status", Json.str ((r.getObjValAs? String "status").toOption.getD "unknown")),
        ("target", match (r.getObjValAs? String "target").toOption with | some t => Json.str t | none => Json.null),
        ("errors", toJson errs.size), ("file", rel)]
      return if withErrors then
        base.setObjVal! "errorList" (Json.arr ((errs.toList.take 200).toArray.map fun e => Json.str (cut ((e.getStr?).toOption.getD "") 400)))
      else base
    | .error _ => return Json.mkObj [("status", "not checked"), ("file", rel)]

def implementationCheck (p : Project) (impl : Impl) : IO Json := implementationCheckNamed p impl.name

/-- The implementation mapping (impl stage): the picked implementation's Implementation.lean a page
at a time, with its check against the specification and every error the check listed. -/
def implStage (p : Project) (impl : Option Impl) (offset : Nat) : IO (Except String Json) := do
  let (rel, name) := match impl with
    | some i => (i.mapping, i.name)
    | none => (if p.isLeanFM then "LeanFM/LLMGenerated/Implementation.lean" else manifestPath p "implementation" "spec/Implementation.lean", "default")
  if rel.isEmpty then return .error s!"{p.name} names no implementation mapping file"
  let some _ ← inside p rel | return .ok (Json.mkObj [("stage", "impl"), ("file", rel), ("found", false)])
  match ← textPage p rel offset with
  | .error e => return .error e
  | .ok pg =>
    let check ← if p.isLeanFM then pure Json.null else implementationCheckNamed p name true
    return .ok <| Json.mkObj [("stage", "impl"), ("file", rel), ("found", true), ("selected", pg), ("check", check)]

def code (p : Project) (file : Option String) (offset : Nat) (impl : Option Impl := none) : IO (Except String Json) := do
  let (files, more) ← walk p (sourceRoot p impl) sourceExtensions (if p.isLeanFM then ["projects", "book", "exports", "reports", "logs"] else [])
  let (traceFile, ms) ← mappings p impl
  let msArr := ms.toArray
  let linksOf (f : String) : Array Nat := (msArr.zipIdx.filter (fun (m, _) => m.names f)).map (·.2)
  let head := Json.mkObj [("stage", "code"), ("file", traceFile), ("root", sourceRoot p impl)]
  let head ← match impl with
    | none => pure head
    | some i => pure <| head.setObjVal! "mapping" (Json.str i.mapping) |>.setObjVal! "check" (← implementationCheck p i)
  match file with
  | none =>
    let rows := files.map fun (f : String) => Json.mkObj [("path", Json.str f), ("links", toJson (linksOf f))]
    let pg := pageOf rows offset
    return .ok <| head.setObjVal! "page" pg |>.setObjVal! "filesCut" (toJson more)
      |>.setObjVal! "mappings" (Json.arr (msArr.map fun m => fitItem (Json.mkObj [("name", m.name), ("requirements", toJson m.requirements)])))
  | some f =>
    unless files.contains f do return .error s!"file must be one of the {p.name} source files listed by project_view stage code"
    let some path ← inside p f | return .error "file must stay inside the project root"
    let (bytes, over) ← headBytes path maxFileBytes
    let chars := (decodeLossy bytes).toList
    let text := String.ofList ((chars.drop offset).take textPageChars)
    let next := offset + textPageChars
    let links := linksOf f
    return .ok <| head.setObjVal! "selected" (Json.mkObj [("path", f), ("text", text), ("offset", offset),
      ("total", chars.length), ("next", if next < chars.length then toJson next else Json.null),
      ("cut", over), ("links", toJson links),
      ("mappings", Json.arr (links.filterMap fun i => msArr[i]?.map (fitItem ·.json)))])

/-! ## The tool -/

def projectNames : IO (List String) := do return (← projects).toList.map (·.name)

def argString (args : Json) (k : String) : Except String (Option String) :=
  match args.getObjVal? k with
  | .error _ => .ok none
  | .ok Json.null => .ok none
  | .ok v => match v.getStr? with
    | .ok s => .ok (some s)
    | .error _ => .error s!"{k} must be a string"

def allowedArgs : List String := ["project", "stage", "page", "theme", "file", "section", "task", "offset", "impl"]

/-- The host refuses a reply over its limit, so no answer longer than `maxAnswerChars` (text and
structured content together) is sent: it is refused, naming the bound and how to narrow it. -/
def bounded (what text : String) (body : Json) : Except String (String × Json) :=
  let size := text.length + body.compress.length
  if size > maxAnswerChars then
    .error s!"project_view {what} would answer {size} characters, over its {maxAnswerChars}-character bound; ask for a section, a task or an offset"
  else .ok (text, body)

/-- {project?, stage?, page?, theme?, file?, section?, task?, offset?}: without stage, only the projects and the stages.
`query` is the served tool; this is its answer, for tests that run with the switch off. -/
def answer (args : Json) : IO (Except String (String × Json)) := do
  if let .obj kvs := args then
    for (k, _) in kvs.toArray do
      unless allowedArgs.contains k do return .error s!"project_view takes only {", ".intercalate allowedArgs}; {k} is not one of them"
  let ps ← projects
  let names := ps.toList.map (·.name)
  let .ok projectArg := argString args "project" | return .error "project must be a string"
  let name := projectArg.getD "LeanFM"
  let some p := ps.find? (·.name == name)
    | return .error s!"project must be one of {", ".intercalate names}"
  let .ok stage := argString args "stage" | return .error "stage must be a string"
  let .ok fileArg := argString args "file" | return .error "file must be a string"
  let .ok themeArg := argString args "theme" | return .error "theme must be a string"
  let .ok sectionArg := argString args "section" | return .error "section must be a string"
  let .ok taskArg := argString args "task" | return .error "task must be a string"
  let .ok implArg := argString args "impl" | return .error "impl must be a string"
  let impl ← match chooseImplementation p implArg with
    | .ok i => pure i
    | .error e => return .error e
  let page := match args.getObjVal? "page" with
    | .ok v => (v.getNat?).toOption.getD 1
    | .error _ => 1
  let offset := match args.getObjVal? "offset" with
    | .ok v => (v.getNat?).toOption.getD 0
    | .error _ => 0
  let head := Json.mkObj [("tool", "project_view"), ("verdict", "shown"), ("project", p.name),
    ("projects", toJson names), ("stages", toJson stages),
    ("implementations", toJson ((implementationsOf p).map (·.name))),
    ("implementation", match impl with | some i => Json.str i.name | none => Json.null),
    ("defaultImplementation", match defaultImplementation p with | some i => Json.str i.name | none => Json.null)]
  let body ← match stage with
    | none => pure (.ok (Json.mkObj [("stage", Json.null)]))
    | some "chat" => pure (.ok (← chat p offset))
    | some "book" => book p page (themeArg != some "light")
    | some "requirements" =>
      match fileArg with
      | none => requirements p sectionArg taskArg offset
      | some f =>
        if (← specFiles p).contains f then
          match ← textPage p f offset with
          | .error e => pure (.error e)
          | .ok pg => pure (.ok (Json.mkObj [("stage", "requirements"), ("file", f), ("selected", pg)]))
        else
        let (protocols, _) ← protocolFiles p
        if !protocols.contains f then pure (.error s!"file must be one of the {p.name} protocol files listed by project_view stage requirements")
        else match ← inside p f with
          | none => pure (.error "file must stay inside the project root")
          | some path =>
            let (bytes, over) ← headBytes path maxFileBytes
            let lean := decodeLossy bytes
            if over || lean.length > textPageChars then
              pure (.error s!"{f} is larger than {textPageChars} characters, too large to open whole in the view")
            else pure (.ok (Json.mkObj [("stage", "requirements"), ("file", f), ("lean", lean)]))
    | some "impl" => implStage p impl offset
    | some "code" => code p fileArg offset impl
    | some s => pure (.error s!"stage must be one of {", ".intercalate stages}, not {s}")
  match body with
  | .error e => return .error e
  | .ok b =>
    let merged := match b with
      | .obj kvs => kvs.foldl (fun acc k v => acc.setObjVal! k v) head
      | _ => head
    let st := (b.getObjValAs? String "stage").toOption.getD "projects"
    let file := (b.getObjValAs? String "file").toOption.getD ""
    let implNote := match st, impl with
      | "impl", some i => s!" [{i.name} implementation; impl switches among {", ".intercalate ((implementationsOf p).map (·.name))}]"
      | "code", some i => s!" [{i.name} implementation{if (defaultImplementation p).map (·.name) == some i.name then ", the default" else ""}; impl switches among {", ".intercalate ((implementationsOf p).map (·.name))}]"
      | _, _ => ""
    let text := s!"project_view {p.name} {st}" ++ implNote ++ (if file.isEmpty then "" else s!" ({file})") ++
      (match st with
       | "chat" => if (b.getObjValAs? Bool "found").toOption.getD false then
           s!": {(((b.getObjValD "messages").getArr?).toOption.getD #[]).size} saved messages" else s!": {chatWhere}"
       | "book" => s!": page {(b.getObjValAs? Nat "page").toOption.getD 0} of {(b.getObjValAs? Nat "pages").toOption.getD 0}; the view shows it"
       | "requirements" =>
         let pg := b.getObjValD "page"
         match (b.getObjValAs? String "section").toOption with
         | some sec => s!": {sec}{match (b.getObjValAs? String "task").toOption with | some t => s!" of {t}" | none => ""}, items {(pg.getObjValAs? Nat "offset").toOption.getD 0 + 1} to {(pg.getObjValAs? Nat "offset").toOption.getD 0 + (arrOf pg "items").size} of {(pg.getObjValAs? Nat "total").toOption.getD 0}" ++
             (match (pg.getObjValAs? Nat "next").toOption with | some n => s!"; the next page is offset {n}" | none => "")
         | none => if b.getObjValD "lean" != Json.null then ": the protocol's text" else
             if b.getObjValD "selected" != Json.null then
               s!": characters {((b.getObjValD "selected").getObjValAs? Nat "offset").toOption.getD 0} of {((b.getObjValD "selected").getObjValAs? Nat "total").toOption.getD 0} of the specification's text" ++
               (match ((b.getObjValD "selected").getObjValAs? Nat "next").toOption with | some n => s!"; the next page is offset {n}" | none => "") else
             ": sections " ++ ", ".intercalate ((arrOf b "sections").toList.map fun x =>
               s!"{(x.getObjValAs? String "name").toOption.getD ""} ({(x.getObjValAs? Nat "count").toOption.getD 0})") ++
             "; ask for one with section (and task for a task's transitions, properties or constraints)"
       | "impl" =>
         let sel := b.getObjValD "selected"
         if sel == Json.null then ": no implementation mapping file yet" else
         s!": characters {(sel.getObjValAs? Nat "offset").toOption.getD 0} of {(sel.getObjValAs? Nat "total").toOption.getD 0} of the mapping" ++
           (match ((b.getObjValD "check").getObjValAs? String "status").toOption with
            | some st => s!"; checked against the specification: {st}, {((b.getObjValD "check").getObjValAs? Nat "errors").toOption.getD 0} errors"
            | none => "") ++
           (match (sel.getObjValAs? Nat "next").toOption with | some n => s!"; the next page is offset {n}" | none => "")
       | "code" =>
         match b.getObjValD "selected" with
         | .null =>
           let pg := b.getObjValD "page"
           s!": files {(pg.getObjValAs? Nat "offset").toOption.getD 0 + 1} to {(pg.getObjValAs? Nat "offset").toOption.getD 0 + (arrOf pg "items").size} of {(pg.getObjValAs? Nat "total").toOption.getD 0}, {(arrOf b "mappings").size} traceability mappings" ++
             (match (pg.getObjValAs? Nat "next").toOption with | some n => s!"; the next page is offset {n}" | none => "")
         | sel => s!": {(sel.getObjValAs? String "path").toOption.getD ""}, characters {(sel.getObjValAs? Nat "offset").toOption.getD 0} of {(sel.getObjValAs? Nat "total").toOption.getD 0}, {(arrOf sel "mappings").size} mappings" ++
             (match (sel.getObjValAs? Nat "next").toOption with | some n => s!"; the next page is offset {n}" | none => "")
       | _ => s!": projects {", ".intercalate names}")
    return bounded s!"{p.name} {st}" text merged

/-- A session tool's `{project, file}` (clause selfhost.mcp.session.project-files): the arguments
with those two replaced by `lean`, the text of that one protocol file, so a client loads a project a
file at a time instead of carrying its text. The file must be one project_view lists among the
project's protocol files, its real path inside the project root, and at most `textPageChars`
characters; the project must be one listed. Read only where project_view is served. Arguments
without `file` (and without `project`) are returned as they are. -/
def protocolArgs (args : Json) : IO (Except String Json) := do
  let .obj kvs := args | return .ok args
  if !kvs.contains "file" && !kvs.contains "project" then return .ok args
  unless ← enabled.get do return .error ("project and file " ++ disabledMessage)
  let .ok (some f) := argString args "file" | return .error "file must be a protocol file listed by project_view stage requirements section protocols"
  if kvs.contains "lean" || kvs.contains "protocol" || kvs.contains "example" then
    return .error "give project and file, or lean (or protocol, or example), not both"
  let ps ← projects
  let .ok projectArg := argString args "project" | return .error "project must be a string"
  let name := projectArg.getD "LeanFM"
  let some p := ps.find? (·.name == name)
    | return .error s!"project must be one of {", ".intercalate (ps.toList.map (·.name))}"
  let (protocols, _) ← protocolFiles p
  if !protocols.contains f then
    return .error s!"file must be one of the {p.name} protocol files listed by project_view stage requirements section protocols"
  let some path ← inside p f | return .error "file must stay inside the project root"
  let (bytes, over) ← headBytes path maxFileBytes
  let lean := decodeLossy bytes
  if over || lean.length > textPageChars then
    return .error s!"{f} is larger than {textPageChars} characters, too large to load whole"
  return .ok (Json.obj ((kvs.erase "project").erase "file") |>.setObjVal! "lean" (Json.str lean))

def query (args : Json) : IO (Except String (String × Json)) := do
  unless ← enabled.get do return .error disabledMessage
  answer args

end LeanFM.ProjectView
