import LeanFM.MCP

open Lean
open LeanFM.MCP

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
    let wants := logicViewTools.contains name
    if wants && uri != some logicViewUri then throw <| IO.userError s!"MCP view: {name} lacks the view"
    if !wants && uri.isSome then throw <| IO.userError s!"MCP view: {name} should not declare a view"
  IO.println "ok: MCP view is declared on exactly the logic tools it draws"
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
