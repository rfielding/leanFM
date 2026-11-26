import LeanFM.MCPHost
import LeanFM.KeepAlive
import LeanFM.ChatUI.HttpRequest
import Std.Async.TCP
import Std.Async.Timer

/-! leanfm-mcp: the MCP endpoint alone, for remote hosting (clause selfhost.mcp.hosting) over HTTP,
or with --stdio for a client that starts it as a child process (clause selfhost.mcp.stdio).
HTTP configuration comes from the environment; see deploy/mcp/README.md.

  leanfm-mcp                         HTTP on LEANFM_MCP_BIND:LEANFM_MCP_PORT (default 127.0.0.1:8090)
  leanfm-mcp --stdio [--root DIR]    MCP on standard input and output; DIR is the LeanFM checkout
                                     whose book and specifications the resources read
  server_logs is served with --stdio, and over HTTP only when LEANFM_MCP_LOGS=1 -/

open Std
open Std.Net
open LeanFM.MCPHost

namespace LeanFM.McpServer

abbrev TcpServer := Std.Async.TCP.Socket.Server
abbrev TcpClient := Std.Async.TCP.Socket.Client

/-- One request from the bytes already received and the connection: the request and the bytes after
its frame, which begin the next request (selfhost.mcp.keepalive). `none` when the connection closed
or stayed idle past `idleMs` before any byte of a request arrived; once a request has begun it has
15 seconds to complete. -/
def readRequest (client : TcpClient) (pending : ByteArray) (idleMs : Nat) :
    IO (Except (Nat × String) (Option (String × ByteArray))) := do
  let start ← IO.monoMsNow
  let mut bytes := pending
  let mut deadline := if pending.isEmpty then start + idleMs else start + 15000
  repeat
    match LeanFM.ChatUI.HttpRequest.frameLength? bytes with
    | .error failure => return .error failure
    | .ok (some expected) =>
        if expected > maxBodyBytes + 32768 then return .error (413, "the request exceeds the size limit")
        if bytes.size ≥ expected then
          return match String.fromUTF8? (bytes.extract 0 expected) with
            | some text => .ok (some (text, bytes.extract expected bytes.size))
            | none => .error (400, "the request is not valid UTF-8")
    | .ok none => pure ()
    let now ← IO.monoMsNow
    if now >= deadline then
      return if bytes.isEmpty then .ok none else .error (408, "the request did not complete within 15 seconds")
    let received ← (do
      let timer ← Std.Async.Selector.sleep (Std.Time.Millisecond.Offset.ofNat (deadline - now))
      Std.Async.Selectable.one #[
        .case (client.recvSelector 65536) (fun chunk => pure (some chunk)),
        .case timer (fun _ => pure none)]).block
    match received with
    | none => return if bytes.isEmpty then .ok none else .error (408, "the request did not complete within 15 seconds")
    | some none => return if bytes.isEmpty then .ok none else .error (400, "the request ended early")
    | some (some chunk) =>
        if chunk.isEmpty then return if bytes.isEmpty then .ok none else .error (400, "the request ended early")
        if bytes.isEmpty then deadline := (← IO.monoMsNow) + 15000
        bytes := bytes ++ chunk
  return .error (400, "incomplete request")

def peerOf (client : TcpClient) : IO String := do
  try pure (toString (← client.getPeerName).ipAddr) catch _ => pure "unknown"

