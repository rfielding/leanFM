//! Port of maqam-live `src/app.rs`: the App (the TUI and main thread of protocol MaqamLive,
//! spec/Maqam.leanfm). It owns the authoritative timeline, parses and dispatches command lines
//! (`handleCommand`), edits the timeline (insert, edit, delete, move, rotate, jumps and control
//! rows), manages the jins registry commands, saves and loads MAQAM_SESSION_V3 files (the parsing
//! itself is session.zig), keeps vol and tuneto in the globals file, records on a worker thread,
//! asks ChatGPT or Claude (answers and tool-call edits that are checked, then applied or rolled
//! back), and runs every NAM command (load, import, pin, TONE3000 login / download, search, list,
//! gain, input, latency). Every message text is the Rust's.
//!
//! Threads: recording, LLM requests, NAM downloads and the TONE3000 login each run on a std.Thread
//! and answer on a one-slot `channel.Mailbox` polled in `tick` (the Rust bounded(1) channels).
//! A worker the App no longer wants (a load replaced the score's NAM dependencies) is abandoned:
//! its result is freed when it arrives and the thread is joined then. Audio commands go to the
//! audio side on the lock-free command ring; whatever the audio side hands back on the garbage
//! ring is freed in `tick` (and while waiting for room on a full command ring).
//!
//! Event log (property "Every implementation logs the same protocol"): each command-line part is
//! one interaction of MaqamLive's Live loop. Its first message decides the branch: Prompt (an LLM
//! request that was sent), Session (save / load), Record (a recording that was started), Fetch (a
//! NAM download that was started), Quit, or else Command with Shown / Rejected at its end. Every
//! audio command sent inside an interaction is one derived session ("<id>.<k>"): Phrase in an edit
//! (with Position from Audio to App when Shared.phrase_starts next advances, polled in `tick`),
//! Resync in a load, Apply in an LLM edit or its rollback, NamModel after a download, Stop on
//! quit. Worker results are logged when `tick` receives them (Saved / RenderFailed, Commands /
//! Answer / LlmFailed, Model + CacheWrite + Cached / DownloadFailed) with the protocol's causes.
//! The audio side never logs. API keys and tokens are never logged (eventlog also redacts).
//!
//! Deliberate differences from the Rust (each so that no input can crash or escape, tests stay
//! offline, or a bound the specification asks for holds):
//! * The App works through an injected `Http` seam (fetch, download, open a browser) and an
//!   injected `record_fn`; tests use `Http.offline`, which never touches the network or a browser
//!   (proof "Tests do not reach out"; the Rust tests could start a TONE3000 login and xdg-open).
//!   Files are opened relative to `Config.cwd` (the process cwd outside tests), so tests stay in
//!   their scratch directory.
//! * Every NAM cache file name is sanitized at the point it is written or looked up (a
//!   `nam tone3000 ID as NAME` from a loaded session included): only [A-Za-z0-9._-] survive, and a
//!   name with '/', '\\', NUL or ".." is never joined to the cache directory (proof "Cache writes
//!   stay in the cache"; the Rust joined an unsanitized TONE3000 name).
//! * The timeline holds at most 4096 entries (shared.max_entries); an edit past that is rejected
//!   with "✗ the timeline holds at most 4096 entries; delete some with x <id> first", and a
//!   session with more fails to load. LLM responses are bounded by net.max_body, downloads by
//!   net.max_download.
//! * A phrase the builder rejects (fewer than 3 notes, more than 20 repeats, more than 10000 jump
//!   passes; see sequencer.zig) is shown as "✗ <reason>" and consumes no id.
//! * The App changes its own timeline before it sends the matching audio command everywhere
//!   (the Rust sent first for `j` and plain phrases).
//! * `m` refuses while a recording result is still pending as well as while one is rendering.
//! * clockin / clockout are taken before the parser as upstream, but the MIDI clock is not ported
//!   (the specification does not mention MIDI); they answer "✗ clockin: MIDI clock is not available
//!   in this build" (resp. clockout).
//! * HTTP has no request timeouts (std.http.Client), a transport error is named by its Zig error
//!   name, and a download reports no Content-Length total (the progress line shows bytes).
//! * `nam search` runs on the calling thread as upstream, through the seam.
//! * App.init returns a heap App (`*App`), since workers hold pointers into it.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const channel = @import("channel.zig");
const command = @import("command.zig");
const eventlog = @import("eventlog.zig");
const fx = @import("fx.zig");
const nam = @import("nam.zig");
const net = @import("net.zig");
const sequencer = @import("sequencer.zig");
const session = @import("session.zig");
const shared_mod = @import("shared.zig");
const tuning = @import("tuning.zig");
const vcf = @import("vcf.zig");

const Cmd = command.Cmd;
const JinsSpec = command.JinsSpec;
const LlmProvider = command.LlmProvider;
const NamCommand = command.NamCommand;
const NamInput = command.NamInput;
const ValueChange = command.ValueChange;
const FxSettings = fx.FxSettings;
const AudioCmd = sequencer.AudioCmd;
const Garbage = sequencer.Garbage;
const ControlSpec = sequencer.ControlSpec;
const Phrase = sequencer.Phrase;
const Pitch = tuning.Pitch;
const VcfBank = vcf.VcfBank;
const VcfSettings = vcf.VcfSettings;
const VcfTarget = vcf.VcfTarget;
const Shared = shared_mod.Shared;
const EventLog = eventlog.EventLog;
const Field = eventlog.Field;
const Value = std.json.Value;
const rs = sequencer.rust_str;

pub const CmdRing = channel.Ring(AudioCmd, 512);
pub const GarbageRing = channel.Ring(Garbage, 1024);
pub const max_entries: usize = shared_mod.max_entries;

// TONE3000 publishable OAuth client ID for maqam-live. Publishable keys are
// intentionally safe to ship in desktop/client applications; never embed the secret key.
const TONE3000_PUBLISHABLE_CLIENT_ID = "t3k_pub__1tkc-W6fWSyBUgGJdHj-bqpnPtFesDA";

const timeline_full_message = "✗ the timeline holds at most 4096 entries; delete some with x <id> first";

// ── Seams ─────────────────────────────────────────────────────────────────────

/// The network and the browser, injected so tests never reach out.
pub const Http = struct {
    ctx: ?*anyopaque = null,
    /// False: nothing may listen, connect or open a browser (the TONE3000 login checks it first).
    online: bool = true,
    fetch: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: std.Io, method: std.http.Method, url: []const u8, headers: []const net.Header, payload: ?[]const u8) anyerror!net.Response,
    download: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: std.Io, url: []const u8, headers: []const net.Header, file: std.Io.File, progress: *std.atomic.Value(u64)) anyerror!u16,
    open_browser: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: std.Io, url: []const u8) anyerror!void,

    pub const real: Http = .{ .fetch = realFetch, .download = realDownload, .open_browser = realOpenBrowser };
    pub const offline: Http = .{ .online = false, .fetch = offFetch, .download = offDownload, .open_browser = offBrowser };

    fn realFetch(_: ?*anyopaque, gpa: Allocator, io: std.Io, method: std.http.Method, url: []const u8, headers: []const net.Header, payload: ?[]const u8) anyerror!net.Response {
        return net.fetch(gpa, io, method, url, headers, payload);
    }
    fn realDownload(_: ?*anyopaque, gpa: Allocator, io: std.Io, url: []const u8, headers: []const net.Header, file: std.Io.File, progress: *std.atomic.Value(u64)) anyerror!u16 {
        return net.download(gpa, io, url, headers, file, progress);
    }
    fn realOpenBrowser(_: ?*anyopaque, gpa: Allocator, io: std.Io, url: []const u8) anyerror!void {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ "xdg-open", url } });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        switch (r.term) {
            .exited => |code| if (code != 0) return error.BrowserExitFailure,
            else => return error.BrowserExitFailure,
        }
    }
    fn offFetch(_: ?*anyopaque, _: Allocator, _: std.Io, _: std.http.Method, _: []const u8, _: []const net.Header, _: ?[]const u8) anyerror!net.Response {
        return error.NetworkDisabled;
    }
    fn offDownload(_: ?*anyopaque, _: Allocator, _: std.Io, _: []const u8, _: []const net.Header, _: std.Io.File, _: *std.atomic.Value(u64)) anyerror!u16 {
        return error.NetworkDisabled;
    }
    fn offBrowser(_: ?*anyopaque, _: Allocator, _: std.Io, _: []const u8) anyerror!void {
        return error.NetworkDisabled;
    }
};

/// What the recorder answers: the mp4 path or the error message (both owned by the App).
pub const RecordResult = union(enum) { ok: []u8, err: []u8 };
/// record.recordCycle's signature (main adapts the real one; tests pass fakes).
pub const RecordFn = *const fn (gpa: Allocator, io: std.Io, shared: *Shared, phrases: []const Phrase, bpm: f64, sustain: f64, vcf: VcfBank, fx: FxSettings, cycle_repeat: usize) RecordResult;

pub const Config = struct {
    cmds: *CmdRing,
    garbage: *GarbageRing,
    shared: *Shared,
    log: *EventLog,
    env: *const std.process.Environ.Map,
    record_fn: RecordFn,
    http: Http = if (builtin.is_test) Http.offline else Http.real,
    /// The directory relative paths (sessions, .nam, globals, completion) are resolved against.
    cwd: std.Io.Dir = std.Io.Dir.cwd(),
};

pub const NamDownloadProgress = struct {
    name: []u8,
    downloaded: u64,
    total: ?u64,
    load_after: bool,
};

