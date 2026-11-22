import LeanFM.Artifacts

/-!
# maqam-live: Zig implementation mapping

The second implementation of `spec/Requirements.lean`, a port of the upstream Rust written in Zig
0.17 under `impl/zig/source/`. It builds, tests and runs from that directory with only Zig and the
ALSA development headers on Linux, or only Zig and the system's CoreAudio on macOS (`make check`,
`make render`, `make bench`); nothing under `impl/rust/`
is read, built or linked (proof "Implementations stand alone"). Each actor and message is mapped
to the Zig that realizes it. Where the Rust falls short of a requirement (the book's "Known gaps"),
this implementation's control is named in the justification.

The Zig is the default implementation and the reference for further ports; `manifest.json` lists
both. Its reverb is the specification's (markdown `reverb`), not a port of upstream's.
-/

namespace Project.Implementation

open LeanFM

def why (id reason : String) : List RequirementJustification := [{ requirementId := id, reason }]
def actor (name typeName file id : String) : ActorCodegen := { actor := name, typeName, sourceFile := file, justifications := why id "Implements the accepted actor role." }
def chan (name wire channel id reason : String) : MessageCodegen := { message := name, wireType := wire, transport := .inProcessChannel channel, justifications := why id reason }

def implementation : ImplementationSpec :=
  { requirementId := "maqam.visible_behavior"
  , target := .zig
  , moduleName := "maqam-live"
  , outputDirectory := "impl/zig/source/"
  , actors :=
      [ actor "Performer" "terminal keyboard (term.Terminal raw mode, term.decode)" "impl/zig/source/src/ui.zig" "actor:Performer"
      , actor "App" "app.App (timeline, command dispatch, sessions, workers)" "impl/zig/source/src/app.zig" "actor:App"
      , { actor := "Audio", typeName := "audio.Engine.process, called once per block by device.Output: device.Alsa's thread on Linux, coreaudio.CoreAudio's render callback on macOS (sequencer, voices, VCF bank, FX, sympathetics, NAM)", sourceFile := "impl/zig/source/src/audio.zig"
        , justifications := why "actor:Audio" "Implements the accepted actor role." ++ why "proof:The audio callback never blocks" "Everything is preallocated in Engine.create; process only calls Ring.tryRecv, publishes through shared.Shared atomics (jump counters are a fixed atomic table, not a locked map) and hands released objects back on the garbage ring; a test runs a session through process with a failing allocator." ++ why "proof:No missed audio deadline" "NAM runs once per block (nam.Model.processBuffer); make bench releases 64-frame blocks on the period grid (device.bench waits for each release and never starts early) with the sympathetic strings, the reverb and a NAM capture on, and counts every block handed over after release plus one period." ++ why "proof:The audio thread never waits on the kernel" "realtime.lockMemory (mlockall current and future) and realtime.request (SCHED_FIFO, else RealtimeKit's MakeThreadRealtimeWithPID with RLIMIT_RTTIME set) run once in device.Alsa.run and device.bench before the loop. On macOS realtime.request sets the Mach time-constraint policy (period, computation and constraint from the block length) in device.bench; the live callback runs on CoreAudio's I/O thread, which already has it. macOS has no mlockall (lockMemory is false there): coreaudio.CoreAudio.open writes every buffer the callback uses, and the engine renders one silent block, before the device starts. Measured: without them the first block after a load took 916 page faults (about 1 ms) and a preemption delayed one release by 3.2 ms, both skips; with them, 0 faults and 0 of 7500 blocks late in three runs." ++ why "property:Every block is on time" "device.bench times each block from its release to its hand-over on one clock and judges it exactly ((done - release) * rate <= frames * 10^9, integers); --period-log writes the AudioPeriod stream from preallocated arrays after the run; make compare checks every block and its conformance to AudioPeriod." ++ why "proof:A buffer skip is never silent" "device.Alsa counts every playback underrun (snd_pcm_writei returning -EPIPE) into shared.Shared.underruns before recovering; coreaudio.CoreAudio counts one whenever the output timestamp's sample time is past the end of the block handed over before (coreaudio.isSkip, tested); ui draws the count in the header in red once it is nonzero." ++ why "proof:Live input never lags behind a backlog" "Each block's input is bounded by construction: device.Alsa reads at most one period of capture per block, and coreaudio.CoreAudio.render drops the oldest frames of its 16384-frame ring above max(3 output blocks, the last input chunk + one output block) before taking the block's input (coreaudio.FrameRing.dropOldest and coreaudio.backlogLimit, tested)." ++ why "property:The reverb tail follows its decay" "fx.Reverb implements markdown reverb: Reverb.setDecay computes T60, the per-line gains g_i and the wet gain k; the fx test \"reverb tail follows its decay\" measures an impulse response at decay 0 and 0.65 against 0.5 and 1.5 T60." ++ why "property:The reverb is dense and wide" "fx.Reverb feeds the left input to the even tank lines and the right to the odd lines through separate diffusers (right 1.07 times longer) and mixes them with the Householder matrix; the fx test \"reverb is dense and wide\" checks every sample 100..200 ms after an impulse is nonzero and |rho| < 0.3." ++ why "proof:The reverb never distorts or rings" "fx.Reverb has no clamp: g_i < 1 for every finite T60, the Householder matrix is orthogonal and the damping one-pole has gain at most 1; each tank line and allpass owns its slice of one buffer allocated in Reverb.init. FxProcessor.processReverb clamps only the final mix. The fx test \"reverb is linear\" compares the wet output for 0.5 and 1.0 impulses." ++ why "proof:The reverb never muddies the low end" "fx.Reverb runs two one-pole high-pass stages at 120 Hz per channel before the diffusers; the fx test \"reverb keeps the low end dry\" compares the wet RMS of 40 Hz and 1 kHz sines." ++ why "proof:The reverb never produces denormals" "fx.flush zeroes every value below 1e-15 before it is stored in reverb state (high-pass states, allpass and tank samples, damping states); the fx test \"reverb state fades to exact zero\" runs a tail out and checks every state value is 0 or at least 1e-15." }
      , { actor := "Recorder", typeName := "record.recordCycle on a worker thread", sourceFile := "impl/zig/source/src/record.zig"
        , justifications := why "actor:Recorder" "Implements the accepted actor role." ++ why "property:A failed recording leaves no partial mp4" "ffmpeg writes a .partial.mp4 that is renamed into place only on success; every failure path deletes it and the temporary layers." }
      , actor "Ffmpeg" "ffmpeg via std.process (argv only, no shell)" "impl/zig/source/src/record.zig" "actor:Ffmpeg"
      , actor "Llm" "OpenAI chat/completions or Anthropic messages via net.fetch (std.http) on a worker thread" "impl/zig/source/src/app.zig" "actor:Llm"
      , actor "Web" "net.fetch and net.download (std.http) of NAM capture URLs, search and the TONE3000 API" "impl/zig/source/src/net.zig" "actor:Web"
      , actor "Disk" "the working directory: .mq sessions, .nam cache, .globals.ml, maqam-<secs>.mp4" "impl/zig/source/src/session.zig" "actor:Disk" ]
  , messages :=
      [ chan "CommandLine" "[]const u8" "term.Terminal.readKey -> app.App handle command" "message:CommandLine" "One Enter submits one line; ';' splits it into commands."
      , chan "Rejected" "[]const u8 (\"✗ ...\")" "App.message" "message:Rejected" "Parse and range errors (command.parse ParseResult.err, identical text) are shown and stop the remaining parts of the line."
      , chan "Shown" "[]const u8" "App.message" "message:Shown" "The response pane shows one result string."
      , chan "AudioCmd" "sequencer.AudioCmd (pointer payloads; ownership moves to the audio side)" "channel.Ring(AudioCmd, 512)" "message:AudioCmd" "The App changes its timeline first, then sends the matching AudioCmd; the engine drains with tryRecv and returns replaced objects as sequencer.Garbage."
      , chan "Position" "shared.Shared atomics (cur_phrase, cur_subdiv, cur_plays, latency)" "shared.Shared (monotonic loads and stores)" "message:Position" "The engine publishes position without locking; the UI reads it every frame."
      , chan "PhraseStart" "synth spawn phrase start" "audio.Engine tick sequencer" "message:PhraseStart" "A phrase row spawns its voices for each of its repeats into a bounded voice list."
      , chan "JumpTaken" "JumpSpec counter" "audio.Engine, shared.Shared.jump_counters" "message:JumpTaken" "times 0 always jumps; otherwise counter+1 < times jumps back."
      , chan "JumpExhausted" "JumpSpec counter reset" "audio.Engine, shared.Shared.jump_counters" "message:JumpExhausted" "The counter resets to 0 and play continues at the else target or the next row."
      , chan "ControlApplied" "sequencer.ControlSpec" "audio.Engine tick sequencer" "message:ControlApplied" "A control row is applied and the sequencer advances without spending time."
      , chan "SaveSession" "MAQAM_SESSION_V3 text" "session.serializeSessionV3 + std.Io.Dir.writeFile" "message:SaveSession" "save writes header, create lines, then one record per row."
      , chan "LoadSession" "path" "App load (std.Io.Dir.readFileAlloc, bounded)" "message:LoadSession" "load reads the whole file."
      , chan "SessionText" "[]const u8" "session.load" "message:SessionText" "The header selects the V3, V2 or V1 loader."
      , chan "SessionError" "error from std.Io" "App load" "message:SessionError" "A missing or unreadable file is reported."
      , chan "Loaded" "[]const u8" "App.message" "message:Loaded" "After loading, Clear, start settings and every entry are sent to the audio."
      , chan "LoadFailed" "[]const u8 (\"line N: ...\")" "App.message" "message:LoadFailed" "Errors name the line (session.LoadResult.err)."
      , chan "Render" "phrases + sequence start settings" "std.Thread.spawn -> record.recordCycle" "message:Render" "Rendering runs off the audio thread, with its own mix at 44.1 kHz."
      , chan "Encode" "ffmpeg argv" "std.process (argv only)" "message:Encode" "The same ffmpeg arguments as upstream."
      , chan "Encoded" "exit status 0" "std.process child" "message:Encoded" "The staged .partial.mp4 is renamed into place."
      , chan "EncodeFailed" "exit status and ffmpeg log" "std.process child" "message:EncodeFailed" "The staged file and temporary layers are removed."
      , chan "WriteMp4" "./maqam-<unix_secs>.mp4" "std.Io.Dir rename" "message:WriteMp4" "Written in the working directory."
      , chan "RecordSaved" "record.RecordResult.ok" "channel.Mailbox (one slot)" "message:RecordSaved" "Polled by App tick."
      , { message := "RecordFailed", wireType := "record.RecordResult.err", transport := .inProcessChannel "channel.Mailbox (one slot)"
        , justifications := why "message:RecordFailed" "Polled by App tick." ++ why "proof:Possibly an external tool is missing" "ffmpeg -version runs first; a missing ffmpeg gives upstream's message saying to install it on PATH." }
      , chan "Ask" "JSON request" "net.fetch POST on a worker thread" "message:Ask" "System prompt = language reference + score context; the key goes in a header only, never into the event log (eventlog redaction)."
      , chan "ToolCommands" "apply_maqam_commands tool call" "channel.Mailbox (one slot)" "message:ToolCommands" "Each command must pass command.parse and the LLM allow-list before any is applied."
      , chan "Answer" "text (bounded by net.max_body)" "channel.Mailbox (one slot)" "message:Answer" "Shown cleaned in the response pane."
      , chan "LlmError" "[]const u8" "channel.Mailbox (one slot)" "message:LlmError" "Missing keys are reported without a network call."
      , chan "Applied" "[]const u8" "App.message" "message:Applied" "All commands applied."
      , chan "RolledBack" "score snapshot restore" "App LLM edit application" "message:RolledBack" "Any failure restores the previous score and resyncs audio."
      , chan "Download" "HTTP GET" "net.download on a worker thread (bounded by net.max_download)" "message:Download" "Streams into <name>.nam.part."
      , chan "ModelBytes" "file bytes" "channel.Mailbox + atomic progress" "message:ModelBytes" "Renamed from .part into the cache when complete."
      , chan "DownloadFailed" "[]const u8" "channel.Mailbox (one slot)" "message:DownloadFailed" "The .part file is removed."
      , { message := "CacheWrite", wireType := "file", transport := .inProcessChannel "std.Io.Dir (cache: MAQAM_NAM_CACHE_DIR or ./.nam)"
        , justifications := why "message:CacheWrite" "Every cache name is sanitized: no separator, '..', NUL or absolute path can leave the cache directory." }
      , chan "NamLoaded" "*nam.Model via AudioCmd.set_nam_model" "channel.Ring(AudioCmd, 512)" "message:NamLoaded" "The model is built off the audio thread and its pointer moved into the engine; the old one comes back as Garbage." ]
  , channels :=
      { sendFunction := "channel.Ring.send"
      , receiveFunction := "channel.Ring.recv"
      , tryReceiveFunction := "channel.Ring.tryRecv"
      , closeFunction := "channel.Ring.close"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
      , justifications := why "resource:App" "Bounded lock-free rings (512 commands to the audio, 1024 garbage back) and one-slot mailboxes per worker keep memory bounded; the audio side only ever uses tryRecv, so it never blocks. channel.zig tests the order, the bound, close and drain." } }

end Project.Implementation
