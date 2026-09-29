# Bakery event corpus

The canonical quantitative example is `examples/bakery-events.jsonl`. It contains
one JSON object per observable event and is generated deterministically by
`scripts/generate_bakery_events.py`.

The retail bakery has two related grammars. Production is scheduled by bread
kind, baked in batches, and shipped to the storefront before opening:

```text
produceBatch ::=
  BatchScheduled ; BatchBaked ; BatchShipped ; InventoryStocked ;
  (InventorySoldOut | FreshnessWindowElapsed ;
     RemainingInventoryMovedToCharity ; DonationReceiptRecorded)

sellFromInventory ::=
  OrderPlaced ; PaymentRequested ;
  (PaymentDeclined ; OrderRejected
   | PaymentAuthorized ;
     (InventoryReserved ; OrderFulfilled | Stockout ; OrderRejected))
```

An inventory reservation names both the paid order and every stocked batch lot
that supplies it. Lots are consumed oldest-first while still within their
declared two- or three-day freshness window. There is no per-order baking and no
same-day custom-loaf wait.

Each event records:

- stable event identity and a list of immediate ordering predecessors;
- `(session, task)` correlation;
- source and destination actors;
- one `timeAt` timestamp; elapsed time is the difference between separate boundary messages;
- encoded byte count;
- visible values used by reducers.

The stream also contains `ShiftPaid` events. Payment, batch ingredient-cost,
inventory, and donation fields support sales, profit, stockout, sell-through,
inventory-age, and donated-unit/value reducers. A receipt may establish eligible
donation value; actual tax savings remain indeterminate until jurisdiction,
entity type, valuation, deduction limits, and tax rate are declared.

Regenerate and reduce the corpus with:

```text
make bakery-data
make bakery-stats
```

The checked-in `examples/bakery-stats.json` is calculated by streaming the event
file. Its ratios, outcome counts, byte totals, and concurrency values
are the source for quantitative examples. They are observations of this corpus,
not probabilities asserted independently of it.
