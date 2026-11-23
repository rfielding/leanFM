# Diagrams as CTL video

`leanfm-diagrams-as-ctl.mp4` (about 3.7 minutes, narrated) shows what an interaction diagram means
when every diagram is turned into CTL: full diagrams (one session) and flat logs (many sessions
drawn over one another), prev and cause as the chain every message carries and where clauses as
its implementation on the wire, the translation rules of `reports/ctl-translation`, PlaceOrder's 40
formulas all proved, broken variants each failing a named formula, channels as constraints (the
proposed `selfhost.session.ctl-translation`), and measured timings.

- `fetch.py` asks the running service (`make serve`) every question and keeps the answers in `data/`.
- `produce.py` draws only those answers, narrates with the project-local Piper voice, and scores the
  video by rendering a score offline (sympathetic decay 0.9995 in a copy; the source file is unchanged).

```sh
make serve                                   # in another terminal
python3 -I video/ctl/fetch.py
video/.conda/bin/python -I video/ctl/produce.py
```
