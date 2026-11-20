import LeanFM.Artifacts

open LeanFM

/-!
# maqam-live: observable requirements (reverse-engineered)

Distilled from the upstream source at revision c80b35d (`manifest.json` upstream_revision) and
its README, CODE.md, CRITIQUE.md and docs. Each requirement states what a performer, a session
file, a recording or a remote service can observe. Where the code disagrees with its documents,
the code is what is required here and the disagreement is recorded in the markdown section
`doc-disagreements`; where the code breaks a forbidden behavior, the requirement still forbids
it and the book's "Known gaps" chapter carries the counterexample.

The session-type view of the same system is `spec/Maqam.leanfm` (protocol MaqamLive).
-/

namespace Project.Requirements

def protoSource : String := include_str "Requirements.proto"
def framing : MessageFraming := { kind := .protobufMessage, dispatchField := some "kind", note := "In-process values (bounded channels and atomics in each implementation); the protobuf is their typed description, not a wire." }
def field (n : Nat) (name : String) (scalar : ProtoScalar) : ProtoFieldSchema := { number := n, name, scalar }
def message (name src dst : String) (fields : List ProtoFieldSchema) : MessageSchema := { name, src, dst, framing, fields }

def messages : List MessageSchema :=
  [ message "CommandLine" "Performer" "App" [field 1 "line" .string]
  , message "Rejected" "App" "Performer" [field 1 "reason" .string]
  , message "Shown" "App" "Performer" [field 1 "message" .string]
  , message "AudioCmd" "App" "Audio" [field 1 "kind" .string, field 2 "entry_id" .uint64, field 3 "source" .string]
  , message "Position" "Audio" "App" [field 1 "phrase_id" .uint64, field 2 "subdivision" .uint32, field 3 "plays" .uint32, field 4 "latency_us" .uint64]
  , message "PhraseStart" "Audio" "Audio" [field 1 "entry_id" .uint64, field 2 "repeat" .uint32]
  , message "JumpTaken" "Audio" "Audio" [field 1 "entry_id" .uint64, field 2 "target_id" .uint64, field 3 "pass" .uint32]
  , message "JumpExhausted" "Audio" "Audio" [field 1 "entry_id" .uint64, field 2 "next_id" .uint64]
  , message "ControlApplied" "Audio" "Audio" [field 1 "entry_id" .uint64, field 2 "control" .string]
  , message "SaveSession" "App" "Disk" [field 1 "path" .string, field 2 "text" .string]
  , message "LoadSession" "App" "Disk" [field 1 "path" .string]
  , message "SessionText" "Disk" "App" [field 1 "text" .string]
  , message "SessionError" "Disk" "App" [field 1 "reason" .string]
  , message "Loaded" "App" "Performer" [field 1 "path" .string, field 2 "entries" .uint32]
  , message "LoadFailed" "App" "Performer" [field 1 "line" .uint32, field 2 "reason" .string]
  , message "Render" "App" "Recorder" [field 1 "cycles" .uint32]
  , message "Encode" "Recorder" "Ffmpeg" [field 1 "wav" .string, field 2 "staged" .string]
  , message "Encoded" "Ffmpeg" "Recorder" [field 1 "staged" .string]
  , message "EncodeFailed" "Ffmpeg" "Recorder" [field 1 "log" .string]
  , message "WriteMp4" "Recorder" "Disk" [field 1 "path" .string]
  , message "RecordSaved" "Recorder" "App" [field 1 "path" .string]
  , message "RecordFailed" "Recorder" "App" [field 1 "reason" .string]
  , message "Ask" "App" "Llm" [field 1 "provider" .string, field 2 "prompt" .string, field 3 "score" .string]
  , message "ToolCommands" "Llm" "App" [field 1 "commands" .string]
  , message "Answer" "Llm" "App" [field 1 "text" .string]
  , message "LlmError" "Llm" "App" [field 1 "reason" .string]
  , message "Applied" "App" "Performer" [field 1 "count" .uint32]
  , message "RolledBack" "App" "Performer" [field 1 "reason" .string]
  , message "Download" "App" "Web" [field 1 "url" .string, field 2 "name" .string]
  , message "ModelBytes" "Web" "App" [field 1 "name" .string, field 2 "bytes" .uint64]
  , message "DownloadFailed" "Web" "App" [field 1 "reason" .string]
  , message "CacheWrite" "App" "Disk" [field 1 "name" .string]
  , message "NamLoaded" "App" "Performer" [field 1 "name" .string, field 2 "sample_rate" .uint32]
  ]

