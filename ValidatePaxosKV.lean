import LeanFM.PaxosKV.Requirements
import LeanFM.PaxosKV.Implementation

example : LeanFM.PaxosKV.Requirements.scenarioOrderWellFormed
    LeanFM.PaxosKV.Requirements.quorumWriteExample := by native_decide

-- Empty priorIds marks minimal events; several minimal events are valid and
-- remain unordered rather than acquiring order from their list position.
example : LeanFM.PaxosKV.Requirements.scenarioOrderWellFormed
    [ LeanFM.PaxosKV.Requirements.exampleEvent "first-a" [] "browser-a" "web-0" "ListRequest"
        [("session", "browser-a"), ("request_id", "list-a")]
    , LeanFM.PaxosKV.Requirements.exampleEvent "first-b" [] "browser-b" "web-0" "ListRequest"
        [("session", "browser-b"), ("request_id", "list-b")]
    ] := by native_decide

#eval IO.print LeanFM.PaxosKV.Requirements.validationReport
#eval IO.print LeanFM.PaxosKV.Implementation.validationReport
