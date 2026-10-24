import LeanFM.ChatUI.Requirements
import Lean.Data.Json
import Init.System.Uri
import Std.Sync.Mutex

namespace LeanFM.ChatUI.Store

def fp (s : String) : System.FilePath := System.FilePath.mk s

def workspaceRoot : IO String := do
  if (← IO.getEnv "LEANFM_DATA_ROOT").isSome && (← IO.getEnv "LEANFM_WORKSPACE_ROOT").isNone then
    throw (IO.userError "LEANFM_DATA_ROOT is obsolete. Use LEANFM_WORKSPACE_ROOT; projects belong in projects/ and encrypted accounts in .leanfm/accounts/.")
  let root := ((← IO.getEnv "LEANFM_WORKSPACE_ROOT").getD ".")
  IO.FS.createDirAll (fp root)
  if ← (fp (root ++ "/data/accounts")).pathExists then
    throw (IO.userError "Legacy data/accounts storage is present. Stop the service and explicitly migrate or reset it; LeanFM will not silently create a second account namespace.")
  pure (← IO.FS.realPath (fp root)).toString

def dataRoot : IO String := return (← workspaceRoot) ++ "/.leanfm"

def accountsRoot : IO String := return (← dataRoot) ++ "/accounts"

def safeId (value : String) : Bool :=
  !value.isEmpty && value.length ≤ 64 && value.toList.all fun c =>
    c.isAlphanum || c == '-' || c == '_'

def accountRoot (username : String) : IO String := return (← accountsRoot) ++ "/" ++ username
def projectsRoot (_username : String) : IO String := return (← workspaceRoot) ++ "/projects"
def projectRoot? (_username projectId : String) : IO (Option String) := do
  if !safeId projectId then return none
  let out ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["workspace-resolve", ← workspaceRoot, projectId]}
  return if out.exitCode == 0 then some out.stdout.trimAscii.toString else none

