import Lean
import Std.Time
import LeanFM.ServerLogs

/-! Which build of LeanFM is answering (clause selfhost.mcp.server-info), so an agent can tell
whether the server it consults runs the code in front of it.

Requirements this module is held to:
* positive (AG): once captured, every answer names the commit HEAD was at start (or why there is
  none), how many tracked files differed from it, when the server started, which executable it runs
  and when that was built, and whether the executable has been rebuilt since (stale).
* negative (never): git runs for a request, or with an argument from one. git runs only in
  `capture`, at start, with the fixed argument arrays below.
* negative (never): git's output reaches an answer except as a commit that passed `isCommit` and a
  count: no file name, branch, remote or error text.
* negative (never): a missing git or a directory that is not a checkout stops the server.
* negative (never): listed on the hosted HTTP endpoint unless LEANFM_MCP_LOGS=1 (the switch
  ServerLogs.enabled, which LeanFM/MCP.lean consults).
Tested in LeanFM/MCPTests.lean. -/

namespace LeanFM.ServerInfo
open Lean

structure Info where
  commit : Option String
  why : String := ""
  changedFiles : Option Nat
  startedAt : Nat
  executable : String
  builtAt : Nat
  deriving Inhabited

/-- Empty until the serving executable calls `capture`. -/
initialize current : IO.Ref (Option Info) ← IO.mkRef none

def baseVersion : String := "0.1.0"

/-- A full git object name: 40 (SHA-1) or 64 (SHA-256) lowercase hexadecimal digits, nothing else. -/
def isCommit (s : String) : Bool :=
  (s.length == 40 || s.length == 64) && s.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- Runs git with fixed arguments and no shell; any failure is `none`, never git's text. -/
def git (args : Array String) : IO (Option String) := do
  try
    let out ← IO.Process.output { cmd := "git", args, stdin := .null }
    return if out.exitCode == 0 then some out.stdout else none
  catch _ => return none

def mtime (path : System.FilePath) : IO Nat := do
  try return (← path.metadata).modified.sec.toNat catch _ => return 0

/-- Called once by each serving executable after it has settled its working directory. -/
def capture : IO Unit := do
  let head ← git #["rev-parse", "HEAD"]
  let first := (head.map fun s => (s.splitOn "\n").headD "").getD ""
  let commit := if isCommit first then some first else none
  let why := if commit.isSome then ""
    else if head.isNone then "the working directory is not a git checkout, or git did not run"
    else "git rev-parse HEAD did not name a commit"
  let status ← git #["status", "--porcelain", "--untracked-files=no"]
  let changed := status.map fun s => ((s.splitOn "\n").filter (· != "")).length
  let now := (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val.toNat
  let exe ← IO.appPath
  current.set (some { commit, why, changedFiles := changed, startedAt := now,
                      executable := exe.toString, builtAt := ← mtime exe })

def short (i : Info) : Option String := i.commit.map (·.take 12 |>.toString)

/-- serverInfo.version: 0.1.0+<12 digits>, with -dirty for a start from uncommitted work. -/
def version : IO String := do
  match ← current.get with
  | some i => match short i with
    | some c => return s!"{baseVersion}+{c}" ++ (if i.changedFiles.getD 0 == 0 then "" else "-dirty")
    | none => return baseVersion
  | none => return baseVersion

def disabledMessage : String :=
  "server_info is off on this host: it is served where server_logs is, by leanfm-mcp --stdio and by leanfm-server " ++
  "on 127.0.0.1, and by the hosted HTTP endpoint only when LEANFM_MCP_LOGS=1"

/-- Rebuilt since start: the executable on disk is newer than it was when the server started. -/
def isStale (builtAt nowMtime : Nat) : Bool := nowMtime > builtAt

def answer (args : Json) : IO (Except String (String × Json)) := do
  match args with
  | .obj kv => unless kv.isEmpty do return .error "server_info takes no arguments"
  | .null => pure ()
  | _ => return .error "server_info takes no arguments"
  let some i ← current.get | return .error "this server has not recorded its start (ServerInfo.capture was not called)"
  let stale := isStale i.builtAt (← mtime i.executable)
  let iso := LeanFM.ServerLogs.isoUtc
  let body := Json.mkObj [
    ("commit", match i.commit with | some c => Json.str c | none => Json.null),
    ("why", if i.commit.isSome then Json.null else Json.str i.why),
    ("changedFiles", match i.changedFiles with | some n => toJson n | none => Json.null),
    ("startedAt", iso i.startedAt), ("executable", i.executable), ("builtAt", iso i.builtAt),
    ("stale", stale), ("version", ← version)]
  let dirty := match i.changedFiles with
    | some 0 => "" | some n => s!", {n} tracked files changed at start" | none => ""
  let text := (match short i with
      | some c => s!"LeanFM at commit {c}{dirty}"
      | none => s!"LeanFM, commit unknown: {i.why}") ++
    s!"; started {iso i.startedAt}, executable built {iso i.builtAt}" ++
    (if stale then "; STALE: the executable has been rebuilt since the server started, restart it to serve the new build" else "")
  return .ok (text, body)

end LeanFM.ServerInfo
