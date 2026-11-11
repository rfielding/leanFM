import LeanFM.MCP
open Lean LeanFM.MCP

def main : IO Unit := do
  let source ← IO.FS.readFile "examples/sessions/DepositSettlement.leanfm"
  let request := Json.mkObj [("jsonrpc","2.0"),("id",1),("method","tools/call"),
    ("params",Json.mkObj [("name","session_mdp"),("arguments",Json.mkObj [("lean",source)])])]
  let response ← dispatch request.compress
  let json ← IO.ofExcept (Json.parse response.body)
  let result := json.getObjValD "result"
  if (result.getObjValAs? Bool "isError").toOption == some true then
    throw (IO.userError result.pretty)
  IO.FS.writeFile "exports/settlement-probability/native-mcp.json" result.pretty
  let svg ← IO.ofExcept (result.getObjValD "structuredContent" |>.getObjValAs? String "svg")
  IO.FS.writeFile "exports/settlement-probability/native-mcp.svg" svg