def state (id label group : String) (terminal : Bool := false) : RequirementState := { id, label, group, markdown := label, terminal }
def transition (src dst msg : String) (ms : Nat := 1) : RequirementTransition := { src, dst, message := msg, probabilityNum := 1, probabilityDen := 1, dwellMs := ms }
def atom (task src dst msg : String) : GrammarExpr := .event { task, src, dst, message := msg }
def alt (a b : GrammarExpr) : GrammarExpr := .choice [a, b]

/-- A command line: parsed by the App; a parse or range error is shown and changes nothing,
otherwise the App changes its authoritative timeline first and then tells the audio. -/
def editTask : TaskRequirement :=
  { id := "live_edit", title := "Edit the live timeline", actors := ["Performer", "App", "Audio"], initialState := "typing"
  , states := [state "typing" "command box" "tui", state "parsed" "command parsed" "app", state "applied" "timeline updated, audio told" "audio", state "shown" "result shown" "terminal" true, state "rejected" "error shown, nothing changed" "terminal" true]
  , transitions := [transition "typing" "parsed" "CommandLine", transition "parsed" "applied" "AudioCmd", transition "applied" "shown" "Shown", transition "parsed" "rejected" "Rejected"] }

def editGrammar : TaskGrammar :=
  { task := "live_edit", entry := "typing", terminals := ["shown", "rejected"]
  , body := .seq (atom "live_edit" "Performer" "App" "CommandLine")
      (alt (.seq (atom "live_edit" "App" "Audio" "AudioCmd") (atom "live_edit" "App" "Performer" "Shown"))
        (atom "live_edit" "App" "Performer" "Rejected")) }

/-- The audio callback walks the timeline: a phrase plays its repeats, a control entry applies
in no time, a jump row counts passes, and the end wraps to the first row. -/
def playTask : TaskRequirement :=
  { id := "timeline_playback", title := "Play the timeline", actors := ["Audio", "App"], initialState := "at_row"
  , states := [state "at_row" "at a timeline row" "sequencer", state "playing" "phrase playing" "sequencer", state "reported" "position published" "terminal" true]
  , transitions := [transition "at_row" "playing" "PhraseStart", transition "at_row" "at_row" "ControlApplied", transition "at_row" "at_row" "JumpTaken", transition "at_row" "at_row" "JumpExhausted", transition "playing" "reported" "Position"] }

def playGrammar : TaskGrammar :=
  { task := "timeline_playback", entry := "at_row", terminals := ["reported"]
  , body := .seq (.repeat (alt (atom "timeline_playback" "Audio" "Audio" "ControlApplied")
        (alt (atom "timeline_playback" "Audio" "Audio" "JumpTaken") (atom "timeline_playback" "Audio" "Audio" "JumpExhausted"))))
      (.seq (atom "timeline_playback" "Audio" "Audio" "PhraseStart") (atom "timeline_playback" "Audio" "App" "Position")) }

def saveTask : TaskRequirement :=
  { id := "session_save_load", title := "Save and load a MAQAM_SESSION_V3 file", actors := ["Performer", "App", "Disk", "Audio"], initialState := "asked"
  , states := [state "asked" "save or load typed" "app", state "reading" "file requested" "disk", state "text" "text read" "app", state "resynced" "audio rebuilt from the timeline" "audio", state "loaded" "loaded" "terminal" true, state "failed" "load failed with line number" "terminal" true]
  , transitions := [transition "asked" "reading" "LoadSession", transition "reading" "text" "SessionText", transition "text" "resynced" "AudioCmd", transition "resynced" "loaded" "Loaded", transition "reading" "failed" "SessionError", transition "text" "failed" "LoadFailed"] }

def saveGrammar : TaskGrammar :=
  { task := "session_save_load", entry := "asked", terminals := ["loaded", "failed"]
  , body := .seq (atom "session_save_load" "App" "Disk" "LoadSession")
      (alt (.seq (atom "session_save_load" "Disk" "App" "SessionText")
          (alt (.seq (atom "session_save_load" "App" "Audio" "AudioCmd") (atom "session_save_load" "App" "Performer" "Loaded"))
            (atom "session_save_load" "App" "Performer" "LoadFailed")))
        (atom "session_save_load" "Disk" "App" "SessionError")) }

