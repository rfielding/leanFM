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
  let deferred ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"knows\",\"arguments\":{}}}"
  assertContains "MCP knows is honestly unsupported" deferred.body "\"verdict\":\"unsupported\""
