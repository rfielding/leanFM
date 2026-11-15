import LeanFM.MCPHost
import LeanFM.ChatUI.HttpRequest
import Std.Async.TCP
import Std.Async.Timer

/-! leanfm-mcp: the MCP endpoint alone, for remote hosting (clause selfhost.mcp.hosting) over HTTP,
or with --stdio for a client that starts it as a child process (clause selfhost.mcp.stdio).
HTTP configuration comes from the environment; see deploy/mcp/README.md.

  leanfm-mcp                         HTTP on LEANFM_MCP_BIND:LEANFM_MCP_PORT (default 127.0.0.1:8090)
  leanfm-mcp --stdio [--root DIR]    MCP on standard input and output; DIR is the LeanFM checkout
                                     whose book and specifications the resources read -/

open Std
open Std.Net
open LeanFM.MCPHost

namespace LeanFM.McpServer

abbrev TcpServer := Std.Async.TCP.Socket.Server
abbrev TcpClient := Std.Async.TCP.Socket.Client

def readRequest (client : TcpClient) : IO (Except (Nat × String) String) := do
  let deadline := (← IO.monoMsNow) + 15000
  let mut bytes := ByteArray.empty
  repeat
    match LeanFM.ChatUI.HttpRequest.frameLength? bytes with
    | .error failure => return .error failure
    | .ok (some expected) =>
        if expected > maxBodyBytes + 32768 then return .error (413, "the request exceeds the size limit")
        if bytes.size ≥ expected then
          return match String.fromUTF8? (bytes.extract 0 expected) with
            | some text => .ok text
            | none => .error (400, "the request is not valid UTF-8")
    | .ok none => pure ()
    let now ← IO.monoMsNow
    if now >= deadline then return .error (408, "the request did not complete within 15 seconds")
    let received ← (do
      let timer ← Std.Async.Selector.sleep (Std.Time.Millisecond.Offset.ofNat (deadline - now))
      Std.Async.Selectable.one #[
        .case (client.recvSelector 65536) (fun chunk => pure (some chunk)),
        .case timer (fun _ => pure none)]).block
    match received with
    | none => return .error (408, "the request did not complete within 15 seconds")
    | some none => return .error (400, "the request ended early")
    | some (some chunk) =>
        if chunk.isEmpty then return .error (400, "the request ended early")
        bytes := bytes ++ chunk
  return .error (400, "incomplete request")

def peerOf (client : TcpClient) : IO String := do
  try pure (toString (← client.getPeerName).ipAddr) catch _ => pure "unknown"

def handleClient (cfg : HostConfig) (limits : Limits) (client : TcpClient) : IO Unit := do
  let started ← IO.monoMsNow
  let peer ← peerOf client
  let (req, res) ← match ← readRequest client with
    | .error (status, detail) =>
        let r : Req := { method := "?", path := "?" }
        pure (r, plain status "bad_request" detail)
    | .ok text => match parseRequest text peer with
      | none =>
          let r : Req := { method := "?", path := "?" }
          pure (r, plain 400 "bad_request" "malformed request line")
      | some r =>
          let res ← try handle cfg limits r (← IO.monoMsNow)
            catch err =>
              IO.eprintln s!"internal error: {err}"
              pure (plain 500 "internal_error" "internal server error")
          pure (r, res)
  (client.sendAll #[render res]).block
  IO.println (logLine req res ((← IO.monoMsNow) - started))
  (← IO.getStdout).flush

partial def serveLoop (cfg : HostConfig) (limits : Limits) (server : TcpServer) : IO Unit := do
  let client ← (server.accept).block
  let _ ← IO.asTask (do
    try handleClient cfg limits client
    catch err => IO.eprintln s!"connection failed: {err}") Task.Priority.dedicated
  serveLoop cfg limits server

/-- One message per line until standard input ends. Standard output carries only replies. -/
partial def stdioLoop (stdin stdout stderr : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return
  let reply ← try stdioReply line
    catch err =>
      stderr.putStrLn s!"internal error: {err}"
      pure (some (LeanFM.MCP.rpcError Lean.Json.null (-32603) "internal error").body)
  if let some out := reply then
    stdout.putStr (out ++ "\n")
    stdout.flush
  stdioLoop stdin stdout stderr

def usage : String :=
  "usage: leanfm-mcp [--stdio [--root DIR]]\n" ++
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

def serveStdio (root : Option String) : IO UInt32 := do
  let stderr ← IO.getStderr
  if let some dir := root then
    unless ← System.FilePath.isDir dir do
      stderr.putStrLn s!"--root {dir} is not a directory"
      return 2
    IO.Process.setCurrentDir dir
  stderr.putStrLn s!"leanfm-mcp on standard input and output; resources read from {← IO.currentDir}"
  stderr.flush
  stdioLoop (← IO.getStdin) (← IO.getStdout) stderr
  return 0

def serveHttp : IO Unit := do
  let cfg ← HostConfig.fromEnv
  let some addr := IPv4Addr.ofString cfg.bind
    | throw <| IO.userError s!"LEANFM_MCP_BIND must be an IPv4 address, not {cfg.bind}"
  let limits ← Limits.new
  let server ← Std.Async.TCP.Socket.Server.mk
  server.bind (SocketAddress.v4 { addr, port := UInt16.ofNat cfg.port })
  server.listen 128
  IO.println s!"leanfm-mcp listening on http://{cfg.bind}:{cfg.port}/mcp origins={",".intercalate cfg.origins} token={if cfg.token.isSome then "required" else "none"} rate={cfg.ratePerMinute}/min burst={cfg.burst} inflight={cfg.maxInflight}"
  (← IO.getStdout).flush
  serveLoop cfg limits server

def main (args : List String) : IO UInt32 := do
  match parseArgs args with
  | .error why =>
      IO.eprintln s!"{why}\n{usage}"
      return 2
  | .ok (true, root) => serveStdio root
  | .ok (false, some _) =>
      IO.eprintln s!"--root needs --stdio\n{usage}"
      return 2
  | .ok (false, none) =>
      serveHttp
      return 0

end LeanFM.McpServer

def main (args : List String) : IO UInt32 :=
  LeanFM.McpServer.main args
