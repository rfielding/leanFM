import Lean
import Std.Data.HashMap
import LeanFM.MCP

/-! The hosted MCP endpoint (clause selfhost.mcp.hosting, decision mcp-hosting).

Everything here is a function of a parsed request, so it is tested without a socket
(LeanFM/MCPTests.lean). `McpServer.lean` is the executable that reads requests from TCP. The host
links LeanFM.MCP and nothing from the chat UI server, so no chat, LLM, session or file route can be
reached through it. -/

namespace LeanFM.MCPHost
open Lean

/-- Supported values of the Mcp-Protocol-Version header. -/
def protocolVersions : List String := ["2025-03-26", "2025-06-18", "2025-11-25"]

def maxBodyBytes : Nat := 262144
/-- The Claude directory's 25,000-token limit on a tool result, at about four characters a token. -/
def resultCharLimit : Nat := 100000
/-- Path steps kept when a reply is still too large after dropping per-step knowledge. -/
def keptPathSteps : Nat := 64

structure HostConfig where
  bind : String := "127.0.0.1"
  port : Nat := 8090
  origins : List String := ["https://claude.ai", "https://claude.com"]
  token : Option String := none
  ratePerMinute : Nat := 60
  burst : Nat := 20
  maxInflight : Nat := 4
  trustProxy : Bool := false
  deriving Repr

private def envNat (name : String) (default : Nat) : IO Nat := do
  match ← IO.getEnv name with
  | none => pure default
  | some raw => match raw.trimAscii.toString.toNat? with
    | some n => pure n
    | none => throw <| IO.userError s!"{name} must be a decimal number"

def normalizeOrigin (o : String) : String :=
  let t := o.trimAscii.toString
  if t.endsWith "/" then (t.dropEnd 1).toString else t

def HostConfig.fromEnv : IO HostConfig := do
  let d : HostConfig := {}
  let bind := ((← IO.getEnv "LEANFM_MCP_BIND").map (·.trimAscii.toString)).getD d.bind
  let port ← envNat "LEANFM_MCP_PORT" d.port
  if port == 0 || port > 65535 then throw <| IO.userError "LEANFM_MCP_PORT must be between 1 and 65535"
  let origins := match ← IO.getEnv "LEANFM_MCP_ORIGINS" with
    | some raw => ((raw.splitOn ",").map normalizeOrigin).filter (!·.isEmpty)
    | none => d.origins
  if origins.contains "*" then throw <| IO.userError "LEANFM_MCP_ORIGINS may not contain *: list the origins"
  let token := match ← IO.getEnv "LEANFM_MCP_TOKEN" with
    | some t => if t.trimAscii.toString.isEmpty then none else some t.trimAscii.toString
    | none => none
  let rate ← envNat "LEANFM_MCP_RATE" d.ratePerMinute
  let burst ← envNat "LEANFM_MCP_BURST" d.burst
  let inflight ← envNat "LEANFM_MCP_MAX_INFLIGHT" d.maxInflight
  if rate == 0 || burst == 0 || inflight == 0 then
    throw <| IO.userError "LEANFM_MCP_RATE, LEANFM_MCP_BURST and LEANFM_MCP_MAX_INFLIGHT must be positive"
  let trust := ((← IO.getEnv "LEANFM_MCP_TRUST_PROXY").map (fun v => v.trimAscii.toString == "1" || v.trimAscii.toString == "true")).getD false
  pure { bind, port, origins, token, ratePerMinute := rate, burst, maxInflight := inflight, trustProxy := trust }

/-- A request as the host sees it. Header names are matched without regard to case. -/
structure Req where
  method : String
  path : String
  headers : List (String × String) := []
  body : String := ""
  /-- The socket peer address, or the first X-Forwarded-For address behind a trusted proxy. -/
  peer : String := "unknown"

structure Resp where
  status : Nat
  contentType : String := "application/json"
  body : String := ""
  headers : List (String × String) := []
  /-- The JSON-RPC method and tool name, for the log line only. -/
  rpcMethod : String := ""
  tool : String := ""
  deriving Inhabited

