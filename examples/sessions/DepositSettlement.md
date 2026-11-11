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

## Amounts and expected balances

PricedDepositSettlement.leanfm is the same protocol with money on it. A message
moves an amount from its sender to its receiver (`amount 1000 USD`, or
`amount sample { 700 USD : 1/2; 400 USD : 1/2; }` when the quantity is uncertain),
and an obligation can name what its actor pays when it is violated
(`on breach record Section2Violated pays 2000 USD to Tenant`). `session_mdp` then
shows each amount on its state, each terminal's net balance per role and unit,
and the exact expected balance per role (here Tenant +2075/2 USD, with 150 USD of
expected penalty). Balances count from the start of the protocol: the Landlord
already holds the deposit. Every terminal's balances sum to zero per unit.
Amounts never change the global type, so projection, conformance and CTL are as
before. Requirement: selfhost.session.amounts.

## Loops, time, rates and trades (the chain view)

A session with `rec`/`continue` or `accrue` is solved as an absorbing Markov chain
(requirements selfhost.session.mdp.loops and .mdp.rewards). Expected visits come
from v = start + vQ, solved exactly; each edge's expected traversals are visits ×
probability, so loops are counted rather than unrolled.

- `after 1 week` (or `after sample { ... }`) is a delay after the previous step.
- `accrue 10 USD per week from Borrower to Lender;` is a rate in force until the
  next accrue for the same payer, payee and unit; `accrue 0` (or none) is grace.
- `amount { 5 apple; 4 orange; -3 USD; }` is a trade vector: positive entries move
  from sender to receiver, negative ones back, so both sides cancel unit by unit.

The result gives each outcome (one end state per distinct last step) with its
probability and the expected balances and duration given that outcome, plus
expected visits, residence, messages and duration. See Loan.leanfm (grace, then
interest; 20 USD expected interest over 28 expected days) and LimitOrder.leanfm
(half fill at 1004 USD, half give up at 4 USD in fees).

Rates are vectors too: `accrue { 1000 USD per week; -1 roomweek per week; } from Tenant to Landlord;`
(Rental.leanfm) is a continuous trade whose two sides cancel unit by unit at every moment.
Results are maps keyed by unit: `expectedByRole` {role: {unit: value}}, and each state's
`flows` {role: {"USD/week": rate}}.

Rewards come from residencies: solve visits, traversals and time once, then every reward is a
weighted sum of them. Pass `events` (an event stream in session_conform's format, with timeMs)
instead to get the realized rewards of each session's actual walk, and their total.
