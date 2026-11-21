//! Audio devices for the Zig implementation: ALSA output (with optional non-blocking capture for
//! the live input) on a thread of its own on Linux, CoreAudio on macOS (coreaudio.zig), chosen at
//! compile time as `Output`, and a null device for the bench hook. Each device calls
//! one process function per block; that function is the "output callback" of the specification,
//! and must not lock, allocate on the heap of other threads, touch files or the network (proof
//! "The audio callback never blocks"). The device thread itself blocks only in the ALSA write,
//! which is the device's clock.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("alsa");
const realtime = @import("realtime.zig");

/// The live output device of this operating system: open, start, stop, close, rate, period and
/// latency_us are the same on each. The ALSA headers are only translated for Linux (build.zig).
pub const Output = if (builtin.os.tag.isDarwin()) @import("coreaudio.zig").CoreAudio else Alsa;

pub const Frame = [2]f32;

/// Called once per block with interleaved stereo output to fill and the captured input frames
/// (possibly fewer than `out.len / 2`, possibly none).
pub const Process = *const fn (ctx: *anyopaque, out: []f32, input: []const Frame) void;

pub const Config = struct {
    rate: u32 = 48000,
    period_frames: u32 = 256,
    periods: u32 = 3,
    capture: bool = true,
    /// Counts every playback underrun (proof "A buffer skip is never silent"); null counts nothing.
    underruns: ?*std.atomic.Value(u64) = null,
};

/// True when a write result says the device ran out of samples (an underrun, -EPIPE).
pub fn isUnderrun(w: c_long) bool {
    return w == -@as(c_long, @backingInt(std.posix.E.PIPE));
}

