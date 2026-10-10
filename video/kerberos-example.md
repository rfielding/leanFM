# Kerberos: concurrency, history, knowledge, and obligation

Status: requirements proposal for a separate video and a navigable trace.
The existing CTL evaluator does not implement epistemic or deontic operators.

## Question and boundary

Prompt: show nested concurrency over a long immutable event stream; relate past
requirements to future checks; quantify explicitly over knowledge and obligation.
Question: at a selected legal history, which messages are admissible, what can
each actor know, and what do the declared policies require?
Event source: modeled Kerberos AS, TGS, AP exchanges, followed by application
workflows and their task-start/task-complete observations.
Reducer: build the prior-ID graph and successor index; project actor-local views;
evaluate monitor predicates; enumerate explicit epistemic alternatives and
policy-compliant futures. Units: events, tasks, histories, paths, positions.
Boundary: one realm; uncompromised client, KDC, and two service keys; symbolic
encryption; explicit replay cache and time-validity checks; mutual authentication.
Application forks and audit policy are example requirements, not Kerberos rules.

Kerberos V5 uses ASN.1 DER on the wire, not protobuf. A LeanFM protobuf event
envelope may record the original DER bytes and decoded observations. The old
Kerberos/DH sketch is not the standard protocol used for this example.
Reference: https://datatracker.ietf.org/doc/html/rfc4120

## Nested concurrent scenario

Alice obtains a TGT through AS-REQ / AS-REP. She then starts a workspace task
with two concurrent children: Documents and Reports. Each independently obtains
a service ticket through TGS-REQ / TGS-REP and mutually authenticates through
AP-REQ / AP-REP. Documents forks into metadata and content requests. Reports
forks into two report requests; each report forks again into data and template
requests. Children join before their parent completes. Both service branches
join before the workspace completes. Repeat the workflow with distinct task,
ticket, and authenticator IDs to create a long trace; include replay rejection
and expired-ticket rejection as alternate scenarios.

Task hierarchy is explicit. Every completion points back to its own start and
the child completions it requires. Unrelated events may be interleaved in a
display order without acquiring a predecessor edge. The trace is one execution;
other legal executions remain part of the model for modal checking.

The trace viewer must support backward/forward scrolling, selecting a prefix,
filtering by actor and task, and jumping between starts, completions, and prior
IDs. The video pans through that same trace and freezes selected prefixes for
the mathematical explanation. Synchronize the trace, interaction diagram,
per-task residual grammar, monitor values, and actor-local view.

## Past predicates become forward monitor state

For a linear display history h, H denotes strictly earlier positions:

    H issued(t) at i  ⇔  ∃ j < i. issued(t) at j

Read: previously ticket t was issued if and only if there exists a position j
strictly less than i where ticket t was issued. For causal history, replace j<i
with the declared ancestor relation; a display order is insufficient.

Introduce issuedBefore_i, a set indexed by ticket ID:

    issuedBefore_0 = ∅
    issuedBefore_(i+1) = issuedBefore_i ∪ ticketsIssuedAt(i)
    H issued(t) at i  ⇔  t ∈ issuedBefore_i
    AG(accepted(t) → t ∈ issuedBefore)

Read the last formula: on every future and every position, accepting ticket t
implies t belongs to the set of tickets issued earlier. The monitor is evaluated
before consuming the current event, so issuance and acceptance at the same
position cannot manufacture a strictly previous issuance.

This is state augmentation, not reversing time or replacing a past requirement
with AF. Expiration, revocation, task scope, and unbounded identifiers determine
which monitor data is needed. Finite abstractions need a preservation argument.

## Quantification over knowledge

Let W be the declared admissible histories. Define obs_a(h) as actor a's local
messages, private state, and symbolic deductions under the stated key assumptions.

    h ~a h′  ⇔  obs_a(h) = obs_a(h′)
    K_a φ(h) ⇔ ∀ h′ ∈ W. (h ~a h′ → φ(h′))

Read: actor a knows phi at history h if and only if, for every admissible history
h prime, having the same local view implies phi holds in that history.

Example candidate: after validating a service ticket and fresh authenticator,
the service knows that its session key was issued by the trusted KDC for the
named client/service binding, under the uncompromised-key and derivation model.
Receipt alone does not establish the claim. Knowledge of a key's origin also
does not establish that its supposed owner is currently participating.

Show two histories with identical observer ciphertext views but different
plaintexts. If phi differs, the observer does not know phi. Seeing encrypted
bytes is not knowing the plaintext. Symbolic non-derivability of a key and
computational secrecy are separate claims.

## Quantification over obligation

Let Ideal_a(h) be the nonempty set of futures satisfying the explicitly declared
policy for actor a at h. This relation differs from both temporal reachability
and epistemic indistinguishability.

    O_a ψ(h) ⇔ ∀ π ∈ Ideal_a(h). ψ(π)
    P_a ψ(h) ⇔ ∃ π ∈ Ideal_a(h). ψ(π)
    O_a F audit(r) ⇔ ∀ π ∈ Ideal_a(h). ∃ i ≥ 0. audit(r, π_i)

Read: actor a is obliged eventually to audit request r if and only if, for every
policy-compliant future from h, there exists a nonnegative position i where
request r is audited. An empty ideal set reports inconsistent policy; it must
not silently certify every obligation.

Actual legal futures may violate policy. Consequently O_a F audit(r) does not
imply AF audit(r). Require enforcement separately, or exhibit a legal unaudited
cycle as a counterexample. Authentication establishes identity evidence;
authorization and audit duties come from the application policy.

## Video sequence

1. Standard AS/TGS/AP exchange and key ownership.
2. Grow the nested task tree while messages populate the immutable trace.
3. Pan forward and backward; distinguish chronology, ancestry, and local views.
4. Translate the earlier-ticket requirement into a forward monitor.
5. Freeze two indistinguishable histories and evaluate the knowledge quantifier.
6. Branch policy-compliant and violating futures; evaluate obligation and AF.
7. Show a concrete replay rejection and a missing-audit liveness counterexample.

Acceptance needs to settle the local-view abstraction, admissible histories,
ideal-future policy, terminal-path convention, causal versus chronological past,
and desired enforcement guarantees before implementation is claimed complete.
