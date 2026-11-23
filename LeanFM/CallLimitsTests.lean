import LeanFM.CallLimits
import LeanFM.SessionTools
import LeanFM.MCPHost

/-! Per-call limits (selfhost.mcp.limits) and startup checks of the environment (selfhost.env.startup). -/

namespace LeanFM.CallLimitsTests
open Lean LeanFM LeanFM.CallLimits

def args (s : String) : Json := (Json.parse s).toOption.getD Json.null
def refused (r : Except String α) (part : String) : Bool := match r with
  | .error e => (e.splitOn part).length > 1
  | .ok _ => false
def has (s part : String) : Bool := (s.splitOn part).length > 1

-- absent, and the defaults
#guard (validate (args "{}") 100).toOption.map (·.length) == some 0
#guard (validate (args "{\"limits\": null}") 100).toOption.map (·.length) == some 0
#guard get (args "{}") "states" == 20000
#guard get (args "{\"limits\": {\"states\": 40000}}") "states" == 40000
-- raised, lowered, and capped at the operator's ceiling (default times the factor)
#guard (validate (args "{\"limits\": {\"states\": 40000}}") 100).toOption.map (·.map (·.applied)) == some [40000]
#guard (validate (args "{\"limits\": {\"states\": 5}}") 100).toOption.map (·.map (·.applied)) == some [5]
#guard (validate (args "{\"limits\": {\"states\": 999999999}}") 100).toOption.map (·.map (·.applied)) == some [2000000]
#guard (validate (args "{\"limits\": {\"states\": 999999999}}") 2).toOption.map (·.map (·.applied)) == some [40000]
#guard has (warning [{ name := "states", requested := 999999999, applied := 40000 }]) "capped at the operator's ceiling"
-- the rewritten arguments carry only applied values
#guard get (rewrite (args "{\"limits\": {\"states\": 999999999}}") ((validate (args "{\"limits\": {\"states\": 999999999}}") 2).toOption.getD [])) "states" == 40000
-- negative: malformed limits are refused, naming the known limits
#guard refused (validate (args "{\"limits\": {\"stats\": 5}}") 100) "unknown limit stats; the limits are states (20000)"
#guard refused (validate (args "{\"limits\": {\"states\": 0}}") 100) "at least 1"
#guard refused (validate (args "{\"limits\": {\"states\": \"lots\"}}") 100) "at least 1"
#guard refused (validate (args "{\"limits\": {\"states\": -3}}") 100) "at least 1"
#guard refused (validate (args "{\"limits\": [1]}") 100) "must be an object"
-- the startup checks: LEANFM_LIMIT_CEILING and the switches
#guard (parseCeiling none).toOption == some 100
#guard (parseCeiling (some " 7 ")).toOption == some 7
#guard refused (parseCeiling (some "0")) "LEANFM_LIMIT_CEILING"
#guard refused (parseCeiling (some "lots")) "LEANFM_LIMIT_CEILING"
#guard (MCPHost.parseSwitch "LEANFM_MCP_LOGS" false (some "TRUE") |>.toOption) == some true
#guard (MCPHost.parseSwitch "LEANFM_MCP_LOGS" false none).toOption == some false
#guard refused (MCPHost.parseSwitch "LEANFM_MCP_LOGS" false (some "yes")) "LEANFM_MCP_LOGS must be 0, 1, true or false"

/-! Each registered limit, reached and named with the argument that raises it -/

def images := "protocol Images (Browser, Server) {
  g: GetImage from Browser to Server;
  choice {
    Image from Server to Browser cause g;
  } or {
    NotFound from Server to Browser cause g;
  }
}"
def call (extra : String) : Json := args ("{\"lean\": " ++ (Json.str images).compress ++ extra ++ "}")
def answer (r : Except String Json) : String := match r with | .ok j => j.compress | .error e => e

-- states: session_ctl, its suggestions, faithful rules and session_review stop at it and name it
#guard (SessionTools.ctl (call ", \"formula\": {\"AF\": \"terminal\"}")).toOption.isSome
#guard refused (SessionTools.ctl (call ", \"formula\": {\"AF\": \"terminal\"}, \"limits\": {\"states\": 2}")) "\"limits\": {\"states\": 4}"
#guard has (answer (SessionTools.ctl (call ", \"limits\": {\"states\": 2}"))) "the states limit (2)"
#guard refused (SessionTools.ctl (call ", \"faithful\": \"rules\", \"limits\": {\"states\": 2}")) "the states limit (2)"
#guard has (answer (SessionTools.review (call ", \"limits\": {\"states\": 2}"))) "the states limit (2)"
-- formulaNodes
#guard refused (SessionTools.ctl (call ", \"formula\": {\"AG\": {\"EF\": \"terminal\"}}, \"limits\": {\"formulaNodes\": 2}")) "\"formulaNodes\": 4"
-- faithfulRules: the rules are cut and the reading says how to see them all
#guard has (answer (SessionTools.ctl (call ", \"faithful\": \"rules\", \"limits\": {\"faithfulRules\": 1}"))) "the faithfulRules limit (1)"
-- logEvents
#guard refused (SessionTools.conform (call ", \"events\": [{\"id\":\"a\",\"from\":\"Browser\",\"to\":\"Server\",\"label\":\"GetImage\"},{\"id\":\"b\",\"from\":\"Server\",\"to\":\"Browser\",\"label\":\"Image\",\"cause\":\"a\"}], \"limits\": {\"logEvents\": 1}")) "the logEvents limit (1)"
-- datasetSessions and datasetEvents
#guard refused (SessionTools.dataset (call ", \"sessions\": 10, \"limits\": {\"datasetSessions\": 5}")) "the datasetSessions limit (5)"
#guard refused (SessionTools.dataset (call ", \"sessions\": 10, \"limits\": {\"datasetEvents\": 3}")) "the datasetEvents limit (3)"
#guard (SessionTools.dataset (call ", \"sessions\": 10")).toOption.isSome
-- check_ctl's own limits
def draft := "{\"task\": {\"id\": \"d\", \"states\": [\"a\", \"b\"], \"initial\": \"a\", \"terminals\": [\"b\"], \"transitions\": [{\"src\": \"a\", \"dst\": \"b\", \"message\": \"m\"}]}, \"formula\": {\"AF\": \"terminal\"}"
#guard match Logic.run "check_ctl" (args (draft ++ "}")) with | some (.ok _) => true | _ => false
#guard match Logic.run "check_ctl" (args (draft ++ ", \"limits\": {\"draftStates\": 1}}")) with | some r => refused r "the draftStates limit (1)" | none => false
#guard match Logic.run "check_ctl" (args (draft ++ ", \"limits\": {\"ctlFormulaNodes\": 1}}")) with | some r => refused r "the ctlFormulaNodes limit (1)" | none => false
#guard match Logic.run "check_ctl" (args (draft ++ ", \"limits\": {\"draftTransitions\": 0}}")) with | some (.ok _) => true | _ => false

end LeanFM.CallLimitsTests