/-- Serve requests on one connection until it should close (selfhost.mcp.keepalive): the client
asked, the request quota is reached, it stayed idle, or a request could not be read. -/
partial def handleClient (cfg : HostConfig) (limits : Limits) (client : TcpClient) (pending : ByteArray := .empty)
    (served : Nat := 0) : IO Unit := do
  let ka ← LeanFM.KeepAlive.settings.get
  let started ← IO.monoMsNow
  let peer ← peerOf client
  match ← readRequest client pending (ka.idleSeconds * 1000) with
  | .ok none => return
  | .error (status, detail) =>
      let r : Req := { method := "?", path := "?" }
      let res := plain status "bad_request" detail
      (client.sendAll #[render res false]).block
      IO.println (logLine r res ((← IO.monoMsNow) - started))
      (← IO.getStdout).flush
  | .ok (some (text, rest)) =>
      let (req, res, keep) ← match parseRequest text peer with
        | none =>
            let r : Req := { method := "?", path := "?" }
            pure (r, plain 400 "bad_request" "malformed request line", false)
        | some r =>
            let res ← try handle cfg limits r (← IO.monoMsNow)
              catch err =>
                IO.eprintln s!"internal error: {err}"
                pure (plain 500 "internal_error" "internal server error")
            pure (r, res, !LeanFM.KeepAlive.wantsClose r.headers && served + 1 < ka.requests)
      (client.sendAll #[render res keep]).block
      IO.println (logLine req res ((← IO.monoMsNow) - started))
      (← IO.getStdout).flush
      if keep then handleClient cfg limits client rest (served + 1)

partial def serveLoop (cfg : HostConfig) (limits : Limits) (server : TcpServer) : IO Unit := do
  let client ← (server.accept).block
  let _ ← IO.asTask (do
    if ← LeanFM.KeepAlive.tryOpen then
      try handleClient cfg limits client
      catch err => IO.eprintln s!"connection failed: {err}"
      LeanFM.KeepAlive.close
    else
      try (client.sendAll #[render (plain 503 "busy" "too many open connections") false]).block
      catch _ => pure ()) Task.Priority.dedicated
  serveLoop cfg limits server

/-- One message per line until standard input ends. Standard output carries only replies. -/
partial def stdioLoop (stdin stdout stderr : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then
    -- Claude Desktop copies standard error into mcp-server-leanfm.log, so the reason is on record
    stderr.putStrLn "leanfm-mcp: standard input ended, exiting"
    stderr.flush
    return
  let reply ← try stdioReply line
    catch err =>
      stderr.putStrLn s!"internal error: {err}"
      pure (some (LeanFM.MCP.rpcError Lean.Json.null (-32603) "internal error").body)
  if let some out := reply then
    stdout.putStr (out ++ "\n")
    stdout.flush
  stdioLoop stdin stdout stderr

def usage : String :=
  "usage: leanfm-mcp [--stdio [--root DIR | --forward http://127.0.0.1:PORT/mcp]]\n" ++
  "  without --stdio it serves MCP over HTTP, configured by LEANFM_MCP_* (see deploy/mcp/README.md)"

/-- The command line: --stdio and --root DIR, each at most once; anything else is refused. -/
def parseArgs : List String -> Except String (Bool × Option String)
  | [] => .ok (false, none)
  | "--stdio" :: rest => do
      let (s, r) <- parseArgs rest
      if s then throw "--stdio given twice" else pure (true, r)
  | "--root" :: dir :: rest => do
      let (s, r) <- parseArgs rest
      if r.isSome then throw "--root given twice" else pure (s, some dir)
  | other :: _ => .error s!"unknown argument {other}"

/-! ## Forwarding (clause selfhost.mcp.forward)

`leanfm-mcp --stdio --forward http://127.0.0.1:8080/mcp` relays each line to a running HTTP server
and its answer back, so a client that can only start a command (Claude Desktop, Codex) shares the
one server, and a rebuild needs only that server restarted. -/

/-- `--forward URL` taken out of the arguments, at most once. -/
def splitForward : List String → Except String (Option String × List String)
  | [] => .ok (none, [])
  | "--forward" :: url :: rest => do
      let (f, r) ← splitForward rest
      if f.isSome then throw "--forward given twice" else pure (some url, r)
  | ["--forward"] => .error "--forward needs a URL"
  | x :: rest => do let (f, r) ← splitForward rest; pure (f, x :: r)

structure Forward where
  port : Nat
  path : String
  hostHeader : String

/-- Only plain HTTP on this machine: 127.0.0.1 or localhost, a port, and a path. -/
def parseForward (url : String) : Except String Forward := do
  let bad := s!"--forward takes an http URL on 127.0.0.1 or localhost, such as http://127.0.0.1:8080/mcp, not {url}"
  unless url.startsWith "http://" do throw bad
  let rest := (url.drop 7).toString
  let (hostPort, path) := match rest.splitOn "/" with
    | hp :: ps => (hp, "/" ++ "/".intercalate ps)
    | [] => (rest, "/")
  match hostPort.splitOn ":" with
  | [host, port] =>
    unless host == "127.0.0.1" || host == "localhost" do throw bad
    let some p := port.toNat? | throw bad
    if p == 0 || p > 65535 then throw bad
    return { port := p, path, hostHeader := hostPort }
  | _ => throw bad

/-- One HTTP answer by its Content-Length: status and body. -/
def readAnswer (client : TcpClient) : IO (Except String (Nat × String)) := do
  let mut raw := ByteArray.empty
  let mut headEnd := none
  repeat
    if headEnd.isNone then
      headEnd := LeanFM.ChatUI.HttpRequest.headerEnd? raw
    if let some e := headEnd then
      let head := (String.fromUTF8? (raw.extract 0 e)).getD ""
      let lines := head.splitOn "\r\n"
      let status := (((lines.headD "").splitOn " ")[1]?.bind String.toNat?).getD 0
      let len := (lines.findSome? fun l =>
        match l.splitOn ":" with
        | k :: v :: _ => if k.trimAscii.toString.toLower == "content-length" then v.trimAscii.toString.toNat? else none
        | _ => none).getD 0
      if raw.size ≥ e + len then
        return .ok (status, (String.fromUTF8? (raw.extract e (e + len))).getD "")
    match ← (client.recv? 65536).block with
    | some chunk =>
      if chunk.isEmpty then return .error "the server closed the connection"
      raw := raw ++ chunk
    | none => return .error "the server closed the connection"
  return .error "incomplete answer"

def connectTo (fw : Forward) : IO TcpClient := do
  let client ← Std.Async.TCP.Socket.Client.mk
  (client.connect (SocketAddress.v4 { addr := IPv4Addr.ofParts 127 0 0 1, port := UInt16.ofNat fw.port })).block
  return client

/-- Post one message over the kept connection, opening a new one when it is missing or the server
closed it (tried once more). -/
def post (fw : Forward) (conn : IO.Ref (Option TcpClient)) (body : String) : IO (Except String (Nat × String)) := do
  let bytes := body.toUTF8
  let req := s!"POST {fw.path} HTTP/1.1\r\nHost: {fw.hostHeader}\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: {bytes.size}\r\n\r\n".toUTF8 ++ bytes
  let attempt (client : TcpClient) : IO (Except String (Nat × String)) := do
    try
      (client.sendAll #[req]).block
      readAnswer client
    catch e => pure (.error (toString e))
  if let some client := ← conn.get then
    if let .ok r := ← attempt client then return .ok r
  conn.set none
  let client ← try pure (some (← connectTo fw)) catch _ => pure none
  match client with
  | none => return .error "unreachable"
  | some c =>
    conn.set (some c)
    let r ← attempt c
    if r matches .error _ then conn.set none
    return r

partial def forwardLoop (fw : Forward) (url : String) (conn : IO.Ref (Option TcpClient))
    (stdin stdout stderr : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then
    stderr.putStrLn "leanfm-mcp: standard input ended, exiting"; stderr.flush
    return
  let body := line.trimAscii.toString
  if !body.isEmpty then
    let id := match Lean.Json.parse body with
      | .ok j => (j.getObjVal? "id").toOption
      | .error _ => none
    let fail (msg : String) : IO Unit := do
      if let some i := id then
        stdout.putStr ((LeanFM.MCP.rpcError i (-32000) msg).body ++ "\n"); stdout.flush
      stderr.putStrLn s!"leanfm-mcp --forward: {msg}"; stderr.flush
    match ← post fw conn body with
    | .ok (200, answer) =>
      let one := match Lean.Json.parse answer with
        | .ok j => j.compress
        | .error _ => answer.replace "\n" " "
      stdout.putStr (one ++ "\n"); stdout.flush
    | .ok (202, _) => pure ()
    | .ok (status, answer) => fail s!"the server at {url} answered {status}: {(answer.take 200).toString}"
    | .error "unreachable" => fail s!"nothing is listening at {url}; start it with make serve"
    | .error e => fail s!"the server at {url} failed: {e}"
  forwardLoop fw url conn stdin stdout stderr

def serveForward (url : String) : IO UInt32 := do
  let fw ← match parseForward url with
    | .ok f => pure f
    | .error e => IO.eprintln e; return 2
  let stderr ← IO.getStderr
  stderr.putStrLn s!"leanfm-mcp relaying standard input and output to {url}"; stderr.flush
  let conn ← IO.mkRef (none : Option TcpClient)
  forwardLoop fw url conn (← IO.getStdin) (← IO.getStdout) stderr
  return 0

def serveStdio (root : Option String) : IO UInt32 := do
  let stderr ← IO.getStderr
  if let some dir := root then
    unless ← System.FilePath.isDir dir do
      stderr.putStrLn s!"--root {dir} is not a directory"
      return 2
    IO.Process.setCurrentDir dir
  -- a child process of the user's own client may read the user's own logs (LeanFM/ServerLogs.lean)
  LeanFM.ServerLogs.enable
  LeanFM.ServerInfo.capture
  stderr.putStrLn s!"leanfm-mcp on standard input and output; resources read from {← IO.currentDir}"
  stderr.flush
  stdioLoop (← IO.getStdin) (← IO.getStdout) stderr
  return 0

def serveHttp : IO Unit := do
  let cfg ← HostConfig.fromEnv
  let some addr := IPv4Addr.ofString cfg.bind
    | throw <| IO.userError s!"LEANFM_MCP_BIND must be an IPv4 address, not {cfg.bind}"
  let limits ← Limits.new
  -- logs stay private on a hosted endpoint unless its operator opts in
  if ← envSwitch "LEANFM_MCP_LOGS" false then LeanFM.ServerLogs.enable
  LeanFM.ServerInfo.capture
  let server ← Std.Async.TCP.Socket.Server.mk
  server.bind (SocketAddress.v4 { addr, port := UInt16.ofNat cfg.port })
  server.listen 128
  IO.println s!"leanfm-mcp listening on http://{cfg.bind}:{cfg.port}/mcp origins={",".intercalate cfg.origins} token={if cfg.token.isSome then "required" else "none"} rate={cfg.ratePerMinute}/min burst={cfg.burst} inflight={cfg.maxInflight}"
  (← IO.getStdout).flush
  serveLoop cfg limits server

def main (args : List String) : IO UInt32 := do
  -- every environment variable is checked before serving, so a bad one stops the server now, not
  -- later in its logs (selfhost.env.startup); HTTP's own variables are checked by HostConfig.fromEnv
  try LeanFM.CallLimits.configureFromEnv; LeanFM.ModelCache.configureFromEnv; LeanFM.KeepAlive.configureFromEnv catch e =>
    IO.eprintln s!"leanfm-mcp: {e}"
    return 2
  let (forward, args) ← match splitForward args with
    | .ok r => pure r
    | .error why => IO.eprintln s!"{why}\n{usage}"; return 2
  match parseArgs args with
  | .error why =>
      IO.eprintln s!"{why}\n{usage}"
      return 2
  | .ok (true, root) => match forward with
    | some url => serveForward url
    | none => serveStdio root
  | .ok (false, root) =>
    if forward.isSome then
      IO.eprintln s!"--forward needs --stdio\n{usage}"
      return 2
    if root.isSome then
      IO.eprintln s!"--root needs --stdio\n{usage}"
      return 2
    serveHttp
    return 0

end LeanFM.McpServer

def main (args : List String) : IO UInt32 :=
  LeanFM.McpServer.main args
