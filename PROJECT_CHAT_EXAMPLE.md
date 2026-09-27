# Example project-creation chat

This example shows a requirements conversation creating a project, rather than
adding one isolated task. A project is an inter-related set of named interaction
grammars. The grammars may reference one another, share actors and event fields,
and produce several scenarios. Every requested output records the prompt that
motivated it and the event reducer that answers it.

## Conversation

**User:** Create a returns project for our shop. A customer signs in, submits a
return, the warehouse inspects it, and approved returns are refunded. I want to
see where returns stall and how much they cost us.

**Assistant:** I will treat that as one project containing related interactions,
not one long sequence. What identifies a project run and a particular return?
Which actors exchange visible messages?

**User:** The project is `shop_returns`. `session_id` identifies the customer's
login session and `return_id` identifies a return. The actors are Customer,
Storefront, Identity, Returns, Warehouse, Payments, and Finance.

**Assistant:** I have five candidate grammars: authenticate, submit return,
inspect return, issue refund, and query status. Does submission require a prior
successful authentication? Can inspection and refund fail independently?

**User:** Submission must carry a visible `session_proof` issued by authenticate.
Inspection can approve or reject. After approval, warehouse restocking and the
payment refund happen in parallel. The return is complete only after both reply.
Refund can fail and be retried up to three times. Finance records tax reversal
separately from the refund.

**Assistant:** To answer “where returns stall,” I need timestamps on separate
start/end events, causal `prior` links, and an observation-window policy for
unfinished returns. Should the output include one interaction diagram and one
state machine for every `(session_id, return_id)` scenario, plus stage-latency
and queue-depth functions over time?

**User:** Yes. Pair completions to starts by event ID. Show p50/p95/p99 latency by
stage, queue depth by service over time, completion and rejection counts, and a
pie of terminal outcomes. Unfinished returns at the end of the window are
censored, not failures.

**Assistant:** “How much they cost us” needs an accounting boundary. Which event
fields are observable, and what should count as loss?

**User:** Currency is USD cents. Payment emits `refund_cents` and `fee_cents`.
Warehouse emits `handling_cents`, `restock_value_cents`, and `waste_cents`.
Finance emits `sales_tax_reversed_cents`. Plot each component daily and define
`return_loss_cents = refund + fee + handling + waste + tax_reversed -
restock_value`. Do not call it total business loss.

**Assistant:** I will preserve that exact accounting formula and label. The
project outputs now have prompt provenance: scenario diagrams answer how each
return unfolded; latency and queues answer where it stalled; outcome counts
answer what happened; and the daily cost function answers the bounded cost
question. These will all reduce the same accepted event stream and the scalar
results will also be exported at `/metrics`. Shall status queries affect return
state or only observe it?

**User:** Only observe it. A status response names the latest event ID it saw.

**Assistant:** The project is sufficiently identified. I will emit the related
grammars, protobuf event fields, actor projections, desired-output catalog,
reducers, CTL obligations, and implementation mappings. Missing runtime events
will make the corresponding output indeterminate; they will not be invented.

## Resulting grammar set

The project grammar composes named interactions by reference:

```text
project shop_returns ::=
  authenticate ;
  (submit_return ; inspect_return ; complete_approved_return
   || repeat(status_query))

authenticate ::=
  Auth.Request ;
  (Auth.Denied
   | Auth.Challenge ; Auth.Proof ; Auth.SessionIssued)

submit_return ::=
  guard(prior Auth.SessionIssued(session_proof)) ;
  Return.Submitted ; Return.Accepted

inspect_return ::=
  Warehouse.InspectionRequested ;
  (Warehouse.Rejected
   | Warehouse.Approved)

complete_approved_return ::=
  guard(prior Warehouse.Approved(return_id)) ;
  (restock || refund_with_retry) ;
  join(Restock.Result, Refund.Result) ;
  Finance.TaxReversalRecorded ;
  Return.Completed

restock ::=
  Warehouse.RestockRequested ;
  (Warehouse.Restocked | Warehouse.Wasted)

refund_with_retry ::=
  Payment.RefundRequested ;
  (Payment.Refunded
   | Payment.RefundFailed ; retry(refund_with_retry, max=3))

status_query ::=
  Status.Request(return_id) ;
  Status.Response(return_id, latest_event_id)
```

The reference edges are part of the project:

```text
authenticate ──session_proof──▶ submit_return
submit_return ──return_id──────▶ inspect_return
inspect_return ──approval──────▶ complete_approved_return
complete_approved_return ──────▶ restock
complete_approved_return ──────▶ refund_with_retry
all return interactions ───────▶ status_query (read-only observation)
```

Each concrete run is partitioned by `(session_id, return_id)`. Its interaction
diagram is a projection of accepted events onto actor lifelines. Its state
machine is a projection of the same events onto observable state/message/state
triples. Neither visual is independently authored.

## Prompt-derived outputs

| Output ID | Shape | Question retained from the chat | Event reducer |
| --- | --- | --- | --- |
| `return.interaction` | interaction diagram | How did this return unfold between actors? | Partition by `(session_id,return_id)`; causally order messages by `prior` and `timeAt` |
| `return.state_machine` | state machine | Which return states and transitions occurred? | Project observable state/message/state triples |
| `return.stage_latency` | 2D function | Where do returns stall? | Pair stage end to start; plot p50/p95/p99 by stage |
| `return.queue_depth` | 2D function | Which service accumulates work? | Time-weight queue observations by service |
| `return.terminal_outcomes` | scalar and pie | What happened to submitted returns? | Count completed, rejected, refund-failed, and censored terminal classes |
| `return.daily_loss` | 2D function | How much do returns cost under the agreed boundary? | Daily sum of refund + fee + handling + waste + tax reversal - restock value |

Prometheus exports numeric reductions with the stable output ID as provenance.
The 2D renderers consume the corresponding ordered samples. The diagrams and
FSMs consume projections of the same scenario events. All six artifacts exist
because a prompt in the conversation asked a question; adding another artifact
requires another durable `DesiredOutput` record.
