//! Port of maqam-live `src/main.rs`: the entry point. With no arguments it starts the live audio
//! engine and the terminal UI; with arguments it runs them as commands (the Rust `run_cli`), and
//! it provides the two hooks of the specification's "comparison" markdown (spec/Requirements.lean):
//!
//!   maqam-live --render <session.mq> --cycles <n> --rate <hz> --wav <out.wav>
//!   maqam-live --bench <session.mq> --seconds <s> --frames 64 --rate 48000 [--nam <capture.nam>] [--period-log <path>]
//!
//! --render writes a 32-bit float mono WAV and exits 0 (no device, no TUI); --bench prints one JSON
//! line {frames, rate, callbacks, deadline_misses, callback_p50_us, callback_p99_us,
//! callback_max_us}. Bad hook usage prints the usage on stderr and exits 2. MAQAM_EVENT_LOG names
//! the event log (eventlog.zig).
//!
//! Deliberate differences from the Rust:
//! * The MIDI clock (midi_clock.rs, midi_clockout.rs) is not ported: the specification does not
//!   mention MIDI; app.zig answers clockin / clockout with a rejection.
//! * The TUI exits 1 with a message on stderr when the audio device cannot be opened (the Rust
//!   returned the error from main, which printed "Error: ..." and exited 1).
//! * Command mode without an audio device closes the command ring, so the App frees each audio
//!   command instead of queueing it for nobody (the Rust kept a receiver alive that never read).
//! * The main thread frees what the audio thread hands back on the garbage ring (App.tick, and
//!   App.deinit before the engine stops); the Rust freed it on the audio thread.
//! * NO_COLOR is not consulted at all: the UI always writes truecolor (the Rust removed NO_COLOR
//!   and forced color output).
const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const audio = @import("audio.zig");
const device = @import("device.zig");
const realtime = @import("realtime.zig");
const eventlog = @import("eventlog.zig");
const session = @import("session.zig");
const fx = @import("fx.zig");
const record = @import("record.zig");
const sequencer = @import("sequencer.zig");
const shared_mod = @import("shared.zig");
const ui = @import("ui.zig");
const vcf = @import("vcf.zig");
const wav = @import("wav.zig");

const App = app_mod.App;
const Shared = shared_mod.Shared;

const render_usage = "usage: maqam-live --render <session.mq> --cycles <n> --rate <hz> --wav <out.wav>\n";
const bench_usage = "usage: maqam-live --bench <session.mq> --seconds <s> --frames 64 --rate 48000 [--nam <capture.nam>] [--period-log <path>]\n";
const max_session_bytes = 64 << 20;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 0) argv[1..] else argv;

    if (args.len > 0 and std.mem.eql(u8, args[0], "--render")) std.process.exit(runRender(gpa, io, init.environ_map, args));
    if (args.len > 0 and std.mem.eql(u8, args[0], "--bench")) std.process.exit(runBench(gpa, io, args));

    var log = eventlog.EventLog.fromEnv(io, init.environ_map);
    defer log.close();
    const shared = try gpa.create(Shared);
    defer gpa.destroy(shared);
    shared.* = .{};

    if (args.len > 0) {
        const commands = try cliCommands(gpa, args);
        defer {
            for (commands) |c| gpa.free(c);
            gpa.free(commands);
        }
        try runCli(gpa, io, init.environ_map, shared, &log, commands);
        return;
    }

    var live = audio.startLive(gpa, io, shared) catch |err| {
        eprint(io, "maqam-live: audio output unavailable ({s}); run maqam-live in an environment with an audio device\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer live.stop();
    const app = try App.init(gpa, io, .{
        .cmds = &live.engine.cmds,
        .garbage = &live.engine.garbage,
        .shared = shared,
        .log = &log,
        .env = init.environ_map,
        .record_fn = recordAdapter,
    });
    defer app.deinit();
    try ui.run(app, io);
}

/// record.recordCycle with the App's result type.
fn recordAdapter(gpa: Allocator, io: std.Io, shared: *Shared, phrases: []const sequencer.Phrase, bpm: f64, sustain: f64, bank: vcf.VcfBank, settings: fx.FxSettings, cycle_repeat: usize) app_mod.RecordResult {
    return switch (record.recordCycle(gpa, io, shared, phrases, bpm, sustain, bank, settings, cycle_repeat)) {
        .ok => |p| .{ .ok = p },
        .err => |m| .{ .err = m },
    };
}

/// The arguments split on "--" into command lines (the Rust `cli_commands`). Caller owns them.
fn cliCommands(gpa: Allocator, args: []const [:0]const u8) ![][]u8 {
    var commands: std.ArrayList([]u8) = .empty;
    errdefer {
        for (commands.items) |c| gpa.free(c);
        commands.deinit(gpa);
    }
    var cur: std.ArrayList([]const u8) = .empty;
    defer cur.deinit(gpa);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            if (cur.items.len > 0) {
                try commands.append(gpa, try std.mem.join(gpa, " ", cur.items));
                cur.clearRetainingCapacity();
            }
        } else try cur.append(gpa, arg);
    }
    if (cur.items.len > 0) try commands.append(gpa, try std.mem.join(gpa, " ", cur.items));
    return commands.toOwnedSlice(gpa);
}

