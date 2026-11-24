# CTL and where clauses video

`leanfm-ctl-and-where.mp4` (about 7 minutes, narrated) is the deep version of `video/ctl`. It follows
a diagram into CTL step by step:

- the checker model: a node is a moment labelled by its last message, with the atoms `after` and `terminal`,
  and an ended session stutters;
- the three lines (EX, EX, AX) LeanFM writes for one moment of Images;
- typestates found by refinement rounds: Upload's two Acks share a class in round 0 and split in round 1, so
  its lookahead is 1;
- names with shared parts, PlaceOrder's 11 faithful rules and the bisimulation theorem;
- faithfulness decided in one walk.

It then adds the data a diagram cannot show:

- a field atom in CTL is `unknown`, because the graph holds labels, not values;
- a guard picks a branch: CTL proves both branches possible, and `session_conform` picks one by the logged
  values, reporting a missing value as unchecked;
- guards that leave a gap (PricingGap, total 70) leave a run stuck where the shape proves `AF terminal`.
  AG safety carries over to conforming runs. AF and EF carry over only when a choice's guards cover every
  value;
- conditions across messages (`p.amount = q.price`) and structure constraints (`contentLength = size`);
- Fresh/Link equations as identity, untangling a flat log.

Together: identity, then shape, then values.

- `protocols/` holds the protocols the video checks.
- `Typestates.lean` asks LeanFM's own `Faithful.typestates` for the checker model and refinement rounds.
- `fetch.py` asks the running service (`make serve`) every other question and keeps the answers in `data/`.
- `produce.py` draws only those answers (dot places the boxes), narrates with the project-local Piper voice,
  and scores the video as `video/ctl` does.

```sh
make serve                                   # in another terminal
python3 -I video/ctl-where/fetch.py
video/.conda/bin/python -I video/ctl-where/produce.py
ONLY=gap video/.conda/bin/python -I video/ctl-where/produce.py   # one scene's still, in build/
```