def recordTask : TaskRequirement :=
  { id := "record_mp4", title := "Record cycles to an MP4", actors := ["App", "Recorder", "Ffmpeg"], initialState := "requested"
  , states := [state "requested" "render requested" "app", state "rendering" "offline render" "recorder", state "encoding" "ffmpeg running" "ffmpeg", state "written" "mp4 renamed into place" "disk", state "saved" "path shown" "terminal" true, state "failed" "error shown" "terminal" true]
  , transitions := [transition "requested" "rendering" "Render", transition "rendering" "encoding" "Encode", transition "encoding" "written" "Encoded", transition "written" "saved" "RecordSaved", transition "encoding" "failed" "EncodeFailed", transition "rendering" "failed" "RecordFailed"] }

def recordGrammar : TaskGrammar :=
  { task := "record_mp4", entry := "requested", terminals := ["saved", "failed"]
  , body := .seq (atom "record_mp4" "App" "Recorder" "Render")
      (alt (.seq (atom "record_mp4" "Recorder" "Ffmpeg" "Encode")
          (alt (.seq (atom "record_mp4" "Ffmpeg" "Recorder" "Encoded") (atom "record_mp4" "Recorder" "App" "RecordSaved"))
            (atom "record_mp4" "Ffmpeg" "Recorder" "EncodeFailed")))
        (atom "record_mp4" "Recorder" "App" "RecordFailed")) }

def llmTask : TaskRequirement :=
  { id := "llm_edit", title := "Edit the score through an LLM", actors := ["Performer", "App", "Llm"], initialState := "prompted"
  , states := [state "prompted" "chatgpt: or claude: typed" "app", state "asked" "request in flight" "llm", state "checked" "every command parsed and allowed" "app", state "applied" "applied" "terminal" true, state "rolled_back" "restored the previous score" "terminal" true, state "answered" "answer shown" "terminal" true, state "failed" "error shown" "terminal" true]
  , transitions := [transition "prompted" "asked" "Ask", transition "asked" "checked" "ToolCommands", transition "checked" "applied" "Applied", transition "checked" "rolled_back" "RolledBack", transition "asked" "answered" "Answer", transition "asked" "failed" "LlmError"] }

def llmGrammar : TaskGrammar :=
  { task := "llm_edit", entry := "prompted", terminals := ["applied", "rolled_back", "answered", "failed"]
  , body := .seq (atom "llm_edit" "App" "Llm" "Ask")
      (alt (.seq (atom "llm_edit" "Llm" "App" "ToolCommands")
          (alt (atom "llm_edit" "App" "Performer" "Applied") (atom "llm_edit" "App" "Performer" "RolledBack")))
        (alt (atom "llm_edit" "Llm" "App" "Answer") (atom "llm_edit" "Llm" "App" "LlmError"))) }

def namTask : TaskRequirement :=
  { id := "nam_fetch", title := "Fetch and load a NAM capture", actors := ["Performer", "App", "Web"], initialState := "requested"
  , states := [state "requested" "nam import/pin/tone3000" "app", state "downloading" "download in flight" "web", state "cached" "written into the cache" "disk", state "loaded" "model on the live input" "terminal" true, state "failed" "error shown" "terminal" true]
  , transitions := [transition "requested" "downloading" "Download", transition "downloading" "cached" "ModelBytes", transition "cached" "loaded" "NamLoaded", transition "downloading" "failed" "DownloadFailed"] }

def namGrammar : TaskGrammar :=
  { task := "nam_fetch", entry := "requested", terminals := ["loaded", "failed"]
  , body := .seq (atom "nam_fetch" "App" "Web" "Download")
      (alt (.seq (atom "nam_fetch" "Web" "App" "ModelBytes") (atom "nam_fetch" "App" "Performer" "NamLoaded"))
        (atom "nam_fetch" "Web" "App" "DownloadFailed")) }