pub const Alsa = struct {
    playback: ?*c.snd_pcm_t = null,
    capture: ?*c.snd_pcm_t = null,
    rate: u32 = 48000,
    period: u32 = 256,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    process: Process = undefined,
    ctx: *anyopaque = undefined,
    out_buf: []f32 = &.{},
    in_buf: []Frame = &.{},
    in_raw: []f32 = &.{},
    capture_channels: u32 = 2,
    /// Microseconds the last write waited for the device (an estimate of playback latency).
    latency_us: std.atomic.Value(u64) = .init(0),
    underruns: ?*std.atomic.Value(u64) = null,
    io: std.Io = undefined,
    /// The scheduling the audio thread got when it started (realtime.request).
    realtime: realtime.Granted = .none,
    memory_locked: bool = false,

    /// Opens the default playback device (and, when asked, the default capture device; a missing
    /// capture device only means no live input). The returned device is not running yet.
    pub fn open(gpa: std.mem.Allocator, cfg: Config) !*Alsa {
        const self = try gpa.create(Alsa);
        errdefer gpa.destroy(self);
        self.* = .{};
        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.NoAudioOutput;
        errdefer _ = c.snd_pcm_close(pcm);
        var rate = cfg.rate;
        var period: c.snd_pcm_uframes_t = cfg.period_frames;
        try configure(pcm.?, 2, &rate, &period, cfg.periods);
        self.playback = pcm;
        self.underruns = cfg.underruns;
        self.rate = rate;
        self.period = @intCast(period);
        if (cfg.capture) {
            var cap: ?*c.snd_pcm_t = null;
            if (c.snd_pcm_open(&cap, "default", c.SND_PCM_STREAM_CAPTURE, c.SND_PCM_NONBLOCK) >= 0) {
                var cap_rate = rate;
                var cap_period = period;
                if (configure(cap.?, 2, &cap_rate, &cap_period, cfg.periods)) |_| {
                    if (cap_rate == rate and c.snd_pcm_start(cap) >= 0) self.capture = cap else _ = c.snd_pcm_close(cap);
                } else |_| _ = c.snd_pcm_close(cap);
            }
        }
        self.out_buf = try gpa.alloc(f32, self.period * 2);
        self.in_raw = try gpa.alloc(f32, self.period * 2);
        self.in_buf = try gpa.alloc(Frame, self.period);
        return self;
    }

    fn configure(pcm: *c.snd_pcm_t, channels: u32, rate: *u32, period: *c.snd_pcm_uframes_t, periods: u32) !void {
        var hw: ?*c.snd_pcm_hw_params_t = null;
        if (c.snd_pcm_hw_params_malloc(&hw) < 0) return error.AlsaParams;
        defer c.snd_pcm_hw_params_free(hw);
        if (c.snd_pcm_hw_params_any(pcm, hw) < 0) return error.AlsaParams;
        if (c.snd_pcm_hw_params_set_access(pcm, hw, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.AlsaParams;
        if (c.snd_pcm_hw_params_set_format(pcm, hw, c.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.AlsaFormat;
        if (c.snd_pcm_hw_params_set_channels(pcm, hw, channels) < 0) return error.AlsaChannels;
        var r: c_uint = rate.*;
        if (c.snd_pcm_hw_params_set_rate_near(pcm, hw, &r, null) < 0) return error.AlsaRate;
        rate.* = r;
        var p = period.*;
        _ = c.snd_pcm_hw_params_set_period_size_near(pcm, hw, &p, null);
        var buffer: c.snd_pcm_uframes_t = p * periods;
        _ = c.snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer);
        if (c.snd_pcm_hw_params(pcm, hw) < 0) return error.AlsaParams;
        _ = c.snd_pcm_hw_params_get_period_size(hw, &p, null);
        period.* = p;
        if (c.snd_pcm_prepare(pcm) < 0) return error.AlsaPrepare;
    }

    /// Whether a capture device feeds the live input.
    pub fn hasInput(self: *const Alsa) bool {
        return self.capture != null;
    }

    pub fn start(self: *Alsa, io: std.Io, process: Process, ctx: *anyopaque) !void {
        self.io = io;
        self.process = process;
        self.ctx = ctx;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Alsa) void {
        self.memory_locked = realtime.lockMemory();
        self.realtime = realtime.request(self.io, @as(u64, self.period) * std.time.ns_per_s / self.rate);
        const frames: c.snd_pcm_uframes_t = self.period;
        while (self.running.load(.acquire)) {
            var got: usize = 0;
            if (self.capture) |cap| {
                const n = c.snd_pcm_readi(cap, self.in_raw.ptr, frames);
                if (n > 0) {
                    got = @intCast(n);
                    for (0..got) |i| self.in_buf[i] = .{ self.in_raw[2 * i], self.in_raw[2 * i + 1] };
                } else if (n < 0 and n != -@as(c_long, @backingInt(std.posix.E.AGAIN))) {
                    _ = c.snd_pcm_recover(cap, @intCast(n), 1);
                    _ = c.snd_pcm_start(cap);
                }
            }
            self.process(self.ctx, self.out_buf, self.in_buf[0..got]);
            var off: usize = 0;
            while (off < self.period and self.running.load(.acquire)) {
                const w = c.snd_pcm_writei(self.playback, self.out_buf.ptr + off * 2, self.period - off);
                if (w < 0) {
                    // A buffer skip is counted before it is recovered from, never hidden.
                    if (isUnderrun(w)) {
                        if (self.underruns) |u| _ = u.fetchAdd(1, .monotonic);
                    }
                    if (c.snd_pcm_recover(self.playback, @intCast(w), 1) < 0) break;
                    continue;
                }
                off += @intCast(w);
            }
            var delay: c.snd_pcm_sframes_t = 0;
            if (c.snd_pcm_delay(self.playback, &delay) >= 0 and delay > 0)
                self.latency_us.store(@intCast(@divTrunc(@as(i64, delay) * 1_000_000, self.rate)), .monotonic);
        }
    }

    pub fn stop(self: *Alsa) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn close(self: *Alsa, gpa: std.mem.Allocator) void {
        self.stop();
        if (self.capture) |cap| _ = c.snd_pcm_close(cap);
        if (self.playback) |pcm| {
            _ = c.snd_pcm_drain(pcm);
            _ = c.snd_pcm_close(pcm);
        }
        gpa.free(self.out_buf);
        gpa.free(self.in_raw);
        gpa.free(self.in_buf);
        gpa.destroy(self);
    }
};

/// The null device for the bench hook. It is the clock, like a real output device: it releases
/// block k at t0 + k * frames/rate and the block must be handed over before its release plus one
/// period (protocol AudioPeriod). The bench waits for each release (sleeping, then spinning for
/// the last 200 us), never starts a block early, and never moves the grid: a late block makes the
/// next one start late, as it would on a device. Callback times run from release to hand-over,
/// so the wake-up delay counts as well as the rendering.
pub const BenchResult = struct {
    frames: u32,
    rate: u32,
    callbacks: u64,
    deadline_misses: u64,
    callback_p50_us: f64,
    callback_p99_us: f64,
    callback_max_us: f64,
    /// The longest wait between a release and the start of its block.
    release_late_max_us: f64,
    /// The period minus the longest callback; negative when a block was late.
    slack_min_us: f64,
    /// The scheduling the timed thread got (realtime.request): fifo, rtkit or none.
    realtime: realtime.Granted = .none,
    /// Whether every mapping was locked in RAM before the timed loop (realtime.lockMemory).
    memory_locked: bool = false,
};

/// One block of the AudioPeriod stream: release and hand-over, nanoseconds from the bench's t0.
pub const BlockTime = struct { release_ns: u64, done_ns: u64 };

/// Release k on the grid, in nanoseconds from t0, exactly: floor(k * frames * 10^9 / rate).
pub fn releaseNs(k: u64, frames: u32, rate: u32) u64 {
    return @intCast(@as(u128, k) * frames * std.time.ns_per_s / rate);
}

/// The device's verdict on one block, in integers: handed over within one period of its release.
pub fn onTime(t: BlockTime, frames: u32, rate: u32) bool {
    if (t.done_ns < t.release_ns) return true;
    return @as(u128, t.done_ns - t.release_ns) * rate <= @as(u128, frames) * std.time.ns_per_s;
}

fn nowNs(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
}

fn waitUntil(io: std.Io, t: u64) void {
    const spin_ns: u64 = 200 * std.time.ns_per_us;
    var now = nowNs(io);
    if (now + spin_ns < t) {
        const d = t - spin_ns - now;
        sleepNs(d);
    }
    now = nowNs(io);
    while (now < t) : (now = nowNs(io)) std.atomic.spinLoopHint();
}

fn sleepNs(d: u64) void {
    if (builtin.os.tag.isDarwin()) {
        var req: std.c.timespec = .{ .sec = @intCast(d / std.time.ns_per_s), .nsec = @intCast(d % std.time.ns_per_s) };
        _ = nanosleep(&req, null);
    } else {
        var req: std.os.linux.timespec = .{ .sec = @intCast(d / std.time.ns_per_s), .nsec = @intCast(d % std.time.ns_per_s) };
        _ = std.os.linux.nanosleep(&req, null);
    }
}

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

/// The number of blocks in `seconds`: a trace passed to `bench` must hold this many.
pub fn blocksFor(seconds: f64, frames: u32, rate: u32) usize {
    return @intFromFloat(@ceil(seconds * @as(f64, @floatFromInt(rate)) / @as(f64, @floatFromInt(frames))));
}

/// `trace`, when given, receives one BlockTime per block; it is preallocated by the caller and
/// written to a file only after the run (never from the timed loop).
pub fn bench(gpa: std.mem.Allocator, io: std.Io, process: Process, ctx: *anyopaque, frames: u32, rate: u32, seconds: f64, input: ?[]const Frame, trace: ?[]BlockTime, want_realtime: bool) !BenchResult {
    const callbacks = blocksFor(seconds, frames, rate);
    if (trace) |t| if (t.len < callbacks) return error.TraceTooShort;
    const out = try gpa.alloc(f32, frames * 2);
    defer gpa.free(out);
    const times = try gpa.alloc(f64, callbacks);
    defer gpa.free(times);
    const period_us = @as(f64, @floatFromInt(frames)) * 1e6 / @as(f64, @floatFromInt(rate));
    var misses: u64 = 0;
    var late_start_max: u64 = 0;
    var in_pos: usize = 0;
    // Asked for before the timed loop, as the live audio thread does; back to normal after it.
    const granted: realtime.Granted = if (want_realtime) realtime.request(io, @as(u64, frames) * std.time.ns_per_s / rate) else .none;
    const locked = want_realtime and realtime.lockMemory();
    defer if (locked) realtime.unlockMemory();
    defer realtime.release(granted);
    const t0 = nowNs(io) + 2 * std.time.ns_per_ms;
    for (0..callbacks) |i| {
        var block_in: []const Frame = &.{};
        if (input) |src| if (src.len >= frames) {
            if (in_pos + frames > src.len) in_pos = 0;
            block_in = src[in_pos .. in_pos + frames];
            in_pos += frames;
        };
        const release = t0 + releaseNs(i, frames, rate);
        waitUntil(io, release);
        const started = nowNs(io);
        process(ctx, out, block_in);
        const done = nowNs(io);
        late_start_max = @max(late_start_max, started - release);
        const bt: BlockTime = .{ .release_ns = release - t0, .done_ns = done - t0 };
        if (trace) |t| t[i] = bt;
        times[i] = @as(f64, @floatFromInt(done - release)) / 1000.0;
        if (!onTime(bt, frames, rate)) misses += 1;
    }
    std.mem.sort(f64, times, {}, std.sort.asc(f64));
    const pick = struct {
        fn at(xs: []const f64, q: f64) f64 {
            if (xs.len == 0) return 0;
            const idx: usize = @min(xs.len - 1, @as(usize, @intFromFloat(@floor(q * @as(f64, @floatFromInt(xs.len - 1))))));
            return xs[idx];
        }
    };
    const max_us = if (times.len > 0) times[times.len - 1] else 0;
    return .{
        .frames = frames,
        .rate = rate,
        .callbacks = callbacks,
        .deadline_misses = misses,
        .callback_p50_us = pick.at(times, 0.5),
        .callback_p99_us = pick.at(times, 0.99),
        .callback_max_us = max_us,
        .release_late_max_us = @as(f64, @floatFromInt(late_start_max)) / 1000.0,
        .slack_min_us = period_us - max_us,
        .realtime = granted,
        .memory_locked = locked,
    };
}

/// Writes the AudioPeriod stream: per block (session = its index) Pull at the release, Block at the
/// hand-over, then Played or Skipped one nanosecond later, ts absolute (base + offset). Timestamps
/// stay unique by moving a Block or verdict that lands on a later block's release one nanosecond
/// later, and the verdict is computed from the written timestamps, so the file is self-consistent.
pub fn writePeriodLog(w: *std.Io.Writer, base_ns: u64, trace: []const BlockTime, frames: u32, rate: u32) !void {
    for (trace, 0..) |t, k| {
        const pull = base_ns + t.release_ns;
        const block = past(base_ns, trace, k, base_ns + t.done_ns);
        const verdict_ts = past(base_ns, trace, k, block + 1);
        const ok = onTime(.{ .release_ns = pull, .done_ns = block }, frames, rate);
        try w.print("{{\"ts\":\"{d}\",\"session\":\"{d}\",\"from\":\"Device\",\"to\":\"Audio\",\"label\":\"Pull\",\"cause\":null,\"fields\":{{}}}}\n", .{ pull, k });
        try w.print("{{\"ts\":\"{d}\",\"session\":\"{d}\",\"from\":\"Audio\",\"to\":\"Device\",\"label\":\"Block\",\"cause\":\"{d}\",\"fields\":{{}}}}\n", .{ block, k, pull });
        try w.print("{{\"ts\":\"{d}\",\"session\":\"{d}\",\"from\":\"Device\",\"to\":\"Audio\",\"label\":\"{s}\",\"cause\":\"{d}\",\"fields\":{{}}}}\n", .{ verdict_ts, k, if (ok) "Played" else "Skipped", block });
    }
}

/// `ts`, moved later past any release of a block after k that it lands on.
fn past(base_ns: u64, trace: []const BlockTime, k: usize, ts: u64) u64 {
    var v = ts;
    var j = k + 1;
    while (j < trace.len and base_ns + trace[j].release_ns <= v) : (j += 1) {
        if (base_ns + trace[j].release_ns == v) v += 1;
    }
    return v;
}

test "release grid is exact and the verdict is judged in integers" {
    try std.testing.expectEqual(@as(u64, 0), releaseNs(0, 64, 48000));
    try std.testing.expectEqual(@as(u64, 1_333_333), releaseNs(1, 64, 48000));
    try std.testing.expectEqual(@as(u64, 4_000_000), releaseNs(3, 64, 48000));
    try std.testing.expect(onTime(.{ .release_ns = 0, .done_ns = 1_333_333 }, 64, 48000));
    try std.testing.expect(!onTime(.{ .release_ns = 0, .done_ns = 1_333_334 }, 64, 48000));
}

test "an underrun is recognized from the write result" {
    try std.testing.expect(isUnderrun(-@as(c_long, @backingInt(std.posix.E.PIPE))));
    try std.testing.expect(!isUnderrun(-@as(c_long, @backingInt(std.posix.E.AGAIN))));
    try std.testing.expect(!isUnderrun(64));
}

const TestProc = struct {
    io: std.Io,
    calls: usize = 0,
    /// every `slow_every`-th block takes `slow_ns` (0: never)
    slow_every: usize = 0,
    slow_ns: u64 = 0,
    fn process(ctx: *anyopaque, out: []f32, input: []const Frame) void {
        _ = input;
        const self: *TestProc = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        @memset(out, 0);
        if (self.slow_every != 0 and self.calls % self.slow_every == 0) {
            const until = nowNs(self.io) + self.slow_ns;
            while (nowNs(self.io) < until) std.atomic.spinLoopHint();
        }
    }
};

test "the bench waits for each release and never starts a block early" {
    const io = std.testing.io;
    var p: TestProc = .{ .io = io };
    const n = blocksFor(0.05, 64, 48000);
    const trace = try std.testing.allocator.alloc(BlockTime, n);
    defer std.testing.allocator.free(trace);
    const before = nowNs(io);
    const r = try bench(std.testing.allocator, io, TestProc.process, &p, 64, 48000, 0.05, null, trace, false);
    const elapsed = nowNs(io) - before;
    try std.testing.expectEqual(@as(u64, n), r.callbacks);
    // paced, not as fast as it can: at least n - 1 periods
    try std.testing.expect(elapsed >= releaseNs(n - 1, 64, 48000));
    for (trace, 0..) |t, k| {
        try std.testing.expectEqual(releaseNs(k, 64, 48000), t.release_ns);
        try std.testing.expect(t.done_ns >= t.release_ns);
    }
    try std.testing.expect(r.slack_min_us <= 1333.34);
}

test "a block that overruns its period is a miss, and a late block delays the next" {
    const io = std.testing.io;
    // every 5th block takes two periods: it misses, and the block after it starts late
    var p: TestProc = .{ .io = io, .slow_every = 5, .slow_ns = 2 * releaseNs(1, 64, 48000) };
    const n = blocksFor(0.05, 64, 48000);
    const trace = try std.testing.allocator.alloc(BlockTime, n);
    defer std.testing.allocator.free(trace);
    const r = try bench(std.testing.allocator, io, TestProc.process, &p, 64, 48000, 0.05, null, trace, false);
    try std.testing.expect(r.deadline_misses >= n / 5);
    try std.testing.expect(r.slack_min_us < 0);
    try std.testing.expect(r.release_late_max_us > 1000);
}

test "the period log: Pull, Block, then the device's verdict from the written times" {
    const trace = [_]BlockTime{ .{ .release_ns = 0, .done_ns = 200_000 }, .{ .release_ns = 1_333_333, .done_ns = 2_700_000 } };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePeriodLog(&w, 1_000_000_000, &trace, 64, 48000);
    const text = w.buffered();
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"session\":\"0\",\"from\":\"Device\",\"to\":\"Audio\",\"label\":\"Played\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"session\":\"1\",\"from\":\"Device\",\"to\":\"Audio\",\"label\":\"Skipped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ts\":\"1000200000\",\"session\":\"0\",\"from\":\"Audio\",\"to\":\"Device\",\"label\":\"Block\",\"cause\":\"1000000000\"") != null);
}

test "a hand-over that lands on a later release is moved past it" {
    const trace = [_]BlockTime{ .{ .release_ns = 0, .done_ns = 1_333_333 }, .{ .release_ns = 1_333_333, .done_ns = 1_500_000 } };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePeriodLog(&w, 0, &trace, 64, 48000);
    const text = w.buffered();
    // block 0 handed over exactly at release 1: written at +1 ns, so it is one nanosecond late
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ts\":\"1333334\",\"session\":\"0\",\"from\":\"Audio\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"session\":\"0\",\"from\":\"Device\",\"to\":\"Audio\",\"label\":\"Skipped\"") != null);
}