const LlmRole = enum {
    user,
    assistant,
    fn asApiRole(self: LlmRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

const LlmChatMessage = struct { role: LlmRole, content: []u8 };

const Tone3000Auth = struct {
    access_token: []u8,
    refresh_token: ?[]u8,
    expires_at: u64,
    client_id: []u8,

    fn deinit(self: Tone3000Auth, gpa: Allocator) void {
        gpa.free(self.access_token);
        if (self.refresh_token) |r| gpa.free(r);
        gpa.free(self.client_id);
    }
};

/// A worker failure message (owned), the Rust `Err(String)`.
const Failure = struct {
    gpa: Allocator,
    msg: ?[]u8 = null,

    const Error = error{ Fail, OutOfMemory };

    fn fail(self: *Failure, comptime f: []const u8, args: anytype) Error {
        const m = try std.fmt.allocPrint(self.gpa, f, args);
        if (self.msg) |old| self.gpa.free(old);
        self.msg = m;
        return error.Fail;
    }

    fn take(self: *Failure, e: Error) []u8 {
        return switch (e) {
            error.Fail => blk: {
                const m = self.msg.?;
                self.msg = null;
                break :blk m;
            },
            error.OutOfMemory => self.gpa.dupe(u8, "out of memory") catch @constCast("out of memory"),
        };
    }

    fn deinit(self: *Failure) void {
        if (self.msg) |m| self.gpa.free(m);
    }
};

fn freeMsg(gpa: Allocator, m: []u8) void {
    if (m.ptr == @as([]const u8, "out of memory").ptr) return;
    gpa.free(m);
}

// ── Workers ───────────────────────────────────────────────────────────────────

/// The protocol position a worker's interaction is at (for the event log).
const LogRef = struct {
    logged: bool = false,
    session: u64 = 0,
    /// The interaction's first message (m, p or n).
    first: u64 = 0,
    /// The request the worker answers (r, q or g).
    request: u64 = 0,
};

const RecJob = struct {
    thread: std.Thread = undefined,
    box: channel.Mailbox(RecordResult) = .{},
    phrases: []Phrase,
    bpm: f64,
    sustain: f64,
    vcf: VcfBank,
    fx: FxSettings,
    reps: usize,
    log: LogRef = .{},
};

const LlmRequest = struct {
    provider: LlmProvider,
    key: []u8,
    model: []u8,
    prompt: []u8,
    history: []LlmChatMessage,
    score_context: []u8,

    fn providerName(self: *const LlmRequest) []const u8 {
        return providerNameOf(self.provider);
    }

    fn deinit(self: *LlmRequest, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.model);
        gpa.free(self.prompt);
        for (self.history) |m| gpa.free(m.content);
        gpa.free(self.history);
        gpa.free(self.score_context);
    }
};

fn providerNameOf(p: LlmProvider) []const u8 {
    return switch (p) {
        .chat_gpt => "chatgpt",
        .claude => "claude",
    };
}

const LlmOutcome = union(enum) {
    answer: []u8,
    commands: [][]u8,
    err: []u8,
};

const LlmJob = struct {
    thread: std.Thread = undefined,
    box: channel.Mailbox(LlmOutcome) = .{},
    req: LlmRequest,
    edit: bool,
    /// The prompt as sent (the edit prompt for an edit), remembered in the LLM history.
    sent_prompt: []u8,
    log: LogRef = .{},
};

const DlResult = union(enum) { done, err: []u8 };

const DownloadJob = struct {
    thread: std.Thread = undefined,
    box: channel.Mailbox(DlResult) = .{},
    /// The capture URL (for a TONE3000 tone it is looked up by the worker).
    url: ?[]u8,
    tone_id: ?u64 = null,
    token: ?[]u8 = null,
    cache_dir: []u8,
    /// A sanitized cache name.
    name: []u8,
    load_after: bool,
    progress: std.atomic.Value(u64) = .init(0),
    log: LogRef = .{},

    fn destroy(self: *DownloadJob, gpa: Allocator) void {
        if (self.url) |u| gpa.free(u);
        if (self.token) |t| gpa.free(t);
        gpa.free(self.cache_dir);
        gpa.free(self.name);
        gpa.destroy(self);
    }
};

const AuthResult = union(enum) { ok: Tone3000Auth, err: []u8 };

const AuthJob = struct {
    thread: std.Thread = undefined,
    box: channel.Mailbox(AuthResult) = .{},
    client_id: []u8,

    fn destroy(self: *AuthJob, gpa: Allocator) void {
        gpa.free(self.client_id);
        gpa.destroy(self);
    }
};

const ScoreSnapshot = struct {
    phrases: []Phrase,
    next_phrase_id: usize,
    last_rhythm: []u8,
    bpm: f64,
    sustain: f64,
    vcf: VcfBank,
    fx: FxSettings,
    paused: bool,
};

// ── Event-log interactions ────────────────────────────────────────────────────

const Branch = enum { edit, session, record, prompt, fetch, quit };

const Interaction = struct {
    session: u64,
    first: u64,
    branch: Branch,
    /// Derived sessions so far.
    sub: u32 = 0,
    /// The label of each audio command sent in this interaction (null: not logged).
    audio_label: ?[]const u8,
};

const SubRef = struct { session: u64, sub: u32 };
const max_pending_positions: usize = 1024;

// ── App ───────────────────────────────────────────────────────────────────────

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    cmds: *CmdRing,
    garbage: *GarbageRing,
    shared: *Shared,
    log: *EventLog,
    env: *const std.process.Environ.Map,
    record_fn: RecordFn,
    http: Http,
    cwd: std.Io.Dir,

    phrases: std.ArrayList(Phrase) = .empty,
    input: std.ArrayList(u8) = .empty,
    message: ?[]u8 = null,
    show_help: bool = false,
    show_jins: bool = false,
    help_scroll: u16 = 0,
    jins_scroll: u16 = 0,
    message_scroll: u16 = 0,
    bpm: f64 = 120.0,
    sustain: f64 = 1.25,
    vcf: VcfBank = .{},
    fx: FxSettings = .{},
    vol: f32 = 1.0,
    tune_to: Pitch = .{ .letter = 'd', .accidental = 0, .octave = 4 },
    live_nam_commands: std.ArrayList([]u8) = .empty,
    paused: bool = false,
    should_quit: bool = false,
    last_recording: ?[]u8 = null,
    nam_download_progress: ?NamDownloadProgress = null,
    history: std.ArrayList([]u8) = .empty,
    history_pos: ?usize = null,
    saved_input: std.ArrayList(u8) = .empty,
    cursor_pos: usize = 0,
    rec_job: ?*RecJob = null,
    nam_download: ?*DownloadJob = null,
    tone3000_auth: ?*AuthJob = null,
    latency_box: *channel.Mailbox(sequencer.LatencyResult),
    latency_pending: bool = false,
    pending_tone3000_download: ?struct { tone_id: u64, name: []u8 } = null,
    llm_job: ?*LlmJob = null,
    llm_history: std.ArrayList(LlmChatMessage) = .empty,
    session_path: ?[]u8 = null,
    pending_nam_slot: ?[]u8 = null,
    next_phrase_id: usize = 0,
    last_rhythm: std.ArrayList(u8) = .empty,
    auditioning_jins: bool = false,

    zombie_downloads: std.ArrayList(*DownloadJob) = .empty,
    zombie_auths: std.ArrayList(*AuthJob) = .empty,
    zombie_llm: std.ArrayList(*LlmJob) = .empty,

    // event log state
    cur: ?Interaction = null,
    part_line: ?[]const u8 = null,
    deferred_fetch: ?*DownloadJob = null,
    pending_positions: std.ArrayList(SubRef) = .empty,
    last_phrase_starts: u64 = 0,

    /// The App, with the globals file read and SetVol sent (the Rust `App::new`).
    pub fn init(gpa: Allocator, io: std.Io, cfg: Config) !*App {
        tuning.resetTuningBase();
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        const box = try gpa.create(channel.Mailbox(sequencer.LatencyResult));
        errdefer gpa.destroy(box);
        box.* = .{};
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cmds = cfg.cmds,
            .garbage = cfg.garbage,
            .shared = cfg.shared,
            .log = cfg.log,
            .env = cfg.env,
            .record_fn = cfg.record_fn,
            .http = cfg.http,
            .cwd = cfg.cwd,
            .latency_box = box,
        };
        self.last_phrase_starts = cfg.shared.phrase_starts.load(.monotonic);
        try self.last_rhythm.appendSlice(gpa, &.{ 3, 3, 2 });
        try self.setMsg("? for help", .{});
        self.loadGlobals() catch |e| switch (e) {
            error.OutOfMemory => return e,
        };
        try self.sendAudio(.{ .set_vol = self.vol });
        return self;
    }

    /// Joins every worker (current and abandoned) and frees everything.
    pub fn deinit(self: *App) void {
        const gpa = self.gpa;
        if (self.rec_job) |j| {
            j.thread.join();
            if (j.box.take()) |r| switch (r) {
                .ok => |p| gpa.free(p),
                .err => |m| gpa.free(m),
            };
            self.freeRecJob(j);
        }
        if (self.llm_job) |j| self.reapLlm(j, true);
        for (self.zombie_llm.items) |j| self.reapLlm(j, true);
        self.zombie_llm.deinit(gpa);
        if (self.nam_download) |j| self.reapDownload(j, true);
        for (self.zombie_downloads.items) |j| self.reapDownload(j, true);
        self.zombie_downloads.deinit(gpa);
        if (self.tone3000_auth) |j| self.reapAuth(j, true);
        for (self.zombie_auths.items) |j| self.reapAuth(j, true);
        self.zombie_auths.deinit(gpa);
        self.drainGarbage();
        for (self.phrases.items) |*p| p.deinit(gpa);
        self.phrases.deinit(gpa);
        self.input.deinit(gpa);
        if (self.message) |m| gpa.free(m);
        for (self.live_nam_commands.items) |c| gpa.free(c);
        self.live_nam_commands.deinit(gpa);
        if (self.last_recording) |r| gpa.free(r);
        if (self.nam_download_progress) |p| gpa.free(p.name);
        for (self.history.items) |h| gpa.free(h);
        self.history.deinit(gpa);
        self.saved_input.deinit(gpa);
        gpa.destroy(self.latency_box);
        if (self.pending_tone3000_download) |p| gpa.free(p.name);
        for (self.llm_history.items) |m| gpa.free(m.content);
        self.llm_history.deinit(gpa);
        if (self.session_path) |p| gpa.free(p);
        if (self.pending_nam_slot) |p| gpa.free(p);
        self.last_rhythm.deinit(gpa);
        self.pending_positions.deinit(gpa);
        gpa.destroy(self);
    }

    // ── Messages ──────────────────────────────────────────────────────────

    fn setMsg(self: *App, comptime f: []const u8, args: anytype) Allocator.Error!void {
        const m = try std.fmt.allocPrint(self.gpa, f, args);
        if (self.message) |old| self.gpa.free(old);
        self.message = m;
    }

    fn setMsgOwned(self: *App, m: []u8) void {
        if (self.message) |old| self.gpa.free(old);
        self.message = m;
    }

    fn clearMsg(self: *App) void {
        if (self.message) |old| self.gpa.free(old);
        self.message = null;
    }

    fn msgIsError(self: *const App) bool {
        const m = self.message orelse return false;
        return std.mem.startsWith(u8, m, "✗");
    }

    fn reset(self: *App, slot: *?[]u8, value: ?[]const u8) Allocator.Error!void {
        const copy = if (value) |v| try self.gpa.dupe(u8, v) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
    }

    fn resetTransientViewState(self: *App) void {
        self.input.clearRetainingCapacity();
        self.message_scroll = 0;
        self.show_help = false;
        self.show_jins = false;
        self.help_scroll = 0;
        self.jins_scroll = 0;
        self.history_pos = null;
        self.saved_input.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.auditioning_jins = false;
    }

    // ── History ───────────────────────────────────────────────────────────

    /// Upstream bounds neither; these keep a long performance's memory bounded.
    pub const max_history_lines: usize = 1000;
    pub const max_llm_exchanges: usize = 16;

    pub fn historyPush(self: *App, cmd: []const u8) Allocator.Error!void {
        const s = rs.trim(cmd);
        const differs = if (self.history.items.len == 0) true else !std.mem.eql(u8, self.history.items[self.history.items.len - 1], s);
        if (s.len > 0 and differs) {
            if (self.history.items.len >= max_history_lines) {
                self.gpa.free(self.history.items[0]);
                _ = self.history.orderedRemove(0);
            }
            const copy = try self.gpa.dupe(u8, s);
            self.history.append(self.gpa, copy) catch |e| {
                self.gpa.free(copy);
                return e;
            };
        }
        self.history_pos = null;
        self.saved_input.clearRetainingCapacity();
    }

    pub fn lastHistory(self: *const App) ?[]const u8 {
        if (self.history.items.len == 0) return null;
        return self.history.items[self.history.items.len - 1];
    }

    pub fn sessionFilename(self: *const App) ?[]const u8 {
        const p = self.session_path orelse return null;
        return fileName(p);
    }

    /// The globals file's name (for the title). Caller owns it.
    pub fn globalsFilename(self: *const App, gpa: Allocator) Allocator.Error![]u8 {
        const p = self.globalsPath();
        return gpa.dupe(u8, fileName(p) orelse ".globals.ml");
    }

    fn setInput(self: *App, text: []const u8) Allocator.Error!void {
        self.input.clearRetainingCapacity();
        try self.input.appendSlice(self.gpa, text);
        self.cursor_pos = charCount(self.input.items);
    }

    pub fn historyUp(self: *App) Allocator.Error!void {
        if (self.history.items.len == 0) return;
        if (self.history_pos) |i| {
            if (i != 0) self.history_pos = i - 1;
        } else {
            self.saved_input.clearRetainingCapacity();
            try self.saved_input.appendSlice(self.gpa, self.input.items);
            self.history_pos = self.history.items.len - 1;
        }
        if (self.history_pos) |i| try self.setInput(self.history.items[i]);
    }

    pub fn historyDown(self: *App) Allocator.Error!void {
        const i = self.history_pos orelse return;
        if (i + 1 >= self.history.items.len) {
            self.history_pos = null;
            const saved = try self.gpa.dupe(u8, self.saved_input.items);
            defer self.gpa.free(saved);
            try self.setInput(saved);
        } else {
            self.history_pos = i + 1;
            try self.setInput(self.history.items[i + 1]);
        }
    }

    // ── Cursor / line editing ─────────────────────────────────────────────

    pub fn cursorLeft(self: *App) void {
        if (self.cursor_pos > 0) self.cursor_pos -= 1;
    }

    pub fn cursorRight(self: *App) void {
        if (self.cursor_pos < charCount(self.input.items)) self.cursor_pos += 1;
    }

    pub fn cursorHome(self: *App) void {
        self.cursor_pos = 0;
    }

    pub fn cursorEnd(self: *App) void {
        self.cursor_pos = charCount(self.input.items);
    }

    pub fn insertChar(self: *App, ch: u21) Allocator.Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &buf) catch return;
        const at = byteIndexOfChar(self.input.items, self.cursor_pos);
        try self.input.insertSlice(self.gpa, at, buf[0..n]);
        self.cursor_pos += 1;
    }

    pub fn backspace(self: *App) void {
        if (self.cursor_pos == 0) return;
        const at = byteIndexOfChar(self.input.items, self.cursor_pos - 1);
        if (at >= self.input.items.len) {
            if (self.input.items.len > 0) _ = self.input.pop();
        } else {
            const len = charLenAt(self.input.items, at);
            self.input.replaceRangeAssumeCapacity(at, len, &.{});
        }
        self.cursor_pos -= 1;
    }

    pub fn deleteChar(self: *App) void {
        if (self.cursor_pos >= charCount(self.input.items)) return;
        const at = byteIndexOfChar(self.input.items, self.cursor_pos);
        const len = charLenAt(self.input.items, at);
        self.input.replaceRangeAssumeCapacity(at, len, &.{});
    }

    /// Tab completion: edit rows, command metadata, the next phrase, then .mq paths.
    pub fn completeInput(self: *App) Allocator.Error!void {
        if (try self.completeEditInput()) return;
        if (try self.completeMetadataCommandInput()) return;
        if (try self.completePhraseInput()) return;
        const target = completionTarget(self.input.items) orelse return;
        const matches = try mqMatches(self.gpa, self.io, self.cwd, target.cmd, target.partial);
        defer freeStrList(self.gpa, matches);
        if (matches.len == 0) {
            try self.setMsg("✗ no .mq matches", .{});
            return;
        }
        const common = try completionCommonPrefix(self.gpa, target.cmd, target.partial, matches);
        defer self.gpa.free(common);
        const replacement: []const u8 = if (matches.len == 1)
            matches[0]
        else if (common.len > target.partial.len) blk: {
            try self.setListMsg(target.cmd, matches);
            break :blk common;
        } else {
            try self.setListMsg(target.cmd, matches);
            return;
        };
        const repl = try self.gpa.dupe(u8, replacement);
        defer self.gpa.free(repl);
        self.input.shrinkRetainingCapacity(target.arg_start);
        try self.input.appendSlice(self.gpa, repl);
        self.cursor_pos = charCount(self.input.items);
        if (matches.len == 1) self.clearMsg();
    }

    fn setListMsg(self: *App, cmd: []const u8, matches: []const []u8) Allocator.Error!void {
        const joined = try std.mem.join(self.gpa, "  ", matches);
        defer self.gpa.free(joined);
        try self.setMsg("{s}: {s}", .{ cmd, joined });
    }

    fn completeEditInput(self: *App) Allocator.Error!bool {
        const trimmed = rs.trim(self.input.items);
        var tokens = rs.words(trimmed);
        const first = tokens.next() orelse return false;
        if (!std.mem.eql(u8, first, "edit")) return false;
        const id_token = tokens.next() orelse return false;
        if (tokens.next() != null) return false;
        const id_ref = parseIsize(id_token) orelse return false;
        const id = self.resolveIdRef(id_ref) orelse {
            try self.setMsg("✗ no phrase id {d}", .{id_ref});
            return true;
        };
        const pos = self.positionOf(id) orelse {
            try self.setMsg("✗ no phrase id {d}", .{id});
            return true;
        };
        const display = try self.phrases.items[pos].displaySrc(self.gpa);
        defer self.gpa.free(display);
        const text = try std.fmt.allocPrint(self.gpa, "edit {s} {s}", .{ id_token, display });
        defer self.gpa.free(text);
        try self.setInput(text);
        self.clearMsg();
        return true;
    }

    fn completeMetadataCommandInput(self: *App) Allocator.Error!bool {
        const body = commandBodyForCompletion(self.input.items) orelse return false;
        var completion = (try metadataCommandCompletion(self.gpa, self.input.items[body.start..])) orelse return false;
        defer if (completion.message) |m| self.gpa.free(m);
        if (completion.replacement) |r| {
            defer self.gpa.free(r);
            self.input.shrinkRetainingCapacity(body.start);
            try self.input.appendSlice(self.gpa, r);
            self.cursor_pos = charCount(self.input.items);
        }
        self.clearMsg();
        self.message = completion.message;
        completion.message = null;
        return true;
    }

    fn completePhraseInput(self: *App) Allocator.Error!bool {
        const replacement = (try phraseCompletion(self.gpa, self.input.items, self.phrases.items)) orelse return false;
        defer self.gpa.free(replacement);
        try self.setInput(replacement);
        self.clearMsg();
        return true;
    }

    pub fn overlayScrollUp(self: *App) void {
        if (self.show_help) {
            self.help_scroll -|= 1;
        } else if (self.show_jins) {
            self.jins_scroll -|= 1;
        }
    }

    pub fn overlayScrollDown(self: *App) void {
        if (self.show_help) {
            self.help_scroll +|= 1;
        } else if (self.show_jins) {
            self.jins_scroll +|= 1;
        }
    }

    pub fn overlayScrollHome(self: *App) void {
        if (self.show_help) self.help_scroll = 0;
        if (self.show_jins) self.jins_scroll = 0;
    }

    pub fn messageScrollUp(self: *App) void {
        self.message_scroll -|= 1;
    }

    pub fn messageScrollDown(self: *App) void {
        self.message_scroll +|= 1;
    }

    pub fn messageScrollHome(self: *App) void {
        self.message_scroll = 0;
    }

    /// True while a recording is pending (the CLI waits for it).
    pub fn recordingPending(self: *const App) bool {
        return self.rec_job != null or self.shared.rec_active.load(.monotonic);
    }

    // ── Audio and the event log ───────────────────────────────────────────

    /// Frees everything the audio side handed back.
    pub fn drainGarbage(self: *App) void {
        while (self.garbage.tryRecv()) |g| g.deinit(self.gpa);
    }

    /// Sends one command to the audio side (waiting for room, freeing garbage meanwhile), logging
    /// it as a derived session of the current interaction.
    fn sendAudio(self: *App, cmd: AudioCmd) Allocator.Error!void {
        self.ensureEdit();
        if (self.cur) |*c| if (c.audio_label) |label| if (self.log.enabled()) {
            c.sub += 1;
            var idbuf: [24]u8 = undefined;
            var fields: [2]Field = undefined;
            var n: usize = 0;
            switch (cmd) {
                .add_phrase, .replace_phrase => |p| {
                    fields[0] = .{ .name = "id", .value = std.fmt.bufPrint(&idbuf, "{d}", .{p.id}) catch "" };
                    fields[1] = .{ .name = "source", .value = p.src };
                    n = 2;
                },
                .insert_phrase => |v| {
                    fields[0] = .{ .name = "id", .value = std.fmt.bufPrint(&idbuf, "{d}", .{v.phrase.id}) catch "" };
                    fields[1] = .{ .name = "source", .value = v.phrase.src };
                    n = 2;
                },
                .remove_phrase => |id| {
                    fields[0] = .{ .name = "id", .value = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch "" };
                    fields[1] = .{ .name = "source", .value = "remove_phrase" };
                    n = 2;
                },
                .move_phrase => |v| {
                    fields[0] = .{ .name = "id", .value = std.fmt.bufPrint(&idbuf, "{d}", .{v.id}) catch "" };
                    fields[1] = .{ .name = "source", .value = "move_phrase" };
                    n = 2;
                },
                else => {
                    fields[0] = .{ .name = "source", .value = @tagName(cmd) };
                    n = 1;
                },
            }
            _ = self.log.emit(c.session, c.sub, "App", "Audio", label, null, fields[0..n]);
            if (std.mem.eql(u8, label, "Phrase")) {
                if (self.pending_positions.items.len >= max_pending_positions) _ = self.pending_positions.orderedRemove(0);
                try self.pending_positions.append(self.gpa, .{ .session = c.session, .sub = c.sub });
            }
        };
        while (!self.cmds.trySend(cmd)) {
            if (self.cmds.closed.load(.acquire)) {
                cmd.deinit(self.gpa);
                return;
            }
            self.drainGarbage();
            std.Thread.yield() catch {};
        }
    }

    /// Sends a heap copy of `p` as the command `make` builds.
    fn sendPhraseCopy(self: *App, p: *const Phrase, comptime kind: enum { add, replace }) Allocator.Error!void {
        const h = try self.heapClone(p);
        try self.sendAudio(switch (kind) {
            .add => .{ .add_phrase = h },
            .replace => .{ .replace_phrase = h },
        });
    }

    fn sendInsertCopy(self: *App, pos: usize, p: *const Phrase) Allocator.Error!void {
        const h = try self.heapClone(p);
        try self.sendAudio(.{ .insert_phrase = .{ .pos = pos, .phrase = h } });
    }

    fn heapClone(self: *App, p: *const Phrase) Allocator.Error!*Phrase {
        var c = try p.clone(self.gpa);
        errdefer c.deinit(self.gpa);
        return Phrase.create(self.gpa, c);
    }

    /// The edit branch starts with the command line when the first audio command of an
    /// interaction is sent.
    fn ensureEdit(self: *App) void {
        if (self.cur != null) return;
        const line = self.part_line orelse return;
        if (!self.log.enabled()) {
            self.cur = .{ .session = 0, .first = 0, .branch = .edit, .audio_label = null };
            return;
        }
        const s = self.log.interaction();
        const ts = self.log.emit(s, 0, "Performer", "App", "Command", null, &.{.{ .name = "line", .value = line }});
        self.cur = .{ .session = s, .first = ts, .branch = .edit, .audio_label = "Phrase" };
    }

    /// Starts an interaction with `label` from the Performer; false when one is already running
    /// (then nothing is logged for this branch).
    fn beginBranch(self: *App, branch: Branch, label: []const u8, fields: []const Field, audio_label: ?[]const u8) bool {
        if (self.cur != null) return false;
        if (!self.log.enabled()) {
            self.cur = .{ .session = 0, .first = 0, .branch = branch, .audio_label = null };
            return false;
        }
        const s = self.log.interaction();
        const ts = self.log.emit(s, 0, "Performer", "App", label, null, fields);
        self.cur = .{ .session = s, .first = ts, .branch = branch, .audio_label = audio_label };
        return true;
    }

    fn emitIn(self: *App, ref: LogRef, from: []const u8, to: []const u8, label: []const u8, cause: u64, fields: []const Field) u64 {
        if (!ref.logged or !self.log.enabled()) return 0;
        return self.log.emit(ref.session, 0, from, to, label, cause, fields);
    }

    /// Ends the interaction of one command-line part.
    fn endPart(self: *App) Allocator.Error!void {
        if (self.log.enabled()) {
            if (self.cur) |c| {
                if (c.branch == .edit and c.session != 0)
                    _ = self.log.emit(c.session, 0, "App", "Performer", "Shown", c.first, &.{});
            } else if (self.part_line) |line| {
                const s = self.log.interaction();
                const ts = self.log.emit(s, 0, "Performer", "App", "Command", null, &.{.{ .name = "line", .value = line }});
                _ = self.log.emit(s, 0, "App", "Performer", if (self.msgIsError()) "Rejected" else "Shown", ts, &.{});
            }
        }
        self.cur = null;
        self.part_line = null;
        self.flushDeferredFetch();
    }

    fn flushDeferredFetch(self: *App) void {
        const job = self.deferred_fetch orelse return;
        self.deferred_fetch = null;
        if (self.nam_download != job) return;
        self.logFetchStart(job);
        self.cur = null;
    }

    /// Fetch from the Performer and Download to the Web, for a download that just started.
    fn logFetchStart(self: *App, job: *DownloadJob) void {
        if (!self.log.enabled()) return;
        const url: []const u8 = job.url orelse "https://www.tone3000.com/api/v1/models";
        if (!self.beginBranch(.fetch, "Fetch", &.{ .{ .name = "url", .value = url }, .{ .name = "name", .value = job.name } }, null)) return;
        const c = self.cur.?;
        job.log = .{ .logged = true, .session = c.session, .first = c.first };
        job.log.request = self.log.emit(c.session, 0, "App", "Web", "Download", c.first, &.{});
    }

    /// Position from the audio side for every Phrase session sent before the last phrase start.
    fn pollPositions(self: *App) void {
        const ps = self.shared.phrase_starts.load(.monotonic);
        if (ps == self.last_phrase_starts) return;
        self.last_phrase_starts = ps;
        if (self.log.enabled()) {
            for (self.pending_positions.items) |r| _ = self.log.emit(r.session, r.sub, "Audio", "App", "Position", null, &.{});
        }
        self.pending_positions.clearRetainingCapacity();
    }

    // ── Worker poll ───────────────────────────────────────────────────────

    /// Polls every worker, frees audio garbage and logs positions (the Rust `tick`).
    pub fn tick(self: *App) Allocator.Error!void {
        self.drainGarbage();
        self.pollPositions();
        if (self.llm_job) |job| {
            if (job.box.take()) |result| {
                job.thread.join();
                self.llm_job = null;
                defer self.freeLlmJob(job);
                try self.finishLlm(job, result);
            }
        }
        if (self.rec_job) |job| {
            if (job.box.take()) |result| {
                job.thread.join();
                self.rec_job = null;
                defer self.freeRecJob(job);
                switch (result) {
                    .ok => |path| {
                        defer self.gpa.free(path);
                        _ = self.emitIn(job.log, "Recorder", "App", "Saved", job.log.request, &.{.{ .name = "path", .value = path }});
                        _ = self.emitIn(job.log, "App", "Performer", "RecordDone", job.log.first, &.{});
                        try self.reset(&self.last_recording, path);
                        try self.setMsg("saved → {s}", .{path});
                    },
                    .err => |e| {
                        defer self.gpa.free(e);
                        _ = self.emitIn(job.log, "Recorder", "App", "RenderFailed", job.log.request, &.{});
                        _ = self.emitIn(job.log, "App", "Performer", "RecordFailed", job.log.first, &.{});
                        try self.setMsg("✗ {s}", .{e});
                    },
                }
            }
        }
        try self.pollNamDownload();
        try self.pollTone3000Auth();
        self.reapZombies();
        if (self.latency_pending) {
            if (self.latency_box.take()) |result| {
                self.latency_pending = false;
                switch (result) {
                    .ok => |ms| try self.setMsg("NAM input round-trip latency: {f} ms", .{rfix(ms, 1)}),
                    .err => |e| try self.setMsg("✗ latency test: {s}", .{e}),
                }
            }
        }
    }

    fn finishLlm(self: *App, job: *LlmJob, result: LlmOutcome) Allocator.Error!void {
        switch (result) {
            .answer => |answer| {
                defer self.gpa.free(answer);
                _ = self.emitIn(job.log, "Llm", "App", "Answer", job.log.request, &.{});
                _ = self.emitIn(job.log, "App", "Performer", "Explained", job.log.first, &.{});
                try self.rememberLlmExchange(job.sent_prompt, answer);
                try self.setMsg("{s}", .{answer});
            },
            .commands => |commands| {
                defer freeStrList(self.gpa, commands);
                var countbuf: [24]u8 = undefined;
                const count = std.fmt.bufPrint(&countbuf, "{d}", .{commands.len}) catch "";
                _ = self.emitIn(job.log, "Llm", "App", "Commands", job.log.request, &.{.{ .name = "count", .value = count }});
                const returned = try std.mem.join(self.gpa, "\n", commands);
                defer self.gpa.free(returned);
                self.cur = .{ .session = job.log.session, .first = job.log.first, .branch = .prompt, .audio_label = if (job.log.logged) "Apply" else null };
                self.applyLlmEditCommands(commands) catch |e| {
                    self.cur = null;
                    return e;
                };
                self.cur = null;
                const applied = if (self.message) |m| std.mem.startsWith(u8, m, "LLM applied ") else false;
                _ = self.emitIn(job.log, "App", "Performer", if (applied) "Applied" else "RolledBack", job.log.first, &.{});
                self.flushDeferredFetch();
                const result_text: []const u8 = self.message orelse "LLM edit produced no visible result";
                const remembered = try std.fmt.allocPrint(self.gpa, "Tool returned commands:\n{s}\n\nApplication result:\n{s}", .{ returned, result_text });
                defer self.gpa.free(remembered);
                try self.rememberLlmExchange(job.sent_prompt, remembered);
            },
            .err => |e| {
                defer freeMsg(self.gpa, e);
                _ = self.emitIn(job.log, "Llm", "App", "LlmFailed", job.log.request, &.{});
                _ = self.emitIn(job.log, "App", "Performer", "AskFailed", job.log.first, &.{});
                try self.setMsg("✗ {s}", .{e});
            },
        }
    }

    fn pollTone3000Auth(self: *App) Allocator.Error!void {
        const job = self.tone3000_auth orelse return;
        const result = job.box.take() orelse return;
        job.thread.join();
        self.tone3000_auth = null;
        job.destroy(self.gpa);
        switch (result) {
            .ok => |auth| {
                defer auth.deinit(self.gpa);
                if (self.saveTone3000Auth(auth)) |err| {
                    defer self.gpa.free(err);
                    try self.setMsg("✗ TONE3000 login succeeded but credentials could not be saved: {s}", .{err});
                    return;
                }
                try self.setMsg("TONE3000 login complete", .{});
                if (self.pending_tone3000_download) |p| {
                    self.pending_tone3000_download = null;
                    defer self.gpa.free(p.name);
                    try self.startTone3000Download(p.tone_id, p.name);
                }
            },
            .err => |e| {
                defer freeMsg(self.gpa, e);
                self.shared.nam_status.store(4, .monotonic);
                try self.setMsg("✗ TONE3000 login failed: {s}", .{e});
            },
        }
    }

    fn pollNamDownload(self: *App) Allocator.Error!void {
        const job = self.nam_download orelse return;
        if (self.nam_download_progress) |*p| p.downloaded = job.progress.load(.monotonic);
        const result = job.box.take() orelse return;
        job.thread.join();
        self.nam_download = null;
        if (self.deferred_fetch == job) self.deferred_fetch = null;
        defer job.destroy(self.gpa);
        if (self.nam_download_progress) |p| self.gpa.free(p.name);
        self.nam_download_progress = null;
        switch (result) {
            .done => {
                _ = self.emitIn(job.log, "Web", "App", "Model", job.log.request, &.{});
                const k = self.emitIn(job.log, "App", "Disk", "CacheWrite", job.log.first, &.{});
                _ = self.emitIn(job.log, "Disk", "App", "Cached", k, &.{});
                if (job.load_after) {
                    switch (try self.namLoadAudioCmd(job.name)) {
                        .ok => |v| {
                            self.cur = .{ .session = job.log.session, .first = job.log.first, .branch = .fetch, .audio_label = if (job.log.logged) "NamModel" else null };
                            defer self.cur = null;
                            try self.sendAudio(.{ .set_nam_model = v.model });
                            const src = try std.fmt.allocPrint(self.gpa, "nam {s}", .{job.name});
                            try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, src);
                            self.setMsgOwned(v.message);
                        },
                        .err => |e| {
                            defer self.gpa.free(e);
                            try self.setMsg("✗ {s}", .{e});
                        },
                    }
                } else {
                    try self.setMsg("NAM capture downloaded: {s}", .{job.name});
                }
                _ = self.emitIn(job.log, "App", "Performer", "NamLoaded", job.log.first, &.{});
            },
            .err => |e| {
                defer freeMsg(self.gpa, e);
                _ = self.emitIn(job.log, "Web", "App", "DownloadFailed", job.log.request, &.{});
                _ = self.emitIn(job.log, "App", "Performer", "NamFailed", job.log.first, &.{});
                self.shared.nam_status.store(4, .monotonic);
                try self.setMsg("✗ {s}", .{e});
            },
        }
    }

    fn reapZombies(self: *App) void {
        var i: usize = 0;
        while (i < self.zombie_downloads.items.len) {
            const j = self.zombie_downloads.items[i];
            if (j.box.take()) |r| {
                switch (r) {
                    .done => {},
                    .err => |e| freeMsg(self.gpa, e),
                }
                j.thread.join();
                j.destroy(self.gpa);
                _ = self.zombie_downloads.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < self.zombie_auths.items.len) {
            const j = self.zombie_auths.items[i];
            if (j.box.take()) |r| {
                switch (r) {
                    .ok => |a| a.deinit(self.gpa),
                    .err => |e| freeMsg(self.gpa, e),
                }
                j.thread.join();
                j.destroy(self.gpa);
                _ = self.zombie_auths.swapRemove(i);
            } else i += 1;
        }
    }

    fn reapDownload(self: *App, j: *DownloadJob, wait: bool) void {
        if (wait) j.thread.join();
        if (j.box.take()) |r| switch (r) {
            .done => {},
            .err => |e| freeMsg(self.gpa, e),
        };
        j.destroy(self.gpa);
    }

    fn reapAuth(self: *App, j: *AuthJob, wait: bool) void {
        if (wait) j.thread.join();
        if (j.box.take()) |r| switch (r) {
            .ok => |a| a.deinit(self.gpa),
            .err => |e| freeMsg(self.gpa, e),
        };
        j.destroy(self.gpa);
    }

    fn reapLlm(self: *App, j: *LlmJob, wait: bool) void {
        if (wait) j.thread.join();
        if (j.box.take()) |r| switch (r) {
            .answer => |a| self.gpa.free(a),
            .commands => |c| freeStrList(self.gpa, c),
            .err => |e| freeMsg(self.gpa, e),
        };
        self.freeLlmJob(j);
    }

    fn freeLlmJob(self: *App, j: *LlmJob) void {
        j.req.deinit(self.gpa);
        self.gpa.free(j.sent_prompt);
        self.gpa.destroy(j);
    }

    fn freeRecJob(self: *App, j: *RecJob) void {
        for (j.phrases) |*p| p.deinit(self.gpa);
        self.gpa.free(j.phrases);
        self.gpa.destroy(j);
    }

    /// Drops the NAM dependency workers of the previous score (their results are discarded).
    fn abandonNamWorkers(self: *App) Allocator.Error!void {
        if (self.nam_download) |j| {
            try self.zombie_downloads.append(self.gpa, j);
            self.nam_download = null;
            if (self.deferred_fetch == j) self.deferred_fetch = null;
        }
        if (self.nam_download_progress) |p| self.gpa.free(p.name);
        self.nam_download_progress = null;
        if (self.tone3000_auth) |j| {
            try self.zombie_auths.append(self.gpa, j);
            self.tone3000_auth = null;
        }
        if (self.pending_tone3000_download) |p| self.gpa.free(p.name);
        self.pending_tone3000_download = null;
        try self.reset(&self.pending_nam_slot, null);
        for (self.live_nam_commands.items) |c| self.gpa.free(c);
        self.live_nam_commands.clearRetainingCapacity();
    }

    // ── Timeline helpers ──────────────────────────────────────────────────

    fn resyncAudioSequence(self: *App, focus_id: ?usize) Allocator.Error!void {
        const target_pos = if (focus_id) |id| (self.positionOf(id) orelse 0) else 0;
        const start = try session.sequenceStartSettings(self.gpa, self.phrases.items);
        try self.sendAudio(.clear);
        try self.sendAudio(.{ .set_bpm = start.bpm });
        try self.sendAudio(.{ .set_sustain = start.sustain });
        try self.sendAudio(.{ .set_vcf_bank = start.vcf });
        try self.sendAudio(.{ .set_fx_settings = start.fx });
        try self.sendAudio(.{ .set_vol = self.vol });
        try self.sendAudio(.{ .set_paused = self.paused });
        for (self.phrases.items) |*p| try self.sendPhraseCopy(p, .add);
        if (self.phrases.items.len > 0) try self.sendAudio(.{ .set_cur_phrase = @min(target_pos, self.phrases.items.len - 1) });
        self.auditioning_jins = false;
    }

    fn resolveIdRef(self: *const App, id_ref: isize) ?usize {
        return resolveIdRefInPhrases(self.phrases.items, id_ref);
    }

    fn positionOf(self: *const App, id: usize) ?usize {
        for (self.phrases.items, 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    fn hasId(self: *const App, id: usize) bool {
        return self.positionOf(id) != null;
    }

    /// The insert position before `before`, or null after setting "✗ no phrase id <before>".
    fn insertPos(self: *App, before: isize) Allocator.Error!?usize {
        const before_id = self.resolveIdRef(before) orelse {
            try self.setMsg("✗ no phrase id {d}", .{before});
            return null;
        };
        return self.positionOf(before_id) orelse self.phrases.items.len;
    }

    const IdPos = struct { id: usize, pos: usize };

    /// The id and position `id_ref` names, or null after setting the Rust's message.
    fn requireEntry(self: *App, id_ref: isize) Allocator.Error!?IdPos {
        const id = self.resolveIdRef(id_ref) orelse {
            try self.setMsg("✗ no phrase id {d}", .{id_ref});
            return null;
        };
        const pos = self.positionOf(id) orelse {
            try self.setMsg("✗ no phrase id {d}", .{id});
            return null;
        };
        return .{ .id = id, .pos = pos };
    }

    /// False (with the message) when the timeline holds max_entries entries.
    fn roomForEntry(self: *App) Allocator.Error!bool {
        if (self.phrases.items.len >= max_entries) {
            try self.setMsg("{s}", .{timeline_full_message});
            return false;
        }
        return true;
    }

    fn takeId(self: *App) usize {
        const id = self.next_phrase_id;
        self.next_phrase_id += 1;
        return id;
    }

    /// Appends `entry` (taking it) and sends a copy to the audio side.
    fn pushEntry(self: *App, entry: Phrase) Allocator.Error!void {
        var e = entry;
        self.phrases.append(self.gpa, e) catch |err| {
            e.deinit(self.gpa);
            return err;
        };
        try self.sendPhraseCopy(&self.phrases.items[self.phrases.items.len - 1], .add);
    }

    fn insertEntry(self: *App, pos: usize, entry: Phrase) Allocator.Error!void {
        var e = entry;
        self.phrases.insert(self.gpa, pos, e) catch |err| {
            e.deinit(self.gpa);
            return err;
        };
        try self.sendInsertCopy(pos, &self.phrases.items[pos]);
    }

    fn replaceEntry(self: *App, pos: usize, entry: Phrase) Allocator.Error!void {
        self.phrases.items[pos].deinit(self.gpa);
        self.phrases.items[pos] = entry;
        try self.sendPhraseCopy(&self.phrases.items[pos], .replace);
    }

    fn controlEntry(self: *App, id: usize, src: []const u8, control: ControlSpec) Allocator.Error!Phrase {
        return sequencer.buildControlEntry(self.gpa, id, src, control);
    }

    fn insertSymControl(self: *App, before: isize, src: []const u8, control: ControlSpec) Allocator.Error!void {
        if (!try self.roomForEntry()) return;
        const pos = (try self.insertPos(before)) orelse return;
        const id = self.takeId();
        try self.insertEntry(pos, try self.controlEntry(id, src, control));
        try self.setMsg("inserted sym at {d}", .{pos});
    }

    fn replaceSymControl(self: *App, id_ref: isize, src: []const u8, control: ControlSpec) Allocator.Error!void {
        const e = (try self.requireEntry(id_ref)) orelse return;
        try self.replaceEntry(e.pos, try self.controlEntry(e.id, src, control));
        try self.setMsg("edited {d} → sym", .{e.id});
    }

    fn insertNamControl(self: *App, before: isize, cmd: NamCommand) Allocator.Error!void {
        const control = session.namTimelineControl(cmd) orelse {
            try self.setMsg("✗ this NAM utility command cannot be scheduled", .{});
            return;
        };
        if (!try self.roomForEntry()) return;
        const before_id = self.resolveIdRef(before) orelse {
            try self.setMsg("✗ no phrase id {d}", .{before});
            return;
        };
        const pos = self.positionOf(before_id) orelse self.phrases.items.len;
        const id = self.takeId();
        const src = (try session.namCommandSrc(self.gpa, cmd)).?;
        defer self.gpa.free(src);
        try self.insertEntry(pos, try self.controlEntry(id, src, control));
        try self.applyNamCommand(cmd);
    }

    fn replaceNamControl(self: *App, id_ref: isize, cmd: NamCommand) Allocator.Error!void {
        const control = session.namTimelineControl(cmd) orelse {
            try self.setMsg("✗ this NAM utility command cannot be scheduled", .{});
            return;
        };
        const e = (try self.requireEntry(id_ref)) orelse return;
        const src = (try session.namCommandSrc(self.gpa, cmd)).?;
        defer self.gpa.free(src);
        try self.replaceEntry(e.pos, try self.controlEntry(e.id, src, control));
        try self.applyNamCommand(cmd);
    }

    fn auditionJins(self: *App, specs: []const JinsSpec) Allocator.Error!?[]u8 {
        const resolved = try sequencer.resolveRhythms(self.gpa, specs, &.{1});
        defer self.gpa.free(resolved);
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(self.gpa);
        try src.appendSlice(self.gpa, "[preview] ");
        for (resolved, 0..) |s, i| {
            if (i > 0) try src.appendSlice(self.gpa, ", ");
            try src.appendSlice(self.gpa, s.src);
        }
        var built = try sequencer.buildPhrase(self.gpa, std.math.maxInt(usize), src.items, resolved, 4, 1);
        var phrase = switch (built) {
            .ok => |p| p,
            .err => |m| return m,
        };
        built = undefined;
        errdefer phrase.deinit(self.gpa);
        const n_freqs = @max(phrase.bar.frequencies.len, 1);
        var walk: std.ArrayList(usize) = .empty;
        defer walk.deinit(self.gpa);
        for (0..n_freqs) |d| try walk.appendSlice(self.gpa, &.{ d, d });
        if (n_freqs > 1) {
            var d = n_freqs - 1;
            while (d > 0) {
                d -= 1;
                try walk.appendSlice(self.gpa, &.{ d, d });
            }
        }
        const groups = try self.gpa.alloc(u8, walk.items.len);
        @memset(groups, 1);
        self.gpa.free(phrase.bar.groups);
        phrase.bar.groups = groups;
        try walk.append(self.gpa, 0);
        const gd = try walk.toOwnedSlice(self.gpa);
        self.gpa.free(phrase.bar.group_degrees);
        phrase.bar.group_degrees = gd;
        try phrase.bar.recomputeEventsAlloc(self.gpa);
        phrase.bar.total_subdivs = phrase.bar.events.len;

        self.paused = false;
        try self.sendAudio(.clear);
        try self.sendAudio(.{ .set_bpm = self.bpm });
        try self.sendAudio(.{ .set_sustain = self.sustain });
        try self.sendAudio(.{ .set_vcf_bank = self.vcf });
        try self.sendAudio(.{ .set_fx_settings = self.fx });
        try self.sendAudio(.{ .set_vol = self.vol });
        try self.sendAudio(.{ .set_paused = false });
        const h = try Phrase.create(self.gpa, phrase);
        try self.sendAudio(.{ .add_phrase = h });
        try self.sendAudio(.{ .set_cur_phrase = 0 });
        self.auditioning_jins = true;
        return null;
    }

    // ── Commands ──────────────────────────────────────────────────────────

    /// One command line: split on ';', each part executed in order; a parse error stops the rest.
    pub fn handleCommand(self: *App, raw: []const u8) Allocator.Error!void {
        var parts = std.mem.splitScalar(u8, raw, ';');
        while (parts.next()) |part_raw| {
            const part = rs.trim(part_raw);
            if (part.len == 0) continue;
            self.part_line = part;
            self.cur = null;
            errdefer {
                self.part_line = null;
                self.cur = null;
            }

            // clockin / clockout <device>: MIDI clock (not ported; see the header)
            if (std.mem.startsWith(u8, part, "clockin ") or std.mem.startsWith(u8, part, "clockout ")) {
                const which = if (std.mem.startsWith(u8, part, "clockin ")) "clockin" else "clockout";
                try self.setMsg("✗ {s}: MIDI clock is not available in this build", .{which});
                try self.endPart();
                continue;
            }

            var parsed = try command.parse(self.gpa, part);
            switch (parsed) {
                .ok => |cmd| {
                    parsed = undefined;
                    try self.execute(cmd);
                    try self.endPart();
                },
                .err => |m| {
                    defer self.gpa.free(m);
                    try self.setMsg("✗ {s}", .{m});
                    try self.endPart();
                    return;
                },
            }
        }
    }

    fn execute(self: *App, cmd: Cmd) Allocator.Error!void {
        defer cmd.deinit(self.gpa);
        const keep_audition = switch (cmd) {
            .create_jins, .audition_jins, .help, .list_jins => true,
            else => false,
        };
        if (self.auditioning_jins and !keep_audition) try self.resyncAudioSequence(null);
        switch (cmd) {
            .quit => {
                self.should_quit = true;
                if (self.beginBranch(.quit, "Quit", &.{}, "Stop")) {
                    const c = &self.cur.?;
                    c.sub += 1;
                    _ = self.log.emit(c.session, c.sub, "App", "Audio", "Stop", null, &.{});
                }
            },
            .help => self.show_help = true,
            .ask_llm => |v| {
                if (llmPromptIsEditRequest(v.prompt)) {
                    try self.askLlmForEdit(v.provider, v.prompt);
                } else {
                    try self.askLlm(v.provider, v.prompt);
                }
            },
            .jump => |v| {
                if (v.times == 1) {
                    try self.setMsg("✗ jump ×1 is a no-op; use j <id> 2 or omit the jump", .{});
                    return;
                }
                if (!try self.roomForEntry()) return;
                const t = (try self.jumpTargets(v.to, v.fail_to)) orelse return;
                const id = self.takeId();
                switch (try sequencer.buildJumpEntry(self.gpa, id, t.to, t.fail, v.times)) {
                    .ok => |entry| try self.pushEntry(entry),
                    .err => |m| {
                        self.next_phrase_id -= 1;
                        defer self.gpa.free(m);
                        try self.setMsg("✗ {s}", .{m});
                        return;
                    },
                }
                self.clearMsg();
            },
            .insert => |v| {
                if (v.specs.len == 0) {
                    try self.setMsg("✗ empty phrase", .{});
                    return;
                }
                if (!try self.roomForEntry()) return;
                const resolved = try sequencer.resolveRhythms(self.gpa, v.specs, self.last_rhythm.items);
                defer self.gpa.free(resolved);
                try self.setLastRhythm(resolved);
                const id = self.takeId();
                var built = try sequencer.buildPhrase(self.gpa, id, v.source, resolved, 4, @max(v.repeat, 1));
                const phrase = switch (built) {
                    .ok => |p| p,
                    .err => |m| {
                        self.next_phrase_id -= 1;
                        defer self.gpa.free(m);
                        try self.setMsg("✗ {s}", .{m});
                        return;
                    },
                };
                built = undefined;
                var ph = phrase;
                const pos = (self.insertPos(v.before) catch |e| {
                    ph.deinit(self.gpa);
                    return e;
                }) orelse {
                    ph.deinit(self.gpa);
                    return;
                };
                try self.insertEntry(pos, ph);
                try self.setMsg("inserted at {d}", .{pos});
            },
            .insert_jump => |v| {
                if (v.times == 1) {
                    try self.setMsg("✗ jump ×1 is a no-op; insert a phrase/control line or use j <id> 2", .{});
                    return;
                }
                if (!try self.roomForEntry()) return;
                const t = (try self.jumpTargets(v.to, v.fail_to)) orelse return;
                const pos = (try self.insertPos(v.before)) orelse return;
                const id = self.takeId();
                switch (try sequencer.buildJumpEntry(self.gpa, id, t.to, t.fail, v.times)) {
                    .ok => |entry| try self.insertEntry(pos, entry),
                    .err => |m| {
                        self.next_phrase_id -= 1;
                        defer self.gpa.free(m);
                        try self.setMsg("✗ {s}", .{m});
                        return;
                    },
                }
                self.clearMsg();
            },
            .insert_bpm => |v| {
                const bpm = switch (try session.applyBpmChange(self.gpa, self.bpm, v.change)) {
                    .ok => |x| x,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const pos = (try self.insertPos(v.before)) orelse return;
                const id = self.takeId();
                const src = try std.fmt.allocPrint(self.gpa, "bpm {d}", .{bpm});
                defer self.gpa.free(src);
                try self.insertEntry(pos, try self.controlEntry(id, src, .{ .set_bpm = bpm }));
                try self.setMsg("inserted bpm at {d}", .{pos});
            },
            .insert_sustain => |v| {
                const secs = switch (try session.applySustainChange(self.gpa, self.sustain, v.change)) {
                    .ok => |x| x,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const pos = (try self.insertPos(v.before)) orelse return;
                const id = self.takeId();
                const src = try std.fmt.allocPrint(self.gpa, "s {d}", .{secs});
                defer self.gpa.free(src);
                try self.insertEntry(pos, try self.controlEntry(id, src, .{ .set_sustain = secs }));
                try self.setMsg("inserted sustain at {d}", .{pos});
            },
            .insert_vcf => |v| {
                switch (try command.applyVcfChange(self.gpa, self.vcf, v.change)) {
                    .ok => {},
                    .err => |m| return self.failOwned(m),
                }
                if (!try self.roomForEntry()) return;
                const pos = (try self.insertPos(v.before)) orelse return;
                const id = self.takeId();
                const src = try session.vcfChangeSrc(self.gpa, v.change);
                defer self.gpa.free(src);
                try self.insertEntry(pos, try self.controlEntry(id, src, .{ .set_vcf = v.change }));
                try self.setMsg("inserted vcf at {d}", .{pos});
            },
            .insert_fx => |v| {
                const settings = switch (try command.applyFxChange(self.gpa, self.fx, v.change)) {
                    .ok => |s| s,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const pos = (try self.insertPos(v.before)) orelse return;
                const id = self.takeId();
                const src = try session.fxChangeSrc(self.gpa, v.change);
                defer self.gpa.free(src);
                try self.insertEntry(pos, try self.controlEntry(id, src, .{ .set_fx = v.change }));
                const d = try describeFx(self.gpa, settings);
                defer self.gpa.free(d);
                try self.setMsg("inserted {s}", .{d});
            },
            .insert_nam => |v| try self.insertNamControl(v.before, v.command),
            .insert_sympathetics => |v| try self.insertSymControl(v.before, if (v.enabled) "sym on" else "sym off", .{ .set_sympathetics = v.enabled }),
            .insert_sympathetic_decay => |v| {
                const src = try std.fmt.allocPrint(self.gpa, "sym decay {d}", .{v.decay});
                defer self.gpa.free(src);
                try self.insertSymControl(v.before, src, .{ .set_sympathetic_decay = v.decay });
            },
            .insert_sympathetic_gain => |v| {
                const src = try std.fmt.allocPrint(self.gpa, "sym drive {d}", .{v.gain});
                defer self.gpa.free(src);
                try self.insertSymControl(v.before, src, .{ .set_sympathetic_gain = v.gain });
            },
            .insert_sympathetic => |v| {
                const src = try session.symChangeSrc(self.gpa, v.change);
                defer self.gpa.free(src);
                try self.insertSymControl(v.before, src, .{ .set_sympathetic = v.change });
            },
            .toggle_pause => |v| {
                if (v.start_id) |sid| {
                    const id = self.resolveIdRef(sid) orelse {
                        try self.setMsg("✗ no phrase id {d}", .{sid});
                        return;
                    };
                    // z <id>: queue the address for the next phrase exit.
                    if (self.hasId(id)) {
                        try self.sendAudio(.{ .queue_next_phrase = id });
                        try self.setMsg("next → phrase {d}", .{id});
                    } else {
                        try self.setMsg("✗ no phrase id {d}", .{id});
                    }
                } else {
                    // z alone: toggle pause; restart from 0 when unpausing
                    self.paused = !self.paused;
                    if (!self.paused) try self.sendAudio(.{ .set_cur_phrase = 0 });
                    try self.sendAudio(.{ .set_paused = self.paused });
                    try self.setMsg("{s}", .{if (self.paused) "⏸ paused" else "▶ playing"});
                }
            },
            .set_vol => |v| {
                self.vol = v;
                try self.sendAudio(.{ .set_vol = v });
                if (try self.saveGlobals()) |err| {
                    defer self.gpa.free(err);
                    try self.setMsg("✗ {s}", .{err});
                } else {
                    try self.setMsg("vol → {f}", .{rfix(v, 2)});
                }
            },
            .record => |reps| try self.startRecording(reps),
            .rotate => {
                if (self.phrases.items.len < 2) {
                    try self.setMsg("nothing to rotate", .{});
                } else {
                    const first = self.phrases.orderedRemove(0);
                    self.phrases.appendAssumeCapacity(first);
                    try self.sendAudio(.rotate);
                    self.clearMsg();
                }
            },
            .move_up => |id_ref| {
                const e = (try self.requireEntry(id_ref)) orelse return;
                if (e.pos == 0) {
                    try self.setMsg("id {d} is already at top", .{e.id});
                    return;
                }
                std.mem.swap(Phrase, &self.phrases.items[e.pos - 1], &self.phrases.items[e.pos]);
                try self.sendAudio(.{ .move_phrase = .{ .id = e.id, .down = false } });
                try self.setMsg("moved {d} up", .{e.id});
            },
            .move_down => |id_ref| {
                const e = (try self.requireEntry(id_ref)) orelse return;
                if (e.pos + 1 >= self.phrases.items.len) {
                    try self.setMsg("id {d} is already at bottom", .{e.id});
                    return;
                }
                std.mem.swap(Phrase, &self.phrases.items[e.pos], &self.phrases.items[e.pos + 1]);
                try self.sendAudio(.{ .move_phrase = .{ .id = e.id, .down = true } });
                try self.setMsg("moved {d} down", .{e.id});
            },
            .list_jins => self.show_jins = true,
            .audition_jins => |v| {
                var label: std.ArrayList(u8) = .empty;
                defer label.deinit(self.gpa);
                for (v.specs, 0..) |s, i| {
                    if (i > 0) try label.appendSlice(self.gpa, ", ");
                    try label.appendSlice(self.gpa, s.src);
                }
                if (try self.auditionJins(v.specs)) |err| {
                    defer self.gpa.free(err);
                    try self.setMsg("✗ {s}", .{err});
                } else {
                    try self.setMsg("auditioning {s}", .{label.items});
                }
            },
            .create_jins => |v| switch (try tuning.Maqam.create(v.name, v.ratios)) {
                .ok => try self.setMsg("created jins {s}", .{v.name}),
                .err => |e| try self.setMsg("✗ {s}", .{e}),
            },
            .delete_jins => |v| {
                if (tuning.Maqam.delete(v.name)) {
                    try self.setMsg("deleted jins {s}", .{v.name});
                } else {
                    try self.setMsg("✗ no jins '{s}'", .{v.name});
                }
            },
            .save => |v| try self.saveCommand(v.path),
            .load => |v| try self.loadCommand(v.path),
            .clear => {
                for (self.phrases.items) |*p| p.deinit(self.gpa);
                self.phrases.clearRetainingCapacity();
                self.next_phrase_id = 0;
                try self.sendAudio(.clear);
                try self.setMsg("cleared", .{});
            },
            .stop => {
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                try self.pushEntry(try self.controlEntry(id, "stop", .stop));
                try self.setMsg("stop line added", .{});
            },
            .sympathetics => |enabled| {
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                try self.pushEntry(try self.controlEntry(id, if (enabled) "sym on" else "sym off", .{ .set_sympathetics = enabled }));
                try self.sendAudio(.{ .set_sympathetics = enabled });
                try self.setMsg("{s}", .{if (enabled) "sympathetic strings on" else "sympathetic strings off"});
            },
            .sympathetic_decay => |decay| {
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try std.fmt.allocPrint(self.gpa, "sym decay {d}", .{decay});
                defer self.gpa.free(src);
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_sympathetic_decay = decay }));
                try self.sendAudio(.{ .set_sympathetic_decay = decay });
                try self.setMsg("sym decay {f}", .{rfix(decay, 5)});
            },
            .sympathetic_gain => |gain| {
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try std.fmt.allocPrint(self.gpa, "sym gain {d}", .{gain});
                defer self.gpa.free(src);
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_sympathetic_gain = gain }));
                try self.sendAudio(.{ .set_sympathetic_gain = gain });
                try self.setMsg("sym gain {f}", .{rfix(gain, 2)});
            },
            .sympathetic => |change| {
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try session.symChangeSrc(self.gpa, change);
                defer self.gpa.free(src);
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_sympathetic = change }));
                try self.sendAudio(.{ .set_sympathetic = change });
                try self.setMsg("{s}", .{src});
            },
            .set_bpm => |change| {
                const bpm = switch (try session.applyBpmChange(self.gpa, self.bpm, change)) {
                    .ok => |x| x,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try std.fmt.allocPrint(self.gpa, "bpm {d}", .{bpm});
                defer self.gpa.free(src);
                self.bpm = bpm;
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_bpm = bpm }));
                try self.sendAudio(.{ .set_bpm = bpm });
                try self.setMsg("BPM line → {f}", .{rfix(bpm, 2)});
            },
            .tune_to => |pitch| {
                tuning.tuneToStandardPitch(pitch);
                self.tune_to = pitch;
                var buf: [3]u8 = undefined;
                const tok = pitch.sourceTokenBuf(&buf);
                if (try self.saveGlobals()) |err| {
                    defer self.gpa.free(err);
                    try self.setMsg("✗ {s}", .{err});
                } else {
                    try self.setMsg("tuneto {s} → standard MIDI {s}", .{ tok, tok });
                }
            },
            .set_sustain => |change| {
                const secs = switch (try session.applySustainChange(self.gpa, self.sustain, change)) {
                    .ok => |x| x,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try std.fmt.allocPrint(self.gpa, "s {d}", .{secs});
                defer self.gpa.free(src);
                self.sustain = secs;
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_sustain = secs }));
                try self.sendAudio(.{ .set_sustain = secs });
                try self.setMsg("s line → {f}s", .{rfix(secs, 2)});
            },
            .set_vcf => |change| {
                const setting = switch (try command.applyVcfChange(self.gpa, self.vcf, change)) {
                    .ok => |s| s,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try session.vcfChangeSrc(self.gpa, change);
                defer self.gpa.free(src);
                self.vcf.apply(setting);
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_vcf = change }));
                try self.sendAudio(.{ .set_vcf = change });
                const d = try describeVcf(self.gpa, setting);
                defer self.gpa.free(d);
                try self.setMsg("VCF line → {s}", .{d});
            },
            .set_fx => |change| {
                const settings = switch (try command.applyFxChange(self.gpa, self.fx, change)) {
                    .ok => |s| s,
                    .err => |m| return self.failOwned(m),
                };
                if (!try self.roomForEntry()) return;
                const id = self.takeId();
                const src = try session.fxChangeSrc(self.gpa, change);
                defer self.gpa.free(src);
                self.fx = settings;
                try self.pushEntry(try self.controlEntry(id, src, .{ .set_fx = change }));
                try self.sendAudio(.{ .set_fx = change });
                const d = try describeFx(self.gpa, settings);
                defer self.gpa.free(d);
                try self.setMsg("FX line → {s}", .{d});
            },
            .set_nam => |nc| {
                if (session.namTimelineControl(nc)) |control| {
                    if (!try self.roomForEntry()) return;
                    const id = self.takeId();
                    const src = (try session.namCommandSrc(self.gpa, nc)).?;
                    defer self.gpa.free(src);
                    try self.pushEntry(try self.controlEntry(id, src, control));
                }
                try self.applyNamCommand(nc);
            },
            .edit_jump => |v| {
                if (v.times == 1) {
                    try self.setMsg("✗ jump ×1 is a no-op; edit the row to a phrase/control line or use j <id> 2", .{});
                    return;
                }
                const id = self.resolveIdRef(v.id) orelse {
                    try self.setMsg("✗ no phrase id {d}", .{v.id});
                    return;
                };
                const t = (try self.jumpTargets(v.to, v.fail_to)) orelse return;
                const pos = self.positionOf(id) orelse {
                    try self.setMsg("✗ no phrase id {d}", .{id});
                    return;
                };
                switch (try sequencer.buildJumpEntry(self.gpa, id, t.to, t.fail, v.times)) {
                    .ok => |entry| try self.replaceEntry(pos, entry),
                    .err => |m| return self.failOwned(m),
                }
                try self.setMsg("edited {d} → jump to {d} ×{d}", .{ id, t.to, v.times });
            },
            .edit => |v| {
                const e = (try self.requireEntry(v.id)) orelse return;
                const resolved = try sequencer.resolveRhythms(self.gpa, v.specs, self.last_rhythm.items);
                defer self.gpa.free(resolved);
                if (resolved.len == 0) {
                    try self.setMsg("✗ empty phrase", .{});
                    return;
                }
                try self.setLastRhythm(resolved);
                const phrase = switch (try sequencer.buildPhrase(self.gpa, e.id, v.source, resolved, 4, @max(v.repeat, 1))) {
                    .ok => |p| p,
                    .err => |m| return self.failOwned(m),
                };
                try self.replaceEntry(e.pos, phrase);
                // Editing establishes the score-design position. Move playback
                // to the edited phrase so the TUI immediately marks it current
                // and the audio thread can publish its jump-aware successor.
                self.shared.cur_phrase.store(e.pos, .monotonic);
                self.shared.cur_subdiv.store(0, .monotonic);
                self.shared.cur_plays.store(0, .monotonic);
                self.shared.next_phrase.store(shared_mod.none, .monotonic);
                self.shared.exit_phrase.store(shared_mod.none, .monotonic);
                try self.sendAudio(.{ .set_cur_phrase = e.pos });
                try self.setMsg("edited {d}", .{e.id});
            },
            .edit_bpm => |v| {
                const e = (try self.requireEntry(v.id)) orelse return;
                const bpm = switch (try session.applyBpmChange(self.gpa, self.bpm, v.change)) {
                    .ok => |x| x,
                    .err => |m| return self.failOwned(m),
                };
                const src = try std.fmt.allocPrint(self.gpa, "bpm {d}", .{bpm});
                defer self.gpa.free(src);
                try self.replaceEntry(e.pos, try self.controlEntry(e.id, src, .{ .set_bpm = bpm }));
                try self.setMsg("edited {d} → bpm {f}", .{ e.id, rfix(bpm, 2) });
            },
            .edit_sustain => |v| {
                const e = (try self.requireEntry(v.id)) orelse return;
                const secs = switch (try session.applySustainChange(self.gpa, self.sustain, v.change)) {
                    .ok => |x| x,
                    .err => |m| return self.failOwned(m),
                };
                const src = try std.fmt.allocPrint(self.gpa, "s {d}", .{secs});
                defer self.gpa.free(src);
                try self.replaceEntry(e.pos, try self.controlEntry(e.id, src, .{ .set_sustain = secs }));
                try self.setMsg("edited {d} → s {f}s", .{ e.id, rfix(secs, 2) });
            },
            .edit_vcf => |v| {
                const e = (try self.requireEntry(v.id)) orelse return;
                const setting = switch (try command.applyVcfChange(self.gpa, self.vcf, v.change)) {
                    .ok => |s| s,
                    .err => |m| return self.failOwned(m),
                };
                const src = try session.vcfChangeSrc(self.gpa, v.change);
                defer self.gpa.free(src);
                try self.replaceEntry(e.pos, try self.controlEntry(e.id, src, .{ .set_vcf = v.change }));
                const d = try describeVcf(self.gpa, setting);
                defer self.gpa.free(d);
                try self.setMsg("edited {d} → {s}", .{ e.id, d });
            },
            .edit_fx => |v| {
                const e = (try self.requireEntry(v.id)) orelse return;
                const settings = switch (try command.applyFxChange(self.gpa, self.fx, v.change)) {
                    .ok => |s| s,
                    .err => |m| return self.failOwned(m),
                };
                const src = try session.fxChangeSrc(self.gpa, v.change);
                defer self.gpa.free(src);
                try self.replaceEntry(e.pos, try self.controlEntry(e.id, src, .{ .set_fx = v.change }));
                const d = try describeFx(self.gpa, settings);
                defer self.gpa.free(d);
                try self.setMsg("edited {d} → {s}", .{ e.id, d });
            },
            .edit_nam => |v| try self.replaceNamControl(v.id, v.command),
            .edit_sympathetics => |v| try self.replaceSymControl(v.id, if (v.enabled) "sym on" else "sym off", .{ .set_sympathetics = v.enabled }),
            .edit_sympathetic_decay => |v| {
                const src = try std.fmt.allocPrint(self.gpa, "sym decay {d}", .{v.decay});
                defer self.gpa.free(src);
                try self.replaceSymControl(v.id, src, .{ .set_sympathetic_decay = v.decay });
            },
            .edit_sympathetic_gain => |v| {
                const src = try std.fmt.allocPrint(self.gpa, "sym gain {d}", .{v.gain});
                defer self.gpa.free(src);
                try self.replaceSymControl(v.id, src, .{ .set_sympathetic_gain = v.gain });
            },
            .edit_sympathetic => |v| {
                const src = try session.symChangeSrc(self.gpa, v.change);
                defer self.gpa.free(src);
                try self.replaceSymControl(v.id, src, .{ .set_sympathetic = v.change });
            },
            .delete_bars => |ids| {
                var not_found: std.ArrayList(isize) = .empty;
                defer not_found.deinit(self.gpa);
                for (ids) |id_ref| {
                    const id = self.resolveIdRef(id_ref) orelse {
                        try not_found.append(self.gpa, id_ref);
                        continue;
                    };
                    if (self.positionOf(id)) |pos| {
                        var removed = self.phrases.orderedRemove(pos);
                        const rid = removed.id;
                        removed.deinit(self.gpa);
                        try self.sendAudio(.{ .remove_phrase = rid });
                    } else {
                        try not_found.append(self.gpa, id_ref);
                    }
                }
                if (not_found.items.len > 0) {
                    var s: std.ArrayList(u8) = .empty;
                    defer s.deinit(self.gpa);
                    for (not_found.items, 0..) |i, k| {
                        if (k > 0) try s.append(self.gpa, ' ');
                        try s.print(self.gpa, "{d}", .{i});
                    }
                    try self.setMsg("✗ no id {s}", .{s.items});
                } else {
                    self.clearMsg();
                }
            },
            .add_phrase => |v| {
                if (v.specs.len == 0) {
                    try self.setMsg("✗ empty phrase", .{});
                    return;
                }
                if (!try self.roomForEntry()) return;
                const resolved = try sequencer.resolveRhythms(self.gpa, v.specs, self.last_rhythm.items);
                defer self.gpa.free(resolved);
                try self.setLastRhythm(resolved);
                const peak: usize = if (self.phrases.items.len == 0) 4 else blk: {
                    var total: usize = 0;
                    for (self.phrases.items) |p| total += p.bar.total_subdivs;
                    const count = @max(self.phrases.items.len, 1);
                    break :blk std.math.clamp(total / count / 2, 2, 4);
                };
                const id = self.takeId();
                const phrase = switch (try sequencer.buildPhrase(self.gpa, id, v.source, resolved, peak, @max(v.repeat, 1))) {
                    .ok => |p| p,
                    .err => |m| {
                        self.next_phrase_id -= 1;
                        return self.failOwned(m);
                    },
                };
                try self.pushEntry(phrase);
                self.clearMsg();
            },
        }
    }

    fn failOwned(self: *App, m: []u8) Allocator.Error!void {
        defer self.gpa.free(m);
        try self.setMsg("✗ {s}", .{m});
    }

    fn setLastRhythm(self: *App, resolved: []const sequencer.BarSpec) Allocator.Error!void {
        if (resolved.len == 0) return;
        const g = resolved[resolved.len - 1].groups;
        const copy = try self.gpa.dupe(u8, g);
        defer self.gpa.free(copy);
        self.last_rhythm.clearRetainingCapacity();
        try self.last_rhythm.appendSlice(self.gpa, copy);
    }

    const JumpTargets = struct { to: usize, fail: ?usize };

    fn jumpTargets(self: *App, to_ref: isize, fail_ref: ?isize) Allocator.Error!?JumpTargets {
        const to = self.resolveIdRef(to_ref) orelse {
            try self.setMsg("✗ no phrase id {d}", .{to_ref});
            return null;
        };
        if (!self.hasId(to)) {
            try self.setMsg("✗ no phrase id {d}", .{to});
            return null;
        }
        var fail: ?usize = null;
        if (fail_ref) |value| {
            const id = self.resolveIdRef(value);
            if (id == null or !self.hasId(id.?)) {
                try self.setMsg("✗ no failure phrase id {d}", .{value});
                return null;
            }
            fail = id;
        }
        return .{ .to = to, .fail = fail };
    }

    fn startRecording(self: *App, reps: usize) Allocator.Error!void {
        if (self.recordingPending()) {
            try self.setMsg("✗ already rendering", .{});
            return;
        }
        const gpa = self.gpa;
        const phrases = try gpa.alloc(Phrase, self.phrases.items.len);
        var filled: usize = 0;
        errdefer {
            for (phrases[0..filled]) |*p| p.deinit(gpa);
            gpa.free(phrases);
        }
        for (self.phrases.items) |*p| {
            phrases[filled] = try p.clone(gpa);
            filled += 1;
        }
        const start = try session.sequenceStartSettings(gpa, self.phrases.items);
        const job = try gpa.create(RecJob);
        errdefer gpa.destroy(job);
        job.* = .{ .phrases = phrases, .bpm = start.bpm, .sustain = start.sustain, .vcf = start.vcf, .fx = start.fx, .reps = reps };
        job.thread = std.Thread.spawn(.{}, recWorker, .{ self, job }) catch {
            try self.setMsg("✗ could not start the recording thread", .{});
            for (phrases) |*p| p.deinit(gpa);
            gpa.free(phrases);
            gpa.destroy(job);
            return;
        };
        self.rec_job = job;
        if (self.beginBranch(.record, "Record", &.{}, null)) {
            const c = self.cur.?;
            job.log = .{ .logged = true, .session = c.session, .first = c.first };
            job.log.request = self.log.emit(c.session, 0, "App", "Recorder", "Render", c.first, &.{});
        }
        try self.setMsg("◉ rendering {d}×…", .{reps});
    }

    fn recWorker(self: *App, job: *RecJob) void {
        const r = self.record_fn(self.gpa, self.io, self.shared, job.phrases, job.bpm, job.sustain, job.vcf, job.fx, job.reps);
        _ = job.box.put(r);
    }

    fn saveCommand(self: *App, path_opt: ?[]const u8) Allocator.Error!void {
        const path_src = path_opt orelse self.session_path orelse {
            try self.setMsg("✗ usage: save <path>", .{});
            return;
        };
        const path = try self.gpa.dupe(u8, path_src);
        defer self.gpa.free(path);
        const logged = self.beginBranch(.session, "Session", &.{}, null);
        const c = self.cur;
        const w = if (logged) self.log.emit(c.?.session, 0, "App", "Disk", "ReadOrWrite", c.?.first, &.{}) else 0;
        if (try self.saveSession(path)) |err| {
            defer self.gpa.free(err);
            if (logged) {
                _ = self.log.emit(c.?.session, 0, "Disk", "App", "Failed", w, &.{});
                _ = self.log.emit(c.?.session, 0, "App", "Performer", "LoadFailed", c.?.first, &.{});
            }
            try self.setMsg("✗ save failed: {s}", .{err});
            return;
        }
        if (logged) {
            _ = self.log.emit(c.?.session, 0, "Disk", "App", "Done", w, &.{});
            _ = self.log.emit(c.?.session, 0, "App", "Performer", "Loaded", c.?.first, &.{});
        }
        try self.reset(&self.session_path, path);
        try self.setMsg("saved session → {s}", .{path});
    }

    fn loadCommand(self: *App, path_in: []const u8) Allocator.Error!void {
        const path = try self.gpa.dupe(u8, path_in);
        defer self.gpa.free(path);
        const logged = self.beginBranch(.session, "Session", &.{}, "Resync");
        const c = self.cur;
        const w = if (logged) self.log.emit(c.?.session, 0, "App", "Disk", "ReadOrWrite", c.?.first, &.{}) else 0;
        const read_done = struct {
            fn f(app: *App, l: bool, ci: ?Interaction, wt: u64) void {
                if (l) _ = app.log.emit(ci.?.session, 0, "Disk", "App", "Done", wt, &.{});
            }
        }.f;
        if (try self.loadSession(path, .{ .logged = logged, .cur = c, .w = w, .done = read_done })) |err| {
            defer self.gpa.free(err);
            if (logged) {
                _ = self.log.emit(c.?.session, 0, "Disk", "App", "Failed", w, &.{});
                _ = self.log.emit(c.?.session, 0, "App", "Performer", "LoadFailed", c.?.first, &.{});
            }
            try self.setMsg("✗ load failed: {s}", .{err});
            return;
        }
        try self.reset(&self.session_path, path);
        const detail = self.message;
        self.message = null;
        if (detail) |d| {
            const keep = self.pending_nam_slot != null or self.nam_download_progress != null or
                std.mem.startsWith(u8, d, "TONE3000 authorization") or std.mem.startsWith(u8, d, "TONE3000 login") or
                std.mem.indexOf(u8, d, "TONE3000_CLIENT_ID") != null;
            if (keep) {
                self.message = d;
            } else if (std.mem.startsWith(u8, d, "loaded session; ")) {
                defer self.gpa.free(d);
                var rest: []const u8 = d;
                while (std.mem.startsWith(u8, rest, "loaded session; ")) rest = rest["loaded session; ".len..];
                try self.setMsg("loaded session ← {s}; {s}", .{ path, rest });
            } else {
                self.gpa.free(d);
                try self.setMsg("loaded session ← {s}", .{path});
            }
        } else {
            try self.setMsg("loaded session ← {s}", .{path});
        }
        if (logged) _ = self.log.emit(c.?.session, 0, "App", "Performer", "Loaded", c.?.first, &.{});
    }

    // ── NAM ───────────────────────────────────────────────────────────────

    fn applyNamCommand(self: *App, nc: NamCommand) Allocator.Error!void {
        const display_src = try session.namCommandSrc(self.gpa, nc);
        var src_taken = false;
        defer if (!src_taken) if (display_src) |s| self.gpa.free(s);
        switch (nc) {
            .login => try self.startTone3000Login(),
            .logout => {
                if (self.pending_tone3000_download) |p| self.gpa.free(p.name);
                self.pending_tone3000_download = null;
                const path = self.tone3000AuthPath();
                if (self.cwd.deleteFile(self.io, path)) |_| {
                    try self.setMsg("TONE3000 logged out", .{});
                } else |err| switch (err) {
                    error.FileNotFound => try self.setMsg("TONE3000 was not logged in", .{}),
                    else => try self.setMsg("✗ could not remove TONE3000 credentials: {s}", .{ioErrText(err)}),
                }
            },
            .off => {
                try self.sendAudio(.{ .set_nam_enabled = false });
                src_taken = true;
                try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, display_src);
                try self.setMsg("NAM input amp off", .{});
            },
            .list => {
                const cache_dir = self.namCacheDir();
                var cached = try self.listCachedNamModels(cache_dir);
                defer cached.deinit(self.gpa);
                var files = try self.listCurrentDirNamFiles();
                defer files.deinit(self.gpa);
                switch (cached) {
                    .err => |e| try self.setMsg("✗ cannot list NAM cache {s}: {s}; create ./.nam or set MAQAM_NAM_CACHE_DIR", .{ cache_dir, e }),
                    .ok => |c| switch (files) {
                        .err => |e| try self.setMsg("✗ cannot list NAM files in current directory: {s}; check directory permissions", .{e}),
                        .ok => |f| {
                            if (c.len == 0 and f.len == 0) {
                                try self.setMsg("no NAM captures found; {s} is ready. Run `nam import URL as name` to download into it, or `nam import FILENAME.nam as name` to cache a local file", .{cache_dir});
                            } else {
                                var out: std.ArrayList(u8) = .empty;
                                defer out.deinit(self.gpa);
                                if (c.len > 0) {
                                    try out.appendSlice(self.gpa, "cached: ");
                                    for (c, 0..) |n, i| {
                                        if (i > 0) try out.appendSlice(self.gpa, "  ");
                                        try out.appendSlice(self.gpa, n);
                                    }
                                }
                                if (f.len > 0) {
                                    if (c.len > 0) try out.appendSlice(self.gpa, " | ");
                                    try out.appendSlice(self.gpa, "files: ");
                                    for (f, 0..) |n, i| {
                                        if (i > 0) try out.appendSlice(self.gpa, "  ");
                                        try out.appendSlice(self.gpa, n);
                                    }
                                }
                                try self.setMsg("{s}", .{out.items});
                            }
                        },
                    },
                }
            },
            .search => |v| {
                var f: Failure = .{ .gpa = self.gpa };
                defer f.deinit();
                if (findNamCaptures(&f, self.http, self.gpa, self.io, v.query)) |results| {
                    self.setMsgOwned(results);
                } else |e| {
                    const m = f.take(e);
                    defer freeMsg(self.gpa, m);
                    try self.setMsg("✗ {s}", .{m});
                }
            },
            .gain => |gain| {
                try self.sendAudio(.{ .set_nam_gain = gain });
                src_taken = true;
                try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, display_src);
                try self.setMsg("NAM input gain {f}", .{rfix(gain, 2)});
            },
            .input => |route| {
                try self.sendAudio(.{ .set_nam_input = route });
                src_taken = true;
                try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, display_src);
                try self.setMsg("NAM input → {s}", .{session.namInputName(route)});
            },
            .latency => |route| {
                // A new measurement replaces the one in flight (the Rust dropped its receiver).
                _ = self.latency_box.take();
                self.latency_pending = true;
                try self.sendAudio(.{ .measure_input_latency = .{ .input = route, .result = self.latency_box } });
                try self.setMsg("measuring capture-to-playback device timestamps for {s} input…", .{session.namInputName(route)});
            },
            .import => |v| {
                if (isHttpUrl(v.path)) {
                    try self.startNamDownload(v.path, v.name, false);
                    return;
                }
                if (!self.isFile(v.path)) {
                    try self.setMsg("✗ NAM model file not found: {s}; run `nam import URL as name` to download into ./.nam, or `nam import FILENAME.nam as name` for a real local file", .{v.path});
                    return;
                }
                const cache_dir = self.namCacheDir();
                self.cwd.createDirPath(self.io, cache_dir) catch |err| {
                    try self.setMsg("✗ cannot create NAM cache {s}: {s}; create ./.nam or set MAQAM_NAM_CACHE_DIR to a writable directory", .{ cache_dir, ioErrText(err) });
                    return;
                };
                const cache_name = blk: {
                    if (v.name) |n| {
                        const s = try sanitizeNamCacheName(self.gpa, n);
                        if (s.len > 0) break :blk s;
                        self.gpa.free(s);
                    }
                    break :blk try namCacheNameFromPath(self.gpa, v.path);
                };
                defer self.gpa.free(cache_name);
                const dest = try cachePath(self.gpa, cache_dir, cache_name);
                defer self.gpa.free(dest);
                self.cwd.copyFile(v.path, self.cwd, dest, self.io, .{}) catch |err| {
                    try self.setMsg("✗ cannot import NAM model to {s}: {s}; check file permissions on ./.nam or set MAQAM_NAM_CACHE_DIR", .{ dest, ioErrText(err) });
                    return;
                };
                try self.setMsg("NAM capture imported: {s}", .{cache_name});
            },
            .pin => |v| {
                const name = try sanitizeNamCacheName(self.gpa, v.name);
                defer self.gpa.free(name);
                if (name.len == 0) {
                    try self.setMsg("✗ NAM pin name is empty", .{});
                    return;
                }
                if (self.session_path) |path| {
                    const pinned = try std.fmt.allocPrint(self.gpa, "nam pin {s} as {s}", .{ v.url, name });
                    defer self.gpa.free(pinned);
                    if (try self.pinNamReference(path, name, pinned)) |err| {
                        defer self.gpa.free(err);
                        try self.setMsg("✗ could not update {s}: {s}", .{ path, err });
                        return;
                    }
                }
                try self.reset(&self.pending_nam_slot, null);
                const src = try std.fmt.allocPrint(self.gpa, "nam pin {s} as {s}", .{ v.url, name });
                try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, src);
                try self.startNamDownload(v.url, name, true);
            },
            .tone3000 => |v| {
                const name = try sanitizeNamCacheName(self.gpa, v.name);
                defer self.gpa.free(name);
                const src = try std.fmt.allocPrint(self.gpa, "nam tone3000 {d} as {s}", .{ v.tone_id, name });
                if (self.session_path) |path| {
                    if (try self.pinNamReference(path, name, src)) |err| {
                        defer self.gpa.free(err);
                        self.gpa.free(src);
                        try self.setMsg("✗ could not update {s}: {s}", .{ path, err });
                        return;
                    }
                }
                try self.reset(&self.pending_nam_slot, null);
                try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, src);
                try self.startTone3000Download(v.tone_id, name);
            },
            .load => |v| {
                if (isHttpUrl(v.path)) {
                    try self.startNamDownload(v.path, null, true);
                    return;
                }
                switch (try self.namLoadAudioCmd(v.path)) {
                    .ok => |r| {
                        try self.sendAudio(.{ .set_nam_model = r.model });
                        src_taken = true;
                        try session.replaceLiveNamCommand(self.gpa, &self.live_nam_commands, display_src);
                        self.setMsgOwned(r.message);
                    },
                    .err => |e| {
                        defer self.gpa.free(e);
                        try self.setMsg("✗ {s}", .{e});
                    },
                }
            },
        }
    }

    fn startNamDownload(self: *App, url: []const u8, name: ?[]const u8, load_after: bool) Allocator.Error!void {
        if (self.nam_download != null) {
            try self.setMsg("✗ NAM download already running; wait for it to finish, then run the command again", .{});
            return;
        }
        const cache_dir = self.namCacheDir();
        self.cwd.createDirPath(self.io, cache_dir) catch |err| {
            try self.setMsg("✗ cannot create NAM cache {s}: {s}; create ./.nam or set MAQAM_NAM_CACHE_DIR to a writable directory", .{ cache_dir, ioErrText(err) });
            return;
        };
        const cache_name = blk: {
            if (name) |n| {
                const s = try sanitizeNamCacheName(self.gpa, n);
                if (s.len > 0) break :blk s;
                self.gpa.free(s);
            }
            break :blk try namCacheNameFromUrl(self.gpa, url);
        };
        if (cache_name.len == 0) {
            self.gpa.free(cache_name);
            try self.setMsg("✗ cannot infer a NAM cache name from that URL; run `nam import URL as name`", .{});
            return;
        }
        const job = try self.newDownloadJob(try self.gpa.dupe(u8, url), cache_name, load_after);
        try self.setMsg("downloading NAM capture → {s}", .{cache_name});
        try self.spawnDownload(job);
    }

    /// A job taking `url` and `cache_name` (sanitized) with the cache directory copied.
    fn newDownloadJob(self: *App, url: ?[]u8, cache_name: []u8, load_after: bool) Allocator.Error!*DownloadJob {
        errdefer {
            if (url) |u| self.gpa.free(u);
            self.gpa.free(cache_name);
        }
        const dir = try self.gpa.dupe(u8, self.namCacheDir());
        errdefer self.gpa.free(dir);
        const job = try self.gpa.create(DownloadJob);
        job.* = .{ .url = url, .cache_dir = dir, .name = cache_name, .load_after = load_after };
        return job;
    }

    fn spawnDownload(self: *App, job: *DownloadJob) Allocator.Error!void {
        const pname = try self.gpa.dupe(u8, job.name);
        job.thread = std.Thread.spawn(.{}, downloadWorker, .{ self, job }) catch {
            self.gpa.free(pname);
            job.destroy(self.gpa);
            try self.setMsg("✗ could not start the NAM download thread", .{});
            return;
        };
        self.nam_download = job;
        if (self.nam_download_progress) |p| self.gpa.free(p.name);
        self.nam_download_progress = .{ .name = pname, .downloaded = 0, .total = null, .load_after = job.load_after };
        if (self.cur == null) {
            self.logFetchStart(job);
            // Outside a command line (a login finished in tick) the interaction ends here.
            if (self.part_line == null) self.cur = null;
        } else if (self.cur.?.branch != .fetch) {
            self.deferred_fetch = job;
        }
    }

    fn startTone3000Download(self: *App, tone_id: u64, name_in: []const u8) Allocator.Error!void {
        const name = try sanitizeNamCacheName(self.gpa, name_in);
        if (name.len == 0) {
            self.gpa.free(name);
            try self.setMsg("✗ NAM tone3000 name is empty", .{});
            return;
        }
        var f: Failure = .{ .gpa = self.gpa };
        defer f.deinit();
        const token = self.tone3000AccessToken(&f) catch |e| switch (e) {
            error.OutOfMemory => {
                self.gpa.free(name);
                return error.OutOfMemory;
            },
            error.Fail => {
                self.shared.nam_status.store(2, .monotonic);
                if (self.pending_tone3000_download) |p| self.gpa.free(p.name);
                self.pending_tone3000_download = .{ .tone_id = tone_id, .name = name };
                try self.startTone3000Login();
                return;
            },
        };
        self.shared.nam_status.store(3, .monotonic);
        if (self.nam_download) |old| {
            // The Rust replaced the receiver of a running download.
            try self.zombie_downloads.append(self.gpa, old);
            self.nam_download = null;
            if (self.deferred_fetch == old) self.deferred_fetch = null;
        }
        const job = self.newDownloadJob(null, name, true) catch |e| {
            self.gpa.free(token);
            return e;
        };
        job.tone_id = tone_id;
        job.token = token;
        try self.setMsg("downloading TONE3000 tone {d} → {s}", .{ tone_id, job.name });
        try self.spawnDownload(job);
    }

    fn startTone3000Login(self: *App) Allocator.Error!void {
        if (self.tone3000_auth != null) {
            try self.setMsg("TONE3000 login is already waiting in the browser", .{});
            return;
        }
        const client_id = blk: {
            if (self.env.get("TONE3000_CLIENT_ID")) |v| break :blk try self.gpa.dupe(u8, v);
            if (self.env.get("TONE3000_PUBLISHABLE_KEY")) |v| break :blk try self.gpa.dupe(u8, v);
            var f: Failure = .{ .gpa = self.gpa };
            defer f.deinit();
            if (self.loadTone3000Auth(&f)) |auth| {
                defer auth.deinit(self.gpa);
                break :blk try self.gpa.dupe(u8, auth.client_id);
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Fail => break :blk try self.gpa.dupe(u8, TONE3000_PUBLISHABLE_CLIENT_ID),
            }
        };
        const job = self.gpa.create(AuthJob) catch |e| {
            self.gpa.free(client_id);
            return e;
        };
        job.* = .{ .client_id = client_id };
        job.thread = std.Thread.spawn(.{}, authWorker, .{ self, job }) catch {
            job.destroy(self.gpa);
            try self.setMsg("✗ could not start the TONE3000 login thread", .{});
            return;
        };
        self.tone3000_auth = job;
        try self.setMsg("TONE3000 login opened in your browser; maqam-live is still running", .{});
    }

    fn authWorker(self: *App, job: *AuthJob) void {
        var f: Failure = .{ .gpa = self.gpa };
        defer f.deinit();
        if (tone3000BrowserLogin(&f, self.http, self.gpa, self.io, job.client_id)) |auth| {
            _ = job.box.put(.{ .ok = auth });
        } else |e| {
            _ = job.box.put(.{ .err = f.take(e) });
        }
    }

    fn downloadWorker(self: *App, job: *DownloadJob) void {
        var f: Failure = .{ .gpa = self.gpa };
        defer f.deinit();
        if (self.downloadNamCapture(&f, job)) |_| {
            _ = job.box.put(.done);
        } else |e| {
            _ = job.box.put(.{ .err = f.take(e) });
        }
    }

    /// The worker side of a download: .part file, rename into the cache.
    fn downloadNamCapture(self: *App, f: *Failure, job: *DownloadJob) Failure.Error!void {
        const gpa = self.gpa;
        const io = self.io;
        if (job.tone_id) |tid| {
            const u = try tone3000ModelUrl(f, self.http, gpa, io, tid, job.token.?);
            job.url = u;
        }
        const url = job.url.?;
        if (!isSafeCacheName(job.name)) return f.fail("NAM cache name `{s}` is not a plain file name; run `nam import URL as name`", .{job.name});
        self.cwd.createDirPath(io, job.cache_dir) catch |err|
            return f.fail("cannot create NAM cache {s}: {s}; create ./.nam or set MAQAM_NAM_CACHE_DIR to a writable directory", .{ job.cache_dir, ioErrText(err) });
        const dest = try cachePath(gpa, job.cache_dir, job.name);
        defer gpa.free(dest);
        const partial = try std.fmt.allocPrint(gpa, "{s}.part", .{dest});
        defer gpa.free(partial);
        const file = self.cwd.createFile(io, partial, .{ .read = true }) catch |err|
            return f.fail("cannot write NAM download {s}: {s}; check file permissions on ./.nam or set MAQAM_NAM_CACHE_DIR", .{ partial, ioErrText(err) });
        var closed = false;
        defer if (!closed) file.close(io);
        var auth_buf: ?[]u8 = null;
        defer if (auth_buf) |a| gpa.free(a);
        var headers: [1]net.Header = undefined;
        var nh: usize = 0;
        if (job.token) |t| {
            auth_buf = try std.fmt.allocPrint(gpa, "Bearer {s}", .{t});
            headers[0] = .{ .name = "Authorization", .value = auth_buf.? };
            nh = 1;
        }
        const status = self.http.download(self.http.ctx, gpa, io, url, headers[0..nh], file, &job.progress) catch |err| {
            file.close(io);
            closed = true;
            self.cwd.deleteFile(io, partial) catch {};
            if (err == error.DownloadTooLarge)
                return f.fail("NAM download failed from {s}: the capture is larger than 256 MiB; download the .nam file manually and run `nam import FILENAME.nam as {s}`", .{ url, job.name });
            return f.fail("NAM download failed from {s}: LLM request failed: {s}; check your network connection and try again; check the URL, network connection, or download the .nam file manually and run `nam import FILENAME.nam as {s}`", .{ url, @errorName(err), job.name });
        };
        if (status >= 400) {
            var body_buf: [64 * 1024]u8 = undefined;
            const n = file.readPositionalAll(io, &body_buf, 0) catch 0;
            file.close(io);
            closed = true;
            self.cwd.deleteFile(io, partial) catch {};
            const compact = try compactErrorBody(gpa, body_buf[0..n]);
            defer gpa.free(compact);
            return f.fail("NAM download failed from {s}: LLM HTTP {d}: {s}; check the API key, model name, and account access, then try again; check the URL, network connection, or download the .nam file manually and run `nam import FILENAME.nam as {s}`", .{ url, status, compact, job.name });
        }
        file.close(io);
        closed = true;
        self.cwd.rename(partial, self.cwd, dest, io) catch |err| {
            self.cwd.deleteFile(io, partial) catch {};
            return f.fail("cannot move NAM download into {s}: {s}; check file permissions on ./.nam or set MAQAM_NAM_CACHE_DIR", .{ dest, ioErrText(err) });
        };
    }

    const NamLoad = union(enum) { ok: struct { model: *nam.Model, message: []u8 }, err: []u8 };

    /// The Rust `nam_load_audio_cmd`: resolve, read and build the model.
    fn namLoadAudioCmd(self: *App, value: []const u8) Allocator.Error!NamLoad {
        const model_path = switch (try self.resolveNamModelPath(value)) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(model_path);
        const bytes = self.cwd.readFileAlloc(self.io, model_path, self.gpa, .limited(nam.max_json_bytes)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .err = try std.fmt.allocPrint(self.gpa, "NAM could not load {s}: failed to read .nam file: {s}; use a supported A1/A2 .nam file", .{ model_path, ioErrText(err) }) };
        };
        defer self.gpa.free(bytes);
        var diag: nam.Diagnostic = .{};
        const model = nam.Model.loadBytes(self.gpa, bytes, &diag) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const why: []const u8 = if (diag.len > 0) diag.message() else @errorName(err);
            return .{ .err = try std.fmt.allocPrint(self.gpa, "NAM could not load {s}: {s}; use a supported A1/A2 .nam file", .{ model_path, why }) };
        };
        const message = std.fmt.allocPrint(self.gpa, "NAM input amp loaded ← {s} ({d} Hz model; set your audio device to that rate if it sounds wrong)", .{ model_path, model.expectedSampleRate() }) catch |e| {
            model.deinit();
            return e;
        };
        return .{ .ok = .{ .model = model, .message = message } };
    }

    const PathResult = union(enum) { ok: []u8, err: []u8 };

    fn resolveNamModelPath(self: *App, value: []const u8) Allocator.Error!PathResult {
        if (self.isFile(value)) return self.cacheNamModelFile(value);
        const cache_dir = self.namCacheDir();
        const stem = if (std.mem.endsWith(u8, value, ".nam")) value[0 .. value.len - 4] else value;
        if (isSafeCacheName(stem)) {
            const cached = try cachePath(self.gpa, cache_dir, stem);
            if (self.isFile(cached)) return .{ .ok = cached };
            self.gpa.free(cached);
        }
        const s = try sanitizeNamCacheName(self.gpa, value);
        defer self.gpa.free(s);
        return .{ .err = try std.fmt.allocPrint(self.gpa, "NAM model `{s}` not found as a file or cached capture in ./.nam; run `nam search <amp or tone>` to find one, then `nam import URL as {s}` to download into ./.nam, or `nam import FILENAME.nam as {s}` for a downloaded file", .{ value, s, s }) };
    }

    fn cacheNamModelFile(self: *App, source: []const u8) Allocator.Error!PathResult {
        const cache_dir = self.namCacheDir();
        self.cwd.createDirPath(self.io, cache_dir) catch |err|
            return .{ .err = try std.fmt.allocPrint(self.gpa, "cannot create NAM cache {s}: {s}; create ./.nam or set MAQAM_NAM_CACHE_DIR to a writable directory", .{ cache_dir, ioErrText(err) }) };
        const name = try namCacheNameFromPath(self.gpa, source);
        defer self.gpa.free(name);
        const dest = try cachePath(self.gpa, cache_dir, name);
        if (samePath(source, dest)) return .{ .ok = dest };
        self.cwd.copyFile(source, self.cwd, dest, self.io, .{}) catch |err| {
            defer self.gpa.free(dest);
            return .{ .err = try std.fmt.allocPrint(self.gpa, "cannot cache NAM model in {s}: {s}; check file permissions on ./.nam or set MAQAM_NAM_CACHE_DIR", .{ dest, ioErrText(err) }) };
        };
        return .{ .ok = dest };
    }

    const NameList = union(enum) {
        ok: [][]u8,
        err: []const u8,
        fn deinit(self: *NameList, gpa: Allocator) void {
            switch (self.*) {
                .ok => |l| freeStrList(gpa, l),
                .err => {},
            }
        }
    };

    fn listCachedNamModels(self: *App, cache_dir: []const u8) Allocator.Error!NameList {
        var dir = self.cwd.openDir(self.io, cache_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                self.cwd.createDirPath(self.io, cache_dir) catch |e| return .{ .err = ioErrText(e) };
                return .{ .ok = try self.gpa.alloc([]u8, 0) };
            },
            else => return .{ .err = ioErrText(err) },
        };
        defer dir.close(self.io);
        var names: std.ArrayList([]u8) = .empty;
        errdefer freeList(self.gpa, &names);
        var it = dir.iterate();
        while (it.next(self.io) catch |e| {
            freeList(self.gpa, &names);
            return .{ .err = ioErrText(e) };
        }) |entry| {
            const stem = namStem(entry.name) orelse continue;
            try names.append(self.gpa, try self.gpa.dupe(u8, stem));
        }
        std.mem.sort([]u8, names.items, {}, strLess);
        return .{ .ok = try names.toOwnedSlice(self.gpa) };
    }

    fn listCurrentDirNamFiles(self: *App) Allocator.Error!NameList {
        var dir = self.cwd.openDir(self.io, ".", .{ .iterate = true }) catch |err| return .{ .err = ioErrText(err) };
        defer dir.close(self.io);
        var names: std.ArrayList([]u8) = .empty;
        errdefer freeList(self.gpa, &names);
        var it = dir.iterate();
        while (it.next(self.io) catch |e| {
            freeList(self.gpa, &names);
            return .{ .err = ioErrText(e) };
        }) |entry| {
            if (namStem(entry.name) == null) continue;
            if (!self.isFile(entry.name)) continue;
            try names.append(self.gpa, try self.gpa.dupe(u8, entry.name));
        }
        std.mem.sort([]u8, names.items, {}, strLess);
        return .{ .ok = try names.toOwnedSlice(self.gpa) };
    }

    fn isFile(self: *App, path: []const u8) bool {
        if (path.len == 0) return false;
        const st = self.cwd.statFile(self.io, path, .{}) catch return false;
        return st.kind == .file;
    }

    fn namCacheDir(self: *const App) []const u8 {
        return self.env.get("MAQAM_NAM_CACHE_DIR") orelse ".nam";
    }

    fn tone3000AuthPath(self: *const App) []const u8 {
        return self.env.get("MAQAM_TONE3000_AUTH_FILE") orelse ".tone3000-auth.json";
    }

    /// Rewrites the session file so `name` is pinned (the Rust `pin_nam_reference`); the error
    /// message is owned.
    fn pinNamReference(self: *App, session_path: []const u8, name: []const u8, pinned: []const u8) Allocator.Error!?[]u8 {
        const gpa = self.gpa;
        const source = self.cwd.readFileAlloc(self.io, session_path, gpa, .limited(64 << 20)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return try gpa.dupe(u8, ioErrText(err));
        };
        defer gpa.free(source);
        const lines = try session.splitLines(gpa, source);
        defer gpa.free(lines);
        const alias = try std.fmt.allocPrint(gpa, "nam {s}", .{name});
        defer gpa.free(alias);
        const suffix = try std.fmt.allocPrint(gpa, " as {s}", .{name});
        defer gpa.free(suffix);
        var out: std.ArrayList([]const u8) = .empty;
        defer out.deinit(gpa);
        var replaced = false;
        for (lines) |line| {
            const t = rs.trim(line);
            const matches = std.mem.eql(u8, t, alias) or
                ((std.mem.startsWith(u8, t, "nam pin ") or std.mem.startsWith(u8, t, "nam tone3000 ")) and std.mem.endsWith(u8, t, suffix));
            if (matches) {
                if (!replaced) {
                    try out.append(gpa, pinned);
                    replaced = true;
                }
            } else try out.append(gpa, line);
        }
        if (!replaced) {
            const at: usize = if (out.items.len > 0 and std.mem.eql(u8, out.items[0], "MAQAM_SESSION_V3")) 1 else 0;
            try out.insert(gpa, at, pinned);
        }
        var text = try std.mem.join(gpa, "\n", out.items);
        defer gpa.free(text);
        text = try gpa.realloc(text, text.len + 1);
        text[text.len - 1] = '\n';
        self.cwd.writeFile(self.io, .{ .sub_path = session_path, .data = text }) catch |err| return try gpa.dupe(u8, ioErrText(err));
        return null;
    }

    fn saveTone3000Auth(self: *App, auth: Tone3000Auth) ?[]u8 {
        const gpa = self.gpa;
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        writeAuthJson(&w.writer, auth) catch return gpa.dupe(u8, "out of memory") catch null;
        const path = self.tone3000AuthPath();
        const file = self.cwd.createFile(self.io, path, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) }) catch |err|
            return std.fmt.allocPrint(gpa, "{s}: {s}", .{ path, ioErrText(err) }) catch null;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, w.written()) catch |err| return gpa.dupe(u8, @errorName(err)) catch null;
        return null;
    }

    fn loadTone3000Auth(self: *App, f: *Failure) Failure.Error!Tone3000Auth {
        return loadTone3000AuthAt(f, self.gpa, self.io, self.cwd, self.tone3000AuthPath());
    }

    fn tone3000AccessToken(self: *App, f: *Failure) Failure.Error![]u8 {
        if (self.env.get("TONE3000_ACCESS_TOKEN")) |t| return self.gpa.dupe(u8, t);
        var auth = try self.loadTone3000Auth(f);
        defer auth.deinit(self.gpa);
        const now = unixTime(self.io);
        if (auth.expires_at > now + 60) return self.gpa.dupe(u8, auth.access_token);
        const refresh = auth.refresh_token orelse return f.fail("TONE3000 login expired; run `nam login`", .{});
        const rt = try qenc(self.gpa, refresh);
        defer self.gpa.free(rt);
        const cid = try qenc(self.gpa, auth.client_id);
        defer self.gpa.free(cid);
        const form = try std.fmt.allocPrint(self.gpa, "grant_type=refresh_token&refresh_token={s}&client_id={s}", .{ rt, cid });
        defer self.gpa.free(form);
        var parsed = try httpJson(f, self.http, self.gpa, self.io, .POST, "https://www.tone3000.com/api/v1/oauth/token", &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }}, form, "TONE3000 refresh response could not be read");
        defer parsed.deinit();
        const access = jstrOf(jget(parsed.value, "access_token")) orelse return f.fail("TONE3000 refresh returned no access token", .{});
        const new_access = try self.gpa.dupe(u8, access);
        self.gpa.free(auth.access_token);
        auth.access_token = new_access;
        if (jstrOf(jget(parsed.value, "refresh_token"))) |r| {
            const nr = try self.gpa.dupe(u8, r);
            if (auth.refresh_token) |old| self.gpa.free(old);
            auth.refresh_token = nr;
        }
        auth.expires_at = now + (ju64Of(jget(parsed.value, "expires_in")) orelse 3600);
        if (self.saveTone3000Auth(auth)) |err| {
            defer self.gpa.free(err);
            return f.fail("{s}", .{err});
        }
        return self.gpa.dupe(u8, auth.access_token);
    }

    // ── LLM ───────────────────────────────────────────────────────────────

    fn llmRequestFromEnv(self: *App, provider: LlmProvider, prompt: []const u8) Allocator.Error!?LlmRequest {
        const gpa = self.gpa;
        const key_src: []const u8, const model_src: []const u8 = switch (provider) {
            .chat_gpt => .{ self.env.get("OPENAI_API_KEY") orelse return null, self.env.get("OPENAI_MODEL") orelse "gpt-4o-mini" },
            .claude => .{ self.env.get("ANTHROPIC_API_KEY") orelse self.env.get("CLAUDE_API_KEY") orelse return null, self.env.get("ANTHROPIC_MODEL") orelse "claude-3-5-haiku-latest" },
        };
        const key = try gpa.dupe(u8, key_src);
        errdefer gpa.free(key);
        const model = try gpa.dupe(u8, model_src);
        errdefer gpa.free(model);
        const p = try gpa.dupe(u8, prompt);
        errdefer gpa.free(p);
        const history = try gpa.alloc(LlmChatMessage, self.llm_history.items.len);
        var filled: usize = 0;
        errdefer {
            for (history[0..filled]) |m| gpa.free(m.content);
            gpa.free(history);
        }
        for (self.llm_history.items) |m| {
            history[filled] = .{ .role = m.role, .content = try gpa.dupe(u8, m.content) };
            filled += 1;
        }
        const ctx = try self.llmScoreContext(gpa);
        return .{ .provider = provider, .key = key, .model = model, .prompt = p, .history = history, .score_context = ctx };
    }

    fn askLlm(self: *App, provider: LlmProvider, prompt: []const u8) Allocator.Error!void {
        if (self.llm_job != null) {
            try self.setMsg("✗ already asking LLM", .{});
            return;
        }
        const req = (try self.llmRequestFromEnv(provider, prompt)) orelse {
            switch (provider) {
                .chat_gpt => try self.setMsg("✗ environment variable OPENAI_API_KEY needs to be set to talk to chatgpt", .{}),
                .claude => try self.setMsg("✗ environment variable ANTHROPIC_API_KEY or CLAUDE_API_KEY needs to be set to talk to claude", .{}),
            }
            return;
        };
        try self.spawnLlm(req, false, prompt, prompt);
    }

    fn askLlmForEdit(self: *App, provider: LlmProvider, prompt: []const u8) Allocator.Error!void {
        if (self.llm_job != null) {
            try self.setMsg("✗ already asking LLM; wait for the current answer, then try again", .{});
            return;
        }
        const edit_prompt = try llmEditPrompt(self.gpa, prompt);
        defer self.gpa.free(edit_prompt);
        const req = (try self.llmRequestFromEnv(provider, edit_prompt)) orelse {
            switch (provider) {
                .chat_gpt => try self.setMsg("✗ environment variable OPENAI_API_KEY needs to be set to ask chatgpt to edit", .{}),
                .claude => try self.setMsg("✗ environment variable ANTHROPIC_API_KEY or CLAUDE_API_KEY needs to be set to ask claude to edit", .{}),
            }
            return;
        };
        try self.spawnLlm(req, true, edit_prompt, prompt);
    }

    fn spawnLlm(self: *App, req_in: LlmRequest, edit: bool, sent_prompt: []const u8, user_prompt: []const u8) Allocator.Error!void {
        var req = req_in;
        errdefer req.deinit(self.gpa);
        const sent = try self.gpa.dupe(u8, sent_prompt);
        errdefer self.gpa.free(sent);
        const job = try self.gpa.create(LlmJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .req = req, .edit = edit, .sent_prompt = sent };
        const provider_name = req.providerName();
        job.thread = std.Thread.spawn(.{}, llmWorker, .{ self, job }) catch {
            try self.setMsg("✗ could not start the LLM request thread", .{});
            self.freeLlmJob(job);
            return;
        };
        self.llm_job = job;
        if (self.beginBranch(.prompt, "Prompt", &.{ .{ .name = "provider", .value = provider_name }, .{ .name = "text", .value = user_prompt } }, "Apply")) {
            const c = self.cur.?;
            job.log = .{ .logged = true, .session = c.session, .first = c.first };
            job.log.request = self.log.emit(c.session, 0, "App", "Llm", "Ask", c.first, &.{});
        }
        if (edit) {
            try self.setMsg("asking {s} for edits...", .{provider_name});
        } else {
            try self.setMsg("asking {s}...", .{provider_name});
        }
    }

    fn llmWorker(self: *App, job: *LlmJob) void {
        var f: Failure = .{ .gpa = self.gpa };
        defer f.deinit();
        const outcome: LlmOutcome = if (job.edit)
            (if (llmSendEdit(&f, self.http, self.gpa, self.io, &job.req)) |c| .{ .commands = c } else |e| .{ .err = f.take(e) })
        else
            (if (llmSend(&f, self.http, self.gpa, self.io, &job.req)) |a| .{ .answer = a } else |e| .{ .err = f.take(e) });
        _ = job.box.put(outcome);
    }

    fn rememberLlmExchange(self: *App, user_prompt: []const u8, assistant_answer: []const u8) Allocator.Error!void {
        const u = try self.gpa.dupe(u8, user_prompt);
        errdefer self.gpa.free(u);
        const a = try self.gpa.dupe(u8, assistant_answer);
        errdefer self.gpa.free(a);
        try self.llm_history.ensureUnusedCapacity(self.gpa, 2);
        // Bounded (specification markdown "bounds"; upstream keeps every exchange): only the last
        // max_llm_exchanges exchanges are sent as context, so the oldest pair is dropped.
        while (self.llm_history.items.len >= 2 * max_llm_exchanges) {
            self.gpa.free(self.llm_history.items[0].content);
            self.gpa.free(self.llm_history.items[1].content);
            self.llm_history.replaceRangeAssumeCapacity(0, 2, &.{});
        }
        self.llm_history.appendAssumeCapacity(.{ .role = .user, .content = u });
        self.llm_history.appendAssumeCapacity(.{ .role = .assistant, .content = a });
    }

    /// Checks every returned command first, then applies them all or restores the score.
    fn applyLlmEditCommands(self: *App, commands_in: []const []const u8) Allocator.Error!void {
        const gpa = self.gpa;
        if (commands_in.len == 0) {
            try self.setMsg("✗ the LLM did not return any commands; ask it to return maqam-live commands separated by semicolons or newlines", .{});
            return;
        }
        const commands = try minimizeRepeatedLlmPhraseCommands(gpa, commands_in, self.next_phrase_id);
        defer freeStrList(gpa, commands);
        var parsed_commands: std.ArrayList(Cmd) = .empty;
        defer {
            for (parsed_commands.items) |c| c.deinit(gpa);
            parsed_commands.deinit(gpa);
        }
        for (commands) |src| {
            switch (try command.parse(gpa, src)) {
                .ok => |c| {
                    if (!llmEditCommandAllowed(c)) {
                        defer c.deinit(gpa);
                        const m = try llmRejectedEditCommandMessage(gpa, src, c);
                        self.setMsgOwned(m);
                        return;
                    }
                    parsed_commands.append(gpa, c) catch |e| {
                        c.deinit(gpa);
                        return e;
                    };
                },
                .err => |e| {
                    defer gpa.free(e);
                    try self.setMsg("✗ LLM returned `{s}`, which is not valid: {s}; ask it to return maqam-live commands only", .{ src, e });
                    return;
                },
            }
        }
        var snapshot = try self.snapshotScoreState();
        defer self.freeSnapshot(&snapshot);
        var applied: usize = 0;
        while (parsed_commands.items.len > 0) {
            const c = parsed_commands.orderedRemove(0);
            try self.execute(c);
            if (self.msgIsError()) {
                const err = try gpa.dupe(u8, self.message orelse "✗ LLM edit failed");
                defer gpa.free(err);
                try self.restoreScoreState(&snapshot);
                try self.setMsg("{s}; restored the previous phrases, so ask for a simpler edit or try again", .{err});
                return;
            }
            applied += 1;
        }
        try self.setMsg("LLM applied {d} edit command(s)", .{applied});
    }

    fn snapshotScoreState(self: *App) Allocator.Error!ScoreSnapshot {
        const gpa = self.gpa;
        const phrases = try gpa.alloc(Phrase, self.phrases.items.len);
        var filled: usize = 0;
        errdefer {
            for (phrases[0..filled]) |*p| p.deinit(gpa);
            gpa.free(phrases);
        }
        for (self.phrases.items) |*p| {
            phrases[filled] = try p.clone(gpa);
            filled += 1;
        }
        return .{
            .phrases = phrases,
            .next_phrase_id = self.next_phrase_id,
            .last_rhythm = try gpa.dupe(u8, self.last_rhythm.items),
            .bpm = self.bpm,
            .sustain = self.sustain,
            .vcf = self.vcf,
            .fx = self.fx,
            .paused = self.paused,
        };
    }

    fn freeSnapshot(self: *App, s: *ScoreSnapshot) void {
        for (s.phrases) |*p| p.deinit(self.gpa);
        self.gpa.free(s.phrases);
        self.gpa.free(s.last_rhythm);
        s.phrases = &.{};
        s.last_rhythm = &.{};
    }

    /// Restores (and takes) the snapshot's phrases and rhythm.
    fn restoreScoreState(self: *App, s: *ScoreSnapshot) Allocator.Error!void {
        for (self.phrases.items) |*p| p.deinit(self.gpa);
        self.phrases.clearRetainingCapacity();
        try self.phrases.appendSlice(self.gpa, s.phrases);
        self.gpa.free(s.phrases);
        s.phrases = &.{};
        self.next_phrase_id = s.next_phrase_id;
        self.last_rhythm.clearRetainingCapacity();
        try self.last_rhythm.appendSlice(self.gpa, s.last_rhythm);
        self.bpm = s.bpm;
        self.sustain = s.sustain;
        self.vcf = s.vcf;
        self.fx = s.fx;
        self.paused = s.paused;
        try self.resyncAudioSequence(null);
    }

    fn llmScoreContext(self: *const App, gpa: Allocator) Allocator.Error![]u8 {
        if (self.phrases.items.len == 0)
            return gpa.dupe(u8, "score is empty; time steps are sounding phrase repeat passes, not timeline rows");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var time_step: usize = 0;
        for (self.phrases.items, 0..) |*phrase, i| {
            if (i > 0) try out.append(gpa, '\n');
            const src = try phrase.displaySrc(gpa);
            defer gpa.free(src);
            if (phrase.jump) |jump| {
                try out.print(gpa, "{d}: {s}  [jump row; restarts at id {d} for {d} passes; consumes no sounding time step]", .{ phrase.id, src, jump.target_id, jump.times });
                continue;
            }
            if (phrase.control != null) {
                try out.print(gpa, "{d}: {s}  [control row; consumes no sounding time step]", .{ phrase.id, src });
                continue;
            }
            const start = time_step;
            const steps = @max(phrase.repeat, 1);
            const end = start + steps - 1;
            time_step += steps;
            try out.print(gpa, "{d}: {s}  [time steps {d}..{d}; {d} repeat pass(es); rhythm groups ", .{ phrase.id, src, start, end, steps });
            for (phrase.bar.groups) |g| try out.print(gpa, "{d}", .{g});
            try out.print(gpa, "; {d} subdivisions per pass]", .{phrase.bar.total_subdivs});
        }
        return out.toOwnedSlice(gpa);
    }

    // ── Sessions and globals ──────────────────────────────────────────────

    /// The save error message (owned), or null.
    fn saveSession(self: *App, path: []const u8) Allocator.Error!?[]u8 {
        const out = try session.serializeSessionV3(self.gpa, self.phrases.items);
        defer self.gpa.free(out);
        self.cwd.writeFile(self.io, .{ .sub_path = path, .data = out }) catch |err| return try self.gpa.dupe(u8, ioErrText(err));
        return null;
    }

    fn globalsPath(self: *const App) []const u8 {
        return self.env.get("MAQAM_GLOBALS_PATH") orelse ".globals.ml";
    }

    /// The write error message (owned), or null.
    fn saveGlobals(self: *App) Allocator.Error!?[]u8 {
        const path = self.globalsPath();
        var buf: [3]u8 = undefined;
        const out = try std.fmt.allocPrint(self.gpa, "vol {d}\ntuneto {s}\n", .{ self.vol, self.tune_to.sourceTokenBuf(&buf) });
        defer self.gpa.free(out);
        self.cwd.writeFile(self.io, .{ .sub_path = path, .data = out }) catch |err|
            return try std.fmt.allocPrint(self.gpa, "could not write {s}; check directory permissions, then try the command again: {s}", .{ path, ioErrText(err) });
        return null;
    }

    fn loadGlobals(self: *App) Allocator.Error!void {
        const path = self.globalsPath();
        const source = self.cwd.readFileAlloc(self.io, path, self.gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.setMsg("✗ could not read {s}; check file permissions or remove the file, then restart maqam-live: {s}", .{ path, ioErrText(err) });
                return;
            },
        };
        defer self.gpa.free(source);
        const lines = try session.splitLines(self.gpa, source);
        defer self.gpa.free(lines);
        for (lines, 0..) |raw, idx| {
            const line_no = idx + 1;
            const line = rs.trim(raw);
            if (line.len == 0 or line[0] == '#') continue;
            switch (try command.parse(self.gpa, line)) {
                .err => |e| {
                    defer self.gpa.free(e);
                    try self.setMsg("✗ {s} line {d}: {s}", .{ path, line_no, e });
                    return;
                },
                .ok => |c| {
                    defer c.deinit(self.gpa);
                    switch (c) {
                        .set_vol => |v| self.vol = v,
                        .tune_to => |p| {
                            self.tune_to = p;
                            tuning.tuneToStandardPitch(p);
                        },
                        else => {
                            try self.setMsg("✗ {s} line {d}: globals only support vol and tuneto; remove this line or change it to vol <n> or tuneto <pitch>", .{ path, line_no });
                            return;
                        },
                    }
                },
            }
        }
    }

    const LoadHook = struct {
        logged: bool = false,
        cur: ?Interaction = null,
        w: u64 = 0,
        done: ?*const fn (app: *App, logged: bool, cur: ?Interaction, w: u64) void = null,
    };

    /// Reads and loads a session file (the Rust `load_session`); the error message is owned.
    fn loadSession(self: *App, path: []const u8, hook: LoadHook) Allocator.Error!?[]u8 {
        const text = self.cwd.readFileAlloc(self.io, path, self.gpa, .limited(64 << 20)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return try self.gpa.dupe(u8, ioErrText(err));
        };
        defer self.gpa.free(text);
        if (!std.unicode.utf8ValidateSlice(text)) return try self.gpa.dupe(u8, "stream did not contain valid UTF-8");
        return self.loadSessionText(text, hook);
    }

    /// Loads session text (header and records) into the App.
    pub fn loadSessionText(self: *App, text: []const u8, hook: LoadHook) Allocator.Error!?[]u8 {
        const lines = try session.splitLines(self.gpa, text);
        defer self.gpa.free(lines);
        if (lines.len == 0) return try self.gpa.dupe(u8, "empty file");
        // A newly selected score owns the complete NAM dependency lifecycle.
        try self.abandonNamWorkers();
        var result = try session.load(self.gpa, text, .{ .bpm = self.bpm, .sustain = self.sustain, .vcf = self.vcf, .fx = self.fx });
        switch (result) {
            .err => |m| return m,
            .ok => |*loaded| {
                defer loaded.deinit(self.gpa);
                if (loaded.phrases.len > max_entries) {
                    return try std.fmt.allocPrint(self.gpa, "the session has {d} timeline entries; at most {d} are allowed", .{ loaded.phrases.len, max_entries });
                }
                if (hook.done) |d| d(self, hook.logged, hook.cur, hook.w);
                try self.applyLoaded(loaded);
                return null;
            },
        }
    }

    /// What the Rust load_session_v3 / v1 / v2 did after reading: replace the timeline and the
    /// settings, resync the audio side, and resolve the NAM rows.
    fn applyLoaded(self: *App, loaded: *session.Loaded) Allocator.Error!void {
        const gpa = self.gpa;
        if (loaded.version == .v3) try self.reset(&self.pending_nam_slot, null);
        for (self.phrases.items) |*p| p.deinit(gpa);
        self.phrases.clearRetainingCapacity();
        try self.phrases.ensureTotalCapacity(gpa, loaded.phrases.len);
        for (loaded.phrases) |*p| self.phrases.appendAssumeCapacity(try p.clone(gpa));
        self.next_phrase_id = loaded.next_phrase_id;
        self.last_rhythm.clearRetainingCapacity();
        try self.last_rhythm.appendSlice(gpa, loaded.last_rhythm);
        self.bpm = loaded.settings.bpm;
        self.sustain = loaded.settings.sustain;
        self.vcf = loaded.settings.vcf;
        self.fx = loaded.settings.fx;
        if (loaded.version == .v3) {
            for (self.live_nam_commands.items) |c| gpa.free(c);
            self.live_nam_commands.clearRetainingCapacity();
            for (loaded.live_nam_commands) |c| try self.live_nam_commands.append(gpa, try gpa.dupe(u8, c));
        }
        self.paused = false;
        self.resetTransientViewState();
        const start = loaded.start;

        // Resolve the NAM rows before sending, in file order (nam_session_audio_cmd).
        var nam_cmds: std.ArrayList(AudioCmd) = .empty;
        defer {
            for (nam_cmds.items) |c| c.deinit(gpa);
            nam_cmds.deinit(gpa);
        }
        var warning: ?[]u8 = null;
        defer if (warning) |w| gpa.free(w);
        var pending_pin: ?struct { url: []const u8, name: []const u8 } = null;
        var pending_tone: ?struct { id: u64, name: []const u8 } = null;
        for (loaded.nam_rows) |row| {
            switch (row.command) {
                .load, .pin, .tone3000 => {
                    const value: []const u8 = switch (row.command) {
                        .load => |v| v.path,
                        .pin => |v| v.name,
                        .tone3000 => |v| v.name,
                        else => unreachable,
                    };
                    switch (try self.namLoadAudioCmd(value)) {
                        .ok => |r| {
                            gpa.free(r.message);
                            nam_cmds.append(gpa, .{ .set_nam_model = r.model }) catch |e| {
                                r.model.deinit();
                                return e;
                            };
                        },
                        .err => |e| {
                            defer gpa.free(e);
                            switch (row.command) {
                                .tone3000 => |v| pending_tone = .{ .id = v.tone_id, .name = v.name },
                                .pin => |v| pending_pin = .{ .url = v.url, .name = v.name },
                                .load => |v| {
                                    try self.reset(&self.pending_nam_slot, v.path);
                                    if (!row.record and warning == null)
                                        warning = try std.fmt.allocPrint(gpa, "This score needs a NAM model for “{s}”. What amp or tone should it use?", .{v.path});
                                },
                                else => unreachable,
                            }
                        },
                    }
                },
                .off => try nam_cmds.append(gpa, .{ .set_nam_model = null }),
                .gain => |g| try nam_cmds.append(gpa, .{ .set_nam_gain = g }),
                .input => |r| try nam_cmds.append(gpa, .{ .set_nam_input = r }),
                else => if (warning == null) {
                    warning = try std.fmt.allocPrint(gpa, "line {d}: {s}", .{ row.line_no, session.nam_session_only_message });
                },
            }
        }

        try self.sendAudio(.clear);
        try self.sendAudio(.reset_session_state);
        try self.sendAudio(.{ .set_bpm = start.bpm });
        try self.sendAudio(.{ .set_sustain = start.sustain });
        try self.sendAudio(.{ .set_vcf_bank = start.vcf });
        try self.sendAudio(.{ .set_fx_settings = start.fx });
        try self.sendAudio(.{ .set_vol = self.vol });
        try self.sendAudio(.{ .set_paused = false });
        while (nam_cmds.items.len > 0) try self.sendAudio(nam_cmds.orderedRemove(0));
        for (self.phrases.items) |*p| try self.sendPhraseCopy(p, .add);
        try self.sendAudio(.{ .set_cur_phrase = 0 });
        if (pending_pin) |p| try self.startNamDownload(p.url, p.name, true);
        if (pending_tone) |t| try self.startTone3000Download(t.id, t.name);
        if (warning) |w| {
            warning = null;
            self.setMsgOwned(w);
        }
    }
};

