import LeanFM.ChatUI.Requirements
import Init.System.Uri

namespace LeanFM.ChatUI.Store

def fp (s : String) : System.FilePath := System.FilePath.mk s

def dataRoot : IO String := do
  pure ((← IO.getEnv "LEANFM_DATA_ROOT").getD "data")

def accountsRoot : IO String := return (← dataRoot) ++ "/accounts"

def safeId (value : String) : Bool :=
  !value.isEmpty && value.length ≤ 64 && value.toList.all fun c =>
    c.isAlphanum || c == '-' || c == '_'

def accountRoot (username : String) : IO String := return (← accountsRoot) ++ "/" ++ username
def projectsRoot (username : String) : IO String := return (← accountRoot username) ++ "/projects"
def projectRoot (username projectId : String) : IO String := return (← projectsRoot username) ++ "/" ++ projectId

def ensureDataRoot : IO Unit := do
  IO.FS.createDirAll (fp (← accountsRoot))

def readOr (path fallback : String) : IO String := do
  try IO.FS.readFile (fp path) catch _ => pure fallback

def writeAtomic (path body : String) : IO Unit := do
  let nonce ← IO.rand 100000000 999999999
  let temporary := path ++ ".tmp-" ++ toString nonce
  IO.FS.writeFile (fp temporary) body
  let permissions ← IO.Process.output { cmd := "chmod", args := #["600", temporary] }
  if permissions.exitCode != 0 then
    IO.FS.removeFile (fp temporary)
    throw <| IO.userError "cannot restrict file permissions"
  IO.FS.rename (fp temporary) (fp path)

def entries (path : String) : IO (Array IO.FS.DirEntry) := do
  try (fp path).readDir catch _ => pure #[]

def names (path : String) : IO (List String) := do
  return (← entries path).toList.map (·.fileName) |>.mergeSort

def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
  else none

def urlDecode (value : String) : String :=
  System.Uri.UriEscape.decodeUri (value.replace "+" " ")

def formValue? (body key : String) : Option String :=
  (body.splitOn "&").findSome? fun pair =>
    match pair.splitOn "=" with
    | found :: valueParts => if found == key then some (urlDecode (String.intercalate "=" valueParts)) else none
    | _ => none

def headerValue? (request header : String) : Option String :=
  (request.splitOn "\r\n").findSome? fun line =>
    match line.splitOn ":" with
    | name :: values => if name.toLower == header.toLower then some (String.intercalate ":" values).trimAscii.toString else none
    | _ => none

def cookieValue? (request key : String) : Option String := do
  let cookies ← headerValue? request "Cookie"
  (cookies.splitOn ";").findSome? fun item =>
    match item.trimAscii.toString.splitOn "=" with
    | name :: values => if name == key then some (String.intercalate "=" values) else none
    | _ => none

def jsonEscape (s : String) : String :=
  String.join <| s.toList.map fun c =>
    if c == '"' then "\\\"" else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n" else if c == '\r' then "\\r"
    else if c == '\t' then "\\t" else c.toString

def jsonStringValue? (json key : String) : Option String :=
  match json.splitOn ("\"" ++ key ++ "\":\"") with
  | _ :: rest :: _ => some ((rest.splitOn "\"").headD "")
  | _ => none

def jsonNatValue? (json key : String) : Option Nat :=
  match json.splitOn ("\"" ++ key ++ "\":") with
  | _ :: rest :: _ =>
      let chars := rest.toList.dropWhile (fun c => c == ' ' || c == '\n' || c == '\r' || c == '\t')
      let digits := String.ofList (chars.takeWhile Char.isDigit)
      digits.toNat?
  | _ => none

def base64Alphabet : Array Char := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

partial def base64Loop (bytes : List UInt8) : List Char :=
  match bytes with
  | [] => []
  | [a] =>
      [ base64Alphabet[(a.toNat >>> 2)]!
      , base64Alphabet[((a.toNat &&& 3) <<< 4)]!, '=', '=' ]
  | [a, b] =>
      [ base64Alphabet[(a.toNat >>> 2)]!
      , base64Alphabet[(((a.toNat &&& 3) <<< 4) ||| (b.toNat >>> 4))]!
      , base64Alphabet[((b.toNat &&& 15) <<< 2)]!, '=' ]
  | a :: b :: c :: rest =>
      base64Alphabet[(a.toNat >>> 2)]! ::
      base64Alphabet[(((a.toNat &&& 3) <<< 4) ||| (b.toNat >>> 4))]! ::
      base64Alphabet[(((b.toNat &&& 15) <<< 2) ||| (c.toNat >>> 6))]! ::
      base64Alphabet[(c.toNat &&& 63)]! :: base64Loop rest

def base64Encode (value : String) : String :=
  String.ofList (base64Loop value.toUTF8.toList)

def base64Decode (value : String) : IO String := do
  let out ← IO.Process.output { cmd := "base64", args := #["--decode"] } (some value)
  if out.exitCode == 0 then pure out.stdout else throw <| IO.userError "invalid base64 credential"

def randomHex (bytes : Nat) : IO String := do
  let out ← IO.Process.output { cmd := "openssl", args := #["rand", "-hex", toString bytes] }
  if out.exitCode == 0 then pure out.stdout.trimAscii.toString
  else throw <| IO.userError "OS cryptographic randomness is unavailable"

def runCrypto (mode input : String) : IO String := do
  let out ← IO.Process.output { cmd := "python3", args := #["scripts/chatui_crypto.py", mode] } (some input)
  if out.exitCode == 0 then pure out.stdout.trimAscii.toString
  else throw <| IO.userError "credential operation failed"

def passwordRecord (password : String) : IO String :=
  runCrypto "hash" ("{\"password_b64\":\"" ++ base64Encode password ++ "\"}")

def verifyPassword (password record : String) : IO Bool := do
  let salt := (jsonStringValue? record "salt_b64").getD ""
  let digest := (jsonStringValue? record "digest_b64").getD ""
  let iterations := (jsonNatValue? record "iterations").getD 0
  if salt.isEmpty || digest.isEmpty || iterations == 0 then return false
  let input := "{\"password_b64\":\"" ++ base64Encode password ++ "\",\"iterations\":" ++
    toString iterations ++ ",\"salt_b64\":\"" ++ salt ++ "\",\"digest_b64\":\"" ++ digest ++ "\"}"
  return (← runCrypto "verify" input) == "ok"

-- Keys and session bearers are never persisted. Restart requires password login.
structure UnlockedSession where
  token : String
  username : String
  apiKey : String
  expiresAt : Nat

initialize unlockedSessions : IO.Ref (List UnlockedSession) ← IO.mkRef []

def encryptCredential (username password apiKey : String) : IO String :=
  runCrypto "encrypt" ("{\"username\":\"" ++ jsonEscape username ++ "\",\"password_b64\":\"" ++
    base64Encode password ++ "\",\"secret_b64\":\"" ++ base64Encode apiKey ++ "\"}")

def unlockCredential (username password : String) : IO String := do
  let root ← accountRoot username
  let path := root ++ "/credentials/default.json"
  let record ← readOr path ""
  if ← (fp path).pathExists then
    let encoded ← runCrypto "decrypt" ("{\"username\":\"" ++ jsonEscape username ++
      "\",\"password_b64\":\"" ++ base64Encode password ++ "\",\"record\":" ++ record ++ "}")
    -- Remove any legacy duplicate only after authenticated decryption succeeds.
    let legacy := fp (root ++ "/credentials/default.b64")
    if ← legacy.pathExists then IO.FS.removeFile legacy
    return ← base64Decode encoded
  let legacy := fp (root ++ "/credentials/default.b64")
  let encoded ← IO.FS.readFile legacy
  let key ← base64Decode encoded.trimAscii.toString
  if key.trimAscii.isEmpty then throw <| IO.userError "missing credential"
  let encrypted ← encryptCredential username password key
  writeAtomic path (encrypted ++ "\n")
  IO.FS.removeFile legacy
  return key

def sessionCredential? (token username : String) : IO (Option String) := do
  let now ← IO.monoMsNow
  return (← unlockedSessions.get).findSome? fun session =>
    if session.token == token && session.username == username && session.expiresAt > now then
      some session.apiKey else none

def createAccount (username password provider apiKey : String) : IO (Except String String) := do
  if !safeId username then return .error "Username must contain only letters, digits, '-' or '_'."
  if password.length < 8 then return .error "Password must contain at least 8 characters."
  if apiKey.isEmpty then return .error "A provider API key is required."
  ensureDataRoot
  let root ← accountRoot username
  if ← (fp root).pathExists then return .error "That account already exists."
  IO.FS.createDirAll (fp (root ++ "/credentials"))
  IO.FS.createDirAll (fp (root ++ "/projects"))
  let encrypted ← encryptCredential username password apiKey
  let verifier ← passwordRecord password
  writeAtomic (root ++ "/password.json") (verifier ++ "\n")
  writeAtomic (root ++ "/account.json") ("{\"username\":\"" ++ jsonEscape username ++ "\",\"provider\":\"" ++ jsonEscape provider ++ "\"}\n")
  writeAtomic (root ++ "/credentials/default.json") (encrypted ++ "\n")
  pure (.ok "default")

def login (username password : String) : IO (Except String String) := do
  if !safeId username then return .error "Invalid username or password."
  let root ← accountRoot username
  let record ← readOr (root ++ "/password.json") ""
  if record.isEmpty || !(← verifyPassword password record) then return .error "Invalid username or password."
  let key ← try unlockCredential username password catch _ =>
    return .error "The stored API key could not be unlocked."
  let token ← randomHex 32
  let now ← IO.monoMsNow
  unlockedSessions.modify fun sessions =>
    { token, username, apiKey := key, expiresAt := now + 8 * 60 * 60 * 1000 } ::
      ((sessions.filter (fun session => session.expiresAt > now)).take 255)
  pure (.ok token)

def userForSession? (token : String) : IO (Option String) := do
  if token.length != 64 || !token.toList.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')) then return none
  let now ← IO.monoMsNow
  unlockedSessions.modify (List.filter (fun session => session.expiresAt > now))
  return (← unlockedSessions.get).findSome? fun session =>
    if session.token == token then some session.username else none

def latexEscape (value : String) : String :=
  String.join <| value.toList.map fun c =>
    if c == '\\' then "\\textbackslash{}"
    else if c == '{' then "\\{"
    else if c == '}' then "\\}"
    else if c == '#' then "\\#"
    else if c == '$' then "\\$"
    else if c == '%' then "\\%"
    else if c == '&' then "\\&"
    else if c == '_' then "\\_"
    else if c == '^' then "\\textasciicircum{}"
    else if c == '~' then "\\textasciitilde{}"
    else c.toString

def projectBookSource (name : String) : String :=
  "\\documentclass[11pt,oneside]{book}\n" ++
  "\\usepackage[margin=1in]{geometry}\n\\usepackage{xcolor}\n\\usepackage[hidelinks]{hyperref}\n" ++
  "\\ifdefined\\darkmode\\pagecolor[HTML]{091117}\\color[HTML]{F0EDE4}\\fi\n" ++
  "\\title{" ++ latexEscape name ++ "}\\author{Project team}\\date{\\today}\n" ++
  "\\begin{document}\n\\frontmatter\n\\maketitle\n\\tableofcontents\n\\mainmatter\n" ++
  "\\chapter{Project sketch}\n" ++
  "This is the working design book for \\textbf{" ++ latexEscape name ++ "}. It begins as a sketch and is revised primarily through the Book layer of project chat.\n\n" ++
  "\\section{Problem}\nDescribe the problem, the people or systems affected, and the observable outcome that would make the project useful.\n\n" ++
  "\\section{Scenarios and tasks}\nRecord the named user and system scenarios. As tasks become precise, their generated interaction diagrams and state machines belong here with their provenance.\n\n" ++
  "\\section{Open questions}\nKeep unresolved design questions explicit until the conversation supplies durable answers.\n\n" ++
  "\\chapter{Requirements argument}\nCapture decisions and alternatives here before promoting observable behavior through the requirements acceptance gate.\n\n" ++
  "\\chapter{Implementation argument}\nAfter requirements acceptance, record implementation mappings, transports, repository choices, and validation evidence here.\n" ++
  "\\end{document}\n"

def projectBookMakefile : String :=
  "LATEX := pdflatex\nMAIN := main\nDARK := main-dark\n\n.PHONY: all light dark clean\n\n" ++
  "all: light dark\n\nlight:\n\t$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex\n\t$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex\n\n" ++
  "dark:\n\t$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error \"\\def\\darkmode{1}\\input{$(MAIN).tex}\"\n\t$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error \"\\def\\darkmode{1}\\input{$(MAIN).tex}\"\n\n" ++
  "clean:\n\trm -f $(MAIN).aux $(MAIN).log $(MAIN).out $(MAIN).toc $(MAIN).pdf $(DARK).aux $(DARK).log $(DARK).out $(DARK).toc $(DARK).pdf\n"

def cleanProjectBookIntermediates (root : String) : IO Unit := do
  for file in ["main.aux", "main.log", "main.out", "main.toc", "main-dark.aux", "main-dark.log", "main-dark.out", "main-dark.toc"] do
    let path := fp (root ++ "/book/" ++ file)
    if ← path.pathExists then IO.FS.removeFile path

def provisionProjectBook (root name : String) : IO Unit := do
  IO.FS.createDirAll (fp (root ++ "/book"))
  cleanProjectBookIntermediates root
  writeAtomic (root ++ "/book/main.tex") (projectBookSource name)
  writeAtomic (root ++ "/book/Makefile") projectBookMakefile

def provisionProjectSpecifications (root name : String) : IO Unit := do
  let escaped := jsonEscape name
  writeAtomic (root ++ "/spec/Requirements.lean")
    ("/-- Project-owned observable requirements for " ++ name ++ ".\n" ++
     "    Book-layer discovery has not yet produced an accepted specification. -/\n" ++
     "namespace Project.Requirements\n\ndef projectName : String := \"" ++ escaped ++ "\"\n\nend Project.Requirements\n")
  writeAtomic (root ++ "/spec/Requirements.proto")
    ("syntax = \"proto3\";\n\npackage project.requirements;\n\n// Generated after this project's observable requirements are identified.\n")
  writeAtomic (root ++ "/spec/Implementation.lean")
    ("/-- Project-owned implementation mapping for " ++ name ++ ".\n" ++
     "    This remains empty until requirements acceptance. -/\n" ++
     "namespace Project.Implementation\n\ndef projectName : String := \"" ++ escaped ++ "\"\n\nend Project.Implementation\n")

def repairSelfHostingSpecificationLeak (root name : String) : IO Bool := do
  let projectRequirements ← readOr (root ++ "/spec/Requirements.lean") ""
  let selfRequirements ← readOr "LeanFM/ChatUI/Requirements.lean" ""
  if projectRequirements.isEmpty || (!selfRequirements.isEmpty && projectRequirements == selfRequirements) then
    provisionProjectSpecifications root name
    pure true
  else pure false

def createProject (username name : String) : IO (Except String String) := do
  let projectId ← randomHex 8
  let root ← projectRoot username projectId
  IO.FS.createDirAll (fp root)
  for dir in ["inputs", "book", "spec", "source", "tests", "artifacts", "renders", "events", "reports", "logs", "cache", "conversations"] do
    IO.FS.createDirAll (fp (root ++ "/" ++ dir))
  writeAtomic (root ++ "/manifest.json") ("{\"project_id\":\"" ++ projectId ++ "\",\"display_name\":\"" ++ jsonEscape name ++ "\"}\n")
  provisionProjectBook root name
  let builtBook ← IO.Process.output { cmd := "make", args := #["-C", root ++ "/book"] }
  if builtBook.exitCode != 0 then
    IO.FS.removeDirAll (fp root)
    return .error "The project book sketch could not be built."
  provisionProjectSpecifications root name
  pure (.ok projectId)

def projectListJson (username : String) : IO String := do
  let root ← projectsRoot username
  let mut items : List String := []
  for entry in (← entries root) do
    if safeId entry.fileName then
      let manifest ← readOr (entry.path.toString ++ "/manifest.json") ""
      let name := (jsonStringValue? manifest "display_name").getD entry.fileName
      items := ("{\"project_id\":\"" ++ entry.fileName ++ "\",\"display_name\":\"" ++ jsonEscape name ++ "\",\"read_only\":false}") :: items
  let workspace := "{\"project_id\":\"leanfm-workspace\",\"display_name\":\"LeanFM\",\"read_only\":true,\"kind\":\"workspace\"}"
  pure ("[" ++ String.intercalate "," (items.reverse ++ [workspace]) ++ "]")

def deleteProject (username projectId confirmation : String) : IO (Except String Unit) := do
  if !safeId projectId then return .error "Invalid project identifier."
  let parent ← projectsRoot username
  let root ← projectRoot username projectId
  let manifest ← readOr (root ++ "/manifest.json") ""
  if manifest.isEmpty then return .error "Project not found."
  let displayName := (jsonStringValue? manifest "display_name").getD projectId
  if confirmation != displayName then return .error "Project name confirmation did not match."
  let realParent ← IO.FS.realPath (fp parent)
  let realRoot ← IO.FS.realPath (fp root)
  if realRoot.toString != realParent.toString ++ "/" ++ projectId then
    return .error "Project root did not resolve to the owned projects directory."
  IO.FS.removeDirAll realRoot
  pure (.ok ())

end LeanFM.ChatUI.Store
