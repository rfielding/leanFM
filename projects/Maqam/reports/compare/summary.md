# Implementations of the Maqam specification

Session impl/rust/source/default.mq, 2 cycles at 48000 Hz; bench 10 s at 64 frames, 48 kHz, NAM impl/zig/source/testdata/nam/marshall_jcm800.nam.

| implementation | spec | check | render | null test | events | bench | every block | source lines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rust (default) | validated | pass 0.2 s | not provided |  |  | not provided | not provided | 20156 |
| zig | validated | pass 0.1 s | pass 14.7 s, deterministic |  | conforms | frames 64, rate 48000, callbacks 7500, deadline_misses 0, callback_p50_us 214.04, callback_p99_us 293.053, callback_max_us 837.794, release_late_max_us 130.722, slack_min_us 495.5393333333333, realtime rtkit, memory_locked True | 0 of 7500 late, 0 labels disagree; AudioPeriod: conforms | 25743 |