// ── Free functions: LLM ───────────────────────────────────────────────────────

fn jget(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn jidx(v: ?Value, i: usize) ?Value {
    const x = v orelse return null;
    return switch (x) {
        .array => |a| if (i < a.items.len) a.items[i] else null,
        else => null,
    };
}

fn jgetOpt(v: ?Value, key: []const u8) ?Value {
    return jget(v orelse return null, key);
}

fn jstrOf(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn jarrOf(v: ?Value) ?[]const Value {
    const x = v orelse return null;
    return switch (x) {
        .array => |a| a.items,
        else => null,
    };
}

fn ju64Of(v: ?Value) ?u64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// One HTTP request whose answer is JSON; status >= 400 and transport errors become the Rust's
/// describe_http_error texts.
fn httpJson(f: *Failure, http: Http, gpa: Allocator, io: std.Io, method: std.http.Method, url: []const u8, headers: []const net.Header, payload: ?[]const u8, comptime parse_fail: []const u8) Failure.Error!std.json.Parsed(Value) {
    const resp = http.fetch(http.ctx, gpa, io, method, url, headers, payload) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return f.fail("LLM request failed: {s}; check your network connection and try again", .{@errorName(err)});
    };
    defer resp.deinit(gpa);
    if (resp.status >= 400) {
        const compact = try compactErrorBody(gpa, resp.body);
        defer gpa.free(compact);
        return f.fail("LLM HTTP {d}: {s}; check the API key, model name, and account access, then try again", .{ resp.status, compact });
    }
    return std.json.parseFromSlice(Value, gpa, resp.body, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return f.fail(parse_fail ++ ": {s}", .{@errorName(err)});
    };
}

fn compactErrorBody(gpa: Allocator, body: []const u8) Allocator.Error![]u8 {
    if (std.json.parseFromSlice(Value, gpa, body, .{})) |parsed| {
        defer parsed.deinit();
        const m = jstrOf(jgetOpt(jget(parsed.value, "error"), "message")) orelse
            jstrOf(jgetOpt(jgetOpt(jget(parsed.value, "error"), "error"), "message"));
        if (m) |s| return cleanLlmAnswer(gpa, s);
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    return cleanLlmAnswer(gpa, rs.trim(body));
}

/// Each line's words joined by one space, empty lines dropped.
fn cleanLlmAnswer(gpa: Allocator, answer: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const lines = try session.splitLines(gpa, answer);
    defer gpa.free(lines);
    for (lines) |line| {
        var it = rs.words(line);
        var first = true;
        while (it.next()) |w| {
            if (first) {
                if (out.items.len > 0) try out.append(gpa, '\n');
                first = false;
            } else try out.append(gpa, ' ');
            try out.appendSlice(gpa, w);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn llmSystemPrompt(gpa: Allocator, score_context: []const u8) Allocator.Error![]u8 {
    const reference = try command.languageReference(gpa);
    defer gpa.free(reference);
    return std.fmt.allocPrint(gpa, "You help with maqam-live, a terminal live-coding sequencer.\n\n{s}\nCurrent score context:\n{s}\n\nLLM behavior:\n- The request includes the current score plus prior user prompts and prior assistant answers/tool-command results; use that continuity.\n- For questions, answer concisely and prefer exact commands.\n- When the user asks to find, browse, or download a NAM capture or amp model, use the find_nam_captures tool; never claim you cannot browse, and never invent URLs or fake local paths.\n- For direct .nam URLs found by the tool, suggest `nam import URL as name` or `nam URL`; for result pages, tell the user to open the page and copy the .nam download URL.\n- For edit requests, use the apply_maqam_commands tool with valid commands only.\n- Never return save, load, m/record, q/quit, z/playback, pause, start, clock, help, ls, audition, clear, vol, tuneto, or nam commands.", .{ reference, score_context });
}

const apply_tool_description = "Apply only valid maqam-live score-edit commands from the command language in the system prompt. Use bpm 180, never set tempo 180. Do not include save, load, record, playback, clock, help, audition, or clear commands.";
const find_tool_description = "Search the web for real Neural Amp Modeler (.nam) capture pages or direct .nam download links. Use this when the user asks for an amp model, NAM capture, or a style such as Metallica. Return only real links from the tool result; never invent local paths or URLs.";
const find_query_description = "Amp, artist, tone, or capture search terms, for example `Metallica Mesa Mark IIC+ NAM`.";
const commands_description = "maqam-live commands to apply. Commands may also contain semicolon-separated maqam-live commands. If returning multiple commands, separate them with array items, semicolons, or newlines; never concatenate commands like `sym on sym decay 0.999 drive 2`.";

fn writeFindSchema(w: *std.Io.Writer) !void {
    try w.writeAll("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"query\":{\"type\":\"string\",\"description\":");
    try jsonStr(w, find_query_description);
    try w.writeAll("}},\"required\":[\"query\"]}");
}

fn writeApplySchema(w: *std.Io.Writer) !void {
    try w.writeAll("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"commands\":{\"type\":\"array\",\"description\":");
    try jsonStr(w, commands_description);
    try w.writeAll(",\"items\":{\"type\":\"string\"},\"minItems\":1}},\"required\":[\"commands\"]}");
}

fn writeOpenaiTool(w: *std.Io.Writer, comptime find: bool) !void {
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try jsonStr(w, if (find) "find_nam_captures" else "apply_maqam_commands");
    try w.writeAll(",\"description\":");
    try jsonStr(w, if (find) find_tool_description else apply_tool_description);
    try w.writeAll(",\"parameters\":");
    if (find) try writeFindSchema(w) else try writeApplySchema(w);
    try w.writeAll("}}");
}

fn writeAnthropicTool(w: *std.Io.Writer, comptime find: bool) !void {
    try w.writeAll("{\"name\":");
    try jsonStr(w, if (find) "find_nam_captures" else "apply_maqam_commands");
    try w.writeAll(",\"description\":");
    try jsonStr(w, if (find) find_tool_description else apply_tool_description);
    try w.writeAll(",\"input_schema\":");
    if (find) try writeFindSchema(w) else try writeApplySchema(w);
    try w.writeAll("}");
}

/// The message objects (JSON text, owned) of the OpenAI chat: system, history, the prompt.
fn openaiMessages(gpa: Allocator, history: []const LlmChatMessage, prompt: []const u8, score_context: []const u8) Allocator.Error!std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &list);
    const system = try llmSystemPrompt(gpa, score_context);
    defer gpa.free(system);
    try list.append(gpa, try roleContent(gpa, "system", system));
    for (history) |m| try list.append(gpa, try roleContent(gpa, m.role.asApiRole(), m.content));
    try list.append(gpa, try roleContent(gpa, "user", prompt));
    return list;
}

fn anthropicMessages(gpa: Allocator, history: []const LlmChatMessage, prompt: []const u8) Allocator.Error!std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &list);
    for (history) |m| try list.append(gpa, try roleContent(gpa, m.role.asApiRole(), m.content));
    try list.append(gpa, try roleContent(gpa, "user", prompt));
    return list;
}

fn roleContent(gpa: Allocator, role: []const u8, content: []const u8) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    writeRoleContent(&w.writer, role, content) catch return error.OutOfMemory;
    return w.toOwnedSlice() catch error.OutOfMemory;
}

