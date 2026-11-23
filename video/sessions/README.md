# Session separation video

`leanfm-session-separation.mp4` (about 3 minutes, narrated) shows LeanFM separating a log without
session ids into its sessions. It covers the clauses `selfhost.session.identity.marks`, `.checks`,
`.scopes` and `.children` (each order task a child session of its login), and names `.graph` as the next step.

- `fetch.py` sends every question the video shows to the running service (`make serve`). The
  protocols are the fixtures in `LeanFM/Session/IdentityTests.lean`. The answers are kept in `data/`.
- `produce.py` draws only those answers: protocol text, the generated diagrams, derived sessions,
  verdicts, problems and identity notes. It narrates with the project-local Piper voice and scores the
  video with maqam-live: the Zig implementation renders `synth.mq` offline (`--render`).

```sh
make serve                                   # in another terminal
python3 -I video/sessions/fetch.py
video/.conda/bin/python -I video/sessions/produce.py
```