def Req.header? (r : Req) (name : String) : Option String :=
  (r.headers.find? (fun (k, _) => k.toLower == name.toLower)).map (·.2.trimAscii.toString)

/-- The key a client is rate limited by. -/
def clientKey (cfg : HostConfig) (r : Req) : String :=
  if cfg.trustProxy then
    match r.header? "X-Forwarded-For" with
    | some v => match (v.splitOn ",").head? with
      | some first => if first.trimAscii.toString.isEmpty then r.peer else first.trimAscii.toString
      | none => r.peer
    | none => r.peer
  else r.peer

def originAllowed (cfg : HostConfig) : Option String → Bool
  | none => true
  | some o => cfg.origins.contains (normalizeOrigin o)

def corsHeaders (cfg : HostConfig) (r : Req) : List (String × String) :=
  match r.header? "Origin" with
  | some o =>
    if originAllowed cfg (some o) then
      [("Access-Control-Allow-Origin", normalizeOrigin o), ("Vary", "Origin"),
       ("Access-Control-Allow-Methods", "POST, OPTIONS"),
       ("Access-Control-Allow-Headers", "Content-Type, Accept, Authorization, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-ID"),
       ("Access-Control-Expose-Headers", "Mcp-Session-Id"),
       ("Access-Control-Max-Age", "600")]
    else []
  | none => []