fn writeRoleContent(w: *std.Io.Writer, role: []const u8, content: []const u8) !void {
    try w.writeAll("{\"role\":");
    try jsonStr(w, role);
    try w.writeAll(",\"content\":");
    try jsonStr(w, content);
    try w.writeAll("}");
}

fn writeArray(w: *std.Io.Writer, items: []const []u8) !void {
    try w.writeAll("[");
    for (items, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(m);
    }
    try w.writeAll("]");
}

const BodyKind = enum { openai_answer, openai_followup, openai_edit, claude_answer, claude_followup, claude_edit };

fn requestBody(gpa: Allocator, kind: BodyKind, model: []const u8, messages: []const []u8, system: ?[]const u8) Allocator.Error![]u8 {
    var a: std.Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    const w = &a.writer;
    writeRequestBody(w, kind, model, messages, system) catch return error.OutOfMemory;
    return a.toOwnedSlice() catch error.OutOfMemory;
}

fn writeRequestBody(w: *std.Io.Writer, kind: BodyKind, model: []const u8, messages: []const []u8, system: ?[]const u8) !void {
    try w.writeAll("{\"model\":");
    try jsonStr(w, model);
    switch (kind) {
        .openai_answer, .openai_followup, .openai_edit => {
            try w.writeAll(",\"messages\":");
            try writeArray(w, messages);
            try w.writeAll(",\"temperature\":0.2");
            switch (kind) {
                .openai_answer => {
                    try w.writeAll(",\"tools\":[");
                    try writeOpenaiTool(w, true);
                    try w.writeAll("],\"tool_choice\":\"auto\"");
                },
                .openai_edit => {
                    try w.writeAll(",\"tools\":[");
                    try writeOpenaiTool(w, false);
                    try w.writeAll("],\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"apply_maqam_commands\"}}");
                },
                else => {},
            }
        },
        .claude_answer, .claude_followup, .claude_edit => {
            try w.writeAll(",\"max_tokens\":500,\"system\":");
            try jsonStr(w, system orelse "");
            try w.writeAll(",\"messages\":");
            try writeArray(w, messages);
            switch (kind) {
                .claude_answer => {
                    try w.writeAll(",\"tools\":[");
                    try writeAnthropicTool(w, true);
                    try w.writeAll("]");
                },
                .claude_edit => {
                    try w.writeAll(",\"tools\":[");
                    try writeAnthropicTool(w, false);
                    try w.writeAll("],\"tool_choice\":{\"type\":\"tool\",\"name\":\"apply_maqam_commands\"}");
                },
                else => {},
            }
        },
    }
    try w.writeAll("}");
}

