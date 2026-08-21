Lean Formal Methods, based on communicating heirarchial processes.
=======
# LeanFM

A tiny Lean 4 formal-methods sketch for message-passing processes.

The model treats a protocol as globally observable behavior:

- each actor has its own observable local state machine
- messages are globally visible byte envelopes
- each envelope carries `src`, `dst`, and protocol `bytes`
- the global graph is the product observation of actor states
- optional chance nodes support MDP-style probabilistic outcomes
- dwell time supports expected latency, throughput, and queue metrics
- components can be built independently and assembled into larger systems
- CTL formulas run over the support graph

Run it with:

```sh
lake exe leanfm
```

The current example has three actors:

```text
Client
Gateway
Worker
```

It also includes a separate two-actor authorization group:

```text
Auth
DB
```

The executable assembles the two-actor group and the three-actor group by concatenating their globally visible message grammars and composing their metric summaries.

Two-actor auth group grammar:

```text
Auth->DB:[10 1]
DB->Auth:[10 2]
DB->Auth:[10 255]
```

Three-actor worker group grammar:

```text
Client->Gateway:[1 16]
Gateway->Worker:[2 32]
Worker->Gateway:[3 48]
Gateway->Client:[4 64]
Gateway->Client:[255]
```

Because the source is part of every message, an actor can reply to the sender by constructing a new envelope with its own `src` and the previous sender as `dst`.

The executable prints:

- the byte-level message grammar
- observable actor-state transitions
- MDP choices with weights and dwell times
- a time-weighted queue-length distribution
- globally visible terminal traces
- expected latency, success probability, and throughput
- Graphviz DOT for the state machine
- CTL results from the initial observation

Example metrics:

```text
auth group success probability: 98/100 ~= 0.98
auth group expected latency: 300/100 ~= 3.00
worker group success probability: 95/100 ~= 0.95
worker group expected latency: 795/100 ~= 7.95
assembled system success probability: 9310/10000 ~= 0.93
assembled system expected latency: 10791000/1000000 ~= 10.79
assembled system throughput: 9310000000/107910000000 ~= 0.08
```

For sequential composition, the current metric rule is:

```text
P(success A;B) = P(success A) * P(success B)
E(latency A;B) = E(latency A) + P(success A) * E(latency B)
throughput A;B = P(success A;B) / E(latency A;B)
```

The standalone three-actor worker metrics are:

```text
expected latency: 795/100 ~= 7.95
success probability: 95/100 ~= 0.95
throughput: 95/795 ~= 0.11
```

The graph deliberately excludes private variables. Internal counters, retries, queues, and timers should only appear if they change an actor's observable state, a globally visible message, a probability, or a dwell time.
