# GoServer, live

`leanfm-goserver-live.mp4` (about 2.3 minutes, narrated): two real GoServer games at once (four people on
11×11, three on 9×9), the traffic seven browsers sent, what LeanFM found on first contact with it, the
stream untangled into person sessions, game sessions and joins, and GoServer's session type as 78 CTL
formulas, every one proved.

- `play.py` plays both games in headless Chrome (the GoServer tour's DevTools mechanism, port 8096),
  captures each board after every move into `build/frames/`, and records every browser's API calls
  (session tokens replaced by s1, s2, ...) into `data/traffic.json`.
- `fetch.py` turns the traffic into a LeanFM log (`data/log.json`, with its reducer and findings) and
  asks the running service (`make serve`) for `session_conform` against GoServer's session type, before
  (`data/goserver-before.leanfm`, where the lobby listed games one request at a time) and after the fix;
  it copies `reports/ctl-translation/goserver.json`, from `translate_full.py`.
- `produce.py` draws only those answers and the captured frames, narrates, and scores the video.

```sh
make serve                                              # in another terminal
python3 video/goserver/play.py
python3 -I reports/ctl-translation/translate_full.py goserver reports/ctl-translation/goserver.json
python3 -I video/goserver/fetch.py
video/.conda/bin/python -I video/goserver/produce.py
```