const openai_url = "https://api.openai.com/v1/chat/completions";
const anthropic_url = "https://api.anthropic.com/v1/messages";

fn llmPost(f: *Failure, http: Http, gpa: Allocator, io: std.Io, req: *const LlmRequest, body: []const u8, comptime parse_fail: []const u8) Failure.Error!std.json.Parsed(Value) {
    switch (req.provider) {
        .chat_gpt => {
            const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{req.key});
            defer gpa.free(auth);
            return httpJson(f, http, gpa, io, .POST, openai_url, &.{ .{ .name = "Authorization", .value = auth }, .{ .name = "Content-Type", .value = "application/json" } }, body, parse_fail);
        },
        .claude => return httpJson(f, http, gpa, io, .POST, anthropic_url, &.{ .{ .name = "x-api-key", .value = req.key }, .{ .name = "anthropic-version", .value = "2023-06-01" }, .{ .name = "Content-Type", .value = "application/json" } }, body, parse_fail),
    }
}

/// The answer to a question (the Rust `LlmRequest::send`). Caller owns it.
fn llmSend(f: *Failure, http: Http, gpa: Allocator, io: std.Io, req: *const LlmRequest) Failure.Error![]u8 {
    const prompt = try promptWithAutomaticNamResearch(f, http, gpa, io, req.prompt);
    defer gpa.free(prompt);
    switch (req.provider) {
        .chat_gpt => {
            var messages = try openaiMessages(gpa, req.history, prompt, req.score_context);
            defer freeList(gpa, &messages);
            const body = try requestBody(gpa, .openai_answer, req.model, messages.items, null);
            defer gpa.free(body);
            var response = try llmPost(f, http, gpa, io, req, body, "chatgpt response parse failed");
            defer response.deinit();
            const message = jgetOpt(jidx(jget(response.value, "choices"), 0), "message");
            if (jarrOf(jgetOpt(message, "tool_calls"))) |calls| if (calls.len > 0) {
                const assistant = message orelse return f.fail("chatgpt tool response had no assistant message; ask again", .{});
                try messages.append(gpa, std.json.Stringify.valueAlloc(gpa, assistant, .{}) catch return error.OutOfMemory);
                for (calls) |call| {
                    const id = jstrOf(jget(call, "id")) orelse return f.fail("chatgpt tool call had no id; ask again", .{});
                    const result = try executeOpenaiLlmTool(f, http, gpa, io, call);
                    defer gpa.free(result);
                    var a: std.Io.Writer.Allocating = .init(gpa);
                    defer a.deinit();
                    writeToolMessage(&a.writer, id, result) catch return error.OutOfMemory;
                    try messages.append(gpa, a.toOwnedSlice() catch return error.OutOfMemory);
                }
                const body2 = try requestBody(gpa, .openai_followup, req.model, messages.items, null);
                defer gpa.free(body2);
                var r2 = try llmPost(f, http, gpa, io, req, body2, "chatgpt response parse failed after NAM search");
                defer r2.deinit();
                const content = jstrOf(jgetOpt(jgetOpt(jidx(jget(r2.value, "choices"), 0), "message"), "content")) orelse
                    return f.fail("chatgpt returned no message after NAM search; try again, or paste a direct .nam URL and run `nam import URL as name`", .{});
                const answer = try cleanLlmAnswer(gpa, content);
                if (answer.len == 0) {
                    gpa.free(answer);
                    return f.fail("chatgpt returned no message after NAM search; try again, or paste a direct .nam URL and run `nam import URL as name`", .{});
                }
                return answer;
            };
            const content = jstrOf(jgetOpt(message, "content")) orelse
                return f.fail("chatgpt returned no message content; try asking again, or set OPENAI_MODEL to a chat-capable model", .{});
            const answer = try cleanLlmAnswer(gpa, content);
            if (answer.len == 0) {
                gpa.free(answer);
                return f.fail("chatgpt returned no message content; try asking again, or set OPENAI_MODEL to a chat-capable model", .{});
            }
            return answer;
        },
        .claude => {
            var messages = try anthropicMessages(gpa, req.history, prompt);
            defer freeList(gpa, &messages);
            const system = try llmSystemPrompt(gpa, req.score_context);
            defer gpa.free(system);
            const body = try requestBody(gpa, .claude_answer, req.model, messages.items, system);
            defer gpa.free(body);
            var response = try llmPost(f, http, gpa, io, req, body, "claude response parse failed");
            defer response.deinit();
            const content_v = jget(response.value, "content");
            const content = jarrOf(content_v) orelse
                return f.fail("claude returned no content; try asking again, or set ANTHROPIC_MODEL to a messages-capable model", .{});
            var tool_uses: std.ArrayList(Value) = .empty;
            defer tool_uses.deinit(gpa);
            for (content) |item| {
                if (eqlOpt(jstrOf(jget(item, "type")), "tool_use") and eqlOpt(jstrOf(jget(item, "name")), "find_nam_captures"))
                    try tool_uses.append(gpa, item);
            }
            if (tool_uses.items.len > 0) {
                {
                    var a: std.Io.Writer.Allocating = .init(gpa);
                    defer a.deinit();
                    writeAssistantContent(&a.writer, content_v.?) catch return error.OutOfMemory;
                    try messages.append(gpa, a.toOwnedSlice() catch return error.OutOfMemory);
                }
                var results: std.ArrayList([]u8) = .empty;
                defer freeList(gpa, &results);
                for (tool_uses.items) |tu| {
                    const id = jstrOf(jget(tu, "id")) orelse return f.fail("claude NAM search tool call had no id; ask again", .{});
                    const result = try executeAnthropicLlmTool(f, http, gpa, io, tu);
                    defer gpa.free(result);
                    var a: std.Io.Writer.Allocating = .init(gpa);
                    defer a.deinit();
                    writeToolResult(&a.writer, id, result) catch return error.OutOfMemory;
                    try results.append(gpa, a.toOwnedSlice() catch return error.OutOfMemory);
                }
                {
                    var a: std.Io.Writer.Allocating = .init(gpa);
                    defer a.deinit();
                    writeUserResults(&a.writer, results.items) catch return error.OutOfMemory;
                    try messages.append(gpa, a.toOwnedSlice() catch return error.OutOfMemory);
                }
                const body2 = try requestBody(gpa, .claude_followup, req.model, messages.items, system);
                defer gpa.free(body2);
                var r2 = try llmPost(f, http, gpa, io, req, body2, "claude response parse failed after NAM search");
                defer r2.deinit();
                const answer = (try claudeText(gpa, jarrOf(jget(r2.value, "content")))) orelse
                    return f.fail("claude returned no text after NAM search; try again, or paste a direct .nam URL and run `nam import URL as name`", .{});
                return answer;
            }
            const answer = (try claudeText(gpa, content)) orelse
                return f.fail("claude returned no text content; try asking again, or set ANTHROPIC_MODEL to a messages-capable model", .{});
            return answer;
        },
    }
}

/// The text items of a Claude content array joined by newlines and cleaned; null when empty.
fn claudeText(gpa: Allocator, items_opt: ?[]const Value) Allocator.Error!?[]u8 {
    const items = items_opt orelse return null;
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(gpa);
    for (items) |item| if (jstrOf(jget(item, "text"))) |t| try texts.append(gpa, t);
    const joined = try std.mem.join(gpa, "\n", texts.items);
    defer gpa.free(joined);
    const answer = try cleanLlmAnswer(gpa, joined);
    if (answer.len == 0) {
        gpa.free(answer);
        return null;
    }
    return answer;
}

fn writeToolMessage(w: *std.Io.Writer, id: []const u8, result: []const u8) !void {
    try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
    try jsonStr(w, id);
    try w.writeAll(",\"content\":");
    try jsonStr(w, result);
    try w.writeAll("}");
}

fn writeAssistantContent(w: *std.Io.Writer, content: Value) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":");
    try std.json.Stringify.value(content, .{}, w);
    try w.writeAll("}");
}

fn writeToolResult(w: *std.Io.Writer, id: []const u8, result: []const u8) !void {
    try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try jsonStr(w, id);
    try w.writeAll(",\"content\":");
    try jsonStr(w, result);
    try w.writeAll("}");
}

fn writeUserResults(w: *std.Io.Writer, results: []const []u8) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":");
    try writeArray(w, results);
    try w.writeAll("}");
}

/// The commands of an edit (the Rust `LlmRequest::send_edit`). Caller owns them.
fn llmSendEdit(f: *Failure, http: Http, gpa: Allocator, io: std.Io, req: *const LlmRequest) Failure.Error![][]u8 {
    const prompt = try promptWithAutomaticNamResearch(f, http, gpa, io, req.prompt);
    defer gpa.free(prompt);
    switch (req.provider) {
        .chat_gpt => {
            var messages = try openaiMessages(gpa, req.history, prompt, req.score_context);
            defer freeList(gpa, &messages);
            const body = try requestBody(gpa, .openai_edit, req.model, messages.items, null);
            defer gpa.free(body);
            var response = try llmPost(f, http, gpa, io, req, body, "chatgpt tool-call response parse failed");
            defer response.deinit();
            const calls = jarrOf(jgetOpt(jgetOpt(jidx(jget(response.value, "choices"), 0), "message"), "tool_calls")) orelse
                return f.fail("chatgpt did not call apply_maqam_commands; ask again, or set OPENAI_MODEL to a model that supports tool calling", .{});
            var arguments: ?[]const u8 = null;
            for (calls) |call| {
                if (eqlOpt(jstrOf(jgetOpt(jget(call, "function"), "name")), "apply_maqam_commands")) {
                    arguments = jstrOf(jgetOpt(jget(call, "function"), "arguments"));
                    break;
                }
            }
            const args = arguments orelse return f.fail("chatgpt called the edit tool without command arguments; ask again with the edit request", .{});
            var input = std.json.parseFromSlice(Value, gpa, args, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return f.fail("chatgpt edit tool arguments were not valid JSON: {s}; ask again", .{@errorName(err)});
            };
            defer input.deinit();
            return extractToolCommands(f, gpa, input.value);
        },
        .claude => {
            var messages = try anthropicMessages(gpa, req.history, prompt);
            defer freeList(gpa, &messages);
            const system = try llmSystemPrompt(gpa, req.score_context);
            defer gpa.free(system);
            const body = try requestBody(gpa, .claude_edit, req.model, messages.items, system);
            defer gpa.free(body);
            var response = try llmPost(f, http, gpa, io, req, body, "claude tool-call response parse failed");
            defer response.deinit();
            const content = jarrOf(jget(response.value, "content")) orelse
                return f.fail("claude returned no content; ask again, or set ANTHROPIC_MODEL to a model that supports tool calling", .{});
            for (content) |item| {
                if (eqlOpt(jstrOf(jget(item, "type")), "tool_use") and eqlOpt(jstrOf(jget(item, "name")), "apply_maqam_commands")) {
                    if (jget(item, "input")) |input| return extractToolCommands(f, gpa, input);
                    break;
                }
            }
            return f.fail("claude did not call apply_maqam_commands; ask again, or set ANTHROPIC_MODEL to a model that supports tool calling", .{});
        },
    }
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

fn extractToolCommands(f: *Failure, gpa: Allocator, input: Value) Failure.Error![][]u8 {
    const items = jarrOf(jget(input, "commands")) orelse return f.fail("the edit tool needs a commands array; ask again with the edit request", .{});
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &out);
    for (items) |v| {
        const s = jstrOf(v) orelse continue;
        const parts = try splitToolCommand(gpa, s);
        defer gpa.free(parts);
        try out.appendSlice(gpa, parts);
    }
    if (out.items.len == 0) return f.fail("the edit tool returned no commands; ask it to return maqam-live commands", .{});
    return out.toOwnedSlice(gpa);
}

fn executeOpenaiLlmTool(f: *Failure, http: Http, gpa: Allocator, io: std.Io, call: Value) Failure.Error![]u8 {
    const name = jstrOf(jgetOpt(jget(call, "function"), "name")) orelse return f.fail("chatgpt tool call had no function name; ask again", .{});
    const arguments = jstrOf(jgetOpt(jget(call, "function"), "arguments")) orelse return f.fail("chatgpt tool call had no arguments; ask again", .{});
    var input = std.json.parseFromSlice(Value, gpa, arguments, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return f.fail("chatgpt tool arguments were not valid JSON: {s}; ask again", .{@errorName(err)});
    };
    defer input.deinit();
    return executeLlmTool(f, http, gpa, io, name, input.value);
}

fn executeAnthropicLlmTool(f: *Failure, http: Http, gpa: Allocator, io: std.Io, tool_use: Value) Failure.Error![]u8 {
    const name = jstrOf(jget(tool_use, "name")) orelse return f.fail("claude tool call had no name; ask again", .{});
    const input = jget(tool_use, "input") orelse return f.fail("claude tool call had no input; ask again", .{});
    return executeLlmTool(f, http, gpa, io, name, input);
}

fn executeLlmTool(f: *Failure, http: Http, gpa: Allocator, io: std.Io, name: []const u8, input: Value) Failure.Error![]u8 {
    if (std.mem.eql(u8, name, "find_nam_captures")) {
        const q = jstrOf(jget(input, "query")) orelse "";
        const query = rs.trim(q);
        if (query.len == 0) return f.fail("find_nam_captures needs a non-empty query; ask for a specific amp, artist, or tone", .{});
        return findNamCaptures(f, http, gpa, io, query);
    }
    return f.fail("unknown LLM tool `{s}`; ask again using maqam-live tools only", .{name});
}

fn promptWithAutomaticNamResearch(f: *Failure, http: Http, gpa: Allocator, io: std.Io, prompt: []const u8) Failure.Error![]u8 {
    if (!llmPromptNeedsNamResearch(prompt)) return gpa.dupe(u8, prompt);
    const results = try findNamCaptures(f, http, gpa, io, prompt);
    defer gpa.free(results);
    return std.fmt.allocPrint(gpa, "{s}\n\nmaqam-live already performed NAM capture research for this request:\n{s}\n\nUse these researched links directly. Do not tell the user to go research amp models. If there is a direct .nam URL, give the exact `nam import URL as name` command. If there are only result pages, give the best result links and explain that maqam-live could not extract a direct .nam URL from those pages.", .{ prompt, results });
}

fn containsLower(lower: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, lower, needle) != null;
}

fn llmPromptNeedsNamResearch(prompt: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const lower = asciiLowerBuf(prompt, &buf);
    const mentions = containsLower(lower, ".nam") or containsLower(lower, " nam ") or std.mem.startsWith(u8, lower, "nam ") or
        containsLower(lower, "neural amp") or containsLower(lower, "amp model") or containsLower(lower, "amp capture");
    const needles = [_][]const u8{ "find", "search", "browse", "download", "add", "use", "common", "get me", "look up", "lookup", "where can i get", "where do i get", "metallica", "mesa", "marshall", "5150", "soldano", "rectifier" };
    var asks = false;
    for (needles) |n| if (containsLower(lower, n)) {
        asks = true;
    };
    return mentions and asks;
}

/// ASCII lowercase into `buf` (truncated to its size; prompts longer than that are judged by
/// their first 4096 bytes).
fn asciiLowerBuf(s: []const u8, buf: []u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

const SearchResult = struct {
    title: []u8,
    url: []u8,
    fn deinit(self: SearchResult, gpa: Allocator) void {
        gpa.free(self.title);
        gpa.free(self.url);
    }
};

fn freeResults(gpa: Allocator, list: *std.ArrayList(SearchResult)) void {
    for (list.items) |r| r.deinit(gpa);
    list.deinit(gpa);
}

fn findNamCaptures(f: *Failure, http: Http, gpa: Allocator, io: std.Io, query: []const u8) Failure.Error![]u8 {
    const search_query = try std.fmt.allocPrint(gpa, "{s} Neural Amp Modeler NAM capture download", .{query});
    defer gpa.free(search_query);
    const enc = try qenc(gpa, search_query);
    defer gpa.free(enc);
    const url = try std.fmt.allocPrint(gpa, "https://duckduckgo.com/html/?q={s}", .{enc});
    defer gpa.free(url);
    const resp = http.fetch(http.ctx, gpa, io, .GET, url, &.{.{ .name = "User-Agent", .value = "maqam-live/1.1" }}, null) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return f.fail("NAM search failed for `{s}`: {s}; check your network connection, or paste a direct .nam URL and run `nam import URL as name`", .{ query, @errorName(err) });
    };
    defer resp.deinit(gpa);
    if (resp.status >= 400) {
        const compact = try compactErrorBody(gpa, resp.body);
        defer gpa.free(compact);
        return f.fail("NAM search HTTP {d} for `{s}`: {s}; try a different query, or paste a direct .nam URL and run `nam import URL as name`", .{ resp.status, query, compact });
    }
    if (!std.unicode.utf8ValidateSlice(resp.body))
        return f.fail("NAM search response could not be read: stream did not contain valid UTF-8; paste a direct .nam URL and run `nam import URL as name`", .{});
    var results = try extractSearchLinks(gpa, resp.body, 8);
    defer freeResults(gpa, &results);
    var direct: std.ArrayList(SearchResult) = .empty;
    defer freeResults(gpa, &direct);
    for (results.items) |r| if (containsIgnoreCase(r.url, ".nam")) {
        try direct.append(gpa, .{ .title = try gpa.dupe(u8, r.title), .url = try gpa.dupe(u8, r.url) });
    };
    for (results.items[0..@min(4, results.items.len)]) |r| {
        if (direct.items.len >= 8 or containsIgnoreCase(r.url, ".nam")) continue;
        var page = fetchDirectNamLinksFromPage(gpa, http, io, r.url, 4) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer freeResults(gpa, &page);
        for (page.items) |link| {
            var dup = false;
            for (direct.items) |d| if (std.mem.eql(u8, d.url, link.url)) {
                dup = true;
            };
            if (!dup) try direct.append(gpa, .{ .title = try gpa.dupe(u8, link.title), .url = try gpa.dupe(u8, link.url) });
        }
    }
    if (direct.items.len > 0) {
        try results.insertSlice(gpa, 0, direct.items);
        direct.clearRetainingCapacity();
    }
    if (results.items.len == 0) {
        return std.fmt.allocPrint(gpa, "No NAM capture links were found for `{s}`. Try a more specific query such as `Mesa Mark IIC+ NAM`, `5150 NAM`, or paste a direct .nam URL and run `nam import URL as name`.", .{query});
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "Real search results for `{s}`:\nUse a direct .nam URL with `nam import URL as name`; if a result is a page, open it and copy the .nam download URL.", .{query});
    for (results.items, 0..) |r, i| try out.print(gpa, "\n{d}. {s} — {s}", .{ i + 1, r.title, r.url });
    return out.toOwnedSlice(gpa);
}

fn fetchDirectNamLinksFromPage(gpa: Allocator, http: Http, io: std.Io, url: []const u8, limit: usize) !std.ArrayList(SearchResult) {
    const resp = try http.fetch(http.ctx, gpa, io, .GET, url, &.{.{ .name = "User-Agent", .value = "maqam-live/1.1" }}, null);
    defer resp.deinit(gpa);
    if (resp.status >= 400) return error.HttpStatus;
    if (!std.unicode.utf8ValidateSlice(resp.body)) return error.InvalidUtf8;
    return extractDirectNamLinksFromHtml(gpa, resp.body, url, limit);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

fn extractSearchLinks(gpa: Allocator, html: []const u8, limit: usize) Allocator.Error!std.ArrayList(SearchResult) {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer freeResults(gpa, &results);
    var rest = html;
    while (std.mem.indexOf(u8, rest, "href=\"")) |href_start| {
        rest = rest[href_start + "href=\"".len ..];
        const href_end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const raw_href = rest[0..href_end];
        rest = rest[href_end + 1 ..];
        const url = try normalizeSearchHref(gpa, raw_href);
        var keep = false;
        defer if (!keep) gpa.free(url);
        if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) continue;
        var dup = false;
        for (results.items) |r| if (std.mem.eql(u8, r.url, url)) {
            dup = true;
        };
        if (dup) continue;
        var title: ?[]u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '>')) |start| {
            if (std.mem.indexOf(u8, rest[start + 1 ..], "</a>")) |end| {
                const t = try stripHtmlTags(gpa, rest[start + 1 .. start + 1 + end]);
                if (t.len > 0) title = t else gpa.free(t);
            }
        }
        const t = title orelse try gpa.dupe(u8, url);
        if (!looksLikeNamResult(url, t)) {
            gpa.free(t);
            continue;
        }
        keep = true;
        results.append(gpa, .{ .title = t, .url = url }) catch |e| {
            gpa.free(t);
            gpa.free(url);
            return e;
        };
        if (results.items.len >= limit) break;
    }
    return results;
}

fn extractDirectNamLinksFromHtml(gpa: Allocator, html: []const u8, base_url: []const u8, limit: usize) Allocator.Error!std.ArrayList(SearchResult) {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer freeResults(gpa, &results);
    var rest = html;
    while (std.mem.indexOf(u8, rest, "href=\"")) |href_start| {
        rest = rest[href_start + "href=\"".len ..];
        const href_end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const raw_href = rest[0..href_end];
        rest = rest[href_end + 1 ..];
        const decoded = try htmlEntityDecode(gpa, raw_href);
        defer gpa.free(decoded);
        const url = (try resolveLinkUrl(gpa, decoded, base_url)) orelse continue;
        var keep = false;
        defer if (!keep) gpa.free(url);
        if (!containsIgnoreCase(url, ".nam")) continue;
        var dup = false;
        for (results.items) |r| if (std.mem.eql(u8, r.url, url)) {
            dup = true;
        };
        if (dup) continue;
        const last = if (std.mem.lastIndexOfScalar(u8, url, '/')) |i| url[i + 1 ..] else url;
        var title = try percentDecode(gpa, last);
        if (title.len == 0) {
            gpa.free(title);
            title = try gpa.dupe(u8, "NAM download");
        }
        keep = true;
        results.append(gpa, .{ .title = title, .url = url }) catch |e| {
            gpa.free(title);
            gpa.free(url);
            return e;
        };
        if (results.items.len >= limit) break;
    }
    return results;
}

fn resolveLinkUrl(gpa: Allocator, href: []const u8, base_url: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.startsWith(u8, href, "https://") or std.mem.startsWith(u8, href, "http://")) return try gpa.dupe(u8, href);
    if (std.mem.startsWith(u8, href, "//")) return try std.fmt.allocPrint(gpa, "https:{s}", .{href});
    if (std.mem.startsWith(u8, href, "/")) {
        const sep = std.mem.indexOf(u8, base_url, "://") orelse return null;
        const scheme = base_url[0..sep];
        const rest = base_url[sep + 3 ..];
        const host = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        return try std.fmt.allocPrint(gpa, "{s}://{s}{s}", .{ scheme, host, href });
    }
    return null;
}

fn normalizeSearchHref(gpa: Allocator, raw_href: []const u8) Allocator.Error![]u8 {
    const href = try htmlEntityDecode(gpa, raw_href);
    const prefixes = [_][]const u8{ "//duckduckgo.com/l/?", "https://duckduckgo.com/l/?", "http://duckduckgo.com/l/?", "/l/?" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, href, p)) {
            var parts = std.mem.splitScalar(u8, href[p.len..], '&');
            while (parts.next()) |part| {
                if (std.mem.startsWith(u8, part, "uddg=")) {
                    defer gpa.free(href);
                    return percentDecode(gpa, part["uddg=".len..]);
                }
            }
            break;
        }
    }
    return href;
}

fn looksLikeNamResult(url: []const u8, title: []const u8) bool {
    for ([_][]const u8{ url, title }) |s| {
        if (containsIgnoreCase(s, ".nam") or containsIgnoreCase(s, "neural amp modeler") or containsIgnoreCase(s, "tonehunt") or containsIgnoreCase(s, "nam capture")) return true;
    }
    // A needle may span the joining space ("<url> <title>").
    var buf: [2048]u8 = undefined;
    const combined = std.fmt.bufPrint(&buf, "{s} {s}", .{ url, title }) catch return false;
    return containsIgnoreCase(combined, "neural amp modeler") or containsIgnoreCase(combined, "nam capture");
}

fn stripHtmlTags(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var in_tag = false;
    for (input) |ch| switch (ch) {
        '<' => in_tag = true,
        '>' => in_tag = false,
        else => if (!in_tag) try out.append(gpa, ch),
    };
    const decoded = try htmlEntityDecode(gpa, out.items);
    defer gpa.free(decoded);
    return cleanLlmAnswer(gpa, decoded);
}

/// Percent-decoding ('+' is a space), invalid UTF-8 replaced like from_utf8_lossy.
fn percentDecode(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16)) |v| {
                if (std.ascii.isHex(input[i + 1]) and std.ascii.isHex(input[i + 2])) {
                    try out.append(gpa, v);
                    i += 3;
                    continue;
                }
            } else |_| {}
        }
        try out.append(gpa, if (input[i] == '+') ' ' else input[i]);
        i += 1;
    }
    return utf8Lossy(gpa, out.items);
}

fn utf8Lossy(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i .. i + n])) |_| {
                try out.appendSlice(gpa, bytes[i .. i + n]);
                i += n;
                continue;
            } else |_| {}
        }
        try out.appendSlice(gpa, "\u{FFFD}");
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn htmlEntityDecode(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var cur = try gpa.dupe(u8, input);
    const pairs = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&lt;", "<" }, .{ "&gt;", ">" } };
    for (pairs) |p| {
        const next = try std.mem.replaceOwned(u8, gpa, cur, p[0], p[1]);
        gpa.free(cur);
        cur = next;
    }
    return cur;
}

/// One returned command split on ';' and on repeated sym nouns. Caller owns the strings.
fn splitToolCommand(gpa: Allocator, cmd: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &out);
    var parts = std.mem.splitScalar(u8, cmd, ';');
    while (parts.next()) |raw| {
        const part = rs.trim(raw);
        if (part.len == 0) continue;
        try splitRepeatedCommandNouns(gpa, part, &out);
    }
    return out.toOwnedSlice(gpa);
}

fn splitRepeatedCommandNouns(gpa: Allocator, cmd: []const u8, out: *std.ArrayList([]u8)) Allocator.Error!void {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(gpa);
    var it = rs.words(cmd);
    while (it.next()) |w| try tokens.append(gpa, w);
    if (tokens.items.len < 3 or !isSymCommandNoun(tokens.items[0])) {
        try out.append(gpa, try gpa.dupe(u8, cmd));
        return;
    }
    var start: usize = 0;
    for (1..tokens.items.len) |i| {
        if (isSymCommandNoun(tokens.items[i])) {
            try out.append(gpa, try std.mem.join(gpa, " ", tokens.items[start..i]));
            start = i;
        }
    }
    try out.append(gpa, try std.mem.join(gpa, " ", tokens.items[start..]));
}

fn isSymCommandNoun(token: []const u8) bool {
    for ([_][]const u8{ "sym", "sympathetics", "tanbura", "tambura" }) |n| if (std.ascii.eqlIgnoreCase(token, n)) return true;
    return false;
}

fn llmPromptIsEditRequest(prompt: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const lower = asciiLowerBuf(rs.trim(prompt), &buf);
    // trim_start only: trailing whitespace does not matter for prefixes
    const prefixes = [_][]const u8{ "let's ", "lets ", "i need ", "we need ", "i want ", "we want ", "please ", "can you ", "make ", "add ", "do ", "put ", "use ", "enable ", "turn on ", "set ", "create ", "change ", "replace ", "insert ", "delete " };
    var lower2_buf: [4097]u8 = undefined;
    // Prefixes end in a space: a prompt trimmed to exactly "add" would not match, as in the Rust
    // (which keeps the trailing text); re-add one trailing space when the original had one.
    const t_start = trimStartRust(prompt);
    const lw = asciiLowerBuf(t_start, &lower2_buf);
    _ = lower;
    for (prefixes) |p| if (std.mem.startsWith(u8, lw, p)) return true;
    return llmPromptIsHowToAction(lw);
}

fn trimStartRust(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const l = rs.wsLen(s, i);
        if (l == 0) break;
        i += l;
    }
    return s[i..];
}

fn llmPromptIsHowToAction(lower: []const u8) bool {
    if (std.mem.startsWith(u8, lower, "what ") or std.mem.startsWith(u8, lower, "why ") or containsLower(lower, "valid value") or containsLower(lower, "explain")) return false;
    const actionish = [_][]const u8{ "how do i get ", "how do i add ", "how do i use ", "how do i enable ", "how do i turn on ", "how can i get ", "how can i add ", "how can i use ", "how can i enable ", "how can i turn on " };
    for (actionish) |p| if (std.mem.startsWith(u8, lower, p)) return true;
    return false;
}

fn llmRejectedEditCommandMessage(gpa: Allocator, src: []const u8, cmd: Cmd) Allocator.Error![]u8 {
    return switch (cmd) {
        .set_nam => std.fmt.allocPrint(gpa, "✗ LLM returned `{s}`, but NAM is live input state, not a score edit; import a real .nam file with `nam import FILENAME.nam as name`, then run `nam name` yourself", .{src}),
        else => std.fmt.allocPrint(gpa, "✗ LLM returned `{s}`, but LLM edits cannot run save/load/playback/system commands; ask it for score-edit commands only", .{src}),
    };
}

fn llmEditPrompt(gpa: Allocator, user_prompt: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "User wants this edit:\n{s}\n\nThis is an action request: make the change with the apply_maqam_commands tool instead of explaining how the user could do it. Use the current score from the system prompt as context. Return only new maqam-live commands to apply the edit, separated by newlines or semicolons. Never concatenate two commands without a separator; use `sym on; sym decay 0.999 drive 2`, not `sym on sym decay 0.999 drive 2`. Do not include existing score lines, ids, markdown, bullets, explanations, or comments. Never return save, load, m/record, q/quit, z/playback, pause, start, clock, help, ls, audition, or clear commands. NAM edits must be portable: use only `nam tone3000 ID as name` or `nam pin DIRECT_URL as name`, never a bare local alias.", .{user_prompt});
}

/// The allowlist of LLM edits (property "The LLM never saves, loads, records or plays").
fn llmEditCommandAllowed(cmd: Cmd) bool {
    return switch (cmd) {
        .set_nam => |n| switch (n) {
            .pin, .tone3000 => true,
            else => false,
        },
        .add_phrase, .jump, .insert, .insert_bpm, .insert_sustain, .insert_vcf, .insert_fx, .insert_sympathetics, .insert_sympathetic_decay, .insert_sympathetic_gain, .insert_sympathetic, .move_up, .move_down, .edit, .edit_jump, .edit_bpm, .edit_sustain, .edit_vcf, .edit_fx, .edit_sympathetics, .edit_sympathetic_decay, .edit_sympathetic_gain, .edit_sympathetic, .insert_jump, .delete_bars, .rotate, .stop, .sympathetics, .sympathetic_decay, .sympathetic_gain, .sympathetic, .set_bpm, .set_sustain, .set_vcf, .set_fx, .create_jins, .delete_jins => true,
        else => false,
    };
}

fn llmEditCommandConsumesTimelineId(cmd: Cmd) bool {
    return switch (cmd) {
        .add_phrase, .jump, .insert, .insert_bpm, .insert_sustain, .insert_vcf, .insert_fx, .insert_sympathetics, .insert_sympathetic_decay, .insert_sympathetic_gain, .insert_sympathetic, .insert_jump, .stop, .sympathetics, .sympathetic_decay, .sympathetic_gain, .sympathetic, .set_bpm, .set_sustain, .set_vcf, .set_fx => true,
        else => false,
    };
}

