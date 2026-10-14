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
  let called ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"validate_generated_artifacts\",\"arguments\":{}}}"
  assertContains "MCP validation tool returns checked reports" called.body "generated implementation plan"
  let unknown ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"no/such/method\"}"
  assertContains "MCP rejects unknown methods" unknown.body "-32601"
