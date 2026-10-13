# TLA+ state-space comparison

`OrderQueue.tla` is real TLA+. Run `make tla-toolchain tla-check` from the repo
root. TLC 1.7.4 checks TypeOK and NoPrematureReply in four finite models.
Deadlock detection is disabled because a completed two-order scenario is allowed
to stop. No fairness, liveness or implementation-refinement claim is made.

Messages use explicit FIFO inboxes, server control state and a pending message.
Each order ID is submitted once. CacheStep toggles irrelevant bits independently;
ClockStep increments an irrelevant counter. They change TLC states but not any
order message. Setting ClockBound to -1 enables an unbounded counter; do not run
that variant as an exhaustive finite-state check. Its states are mathematically
infinite. Unbounded repeated submissions/queues would be a second source of
growth, intentionally excluded here.

The measured comparison is in `book/generated/tla-state-space.json`; rerunning
updates elapsed times, whose values are not comparable performance benchmarks.
Only state counts appear in the book. TLC logs and search files are local ignored
outputs below `.tlc`. The pinned toolchain contains only reusable checker code.

`MessageFirst.proposed` is invented, TLA+-inspired notation, not a working
extension. Sending appends to the receiver's inbox; it does not let a sender
arbitrarily mutate the receiver's private variables. Receiving consumes the
message and the receiver changes its own protocol state. Full queues block a
send without mutation; empty queues block receive. Delivery, retries, fairness,
atomicity and message serialization need explicit implementation mappings.

Classes describe actor behavior; instances have distinct IDs and queues.
Sharding chooses an owner by key, replication creates copies of that owner,
and quorum controls acknowledgment. The helper syntax does not implement a
consensus protocol, compiler, or automatic state-space reduction.

Reference: [Lamport, Specifying Systems](https://lamport.azurewebsites.net/tla/book.html).