/// Command mode (the Rust `run_cli`): each command's message on stderr, then the recording path
/// (after waiting for it) or the last message on stdout.
fn runCli(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, shared: *Shared, log: *eventlog.EventLog, commands: []const []const u8) !void {
    var live: ?audio.Live = audio.startLive(gpa, io, shared) catch |err| blk: {
        eprint(io, "audio output unavailable ({s}); continuing command mode without live playback\n", .{@errorName(err)});
        eprint(io, "to hear live playback, run maqam-live in an environment with an audio device\n", .{});
        break :blk null;
    };
    defer if (live) |*l| l.stop();
    // Without a device nobody reads the rings: a closed command ring makes the App free each
    // command at once.
    var sink_cmds: app_mod.CmdRing = .{};
    var sink_garbage: app_mod.GarbageRing = .{};
    sink_cmds.close();
    const app = try App.init(gpa, io, .{
        .cmds = if (live) |*l| &l.engine.cmds else &sink_cmds,
        .garbage = if (live) |*l| &l.engine.garbage else &sink_garbage,
        .shared = shared,
        .log = log,
        .env = env,
        .record_fn = recordAdapter,
    });
    defer app.deinit();

    for (commands) |cmd| {
        eprint(io, "> {s}\n", .{cmd});
        try app.handleCommand(cmd);
        try app.tick();
        if (app.message) |m| eprint(io, "{s}\n", .{m});
    }
    while (app.recordingPending()) {
        try app.tick();
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    try app.tick();
    if (app.last_recording) |path| {
        print(io, "{s}\n", .{path});
    } else if (app.message) |m| {
        print(io, "{s}\n", .{m});
    }
}

fn eprint(io: std.Io, comptime f: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(f, args) catch {};
    w.interface.flush() catch {};
}

fn print(io: std.Io, comptime f: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(f, args) catch {};
    w.interface.flush() catch {};
}

/// The value after flag `name` in `args[2..]` (flags come in pairs after `--<hook> <path>`).
fn flagValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

/// True when every flag after the path is one of `allowed` and has a value.
fn flagsWellFormed(args: []const [:0]const u8, allowed: []const []const u8) bool {
    if (args.len < 2 or (args.len - 2) % 2 != 0) return false;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        var ok = false;
        for (allowed) |a| if (std.mem.eql(u8, args[i], a)) {
            ok = true;
        };
        if (!ok) return false;
    }
    return true;
}