def process (actor task : String) (sends receives : List String) : RequirementProcess :=
  let states := match task with
    | "live_edit" => ["typing", "parsed", "applied", "shown", "rejected"]
    | "timeline_playback" => ["at_row", "playing", "reported"]
    | "session_save_load" => ["asked", "reading", "text", "resynced", "loaded", "failed"]
    | "record_mp4" => ["requested", "rendering", "encoding", "written", "saved", "failed"]
    | "llm_edit" => ["prompted", "asked", "checked", "applied", "rolled_back", "answered", "failed"]
    | _ => ["requested", "downloading", "cached", "loaded", "failed"]
  { actor, task, states, sends, receives }

def processes : List RequirementProcess :=
  [ process "Performer" "live_edit" ["CommandLine"] ["Shown", "Rejected"]
  , process "App" "live_edit" ["AudioCmd", "Shown", "Rejected"] ["CommandLine"]
  , process "Audio" "live_edit" [] ["AudioCmd"]
  , process "Audio" "timeline_playback" ["PhraseStart", "ControlApplied", "JumpTaken", "JumpExhausted", "Position"] ["PhraseStart", "ControlApplied", "JumpTaken", "JumpExhausted"]
  , process "App" "timeline_playback" [] ["Position"]
  , process "App" "session_save_load" ["LoadSession", "AudioCmd", "Loaded", "LoadFailed"] ["SessionText", "SessionError"]
  , process "Disk" "session_save_load" ["SessionText", "SessionError"] ["LoadSession"]
  , process "Audio" "session_save_load" [] ["AudioCmd"]
  , process "Performer" "session_save_load" [] ["Loaded", "LoadFailed"]
  , process "App" "record_mp4" ["Render"] ["RecordSaved", "RecordFailed"]
  , process "Recorder" "record_mp4" ["Encode", "RecordSaved", "RecordFailed"] ["Render", "Encoded", "EncodeFailed"]
  , process "Ffmpeg" "record_mp4" ["Encoded", "EncodeFailed"] ["Encode"]
  , process "App" "llm_edit" ["Ask", "Applied", "RolledBack"] ["ToolCommands", "Answer", "LlmError"]
  , process "Llm" "llm_edit" ["ToolCommands", "Answer", "LlmError"] ["Ask"]
  , process "Performer" "llm_edit" [] ["Applied", "RolledBack"]
  , process "App" "nam_fetch" ["Download", "NamLoaded"] ["ModelBytes", "DownloadFailed"]
  , process "Web" "nam_fetch" ["ModelBytes", "DownloadFailed"] ["Download"]
  , process "Performer" "nam_fetch" [] ["NamLoaded"]
 ]