def baseHeaders : List (String × String) :=
  [("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]

def errorBody (code message : String) : String :=
  (Json.mkObj [("error", Json.str message), ("code", Json.str code)]).compress

def plain (status : Nat) (code message : String) (extra : List (String × String) := []) : Resp :=
  { status, body := errorBody code message, headers := extra }

/-- Equal strings, compared without stopping at the first difference. -/
def constantTimeEq (a b : String) : Bool :=
  let xs := a.toUTF8.toList
  let ys := b.toUTF8.toList
  let diff := (xs.zip ys).foldl (fun acc (x, y) => acc ||| (x ^^^ y)) (0 : UInt8)
  xs.length == ys.length && diff == 0

def acceptsJson (accept : Option String) : Bool :=
  match accept with
  | none => true
  | some a =>
    let types := (a.splitOn ",").map (fun t => ((t.splitOn ";").headD "").trimAscii.toString.toLower)
    types.any (fun t => t == "application/json" || t == "*/*" || t == "application/*")

def isJsonContentType (ct : Option String) : Bool :=
  match ct with
  | some c => ((c.splitOn ";").headD "").trimAscii.toString.toLower == "application/json"
  | none => false

/-- Answers decided before dispatch, in the order the decision lists them. `none` means dispatch. -/
def gate (cfg : HostConfig) (r : Req) : Option Resp :=
  if r.path == "/healthz" then
    if r.method == "GET" then some { status := 200, contentType := "text/plain", body := "ok\n" }
    else some (plain 405 "method_not_allowed" "GET only" [("Allow", "GET")])
  else if r.path != "/mcp" then some (plain 404 "not_found" "only /mcp and /healthz are served")
  else if !originAllowed cfg (r.header? "Origin") then
    some (plain 403 "origin_forbidden" "this origin is not allowed")
  else if r.method == "OPTIONS" then some { status := 204, contentType := "", body := "" }
  else if r.method != "POST" then
    some (plain 405 "method_not_allowed" "this server sends no event stream; use POST" [("Allow", "POST, OPTIONS")])
  else if r.body.utf8ByteSize > maxBodyBytes then
    some (plain 413 "body_too_large" s!"the request body exceeds {maxBodyBytes} bytes")
  else if (match cfg.token with
      | some t => match r.header? "Authorization" with
        | some auth => !(auth.startsWith "Bearer " && constantTimeEq ((auth.drop 7).toString.trimAscii.toString) t)
        | none => true
      | none => false) then
    some (plain 401 "unauthorized" "a bearer token is required" [("WWW-Authenticate", "Bearer realm=\"leanfm\"")])
  else if !isJsonContentType (r.header? "Content-Type") then
    some (plain 415 "unsupported_media_type" "Content-Type must be application/json")
  else if !acceptsJson (r.header? "Accept") then
    some (plain 406 "not_acceptable" "this server answers application/json")
  else match r.header? "Mcp-Protocol-Version" with
    | some v => if protocolVersions.contains v then none
      else some (plain 400 "unsupported_protocol_version" s!"supported: {", ".intercalate protocolVersions}")
    | none => none

/-! ## Reply compaction -/

private def mapPath (reply : Json) (f : Array Json → Array Json) (note : String) : Json :=
  let result := reply.getObjValD "result"
  let sc := result.getObjValD "structuredContent"
  match (sc.getObjValD "evidence").getObjValD "path" |>.getArr? with
  | .ok path =>
    let ev := (sc.getObjValD "evidence").setObjVal! "path" (Json.arr (f path))
    let prior := (sc.getObjValAs? String "note").toOption.getD ""
    let sc := (sc.setObjVal! "evidence" ev).setObjVal! "note" (if prior.isEmpty then note else prior ++ "; " ++ note)
    reply.setObjVal! "result" (result.setObjVal! "structuredContent" sc)
  | .error _ => reply

def dropHolds (reply : Json) : Json :=
  mapPath reply (·.map (fun step => match step with
    | .obj kvs => Json.obj (kvs.erase "holds")
    | other => other))
    "per-step knowledge omitted to fit the 25,000-token result limit"

def keepLastSteps (reply : Json) : Json :=
  mapPath reply (fun path => path.extract (path.size - min path.size keptPathSteps) path.size)
    s!"only the last {keptPathSteps} path steps are included to fit the 25,000-token result limit"

/-- Keep a reply within `limit` characters: drop per-step knowledge, then early path steps, and
otherwise replace it with an error that names the limit. -/
def compactReply (body : String) (limit : Nat := resultCharLimit) : String :=
  if body.length ≤ limit then body else
  match Json.parse body with
  | .error _ => body
  | .ok reply =>
    let a := (dropHolds reply).compress
    if a.length ≤ limit then a else
    let b := (keepLastSteps (dropHolds reply)).compress
    if b.length ≤ limit then b else
    (Json.mkObj [("jsonrpc", "2.0"), ("id", reply.getObjValD "id"),
      ("error", Json.mkObj [("code", (-32000 : Int)),
        ("message", Json.str s!"the result exceeds the {limit}-character (25,000-token) limit; ask a narrower question")])]).compress

/-! ## Rate and concurrency -/

structure Limits where
  buckets : IO.Ref (Std.HashMap String (Nat × Nat))
  inflight : IO.Ref Nat

def Limits.new : IO Limits := do
  pure { buckets := ← IO.mkRef {}, inflight := ← IO.mkRef 0 }

/-- Take one request from the client's token bucket; `none` when allowed, else seconds to wait. -/
def Limits.take (l : Limits) (cfg : HostConfig) (key : String) (nowMs : Nat) : IO (Option Nat) :=
  l.buckets.modifyGet fun table =>
    let table := if table.size > 10000 then {} else table
    let capacity := cfg.burst * 60000
    let (tokens, last) := table.getD key (capacity, nowMs)
    let refilled := min capacity (tokens + (nowMs - last) * cfg.ratePerMinute)
    if refilled ≥ 60000 then (none, table.insert key (refilled - 60000, nowMs))
    else
      let waitMs := (60000 - refilled + cfg.ratePerMinute - 1) / cfg.ratePerMinute
      (some ((waitMs + 999) / 1000), table.insert key (refilled, nowMs))

def Limits.enter (l : Limits) (cfg : HostConfig) : IO Bool :=
  l.inflight.modifyGet fun n => if n < cfg.maxInflight then (true, n + 1) else (false, n)

def Limits.leave (l : Limits) : IO Unit :=
  l.inflight.modify (fun n => n - 1)

/-! ## The handler -/

def handle (cfg : HostConfig) (limits : Limits) (r : Req) (nowMs : Nat) : IO Resp := do
  let cors := corsHeaders cfg r
  let finish (res : Resp) : Resp := { res with headers := baseHeaders ++ cors ++ res.headers }
  if let some early := gate cfg r then return finish early
  if let some wait ← limits.take cfg (clientKey cfg r) nowMs then
    return finish (plain 429 "rate_limited" "too many requests" [("Retry-After", toString wait)])
  let parsed := Json.parse r.body
  let message := parsed.toOption.getD Json.null
  let rpcMethod := (message.getObjValAs? String "method").toOption.getD ""
  let tool := if rpcMethod == "tools/call" then
      ((message.getObjValD "params").getObjValAs? String "name").toOption.getD "" else ""
  let isToolCall := rpcMethod == "tools/call"
  if isToolCall then
    unless ← limits.enter cfg do
      return finish { (plain 503 "busy" "too many tool calls are running; retry shortly" [("Retry-After", "1")]) with rpcMethod, tool }
  let reply ← try LeanFM.MCP.dispatch r.body
    finally if isToolCall then limits.leave
  let hasId := match message with
    | .obj kvs => kvs.contains "id"
    | _ => true
  -- a notification, or a response the client sends, is acknowledged without a body
  if parsed.isOk && !hasId then
    return finish { status := 202, contentType := "", body := "", rpcMethod, tool }
  let body := if reply.status == 200 then compactReply reply.body else reply.body
  return finish { status := reply.status, body, rpcMethod, tool }

/-- One log line: never a body, an argument, a token or a client address. -/
def logLine (r : Req) (res : Resp) (ms : Nat) : String :=
  s!"{r.method} {r.path} rpc={if res.rpcMethod.isEmpty then "-" else res.rpcMethod} tool={if res.tool.isEmpty then "-" else res.tool} status={res.status} ms={ms}"

/-! ## HTTP framing -/

def parseRequest (text : String) (peer : String) : Option Req := do
  let headEnd ← (text.splitOn "\r\n\r\n").head?
  let body := (text.drop (headEnd.length + 4)).toString
  let lines := headEnd.splitOn "\r\n"
  let first ← lines.head?
  match first.splitOn " " with
  | method :: target :: _ =>
    let path := (target.splitOn "?").headD target
    let headers := (lines.drop 1).filterMap fun l =>
      match l.splitOn ":" with
      | k :: rest => some (k.trimAscii.toString, (":".intercalate rest).trimAscii.toString)
      | [] => none
    pure { method, path, headers, body, peer }
  | _ => none

def reasonPhrase : Nat → String
  | 200 => "OK" | 202 => "Accepted" | 204 => "No Content" | 400 => "Bad Request"
  | 401 => "Unauthorized" | 403 => "Forbidden" | 404 => "Not Found" | 405 => "Method Not Allowed"
  | 406 => "Not Acceptable" | 408 => "Request Timeout" | 413 => "Content Too Large"
  | 415 => "Unsupported Media Type" | 429 => "Too Many Requests" | 431 => "Request Header Fields Too Large"
  | 500 => "Internal Server Error" | 503 => "Service Unavailable" | _ => "Status"

def render (res : Resp) : ByteArray :=
  let body := res.body.toUTF8
  let ct := if res.contentType.isEmpty then [] else [("Content-Type", res.contentType ++ (if res.contentType.startsWith "text/" || res.contentType == "application/json" then "; charset=utf-8" else ""))]
  let headers := ct ++ [("Content-Length", toString body.size), ("Connection", "close")] ++ res.headers
  let head := s!"HTTP/1.1 {res.status} {reasonPhrase res.status}\r\n" ++
    String.join (headers.map (fun (k, v) => s!"{k}: {v}\r\n")) ++ "\r\n"
  head.toUTF8 ++ body

end LeanFM.MCPHost
