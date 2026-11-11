# Generative settlement example

Pass DepositSettlement.leanfm as the `lean` argument of `session_check` or
`session_simulate`. Inline probabilities and time distributions are illustrative
assumptions. This example covers direct address receipt and settlement only,
not the full legal chapter or jurisdiction-specific calendar arithmetic.

To replace selected assumptions without editing the protocol, pass the contents
of DepositSettlement.overlay.json as the `overlay` argument. Replacement is
explicit and keyed by choice name or message id (unique labels also work).
Returned `generative.annotations` identifies the effective layer and origin;
the interactive editor retains it for subsequent checks and simulations.

`session_simulate` accepts a seed and instance count and returns ordinary events
with session-relative millisecond times plus separate `deadlineReports`.
`session_conform` accepts those events unchanged, or actual logs with `timeMs`
(or `time`) on every event. Its optional `horizonMs` advances an incomplete
capture's observation boundary. An unmet obligation is pending exactly at the
deadline and violated after it; satisfaction at the deadline is inclusive.

Structural conformance and CTL use the erased global type. Neither a deadline
violation nor zero sampling probability deletes a path. A breach record is
monitor output, never an invented message.

Execution supports finite sequential choices, bounded to 4096 expanded paths.
Annotated concurrency, recursion, sessions blocks and includes require explicit
scheduling semantics and are rejected for generation/monitoring. Plain,
unannotated protocols retain their previous simulator. An unweighted choice
in a generative protocol requires a probability layer before simulation.

Durable requirements: selfhost.session.generative, .execution, .monitor in
LeanFM/LLMGenerated/SelfHosting.lean. Implementation mappings:
LeanFM/LLMGenerated/SessionImplementation.lean. Regression and negative evidence:
LeanFM/Session/GenerativeTests.lean and LeanFM/MCPTests.lean.

Call `session_mdp` with the same `lean` and optional `overlay` to render the
decision process natively through MCP. The result includes SVG, shared drawing
shapes, terminal outcomes, `terminalProbability` (checked to equal "1") and
`violationProbability` (any obligation violated, each terminal counted once).
The MCP Apps editor also has an **MDP diagram** button. Unknown weights or
graphs exceeding 96 nodes fail explicitly. This is a finite tree under the
supplied policy, not an optimal-policy solver.