def outputs : List DesiredOutput :=
  [ { id := "maqam.live.interaction", prompt := "Reverse-engineer maqam and show how it works.", question := "Which threads exchange what when the performer types, records, asks an LLM or loads a NAM capture?", kind := .interactionDiagram, eventSource := "spec/Maqam.leanfm protocol MaqamLive", reducer := "LeanFM session_check sequence diagram with calls folded", unit := "messages" }
  , { id := "maqam.edit.state_machine", prompt := "Show what a command line does.", question := "Which outcomes can one command line have?", kind := .stateMachine, eventSource := "live_edit grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "maqam.playback.state_machine", prompt := "Show how the timeline plays.", question := "How do phrases, controls and jumps advance the sequencer?", kind := .stateMachine, eventSource := "timeline_playback grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "maqam.record.state_machine", prompt := "Show recording.", question := "Where can a recording fail?", kind := .stateMachine, eventSource := "record_mp4 grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "maqam.llm.state_machine", prompt := "Show LLM editing.", question := "When is an LLM edit applied and when is it rolled back?", kind := .stateMachine, eventSource := "llm_edit grammar", reducer := "render grammar residuals", unit := "states and transitions" }
  , { id := "maqam.signal_chain", prompt := "Show the bus and effects order.", question := "In which order is live input, the voices, the sympathetic strings, the filters and the effects mixed?", kind := .interactionDiagram, eventSource := "the audio output path's mix loop, which each implementation's mapping names (actor Audio)", reducer := "one node per processing stage in callback order", unit := "processing stages" }
  , { id := "maqam.test_outcomes", prompt := "Run each implementation's tests.", question := "How many of each implementation's tests pass?", kind := .scalar, eventSource := "make -C impl/<name>/source check, for each implementation manifest.json lists", reducer := "count passed, failed and ignored per implementation", unit := "tests" } ]

def requirements : RequirementSpec :=
  { id := "maqam.visible_behavior", title := "maqam-live: live-coding terminal sequencer for just-intonation maqam"
  , actors := ["Performer", "App", "Audio", "Recorder", "Ffmpeg", "Llm", "Web", "Disk"]
  , actorPopulations :=
      [ {actorSpec := "Performer", instancePrefix := "performer-", count := 1, routing := .roundRobin}
      , {actorSpec := "App", instancePrefix := "app-", count := 1, routing := .roundRobin}
      , {actorSpec := "Audio", instancePrefix := "audio-", count := 1, routing := .roundRobin}
      , {actorSpec := "Recorder", instancePrefix := "recorder-", count := 1, routing := .roundRobin}
      , {actorSpec := "Ffmpeg", instancePrefix := "ffmpeg-", count := 1, routing := .roundRobin}
      , {actorSpec := "Llm", instancePrefix := "llm-", count := 2, routing := .sticky "provider"}
      , {actorSpec := "Web", instancePrefix := "web-", count := 1, routing := .roundRobin}
      , {actorSpec := "Disk", instancePrefix := "disk-", count := 1, routing := .roundRobin} ]
  , actorResources :=
      [ {actor := "Performer", inboundCapacity := 1, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 4096}
      , {actor := "App", inboundCapacity := 1, outboundCapacity := 512, maxInFlight := 1, memoryBudgetBytes := 268435456}
      , {actor := "Audio", inboundCapacity := 512, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 67108864}
      , {actor := "Recorder", inboundCapacity := 1, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 1073741824}
      , {actor := "Ffmpeg", inboundCapacity := 1, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 536870912}
      , {actor := "Llm", inboundCapacity := 1, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 10485760}
      , {actor := "Web", inboundCapacity := 1, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 10485760}
      , {actor := "Disk", inboundCapacity := 1, outboundCapacity := 1, maxInFlight := 1, memoryBudgetBytes := 1048576} ]
  , actorReliability :=
      [ {actor := "Ffmpeg", outageProbability := {numerator := 1, denominator := 100}, meanTimeToRepairMs := 60000}
      , {actor := "Llm", outageProbability := {numerator := 1, denominator := 100}, meanTimeToRepairMs := 30000}
      , {actor := "Web", outageProbability := {numerator := 1, denominator := 100}, meanTimeToRepairMs := 120000} ]
  , reliabilityGates := []
  , actorCosts := [], messages
  , tasks := [editTask, playTask, saveTask, recordTask, llmTask, namTask]
  , grammars := [editGrammar, playGrammar, saveGrammar, recordGrammar, llmGrammar, namGrammar]
  , processes
  , properties :=
      [ {name := "A rejected command changes nothing", mode := .never, task := "live_edit", expression := "Rejected and an AudioCmd for the same command line", probability := some {numerator := 0, denominator := 1}}
      , {name := "Timeline first, audio second", mode := .always, task := "live_edit", expression := "every AudioCmd follows the App's change to its own timeline for that command", probability := some {numerator := 1, denominator := 1}}
      , {name := "Entry ids are stable", mode := .always, task := "live_edit", expression := "insert, delete, move and rotate never renumber an existing entry id; jumps name ids, not positions", probability := some {numerator := 1, denominator := 1}}
      , {name := "Jump passes", mode := .always, task := "timeline_playback", expression := "j X N passes the jump row N times: N-1 JumpTaken then one JumpExhausted that resets its counter; times 0 (always) never exhausts", probability := some {numerator := 1, denominator := 1}}
      , {name := "Controls take no time", mode := .always, task := "timeline_playback", expression := "ControlApplied advances to the next row without a PhraseStart in between", probability := some {numerator := 1, denominator := 1}}
      , {name := "Just intonation", mode := .always, task := "timeline_playback", expression := "every phrase frequency is root(snapped to the oud lattice) times a ratio p/q of its jins", probability := some {numerator := 1, denominator := 1}}
      , {name := "Session round trip", mode := .always, task := "session_save_load", expression := "load(save(timeline)) has the same entries, ids, sources and custom jins; vol and tuneto are never in the session", probability := some {numerator := 1, denominator := 1}}
      , {name := "LLM commands are checked before any is applied", mode := .always, task := "llm_edit", expression := "Applied only when every returned command parses and is on the allowlist; otherwise none is applied", probability := some {numerator := 1, denominator := 1}}
      , {name := "The LLM never saves, loads, records or plays", mode := .never, task := "llm_edit", expression := "an LLM-returned save, load, m, q, z, pause, start, clockin, clockout, help, ls, audition, clear, vol or tuneto command applied", probability := some {numerator := 0, denominator := 1}}
      , {name := "A download is cached before it is loaded", mode := .always, task := "nam_fetch", expression := "NamLoaded follows ModelBytes renamed from its .part file into the cache", probability := some {numerator := 1, denominator := 1}}
  , {name := "Every implementation logs the same protocol", mode := .always, task := "timeline_playback", expression := "with MAQAM_EVENT_LOG set, every message of protocol MaqamLive (spec/Maqam.leanfm) the app takes part in is appended to the event log once, in the order it happens, and the log conforms to MaqamLive (session_conform)", probability := some {numerator := 1, denominator := 1}}
  , {name := "Renders are deterministic", mode := .always, task := "record_mp4", expression := "the offline render (--render) of one session, cycle count and sample rate writes the same samples on every run", probability := some {numerator := 1, denominator := 1}}
  , {name := "A failed recording leaves no partial mp4", mode := .never, task := "record_mp4", expression := "RecordFailed and a ./maqam-<secs>.mp4 or .partial.mp4 left by that render", probability := some {numerator := 0, denominator := 1}}
  , {name := "Every block is on time", mode := .always, task := "timeline_playback", expression := "in protocol AudioPeriod (spec/AudioPeriod.leanfm) every Pull reaches Played: block k of 64 frames at 48 kHz is released by the device at t0 + k * 64/48000 s and handed over before its release plus one period (1333.3 us); the wake-up delay counts as well as the rendering, every block counts (the maximum, never a percentile or an average), and an eventual Block after the period is not on time", probability := some {numerator := 1, denominator := 1}} ]
  , requiredProofs :=
      [ {name := "The audio callback never blocks", mode := .never, task := "timeline_playback", predicate := "a blocking lock, channel send, file or network operation inside the output callback (try_recv and try_lock only)", probability := some {numerator := 0, denominator := 1}}
      , {name := "Output is bounded", mode := .always, task := "timeline_playback", predicate := "every output sample is in [-1, 1] after soft clipping and the final clamp", probability := some {numerator := 1, denominator := 1}}
      , {name := "No input crashes the app", mode := .never, task := "live_edit", predicate := "a command line, session line or scraped page that makes maqam-live panic", probability := some {numerator := 0, denominator := 1}, handlingPlan := some "Counterexample known in impl/rust: create X 1/1 then d x panics in build_phrase (clamp min > max); see Known gaps. impl/zig rejects it."}
      , {name := "Secrets stay out of files, scores and prompts", mode := .never, task := "llm_edit", predicate := "an API key or TONE3000 token in a .mq file, the TUI, the LLM context, a recording or a log", probability := some {numerator := 0, denominator := 1}}
      , {name := "Cache writes stay in the cache", mode := .never, task := "nam_fetch", predicate := "a NAM capture or .part file written outside the cache directory", probability := some {numerator := 0, denominator := 1}, handlingPlan := some "Counterexample known in impl/rust: a nam tone3000 name from a loaded .mq is not sanitized before cache_dir.join; see Known gaps. impl/zig sanitizes every cache name."}
      , {name := "Tests do not reach out", mode := .never, task := "nam_fetch", predicate := "an implementation's tests (make check in its source directory) opening a browser or making a network request", probability := some {numerator := 0, denominator := 1}, handlingPlan := some "Counterexample known in impl/rust: loading bundled nama2.mq in a test starts TONE3000 login and runs xdg-open; see Known gaps."}
      , {name := "No missed audio deadline", mode := .never, task := "timeline_playback", predicate := "a Skipped block in protocol AudioPeriod: a 64-frame block at 48 kHz handed to the device after its release plus one period (1.333 ms), the wake-up delay included, while a NAM A2 capture, the sympathetic strings and the reverb all run on the live input", probability := some {numerator := 0, denominator := 1}, handlingPlan := some "Counterexample known in impl/rust: the reverb stutters at 64-frame buffers (Known gaps). Every implementation's bench releases blocks on the period grid and writes the AudioPeriod stream; make compare checks every block of it, exactly, and its conformance to AudioPeriod."}
      , {name := "The audio thread never waits on the kernel", mode := .never, task := "timeline_playback", predicate := "a page fault inside the output callback (memory first touched there), or the audio thread running at normal priority when the machine allows real-time scheduling (the kernel may then preempt it for longer than a period)", probability := some {numerator := 0, denominator := 1}, handlingPlan := some "Lock every mapping in RAM (mlockall, current and future) and ask for real-time scheduling (SCHED_FIFO, else RealtimeKit) once, in the audio thread, before its loop; the bench reports realtime and memory_locked."}
      , {name := "A buffer skip is never silent", mode := .never, task := "timeline_playback", predicate := "an underrun of the live output device (the driver reports that it ran out of samples) that the app recovers from without counting it and showing the count in the terminal header", probability := some {numerator := 0, denominator := 1}}
  , {name := "The event log carries only declared fields", mode := .never, task := "llm_edit", predicate := "an event log line holding a secret (API key, TONE3000 token), a field its protocol message does not declare, or anything when MAQAM_EVENT_LOG is unset", probability := some {numerator := 0, denominator := 1}}
  , {name := "Implementations stand alone", mode := .never, task := "record_mp4", predicate := "building, testing or running one implementation reading, building or linking anything under another implementation's directory (impl/<other>/), or needing another language's toolchain", probability := some {numerator := 0, denominator := 1}, handlingPlan := some "Each impl/<name>/source has its own Makefile (check, render, bench) using only its own toolchain and system libraries; shared inputs are the session files and the specification."}
  , {name := "Possibly an external tool is missing", mode := .possibly, task := "record_mp4", predicate := "ffmpeg absent from PATH", probability := some {numerator := 1, denominator := 100}, handlingPlan := some "Check ffmpeg -version first and say exactly what to install."} ]
  , performance := [{name := "edit to audible change", task := "live_edit", metric := .clientExperiencedRate, workField := "applied_commands", minimumWork := 1, perMilliseconds := 100}]
  , charts := [{name := "unit test outcomes", kind := .pie, source := "each implementation's make check test summary", groupBy := some "outcome", value := "count"}]
  , desiredOutputs := outputs
  , markdown :=
      [ {id := "comparison", title := "Observable hooks every implementation provides", body := "These make implementations of this specification comparable; they are behavior, so every implementation provides them the same way. Event log: with MAQAM_EVENT_LOG=<path> the app appends one JSON object per line for each message of protocol MaqamLive it takes part in: {ts, session, from, to, label, cause, fields}, ts in nanoseconds from one monotonic clock of the machine, label the protocol's message name, cause the ts of the event the protocol names as its cause, fields only those the message declares with integers as decimal strings; unset, nothing is written. Offline render: maqam-live --render <session.mq> --cycles <n> --rate <hz> --wav <out.wav> renders the session without opening audio devices or the TUI, writes 32-bit float mono WAV and exits 0, the same samples on every run. Bench: maqam-live --bench <session.mq> --seconds <s> --frames 64 --rate 48000 [--nam <capture.nam>] [--period-log <path>] runs the live audio path against a null device with the sympathetic strings and the reverb on. The null device is the clock: it releases block k at t0 + k * frames/rate, the bench waits for each release (it never starts a block early, and a late block delays nothing after it), and times each block from its release to its hand-over. It runs the timed loop the way the live audio thread runs: with real-time scheduling and every page of memory locked in RAM when the machine allows them, and says which it got. It prints one JSON line {frames, rate, callbacks, deadline_misses, callback_p50_us, callback_p99_us, callback_max_us, release_late_max_us, slack_min_us, realtime, memory_locked}: callback times are release to hand-over, deadline_misses the blocks handed over after release plus one period, release_late_max_us the longest wait between a release and the start of its block, slack_min_us the period minus the longest callback (negative when a block was late), realtime the scheduling the timed thread got (fifo, rtkit or none) and memory_locked whether every mapping was locked first. With --period-log it also writes, after the run, the stream of protocol AudioPeriod (spec/AudioPeriod.leanfm), one session per block named by its index, in the event log's JSON format."}
      , {id := "grammar", title := "Command language", body := "A line is split on ';' (no escaping). clockin/clockout are taken before the parser. A line whose text before the first ':' is chatgpt|gpt|openai|claude|anthropic is an LLM prompt. Otherwise: q|quit, ?|help, clear, rot, stop, start, pause, m[N], z [id|start], j <id|start> [times|always], j <ok> else <fail> [times], i <id> <cmd>, edit <id> <cmd>, x <id>..., up/down <id>, bpm, s|sus, vol, tuneto, vcf/cut/res/drive, flanger/chorus/reverb/delay/pingpong/fx off, sym..., nam..., save [path], load <path>, ls, audition, create <Name> <p/q>..., delete <Name>, and otherwise a phrase: <root> <jins> [rhythm] [, <root> <jins> [rhythm]] [rN|N<=20]. Values may be absolute, +n, -n, *k, /k or a per-tick step nt; +0 stops a tick."}
      , {id := "ranges", title := "Ranges", body := "bpm 20..400 (default 120 in the audio thread); sustain 0.05..10 s (default 1.25); vol 0..2; vcf cutoff 10..22000 Hz (and at most 0.45 of the sample rate), resonance 0..0.98, drive 0.1..12; flanger rate 0.01..8 Hz, depth 0..1, delay 0.1..10 ms, feedback -0.95..0.95, mix 0..1; chorus delay 5..35 ms; reverb decay 0..0.98; delay time 0.01..2 s, feedback 0..0.95; sym decay 0.9..0.99999 per ms (default 0.999), gain 0..512 (default 2), interval ratio 1/4..4, at most 8 harmony intervals; nam gain 0..11. A value out of range is rejected with a message naming the range."}
      , {id := "timing", title := "Timing and tuning", body := "One rhythm digit unit is an eighth note: 60/(bpm*2) s. In each group the first subdivision is a kick and the rest snares. Roots are snapped to the D-based oud lattice (D4 = 293.6648 Hz); tuneto <pitch> rebases the lattice so that pitch sounds at its 12-TET frequency (A4 = 440)."}
      , {id := "session", title := "MAQAM_SESSION_V3", body := "Header line, then create lines for custom jins, then one record per timeline row in order: P|id|repeat|src, J|id|target|times or J|id|target|fail|times, B|id|bpm, S|id|sustain, V|id|vcf, F|id|fx, N|id|nam, Y|id|sym, T|id|stop, with \\, | and newline escaped. V1 and V2 files load with sequential ids. vol and tuneto live in .globals.ml (MAQAM_GLOBALS_PATH), never in a session."}
      , {id := "implementations", title := "Implementations", body := "One specification, several implementations (manifest.json implementations): impl/rust/source is the upstream Rust (the reference the requirements were distilled from) and impl/zig/source a port in Zig. Each builds, tests and runs from its own directory with its own toolchain and system libraries only (Rust: cargo; Zig: zig 0.17 and ALSA), and each offers make check, render and bench there. Behavior the requirements fix (commands, messages, session files, ranges, the event log, the render and bench hooks) is the same in each; how each is built is its own."}
      , {id := "doc-disagreements", title := "Where the documents and the code disagree", body := "In the upstream Rust these hold, and they are required of every implementation: recording does not reuse the live path: it has its own mix loop at a fixed 44.1 kHz without the sympathetic strings, NAM, mic or vol, peak-normalizes to 0.9 and assumes 0.25 s subdivisions when spawning voices. NAM rows are saved (N|) although CODE.md and buses-effects-order.md call NAM live state. docs/session-v3.md lists only B, S, P, J, T. Reverb uses two of its four taps. Upstream only: osc.rs, midi.rs, renderer.rs and source_background.rs are not used. The NAM gain range is 0..11 in the parser but 0..8 in its help text. README writes Saba's endpoint as 80/64 (the code says 5/4)."}
      , {id := "bounds", title := "Bounds", body := "The app-to-audio channel holds 512 commands, the input queue 16384 frames; at most 8 harmony intervals and 64 sympathetic targets. Not bounded upstream (see Known gaps): timeline length, phrase repeats, jump times, the recording buffer, LLM history, NAM download size."} ] }

def validationReport : String := match validateRequirementSpec requirements with | [] => "ok: maqam requirements are well formed\n" | es => "invalid maqam requirements\n" ++ joinWithNewline es ++ "\n"

end Project.Requirements