def ensureDataRoot : IO Unit := do
  IO.FS.createDirAll (fp (← accountsRoot))
  let out ← IO.Process.output {cmd := "chmod", args := #["700", ← dataRoot, ← accountsRoot]}
  if out.exitCode != 0 then throw (IO.userError "Cannot protect credential vault permissions")

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
  (((request.splitOn "\r\n\r\n").headD "").splitOn "\r\n").findSome? fun line =>
    match line.splitOn ":" with
    | name :: values => if name.toLower == header.toLower then some (String.intercalate ":" values).trimAscii.toString else none
    | _ => none

def cookieValue? (request key : String) : Option String := do
  let cookies ← headerValue? request "Cookie"
  (cookies.splitOn ";").findSome? fun item =>
    match item.trimAscii.toString.splitOn "=" with
    | name :: values => if name == key then some (String.intercalate "=" values) else none
    | _ => none

-- Keep the released default cookie name, while independent local services
-- must not overwrite one another's browser session. Cookies have no port scope.
def sessionCookieName : IO String := do
  let port := (((← IO.getEnv "LEANFM_PORT").getD "8080").toNat?).getD 8080
  pure (if port == 8080 then "leanfm_session" else "leanfm_session_" ++ toString port)

def requestSessionToken? (request : String) : IO (Option String) := do
  pure ((cookieValue? request (← sessionCookieName)).orElse fun _ =>
    cookieValue? request "leanfm_session")

def sessionCookieHeader (token : String) : IO String := do
  pure ("Set-Cookie: " ++ (← sessionCookieName) ++ "=" ++ token ++
    "; Path=/; HttpOnly; SameSite=Strict")

def jsonEscape (s : String) : String :=
  String.join <| s.toList.map fun c =>
    if c == '"' then "\\\"" else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n" else if c == '\r' then "\\r"
    else if c == '\t' then "\\t" else c.toString

def jsonStringValue? (json key : String) : Option String :=
  (Lean.Json.parse json).toOption.bind fun value =>
    ((value.getObjVal? key).bind Lean.Json.getStr?).toOption

def jsonNatValue? (json key : String) : Option Nat :=
  (Lean.Json.parse json).toOption.bind fun value =>
    ((value.getObjVal? key).bind Lean.Json.getNat?).toOption

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
structure UnlockedCredential where
  provider : String
  credentialRef : String
  apiKey : String
  fingerprint : String

structure UnlockedSession where
  token : String
  username : String
  apiKey : String
  provider : String
  credentialRef : String
  credentialFingerprint : String
  tokensUsed : Nat
  tokenBudget : Nat
  expiresAt : Nat
  credentials : List UnlockedCredential := []

initialize unlockedSessions : IO.Ref (List UnlockedSession) ← IO.mkRef []

-- Serialize credential read/modify/write and login snapshots. Otherwise two
-- simultaneous provider updates can silently discard one another, or a login
-- can publish a session with keys read immediately before a rotation.
initialize credentialLock : Std.BaseMutex ← Std.BaseMutex.new

private def withCredentialLock (action : IO α) : IO α := do
  credentialLock.lock
  try action finally credentialLock.unlock

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

def sessionCredentials (token username : String) : IO (List UnlockedCredential) := do
  let now ← IO.monoMsNow
  return ((← unlockedSessions.get).find? fun session =>
    session.token == token && session.username == username && session.expiresAt > now).map
      (·.credentials) |>.getD []

def sessionCredential? (token username : String) (provider : String := "openai") : IO (Option String) := do
  return (← sessionCredentials token username).findSome? fun credential =>
    if credential.provider == provider then some credential.apiKey else none

def sessionCredentialMetadata? (token username provider : String) : IO (Option UnlockedCredential) := do
  return (← sessionCredentials token username).find? (·.provider == provider)

def sessionActive? (token username : String) : IO Bool := do
  let now ← IO.monoMsNow
  return (← unlockedSessions.get).any fun session =>
    if session.token == token && session.username == username && session.expiresAt > now then
      true else false

structure SessionBilling where
  provider : String
  credentialRef : String
  credentialFingerprint : String
  tokensUsed : Nat
  tokenBudget : Nat
deriving Repr

def sessionBilling? (token username : String) : IO (Option SessionBilling) := do
  let now ← IO.monoMsNow
  return (← unlockedSessions.get).findSome? fun session =>
    if session.token == token && session.username == username && session.expiresAt > now then
      some { provider := session.provider, credentialRef := session.credentialRef
           , credentialFingerprint := session.credentialFingerprint
           , tokensUsed := session.tokensUsed, tokenBudget := session.tokenBudget }
    else none

def recordSessionUsage (token username : String) (tokens : Nat) : IO Unit := do
  unlockedSessions.modify fun sessions => sessions.map fun session =>
    if session.token == token && session.username == username then
      { session with tokensUsed := session.tokensUsed + tokens }
    else session

def privateIdentityTag (value : String) : IO String := do
  let out ← IO.Process.output { cmd := "openssl", args := #["dgst", "-sha256"] } (some value)
  if out.exitCode != 0 then throw <| IO.userError "cannot fingerprint provider credential"
  let digest := out.stdout.trimAscii.toString.splitOn " " |>.getLast?.getD ""
  if digest.length != 64 then throw <| IO.userError "invalid private identity digest"
  pure digest

def keyFingerprint (key : String) : IO String := do
  pure ((← privateIdentityTag key).take 12).toString

def supportedProvider (provider : String) : Bool := ["openai", "anthropic"].contains provider

def validCredentialPairs (pairs : List (String × String)) : Bool :=
  !pairs.isEmpty && (pairs.map Prod.fst).eraseDups.length == pairs.length &&
    pairs.all (fun (provider, key) => supportedProvider provider && !key.trimAscii.isEmpty &&
      key.length ≤ 4096 && key.toList.all (fun c => c.toNat ≥ 33 && c.toNat ≤ 126))

/-- Provider labels and their keys are authenticated together inside one AEAD
    ciphertext. Swapping plaintext provider metadata cannot redirect a key. -/
def saveCredentialBundle (username password : String) (pairs : List (String × String)) : IO Unit := do
  if !validCredentialPairs pairs then throw (IO.userError "invalid provider credentials")
  let plain := (Lean.Json.mkObj [("version", Lean.toJson (1 : Nat)),
    ("credentials", Lean.toJson (pairs.map fun (provider, key) =>
      Lean.Json.mkObj [("provider", Lean.toJson provider), ("key", Lean.toJson key)]))]).compress
  let encrypted ← encryptCredential username password plain
  let root ← accountRoot username
  writeAtomic (root ++ "/credentials/providers.json") (encrypted ++ "\n")
  -- Promotion precedes removal: a failed write preserves the legacy credential.
  for name in ["default.json", "default.b64"] do
    let legacy := fp (root ++ "/credentials/" ++ name)
    if ← legacy.pathExists then IO.FS.removeFile legacy

def unlockCredentialPairs (username password : String) : IO (List (String × String)) := do
  let root ← accountRoot username
  let path := root ++ "/credentials/providers.json"
  if ← (fp path).pathExists then
    let record ← IO.FS.readFile (fp path)
    let encoded ← runCrypto "decrypt" ("{\"username\":\"" ++ jsonEscape username ++
      "\",\"password_b64\":\"" ++ base64Encode password ++ "\",\"record\":" ++ record ++ "}")
    let plain ← base64Decode encoded
    let .ok json := Lean.Json.parse plain | throw (IO.userError "invalid credential bundle")
    let .ok version := (json.getObjVal? "version").bind Lean.Json.getNat?
      | throw (IO.userError "invalid credential bundle version")
    if version != 1 then throw (IO.userError "unsupported credential bundle version")
    let .ok items := (json.getObjVal? "credentials").bind Lean.Json.getArr?
      | throw (IO.userError "invalid credential bundle entries")
    let pairs ← items.toList.mapM fun item => do
      let .ok provider := (item.getObjVal? "provider").bind Lean.Json.getStr?
        | throw (IO.userError "invalid credential provider")
      let .ok key := (item.getObjVal? "key").bind Lean.Json.getStr?
        | throw (IO.userError "invalid credential key")
      pure (provider, key)
    if !validCredentialPairs pairs then throw (IO.userError "invalid provider credential bundle")
    return pairs
  let account ← readOr (root ++ "/account.json") ""
  let provider := (jsonStringValue? account "provider").getD "openai"
  if !supportedProvider provider then throw (IO.userError "unsupported stored credential provider")
  return [(provider, ← unlockCredential username password)]

private def updateCredentialBundleUnlocked (username password : String) (additions : List (String × String)) : IO (Except String Unit) := do
  let root ← accountRoot username
  let record ← readOr (root ++ "/password.json") ""
  if record.isEmpty || !(← verifyPassword password record) then return .error "Invalid username or password."
  if !validCredentialPairs additions then return .error "Supply a valid key for each selected provider (at most 4096 characters)."
  try
    let existing ← unlockCredentialPairs username password
    let replaced := additions.map Prod.fst
    -- Revoke before promotion, including when obsolete-file cleanup fails after
    -- a successful promotion. A failed update may sign out, never retain old keys.
    unlockedSessions.modify (List.filter (·.username != username))
    saveCredentialBundle username password (existing.filter (fun pair => !replaced.contains pair.1) ++ additions)
    return .ok ()
  catch _ => return .error "The encrypted key bundle could not be updated or its obsolete credential files could not be removed."

def updateCredentialBundle (username password : String) (additions : List (String × String)) : IO (Except String Unit) :=
  withCredentialLock (updateCredentialBundleUnlocked username password additions)

/-- Adding a provider preserves the initiating session and its spend/expiry.
    Replacing a secret retains the existing revoke-before-promotion policy. -/
def updateSessionCredentialBundle (username token password : String)
    (additions : List (String × String)) : IO (Except String Bool) :=
  withCredentialLock do
    if !(← sessionActive? token username) then return .error "Sign in before updating provider keys."
    let record ← readOr ((← accountRoot username) ++ "/password.json") ""
    if record.isEmpty || !(← verifyPassword password record) then return .error "Invalid username or password."
    if !validCredentialPairs additions then return .error "Supply at least one valid provider key."
    try
      let existing ← unlockCredentialPairs username password
      let rotation := additions.any fun (provider, key) =>
        existing.any fun (oldProvider, oldKey) => oldProvider == provider && oldKey != key
      let replaced := additions.map Prod.fst
      let merged := existing.filter (fun pair => !replaced.contains pair.1) ++ additions
      let credentials ← merged.mapM fun (provider, apiKey) => do
        let fingerprint ← keyFingerprint apiKey
        pure ({ provider := provider, apiKey := apiKey, fingerprint := fingerprint, credentialRef := (if provider == "openai" then "default" else provider) } : UnlockedCredential)
      if !(← sessionActive? token username) then return .error "The initiating login ended; no key update was applied."
      if rotation then unlockedSessions.modify (List.filter (·.username != username))
      saveCredentialBundle username password merged
      if rotation then return .ok false
      if !(← sessionActive? token username) then
        return .error "The keys were saved, but the initiating login ended. Sign in again to unlock them."
      unlockedSessions.modify fun sessions => sessions.map fun session =>
        if session.token == token && session.username == username then {session with credentials} else session
      return .ok true
    catch _ => return .error "The encrypted provider keys could not be updated safely."

private def createAccountUnlocked (username password provider apiKey : String)
    (additionalKeys : List (String × String) := []) : IO (Except String String) := do
  if !safeId username then return .error "Username must contain only letters, digits, '-' or '_'."
  if password.length < 8 then return .error "Password must contain at least 8 characters."
  if !validCredentialPairs ((provider, apiKey) :: additionalKeys) then
    return .error "A valid OpenAI or Anthropic API key is required for each selected provider."
  ensureDataRoot
  let root ← accountRoot username
  if ← (fp root).pathExists then return .error "That account already exists."
  IO.FS.createDirAll (fp (root ++ "/credentials"))
  let encrypted ← encryptCredential username password apiKey
  let verifier ← passwordRecord password
  writeAtomic (root ++ "/password.json") (verifier ++ "\n")
  writeAtomic (root ++ "/account.json") ("{\"username\":\"" ++ jsonEscape username ++ "\",\"provider\":\"" ++ jsonEscape provider ++ "\"}\n")
  if additionalKeys.isEmpty then writeAtomic (root ++ "/credentials/default.json") (encrypted ++ "\n")
  else saveCredentialBundle username password ((provider, apiKey) :: additionalKeys)
  pure (.ok "default")

def createAccount (username password provider apiKey : String)
    (additionalKeys : List (String × String) := []) : IO (Except String String) :=
  withCredentialLock (createAccountUnlocked username password provider apiKey additionalKeys)

private def loginUnlocked (username password : String) : IO (Except String String) := do
  if !safeId username then return .error "Invalid username or password."
  let root ← accountRoot username
  let record ← readOr (root ++ "/password.json") ""
  if record.isEmpty || !(← verifyPassword password record) then return .error "Invalid username or password."
  let pairs ← try unlockCredentialPairs username password catch _ =>
    return .error "The stored provider keys could not be unlocked."
  let credentials ← try pairs.mapM fun (provider, apiKey) => do
      let fingerprint ← keyFingerprint apiKey
      pure ({ provider := provider, apiKey := apiKey, fingerprint := fingerprint
            , credentialRef := if provider == "openai" then "default" else provider } : UnlockedCredential)
    catch _ => return .error "The stored provider keys could not be identified safely."
  let some primary := (credentials.find? (·.provider == "openai")).orElse (fun _ => credentials.head?)
    | return .error "No provider key is available."
  let tokenBudget := ((← IO.getEnv "LEANFM_SESSION_TOKEN_BUDGET").bind String.toNat?).getD 1000000
  let token ← randomHex 32
  let now ← IO.monoMsNow
  unlockedSessions.modify fun sessions =>
    { token, username, apiKey := primary.apiKey, provider := primary.provider, credentialRef := primary.credentialRef
    , credentialFingerprint := primary.fingerprint, tokensUsed := 0, tokenBudget, credentials
    , expiresAt := now + 8 * 60 * 60 * 1000 } ::
      ((sessions.filter (fun session => session.expiresAt > now)).take 255)
  pure (.ok token)

def login (username password : String) : IO (Except String String) :=
  withCredentialLock (loginUnlocked username password)

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
  let parent ← projectsRoot username
  IO.FS.createDirAll (fp parent)
  if (← IO.FS.realPath (fp parent)).toString != (← workspaceRoot) ++ "/projects" then
    return .error "Projects directory cannot escape the workspace."
  let reserved ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["workspace-create", ← workspaceRoot, name]}
  if reserved.exitCode != 0 then return .error "A readable project directory could not be reserved safely."
  let some projectId := jsonStringValue? reserved.stdout "project_id" | return .error "Project identity was not returned."
  let some root := jsonStringValue? reserved.stdout "root" | return .error "Project directory was not returned."
  for dir in ["inputs", "book", "spec", "source", "tests", "artifacts", "renders", "events", "reports", "logs", "cache", "conversations"] do
    IO.FS.createDirAll (fp (root ++ "/" ++ dir))
  writeAtomic (root ++ "/manifest.json") ("{\"project_id\":\"" ++ projectId ++ "\",\"display_name\":\"" ++ jsonEscape name ++
    "\",\"root\":\".\",\"book\":\"book/main.pdf\",\"dark_book\":\"book/main-dark.pdf\",\"book_source\":\"book/main.tex\",\"requirements\":\"spec/Requirements.lean\",\"protobuf\":\"spec/Requirements.proto\",\"implementation\":\"spec/Implementation.lean\",\"tasks\":\"spec/tasks.json\",\"source\":\"source/\",\"evidence\":\"reports/\",\"acceptance\":{\"requirements\":\"not-recorded\",\"implementation\":\"not-recorded\"}}\n")
  provisionProjectBook root name
  let builtBook ← IO.Process.output { cmd := "make", args := #["-C", root ++ "/book"] }
  if builtBook.exitCode != 0 then
    IO.FS.removeDirAll (fp root)
    return .error "The project book sketch could not be built."
  provisionProjectSpecifications root name
  pure (.ok projectId)

def projectListJson (username : String) : IO String := do
  let _ := username
  let out ← IO.Process.output {cmd := "scripts/chatui_command.sh", args := #["workspace-list", ← workspaceRoot]}
  let items := match Lean.Json.parse out.stdout with
    | .ok value => (value.getArr?.toOption.getD #[]).toList.map Lean.Json.compress
    | .error _ => []
  let workspace := "{\"project_id\":\"leanfm-workspace\",\"display_name\":\"LeanFM\",\"read_only\":true,\"kind\":\"workspace\"}"
  pure ("[" ++ String.intercalate "," (items ++ [workspace]) ++ "]")

def deleteProject (username projectId confirmation : String) : IO (Except String Unit) := do
  if !safeId projectId then return .error "Invalid project identifier."
  let parent ← projectsRoot username
  let some root ← projectRoot? username projectId | return .error "Project not found or its identity is ambiguous."
  let manifest ← readOr (root ++ "/manifest.json") (← readOr (root ++ "/project.json") "")
  if manifest.isEmpty then return .error "Project not found."
  let displayName := (jsonStringValue? manifest "display_name").orElse (fun _ => jsonStringValue? manifest "title") |>.getD projectId
  if confirmation != displayName then return .error "Project name confirmation did not match."
  let realParent ← IO.FS.realPath (fp parent)
  let realRoot ← IO.FS.realPath (fp root)
  if realRoot.parent != some realParent then
    return .error "Project root did not resolve to the owned projects directory."
  IO.FS.removeDirAll realRoot
  pure (.ok ())

end LeanFM.ChatUI.Store
