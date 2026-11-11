import LeanFM.MCP
open Lean LeanFM.MCP

def main : IO Unit := do
  let source ← IO.FS.readFile "exports/nested-splits/Nested.leanfm"
  let request := Json.mkObj [("jsonrpc","2.0"),("id",1),("method","tools/call"),
    ("params",Json.mkObj [("name","session_mdp"),("arguments",Json.mkObj [("lean",source)])])]
  let response ← dispatch request.compress
  let json ← IO.ofExcept (Json.parse response.body)
  let result := json.getObjValD "result"
  if (result.getObjValAs? Bool "isError").toOption == some true then
    throw (IO.userError result.pretty)
  let body := result.getObjValD "structuredContent"
  let terminals ← IO.ofExcept (body.getObjValAs? (Array Json) "terminals")
  let masses := terminals.toList.map (fun t => t.getObjValD "probability")
  if masses != [Json.str "1/2", Json.str "1/4", Json.str "1/20", Json.str "1/5"] then
    throw (IO.userError s!"incorrect nested terminal masses: {masses}")
  if body.getObjValD "terminalProbability" != Json.str "1" then
    throw (IO.userError "terminal total is not one")
  IO.FS.writeFile "exports/nested-splits/result.json" result.pretty
  IO.FS.writeFile "exports/nested-splits/diagram.svg" (← IO.ofExcept (body.getObjValAs? String "svg"))
  IO.println "Checked nested terminal masses: 1/2, 1/4, 1/20, 1/5; total = 1."