fn readSession(gpa: Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_session_bytes)) catch |err| {
        eprint(io, "maqam-live: could not read {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
}

/// --render: the exit code.
fn runRender(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const [:0]const u8) u8 {
    if (!flagsWellFormed(args, &.{ "--cycles", "--rate", "--wav" })) {
        eprint(io, render_usage, .{});
        return 2;
    }
    const cycles = std.fmt.parseInt(u32, flagValue(args, "--cycles") orelse "", 10) catch 0;
    const rate = std.fmt.parseInt(u32, flagValue(args, "--rate") orelse "", 10) catch 0;
    const out = flagValue(args, "--wav") orelse "";
    if (cycles == 0 or rate == 0 or out.len == 0) {
        eprint(io, render_usage, .{});
        return 2;
    }
    // The render takes part in one MaqamLive interaction, the session load (Session, ReadOrWrite,
    // Done or Failed, a Resync per timeline entry sent to the engine, Loaded or LoadFailed), logged
    // like the App's own load so the comparison can check the log with session_conform.
    var log = eventlog.EventLog.fromEnv(io, env);
    defer log.close();
    const sid = log.interaction();
    const s_ts = log.emit(sid, 0, "Performer", "App", "Session", null, &.{});
    const w_ts = log.emit(sid, 0, "App", "Disk", "ReadOrWrite", s_ts, &.{});
    const text = readSession(gpa, io, args[1]) orelse {
        _ = log.emit(sid, 0, "Disk", "App", "Failed", w_ts, &.{});
        _ = log.emit(sid, 0, "App", "Performer", "LoadFailed", s_ts, &.{});
        return 1;
    };
    defer gpa.free(text);
    _ = log.emit(sid, 0, "Disk", "App", "Done", w_ts, &.{});
    if (log.enabled()) {
        if (session.load(gpa, text, .{})) |loaded_const| {
            var loaded = loaded_const;
            defer loaded.deinit(gpa);
            if (loaded == .ok) for (loaded.ok.phrases, 1..) |_, k| {
                _ = log.emit(sid, @intCast(k), "App", "Audio", "Resync", null, &.{});
            };
        } else |_| {}
    }
    const result = audio.render(gpa, io, text, cycles, rate) catch |err| {
        eprint(io, "maqam-live: render failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer result.deinit(gpa);
    const samples = switch (result) {
        .ok => |s| s,
        .err => |m| {
            _ = log.emit(sid, 0, "App", "Performer", "LoadFailed", s_ts, &.{});
            eprint(io, "maqam-live: could not load {s}: {s}\n", .{ args[1], m });
            return 1;
        },
    };
    _ = log.emit(sid, 0, "App", "Performer", "Loaded", s_ts, &.{});
    const bytes = wav.encode(gpa, samples, rate, true) catch |err| {
        eprint(io, "maqam-live: could not encode the WAV: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(bytes);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes }) catch |err| {
        eprint(io, "maqam-live: could not write {s}: {s}\n", .{ out, @errorName(err) });
        return 1;
    };
    return 0;
}

/// --bench: the exit code.
fn runBench(gpa: Allocator, io: std.Io, args: []const [:0]const u8) u8 {
    if (!flagsWellFormed(args, &.{ "--seconds", "--frames", "--rate", "--nam", "--period-log" })) {
        eprint(io, bench_usage, .{});
        return 2;
    }
    const seconds = std.fmt.parseFloat(f64, flagValue(args, "--seconds") orelse "") catch 0;
    const frames = std.fmt.parseInt(u32, flagValue(args, "--frames") orelse "", 10) catch 0;
    const rate = std.fmt.parseInt(u32, flagValue(args, "--rate") orelse "", 10) catch 0;
    if (!(seconds > 0) or !std.math.isFinite(seconds) or frames == 0 or rate == 0) {
        eprint(io, bench_usage, .{});
        return 2;
    }
    const text = readSession(gpa, io, args[1]) orelse return 1;
    defer gpa.free(text);
    const log_path = flagValue(args, "--period-log");
    if (seconds > 600) {
        eprint(io, "maqam-live: --seconds is at most 600\n", .{});
        return 2;
    }
    // Preallocated before the timed loop; written only after it (never from the audio path).
    const trace: ?[]device.BlockTime = if (log_path != null)
        gpa.alloc(device.BlockTime, device.blocksFor(seconds, frames, rate)) catch {
            eprint(io, "maqam-live: out of memory for the period log\n", .{});
            return 1;
        }
    else
        null;
    defer if (trace) |t| gpa.free(t);
    const base_ns: u64 = @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
    const r = audio.bench(gpa, io, text, seconds, frames, rate, flagValue(args, "--nam"), trace, true) catch |err| {
        eprint(io, "maqam-live: bench failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (log_path) |path| writeTrace(gpa, io, path, base_ns, trace.?[0..r.callbacks], frames, rate) catch |err| {
        eprint(io, "maqam-live: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    print(io, "{{\"frames\":{d},\"rate\":{d},\"callbacks\":{d},\"deadline_misses\":{d},\"callback_p50_us\":{d},\"callback_p99_us\":{d},\"callback_max_us\":{d},\"release_late_max_us\":{d},\"slack_min_us\":{d},\"realtime\":\"{s}\",\"memory_locked\":{}}}\n", .{
        r.frames, r.rate, r.callbacks, r.deadline_misses, r.callback_p50_us, r.callback_p99_us, r.callback_max_us, r.release_late_max_us, r.slack_min_us, realtime.name(r.realtime), r.memory_locked,
    });
    return 0;
}

/// The AudioPeriod stream of a bench run, written after the run.
fn writeTrace(gpa: Allocator, io: std.Io, path: []const u8, base_ns: u64, trace: []const device.BlockTime, frames: u32, rate: u32) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try device.writePeriodLog(&out.writer, base_ns, trace, frames, rate);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

test "cli commands are split on --" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "d", "bayati", "4444", "--", "--", "m", "--" };
    const cmds = try cliCommands(gpa, &args);
    defer {
        for (cmds) |c| gpa.free(c);
        gpa.free(cmds);
    }
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("d bayati 4444", cmds[0]);
    try std.testing.expectEqualStrings("m", cmds[1]);
}

test "hook flags" {
    const good = [_][:0]const u8{ "--render", "s.mq", "--cycles", "2", "--rate", "48000", "--wav", "o.wav" };
    try std.testing.expect(flagsWellFormed(&good, &.{ "--cycles", "--rate", "--wav" }));
    try std.testing.expectEqualStrings("48000", flagValue(&good, "--rate").?);
    const bad = [_][:0]const u8{ "--render", "s.mq", "--cycles" };
    try std.testing.expect(!flagsWellFormed(&bad, &.{ "--cycles", "--rate", "--wav" }));
    const unknown = [_][:0]const u8{ "--bench", "s.mq", "--speed", "2" };
    try std.testing.expect(!flagsWellFormed(&unknown, &.{ "--seconds", "--frames", "--rate", "--nam" }));
}
