import LeanFM.MCPHost
import LeanFM.ChatUI.HttpRequest
import Std.Async.TCP
import Std.Async.Timer

/-! leanfm-mcp: the MCP endpoint alone, for remote hosting (clause selfhost.mcp.hosting).
Configuration comes from the environment; see deploy/mcp/README.md. -/

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

def main : IO Unit := do
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

end LeanFM.McpServer

def main : IO Unit :=
  LeanFM.McpServer.main
