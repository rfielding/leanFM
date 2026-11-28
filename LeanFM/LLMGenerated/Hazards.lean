/-! # LeanFM's hazards (clause selfhost.hazards)

A hazard is named before it is fixed. Each one says what can go wrong, the never it would violate,
the control in the implementation that eliminates or bounds it, and the negative test that shows the
control works. An open hazard has no control yet: it is recorded, not hidden. -/

namespace LeanFM.LLMGenerated.Hazards

structure Hazard where
  id : String
  hazard : String
  never : String
  control : String := ""
  test : String := ""
  status : String
  deriving Repr

def hazards : List Hazard :=
  [ { id := "reduce.runaway", status := "mitigated"
      hazard := "a reduce_run program loops or recurses without end"
      never := "a program runs past its tick budget"
      control := "Reduce.eval charges one tick per step against tickBudget (1000000, or LEANFM_REDUCE_TICKS read at startup; no client argument raises it)"
      test := "LeanFM/ReduceTests.lean: a shallow recursion that doubles its work 40 times is refused naming the tick budget" }
  , { id := "reduce.stack", status := "mitigated"
      hazard := "deep recursion in a program exhausts the server's native stack and kills the process"
      never := "a program nests more than maxDepth (10000) calls"
      control := "Reduce.eval tracks call depth and refuses past maxDepth, below what the server's stack holds"
      test := "LeanFM/ReduceTests.lean: recursion 20000 deep is refused naming the depth bound, under the tick budget" }
  , { id := "reduce.bignum", status := "mitigated"
      hazard := "a few ticks of repeated squaring build a number of millions of bits, using memory and time far beyond the ticks"
      never := "a program holds a number whose numerator or denominator exceeds maxBits (4096) bits"
      control := "every arithmetic result is checked against maxBits before it is kept"
      test := "LeanFM/ReduceTests.lean: squaring 2 thirteen times is refused naming the bit bound" }
  , { id := "reduce.divide-by-zero", status := "mitigated"
      hazard := "a division by zero yields a meaningless number that a chart or requirement then uses"
      never := "a division by zero answered as a number"
      control := "arithmetic is exact rationals; / refuses a zero divisor naming the expression; zero? tests for it"
      test := "LeanFM/ReduceTests.lean: (/ 1 0) is refused; (zero? (- 1/3 1/3)) is true" }
  , { id := "reduce.code-execution", status := "mitigated"
      hazard := "a submitted program reaches the file system, the network, the clock or the Lean runtime"
      never := "submitted logic runs as code (required proof Submitted logic never runs as code)"
      control := "Reduce is an interpreter over its own value type: names resolve only to a fixed primitive list, the program's defines and parameters; there is no eval, no IO and no string-to-code"
      test := "LeanFM/ReduceTests.lean: an unknown name (such as readFile or eval) is refused before it runs; proved for every program: LeanFM.ReduceProofs.submitted_programs_closed; ProofCheck's purity walk: nothing Logic.run or Reduce.check can reach takes a way out of purity" }
  , { id := "reduce.input-size", status := "mitigated"
      hazard := "a run too large to hold is sent or named"
      never := "a run over reduceEvents events, or arguments over argumentBytes, is read"
      control := "CallLimits reduceEvents and argumentBytes; serverLog reads a bounded window"
      test := "LeanFM/ReduceTests.lean: a run over reduceEvents is refused naming the limit" }
  , { id := "reduce.output-size", status := "mitigated"
      hazard := "a chart with millions of points makes an answer too large to send or draw"
      never := "a chart over maxPoints (2000) points drawn whole"
      control := "a chart keeps the first maxPoints points and says how many it cut"
      test := "LeanFM/ReduceTests.lean: an xy chart of 3000 points keeps 2000 and reports 1000 cut" }
  , { id := "path.escape", status := "mitigated"
      hazard := "a file argument, a log name or a symlink reaches outside a project root"
      never := "the server reads a file outside the project root it was asked about"
      control := "ProjectView.inside, ServerLogs.pathOf and ProjectRoots resolve real paths and check they are below the root"
      test := "LeanFM/MCPTests.lean: a conform log /etc/passwd outside the root is failing; scripts/external_project_check.py: a symlink out of the root is not read; proved for every path: LeanFM.PathProofs.paths_stay_inside" }
  , { id := "connections.exhaustion", status := "mitigated"
      hazard := "clients hold open connections until the server runs out of file handles"
      never := "more than LEANFM_MAX_CONNECTIONS connections are open at once"
      control := "the HTTP server caps open connections and closes idle ones (LEANFM_KEEPALIVE_SECONDS, LEANFM_KEEPALIVE_REQUESTS)"
      test := "scripts/keepalive_check.py: with LEANFM_MAX_CONNECTIONS 2 a third connection waits" }
  , { id := "request.size", status := "mitigated"
      hazard := "a request body large enough to exhaust memory"
      never := "a body over requestBytes is read"
      control := "the body is sized before it is read; LeanFM-Limits raises it per request up to the operator's ceiling"
      test := "scripts/header_limits_check.py: a body over 256 KiB is refused with 413" }
  , { id := "disk.exhaustion", status := "mitigated"
      hazard := "a LeanFM server writes to disk as it serves, until the disk is full"
      never := "a LeanFM process fills the disk while serving"
      control := "the MCP surface is read-only (selfhost.mcp.readonly) and the servers write their event lines to standard output, never to a file; the chat UI, off by default, is the only writer, of its own store"
      test := "scripts/mcp_run_log.py: a server serving a whole viewer conversation and 40 more requests leaves git status of the checkout unchanged; checked over the built code: nothing MCP.dispatchWith can reach writes (ProofCheck readonly walk, McpNeverWrites)" }
  , { id := "logs.retention", status := "open"
      hazard := "log files kept outside LeanFM (make serve's output where an operator tees it, a project's logs/events.log) grow without bound; LeanFM reads them in bounded windows but does not rotate them"
      never := "a log LeanFM's tools read fills the disk" }
  , { id := "files.handles", status := "mitigated"
      hazard := "many concurrent reads of logs and protocol files exhaust file handles"
      never := "a request fails because the process ran out of file handles"
      control := "LEANFM_MAX_CONNECTIONS caps the requests served at once, and each request reads its files one at a time, closing each before the next"
      test := "scripts/mcp_run_log.py: 40 requests that read the disk leave the server holding at most 4 more files than before them" } ]

def statuses : List String := ["mitigated", "open"]

/-- Problems with the registry: a mitigated hazard without a control or a test, an unknown status,
a duplicate id. -/
def errors : List String :=
  let ids := hazards.map (·.id)
  (hazards.filterMap fun h =>
    if !statuses.contains h.status then some s!"{h.id}: status {h.status} is not mitigated or open"
    else if h.status == "mitigated" && (h.control.isEmpty || h.test.isEmpty) then some s!"{h.id}: mitigated needs a control and a test"
    else if h.hazard.isEmpty || h.never.isEmpty then some s!"{h.id}: a hazard says what can go wrong and the never it violates"
    else none) ++
  (ids.eraseDups.filterMap fun i => if (ids.filter (· == i)).length > 1 then some s!"{i} is listed twice" else none)

def openHazards : List Hazard := hazards.filter (·.status == "open")

end LeanFM.LLMGenerated.Hazards
