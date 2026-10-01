# Draft: three-replica Paxos key-value application

Status: accepted by the user on 2026-10-01.

## Boundary and assumptions

The Paxos participant is `KVReplica`, instantiated as one homogeneous cluster
of exactly three members: `kv-0`, `kv-1`, and `kv-2`. `Browser` and `WebApp` are
actors but are not Paxos participants. Two independent browser sessions may
have tasks in flight concurrently.

The confirmed availability premise means that at every modeled instant at least
two replicas are running, all replicas can reach one another while running, and
each can reach its durable storage. This gives a live majority. Persistence
additionally requires an
acceptor to fsync its accepted ballot, slot, key, and value before sending
`Accepted`; the web response is not successful until a quorum of two durable
acceptances exists. A restarted replica recovers its accepted log before
participating. If all three replicas stop, the service is unavailable rather
than forgetful: after restart, quorum recovery reconstructs the committed log
from durable acceptor state before reads or writes resume.

The confirmed conflict rule is last-committed-slot-wins: if the two browser
sessions write the same key concurrently, the leader assigns distinct Paxos
log slots and the value in the later committed slot is displayed.

## Related grammar set

```text
project paxos_kv ::=
  repeat(quorum_write || linearizable_list || recover_replica)

quorum_write ::=
  Browser.Put(key, value, session, request_id) ;
  WebApp.Propose(key, value, session, request_id) ;
  Leader.Assign(ballot, slot) ;
  parallel(
    Replica.Accept(ballot, slot, key, value) ;
    Replica.Accept(ballot, slot, key, value) ;
    Replica.Accept(ballot, slot, key, value)
  ) ;
  mOfN(2, Replica.DurableAccepted(ballot, slot)) ;
  Leader.Commit(ballot, slot, key, value) ;
  WebApp.PutSucceeded(key, value, slot) ;
  ref(linearizable_list)

linearizable_list ::=
  Browser.List(session, request_id) ;
  WebApp.ReadBarrier(ballot) ;
  mOfN(2, Replica.ReadBarrierAck(ballot, committed_slot)) ;
  Leader.Snapshot(committed_slot, entries) ;
  WebApp.ListSucceeded(committed_slot, entries)

recover_replica ::=
  Replica.Unavailable(instance) ;
  Replica.Restarted(instance) ;
  Replica.RecoverAcceptedLog(instance) ;
  Replica.CatchUp(committed_slot) ;
  Replica.Available(instance)
```

The notation above is intentionally behavioral. An implementation may use a
stable Multi-Paxos leader, but leader election and ballot changes must remain
observable whenever leadership changes.

## Two-session interaction projection

This is the interaction structure to be generated from the grammar. The two
browser branches are incomparable until the leader assigns slots; either may
arrive first.

```text
Browser A      Browser B        WebApp          KV leader       KV followers
    | PUT a=1      |               |                 |                 |
    |------------->|               |                 |                 |
    |               | PUT b=2      |                 |                 |
    |               |------------->|                 |                 |
    |               |               | propose A      |                 |
    |               |               |--------------->|                 |
    |               |               | propose B      |                 |
    |               |               |--------------->|                 |
    |               |               |          assign slots s,s+1      |
    |               |               |                 | accept/fsync -->|
    |               |               |                 |<-- accepted (2) |
    |               |               |<-- commit A ----|                 |
    |<-- success + current list ----|                 |                 |
    |               |               |                 | accept/fsync -->|
    |               |               |                 |<-- accepted (2) |
    |               |               |<-- commit B ----|                 |
    |               |<-- success + current list ------|                 |
```

The durable event representation must keep separate `(session, scenario)` keys
and use `priorIds` to record immediate predecessor order. `priorIds = []` means
that an event is a minimal (first) event in the scenario. If several events
have no predecessor, they are mutually unordered and may proceed in parallel.
A singleton list is the ordinary prior-event link; a list with several IDs is
a join. These links are ordering backpointers, not claims of causation. Event
file line order must not serialize otherwise unordered browser requests.

## Observable safety and progress obligations

- A successful PUT necessarily has two prior `DurableAccepted` observations
  for the same ballot, slot, key, and value.
- No two different values are committed for the same log slot.
- Every committed slot remains present after any one replica is unavailable.
- A list result reflects one committed prefix selected after a quorum read
  barrier; it does not combine entries from different prefixes.
- With two mutually reachable durable replicas and a leader eventually chosen,
  every accepted browser request eventually succeeds or returns an explicit
  error.
- Replica unavailability, leadership loss, retry, rejection, and recovery are
  visible outcomes rather than hidden timeouts.
- At most three replica instances exist, all implementing the same
  `KVReplica` actor specification.

## Prompt-derived outputs

| Output ID | Shape | Prompt/question | Reducer |
| --- | --- | --- | --- |
| `paxos.write.interaction` | interaction diagram | How does a browser write become persistent? | Partition write events by `(session,request_id)` and render quorum branches in `priorIds` order, with typed message fields in each node |
| `paxos.write.state_machine` | state machine | Which observable write states and failure exits exist? | Render residuals of `quorum_write` |
| `paxos.list.interaction` | interaction diagram | How is the complete key/value listing made linearizable? | Render list and read-barrier events by `(session,request_id)` |
| `paxos.list.state_machine` | state machine | Which observable list states and failure exits exist? | Render residuals of `linearizable_list` |
| `paxos.concurrent.order` | prior-pointer graph | Can two browser sessions access the app concurrently? | Render incomparable request branches, slot assignment, quorum joins, and responses |
| `paxos.commit_latency` | 2D function | How does write latency change with concurrent browser sessions? | Pair PUT start to success/error by prior ID; x=max concurrent sessions, y=latency milliseconds |
| `paxos.quorum_size` | scalar and histogram | Did every acknowledged write have a durable majority? | Count distinct accepting replica instances per committed slot |
| `paxos.replica_availability` | line | Were at least two replicas available throughout the observation window? | Sweep `Unavailable`/`Available` intervals and plot available replica count over monotonic time |
| `paxos.recovery_lag` | 2D function | How far behind is a restarting replica? | x=time since restart; y=leader committed slot minus replica applied slot |
| `paxos.outcomes` | pie/histogram | What happened to browser PUT and list requests? | Count success, explicit rejection, timeout/censored, and leadership-loss outcomes |

Numeric reductions use these stable output IDs at `/metrics`. Every diagram,
state machine, and chart is derived from the accepted grammar and events rather
than maintained as a second specification.

## Web behavior

The page contains a string `key` input, a string `value` input, and a submit
action. Below the form it renders the linearizable listing of all committed
key/value pairs. After a successful write the initiating session receives a
page containing a listing at least as new as its committed write. The other
browser session observes that write on its next list operation; server push is
not currently required.

There is no authentication and no delete operation. Keys are nonempty UTF-8
strings of at most 128 encoded bytes. Values are UTF-8 strings of at most 4096
encoded bytes. The database holds at most 10,000 distinct keys and supports at
least two browser sessions with requests in flight concurrently. Invalid or
capacity-exceeding writes return explicit errors without changing the committed
log. Each successful submission returns a listing containing at least that
committed write.
