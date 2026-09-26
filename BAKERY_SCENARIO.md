# Bakery event corpus

The canonical quantitative example is `examples/bakery-events.jsonl`. It contains
one JSON object per observable event and is generated deterministically by
`scripts/generate_bakery_events.py`.

The grammar is:

```text
fulfillOrder ::=
  OrderPlaced ;
  (PaymentRequested ; (PaymentAuthorized | PaymentDeclined)
   ||
   BakeRequested ; (BakeCompleted | BakeFailed)) ;
  join(paymentResult, bakeResult) ;
  (OrderRejected
   | OrderAccepted ;
       (OrderCancelled
        | DeliveryRequested ; CourierAssigned ;
          (OrderDelivered | DeliveryFailed)))
```

`PaymentRequested` and `BakeRequested` both reference `OrderPlaced`, forming a
fork. `OrderAccepted` or `OrderRejected` references both result events, forming a
join. The first byte-level terminal that differs resolves each alternative; no
separate chooser field exists.

Each event records:

- stable event identity and a list of immediate causal predecessors;
- `(session, task)` correlation;
- source and destination actors;
- one `timeAt` timestamp; elapsed time is the difference between separate boundary messages;
- encoded byte count;
- visible values used by reducers.

The stream also contains `ShiftPaid` events with employee, role, minutes, rate,
and pay. Payment, refund, ingredient-cost, and waste fields allow the reducer to
calculate daily gross sales, net revenue, employee pay, ingredient cost, profit,
waste cost, and waste units. Waste is reported separately but is not subtracted
twice: its ingredient cost is already included in total ingredient cost.

Regenerate and reduce the corpus with:

```text
make bakery-data
make bakery-stats
```

The checked-in `examples/bakery-stats.json` is calculated by streaming the event
file. Its ratios, latencies, outcome counts, byte totals, and concurrency values
are the source for quantitative examples. They are observations of this corpus,
not probabilities asserted independently of it.
