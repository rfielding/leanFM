import LeanFM.Artifacts

/-!
# maqam-live: implementation mapping (as found in the upstream Rust source)

Each actor and message of `spec/Requirements.lean` is mapped to the Rust that realizes it in
`source/` (upstream revision c80b35d). This records the implementation as it is; where it falls
short of a requirement, the book's "Known gaps" chapter names the requirement, the code and the
counterexample.
-/

namespace Project.Implementation

open LeanFM

def why (id reason : String) : List RequirementJustification := [{ requirementId := id, reason }]
def actor (name typeName file id : String) : ActorCodegen := { actor := name, typeName, sourceFile := file, justifications := why id "Implements the accepted actor role." }
def chan (name wire channel id reason : String) : MessageCodegen := { message := name, wireType := wire, transport := .inProcessChannel channel, justifications := why id reason }

def implementation : ImplementationSpec :=
  { requirementId := "maqam.visible_behavior"
  , target := .rust
  , moduleName := "maqam-live"
  , outputDirectory := "source/"
  , actors :=
      [ actor "Performer" "terminal keyboard (crossterm events)" "source/src/ui.rs" "actor:Performer"
      , actor "App" "app::App (timeline, command dispatch, sessions, workers)" "source/src/app.rs" "actor:App"
      , actor "Audio" "cpal output callback in audio::start_audio (sequencer, voices, VCF bank, FX, sympathetics, NAM)" "source/src/audio.rs" "actor:Audio"
      , actor "Recorder" "record::record_cycle (delegates to record_old.rs) on a spawned thread" "source/src/record_old.rs" "actor:Recorder"
      , actor "Ffmpeg" "nice -n 10 ffmpeg, argv only (no shell)" "source/src/record_old.rs" "actor:Ffmpeg"
      , actor "Llm" "OpenAI chat/completions or Anthropic messages via ureq on a spawned thread" "source/src/app.rs" "actor:Llm"
      , actor "Web" "ureq GET of NAM capture URLs, DuckDuckGo search and the TONE3000 API" "source/src/app.rs" "actor:Web"
      , actor "Disk" "the working directory: .mq sessions, .nam cache, .globals.ml, maqam-<secs>.mp4" "source/src/session_v3.rs" "actor:Disk" ]
  , messages :=
      [ chan "CommandLine" "String" "crossterm key events -> App::handle_command" "message:CommandLine" "One Enter submits one line; ';' splits it into commands."
      , chan "Rejected" "String (\"✗ ...\")" "App::message" "message:Rejected" "Parse and range errors are shown and stop the remaining parts of the line."
      , chan "Shown" "String" "App::message" "message:Shown" "The response pane shows one result string."
      , chan "AudioCmd" "sequencer::AudioCmd" "crossbeam_channel::bounded::<AudioCmd>(512)" "message:AudioCmd" "The App changes its Vec<Phrase> first, then sends the matching AudioCmd; the callback drains with try_recv."
      , chan "Position" "atomics CUR_PHRASE, CUR_SUBDIV, CUR_PLAYS, AUDIO_LATENCY_*_US" "main.rs statics (Relaxed)" "message:Position" "The callback publishes position without locking; the UI reads it every frame."
      , chan "PhraseStart" "synth::spawn_phrase_start" "audio::tick_sequencer" "message:PhraseStart" "A phrase row spawns its voices for each of its repeats."
      , chan "JumpTaken" "JumpSpec counter" "audio::tick_sequencer jump_counters" "message:JumpTaken" "times 0 always jumps; otherwise counter+1 < times jumps back."
      , chan "JumpExhausted" "JumpSpec counter reset" "audio::tick_sequencer jump_counters" "message:JumpExhausted" "The counter resets to 0 and play continues at the else target or the next row."
      , chan "ControlApplied" "PendingControl" "audio::tick_sequencer" "message:ControlApplied" "A control row is applied and the sequencer advances without spending time."
      , chan "SaveSession" "MAQAM_SESSION_V3 text" "session_v3::serialize + std::fs::write" "message:SaveSession" "save writes header, create lines, then one record per row."
      , chan "LoadSession" "path" "App::load_session (std::fs::read_to_string)" "message:LoadSession" "load reads the whole file."
      , chan "SessionText" "String" "App::load_session" "message:SessionText" "The header selects the V3, V2 or V1 loader."
      , chan "SessionError" "io::Error" "App::load_session" "message:SessionError" "A missing or unreadable file is reported."
      , chan "Loaded" "String" "App::message" "message:Loaded" "After loading, Clear, start settings and every entry are sent to the audio."
      , chan "LoadFailed" "String (\"line N: ...\")" "App::message" "message:LoadFailed" "Errors name the line."
      , chan "Render" "phrases + sequence_start_settings" "std::thread::spawn -> record::record_cycle" "message:Render" "Rendering runs off the audio callback."
      , chan "Encode" "ffmpeg argv" "std::process::Command (nice -n 10 ffmpeg ...)" "message:Encode" "libx264 veryfast -threads 1 so live audio keeps scheduling room."
      , chan "Encoded" "exit status 0" "std::process::Child" "message:Encoded" "The staged .partial.mp4 is renamed into place."
      , chan "EncodeFailed" "exit status and maqam-ffmpeg.log" "std::process::Child" "message:EncodeFailed" "One retry without subtitles; then the staged file is removed."
      , chan "WriteMp4" "./maqam-<unix_secs>.mp4" "std::fs::rename" "message:WriteMp4" "Written in the working directory."
      , chan "RecordSaved" "Result<String,String>" "crossbeam bounded(1)" "message:RecordSaved" "Polled by App::tick."
      , { message := "RecordFailed", wireType := "Result<String,String>", transport := .inProcessChannel "crossbeam bounded(1)"
        , justifications := why "message:RecordFailed" "Polled by App::tick." ++ why "proof:Possibly an external tool is missing" "ensure_ffmpeg_available runs ffmpeg -version first and returns a message saying to install ffmpeg on PATH." }
      , chan "Ask" "JSON request" "ureq POST on a spawned thread (30 s timeout)" "message:Ask" "System prompt = language reference + score context; the key goes in a header only."
      , chan "ToolCommands" "apply_maqam_commands tool call" "crossbeam bounded(1)" "message:ToolCommands" "Each command must pass command::parse and llm_edit_command_allowed before any is applied."
      , chan "Answer" "text" "crossbeam bounded(1)" "message:Answer" "Shown cleaned in the response pane."
      , chan "LlmError" "String" "crossbeam bounded(1)" "message:LlmError" "Missing keys are reported without a network call."
      , chan "Applied" "String" "App::message" "message:Applied" "All commands applied."
      , chan "RolledBack" "ScoreSnapshot restore" "App::apply_llm_edit_commands" "message:RolledBack" "Any failure restores the previous score and resyncs audio."
      , chan "Download" "HTTP GET" "ureq on a spawned thread (120 s timeout)" "message:Download" "Streams 64 KiB chunks into <name>.nam.part."
      , chan "ModelBytes" "file bytes" "crossbeam bounded(1) progress + result" "message:ModelBytes" "Renamed from .part into the cache when complete."
      , chan "DownloadFailed" "String" "crossbeam bounded(1)" "message:DownloadFailed" "The .part file is removed."
      , chan "CacheWrite" "file" "std::fs (cache: MAQAM_NAM_CACHE_DIR or ./.nam)" "message:CacheWrite" "Names pass sanitize_nam_cache_name on the interactive paths."
      , chan "NamLoaded" "nam_rs::Model via AudioCmd::SetNamModel" "crossbeam bounded(512)" "message:NamLoaded" "The model is built off the callback and moved into it." ]
  , channels :=
      { sendFunction := "crossbeam_channel::Sender::send"
      , receiveFunction := "crossbeam_channel::Receiver::recv"
      , tryReceiveFunction := "crossbeam_channel::Receiver::try_recv"
      , closeFunction := "drop(Sender)"
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
      , justifications := why "resource:App" "Bounded channels (512 commands to audio, 1 result per worker) keep memory bounded; the audio side only ever uses try_recv, so it never blocks." } }


end Project.Implementation
