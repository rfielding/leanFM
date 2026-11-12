import LeanFM.CheckMetrics

/-! Tests for selfhost.mcp.metrics (decision mcp-check-metrics). -/
namespace LeanFM.CheckMetricsTests
open Lean LeanFM.CheckMetrics

def listed := ["check_protocol", "session_sla"]

def answer (verdict : String) (more : List (String × Json) := []) : Except String Json :=
  .ok (Json.mkObj [("structuredContent", Json.mkObj ([("verdict", Json.str verdict)] ++ more))])

def has (s sub : String) : Bool := (s.splitOn sub).length > 1

-- labels come from fixed sets: an unlisted tool is other, an unknown verdict is other, a failure is rejected
#guard has (({} : Stats).record listed "drop_tables" (answer "met") 1000).render "leanfm_check_calls_total{tool=\"other\",verdict=\"met\"} 1"
#guard has (({} : Stats).record listed "session_sla" (answer "pwned; rm -rf /") 1000).render "leanfm_check_calls_total{tool=\"session_sla\",verdict=\"other\"} 1"
#guard has (({} : Stats).record listed "session_sla" (.error "no such role Mallory_secr") 1000).render "verdict=\"rejected\"} 1"
#guard !has (({} : Stats).record listed "session_sla" (.error "no such role Mallory_secr") 1000).render "Mallory"

-- histograms are cumulative and end at +Inf with _sum and _count
def twice : Stats := (({} : Stats).record listed "session_sla" (answer "met") 5000000).record listed "session_sla" (answer "met") 2000000000
#guard has twice.render "leanfm_check_duration_seconds_bucket{tool=\"session_sla\",verdict=\"met\",le=\"0.01\"} 1"
#guard has twice.render "leanfm_check_duration_seconds_bucket{tool=\"session_sla\",verdict=\"met\",le=\"10\"} 2"
#guard has twice.render "leanfm_check_duration_seconds_bucket{tool=\"session_sla\",verdict=\"met\",le=\"+Inf\"} 2"
#guard has twice.render "leanfm_check_duration_seconds_count{tool=\"session_sla\",verdict=\"met\"} 2"

-- model sizes, bound hits and secrets
def proto : Stats :=
  (({} : Stats).record listed "check_protocol" (answer "leaked" [("states", toJson 250), ("transitions", toJson 900),
    ("secrets", Json.arr #[Json.mkObj [("term", "passwd_secr")], Json.mkObj [("term", "h(passwd_secr)")]]),
    ("roles", Json.arr #["Zorblax"]), ("formula", "never knows(Ivo, passwd_secr)")]) 1000).record listed "check_protocol" (answer "resource-limit") 1000
#guard has proto.render "leanfm_check_states_explored_bucket{tool=\"check_protocol\",verdict=\"leaked\",le=\"1000\"} 1"
#guard has proto.render "leanfm_check_states_explored_bucket{tool=\"check_protocol\",verdict=\"leaked\",le=\"100\"} 0"
#guard has proto.render "leanfm_check_transitions_explored_sum{tool=\"check_protocol\",verdict=\"leaked\"} 900"
#guard has proto.render "leanfm_check_bound_hits_total{tool=\"check_protocol\",bound=\"model-size\"} 1"
#guard has proto.render "leanfm_check_secrets_checked_bucket{tool=\"check_protocol\",le=\"2\"} 1"
-- never: a secret's name, a term, a role or the formula in the metrics
#guard !has proto.render "passwd" && !has proto.render "Zorblax" && !has proto.render "Ivo" && !has proto.render "knows"

-- every line is a comment or name{labels} value
def wellFormed (line : String) : Bool :=
  line.isEmpty || line.startsWith "# HELP leanfm_" || line.startsWith "# TYPE leanfm_" ||
  (line.startsWith "leanfm_check_" && has line "{" && has line "} " &&
    ((line.splitOn "} ").getLast?.getD "x").all (fun c => c.isDigit || c == '.' || c == 'e' || c == '-'))
#guard ((proto.record listed "session_sla" (answer "met") 7).render.splitOn "\n").all wellFormed

end LeanFM.CheckMetricsTests
