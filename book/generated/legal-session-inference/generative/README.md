# Generative settlement design sketch

Prompt: "let's see what a session type looks like with deadlines and probabilities added in; for the sake of modelling generative session types."

This folder preserves the original design sketch. The accepted syntax is now implemented in the MCP text parser; the executable example is examples/sessions/DepositSettlement.leanfm and regression evidence is LeanFM/Session/GenerativeTests.lean. The checked core is Core.leanfm. The annotations are written in Settlement.proposal.txt. session_check returns no issues; session_review returns no findings for the core only.

Scope: one settlement after lease end and direct address receipt, excluding registration, postal delivery/recovery, hardship and reparation. Receipt delivers the address to Landlord. The core serializes lease end before delivery; max(time(ended), time(address)) states the intended trigger for a broader model. Times are relative to that trigger; a day is a fixed 24 hours, not jurisdiction-specific calendar arithmetic.

Positive invariant: erasing generative annotations preserves the interaction grammar; every generated message trace must conform to that core. The obligation is judged independently of sampling.

Negative requirements:
- A missed deadline must not remove the late trace. Control: monitor status is derived without restricting the message grammar.
- A probability must not be presented as measured. Control: named declared overlay and explicit illustrative provenance.
- No sender learns about postal delivery from an observer annotation. Control: this scope uses direct observed receipt only.
- A deadline violation must not be an invented message. Control: Section2Violated is monitor output, not a protocol send.
- Unknown timing or probability must not silently become zero, uniform or infinite. Control: explicit distributions here; unassigned cases in broader models remain unknown.

The choice probabilities are conditional on reaching settlement. The 7/25-day probabilities are conditional on choosing full return. This is a generative behavior model, not a claim that an agent's free choice is intrinsically random. Delay sampling must be causal, nonnegative and compatible with scheduling assumptions; this sequential example needs no concurrent scheduler. Equal timestamps preserve protocol order.

Deadline satisfaction is inclusive: arrival at trigger + 14 days satisfies the bound; after that boundary, an unmet obligation is violated. The late 25-day return is retained and remains a violation; returning alone does not pay the separate penalty. Reparation is out of scope.

Existing LeanFM supports the erased session protocol and scalar-delay probability overlays over finite acyclic task models. The integrated notation, distribution-valued delays, event-triggered clock binding and normative monitor are now implemented for finite sequential choices. The original artifacts here describe the proposal; current checks live in GenerativeTests.lean.

Desired output: the annotated text answers what a generative session type could look like. Source: Core.leanfm plus declared illustrative annotations. Reducer: annotation erasure followed by LeanFM session_check/session_review. Unit: interaction order, exact conditional probability, fixed days. Boundary: the single settlement specified above. No empirical measurements are asserted.

