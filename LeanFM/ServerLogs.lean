import Lean
import LeanFM.LogIndex

/-! Reading LeanFM's own logs and Claude Desktop's logs of LeanFM, so an agent can diagnose a
failure itself instead of asking the user to paste log files.

Served two ways, with the same answers:
* the MCP tool `server_logs` (LeanFM/MCP.lean), on `leanfm-mcp --stdio` and on leanfm-server's /mcp;
* `GET /tools/logs` on leanfm-server (Server.lean).

Requirements this module is held to:
* positive (AG): every answer names the log it read, where that file is, its size and when it last
  changed, so a reader can line its timestamps up with another log.
* negative (never): a file outside `sources` is read. The argument names a log, never a path, so
  there is no path to traverse; a name not in `sources` is refused.
* negative (never): the hosted HTTP endpoint (`leanfm-mcp` without --stdio, for a public host)
  serves logs, unless its operator sets LEANFM_MCP_LOGS=1. The tool is not even listed there.
* negative (never): an answer exceeds `charLimit` characters, or reads more than the last
  `windowBytes` of a file, however large the log grows.
* negative (never): a bearer token, an `sk-` API key or a `token=` value is shown; they are
  replaced with [redacted] before the answer leaves.
Tested in LeanFM/MCPTests.lean. -/

namespace LeanFM.ServerLogs
open Lean

/-- Off until the executable that is allowed to serve logs turns it on. -/
initialize enabled : IO.Ref Bool ← IO.mkRef false

def enable : IO Unit := enabled.set true

def defaultLines : Nat := 100
def maxLines : Nat := 2000
def charLimit : Nat := 60000
/-- Only the last 4 MiB of a log is read. -/
def windowBytes : Nat := 4 * 1024 * 1024
def maxGrep : Nat := 200

structure Source where
  name : String
  description : String
  /-- true: relative to the LeanFM checkout (the working directory); false: Claude Desktop's log folder -/
  project : Bool
  file : String

def sources : List Source := [
  ⟨"desktop-mcp", "Claude Desktop's log of the leanfm MCP server: every message, connects and disconnects, and anything leanfm-mcp writes to standard error", false, "mcp-server-leanfm.log"⟩,
  ⟨"desktop-mcp-all", "Claude Desktop's log of all its MCP servers", false, "mcp.log"⟩,
  ⟨"desktop-main", "Claude Desktop's main log (app restarts, connectors, memory)", false, "main.log"⟩,
  ⟨"serve", "output of make serve: leanfm-server's standard output and error", true, "logs/serve.log"⟩,
  ⟨"server", "leanfm-server's own log file", true, "logs/leanfm-server.log"⟩,
  ⟨"diagnostics", "LeanFM's runtime diagnostics journal (JSON lines)", true, "logs/runtime-diagnostics.jsonl"⟩]

def names : List String := sources.map (·.name)

def disabledMessage : String :=
  "server_logs is off on this host: it is served by leanfm-mcp --stdio and by leanfm-server on 127.0.0.1, " ++
  "and by the hosted HTTP endpoint only when LEANFM_MCP_LOGS=1"

/-- Claude Desktop's log folder: ~/.config/Claude/logs on Linux, ~/Library/Logs/Claude on macOS. -/
def desktopLogDir : IO (Option System.FilePath) := do
  let some home ← IO.getEnv "HOME" | return none
  for d in [home ++ "/.config/Claude/logs", home ++ "/Library/Logs/Claude"] do
    if ← System.FilePath.isDir d then return some d
  return none

def pathOf (s : Source) : IO (Option System.FilePath) := do
  if s.project then
    return some ((← IO.currentDir) / s.file)
  else
    return (← desktopLogDir).map (· / s.file)

/-- A Unix time in seconds as UTC, e.g. 2026-11-16T18:15:18Z, to line up with the logs' own timestamps. -/
def isoUtc (sec : Nat) : String :=
  let days := sec / 86400
  let rem := sec % 86400
  -- civil-from-days (Howard Hinnant), for dates after 1970
  let z := days + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  let y := yoe + era * 400 + (if m <= 2 then 1 else 0)
  let two (n : Nat) := if n < 10 then s!"0{n}" else toString n
  s!"{y}-{two m}-{two d}T{two (rem / 3600)}:{two (rem % 3600 / 60)}:{two (rem % 60)}Z"

/-! ## Reading the end of a file -/

