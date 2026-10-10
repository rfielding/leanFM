# Kerberos modal example

Independent narrated video: `kerberos-narrated.mp4`.
Source requirements: `../kerberos-example.md`.
Protocol reference: RFC 4120, https://datatracker.ietf.org/doc/html/rfc4120.

Originating prompt: make a video explicitly about Kerberos, using extended modal
logic to track who knows what and security obligations, nested concurrency, and
past-to-future monitor transformations.

The reducer in `scenes.py` generates one 3-workspace symbolic event scenario,
with task forks, joins, original event IDs and predecessor lists. The displayed
order is a topological interleaving, not additional causal edges. `events.json`
is the generated source for trace views. Units are events, tasks, histories,
paths and positions. Boundary and policy assumptions are in the requirements.

Knowledge and obligation equations define example semantics; candidate combined
security formulas are not advertised as proved by LeanFM's existing CTL checker.
The trace is modeled application traffic, not a capture of real Kerberos packets.

Reproduce from the repository root:

```sh
make kerberos-video
```