fn dupeList(gpa: Allocator, items: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (items) |s| {
        out[filled] = try gpa.dupe(u8, s);
        filled += 1;
    }
    return out;
}

/// A trailing run of 4 or more identical phrase blocks becomes one phrase with rN or the block
/// plus a jump (the Rust `minimize_repeated_llm_phrase_commands`). Caller owns the result.
fn minimizeRepeatedLlmPhraseCommands(gpa: Allocator, commands: []const []const u8, next_phrase_id: usize) Allocator.Error![][]u8 {
    if (commands.len < 4) return dupeList(gpa, commands);
    var parsed: std.ArrayList(Cmd) = .empty;
    defer {
        for (parsed.items) |c| c.deinit(gpa);
        parsed.deinit(gpa);
    }
    for (commands) |src| {
        switch (try command.parse(gpa, src)) {
            .ok => |c| parsed.append(gpa, c) catch |e| {
                c.deinit(gpa);
                return e;
            },
            .err => |m| {
                gpa.free(m);
                return dupeList(gpa, commands);
            },
        }
    }
    var last_non_phrase: ?usize = null;
    var i = parsed.items.len;
    while (i > 0) {
        i -= 1;
        if (parsed.items[i] != .add_phrase) {
            last_non_phrase = i;
            break;
        }
    }
    const lnp = last_non_phrase orelse {
        return (try minimizeRepeatedPhraseRun(gpa, commands, next_phrase_id)) orelse dupeList(gpa, commands);
    };
    const run_start = lnp + 1;
    if (run_start >= parsed.items.len or parsed.items.len - run_start < 4) return dupeList(gpa, commands);
    var consumed: usize = 0;
    for (parsed.items[0..run_start]) |c| if (llmEditCommandConsumesTimelineId(c)) {
        consumed += 1;
    };
    const minimized = (try minimizeRepeatedPhraseRun(gpa, commands[run_start..], next_phrase_id + consumed)) orelse return dupeList(gpa, commands);
    defer gpa.free(minimized);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &out);
    for (commands[0..run_start]) |c| try out.append(gpa, try gpa.dupe(u8, c));
    try out.appendSlice(gpa, minimized);
    return out.toOwnedSlice(gpa);
}

fn minimizeRepeatedPhraseRun(gpa: Allocator, commands: []const []const u8, first_phrase_id: usize) Allocator.Error!?[][]u8 {
    const Src = struct { source: []u8, repeat: usize };
    var sources: std.ArrayList(Src) = .empty;
    defer {
        for (sources.items) |s| gpa.free(s.source);
        sources.deinit(gpa);
    }
    for (commands) |src| {
        const r = try command.parse(gpa, src);
        defer r.deinit(gpa);
        switch (r) {
            .ok => |c| switch (c) {
                .add_phrase => |v| try sources.append(gpa, .{ .source = try gpa.dupe(u8, v.source), .repeat = v.repeat }),
                else => return null,
            },
            .err => return null,
        }
    }
    const total = sources.items.len;
    var block_len: usize = 1;
    while (block_len <= total / 2) : (block_len += 1) {
        if (total % block_len != 0) continue;
        const repeats = total / block_len;
        if (repeats < 2) continue;
        const block = sources.items[0..block_len];
        var all = true;
        var k: usize = 0;
        while (k < total) : (k += block_len) {
            for (0..block_len) |j| {
                const a = sources.items[k + j];
                if (!std.mem.eql(u8, a.source, block[j].source) or a.repeat != block[j].repeat) all = false;
            }
        }
        if (!all) continue;
        var out: std.ArrayList([]u8) = .empty;
        errdefer freeList(gpa, &out);
        if (block_len == 1) {
            try out.append(gpa, try phraseSourceWithRepeat(gpa, block[0].source, block[0].repeat * repeats));
            return try out.toOwnedSlice(gpa);
        }
        for (block) |b| try out.append(gpa, try gpa.dupe(u8, b.source));
        try out.append(gpa, try std.fmt.allocPrint(gpa, "j {d} {d}", .{ first_phrase_id, repeats }));
        return try out.toOwnedSlice(gpa);
    }
    return null;
}

fn phraseSourceWithRepeat(gpa: Allocator, source: []const u8, repeat: usize) Allocator.Error![]u8 {
    const trimmed = rs.trimEnd(source);
    const r = @max(repeat, 1);
    // rsplit_once on one whitespace character
    var split: ?usize = null;
    var i: usize = 0;
    while (i < trimmed.len) {
        const l = rs.wsLen(trimmed, i);
        if (l > 0) {
            split = i;
            i += l;
        } else i += 1;
    }
    const at = split orelse return std.fmt.allocPrint(gpa, "{s} r{d}", .{ trimmed, r });
    const base = trimmed[0..at];
    const last = trimmed[at + rs.wsLen(trimmed, at) ..];
    if (last.len >= 2 and std.ascii.toLower(last[0]) == 'r') {
        var digits = true;
        for (last[1..]) |c| {
            if (!std.ascii.isDigit(c)) digits = false;
        }
        if (digits) return std.fmt.allocPrint(gpa, "{s} r{d}", .{ rs.trimEnd(base), r });
    }
    return std.fmt.allocPrint(gpa, "{s} r{d}", .{ trimmed, r });
}

// ── Free functions: NAM, TONE3000 ─────────────────────────────────────────────

fn isHttpUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://");
}

/// Only [A-Za-z0-9._-] survive, whitespace becomes '-', and leading / trailing '.' and '-' go.
pub fn sanitizeNamCacheName(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const t = rs.trim(name);
    var i: usize = 0;
    while (i < t.len) {
        const ws = rs.wsLen(t, i);
        if (ws > 0) {
            try out.append(gpa, '-');
            i += ws;
            continue;
        }
        const ch = t[i];
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') try out.append(gpa, ch);
        i += std.unicode.utf8ByteSequenceLength(ch) catch 1;
    }
    var s: []const u8 = out.items;
    s = std.mem.trim(u8, s, ".");
    s = std.mem.trim(u8, s, "-");
    return gpa.dupe(u8, s);
}

/// A name that can be joined to the cache directory without leaving it.
fn isSafeCacheName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (c == '/' or c == '\\' or c == 0) return false;
    if (std.mem.indexOf(u8, name, "..") != null and std.mem.trim(u8, name, ".").len == 0) return false;
    return true;
}

fn cachePath(gpa: Allocator, cache_dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (cache_dir.len > 0 and cache_dir[cache_dir.len - 1] == '/') return std.fmt.allocPrint(gpa, "{s}{s}.nam", .{ cache_dir, name });
    return std.fmt.allocPrint(gpa, "{s}/{s}.nam", .{ cache_dir, name });
}

fn samePath(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeScalar(u8, a, '/');
    var ib = std.mem.tokenizeScalar(u8, b, '/');
    while (true) {
        var x = ia.next();
        while (x != null and std.mem.eql(u8, x.?, ".")) x = ia.next();
        var y = ib.next();
        while (y != null and std.mem.eql(u8, y.?, ".")) y = ib.next();
        if (x == null or y == null) return x == null and y == null and (a.len > 0 and b.len > 0 and (a[0] == '/') == (b[0] == '/'));
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

/// The file name of a path (Rust `Path::file_name`).
fn fileName(path: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, path, "/");
    if (t.len == 0) return null;
    const name = if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| t[i + 1 ..] else t;
    if (std.mem.eql(u8, name, "..")) return null;
    return name;
}

/// Rust `Path::file_stem`.
fn fileStem(path: []const u8) ?[]const u8 {
    const name = fileName(path) orelse return null;
    if (std.mem.eql(u8, name, ".")) return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot == 0) return name;
    return name[0..dot];
}

/// The stem of a file named "<stem>.nam" (Rust extension() == "nam"), else null.
fn namStem(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0) return null;
    if (!std.mem.eql(u8, name[dot + 1 ..], "nam")) return null;
    return name[0..dot];
}

fn namCacheNameFromPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    if (fileStem(path)) |stem| {
        const s = try sanitizeNamCacheName(gpa, stem);
        if (s.len > 0) return s;
        gpa.free(s);
    }
    return gpa.dupe(u8, "model");
}

fn namCacheNameFromUrl(gpa: Allocator, url: []const u8) Allocator.Error![]u8 {
    const without_fragment = url[0 .. std.mem.indexOfScalar(u8, url, '#') orelse url.len];
    var without_query = without_fragment[0 .. std.mem.indexOfScalar(u8, without_fragment, '?') orelse without_fragment.len];
    without_query = std.mem.trimEnd(u8, without_query, "/");
    const filename = if (std.mem.lastIndexOfScalar(u8, without_query, '/')) |i| without_query[i + 1 ..] else without_query;
    const stem = if (std.mem.endsWith(u8, filename, ".nam")) filename[0 .. filename.len - 4] else filename;
    return sanitizeNamCacheName(gpa, stem);
}

fn writeAuthJson(w: *std.Io.Writer, auth: Tone3000Auth) !void {
    // serde_json's map order (sorted keys)
    try w.writeAll("{\"access_token\":");
    try jsonStr(w, auth.access_token);
    try w.writeAll(",\"client_id\":");
    try jsonStr(w, auth.client_id);
    try w.print(",\"expires_at\":{d},\"refresh_token\":", .{auth.expires_at});
    if (auth.refresh_token) |r| try jsonStr(w, r) else try w.writeAll("null");
    try w.writeAll("}");
}

fn loadTone3000AuthAt(f: *Failure, gpa: Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) Failure.Error!Tone3000Auth {
    const text = cwd.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return f.fail("{s}: {s}", .{ path, ioErrText(err) });
    };
    defer gpa.free(text);
    var parsed = std.json.parseFromSlice(Value, gpa, text, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return f.fail("{s}: {s}", .{ path, @errorName(err) });
    };
    defer parsed.deinit();
    const access = jstrOf(jget(parsed.value, "access_token")) orelse return f.fail("stored access token is missing", .{});
    const client = jstrOf(jget(parsed.value, "client_id")) orelse return f.fail("stored client ID is missing", .{});
    const a = try gpa.dupe(u8, access);
    errdefer gpa.free(a);
    const r = if (jstrOf(jget(parsed.value, "refresh_token"))) |x| try gpa.dupe(u8, x) else null;
    errdefer if (r) |x| gpa.free(x);
    const c = try gpa.dupe(u8, client);
    return .{ .access_token = a, .refresh_token = r, .expires_at = ju64Of(jget(parsed.value, "expires_at")) orelse 0, .client_id = c };
}

fn unixTime(io: std.Io) u64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@max(@divTrunc(ts.nanoseconds, std.time.ns_per_s), 0));
}

fn tone3000ModelUrl(f: *Failure, http: Http, gpa: Allocator, io: std.Io, tone_id: u64, token: []const u8) Failure.Error![]u8 {
    const url = try std.fmt.allocPrint(gpa, "https://www.tone3000.com/api/v1/models?tone_id={d}&page=1&page_size=1&architecture=2", .{tone_id});
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth);
    var parsed = try httpJson(f, http, gpa, io, .GET, url, &.{ .{ .name = "Authorization", .value = auth }, .{ .name = "Content-Type", .value = "application/json" } }, null, "TONE3000 response could not be read");
    defer parsed.deinit();
    const model_url = jstrOf(jgetOpt(jidx(jget(parsed.value, "data"), 0), "model_url")) orelse
        return f.fail("TONE3000 tone {d} has no downloadable A2 NAM model", .{tone_id});
    return gpa.dupe(u8, model_url);
}

fn randomBase64Url(gpa: Allocator, io: std.Io, comptime n: usize) Allocator.Error![]u8 {
    var raw: [n]u8 = undefined;
    io.random(&raw);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(n));
    _ = enc.encode(out, &raw);
    return out;
}

/// The OAuth PKCE login: a loopback listener, the browser, the callback, the token exchange.
fn tone3000BrowserLogin(f: *Failure, http: Http, gpa: Allocator, io: std.Io, client_id: []const u8) Failure.Error!Tone3000Auth {
    if (!http.online) return f.fail("could not start local OAuth callback: the network is disabled", .{});
    var addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| return f.fail("could not start local OAuth callback: {s}", .{@errorName(err)});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    const redirect_uri = try std.fmt.allocPrint(gpa, "http://localhost:{d}/callback", .{port});
    defer gpa.free(redirect_uri);
    const verifier = try randomBase64Url(gpa, io, 64);
    defer gpa.free(verifier);
    const state = try randomBase64Url(gpa, io, 32);
    defer gpa.free(state);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    const q_client = try qenc(gpa, client_id);
    defer gpa.free(q_client);
    const q_redirect = try qenc(gpa, redirect_uri);
    defer gpa.free(q_redirect);
    const auth_url = try std.fmt.allocPrint(gpa, "https://www.tone3000.com/api/v1/oauth/authorize?client_id={s}&redirect_uri={s}&response_type=code&code_challenge={s}&code_challenge_method=S256&state={s}", .{ q_client, q_redirect, &challenge, state });
    defer gpa.free(auth_url);
    http.open_browser(http.ctx, gpa, io, auth_url) catch |err| {
        if (err == error.BrowserExitFailure) return f.fail("could not open browser; visit {s}", .{auth_url});
        return f.fail("could not open browser: {s}", .{@errorName(err)});
    };
    const stream = server.accept(io) catch |err| return f.fail("OAuth callback failed: {s}", .{@errorName(err)});
    defer stream.close(io);
    var request: [8192]u8 = undefined;
    var bufs = [_][]u8{&request};
    const length = stream.read(io, &bufs) catch |err| return f.fail("OAuth callback could not be read: {s}", .{@errorName(err)});
    const first_line = std.mem.sliceTo(request[0..length], '\n');
    var parts = rs.words(first_line);
    _ = parts.next();
    const target = parts.next() orelse return f.fail("invalid OAuth callback", .{});
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
    var returned_state: ?[]u8 = null;
    defer if (returned_state) |s| gpa.free(s);
    var code: ?[]u8 = null;
    defer if (code) |s| gpa.free(s);
    var oauth_error: ?[]u8 = null;
    defer if (oauth_error) |s| gpa.free(s);
    var pairs = std.mem.splitScalar(u8, std.mem.sliceTo(query, '#'), '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const k = pair[0..eq];
        const v = if (eq < pair.len) pair[eq + 1 ..] else "";
        const slot: *?[]u8 = if (std.mem.eql(u8, k, "state")) &returned_state else if (std.mem.eql(u8, k, "code")) &code else if (std.mem.eql(u8, k, "error")) &oauth_error else continue;
        if (slot.* == null) slot.* = try percentDecode(gpa, v);
    }
    const rstate = returned_state orelse return f.fail("OAuth callback omitted state", .{});
    if (!std.mem.eql(u8, rstate, state)) return f.fail("OAuth state did not match", .{});
    const the_code = code orelse {
        if (oauth_error) |e| return f.fail("{s}", .{e});
        return f.fail("OAuth callback omitted code", .{});
    };
    const body = "TONE3000 login complete. You can return to maqam-live.";
    var wbuf: [512]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    sw.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch {};
    sw.interface.flush() catch {};
    const e_code = try qenc(gpa, the_code);
    defer gpa.free(e_code);
    const e_cid = try qenc(gpa, client_id);
    defer gpa.free(e_cid);
    const form = try std.fmt.allocPrint(gpa, "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&code_verifier={s}", .{ e_code, q_redirect, e_cid, verifier });
    defer gpa.free(form);
    var token = try httpJson(f, http, gpa, io, .POST, "https://www.tone3000.com/api/v1/oauth/token", &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }}, form, "TONE3000 token response could not be read");
    defer token.deinit();
    const access = jstrOf(jget(token.value, "access_token")) orelse return f.fail("TONE3000 returned no access token", .{});
    const a = try gpa.dupe(u8, access);
    errdefer gpa.free(a);
    const r = if (jstrOf(jget(token.value, "refresh_token"))) |x| try gpa.dupe(u8, x) else null;
    errdefer if (r) |x| gpa.free(x);
    const c = try gpa.dupe(u8, client_id);
    return .{ .access_token = a, .refresh_token = r, .expires_at = unixTime(io) + (ju64Of(jget(token.value, "expires_in")) orelse 3600), .client_id = c };
}

// ── Free functions: completion ────────────────────────────────────────────────

const CompletionTarget = struct { cmd: []const u8, arg_start: usize, partial: []const u8 };

fn completionTarget(input: []const u8) ?CompletionTarget {
    const trimmed = trimStartRust(input);
    const leading = input.len - trimmed.len;
    var cmd_end: usize = trimmed.len;
    var i: usize = 0;
    while (i < trimmed.len) {
        if (rs.wsLen(trimmed, i) > 0) {
            cmd_end = i;
            break;
        }
        i += 1;
    }
    const cmd = trimmed[0..cmd_end];
    if (!std.mem.eql(u8, cmd, "save") and !std.mem.eql(u8, cmd, "load")) return null;
    const rest = if (cmd_end < trimmed.len) trimmed[cmd_end + rs.wsLen(trimmed, cmd_end) ..] else "";
    const rest_start = leading + cmd.len;
    const arg = trimStartRust(rest);
    const arg_start = input.len - arg.len;
    return .{ .cmd = cmd, .arg_start = @max(arg_start, rest_start), .partial = arg };
}

fn phraseCompletion(gpa: Allocator, input: []const u8, phrases: []const Phrase) Allocator.Error!?[]u8 {
    const trimmed = trimStartRust(input);
    const leading = input.len - trimmed.len;
    var words = rs.words(trimmed);
    const root_token = words.next() orelse return null;
    if (words.next() != null) return null;
    const typed_root = Pitch.parse(root_token) orelse return null;
    var current: ?*const Phrase = null;
    var i = phrases.len;
    while (i > 0) {
        i -= 1;
        if (phrases[i].jump == null and phrases[i].control == null) {
            current = &phrases[i];
            break;
        }
    }
    const cur = current orelse return null;
    const maqam = phraseCompletionMaqam(cur, typed_root) orelse return null;
    const rhythm = phraseRhythmToken(cur) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, ' ', leading);
    try out.print(gpa, "{s} {s} {s}", .{ root_token, maqam, rhythm });
    if (cur.repeat > 1) try out.print(gpa, " r{d}", .{cur.repeat});
    return try out.toOwnedSlice(gpa);
}

fn phraseRhythmToken(phrase: *const Phrase) ?[]const u8 {
    var last: ?[]const u8 = null;
    var it = rs.words(phrase.src);
    while (it.next()) |t| {
        var all = true;
        for (t) |c| {
            if (!std.ascii.isDigit(c)) all = false;
        }
        if (all) last = t;
    }
    return last;
}

fn phraseCompletionMaqam(current: *const Phrase, typed_root: Pitch) ?[]const u8 {
    const name = current.bar.maqam.name();
    const shift = pitchClassDelta(current.bar.root, typed_root);
    if (std.mem.eql(u8, name, "Bayati") and shift == 10) return "rast";
    if ((std.mem.eql(u8, name, "Minor") or std.mem.eql(u8, name, "Aeolian")) and shift == 3) return "major";
    return null;
}

fn pitchClassDelta(from: Pitch, to: Pitch) i8 {
    return @mod(pitchClass(to) - pitchClass(from), 12);
}

fn pitchClass(p: Pitch) i8 {
    const natural: i8 = switch (std.ascii.toLower(p.letter)) {
        'c' => 0,
        'd' => 2,
        'e' => 4,
        'f' => 5,
        'g' => 7,
        'a' => 9,
        'b' => 11,
        else => 0,
    };
    return @mod(natural + p.accidental, 12);
}

const Word = struct { start: usize, end: usize, text: []const u8 };

fn wordsWithSpans(gpa: Allocator, input: []const u8) Allocator.Error![]Word {
    var out: std.ArrayList(Word) = .empty;
    errdefer out.deinit(gpa);
    var start: ?usize = null;
    var i: usize = 0;
    while (i < input.len) {
        const ws = rs.wsLen(input, i);
        if (ws > 0) {
            if (start) |s| try out.append(gpa, .{ .start = s, .end = i, .text = input[s..i] });
            start = null;
            i += ws;
        } else {
            if (start == null) start = i;
            i += 1;
        }
    }
    if (start) |s| try out.append(gpa, .{ .start = s, .end = input.len, .text = input[s..] });
    return out.toOwnedSlice(gpa);
}

const BodyRef = struct { start: usize };

fn commandBodyForCompletion(input: []const u8) ?BodyRef {
    const trimmed = trimStartRust(input);
    const leading = input.len - trimmed.len;
    var buf: [8]Word = undefined;
    var n: usize = 0;
    var start: ?usize = null;
    var i: usize = 0;
    while (i < trimmed.len and n < buf.len) {
        const ws = rs.wsLen(trimmed, i);
        if (ws > 0) {
            if (start) |s| {
                buf[n] = .{ .start = s, .end = i, .text = trimmed[s..i] };
                n += 1;
            }
            start = null;
            i += ws;
        } else {
            if (start == null) start = i;
            i += 1;
        }
    }
    if (start) |s| if (n < buf.len) {
        buf[n] = .{ .start = s, .end = trimmed.len, .text = trimmed[s..] };
        n += 1;
    };
    if (n == 0) return null;
    const first = buf[0].text;
    var alpha_end: usize = 0;
    while (alpha_end < first.len and std.ascii.isAlphabetic(first[alpha_end])) alpha_end += 1;
    const first_alpha = first[0..alpha_end];
    const first_digits = first[alpha_end..];
    if (std.ascii.eqlIgnoreCase(first_alpha, "edit")) {
        if (n < 2) return null;
        const body_start = if (n > 2) buf[2].start else trimmed.len;
        if (parseIsize(buf[1].text) == null) return null;
        return .{ .start = leading + body_start };
    }
    if (std.ascii.eqlIgnoreCase(first_alpha, "i")) {
        if (first_digits.len > 0) {
            const body_start = if (n > 1) buf[1].start else trimmed.len;
            return .{ .start = leading + body_start };
        }
        if (n < 2) return null;
        const body_start = if (n > 2) buf[2].start else trimmed.len;
        if (parseIsize(buf[1].text) == null) return null;
        return .{ .start = leading + body_start };
    }
    return .{ .start = leading };
}

const MetadataCompletion = struct { replacement: ?[]u8, message: ?[]u8 };
const Meta = command.CommandMetadata;
const Param = command.CommandParameterMetadata;

fn metadataCommandCompletion(gpa: Allocator, body: []const u8) Allocator.Error!?MetadataCompletion {
    const body_trimmed = trimStartRust(body);
    const body_leading = body.len - body_trimmed.len;
    if (body_trimmed.len == 0) return null;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(gpa);
    var it = rs.words(body_trimmed);
    while (it.next()) |w| try tokens.append(gpa, w);
    const head = if (tokens.items.len > 0) tokens.items[0] else return null;
    const meta = command.commandMetadata(head) orelse return null;
    const trailing_space = blk: {
        // the last character is whitespace
        var i: usize = body_trimmed.len;
        while (i > 0) {
            i -= 1;
            if ((body_trimmed[i] & 0xC0) != 0x80) break;
        }
        break :blk rs.wsLen(body_trimmed, i) > 0;
    };
    if (tokens.items.len == 1 or trailing_space) try tokens.append(gpa, "");
    const current = tokens.items[tokens.items.len - 1];
    const before = tokens.items[0 .. tokens.items.len - 1];
    if (try metadataValueCompletion(gpa, meta, before, current)) |c| {
        var comp = c;
        if (comp.replacement) |r| {
            defer gpa.free(r);
            comp.replacement = try indent(gpa, body_leading, r);
        }
        return comp;
    }
    const replacement = (try metadataCommandReplacement(gpa, meta, before, current)) orelse return null;
    defer gpa.free(replacement);
    return .{ .replacement = try indent(gpa, body_leading, replacement), .message = null };
}

fn indent(gpa: Allocator, n: usize, s: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, n + s.len);
    @memset(out[0..n], ' ');
    @memcpy(out[n..], s);
    return out;
}

fn canonicalCompletionKey(token: []const u8) []const u8 {
    return token[0 .. std.mem.indexOfScalar(u8, token, '=') orelse token.len];
}

fn paramExpectsValue(p: *const Param) bool {
    return p.values.len > 0 or p.lower != null or p.upper != null or p.units.len > 0;
}

fn completionTokenMatches(name: []const u8, aliases: []const []const u8, partial: []const u8) bool {
    if (partial.len == 0) return false;
    if (std.mem.startsWith(u8, name, partial)) return true;
    for (aliases) |a| if (std.mem.startsWith(u8, a, partial)) return true;
    return false;
}

fn exactCompletionTarget(meta: *const Meta, token: []const u8) ?[]const u8 {
    if (token.len == 0) return null;
    return command.commandTokenName(meta.targets, token);
}

fn firstMatchingCompletionParameter(meta: *const Meta, partial: []const u8, used: []const []const u8) ?*const Param {
    for (meta.parameters) |*p| {
        var is_used = false;
        for (used) |u| if (std.mem.eql(u8, u, p.name)) {
            is_used = true;
        };
        if (!is_used and paramExpectsValue(p) and completionTokenMatches(p.name, p.aliases, partial)) return p;
    }
    return null;
}

fn firstMatchingCompletionToken(meta: *const Meta, partial: []const u8) ?[]const u8 {
    for (meta.targets) |t| if (completionTokenMatches(t.name, t.aliases, partial)) return t.name;
    if (firstMatchingCompletionParameter(meta, partial, &.{})) |p| return p.name;
    return null;
}

fn joinSpace(gpa: Allocator, parts: []const []const u8, trailing: bool) Allocator.Error![]u8 {
    const j = try std.mem.join(gpa, " ", parts);
    if (!trailing) return j;
    defer gpa.free(j);
    return std.fmt.allocPrint(gpa, "{s} ", .{j});
}

fn metadataCommandReplacement(gpa: Allocator, meta: *const Meta, before: []const []const u8, current: []const u8) Allocator.Error!?[]u8 {
    if (before.len == 0) return null;
    const head = before[0];
    var body: std.ArrayList([]const u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, meta.name);
    var idx: usize = 1;
    if (before.len > idx) {
        if (command.commandTokenName(meta.targets, canonicalCompletionKey(before[idx]))) |target| {
            try body.append(gpa, target);
            idx += 1;
        }
    }
    const current_key = canonicalCompletionKey(current);
    if (idx == 1 and before.len == 1) {
        if (exactCompletionTarget(meta, current_key)) |target| {
            try body.append(gpa, target);
            try body.append(gpa, meta.first_parameter);
            return try joinSpace(gpa, body.items, true);
        }
        if (current_key.len == 0) {
            try body.append(gpa, meta.first_parameter);
            return try joinSpace(gpa, body.items, true);
        }
        if (firstMatchingCompletionToken(meta, current_key)) |token| {
            try body.append(gpa, token);
            if (exactCompletionTarget(meta, token) != null) try body.append(gpa, meta.first_parameter);
            return try joinSpace(gpa, body.items, true);
        }
        return null;
    }
    var used: std.ArrayList([]const u8) = .empty;
    defer used.deinit(gpa);
    var scan = idx;
    while (scan < before.len) {
        const token = before[scan];
        const key = canonicalCompletionKey(token);
        if (command.commandParameter(meta, key)) |param| {
            try body.append(gpa, param.name);
            try used.append(gpa, param.name);
            if (std.mem.indexOfScalar(u8, token, '=') != null) {
                scan += 1;
            } else {
                if (scan + 1 < before.len) {
                    const value = before[scan + 1];
                    if (command.commandParameter(meta, canonicalCompletionKey(value)) == null and
                        command.commandTokenName(meta.targets, canonicalCompletionKey(value)) == null)
                    {
                        try body.append(gpa, value);
                        scan += 1;
                    }
                }
                scan += 1;
            }
        } else {
            try body.append(gpa, token);
            scan += 1;
        }
    }
    if (command.commandParameter(meta, current_key)) |param| {
        try body.append(gpa, param.name);
        return try joinSpace(gpa, body.items, true);
    }
    if (firstMatchingCompletionParameter(meta, current_key, used.items)) |param| {
        try body.append(gpa, param.name);
        return try joinSpace(gpa, body.items, true);
    }
    if (current_key.len == 0) {
        for (meta.parameters) |*p| {
            var is_used = false;
            for (used.items) |u| if (std.mem.eql(u8, u, p.name)) {
                is_used = true;
            };
            if (!is_used and paramExpectsValue(p)) {
                try body.append(gpa, p.name);
                return try joinSpace(gpa, body.items, true);
            }
        }
    }
    if (!std.mem.eql(u8, head, meta.name)) return try joinSpace(gpa, body.items, false);
    return null;
}

fn metadataValueCompletion(gpa: Allocator, meta: *const Meta, before: []const []const u8, current: []const u8) Allocator.Error!?MetadataCompletion {
    if (before.len == 2 and command.commandTokenName(meta.targets, canonicalCompletionKey(before[1])) != null) return null;
    if (before.len == 0) return null;
    const param = command.commandParameter(meta, canonicalCompletionKey(before[before.len - 1])) orelse return null;
    if (!paramExpectsValue(param)) return null;
    if (param.values.len == 0) {
        const hint = try parameterValueHint(gpa, param);
        defer gpa.free(hint);
        return .{ .replacement = null, .message = try std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ meta.name, param.name, hint }) };
    }
    var value: ?[]const u8 = null;
    for (param.values) |v| if (std.mem.startsWith(u8, v, current)) {
        value = v;
        break;
    };
    const val = value orelse return null;
    var body: std.ArrayList([]const u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, before);
    body.items[0] = meta.name;
    try body.append(gpa, val);
    return .{ .replacement = try joinSpace(gpa, body.items, true), .message = null };
}

fn parameterValueHint(gpa: Allocator, p: *const Param) Allocator.Error![]u8 {
    if (p.values.len > 0) {
        const j = try std.mem.join(gpa, "|", p.values);
        defer gpa.free(j);
        return std.fmt.allocPrint(gpa, "<{s}>", .{j});
    }
    var lo: [64]u8 = undefined;
    var hi: [64]u8 = undefined;
    const range = if (p.lower != null and p.upper != null)
        try std.fmt.allocPrint(gpa, "{s}..{s}", .{ compactFloat(&lo, p.lower.?), compactFloat(&hi, p.upper.?) })
    else if (p.lower) |l|
        try std.fmt.allocPrint(gpa, ">= {s}", .{compactFloat(&lo, l)})
    else if (p.upper) |u|
        try std.fmt.allocPrint(gpa, "<= {s}", .{compactFloat(&hi, u)})
    else
        try gpa.dupe(u8, "value");
    defer gpa.free(range);
    if (p.units.len == 0) return std.fmt.allocPrint(gpa, "<{s}|+n|-n|+nt>", .{range});
    return std.fmt.allocPrint(gpa, "<{s} {s}|+n|-n|+nt>", .{ range, p.units });
}

fn compactFloat(buf: []u8, value: f64) []const u8 {
    var s = std.fmt.bufPrint(buf, "{f}", .{rfix(value, 5)}) catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (s.len > 0 and s[s.len - 1] == '0') s = s[0 .. s.len - 1];
    }
    if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    return s;
}

/// The .mq files a `save` / `load` argument can complete to (sorted, unique). Caller owns them.
fn mqMatches(gpa: Allocator, io: std.Io, cwd: std.Io.Dir, cmd: []const u8, partial: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &out);
    const recursive = std.mem.eql(u8, cmd, "load") and std.mem.indexOfScalar(u8, partial, '/') == null;
    if (recursive) {
        try recursiveMqMatches(gpa, io, cwd, "", partial, &out, 0);
    } else {
        // Path::parent / file_name of `partial`
        const t = std.mem.trimEnd(u8, partial, "/");
        var dir: []const u8 = ".";
        var prefix: []const u8 = partial;
        if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| {
            if (i > 0) {
                dir = t[0..i];
                prefix = t[i + 1 ..];
            } else {
                dir = "/";
                prefix = t[1..];
            }
        }
        try directMqMatches(gpa, io, cwd, dir, prefix, &out);
    }
    std.mem.sort([]u8, out.items, {}, strLess);
    var w: usize = 0;
    for (out.items, 0..) |s, i| {
        if (i > 0 and std.mem.eql(u8, s, out.items[w - 1])) {
            gpa.free(s);
            continue;
        }
        out.items[w] = s;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
    return out.toOwnedSlice(gpa);
}

fn isMqName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    return dot > 0 and std.mem.eql(u8, name[dot + 1 ..], "mq");
}

fn directMqMatches(gpa: Allocator, io: std.Io, cwd: std.Io.Dir, dir_path: []const u8, prefix: []const u8, out: *std.ArrayList([]u8)) Allocator.Error!void {
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!isMqName(entry.name) or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (std.mem.eql(u8, dir_path, ".")) {
            try out.append(gpa, try gpa.dupe(u8, entry.name));
        } else if (dir_path[dir_path.len - 1] == '/') {
            try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ dir_path, entry.name }));
        } else {
            try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name }));
        }
    }
}

fn recursiveMqMatches(gpa: Allocator, io: std.Io, cwd: std.Io.Dir, rel: []const u8, prefix: []const u8, out: *std.ArrayList([]u8), depth: usize) Allocator.Error!void {
    if (depth > 32) return;
    var dir = cwd.openDir(io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var subdirs: std.ArrayList([]u8) = .empty;
    defer freeList(gpa, &subdirs);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            if (std.mem.eql(u8, entry.name, "target")) continue;
            try subdirs.append(gpa, if (rel.len == 0) try gpa.dupe(u8, entry.name) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name }));
            continue;
        }
        if (!isMqName(entry.name) or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        try out.append(gpa, if (rel.len == 0) try gpa.dupe(u8, entry.name) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name }));
    }
    for (subdirs.items) |s| try recursiveMqMatches(gpa, io, cwd, s, prefix, out, depth + 1);
}

fn longestCommonPrefix(gpa: Allocator, items: []const []const u8) Allocator.Error![]u8 {
    if (items.len == 0) return gpa.dupe(u8, "");
    var keep: usize = items[0].len;
    for (items[1..]) |item| {
        var k: usize = 0;
        var i: usize = 0;
        while (i < keep and i < item.len) {
            const n = std.unicode.utf8ByteSequenceLength(items[0][i]) catch 1;
            if (i + n > keep or i + n > item.len or !std.mem.eql(u8, items[0][i .. i + n], item[i .. i + n])) break;
            i += n;
            k = i;
        }
        keep = k;
        if (keep == 0) break;
    }
    return gpa.dupe(u8, items[0][0..keep]);
}

fn completionCommonPrefix(gpa: Allocator, cmd: []const u8, partial: []const u8, matches: []const []u8) Allocator.Error![]u8 {
    if (std.mem.eql(u8, cmd, "load") and std.mem.indexOfScalar(u8, partial, '/') == null) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        for (matches) |m| if (fileName(m)) |n| try names.append(gpa, n);
        return longestCommonPrefix(gpa, names.items);
    }
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    for (matches) |m| try all.append(gpa, m);
    return longestCommonPrefix(gpa, all.items);
}