/-- The last `window` bytes of a file, read in 1 MiB chunks so a large log never sits in memory. -/
partial def tailBytes (path : System.FilePath) (window : Nat := windowBytes) : IO (ByteArray × Bool) := do
  let h ← IO.FS.Handle.mk path .read
  let rec go (buf : ByteArray) (cut : Bool) : IO (ByteArray × Bool) := do
    let chunk ← h.read 1048576
    if chunk.isEmpty then
      if buf.size > window then return (buf.extract (buf.size - window) buf.size, true)
      return (buf, cut)
    let buf := buf ++ chunk
    if buf.size > 2 * window then go (buf.extract (buf.size - window) buf.size) true
    else go buf cut
  go ByteArray.empty false

/-- UTF-8 text from bytes; a byte that does not decode becomes '?'. -/
def decodeLossy (bytes : ByteArray) : String :=
  match String.fromUTF8? bytes with
  | some s => s
  | none => String.ofList (bytes.toList.map fun b => if b < 128 then Char.ofNat b.toNat else '?')

/-! ## Redaction -/

def redactWord (prev word : String) : String :=
  if prev == "Bearer" || prev == "bearer" then "[redacted]"
  else if (word.splitOn "sk-").length > 1 && word.length > 20 then "[redacted]"
  else if word.startsWith "token=" && word != "token=required" && word != "token=none" then "token=[redacted]"
  else word

