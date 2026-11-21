# maqam-live in Zig

The Zig implementation of the Maqam specification (`../../../spec/Requirements.lean`, protocol
`../../../spec/Maqam.leanfm`), a port of the upstream Rust. Its mapping to the specification is
`../Implementation.lean`; the book (`../../../book/main.pdf`, chapter "Implementations and how
they compare") explains both implementations.

## Build without the Rust

Runs on Linux and macOS. Needs Zig 0.17 and, on Linux, the ALSA development headers
(`libasound2-dev`); on macOS, nothing more than the Command Line Tools (`xcode-select --install`)
for the CoreAudio SDK. ffmpeg on PATH for recording (`m`). Nothing outside this directory is read,
built or linked.

On macOS the terminal running `maqam-live` asks for microphone permission for the live input;
without it the app plays with no input.

```sh
make            # zig-out/bin/maqam-live
make check      # build and run every module's tests
make run        # the terminal app
make render SESSION=default.mq CYCLES=1 RATE=48000 WAV=render.wav
make bench  SESSION=default.mq SECONDS=10 NAM=testdata/nam/marshall_jcm800.nam PERIOD_LOG=period.jsonl
```

`--bufsize=<frames>` asks the audio device for that buffer size (default 64), as upstream.

Command mode runs commands without the terminal UI, separated by `--`, as upstream:

```sh
zig-out/bin/maqam-live load default.mq -- m
```

`MAQAM_EVENT_LOG=<path>` appends every MaqamLive message as one JSON line.

The bench is paced like a device: block k is released at k * 64/48000 s and must be handed over
within one period (protocol `AudioPeriod`, `../../../spec/AudioPeriod.leanfm`). It asks for
real-time scheduling (Linux: SCHED_FIFO, else RealtimeKit; macOS: the Mach time-constraint policy)
and locks memory first (Linux only; macOS has no mlockall), as the live audio thread does, and
reports both; `PERIOD_LOG` writes every block for `make compare` to check.

## Layout

One Zig module per Rust module (`PORTING.md` has the naming and porting conventions):
`tuning`, `command`, `sequencer`, `synth`, `session`, `fx`, `vcf`, `analog`, `sympathetics`,
`nam` (the nam-rs runtime), `audio` + `device` + `coreaudio` (engine, ALSA on Linux, CoreAudio on
macOS), `record` + `carpet` + `png`
(MP4 recording), `app` + `net` (App and workers), `ui` + `term` (terminal UI), `channel` +
`shared` (lock-free rings and atomics), `eventlog` + `wav` (comparison hooks). The bundled
`.mq` sessions are copies of the specification's example sessions.