// ── Free functions: descriptions and misc ─────────────────────────────────────

pub fn describeFx(gpa: Allocator, s: FxSettings) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (s.flanger_enabled) {
        try out.print(gpa, "flanger {f}Hz/{f}/{f}ms/{f}/{f}", .{ rfix(s.flanger_rate_hz, 2), rfix(s.flanger_depth, 2), rfix(s.flanger_delay_ms, 1), rfix(s.flanger_feedback, 2), rfix(s.flanger_mix, 2) });
    } else try out.appendSlice(gpa, "flanger off");
    if (s.chorus_enabled) {
        try out.print(gpa, " chorus {f}Hz/{f}/{f}ms/{f}", .{ rfix(s.chorus_rate_hz, 2), rfix(s.chorus_depth, 2), rfix(s.chorus_delay_ms, 1), rfix(s.chorus_mix, 2) });
    } else try out.appendSlice(gpa, " chorus off");
    if (s.reverb_enabled) {
        try out.print(gpa, " rev {f}/{f}", .{ rfix(s.reverb_mix, 2), rfix(s.reverb_decay, 2) });
    } else try out.appendSlice(gpa, " rev off");
    if (s.delay_enabled) {
        try out.print(gpa, " delay {f}s/{f}/{f}", .{ rfix(s.delay_time_secs, 2), rfix(s.delay_feedback, 2), rfix(s.delay_mix, 2) });
    } else try out.appendSlice(gpa, " delay off");
    return out.toOwnedSlice(gpa);
}

pub fn describeVcf(gpa: Allocator, v: VcfSettings) Allocator.Error![]u8 {
    if (!v.enabled) {
        if (v.target == .all) return gpa.dupe(u8, "vcf off");
        return std.fmt.allocPrint(gpa, "vcf {s} off", .{v.target.asStr()});
    }
    return std.fmt.allocPrint(gpa, "vcf {s} cut {f} Hz  res {f}  drive {f}  {s}", .{ v.target.asStr(), rfix(v.cutoff_hz, 1), rfix(v.resonance, 2), rfix(v.drive, 2), v.wave.asStr() });
}

fn resolveIdRefInPhrases(phrases: []const Phrase, id_ref: isize) ?usize {
    if (id_ref == command.START_REF) return if (phrases.len > 0) phrases[0].id else null;
    if (id_ref >= 0) return @intCast(id_ref);
    const back: usize = @abs(id_ref);
    if (back == 0 or back > phrases.len) return null;
    return phrases[phrases.len - back].id;
}

/// Rust `str::parse::<isize>` (optional sign, decimal digits).
fn parseIsize(s: []const u8) ?isize {
    if (s.len == 0) return null;
    return std.fmt.parseInt(isize, s, 10) catch null;
}

fn charCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += charLenAt(s, i);
    return n;
}

fn charLenAt(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    return if (i + n > s.len) 1 else n;
}

fn byteIndexOfChar(s: []const u8, char_index: usize) usize {
    var i: usize = 0;
    var c: usize = 0;
    while (i < s.len and c < char_index) : (c += 1) i += charLenAt(s, i);
    return @min(i, s.len);
}

fn strLess(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn freeList(gpa: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

fn freeStrList(gpa: Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// The Rust std::io::Error text of the common file errors.
fn ioErrText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
        error.IsDir => "Is a directory (os error 21)",
        error.NotDir => "Not a directory (os error 20)",
        error.NoSpaceLeft => "No space left on device (os error 28)",
        error.ReadOnlyFileSystem => "Read-only file system (os error 30)",
        error.PathAlreadyExists => "File exists (os error 17)",
        error.NameTooLong => "File name too long (os error 36)",
        error.FileTooBig, error.StreamTooLong => "File too large (os error 27)",
        else => @errorName(err),
    };
}

/// A float written like Rust's `{:.N}`: correctly rounded with ties to even (Zig's `{d:.N}`
/// rounds an exact tie such as 1.25 up; Rust writes "1.2"). Use as `{f}` with `rfix(v, n)`.
pub const RustFixed = struct {
    v: f64,
    prec: u8,

    pub fn format(self: RustFixed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const v = self.v;
        if (std.math.isFinite(v) and self.prec <= 15) {
            const scale = std.math.pow(f64, 10, @floatFromInt(self.prec));
            const a = @abs(v);
            const p = a * scale;
            // An exact tie: the product is exact and its fraction is one half.
            if (p < 9007199254740992.0 and @mulAdd(f64, a, scale, -p) == 0 and p - @floor(p) == 0.5) {
                const k: u64 = @intFromFloat(@floor(p));
                const rounded = if (k % 2 == 0) k else k + 1;
                const unit: u64 = @intFromFloat(scale);
                if (std.math.signbit(v)) try w.writeByte('-');
                try w.print("{d}", .{rounded / unit});
                if (self.prec > 0) {
                    var buf: [16]u8 = undefined;
                    const frac = std.fmt.bufPrint(&buf, "{d}", .{rounded % unit}) catch unreachable;
                    try w.writeByte('.');
                    try w.splatByteAll('0', self.prec - frac.len);
                    try w.writeAll(frac);
                }
                return;
            }
        }
        try w.printFloat(v, .{ .mode = .decimal, .precision = self.prec });
    }
};

pub fn rfix(v: anytype, prec: u8) RustFixed {
    return .{ .v = switch (@typeInfo(@TypeOf(v))) {
        .comptime_float, .comptime_int => v,
        .float => @floatCast(v),
        .int => @floatFromInt(v),
        else => @compileError("rfix needs a number"),
    }, .prec = prec };
}

fn qenc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return net.queryEncode(gpa, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // a 3-byte buffer always holds "%XX"
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const util = @import("util.zig");
const AudioTag = std.meta.Tag(AudioCmd);

/// An App with fake audio (a consumer thread recording what was sent), an offline network, a
/// fake recorder, and a scratch directory as its cwd.
const Rig = struct {
    gpa: Allocator,
    cmds: *CmdRing,
    garbage: *GarbageRing,
    shared: *Shared,
    log: *EventLog,
    env: *std.process.Environ.Map,
    tmp: testing.TmpDir,
    app: *App,
    consumer: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    processed: std.atomic.Value(usize) = .init(0),
    lock: util.SpinLock = .{},
    tags: std.ArrayList(AudioTag) = .empty,
    vols: std.ArrayList(f32) = .empty,

    const Options = struct {
        http: Http = Http.offline,
        record_fn: RecordFn = fakeRecordOk,
        with_log: bool = false,
        env: []const [2][]const u8 = &.{},
        files: []const [2][]const u8 = &.{},
    };

    fn init(opts: Options) !*Rig {
        const gpa = testing.allocator;
        const r = try gpa.create(Rig);
        errdefer gpa.destroy(r);
        r.* = undefined;
        r.gpa = gpa;
        r.stop = .init(false);
        r.processed = .init(0);
        r.lock = .{};
        r.tags = .empty;
        r.vols = .empty;
        r.tmp = testing.tmpDir(.{});
        r.cmds = try gpa.create(CmdRing);
        r.cmds.* = .{};
        r.garbage = try gpa.create(GarbageRing);
        r.garbage.* = .{};
        r.shared = try gpa.create(Shared);
        r.shared.* = .{};
        r.log = try gpa.create(EventLog);
        r.log.* = .{ .io = testing.io };
        if (opts.with_log) {
            const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/events.jsonl", .{r.tmp.sub_path});
            defer gpa.free(path);
            r.log.* = try EventLog.open(testing.io, path);
            r.log.fake_clock = 0;
        }
        r.env = try gpa.create(std.process.Environ.Map);
        r.env.* = .init(gpa);
        for (opts.env) |kv| try r.env.put(kv[0], kv[1]);
        for (opts.files) |f| {
            if (std.fs.path.dirname(f[0])) |d| try r.tmp.dir.createDirPath(testing.io, d);
            try r.tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
        }
        r.consumer = try std.Thread.spawn(.{}, consume, .{r});
        r.app = try App.init(gpa, testing.io, .{
            .cmds = r.cmds,
            .garbage = r.garbage,
            .shared = r.shared,
            .log = r.log,
            .env = r.env,
            .record_fn = opts.record_fn,
            .http = opts.http,
            .cwd = r.tmp.dir,
        });
        return r;
    }

    fn consume(r: *Rig) void {
        while (true) {
            if (r.cmds.tryRecv()) |c| {
                r.lock.lock();
                r.tags.append(r.gpa, c) catch {};
                if (c == .set_vol) r.vols.append(r.gpa, c.set_vol) catch {};
                r.lock.unlock();
                c.deinit(r.gpa);
                _ = r.processed.fetchAdd(1, .release);
                continue;
            }
            if (r.stop.load(.acquire)) return;
            std.Thread.yield() catch {};
        }
    }

    /// Waits until the consumer has handled everything sent so far.
    fn sync(r: *Rig) void {
        while (r.processed.load(.acquire) != r.cmds.tail.load(.acquire)) std.Thread.yield() catch {};
    }

    fn sent(r: *Rig, tag: AudioTag) bool {
        r.sync();
        r.lock.lock();
        defer r.lock.unlock();
        for (r.tags.items) |t| if (t == tag) return true;
        return false;
    }

    fn clearSent(r: *Rig) void {
        r.sync();
        r.lock.lock();
        defer r.lock.unlock();
        r.tags.clearRetainingCapacity();
        r.vols.clearRetainingCapacity();
    }

    fn deinit(r: *Rig) void {
        const gpa = r.gpa;
        r.app.deinit();
        r.sync();
        r.stop.store(true, .release);
        r.consumer.join();
        r.tags.deinit(gpa);
        r.vols.deinit(gpa);
        r.log.close();
        gpa.destroy(r.log);
        r.env.deinit();
        gpa.destroy(r.env);
        gpa.destroy(r.shared);
        gpa.destroy(r.garbage);
        gpa.destroy(r.cmds);
        r.tmp.cleanup();
        gpa.destroy(r);
    }

    fn cmd(r: *Rig, line: []const u8) !void {
        try r.app.handleCommand(line);
    }

    fn msg(r: *Rig) []const u8 {
        return r.app.message orelse "";
    }

    fn read(r: *Rig, path: []const u8) ![]u8 {
        return r.tmp.dir.readFileAlloc(testing.io, path, r.gpa, .limited(1 << 20));
    }

    fn input(r: *Rig, text: []const u8) !void {
        try r.app.setInput(text);
    }

    fn src(r: *Rig, i: usize) []const u8 {
        return r.app.phrases.items[i].src;
    }

    fn last(r: *Rig) *const Phrase {
        return &r.app.phrases.items[r.app.phrases.items.len - 1];
    }

    fn ids(r: *Rig, buf: []usize) []usize {
        for (r.app.phrases.items, 0..) |p, i| buf[i] = p.id;
        return buf[0..r.app.phrases.items.len];
    }

    fn loadV3(r: *Rig, lines: []const u8) !void {
        const text = try std.fmt.allocPrint(r.gpa, "MAQAM_SESSION_V3\n{s}", .{lines});
        defer r.gpa.free(text);
        if (try r.app.loadSessionText(text, .{})) |e| {
            defer r.gpa.free(e);
            std.debug.print("load failed: {s}\n", .{e});
            return error.LoadFailed;
        }
    }
};

fn fakeRecordOk(gpa: Allocator, _: std.Io, _: *Shared, _: []const Phrase, _: f64, _: f64, _: VcfBank, _: FxSettings, _: usize) RecordResult {
    return .{ .ok = gpa.dupe(u8, "maqam-test.mp4") catch @panic("oom") };
}

fn fakeRecordErr(gpa: Allocator, _: std.Io, _: *Shared, _: []const Phrase, _: f64, _: f64, _: VcfBank, _: FxSettings, _: usize) RecordResult {
    return .{ .err = gpa.dupe(u8, "generated source background failed") catch @panic("oom") };
}

/// Waits for a worker result to arrive and be handled by tick (bounded).
fn tickUntil(r: *Rig, comptime done: fn (*App) bool) !void {
    var n: usize = 0;
    while (!done(r.app)) : (n += 1) {
        if (n > 20000) return error.Timeout;
        try r.app.tick();
        std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch {};
    }
}

fn expectMsg(r: *Rig, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, r.msg());
}

fn expectMsgContains(r: *Rig, needle: []const u8) !void {
    if (std.mem.indexOf(u8, r.msg(), needle) == null) {
        std.debug.print("message `{s}` lacks `{s}`\n", .{ r.msg(), needle });
        return error.TestExpectedContains;
    }
}

fn parseOk(line: []const u8) !Cmd {
    return switch (try command.parse(testing.allocator, line)) {
        .ok => |c| c,
        .err => |e| {
            testing.allocator.free(e);
            return error.ParseFailed;
        },
    };
}

test "parses direct nam search, pin and tone3000 commands" {
    const a = try parseOk("nam search clean dynamic A2 amp cab");
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("clean dynamic A2 amp cab", a.set_nam.search.query);
    const b = try parseOk("nam pin https://models.example/clean.nam as clean");
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("https://models.example/clean.nam", b.set_nam.pin.url);
    try testing.expectEqualStrings("clean", b.set_nam.pin.name);
    const c = try parseOk("nam tone3000 45896 as nama2");
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 45896), c.set_nam.tone3000.tone_id);
    try testing.expectEqualStrings("nama2", c.set_nam.tone3000.name);
}

test "parses tone3000 login commands and jump addresses" {
    const gpa = testing.allocator;
    const login = try parseOk("nam login");
    defer login.deinit(gpa);
    try testing.expect(login.set_nam == .login);
    const logout = try parseOk("nam logout");
    defer logout.deinit(gpa);
    try testing.expect(logout.set_nam == .logout);
    const input = try parseOk("nam input right");
    defer input.deinit(gpa);
    try testing.expectEqual(NamInput.right, input.set_nam.input);
    const lat = try parseOk("nam latency left");
    defer lat.deinit(gpa);
    try testing.expectEqual(NamInput.left, lat.set_nam.latency);
    const ins = try parseOk("i 6 nam gain 4");
    defer ins.deinit(gpa);
    try testing.expectEqual(@as(isize, 6), ins.insert_nam.before);
    try testing.expectEqual(@as(f32, 4.0), ins.insert_nam.command.gain);
    const ed = try parseOk("edit 2 nam input stereo");
    defer ed.deinit(gpa);
    try testing.expectEqual(@as(isize, 2), ed.edit_nam.id);
    try testing.expectEqual(NamInput.stereo, ed.edit_nam.command.input);
    const j = try parseOk("j 14 else 4 3");
    defer j.deinit(gpa);
    try testing.expectEqual(@as(isize, 14), j.jump.to);
    try testing.expectEqual(@as(?isize, 4), j.jump.fail_to);
    try testing.expectEqual(@as(usize, 3), j.jump.times);
    const always = try parseOk("j 4 always");
    defer always.deinit(gpa);
    try testing.expectEqual(@as(?isize, null), always.jump.fail_to);
    try testing.expectEqual(@as(usize, 0), always.jump.times);
}

test "pinning nam rewrites ambiguous session dependency" {
    const r = try Rig.init(.{ .files = &.{.{ "pin.mq", "MAQAM_SESSION_V3\nnam slot\nP|0|1|d bayati 4\n" }} });
    defer r.deinit();
    try testing.expectEqual(@as(?[]u8, null), try r.app.pinNamReference("pin.mq", "slot", "nam pin https://models.example/clean.nam as slot"));
    const got = try r.read("pin.mq");
    defer r.gpa.free(got);
    try testing.expectEqualStrings("MAQAM_SESSION_V3\nnam pin https://models.example/clean.nam as slot\nP|0|1|d bayati 4\n", got);
}

test "phrase display source preserves the users text" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d nah 332,   a hij 44 r3");
    try testing.expectEqualStrings("d nah 332,   a hij 44 r3", r.src(0));
    try testing.expectEqual(@as(usize, 3), r.app.phrases.items[0].repeat);
}

test "western mode names parse as builtin jins" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d major 332");
    try r.cmd("e dorian 332");
    try r.cmd("f locrian 332");
    try r.cmd("g diminished 332");
    const ps = r.app.phrases.items;
    try testing.expectEqualStrings("Major", ps[0].bar.maqam_names[0]);
    try testing.expectEqualStrings("1/1 9/8 5/4 4/3 3/2 5/3 15/8", ps[0].bar.ratio_strs[0]);
    try testing.expectEqualStrings("Dorian", ps[1].bar.maqam_names[0]);
    try testing.expectEqualStrings("Locrian", ps[2].bar.maqam_names[0]);
    try testing.expectEqualStrings("1/1 16/15 6/5 4/3 64/45 8/5 9/5", ps[2].bar.ratio_strs[0]);
    try testing.expectEqualStrings("Diminished", ps[3].bar.maqam_names[0]);
    try testing.expectEqualStrings("1/1 9/8 6/5 4/3 64/45 8/5 5/3 15/8", ps[3].bar.ratio_strs[0]);
}

test "inserts sym drive as a timeline control" {
    const r = try Rig.init(.{});
    defer r.deinit();
    for (0..5) |_| try r.cmd("d bayati 4");
    try r.cmd("i 4 sym drive 64");
    try testing.expectEqual(@as(usize, 5), r.app.phrases.items[4].id);
    try testing.expectEqualStrings("sym drive 64", r.src(4));
    try testing.expectEqual(@as(f32, 64), r.app.phrases.items[4].control.?.set_sympathetic_gain);
    try testing.expectEqual(@as(usize, 4), r.app.phrases.items[5].id);

    try r.cmd("edit 5 sym gain 96");
    try testing.expectEqual(@as(usize, 5), r.app.phrases.items[4].id);
    try testing.expectEqualStrings("sym gain 96", r.src(4));
    try testing.expectEqual(@as(f32, 96), r.app.phrases.items[4].control.?.set_sympathetic_gain);

    try r.cmd("edit 5 sym decay 0.999 drive 2 kanun 0.5 bass 0.5");
    try testing.expectEqualStrings("sym decay 0.999 drive 2 kanun 0.5 bass 0.5", r.src(4));
    var ch = r.app.phrases.items[4].control.?.set_sympathetic;
    try testing.expectEqual(@as(?command.SympatheticTarget, null), ch.target);
    try testing.expectEqual(@as(?bool, null), ch.enabled);
    try testing.expectEqual(@as(?f32, 0.999), ch.decay);
    try testing.expectEqual(@as(?f32, 2.0), ch.gain);
    try testing.expectEqual(@as(?f64, null), ch.interval_ratio);
    try testing.expectEqual(@as(?f32, null), ch.amount);
    try testing.expectEqual(@as(?f32, null), ch.mic);
    try testing.expectEqual(@as(?f32, 0.5), ch.kanun);
    try testing.expectEqual(@as(?f32, 0.5), ch.bass);
    try testing.expectEqual(@as(?f32, null), ch.drums);

    try r.cmd("edit 5 sym mic decay 0.9999 drive 8 amount 1.5");
    try testing.expectEqualStrings("sym mic decay 0.9999 drive 8 amount 1.5", r.src(4));
    ch = r.app.phrases.items[4].control.?.set_sympathetic;
    try testing.expectEqual(@as(?command.SympatheticTarget, .mic), ch.target);
    try testing.expectEqual(@as(?f32, 0.9999), ch.decay);
    try testing.expectEqual(@as(?f32, 8.0), ch.gain);
    try testing.expectEqual(@as(?f32, 1.5), ch.amount);
    try testing.expectEqual(@as(?f32, null), ch.kanun);

    try r.cmd("edit 5 sym up fifth");
    try testing.expectEqualStrings("sym up fifth", r.src(4));
    try testing.expectEqual(@as(?f64, 3.0 / 2.0), r.app.phrases.items[4].control.?.set_sympathetic.interval_ratio);

    try r.cmd("edit 5 sym harmony root 0.50 third 0.25 fifth 0.25");
    try testing.expectEqualStrings("sym harmony root 0.50 third 0.25 fifth 0.25", r.src(4));
    const harmony = r.app.phrases.items[4].control.?.set_sympathetic.harmony.?;
    const comps = harmony.items();
    try testing.expectEqual(@as(usize, 3), comps.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), comps[0].ratio, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.5), comps[0].weight, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 6.0 / 5.0), comps[1].ratio, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.25), comps[1].weight, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 2.0), comps[2].ratio, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.25), comps[2].weight, 1e-6);
}

test "nam cache names are shell friendly and never escape the cache" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Metallica A2", "Metallica-A2" },
        .{ "../bad name!!", "bad-name" },
        .{ "../../etc/passwd", "etcpasswd" },
        .{ "/abs/path", "abspath" },
        .{ "..", "" },
        .{ "a\x00b", "ab" },
        .{ "a\\b", "ab" },
    };
    for (cases) |c| {
        const s = try sanitizeNamCacheName(gpa, c[0]);
        defer gpa.free(s);
        try testing.expectEqualStrings(c[1], s);
        try testing.expect(std.mem.indexOfScalar(u8, s, '/') == null);
    }
    const p = try namCacheNameFromPath(gpa, "mesa dual rect.nam");
    defer gpa.free(p);
    try testing.expectEqualStrings("mesa-dual-rect", p);
    const url1 = try namCacheNameFromUrl(gpa, "https://example.test/models/NAM%20A2.nam?download=1");
    defer gpa.free(url1);
    try testing.expectEqualStrings("NAM20A2", url1);
    const url2 = try namCacheNameFromUrl(gpa, "https://example.test/models/");
    defer gpa.free(url2);
    try testing.expectEqualStrings("models", url2);
    const url3 = try namCacheNameFromUrl(gpa, "https://example.test/..%2F..%2Fescape.nam");
    defer gpa.free(url3);
    try testing.expect(std.mem.indexOf(u8, url3, "/") == null);
    try testing.expect(!isSafeCacheName(""));
    try testing.expect(!isSafeCacheName(".."));
    try testing.expect(!isSafeCacheName("a/b"));
    try testing.expect(isSafeCacheName("clean"));
}

test "a tone3000 name from a session is sanitized before it reaches the cache" {
    const r = try Rig.init(.{ .env = &.{.{ "TONE3000_ACCESS_TOKEN", "tok" }} });
    defer r.deinit();
    try r.cmd("nam tone3000 7 as ../../outside");
    // offline: the download fails, but the job only ever names a plain file in .nam
    try testing.expect(std.mem.indexOf(u8, r.msg(), "→ outside") != null);
    try tickUntil(r, struct {
        fn f(a: *App) bool {
            return a.nam_download == null;
        }
    }.f);
    try testing.expect(r.app.msgIsError());
    try testing.expectError(error.FileNotFound, r.tmp.parent_dir.statFile(testing.io, "outside.nam", .{}));
}

test "listing nam cache creates missing cache dir" {
    const r = try Rig.init(.{ .env = &.{.{ "MAQAM_NAM_CACHE_DIR", "cache-test" }} });
    defer r.deinit();
    var names = try r.app.listCachedNamModels(r.app.namCacheDir());
    defer names.deinit(r.gpa);
    try testing.expectEqual(@as(usize, 0), names.ok.len);
    const st = try r.tmp.dir.statFile(testing.io, "cache-test", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, st.kind);
    try r.cmd("nam ls");
    try expectMsg(r, "no NAM captures found; cache-test is ready. Run `nam import URL as name` to download into it, or `nam import FILENAME.nam as name` to cache a local file");
}

test "missing nam live state does not block session load" {
    const r = try Rig.init(.{ .env = &.{.{ "MAQAM_NAM_CACHE_DIR", "empty-cache" }} });
    defer r.deinit();
    try r.loadV3("nam practice\nP|0|1|d bayati 4444\n");
    try testing.expectEqual(@as(usize, 1), r.app.live_nam_commands.items.len);
    try testing.expectEqualStrings("nam practice", r.app.live_nam_commands.items[0]);
    try testing.expectEqual(@as(usize, 2), r.app.phrases.items.len);
    try testing.expectEqualStrings("nam practice", r.src(0));
    try testing.expectEqual(true, r.app.phrases.items[0].control.?.set_nam_enabled);
    try testing.expectEqualStrings("d bayati 4444", r.src(1));
    try testing.expectEqualStrings("practice", r.app.pending_nam_slot.?);
    try expectMsg(r, "This score needs a NAM model for “practice”. What amp or tone should it use?");
}

test "loads and saves v3 without rewriting input" {
    const source = "MAQAM_SESSION_V3\ncreate testv3 1/1 9/8 5/4\nvol 0.75\nB|4|180\nS|7|1.2\nY|8|sym on\nY|9|sym gain 64\nY|10|sym decay 0.99\nP|11|2|g testv3 332\nJ|15|11|3\n";
    const r = try Rig.init(.{ .files = &.{.{ "in.mq", source }} });
    defer r.deinit();
    r.app.vol = 0.42;
    try r.cmd("load in.mq");
    try expectMsg(r, "loaded session ← in.mq");
    try testing.expectEqual(@as(f32, 0.42), r.app.vol);
    const again = try r.read("in.mq");
    defer r.gpa.free(again);
    try testing.expectEqualStrings(source, again);
    var buf: [16]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 4, 7, 8, 9, 10, 11, 15 }, r.ids(&buf));
    const ps = r.app.phrases.items;
    try testing.expectEqual(true, ps[2].control.?.set_sympathetics);
    try testing.expectEqual(@as(f32, 64), ps[3].control.?.set_sympathetic_gain);
    try testing.expectEqual(@as(f32, 0.99), ps[4].control.?.set_sympathetic_decay);
    try testing.expectEqual(@as(usize, 2), ps[5].repeat);
    try testing.expectEqual(@as(usize, 11), ps[6].jump.?.target_id);
    try testing.expectEqual(@as(usize, 16), r.app.next_phrase_id);

    try r.cmd("save out.mq");
    try expectMsg(r, "saved session → out.mq");
    const saved = try r.read("out.mq");
    defer r.gpa.free(saved);
    try testing.expect(std.mem.startsWith(u8, saved, "MAQAM_SESSION_V3\n"));
    try testing.expect(std.mem.indexOf(u8, saved, "\nvol ") == null);
    try testing.expect(std.mem.indexOf(u8, saved, "tuneto") == null);
    for ([_][]const u8{ "B|4|180\n", "Y|8|sym on\n", "Y|9|sym gain 64\n", "Y|10|sym decay 0.99\n", "P|11|2|g testv3 332\n" }) |line|
        try testing.expect(std.mem.indexOf(u8, saved, line) != null);
    // save with no path reuses the session path
    try r.cmd("save");
    try expectMsg(r, "saved session → out.mq");
    try r.cmd("load missing.mq");
    try expectMsg(r, "✗ load failed: No such file or directory (os error 2)");
}

test "tuneto is live state and not saved in sessions" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("tuneto a");
    try expectMsg(r, "tuneto a → standard MIDI a");
    try testing.expectEqual(@as(usize, 0), r.app.phrases.items.len);
    try r.cmd("a major 44");
    try testing.expectApproxEqAbs(@as(f64, 440.0), r.app.phrases.items[0].bar.root_hz, 0.0001);
    try r.cmd("save out.mq");
    const saved = try r.read("out.mq");
    defer r.gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "tuneto") == null);
    try testing.expect(std.mem.indexOf(u8, saved, "P|0|1|a major 44\n") != null);
}

test "globals are written immediately when live settings change" {
    const r = try Rig.init(.{ .env = &.{.{ "MAQAM_GLOBALS_PATH", "g.ml" }} });
    defer r.deinit();
    try r.cmd("vol 0.7");
    try expectMsg(r, "vol → 0.70");
    const a = try r.read("g.ml");
    defer r.gpa.free(a);
    try testing.expectEqualStrings("vol 0.7\ntuneto d\n", a);
    try r.cmd("tuneto a");
    const b = try r.read("g.ml");
    defer r.gpa.free(b);
    try testing.expectEqualStrings("vol 0.7\ntuneto a\n", b);
    try testing.expectApproxEqAbs(@as(f64, 440.0), tuning.pitchToHz('a', 0, 4), 0.0001);
}

test "globals load on startup" {
    const r = try Rig.init(.{ .files = &.{.{ ".globals.ml", "vol 0.25\ntuneto a\n" }} });
    defer r.deinit();
    try testing.expectEqual(@as(f32, 0.25), r.app.vol);
    var buf: [3]u8 = undefined;
    try testing.expectEqualStrings("a", r.app.tune_to.sourceTokenBuf(&buf));
    r.sync();
    try testing.expect(r.tags.items[0] == .set_vol);
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.vols.items[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 440.0), tuning.pitchToHz('a', 0, 4), 0.0001);
}

test "bad globals lines are reported" {
    const r = try Rig.init(.{ .files = &.{.{ ".globals.ml", "vol 0.5\nbpm 90\n" }} });
    defer r.deinit();
    try expectMsg(r, "✗ .globals.ml line 2: globals only support vol and tuneto; remove this line or change it to vol <n> or tuneto <pitch>");
}

test "loads legacy and vcf control lines under v3 header" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.loadV3("bpm 180\ns 1.2\nP|2|1|g hijaz 4444\n");
    var buf: [16]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, r.ids(&buf));
    try testing.expectEqual(@as(f64, 180), r.app.bpm);
    try testing.expectEqual(@as(f64, 1.2), r.app.sustain);

    try r.loadV3("vcf bass cut=900 res=0.65 drive=3.5\ncut +100\nV|5|kanun|1200|0.4|2.25\nP|6|1|g hijaz 4444\n");
    try testing.expectEqualSlices(usize, &.{ 0, 1, 5, 6 }, r.ids(&buf));
    try testing.expectEqual(@as(f32, 1200), r.app.vcf.kanun.cutoff_hz);
    try testing.expectEqual(@as(f32, 0.4), r.app.vcf.kanun.resonance);
    try testing.expectEqual(@as(f32, 2.25), r.app.vcf.kanun.drive);
    try testing.expectEqual(VcfTarget.kanun, r.app.vcf.kanun.target);
}

fn expectAllVcfOff(b: VcfBank) !void {
    for ([_]VcfSettings{ b.all, b.mic, b.bass, b.kanun, b.kick, b.tanbura }) |s| try testing.expect(!s.enabled);
}

test "vcf off is a transparent control command" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("vcf");
    try testing.expect(r.app.vcf.all.enabled);
    try testing.expectEqual(VcfTarget.all, r.app.vcf.all.target);
    try testing.expectEqualStrings("vcf", r.last().src);
    try r.cmd("vcf off");
    try expectAllVcfOff(r.app.vcf);
    try testing.expectEqual(VcfTarget.all, r.app.vcf.focus);
    try r.cmd("vcf bass off");
    try expectAllVcfOff(r.app.vcf);
    try testing.expectEqual(VcfTarget.bass, r.app.vcf.focus);
    try r.cmd("vcf bass 900 0.65 3.5");
    try testing.expect(r.app.vcf.bass.enabled);
    try testing.expectEqual(VcfTarget.bass, r.app.vcf.bass.target);
}

test "vcf wave is named" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const v = &r.app.vcf;
    try r.cmd("vcf bass 900 0.65 3.5 wave=saw");
    try testing.expect(v.bass.enabled);
    try testing.expectEqual(VcfTarget.bass, v.bass.target);
    try testing.expectEqual(@as(f32, 900), v.bass.cutoff_hz);
    try testing.expectEqual(@as(f32, 0.65), v.bass.resonance);
    try testing.expectEqual(@as(f32, 3.5), v.bass.drive);
    try testing.expectEqual(vcf.VcoWave.saw, v.bass.wave);
    try r.cmd("vcf kanun cut=2400 res=0.35 drive=2.0 wave=tri");
    try testing.expect(v.bass.enabled and v.kanun.enabled and !v.all.enabled);
    try testing.expectEqual(VcfTarget.kanun, v.kanun.target);
    try testing.expectEqual(vcf.VcoWave.tri, v.kanun.wave);
    try r.cmd("vcf drums cut=700 res=0.25 drive=2.5 wave=squ");
    try testing.expect(v.bass.enabled and v.kanun.enabled and v.kick.enabled);
    try testing.expectEqual(VcfTarget.kick, v.kick.target);
    try testing.expectEqual(vcf.VcoWave.squ, v.kick.wave);
    try testing.expectEqualStrings("vcf drums cut 700 res 0.25 drive 2.5 wave squ", r.last().src);
    try r.cmd("vcf mic cut=1800 res=0.2 drive=1.2 wave=sin");
    try testing.expect(v.mic.enabled);
    try testing.expectEqual(VcfTarget.mic, v.mic.target);
    try testing.expectEqual(@as(f32, 1800), v.mic.cutoff_hz);
    try testing.expectEqual(vcf.VcoWave.mic, v.mic.wave);
    try r.cmd("vcf mic cut 1200 res 0.6 drive 2 wave mic");
    try testing.expectEqual(@as(f32, 1200), v.mic.cutoff_hz);
    try testing.expectEqual(@as(f32, 0.6), v.mic.resonance);
    try testing.expectEqual(@as(f32, 2), v.mic.drive);
    try testing.expectEqual(vcf.VcoWave.mic, v.mic.wave);
    try testing.expectEqualStrings("vcf mic cut 1200 res 0.6 drive 2", r.last().src);
    try r.cmd("vcf sym cut=1800 res=0.7 drive=1.5");
    try testing.expect(v.tanbura.enabled);
    try testing.expectEqual(VcfTarget.tanbura, v.tanbura.target);
    try testing.expectEqual(@as(f32, 1800), v.tanbura.cutoff_hz);
    try testing.expectEqualStrings("vcf sym cut 1800 res 0.7 drive 1.5", r.last().src);
    try r.cmd("vcf bass off");
    try testing.expect(!v.bass.enabled and v.kanun.enabled and v.kick.enabled);
    try testing.expectEqual(VcfTarget.bass, v.focus);
    try r.cmd("vcf all 1200 0.35 1.5 wave=saw");
    try testing.expect(v.all.enabled);
    try testing.expectEqual(vcf.VcoWave.sin, v.all.wave);
    try testing.expect(!v.mic.enabled and !v.bass.enabled and !v.kanun.enabled and !v.kick.enabled and !v.tanbura.enabled);
    try testing.expectEqualStrings("vcf all cut 1200 res 0.35 drive 1.5", r.last().src);
    try r.cmd("vcf all off");
    try expectAllVcfOff(r.app.vcf);
    try testing.expectEqual(VcfTarget.all, v.focus);
}

test "vcf relative and tick changes are preserved" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("vcf bass 900 0.65 3.5 wave=saw");
    try r.cmd("vcf bass cut -100");
    try testing.expectEqual(@as(f32, 800), r.app.vcf.bass.cutoff_hz);
    try testing.expectEqualStrings("vcf bass cut -100", r.last().src);
    try r.cmd("vcf bass cut=+2t");
    try testing.expectEqual(@as(f32, 2), r.app.vcf.bass.cutoff_step_per_tick);
    try testing.expectEqualStrings("vcf bass cut +2t", r.last().src);
    try r.cmd("vcf bass cut=+0");
    try testing.expectEqual(@as(f32, 0), r.app.vcf.bass.cutoff_step_per_tick);
    try testing.expectEqual(@as(f32, 800), r.app.vcf.bass.cutoff_hz);
}