def redactLine (line : String) : String :=
  let words := line.splitOn " "
  let (_, out) := words.foldl (fun (prev, acc) w => (w, acc.push (redactWord prev w))) ("", (#[] : Array String))
  " ".intercalate out.toList

/-! ## Answers -/

structure Answer where
  log : String
  path : String
  found : Bool
  bytes : Nat := 0
  modifiedUnix : Nat := 0
  /-- the lines returned, oldest first -/
  lines : Array String := #[]
  /-- lines that matched before the count was applied -/
  matched : Nat := 0
  partialRead : Bool := false
  note : String := ""

def lineMatches (grep : Option String) (line : String) : Bool :=
  match grep with
  | none => true
  | some g => (line.toLower.splitOn g.toLower).length > 1

/-- Keep the newest lines whose total stays within `charLimit`. -/
def fitLimit (ls : Array String) : Array String × Bool := Id.run do
  let mut total := 0
  let mut kept : Array String := #[]
  for l in ls.reverse do
    if total + l.length + 1 > charLimit then return (kept.reverse, true)
    total := total + l.length + 1
    kept := kept.push l
  return (kept.reverse, false)

def read (s : Source) (count : Nat) (grep : Option String) : IO Answer := do
  let some path ← pathOf s
    | return { log := s.name, path := "", found := false, note := "Claude Desktop's log folder was not found under HOME" }
  unless ← path.pathExists do
    return { log := s.name, path := path.toString, found := false, note := "no such file yet" }
  let md ← path.metadata
  let (bytes, cut) ← tailBytes path
  let text := decodeLossy bytes
  let all := (text.splitOn "\n").toArray
  -- a cut window starts mid-line: drop that first fragment
  let all := if cut && all.size > 1 then all.extract 1 all.size else all
  let all := if all.back? == some "" then all.pop else all
  let hit := all.filter (lineMatches grep)
  let picked := hit.extract (hit.size - min hit.size count) hit.size
  let (fitted, trimmed) := fitLimit (picked.map redactLine)
  let notes := (if cut then [s!"only the last {windowBytes / 1048576} MiB of the file was read"] else []) ++
    (if trimmed then [s!"older lines were dropped to stay within {charLimit} characters"] else [])
  return { log := s.name, path := path.toString, found := true, bytes := md.byteSize.toNat,
           modifiedUnix := md.modified.sec.toNat, lines := fitted, matched := hit.size,
           partialRead := cut, note := "; ".intercalate notes }

def Answer.toJson (a : Answer) : Json :=
  Json.mkObj [("log", a.log), ("path", a.path), ("found", a.found), ("bytes", a.bytes),
    ("modifiedUnix", a.modifiedUnix), ("modified", isoUtc a.modifiedUnix), ("matched", a.matched), ("returned", a.lines.size),
    ("partialRead", a.partialRead), ("note", a.note), ("lines", Json.arr (a.lines.map Json.str))]

def Answer.toText (a : Answer) : String :=
  let head := if !a.found then s!"{a.log}: {a.path} — {a.note}"
    else s!"{a.log}: {a.path} ({a.bytes} bytes, modified {isoUtc a.modifiedUnix}); {a.lines.size} of {a.matched} matching lines" ++
      (if a.note.isEmpty then "" else s!"; {a.note}")
  if a.lines.isEmpty then head else head ++ "\n" ++ "\n".intercalate a.lines.toList

/-- The index: every log this server can show, whether it exists, its size and when it changed. -/
def index : IO Json := do
  let mut rows : Array Json := #[]
  for s in sources do
    let p ← pathOf s
    let (found, size, mod) ← match p with
      | none => pure (false, 0, 0)
      | some path =>
        if ← path.pathExists then
          let m ← path.metadata
          pure (true, m.byteSize.toNat, m.modified.sec.toNat)
        else pure (false, 0, 0)
    rows := rows.push (Json.mkObj [("log", s.name), ("description", s.description),
      ("path", (p.map (·.toString)).getD ""), ("found", found), ("bytes", size), ("modifiedUnix", mod)])
  return Json.mkObj [("logs", Json.arr rows)]

def indexText (j : Json) : String :=
  let rows := ((j.getObjValD "logs").getArr?).toOption.getD #[]
  let line (r : Json) : String :=
    let f (k : String) := (r.getObjValAs? String k).toOption.getD ""
    let n (k : String) := (r.getObjValAs? Nat k).toOption.getD 0
    let found := (r.getObjValAs? Bool "found").toOption.getD false
    s!"{f "log"}: {f "path"} " ++ (if found then s!"({n "bytes"} bytes, modified {isoUtc (n "modifiedUnix")})" else "(not found)") ++
      s!" — {f "description"}"
  "Logs this server can show (pass one as log):\n" ++ "\n".intercalate (rows.toList.map line)

/-- The most of a log session_conform reads by name. -/
def logArgsBytes : Nat := 64 * 1024 * 1024

/-- session_conform's `serverLog` (selfhost.session.event-log): the arguments with it replaced by `log`,
the text of that log as server_logs names it, the whole file up to `logArgsBytes` (beyond that its
end, with a first line the window cut dropped, so no event line is read half). Only where server_logs is served; other arguments pass. -/
def logArgs (args : Json) : IO (Except String Json) := do
  let .obj kvs := args | return .ok args
  let some v := kvs.get? "serverLog" | return .ok args
  unless ← enabled.get do return .error ("serverLog " ++ disabledMessage)
  let .str name := v | return .error s!"serverLog is the name of a log: one of {", ".intercalate names}"
  if kvs.contains "log" || kvs.contains "events" then return .error "give serverLog, log or events, not two of them"
  let some src := sources.find? (·.name == name)
    | return .error s!"serverLog must be one of {", ".intercalate names}"
  let some path ← pathOf src | return .error s!"the {name} log is not on this machine"
  unless ← path.pathExists do return .error s!"the {name} log does not exist yet ({path})"
  -- by line ranges through the log's index (selfhost.session.log-paging): only appended bytes are
  -- read to update it, and a window is read from the nearest kept offset
  let nat (k : String) : Except String (Option Nat) := match kvs.get? k with
    | none => .ok none
    | some v => match v.getNat? with
      | .ok n => .ok (some n)
      | .error _ => .error s!"{k} is a whole number"
  let (fromLine, count, lastLines) ← match nat "fromLine", nat "lineCount", nat "lastLines" with
    | .ok a, .ok b, .ok c => pure (a, b, c)
    | .error e, _, _ | _, .error e, _ | _, _, .error e => return .error e
  if lastLines.isSome && (fromLine.isSome || count.isSome) then
    return .error "give lastLines, or fromLine and lineCount, not both"
  if fromLine == some 0 then return .error "fromLine counts from 1"
  if [count, lastLines].any (·.any fun c => c == 0 || c > 100000) then
    return .error "lineCount and lastLines are from 1 to 100000"
  let (fp, ix) ← LogIndex.refresh path
  let total := ix.lines
  let (first, last) := match lastLines with
    | some n => (total - min n total + 1, total)
    | none => let f := fromLine.getD 1; (f, match count with | some c => f + c - 1 | none => total)
  let (lines, next) ← LogIndex.window path ix first last
  let window := Json.mkObj [("fromLine", toJson first), ("nextLine", toJson (max next first)),
    ("logLines", toJson total), ("logFingerprint", Json.str fp)]
  let kvs := ((kvs.erase "serverLog").erase "fromLine" |>.erase "lineCount").erase "lastLines"
  return .ok (Json.obj kvs |>.setObjVal! "log" (Json.str ("\n".intercalate lines.toList))
    |>.setObjVal! "logWindow" window)

/-- The arguments {log?, lines?, grep?}: without log, the index; with it, the end of that log. -/
def query (args : Json) : IO (Except String (String × Json)) := do
  unless ← enabled.get do return .error disabledMessage
  match args.getObjVal? "log" with
  | .error _ =>
    let j ← index
    return .ok (indexText j, j)
  | .ok logJson =>
    let .ok name := logJson.getStr? | return .error "log must be a string"
    let some s := sources.find? (·.name == name)
      | return .error s!"log must be one of {", ".intercalate names}"
    let count ← match args.getObjVal? "lines" with
      | .error _ => pure defaultLines
      | .ok v => match v.getNat? with
        | .ok n =>
          if n == 0 || n > maxLines then return .error s!"lines must be between 1 and {maxLines}"
          pure n
        | .error _ => return .error "lines must be a whole number"
    let grep ← match args.getObjVal? "grep" with
      | .error _ => pure none
      | .ok v => match v.getStr? with
        | .ok g =>
          if g.length > maxGrep then return .error s!"grep may be at most {maxGrep} characters"
          pure (if g.isEmpty then none else some g)
        | .error _ => return .error "grep must be a string"
    let a ← read s count grep
    return .ok (a.toText, a.toJson)

/-! ## HTTP: GET /tools/logs?log=NAME&lines=N&grep=TEXT -/

def hexVal (c : Char) : Option Nat :=
  if c.isDigit then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

partial def percentDecode (s : String) : String :=
  let rec go : List Char → List UInt8 → List UInt8
    | [], acc => acc.reverse
    | '+' :: rest, acc => go rest (32 :: acc)
    | '%' :: a :: b :: rest, acc => match hexVal a, hexVal b with
      | some x, some y => go rest ((x * 16 + y).toUInt8 :: acc)
      | _, _ => go (a :: b :: rest) ('%'.toNat.toUInt8 :: acc)
    | c :: rest, acc => go rest ((String.singleton c).toUTF8.toList.reverse ++ acc)
  decodeLossy (ByteArray.mk (go s.toList []).toArray)

/-- The query string of a request target, as the tool's arguments. -/
def argsOfTarget (target : String) : Json := Id.run do
  let query := match target.splitOn "?" with
    | _ :: q :: _ => q
    | _ => ""
  let mut fields : List (String × Json) := []
  for pair in query.splitOn "&" do
    match pair.splitOn "=" with
    | k :: v :: _ =>
      let k := percentDecode k
      let v := percentDecode v
      if k == "lines" then
        fields := (k, match v.toNat? with | some n => Json.num n | none => Json.str v) :: fields
      else if k == "log" || k == "grep" then
        fields := (k, Json.str v) :: fields
    | _ => pure ()
  return Json.mkObj fields

/-- Status, content type and body for GET /tools/logs. Plain text unless format=json is asked for. -/
def httpAnswer (target : String) : IO (Nat × String × String) := do
  let json := (target.splitOn "format=json").length > 1
  match ← query (argsOfTarget target) with
  | .error why => return (400, "text/plain; charset=utf-8", why ++ "\n")
  | .ok (text, j) =>
    if json then return (200, "application/json; charset=utf-8", j.compress ++ "\n")
    return (200, "text/plain; charset=utf-8", text ++ "\n")

/-- GET /tools/logs?log=NAME with a Range header of lines (selfhost.session.log-paging): status,
content type, headers and body. 206 with the lines, each redacted as the 200 answers are; 416 when
the range starts after the last line or is not one this reads. -/
def rangeAnswer (target header : String) : IO (Nat × String × List String × String) := do
  unless ← enabled.get do return (403, "text/plain; charset=utf-8", [], disabledMessage ++ "\n")
  let args := argsOfTarget target
  let some name := (args.getObjValAs? String "log").toOption
    | return (400, "text/plain; charset=utf-8", [], "a range needs log=NAME\n")
  let some src := sources.find? (·.name == name)
    | return (400, "text/plain; charset=utf-8", [], s!"log must be one of {", ".intercalate names}\n")
  let some path ← pathOf src | return (404, "text/plain; charset=utf-8", [], s!"the {name} log is not on this machine\n")
  unless ← path.pathExists do return (404, "text/plain; charset=utf-8", [], s!"the {name} log does not exist yet\n")
  let (fp, ix) ← LogIndex.refresh path
  let tag := "ETag: \"" ++ fp ++ "\""
  let unsatisfiable := (416, "text/plain; charset=utf-8",
    [s!"Content-Range: lines */{ix.lines}", "Accept-Ranges: lines", tag], "")
  let .ok r := LogIndex.parseRange header | return unsatisfiable
  let some (first, last) := LogIndex.resolve r ix.lines | return unsatisfiable
  let (lines, next) ← LogIndex.window path ix first last
  if lines.isEmpty then return unsatisfiable
  let body := String.join (lines.toList.map fun l => redactLine l ++ "\n")
  return (206, "text/plain; charset=utf-8",
    [s!"Content-Range: lines {first}-{next - 1}/{ix.lines}", "Accept-Ranges: lines", tag], body)

end LeanFM.ServerLogs
