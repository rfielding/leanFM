import LeanFM.MCP
import LeanFM.MCPHost

open Lean
open LeanFM.MCP
open LeanFM.MCPHost

def assertContains (label haystack needle : String) : IO Unit :=
  if haystack.contains needle then IO.println s!"ok: {label}"
  else throw <| IO.userError s!"{label}: expected {needle}"

def main : IO Unit := do
  let initialized ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  assertContains "MCP initialization supplies durable book instructions" initialized.body "durable agent context"
  assertContains "MCP negotiates a protocol version" initialized.body "2025-06-18"
  let listed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/list\",\"params\":{}}"
  assertContains "MCP lists the central book" listed.body "leanfm://project/book/main.pdf"
  assertContains "MCP lists canonical requirements" listed.body "Requirements.lean"
  let book ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"leanfm://project/book/main.pdf\"}}"
  let .ok json := Json.parse book.body | throw (IO.userError "MCP PDF reply is not JSON")
  let .ok result := json.getObjVal? "result" | throw (IO.userError "MCP PDF resource failed")
  let .ok contents := (result.getObjVal? "contents").bind Json.getArr? | throw (IO.userError "MCP PDF contents missing")
  let some item := contents[0]? | throw (IO.userError "MCP PDF contents empty")
  let .ok blob := (item.getObjVal? "blob").bind Json.getStr? | throw (IO.userError "MCP PDF blob missing")
  let bytes ← IO.FS.readBinFile "book/main.pdf"
  if blob.length != ((bytes.size + 2) / 3) * 4 || !blob.startsWith "JVBER" then
    throw (IO.userError "MCP PDF encoding is incomplete")
  IO.println "ok: MCP reads the complete central PDF without overflowing the stack"
  let called ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"validate_generated_artifacts\",\"arguments\":{}}}"
  assertContains "MCP validation tool returns checked reports" called.body "generated implementation plan"
  let unknown ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"no/such/method\"}"
  assertContains "MCP rejects unknown methods" unknown.body "-32601"
  let toolsListed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\"}"
  assertContains "MCP lists check_ctl with an input schema" toolsListed.body "\"name\":\"check_ctl\""
  assertContains "MCP logic tools require their arguments" toolsListed.body "\"required\":[\"task\",\"formula\"]"
  let reference ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/read\",\"params\":{\"uri\":\"leanfm://language/logic-reference\"}}"
  assertContains "MCP serves the logic reference" reference.body "Terminal convention"
  let ctl ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"check_ctl\",\"arguments\":{\"task\":\"mcp_logic_consult\",\"formula\":{\"never\":{\"after\":\"LogicInputRejected\"}}}}}"
  assertContains "MCP check_ctl passes arguments and returns a verdict" ctl.body "\"verdict\":\"disproved\""
  assertContains "MCP check_ctl returns a counterexample" ctl.body "\"kind\":\"counterexample\""
  let bad ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"check_ctl\",\"arguments\":{\"task\":\"mcp_logic_consult\",\"formula\":{\"G\":\"terminal\"}}}}"
  assertContains "MCP rejects malformed logic as a tool error" bad.body "\"isError\":true"
  assertContains "MCP rejection names the typing error" bad.body "AG (on every path)"
  let known ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"knows\",\"arguments\":{\"actor\":\"Ivo\",\"at\":\"e1\",\"initial\":[{\"sk\":\"I\"}],\"query\":{\"atom\":\"nb\"},\"events\":[{\"id\":\"e1\",\"src\":\"Alice\",\"dst\":\"Ivo\",\"term\":{\"enc\":{\"key\":{\"pk\":\"I\"},\"body\":{\"atom\":\"nb\"}}}}]}}}"
  assertContains "MCP knows decides a query" known.body "\"verdict\":\"proved\""
  assertContains "MCP knows returns the derivation" known.body "\"kind\":\"derivation\""
  assertContains "MCP lists check_protocol" toolsListed.body "\"name\":\"check_protocol\""
  assertContains "MCP lists check_reassembly" toolsListed.body "\"name\":\"check_reassembly\""
  let reasm ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"check_reassembly\",\"arguments\":{\"signature\":\"AB\"}}}"
  assertContains "MCP check_reassembly finds an evasion with defaults" reasm.body "\"verdict\":\"disproved\""
  assertContains "MCP check_reassembly lists the segments" reasm.body "{\"data\":\"AB\",\"offset\":\"0\"}"
  let proto ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"check_protocol\",\"arguments\":{\"roles\":[{\"name\":\"Alice\",\"steps\":[{\"send\":{\"to\":{\"atom\":\"Bob\"},\"message\":{\"atom\":\"secret\"}}}]}],\"attacker\":{\"name\":\"Ivo\"},\"formula\":{\"never\":{\"knows\":{\"actor\":\"Ivo\",\"term\":{\"atom\":\"secret\"}}}}}}}"
  assertContains "MCP check_protocol finds a plaintext leak" proto.body "\"verdict\":\"disproved\""
  assertContains "MCP check_protocol shows the send to its addressee, via the attacker" proto.body "{\"event\":\"send\",\"from\":\"Alice\",\"term\":\"secret\",\"to\":\"Bob\",\"via\":\"Ivo\"}"
  -- The answer appears once, as structuredContent; the text block is a one-line summary, not a copy.
  let summaryOf (label body : String) : IO String := do
    let json ← IO.ofExcept (Json.parse body)
    let block ← IO.ofExcept ((json.getObjValD "result").getObjValD "content" |>.getArrVal? 0)
    let text ← IO.ofExcept (block.getObjValAs? String "text")
    let structured := json.getObjValD "result" |>.getObjValD "structuredContent"
    if structured.isNull then throw <| IO.userError s!"{label}: no structuredContent"
    if text.contains '\n' || text.contains '{' || text.length > LeanFM.MCP.logicSummaryLimit then
      throw <| IO.userError s!"{label}: text block is not a one-line summary: {text}"
    IO.println s!"ok: {label}"
    return text
  let protoText ← summaryOf "MCP check_protocol text is a summary, not a second copy" proto.body
  assertContains "MCP check_protocol summary gives verdict and reading" protoText "check_protocol disproved: on every path, never Ivo can derive secret"
  let badText ← summaryOf "MCP rejection text is a summary" bad.body
  assertContains "MCP rejection summary gives the reason" badText "rejected: "
  let ctlText ← summaryOf "MCP check_ctl text is a summary" ctl.body
  assertContains "MCP check_ctl summary gives the verdict" ctlText "check_ctl disproved"
  -- The MCP Apps view (clause selfhost.mcp.logic.view).
  let toolsJson ← IO.ofExcept (Json.parse toolsListed.body)
  let listedTools ← IO.ofExcept ((toolsJson.getObjValD "result").getObjValD "tools" |>.getArr?)
  for t in listedTools do
    let name ← IO.ofExcept (t.getObjValAs? String "name")
    let uri := ((t.getObjValD "_meta").getObjValD "ui").getObjValAs? String "resourceUri" |>.toOption
    let expected := if logicViewTools.contains name then some logicViewUri
      else if sessionViewTools.contains name then some sessionViewUri else none
    if uri != expected then throw <| IO.userError s!"MCP view: {name} declares {uri}, not {expected}"
  IO.println "ok: MCP views are declared on exactly the tools they draw"
  assertContains "MCP lists the view resource" listed.body logicViewUri
  assertContains "MCP lists the view with the MCP Apps MIME type" listed.body "\"mimeType\":\"text/html;profile=mcp-app\""
  let view ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://leanfm/logic-view\"}}"
  let viewJson ← IO.ofExcept (Json.parse view.body)
  let viewItem ← IO.ofExcept ((viewJson.getObjValD "result").getObjValD "contents" |>.getArrVal? 0)
  let html ← IO.ofExcept (viewItem.getObjValAs? String "text")
  if html != logicViewHtml then throw <| IO.userError "MCP view: resources/read does not return the compiled view"
  let mime ← IO.ofExcept (viewItem.getObjValAs? String "mimeType")
  if mime != logicViewMimeType then throw <| IO.userError s!"MCP view: wrong MIME type {mime}"
  let csp := ((viewItem.getObjValD "_meta").getObjValD "ui").getObjValD "csp"
  for key in ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"] do
    if csp.getObjValD key != Json.arr #[] then throw <| IO.userError s!"MCP view: {key} is not empty"
  IO.println "ok: MCP reads the view with its MIME type and no CSP domains"
  -- Negative requirements: no network, no data as HTML or code, no paths.
  let withoutNamespace := html.replace "http://www.w3.org/2000/svg" ""
  for needle in ["http://", "https://", "src=", "href=", "fetch(", "XMLHttpRequest", "WebSocket", "EventSource",
      "import(", "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function",
      "/home/", "/Users/", "leanfm://"] do
    if withoutNamespace.contains needle then throw <| IO.userError s!"MCP view: forbidden text {needle}"
  IO.println "ok: MCP view has no network access, no HTML or code from data, and no paths"
  assertContains "MCP view speaks the MCP Apps handshake" html "\"ui/initialize\""
  assertContains "MCP view announces it is ready" html "\"ui/notifications/initialized\""
  assertContains "MCP view renders tool results" html "\"ui/notifications/tool-result\""
  assertContains "MCP view reports its size" html "\"ui/notifications/size-changed\""
  assertContains "MCP view bounds the drawing" html "MAX_STEPS = 64, MAX_ITEMS = 256"
  let unknownUi ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://leanfm/other\"}}"
  assertContains "MCP rejects an undeclared ui:// URI" unknownUi.body "unknown resource URI"
  -- Hosts without the extension still get one summary line and the structured answer.
  let protoAgain ← summaryOf "MCP check_protocol result is unchanged by the view" proto.body
  assertContains "MCP check_protocol summary is unchanged" protoAgain "check_protocol disproved"
  -- The session tools and their view (clauses selfhost.mcp.session.tools and .view).
  for t in ["session_check", "session_diagram", "session_simulate", "session_conform"] do
    assertContains s!"MCP lists {t}" toolsListed.body s!"\"name\":\"{t}\""
  assertContains "MCP instructions point to the session tools" initialized.body "session_check"
  assertContains "MCP lists the session reference" listed.body "leanfm://language/session-reference"
  let sref ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"resources/read\",\"params\":{\"uri\":\"leanfm://language/session-reference\"}}"
  assertContains "MCP serves the session reference" sref.body "# LeanFM session types"
  let sess ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"lean\":\"protocol Ping (A, B) { p: Ping from A to B; Pong from B to A cause p status 200; }\"}}}"
  assertContains "MCP session_check reads Lean protocol text through the dispatch" sess.body "\"verdict\":\"ok\""
  assertContains "MCP session_check echoes the Lean text" sess.body "protocol Ping (A, B)"
  let sessText ← summaryOf "MCP session_check text is a one-line summary" sess.body
  assertContains "MCP session_check summary gives the reading" sessText "session_check ok: Ping: no issues"
  let sessBad ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"protocol\":{\"roles\":[\"A\"],\"steps\":[{\"exec\":\"x\"}]}}}}"
  assertContains "MCP session_check rejects an unknown step as a tool error" sessBad.body "\"isError\":true"
  let sim ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"session_simulate\",\"arguments\":{\"seed\":5,\"instances\":3,\"protocol\":{\"roles\":[\"A\",\"B\"],\"steps\":[{\"msg\":\"Ping\",\"id\":\"p\",\"from\":\"A\",\"to\":\"B\"},{\"msg\":\"Pong\",\"from\":\"B\",\"to\":\"A\",\"cause\":\"p\"}]}}}}"
  assertContains "MCP session_simulate runs concurrent copies" sim.body "6 events from 3 sessions"
  assertContains "MCP lists the session view" listed.body sessionViewUri
  let sview ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://leanfm/session-view\"}}"
  let sviewJson ← IO.ofExcept (Json.parse sview.body)
  let sviewItem ← IO.ofExcept ((sviewJson.getObjValD "result").getObjValD "contents" |>.getArrVal? 0)
  let shtml ← IO.ofExcept (sviewItem.getObjValAs? String "text")
  if shtml != sessionViewHtml then throw <| IO.userError "MCP session view: resources/read does not return the compiled view"
  if (sviewItem.getObjValAs? String "mimeType").toOption != some logicViewMimeType then
    throw <| IO.userError "MCP session view: wrong MIME type"
  let scsp := ((sviewItem.getObjValD "_meta").getObjValD "ui").getObjValD "csp"
  for key in ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"] do
    if scsp.getObjValD key != Json.arr #[] then throw <| IO.userError s!"MCP session view: {key} is not empty"
  let sbare := shtml.replace "http://www.w3.org/2000/svg" ""
  for needle in ["http://", "https://", "src=", "href=", "fetch(", "XMLHttpRequest", "WebSocket", "EventSource",
      "import(", "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function",
      "DOMParser", "/home/", "/Users/", "leanfm://"] do
    if sbare.contains needle then throw <| IO.userError s!"MCP session view: forbidden text {needle}"
  IO.println "ok: MCP session view has no network access, no HTML or code from data, and no paths"
  assertContains "MCP session view speaks the MCP Apps handshake" shtml "\"ui/initialize\""
  assertContains "MCP session view renders tool results" shtml "\"ui/notifications/tool-result\""
  assertContains "MCP session view reports its size" shtml "\"ui/notifications/size-changed\""
  assertContains "MCP session view builds SVG elements, not markup" shtml "createElementNS"
  assertContains "MCP session view bounds the drawing" shtml "MAX_SHAPES = 4000, MAX_EVENTS = 600"
  assertContains "MCP session view starts the animation simple" shtml "detail = false"
  let promptsListed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"prompts/list\"}"
  assertContains "MCP offers the session design prompt" promptsListed.body "design_with_session_types"
  let promptGot ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":36,\"method\":\"prompts/get\",\"params\":{\"name\":\"design_with_session_types\"}}"
  assertContains "MCP session design prompt ends at session_conform" promptGot.body "session_conform"
  assertContains "MCP session view edits through tools/call" shtml "\"tools/call\""
  assertContains "MCP session view calls only the session tools, bounded" shtml "const EDIT_TOOLS = [\"session_check\", \"session_simulate\"], MAX_EDIT_BYTES = 65536"
  -- The hosted endpoint (clause selfhost.mcp.hosting).
  let cfg : HostConfig := { burst := 3, ratePerMinute := 60, maxInflight := 1 }
  let limits ← Limits.new
  let ping := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
  let post (hs : List (String × String)) (body : String := ping) (path := "/mcp") (peer := "10.0.0.1") : Req :=
    { method := "POST", path, headers := [("Content-Type", "application/json")] ++ hs, body, peer }
  let hdr (r : Resp) (k : String) : Option String := (r.headers.find? (fun (n, _) => n.toLower == k.toLower)).map (·.2)
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"MCP host: {label}"
  let t := 1000000
  let pre ← handle cfg limits { method := "OPTIONS", path := "/mcp", headers := [("Origin", "https://claude.ai"),
    ("Access-Control-Request-Method", "POST")], peer := "p0" } t
  expect "MCP host answers a preflight from claude.ai" (pre.status == 204 && hdr pre "Access-Control-Allow-Origin" == some "https://claude.ai")
  expect "MCP host allows the MCP request headers" (((hdr pre "Access-Control-Allow-Headers").getD "").contains "Mcp-Protocol-Version" &&
    ((hdr pre "Access-Control-Allow-Headers").getD "").contains "Mcp-Session-Id" && hdr pre "Access-Control-Expose-Headers" == some "Mcp-Session-Id")
  let evil ← handle cfg limits (post [("Origin", "https://evil.example")] (peer := "p1")) t
  expect "MCP host refuses an unlisted origin without CORS headers" (evil.status == 403 && (hdr evil "Access-Control-Allow-Origin").isNone)
  let noOrigin ← handle cfg limits (post [] (peer := "p2")) t
  expect "MCP host serves a server-side client with no Origin" (noOrigin.status == 200 && noOrigin.body.contains "\"result\"")
  let fromClaude ← handle cfg limits (post [("Origin", "https://claude.ai")] (peer := "p3")) t
  expect "MCP host adds CORS headers for claude.ai" (fromClaude.status == 200 && hdr fromClaude "Access-Control-Allow-Origin" == some "https://claude.ai" && hdr fromClaude "Vary" == some "Origin")
  let get ← handle cfg limits { method := "GET", path := "/mcp", peer := "p4" } t
  expect "MCP host answers GET /mcp with 405" (get.status == 405 && hdr get "Allow" == some "POST, OPTIONS")
  for path in ["/api/llm", "/api/session", "/", "/renders/", "/api/projects"] do
    let r ← handle cfg limits (post [] (path := path) (peer := "p5")) t
    expect s!"MCP host does not serve {path}" (r.status == 404)
  let ct ← handle cfg limits { method := "POST", path := "/mcp", headers := [("Content-Type", "text/plain")], body := ping, peer := "p6" } t
  expect "MCP host refuses a non-JSON body" (ct.status == 415)
  let acc ← handle cfg limits (post [("Accept", "text/html")] (peer := "p7")) t
  expect "MCP host refuses an Accept without JSON" (acc.status == 406)
  let streamable ← handle cfg limits (post [("Accept", "application/json, text/event-stream")] (peer := "p7b")) t
  expect "MCP host serves a Streamable HTTP Accept header" (streamable.status == 200)
  let ver ← handle cfg limits (post [("Mcp-Protocol-Version", "1999-01-01")] (peer := "p8")) t
  expect "MCP host refuses an unsupported protocol version" (ver.status == 400)
  let verOk ← handle cfg limits (post [("Mcp-Protocol-Version", "2025-06-18")] (peer := "p8b")) t
  expect "MCP host accepts protocol version 2025-06-18" (verOk.status == 200)
  let big ← handle cfg limits (post [] (body := String.ofList (List.replicate 300000 ' ')) (peer := "p9")) t
  expect "MCP host refuses a body over 256 KiB" (big.status == 413)
  let tcfg : HostConfig := { cfg with token := some "s3cret" }
  let noTok ← handle tcfg limits (post [] (peer := "t1")) t
  let badTok ← handle tcfg limits (post [("Authorization", "Bearer wrong")] (peer := "t2")) t
  let goodTok ← handle tcfg limits (post [("Authorization", "Bearer s3cret")] (peer := "t3")) t
  expect "MCP host requires the configured token" (noTok.status == 401 && badTok.status == 401 && hdr noTok "WWW-Authenticate" == some "Bearer realm=\"leanfm\"" && goodTok.status == 200)
  let note ← handle cfg limits (post [] (body := "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") (peer := "p10")) t
  expect "MCP host acknowledges a notification with 202 and no body" (note.status == 202 && note.body.isEmpty)
  let a ← handle cfg limits (post [] (peer := "burst")) t
  let b ← handle cfg limits (post [] (peer := "burst")) t
  let c ← handle cfg limits (post [] (peer := "burst")) t
  let d ← handle cfg limits (post [] (peer := "burst")) t
  expect "MCP host serves the burst, then rate limits with Retry-After" (a.status == 200 && b.status == 200 && c.status == 200 && d.status == 429 && (hdr d "Retry-After").isSome)
  let later ← handle cfg limits (post [] (peer := "burst")) (t + 1000)
  expect "MCP host refills a client's allowance over time" (later.status == 200)
  limits.inflight.set 1
  let busy ← handle cfg limits (post [] (body := "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"check_reassembly\",\"arguments\":{}}}") (peer := "p11")) t
  limits.inflight.set 0
  expect "MCP host refuses a tool call beyond the in-flight limit" (busy.status == 503 && hdr busy "Retry-After" == some "1")
  let health ← handle cfg limits { method := "GET", path := "/healthz", peer := "p12" } t
  expect "MCP host answers /healthz" (health.status == 200 && health.body == "ok\n")
  -- compaction to the 25,000-token limit
  let step (i : Nat) : Json := Json.mkObj [("state", Json.str s!"s{i}"), ("message", Json.str "m"),
    ("holds", Json.mkObj [("Ivo", Json.arr ((List.range 40).map (fun k => Json.str s!"term-{i}-{k}")).toArray)])]
  let replyWith (n : Nat) : String := (Json.mkObj [("jsonrpc", "2.0"), ("id", (7 : Nat)), ("result", Json.mkObj
    [("structuredContent", Json.mkObj [("verdict", "disproved"), ("evidence", Json.mkObj [("path", Json.arr ((List.range n).map step).toArray)])])])]).compress
  let huge := replyWith 400
  let compacted := compactReply huge 20000
  expect "MCP host compacts an oversized reply below the limit, keeping its verdict" (huge.length > 20000 && compacted.length ≤ 20000 && compacted.contains "\"verdict\":\"disproved\"" && compacted.contains "omitted")
  let irreducible := compactReply huge 200
  expect "MCP host replaces an irreducible reply with error -32000" (irreducible.contains "-32000" && irreducible.length < 400)
  for r in [pre, evil, noOrigin, fromClaude, get, ct, acc, ver, big, noTok, goodTok, note, d, busy, health] do
    if hdr r "Access-Control-Allow-Origin" == some "*" || (hdr r "Access-Control-Allow-Credentials").isSome then
      throw <| IO.userError "MCP host: a response allowed every origin or credentials"
    if hdr r "Cache-Control" != some "no-store" then throw <| IO.userError "MCP host: a response lacks Cache-Control: no-store"
  IO.println "ok: MCP host never allows every origin or credentials, and never caches"
  let line := logLine (post [("Authorization", "Bearer s3cret")] (body := "{\"secret\":1}") (peer := "203.0.113.9")) goodTok 5
  expect "MCP host log line holds no body, token or client address" (!line.contains "s3cret" && !line.contains "secret" && !line.contains "203.0.113.9")
  -- LeanFM's own requirements and mappings are readable resources
  for uri in ["leanfm://project/specification/SelfHosting.lean", "leanfm://project/specification/McpLogicImplementation.lean",
      "leanfm://project/specification/SessionImplementation.lean"] do
    let r ← dispatch ("{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"resources/read\",\"params\":{\"uri\":\"" ++ uri ++ "\"}}")
    assertContains s!"MCP lists {uri}" listed.body uri
    assertContains s!"MCP reads {uri}" r.body "\"contents\""
  assertContains "MCP instructions point at LeanFM's own requirements" initialized.body "SelfHosting.lean"
