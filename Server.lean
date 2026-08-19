import LeanFM
import Std.Internal.Async.TCP

open Std
open Std.Net

namespace LeanFM.Server

abbrev TcpServer := Std.Internal.IO.Async.TCP.Socket.Server
abbrev TcpClient := Std.Internal.IO.Async.TCP.Socket.Client

def bindAddr : SocketAddress :=
  SocketAddress.v4
    { addr := IPv4Addr.ofParts 127 0 0 1
    , port := 8080
    }

def requestPath (request : String) : String :=
  match request.splitOn "\r\n" with
  | firstLine :: _ =>
      match firstLine.splitOn " " with
      | _method :: path :: _ =>
          match path.splitOn "?" with
          | clean :: _ => clean
          | _ => path
      | _ => "/"
  | _ => "/"

def responseBody (path : String) : IO (Nat × String × ByteArray) := do
  match path with
  | "/" => pure (200, "text/html; charset=utf-8", LeanFM.htmlPage.toUTF8)
  | "/diagrams/" => pure (200, "text/html; charset=utf-8", LeanFM.htmlPage.toUTF8)
  | "/metrics" => pure (200, "text/plain; charset=utf-8", LeanFM.textReport.toUTF8)
  | "/graph.dot" => pure (200, "text/vnd.graphviz; charset=utf-8", LeanFM.graphDot.toUTF8)
  | "/auth.dot" => pure (200, "text/vnd.graphviz; charset=utf-8", LeanFM.authGraphDot.toUTF8)
  | "/assembled.dot" => pure (200, "text/vnd.graphviz; charset=utf-8", LeanFM.assembledGraphDot.toUTF8)
  | "/diagrams/auth.svg" => pure (200, "image/svg+xml; charset=utf-8", (← IO.FS.readFile "diagrams/auth.svg").toUTF8)
  | "/diagrams/worker.svg" => pure (200, "image/svg+xml; charset=utf-8", (← IO.FS.readFile "diagrams/worker.svg").toUTF8)
  | "/diagrams/assembled.svg" => pure (200, "image/svg+xml; charset=utf-8", (← IO.FS.readFile "diagrams/assembled.svg").toUTF8)
  | "/diagrams/auth.png" => pure (200, "image/png", ← IO.FS.readBinFile "diagrams/auth.png")
  | "/diagrams/worker.png" => pure (200, "image/png", ← IO.FS.readBinFile "diagrams/worker.png")
  | "/diagrams/assembled.png" => pure (200, "image/png", ← IO.FS.readBinFile "diagrams/assembled.png")
  | "/health" => pure (200, "text/plain; charset=utf-8", "ok\n".toUTF8)
  | _ => pure (404, "text/plain; charset=utf-8", "not found\n".toUTF8)

def statusText : Nat -> String
  | 200 => "OK"
  | 404 => "Not Found"
  | _ => "OK"

def httpHeader (status : Nat) (contentType : String) (body : ByteArray) : String :=
  "HTTP/1.1 " ++ toString status ++ " " ++ statusText status ++ "\r\n" ++
  "Content-Type: " ++ contentType ++ "\r\n" ++
  "Content-Length: " ++ toString body.size ++ "\r\n" ++
  "Cache-Control: no-store\r\n" ++
  "X-Content-Type-Options: nosniff\r\n" ++
  "Connection: close\r\n\r\n"

def writeDiagram (name dot : String) : IO Unit := do
  IO.FS.createDirAll "diagrams"
  let dotPath := s!"diagrams/{name}.dot"
  let svgPath := s!"diagrams/{name}.svg"
  let pngPath := s!"diagrams/{name}.png"
  IO.FS.writeFile dotPath dot
  let svgChild ← IO.Process.output
    { cmd := "dot"
    , args := #["-Tsvg", dotPath, "-o", svgPath]
    }
  let pngChild ← IO.Process.output
    { cmd := "dot"
    , args := #["-Tpng", dotPath, "-o", pngPath]
    }
  if svgChild.exitCode != 0 || pngChild.exitCode != 0 then
    throw <| IO.userError s!"dot failed for {dotPath}: {svgChild.stderr}{pngChild.stderr}"

def writeDiagrams : IO Unit := do
  writeDiagram "auth" LeanFM.authGraphDot
  writeDiagram "worker" LeanFM.graphDot
  writeDiagram "assembled" LeanFM.assembledGraphDot

def handleClient (client : TcpClient) : IO Unit := do
  let requestBytes? ← (client.recv? 4096).block
  let request :=
    match requestBytes? with
    | some bytes => String.fromUTF8! bytes
    | none => ""
  let (status, contentType, body) ← responseBody (requestPath request)
  (client.sendAll #[(httpHeader status contentType body).toUTF8, body]).block

partial def serveLoop (server : TcpServer) : IO Unit := do
  let client ← (server.accept).block
  try
    handleClient client
  catch err =>
    IO.eprintln s!"request failed: {err}"
  serveLoop server

def main : IO Unit := do
  writeDiagrams
  let server ← Std.Internal.IO.Async.TCP.Socket.Server.mk
  server.bind bindAddr
  server.listen 128
  IO.println "LeanFM server listening on http://127.0.0.1:8080"
  serveLoop server

end LeanFM.Server

def main : IO Unit :=
  LeanFM.Server.main
