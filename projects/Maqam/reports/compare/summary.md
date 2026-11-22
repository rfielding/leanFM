# Implementations of the Maqam specification

Session impl/zig/source/default.mq, 2 cycles at 48000 Hz; bench 30 s at 64 frames, 48 kHz, NAM impl/zig/source/testdata/nam/marshall_jcm800.nam.

| implementation | spec | check | render | null test | events | bench | every block | source lines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| zig (default) | validated | pass 0.1 s | pass 14.8 s, deterministic |  | conforms | frames 64, rate 48000, callbacks 22500, deadline_misses 0, callback_p50_us 217.852, callback_p99_us 301.111, callback_max_us 791.174, release_late_max_us 321.015, slack_min_us 542.1593333333333, realtime rtkit, memory_locked True | 0 of 22500 late, 0 labels disagree; AudioPeriod: conforms | 27572 |
