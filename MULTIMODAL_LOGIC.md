# Multimodal language extension

Status: agreed design direction. CTL is implemented; general knowledge and
policy evaluation is not. This document does not replace the accepted canonical
specifications in `LeanFM/LLMGenerated/`. Typed requirements, implementation
mappings, and their acceptance gates must precede checker implementation.

## Distinct quantification domains

- Temporal CTL `A/E`: all/some legal forward paths. `F/G`: eventually/always
  along a path. Temporal possibility includes now and the future.
- Knowledge `K_a φ(h)`: for every legal history `h'` with the same declared local
  observation as `h`, `φ(h')` holds. Include `h` itself; knowledge is factive.
- Epistemic possibility: `not K_a(not φ)`, meaning the actor cannot rule out φ.
- Obligation `O_a ψ(h)`: every declared ideal policy future from `h` satisfies
  path condition ψ.
- Permission `P_a ψ(h)`: some ideal policy future from `h` satisfies ψ.
  With the same relation, `P_a ψ = not O_a(not ψ)`.

Policy futures must be nonempty. Report inconsistent policies rather than
vacuously certifying obligations. Legal executions and ideal futures are not
interchangeable: actual behavior may violate policy. Policy is not morality.
Belief requires a separate relation and must not accidentally become factive.
Probability, strategic ability, and program modalities are outside this initial
extension. No claim of supporting every modality follows from this design.

State formulas and path conditions need distinct types. For example,
`O_a F audit(r)` means: every ideal future has some position at or after the
current position where request r is audited. It is not bare CTL syntax.

## Persistence and recurrence in CTL

| Formula | Exact reading |
| --- | --- |
| `AF AG p` | Every path eventually reaches a state from which every path always satisfies p. |
| `AG AF p` | At every reachable state, every future path eventually satisfies p. |
| `EF EG p` | Some path eventually reaches a state with some future always satisfying p. |
| `EG EF p` | Some path always visits states with some future eventually satisfying p. |

`not(AF AG p) = EG EF(not p)` and `not(AG AF p) = EF EG(not p)` retain
existential counterexample search. The witness futures inside `EG EF` need not
be the outer path. Universal LTL `G F p` matches `AG AF p` under the usual total
transition semantics; `AF AG p` is stronger than universal LTL `F G p`.
These additions do not make CTL equivalent to LTL.

## First verification milestone

Use a bounded Kerberos model with named actors, byte-defined messages, task and
ticket correlation, nested concurrency, and interaction-diagram assertions.
Declare each actor's visible messages, private keys, retained memory, and clock
observations. Define policy futures independently of actual legal behavior.
Return witnesses or counterexamples with their observation/policy boundary.
Test composition with CTL, policy inconsistency, and indistinguishable histories
where a claimed fact differs. Keep symbolic uncompromised-key assumptions
explicit: this is not a computational cryptography proof.

Past facts such as prior ticket issuance may compile into forward monitor state
only with a justified equivalence. Evaluate strictly prior facts before adding
the current event. Define causal ancestry versus linearized order explicitly;
concurrent screen order is not causal evidence. Unbounded past logic is deferred.

The [Kerberos video on YouTube](https://www.youtube.com/watch?v=f2efwxq8BaY)
([local MP4](video/kerberos/kerberos-narrated.mp4)) illustrates the design,
not an implemented modal checker. The central book contains the formulas and
their English readings. Existing tools such as
[MCMAS](https://sail.doc.ic.ac.uk/software/mcmas/) already combine temporal and
epistemic checking; LeanFM's intended distinction is its integrated software
engineering workflow, not invention of multimodal logic.