test "fx commands use vcf style parameter rules" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const f = &r.app.fx;
    try r.cmd("reverb mix=0.25 decay=0.7");
    try testing.expect(f.reverb_enabled);
    try testing.expectEqual(@as(f32, 0.25), f.reverb_mix);
    try testing.expectEqual(@as(f32, 0.7), f.reverb_decay);
    try r.cmd("pingpong time=0.33 feedback=0.45 mix=0.2");
    try testing.expect(f.delay_enabled);
    try testing.expectEqual(@as(f32, 0.33), f.delay_time_secs);
    try testing.expectEqual(@as(f32, 0.45), f.delay_feedback);
    try testing.expectEqual(@as(f32, 0.2), f.delay_mix);
    try r.cmd("flanger rate=0.18 depth=0.8 delay=2.5 feedback=0.55 mix=0.35");
    try testing.expect(f.flanger_enabled);
    try testing.expectEqual(@as(f32, 0.18), f.flanger_rate_hz);
    try testing.expectEqual(@as(f32, 0.8), f.flanger_depth);
    try testing.expectEqual(@as(f32, 2.5), f.flanger_delay_ms);
    try testing.expectEqual(@as(f32, 0.55), f.flanger_feedback);
    try testing.expectEqual(@as(f32, 0.35), f.flanger_mix);
    try r.cmd("chorus rate=0.7 depth=0.55 delay=18 mix=0.32");
    try testing.expect(f.chorus_enabled);
    try testing.expectEqual(@as(f32, 0.7), f.chorus_rate_hz);
    try testing.expectEqual(@as(f32, 0.55), f.chorus_depth);
    try testing.expectEqual(@as(f32, 18), f.chorus_delay_ms);
    try testing.expectEqual(@as(f32, 0.32), f.chorus_mix);
    try r.cmd("flange feedback=-0.1t");
    try testing.expectEqual(@as(f32, -0.1), f.flanger_feedback_step_per_tick);
    try testing.expectEqualStrings("flanger feedback -0.1t", r.last().src);
    try r.cmd("delay mix=+0.1");
    try testing.expectEqual(@as(f32, 0.3), f.delay_mix);
    try testing.expectEqualStrings("delay mix +0.1", r.last().src);
    try r.cmd("delay feedback=+0.01t");
    try testing.expectEqual(@as(f32, 0.01), f.delay_feedback_step_per_tick);
    try testing.expectEqualStrings("delay feedback +0.01t", r.last().src);
    try r.cmd("fx off");
    try testing.expect(!f.flanger_enabled and !f.chorus_enabled and !f.reverb_enabled and !f.delay_enabled);
}

test "jump times one is noop and not added" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 4444");
    try r.cmd("j 0 1");
    try testing.expectEqual(@as(usize, 1), r.app.phrases.items.len);
    try expectMsg(r, "✗ jump ×1 is a no-op; use j <id> 2 or omit the jump");
    try r.cmd("j 9 2");
    try expectMsg(r, "✗ no phrase id 9");
    try r.cmd("j 0 else 9 2");
    try expectMsg(r, "✗ no failure phrase id 9");
    try r.cmd("j 0 3");
    try testing.expectEqual(@as(usize, 2), r.app.phrases.items.len);
    try testing.expectEqual(@as(usize, 0), r.last().jump.?.target_id);
}

test "load tab completion lists and completes mq files" {
    const hdr = "MAQAM_SESSION_V3\n";
    const r = try Rig.init(.{ .files = &.{ .{ "alpha.mq", hdr }, .{ "alpine.mq", hdr }, .{ "sets/alphaDeep.mq", hdr } } });
    defer r.deinit();
    try r.input("load al");
    try r.app.completeInput();
    try testing.expectEqualStrings("load alp", r.app.input.items);
    try expectMsg(r, "load: alpha.mq  alpine.mq  sets/alphaDeep.mq");
    try r.app.completeInput();
    try testing.expectEqualStrings("load alp", r.app.input.items);
    try expectMsg(r, "load: alpha.mq  alpine.mq  sets/alphaDeep.mq");
    try r.input("load alphaD");
    try r.app.completeInput();
    try testing.expectEqualStrings("load sets/alphaDeep.mq", r.app.input.items);
    try testing.expect(r.app.message == null);
    try r.input("save zz");
    try r.app.completeInput();
    try expectMsg(r, "✗ no .mq matches");
}

test "edit tab completion fills current timeline value" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 332 r3");
    try r.input("edit 0");
    try r.app.completeInput();
    try testing.expectEqualStrings("edit 0 d bayati 332 r3", r.app.input.items);
    try testing.expect(r.app.message == null);
    try r.cmd("vcf bass cut=900 res=0.65");
    try r.input("edit 1 ");
    try r.app.completeInput();
    try testing.expectEqualStrings("edit 1 vcf bass cut 900 res 0.65", r.app.input.items);
    try testing.expect(r.app.message == null);
}

test "command metadata drives parameter completion" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const cases = [_][2][]const u8{
        .{ "vcf", "vcf cut " },
        .{ "vcf mic ", "vcf mic cut " },
        .{ "vcf mic cut ", "vcf mic cut " },
        .{ "vcf bass wave s", "vcf bass wave sin " },
        .{ "i 4 vcf bass ", "i 4 vcf bass cut " },
        .{ "edit 4 sym mic ", "edit 4 sym mic decay " },
    };
    for (cases) |c| {
        try r.input(c[0]);
        try r.app.completeInput();
        try testing.expectEqualStrings(c[1], r.app.input.items);
        if (std.mem.eql(u8, c[0], "vcf mic cut ")) {
            try expectMsg(r, "vcf cut <10..22000 Hz|+n|-n|+nt>");
        } else if (std.mem.eql(u8, c[0], "vcf") or std.mem.eql(u8, c[0], "vcf bass wave s")) {
            try testing.expect(r.app.message == null);
        }
    }
}

test "llm missing key error tells user what to do" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("chatgpt: what is a jins?");
    try expectMsg(r, "✗ environment variable OPENAI_API_KEY needs to be set to talk to chatgpt");
    try r.cmd("claude: what is a jins?");
    try expectMsg(r, "✗ environment variable ANTHROPIC_API_KEY or CLAUDE_API_KEY needs to be set to talk to claude");
    try r.cmd("claude: add in sympathetics");
    try expectMsg(r, "✗ environment variable ANTHROPIC_API_KEY or CLAUDE_API_KEY needs to be set to ask claude to edit");
}

test "llm edit intent requires prefixed llm prompt" {
    try testing.expect(llmPromptIsEditRequest("let's do an e minor that does a d major hemiola turnaround"));
    try testing.expect(llmPromptIsEditRequest("add in sympathetics"));
    try testing.expect(llmPromptIsEditRequest("how do i get sympathetics?"));
    try testing.expect(!llmPromptIsEditRequest("can i have NAM A2?"));
    try testing.expect(llmPromptIsEditRequest("add NAM A2 on input"));
    try testing.expect(!llmPromptIsEditRequest("what are the valid values for sym decay?"));
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("let's do an e minor that does a d major hemiola turnaround");
    try testing.expect(std.mem.startsWith(u8, r.msg(), "✗ unknown pitch"));
}

fn extractFromJson(text: []const u8) ![][]u8 {
    const gpa = testing.allocator;
    var p = try std.json.parseFromSlice(Value, gpa, text, .{});
    defer p.deinit();
    var f: Failure = .{ .gpa = gpa };
    defer f.deinit();
    return extractToolCommands(&f, gpa, p.value) catch |e| {
        if (e == error.Fail) {
            const m = f.take(e);
            defer gpa.free(m);
            if (std.mem.indexOf(u8, m, "edit tool returned no commands") != null) return error.NoCommands;
        }
        return e;
    };
}

fn expectStrs(expected: []const []const u8, got: []const []u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "llm edit commands reject save and nam" {
    const commands = try extractFromJson("{\"commands\":[\"e minor 332\",\"save default.mq\"]}");
    defer freeStrList(testing.allocator, commands);
    try expectStrs(&.{ "e minor 332", "save default.mq" }, commands);
    const save = try parseOk("save default.mq");
    defer save.deinit(testing.allocator);
    try testing.expect(!llmEditCommandAllowed(save));
    const phrase = try parseOk("e minor 332");
    defer phrase.deinit(testing.allocator);
    try testing.expect(llmEditCommandAllowed(phrase));

    const r = try Rig.init(.{});
    defer r.deinit();
    try r.app.applyLlmEditCommands(commands);
    try testing.expectEqual(@as(usize, 0), r.app.phrases.items.len);
    try expectMsgContains(r, "cannot run save/load");

    const split = try extractFromJson("{\"commands\":[\"e minor 332; d major 332332; save default.mq\"]}");
    defer freeStrList(testing.allocator, split);
    try expectStrs(&.{ "e minor 332", "d major 332332", "save default.mq" }, split);

    try r.app.applyLlmEditCommands(&.{"nam load metallica"});
    try testing.expectEqual(@as(usize, 0), r.app.phrases.items.len);
    try expectMsgContains(r, "NAM is live input state");
    try expectMsgContains(r, "nam import FILENAME.nam as name");
}

test "llm edit tool arguments extract commands and split repeated sym nouns" {
    const a = try extractFromJson("{\"commands\":[\"e minor 4444\",\"d major 332332\"]}");
    defer freeStrList(testing.allocator, a);
    try expectStrs(&.{ "e minor 4444", "d major 332332" }, a);
    try testing.expectError(error.NoCommands, extractFromJson("{\"commands\":[]}"));
    const b = try extractFromJson("{\"commands\":[\"sym on sym decay 0.999 drive 2\"]}");
    defer freeStrList(testing.allocator, b);
    try expectStrs(&.{ "sym on", "sym decay 0.999 drive 2" }, b);
}

test "llm system prompt specifies command language" {
    const gpa = testing.allocator;
    const prompt = try llmSystemPrompt(gpa, "0: d bayati 4444\n1: vcf mic cut 1200 res 0.6");
    defer gpa.free(prompt);
    const reference = try command.languageReference(gpa);
    defer gpa.free(reference);
    const needles = [_][]const u8{
        "bpm 180",                                                             "never `set tempo 180`",
        "`<root> <jins> [rhythm]`",                                            "there is no time signature setting",
        "grouping rhythm chunks",                                              "for 7/8 use 43",
        "4433 is two 7/8 bars",                                                "16 bars in 7/8 is usually `<root> <jins> 43 r16`",
        "use r8",                                                              "use jumps only to restart a multi-row section",
        "do not use a jump where one phrase repeat like r16",                  "jump times count passes through the jump row",
        "for a restart after 16 bars",                                         "count 16 steps in time, not 16 phrase rows",
        "a jump with times 1 is a no-op",                                      "do not generate `j <id> 1`",
        "about a dozen timeline rows",                                         "sym gain <0..512>",
        "if the user says `add in sympathetics`, make the edit",               "sym decay 0.999 drive 2 kanun 0.5 bass 0.5",
        "practical edit values are usually 0.5..8",                            "values above 16 are extreme",
        "amount/source sends have hard range 0..512",                          "VCF",
        "Current score context:",                                              "0: d bayati 4444",
        "1: vcf mic cut 1200 res 0.6",                                         "LLM behavior:",
        "prior user prompts and prior assistant answers/tool-command results", "Never return save",
    };
    for (needles) |n| if (std.mem.indexOf(u8, prompt, n) == null) {
        std.debug.print("missing: {s}\n", .{n});
        return error.TestExpectedContains;
    };
    for ([_][]const u8{ "Nouns:", "filter cutoff frequency", "sympathetic resonator excitation drive" }) |n|
        try testing.expect(std.mem.indexOf(u8, reference, n) != null);
}

test "llm message payloads include history and current prompt" {
    const gpa = testing.allocator;
    var h0 = "what is sym?".*;
    var h1 = "sym controls sympathetics".*;
    const history = [_]LlmChatMessage{ .{ .role = .user, .content = &h0 }, .{ .role = .assistant, .content = &h1 } };
    var messages = try openaiMessages(gpa, &history, "how do i filter mic?", "0: d bayati 4444");
    defer freeList(gpa, &messages);
    const Msg = struct { role: []const u8, content: []const u8 };
    var m: [4]std.json.Parsed(Msg) = undefined;
    for (0..4) |i| m[i] = try std.json.parseFromSlice(Msg, gpa, messages.items[i], .{});
    defer for (m) |x| x.deinit();
    try testing.expectEqualStrings("system", m[0].value.role);
    try testing.expect(std.mem.indexOf(u8, m[0].value.content, "0: d bayati 4444") != null);
    try testing.expectEqualStrings("user", m[1].value.role);
    try testing.expectEqualStrings("what is sym?", m[1].value.content);
    try testing.expectEqualStrings("assistant", m[2].value.role);
    try testing.expectEqualStrings("how do i filter mic?", m[3].value.content);
    var anthropic = try anthropicMessages(gpa, &history, "next question");
    defer freeList(gpa, &anthropic);
    try testing.expectEqual(@as(usize, 3), anthropic.items.len);
    const last = try std.json.parseFromSlice(Msg, gpa, anthropic.items[2], .{});
    defer last.deinit();
    try testing.expectEqualStrings("next question", last.value.content);
}

test "llm answer cleanup preserves response lines" {
    const s = try cleanLlmAnswer(testing.allocator, " first   line\n\n second   line ");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("first line\nsecond line", s);
}

test "nam search helpers extract real links" {
    const gpa = testing.allocator;
    const html =
        \\
        \\            <a class="result__a" href="/l/?uddg=https%3A%2F%2Ftonehunt.org%2Fmodels%2Fabc&amp;rut=x">
        \\                Metallica NAM capture
        \\            </a>
        \\            <a href="https://example.com/manual">Ignore me</a>
        \\            <a href="https://example.com/model.nam">Direct NAM</a>
        \\
    ;
    var links = try extractSearchLinks(gpa, html, 8);
    defer freeResults(gpa, &links);
    try testing.expectEqual(@as(usize, 2), links.items.len);
    try testing.expectEqualStrings("Metallica NAM capture", links.items[0].title);
    try testing.expectEqualStrings("https://tonehunt.org/models/abc", links.items[0].url);
    try testing.expectEqualStrings("Direct NAM", links.items[1].title);
    try testing.expectEqualStrings("https://example.com/model.nam", links.items[1].url);
    const enc = try qenc(gpa, "Metallica Mark IIC+ NAM");
    defer gpa.free(enc);
    try testing.expectEqualStrings("Metallica+Mark+IIC%2B+NAM", enc);
}

test "nam search extracts direct links from result pages" {
    const gpa = testing.allocator;
    const html =
        \\
        \\            <a href="/downloads/mesa.nam">Mesa</a>
        \\            <a href="//cdn.example.test/amps/5150.nam?download=1">5150</a>
        \\
    ;
    var links = try extractDirectNamLinksFromHtml(gpa, html, "https://example.test/models/abc", 8);
    defer freeResults(gpa, &links);
    try testing.expectEqual(@as(usize, 2), links.items.len);
    try testing.expectEqualStrings("mesa.nam", links.items[0].title);
    try testing.expectEqualStrings("https://example.test/downloads/mesa.nam", links.items[0].url);
    try testing.expectEqualStrings("5150.nam?download=1", links.items[1].title);
    try testing.expectEqualStrings("https://cdn.example.test/amps/5150.nam?download=1", links.items[1].url);
}

test "nam research is automatic for amp discovery prompts" {
    try testing.expect(llmPromptNeedsNamResearch("find me a Metallica NAM amp capture"));
    try testing.expect(llmPromptNeedsNamResearch("where can i get a Mesa amp model?"));
    try testing.expect(!llmPromptNeedsNamResearch("how do i turn NAM off?"));
    try testing.expect(!llmPromptNeedsNamResearch("how do i set vcf mic?"));
}

test "nam tool requires a query" {
    const gpa = testing.allocator;
    var p = try std.json.parseFromSlice(Value, gpa, "{}", .{});
    defer p.deinit();
    var f: Failure = .{ .gpa = gpa };
    defer f.deinit();
    const e = executeLlmTool(&f, Http.offline, gpa, testing.io, "find_nam_captures", p.value);
    try testing.expectError(error.Fail, e);
    try testing.expect(std.mem.indexOf(u8, f.msg.?, "needs a non-empty query") != null);
}

test "llm and line histories are bounded, oldest first out" {
    const r = try Rig.init(.{});
    defer r.deinit();
    var buf: [32]u8 = undefined;
    for (0..App.max_llm_exchanges + 5) |i| {
        try r.app.rememberLlmExchange(try std.fmt.bufPrint(&buf, "ask {d}", .{i}), "answer");
    }
    try testing.expectEqual(2 * App.max_llm_exchanges, r.app.llm_history.items.len);
    try testing.expectEqualStrings("ask 5", r.app.llm_history.items[0].content);
    for (0..App.max_history_lines + 3) |i| try r.app.historyPush(try std.fmt.bufPrint(&buf, "bpm {d}", .{i}));
    try testing.expectEqual(App.max_history_lines, r.app.history.items.len);
    try testing.expectEqualStrings("bpm 3", r.app.history.items[0]);
}

test "llm history remembers exact sent prompt and returned commands" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const sent = try llmEditPrompt(r.gpa, "make a d major turnaround");
    defer r.gpa.free(sent);
    try testing.expect(std.mem.indexOf(u8, sent, "make the change with the apply_maqam_commands tool") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "Never concatenate two commands without a separator") != null);
    try r.app.rememberLlmExchange(sent, "d major 332\ng major 332");
    try testing.expectEqual(@as(usize, 2), r.app.llm_history.items.len);
    try testing.expectEqualStrings(sent, r.app.llm_history.items[0].content);
    try testing.expectEqualStrings("d major 332\ng major 332", r.app.llm_history.items[1].content);
}

test "llm score context reports time steps not just phrase rows" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 43 r16");
    const ctx = try r.app.llmScoreContext(r.gpa);
    defer r.gpa.free(ctx);
    for ([_][]const u8{ "0: d bayati 43 r16", "time steps 0..15", "16 repeat pass(es)", "rhythm groups 43", "7 subdivisions per pass" }) |n|
        try testing.expect(std.mem.indexOf(u8, ctx, n) != null);
}

test "llm repeated phrase suggestions are minimized compactly" {
    const gpa = testing.allocator;
    const a = try minimizeRepeatedLlmPhraseCommands(gpa, &.{ "e minor 43", "e minor 43", "e minor 43", "e minor 43" }, 7);
    defer freeStrList(gpa, a);
    try expectStrs(&.{"e minor 43 r4"}, a);
    const b = try minimizeRepeatedLlmPhraseCommands(gpa, &.{ "e minor 332", "d major 332332", "e minor 332", "d major 332332", "e minor 332", "d major 332332" }, 7);
    defer freeStrList(gpa, b);
    try expectStrs(&.{ "e minor 332", "d major 332332", "j 7 3" }, b);
    const c = try minimizeRepeatedLlmPhraseCommands(gpa, &.{ "bpm 140", "e minor 332", "d major 332332", "e minor 332", "d major 332332" }, 7);
    defer freeStrList(gpa, c);
    try expectStrs(&.{ "bpm 140", "e minor 332", "d major 332332", "j 8 2" }, c);
    const d = try minimizeRepeatedLlmPhraseCommands(gpa, &.{ "e minor 332", "bpm 140", "e minor 332", "bpm 140" }, 0);
    defer freeStrList(gpa, d);
    try expectStrs(&.{ "e minor 332", "bpm 140", "e minor 332", "bpm 140" }, d);
}

test "llm edit rolls back when an applied command fails" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 4444");
    try r.app.applyLlmEditCommands(&.{ "e minor 332", "edit 999 d major 332" });
    try testing.expectEqual(@as(usize, 1), r.app.phrases.items.len);
    const shown = try r.app.phrases.items[0].displaySrc(r.gpa);
    defer r.gpa.free(shown);
    try testing.expectEqualStrings("d bayati 4444", shown);
    try testing.expectEqual(@as(usize, 1), r.app.next_phrase_id);
    try expectMsgContains(r, "restored the previous phrases");
}

test "phrase completion uses current phrase transition rules" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 4444");
    try r.input("c ");
    try r.app.completeInput();
    try testing.expectEqualStrings("c rast 4444", r.app.input.items);
    try r.cmd("e minor 332 r2");
    try r.input("g ");
    try r.app.completeInput();
    try testing.expectEqualStrings("g major 332 r2", r.app.input.items);
}

test "loads rewritten v1 session with custom jins" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const text = "MAQAM_SESSION_V1\ncreate saba2 1/1 13/12 6/5 5/4\nvol 1\nbpm 180\ns 2\nP|2|1|d bayati, f hijaz 4444\nJ|3|0|3\nP|4|1|a saba, c hijaz\nP|5|1|a saba2, c hijaz\nJ|6|4|4\nP|7|1|g rast 664664\nJ|8|7|4\n";
    if (try r.app.loadSessionText(text, .{})) |e| {
        defer r.gpa.free(e);
        return error.LoadFailed;
    }
    try testing.expectEqual(@as(usize, 9), r.app.phrases.items.len);
    try testing.expectEqual(@as(usize, 9), r.app.next_phrase_id);
}

test "load session resets transient view and audio effect state" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const a = r.app;
    try a.setInput("stale command");
    a.show_help = true;
    a.show_jins = true;
    a.help_scroll = 12;
    a.jins_scroll = 7;
    a.message_scroll = 4;
    a.history_pos = 0;
    try a.saved_input.appendSlice(r.gpa, "saved");
    a.cursor_pos = 3;
    a.auditioning_jins = true;
    r.clearSent();
    try r.loadV3("P|0|1|d bayati 4444\n");
    try testing.expectEqual(@as(usize, 0), a.input.items.len);
    try testing.expect(!a.show_help and !a.show_jins);
    try testing.expectEqual(@as(u16, 0), a.help_scroll);
    try testing.expectEqual(@as(u16, 0), a.jins_scroll);
    try testing.expectEqual(@as(u16, 0), a.message_scroll);
    try testing.expectEqual(@as(?usize, null), a.history_pos);
    try testing.expectEqual(@as(usize, 0), a.saved_input.items.len);
    try testing.expectEqual(@as(usize, 0), a.cursor_pos);
    try testing.expect(!a.auditioning_jins);
    try testing.expect(r.sent(.reset_session_state));
}

test "bundled v3 sessions load" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "default.mq", "magiccarpet.mq", "growl.mq" }) |name| {
        const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, name, gpa, .limited(16 << 20));
        defer gpa.free(source);
        try testing.expect(std.mem.startsWith(u8, source, "MAQAM_SESSION_V3\n"));
        const r = try Rig.init(.{});
        defer r.deinit();
        if (try r.app.loadSessionText(source, .{})) |e| {
            defer gpa.free(e);
            std.debug.print("{s} failed to load: {s}\n", .{ name, e });
            return error.LoadFailed;
        }
        try testing.expect(r.app.phrases.items.len > 0);
        for (r.app.phrases.items) |p| try testing.expect(p.id < r.app.next_phrase_id);
    }
}

test "recording errors appear in response area" {
    const r = try Rig.init(.{ .record_fn = fakeRecordErr });
    defer r.deinit();
    try r.cmd("m");
    try testing.expect(std.mem.startsWith(u8, r.msg(), "◉ rendering 1×") or r.app.rec_job == null);
    try tickUntil(r, struct {
        fn f(a: *App) bool {
            return a.rec_job == null;
        }
    }.f);
    try expectMsg(r, "✗ generated source background failed");
}

test "recording success sets the last recording; a second m is refused while pending" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 4444");
    try r.cmd("m 2");
    try testing.expectEqualStrings("◉ rendering 2×…", r.msg());
    r.shared.rec_active.store(true, .monotonic);
    try r.cmd("m");
    try expectMsg(r, "✗ already rendering");
    r.shared.rec_active.store(false, .monotonic);
    try tickUntil(r, struct {
        fn f(a: *App) bool {
            return a.rec_job == null;
        }
    }.f);
    try expectMsg(r, "saved → maqam-test.mp4");
    try testing.expectEqualStrings("maqam-test.mp4", r.app.last_recording.?);
}

test "the timeline is bounded" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 4");
    // Fill with copies directly (sending 4096 audio commands would only slow the test).
    while (r.app.phrases.items.len < max_entries) {
        const c = try r.app.phrases.items[0].clone(r.gpa);
        try r.app.phrases.append(r.gpa, c);
    }
    try r.cmd("d bayati 4");
    try expectMsg(r, timeline_full_message);
    try r.cmd("stop");
    try expectMsg(r, timeline_full_message);
    try r.cmd("i 0 bpm 100");
    try expectMsg(r, timeline_full_message);
    try testing.expectEqual(max_entries, r.app.phrases.items.len);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(r.gpa);
    try text.appendSlice(r.gpa, "MAQAM_SESSION_V3\n");
    for (0..max_entries + 1) |i| try text.print(r.gpa, "B|{d}|120\n", .{i});
    const err = (try r.app.loadSessionText(text.items, .{})).?;
    defer r.gpa.free(err);
    try testing.expectEqualStrings("the session has 4097 timeline entries; at most 4096 are allowed", err);
}

test "editing commands and their messages" {
    const r = try Rig.init(.{});
    defer r.deinit();
    try r.cmd("d bayati 4444");
    try r.cmd("e hijaz 332");
    try r.cmd("i 1 bpm 140");
    try expectMsg(r, "inserted bpm at 1");
    try r.cmd("i 1 s 2");
    try expectMsg(r, "inserted sustain at 2");
    try r.cmd("edit 2 bpm 90");
    try expectMsg(r, "edited 2 → bpm 90.00");
    try r.cmd("edit 3 s 1.5");
    try expectMsg(r, "edited 3 → s 1.50s");
    try r.cmd("up 1");
    try expectMsg(r, "moved 1 up");
    try r.cmd("up 1");
    try expectMsg(r, "moved 1 up");
    try r.cmd("up 1");
    try expectMsg(r, "moved 1 up");
    try r.cmd("up 1");
    try expectMsg(r, "id 1 is already at top");
    try r.cmd("bpm 100");
    try expectMsg(r, "BPM line → 100.00");
    try r.cmd("s 0.5");
    try expectMsg(r, "s line → 0.50s");
    try r.cmd("x 99 0");
    try expectMsg(r, "✗ no id 99");
    try r.cmd("edit 1 d rast 332");
    try expectMsg(r, "edited 1");
    try r.cmd("z");
    try expectMsg(r, "⏸ paused");
    try r.cmd("z");
    try expectMsg(r, "▶ playing");
    try r.cmd("z 1");
    try expectMsg(r, "next → phrase 1");
    try r.cmd("clear");
    try expectMsg(r, "cleared");
    try testing.expectEqual(@as(usize, 0), r.app.phrases.items.len);
    try r.cmd("rot");
    try expectMsg(r, "nothing to rotate");
    try r.cmd("clockin usb");
    try expectMsg(r, "✗ clockin: MIDI clock is not available in this build");
    try r.cmd("q");
    try testing.expect(r.app.should_quit);
}

test "history and line editing" {
    const r = try Rig.init(.{});
    defer r.deinit();
    const a = r.app;
    try a.historyPush("  one ");
    try a.historyPush("one");
    try a.historyPush("two");
    try testing.expectEqual(@as(usize, 2), a.history.items.len);
    try a.setInput("draft");
    try a.historyUp();
    try testing.expectEqualStrings("two", a.input.items);
    try a.historyUp();
    try a.historyUp();
    try testing.expectEqualStrings("one", a.input.items);
    try a.historyDown();
    try a.historyDown();
    try testing.expectEqualStrings("draft", a.input.items);
    try a.setInput("aé");
    a.cursorLeft();
    try a.insertChar('x');
    try testing.expectEqualStrings("axé", a.input.items);
    a.cursorEnd();
    a.backspace();
    try testing.expectEqualStrings("ax", a.input.items);
    a.cursorHome();
    a.deleteChar();
    try testing.expectEqualStrings("x", a.input.items);
}

/// A fake network: answers the LLM with a fixed body and records every request.
const FakeHttp = struct {
    body: []const u8,
    status: u16 = 200,
    requests: std.ArrayList(u8) = .empty,
    lock: util.SpinLock = .{},

    fn http(self: *FakeHttp) Http {
        return .{ .ctx = self, .online = false, .fetch = fetch, .download = Http.offline.download, .open_browser = Http.offline.open_browser };
    }

    fn fetch(ctx: ?*anyopaque, gpa: Allocator, _: std.Io, _: std.http.Method, url: []const u8, headers: []const net.Header, payload: ?[]const u8) anyerror!net.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ctx.?));
        self.lock.lock();
        defer self.lock.unlock();
        try self.requests.appendSlice(testing.allocator, url);
        for (headers) |h| try self.requests.print(testing.allocator, "\n{s}: {s}", .{ h.name, h.value });
        if (payload) |p| try self.requests.appendSlice(testing.allocator, p);
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.body) };
    }
};

test "an LLM edit is applied through the seam and its key never reaches the log" {
    var fake: FakeHttp = .{ .body =
        \\{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"apply_maqam_commands","arguments":"{\"commands\":[\"d bayati 4444\",\"bpm 150\"]}"}}]}}]}
    };
    defer fake.requests.deinit(testing.allocator);
    const r = try Rig.init(.{ .http = fake.http(), .with_log = true, .env = &.{.{ "OPENAI_API_KEY", "sk-secret-test-key" }} });
    defer r.deinit();
    try r.cmd("chatgpt: add a bayati phrase");
    try expectMsg(r, "asking chatgpt for edits...");
    try tickUntil(r, struct {
        fn f(a: *App) bool {
            return a.llm_job == null;
        }
    }.f);
    try expectMsg(r, "LLM applied 2 edit command(s)");
    try testing.expectEqual(@as(usize, 2), r.app.phrases.items.len);
    try testing.expectEqual(@as(f64, 150), r.app.bpm);
    try testing.expect(std.mem.indexOf(u8, fake.requests.items, "Bearer sk-secret-test-key") != null);
    try testing.expectEqual(@as(usize, 2), r.app.llm_history.items.len);
    try testing.expect(std.mem.indexOf(u8, r.app.llm_history.items[1].content, "Tool returned commands:\nd bayati 4444\nbpm 150") != null);

    r.log.close();
    const log = try r.read("events.jsonl");
    defer r.gpa.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "sk-secret") == null);
    for ([_][]const u8{ "\"label\":\"Prompt\"", "\"label\":\"Ask\"", "\"label\":\"Commands\"", "\"label\":\"Apply\"", "\"label\":\"Applied\"" }) |n|
        try testing.expect(std.mem.indexOf(u8, log, n) != null);
    // nothing about the key in any file the App wrote
    const globals = r.read(".globals.ml") catch null;
    if (globals) |g| {
        defer r.gpa.free(g);
        try testing.expect(std.mem.indexOf(u8, g, "sk-") == null);
    }
}

test "an LLM answer and an LLM HTTP error" {
    var fake: FakeHttp = .{ .body = "{\"choices\":[{\"message\":{\"content\":\"  a jins is   a short scale \"}}]}" };
    defer fake.requests.deinit(testing.allocator);
    const r = try Rig.init(.{ .http = fake.http(), .env = &.{.{ "OPENAI_API_KEY", "k" }} });
    defer r.deinit();
    try r.cmd("chatgpt: what is a jins?");
    try expectMsg(r, "asking chatgpt...");
    try r.cmd("chatgpt: again?");
    try expectMsg(r, "✗ already asking LLM");
    try tickUntil(r, struct {
        fn f(a: *App) bool {
            return a.llm_job == null;
        }
    }.f);
    try expectMsg(r, "a jins is a short scale");
    fake.status = 401;
    fake.body = "{\"error\":{\"message\":\"bad key\"}}";
    try r.cmd("chatgpt: what is a jins?");
    try tickUntil(r, struct {
        fn f(a: *App) bool {
            return a.llm_job == null;
        }
    }.f);
    try expectMsg(r, "✗ LLM HTTP 401: bad key; check the API key, model name, and account access, then try again");
}

test "the event log records an edit interaction with phrase sessions and positions" {
    const r = try Rig.init(.{ .with_log = true });
    defer r.deinit();
    try r.cmd("d bayati 4444");
    r.shared.phrase_starts.store(1, .monotonic);
    try r.app.tick();
    try r.cmd("j 77 2");
    try r.cmd("q");
    r.log.close();
    const log = try r.read("events.jsonl");
    defer r.gpa.free(log);
    const expected = [_][]const u8{
        "\"session\":\"1\",\"from\":\"Performer\",\"to\":\"App\",\"label\":\"Command\",\"cause\":null,\"fields\":{\"line\":\"d bayati 4444\"}",
        "\"session\":\"1.1\",\"from\":\"App\",\"to\":\"Audio\",\"label\":\"Phrase\",\"cause\":null,\"fields\":{\"id\":\"0\",\"source\":\"d bayati 4444\"}",
        "\"session\":\"1\",\"from\":\"App\",\"to\":\"Performer\",\"label\":\"Shown\"",
        "\"session\":\"1.1\",\"from\":\"Audio\",\"to\":\"App\",\"label\":\"Position\"",
        "\"session\":\"2\",\"from\":\"App\",\"to\":\"Performer\",\"label\":\"Rejected\"",
        "\"session\":\"3\",\"from\":\"Performer\",\"to\":\"App\",\"label\":\"Quit\"",
        "\"session\":\"3.1\",\"from\":\"App\",\"to\":\"Audio\",\"label\":\"Stop\"",
    };
    var at: usize = 0;
    for (expected) |e| {
        const i = std.mem.indexOfPos(u8, log, at, e) orelse {
            std.debug.print("missing in order: {s}\nlog:\n{s}\n", .{ e, log });
            return error.TestExpectedContains;
        };
        at = i + e.len;
    }
}

test "describe fx and vcf" {
    const gpa = testing.allocator;
    const d = try describeFx(gpa, .{});
    defer gpa.free(d);
    try testing.expect(std.mem.startsWith(u8, d, "flanger"));
    const v = try describeVcf(gpa, .{});
    defer gpa.free(v);
    try testing.expect(std.mem.startsWith(u8, v, "vcf"));
}

test "fixed-point floats round ties to even like Rust" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { f64, u8, []const u8 }{
        .{ 1.25, 1, "1.2" },      .{ 1.35, 1, "1.4" },      .{ 0.125, 2, "0.12" }, .{ 2.5, 0, "2" },
        .{ 3.5, 0, "4" },         .{ -1.25, 1, "-1.2" },    .{ 0.7, 2, "0.70" },   .{ 120, 2, "120.00" },
        .{ 0.999, 5, "0.99900" }, .{ 1.0 / 3.0, 1, "0.3" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[2], try std.fmt.bufPrint(&buf, "{f}", .{rfix(c[0], c[1])}));
    try testing.expectEqualStrings("0.25", try std.fmt.bufPrint(&buf, "{f}", .{rfix(@as(f32, 0.25), 2)}));
}

test "every declaration compiles" {
    testing.refAllDecls(App);
}
