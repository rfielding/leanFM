//! Port of maqam-live `src/fx.rs`: the post-amp effect settings (flanger, chorus, reverb, ping-pong
//! delay with per-tick steps, the cabinet stage), the stereo `FxProcessor` and the mono
//! `CabinetProcessor` on the live input.
//!
//! The processor owns its delay lines: `FxProcessor.init(gpa, sample_rate)` allocates them and
//! `deinit(gpa)` frees them; `process` never allocates. Float clamps and float-to-index casts follow
//! Rust semantics (a NaN passes through `clamp`; `as usize` saturates), so no input can trap.
//! One deliberate difference: `CabinetProcessor` computes the three impulse responses in `init`, so
//! `setModel` (called from the output callback) never allocates; upstream rebuilds the response and
//! resizes its history there (book: Known gaps). The samples it produces are the same.
const std = @import("std");

const TAU: f32 = std.math.tau;
const PI: f32 = std.math.pi;

/// Rust `f32::clamp` (NaN stays NaN).
fn fclamp(x: f32, lo: f32, hi: f32) f32 {
    var v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

/// Rust `f32 as usize` (saturating, NaN -> 0).
fn toUsize(x: f32) usize {
    if (!(x > 0.0)) return 0;
    if (x >= @as(f32, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

pub const CabinetModel = enum {
    vintage,
    modern,
    open,

    pub fn parse(value: []const u8) ?CabinetModel {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(value, "vintage") or eq(value, "4x12")) return .vintage;
        if (eq(value, "modern") or eq(value, "tight")) return .modern;
        if (eq(value, "open") or eq(value, "1x12") or eq(value, "open-back")) return .open;
        return null;
    }

    pub fn name(self: CabinetModel) []const u8 {
        return switch (self) {
            .vintage => "vintage",
            .modern => "modern",
            .open => "open",
        };
    }
};

pub const FxSettings = struct {
    flanger_enabled: bool = false,
    flanger_rate_hz: f32 = 0.22,
    flanger_depth: f32 = 0.75,
    flanger_delay_ms: f32 = 2.8,
    flanger_feedback: f32 = 0.45,
    flanger_mix: f32 = 0.35,
    flanger_rate_step_per_tick: f32 = 0.0,
    flanger_depth_step_per_tick: f32 = 0.0,
    flanger_delay_step_per_tick: f32 = 0.0,
    flanger_feedback_step_per_tick: f32 = 0.0,
    flanger_mix_step_per_tick: f32 = 0.0,
    chorus_enabled: bool = false,
    chorus_rate_hz: f32 = 0.7,
    chorus_depth: f32 = 0.55,
    chorus_delay_ms: f32 = 18.0,
    chorus_mix: f32 = 0.32,
    chorus_rate_step_per_tick: f32 = 0.0,
    chorus_depth_step_per_tick: f32 = 0.0,
    chorus_delay_step_per_tick: f32 = 0.0,
    chorus_mix_step_per_tick: f32 = 0.0,
    reverb_enabled: bool = false,
    reverb_mix: f32 = 0.18,
    reverb_decay: f32 = 0.65,
    reverb_mix_step_per_tick: f32 = 0.0,
    reverb_decay_step_per_tick: f32 = 0.0,
    delay_enabled: bool = false,
    delay_time_secs: f32 = 0.28,
    delay_feedback: f32 = 0.42,
    delay_mix: f32 = 0.22,
    delay_time_step_per_tick: f32 = 0.0,
    delay_feedback_step_per_tick: f32 = 0.0,
    delay_mix_step_per_tick: f32 = 0.0,
    cabinet_enabled: bool = false,
    cabinet_model: CabinetModel = .vintage,
    cabinet_mix: f32 = 1.0,

    /// The Rust `FxSettings::default()`.
    pub fn default() FxSettings {
        return .{};
    }

    pub fn active(self: FxSettings) bool {
        return self.flanger_enabled or self.chorus_enabled or self.reverb_enabled or self.delay_enabled;
    }

    pub fn advanceTick(self: *FxSettings) void {
        if (self.flanger_enabled) {
            self.flanger_rate_hz = fclamp(self.flanger_rate_hz + self.flanger_rate_step_per_tick, 0.01, 8.0);
            self.flanger_depth = fclamp(self.flanger_depth + self.flanger_depth_step_per_tick, 0.0, 1.0);
            self.flanger_delay_ms = fclamp(self.flanger_delay_ms + self.flanger_delay_step_per_tick, 0.1, 10.0);
            self.flanger_feedback = fclamp(self.flanger_feedback + self.flanger_feedback_step_per_tick, -0.95, 0.95);
            self.flanger_mix = fclamp(self.flanger_mix + self.flanger_mix_step_per_tick, 0.0, 1.0);
        }
        if (self.chorus_enabled) {
            self.chorus_rate_hz = fclamp(self.chorus_rate_hz + self.chorus_rate_step_per_tick, 0.01, 8.0);
            self.chorus_depth = fclamp(self.chorus_depth + self.chorus_depth_step_per_tick, 0.0, 1.0);
            self.chorus_delay_ms = fclamp(self.chorus_delay_ms + self.chorus_delay_step_per_tick, 5.0, 35.0);
            self.chorus_mix = fclamp(self.chorus_mix + self.chorus_mix_step_per_tick, 0.0, 1.0);
        }
        if (self.reverb_enabled) {
            self.reverb_mix = fclamp(self.reverb_mix + self.reverb_mix_step_per_tick, 0.0, 1.0);
            self.reverb_decay = fclamp(self.reverb_decay + self.reverb_decay_step_per_tick, 0.0, 0.98);
        }
        if (self.delay_enabled) {
            self.delay_time_secs = fclamp(self.delay_time_secs + self.delay_time_step_per_tick, 0.01, 2.0);
            self.delay_feedback = fclamp(self.delay_feedback + self.delay_feedback_step_per_tick, 0.0, 0.95);
            self.delay_mix = fclamp(self.delay_mix + self.delay_mix_step_per_tick, 0.0, 1.0);
        }
    }
};

pub const Stereo = struct { left: f32, right: f32 };

pub const FxProcessor = struct {
    settings: FxSettings,
    sample_rate: f32,
    delay_l: []f32,
    delay_r: []f32,
    delay_pos: usize,
    delay_samples: usize,
    flanger_l: []f32,
    flanger_r: []f32,
    flanger_pos: usize,
    flanger_phase: f32,
    chorus_l: []f32,
    chorus_r: []f32,
    chorus_pos: usize,
    chorus_phase: f32,
    rev_l: []f32,
    rev_r: []f32,
    rev_pos: [4]usize,
    rev_len: [4]usize,

    /// The Rust `FxProcessor::new`. Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, sample_rate_in: f32) error{OutOfMemory}!FxProcessor {
        const sample_rate = @max(sample_rate_in, 1.0);
        const max_delay = toUsize(@ceil(sample_rate * 2.0)) +| 1;
        const max_flanger = toUsize(@ceil(sample_rate * 0.025)) +| 4;
        const max_chorus = toUsize(@ceil(sample_rate * 0.060)) +| 4;
        const reverb_len = toUsize(@ceil(sample_rate * 0.19)) +| 1;
        const delay_l = try zeroed(gpa, max_delay);
        errdefer gpa.free(delay_l);
        const delay_r = try zeroed(gpa, max_delay);
        errdefer gpa.free(delay_r);
        const flanger_l = try zeroed(gpa, max_flanger);
        errdefer gpa.free(flanger_l);
        const flanger_r = try zeroed(gpa, max_flanger);
        errdefer gpa.free(flanger_r);
        const chorus_l = try zeroed(gpa, max_chorus);
        errdefer gpa.free(chorus_l);
        const chorus_r = try zeroed(gpa, max_chorus);
        errdefer gpa.free(chorus_r);
        const rev_l = try zeroed(gpa, reverb_len);
        errdefer gpa.free(rev_l);
        const rev_r = try zeroed(gpa, reverb_len);
        var fx: FxProcessor = .{
            .settings = .{},
            .sample_rate = sample_rate,
            .delay_l = delay_l,
            .delay_r = delay_r,
            .delay_pos = 0,
            .delay_samples = 1,
            .flanger_l = flanger_l,
            .flanger_r = flanger_r,
            .flanger_pos = 0,
            .flanger_phase = 0.0,
            .chorus_l = chorus_l,
            .chorus_r = chorus_r,
            .chorus_pos = 0,
            .chorus_phase = 0.0,
            .rev_l = rev_l,
            .rev_r = rev_r,
            .rev_pos = .{ 0, 0, 0, 0 },
            .rev_len = .{ 1, 1, 1, 1 },
        };
        fx.recomputeCachedLengths();
        return fx;
    }

    pub fn deinit(self: *FxProcessor, gpa: std.mem.Allocator) void {
        gpa.free(self.delay_l);
        gpa.free(self.delay_r);
        gpa.free(self.flanger_l);
        gpa.free(self.flanger_r);
        gpa.free(self.chorus_l);
        gpa.free(self.chorus_r);
        gpa.free(self.rev_l);
        gpa.free(self.rev_r);
        self.* = undefined;
    }

    pub fn setSettings(self: *FxProcessor, settings: FxSettings) void {
        self.settings = settings;
        self.recomputeCachedLengths();
    }

    pub fn process(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.active()) return .{ .left = left, .right = right };
        const a = self.processFlanger(left, right);
        const b = self.processChorus(a.left, a.right);
        const c = self.processPingpong(b.left, b.right);
        return self.processReverb(c.left, c.right);
    }

    fn recomputeCachedLengths(self: *FxProcessor) void {
        self.delay_samples = toUsize(fclamp(
            @round(self.settings.delay_time_secs * self.sample_rate),
            1.0,
            @floatFromInt(self.delay_l.len - 1),
        ));
        const taps = [4]f32{ 0.029, 0.041, 0.053, 0.071 };
        const hi = @max(self.rev_l.len -| 1, 1);
        for (taps, 0..) |tap, i| {
            self.rev_len[i] = std.math.clamp(toUsize(@round(self.sample_rate * tap)), 1, hi);
            self.rev_pos[i] %= self.rev_len[i];
        }
    }

    fn processFlanger(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.flanger_enabled) return .{ .left = left, .right = right };
        const s = self.settings;
        const lfo = 0.5 + 0.5 * @sin(self.flanger_phase);
        const base = s.flanger_delay_ms * self.sample_rate * 0.001;
        const sweep = base * s.flanger_depth;
        const delay = fclamp(base + sweep * (lfo - 0.5) * 2.0, 1.0, @as(f32, @floatFromInt(self.flanger_l.len)) - 2.0);
        const wet_l = readDelay(self.flanger_l, self.flanger_pos, delay);
        const wet_r = readDelay(self.flanger_r, self.flanger_pos, delay);
        self.flanger_l[self.flanger_pos] = fclamp(left + wet_l * s.flanger_feedback, -1.0, 1.0);
        self.flanger_r[self.flanger_pos] = fclamp(right + wet_r * s.flanger_feedback, -1.0, 1.0);
        self.flanger_pos = (self.flanger_pos + 1) % self.flanger_l.len;
        self.flanger_phase = advanceLfo(self.flanger_phase, s.flanger_rate_hz, self.sample_rate);
        const dry = 1.0 - s.flanger_mix;
        return .{
            .left = fclamp(left * dry + wet_l * s.flanger_mix, -1.0, 1.0),
            .right = fclamp(right * dry + wet_r * s.flanger_mix, -1.0, 1.0),
        };
    }

    fn processChorus(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.chorus_enabled) return .{ .left = left, .right = right };
        const s = self.settings;
        const lfo_l = 0.5 + 0.5 * @sin(self.chorus_phase);
        const lfo_r = 0.5 + 0.5 * @sin(self.chorus_phase + PI * 0.67);
        const base = s.chorus_delay_ms * self.sample_rate * 0.001;
        const sweep = base * s.chorus_depth * 0.75;
        const delay_l = fclamp(base + sweep * (lfo_l - 0.5) * 2.0, 1.0, @as(f32, @floatFromInt(self.chorus_l.len)) - 2.0);
        const delay_r = fclamp(base + sweep * (lfo_r - 0.5) * 2.0, 1.0, @as(f32, @floatFromInt(self.chorus_r.len)) - 2.0);
        const wet_l = readDelay(self.chorus_l, self.chorus_pos, delay_l);
        const wet_r = readDelay(self.chorus_r, self.chorus_pos, delay_r);
        self.chorus_l[self.chorus_pos] = left;
        self.chorus_r[self.chorus_pos] = right;
        self.chorus_pos = (self.chorus_pos + 1) % self.chorus_l.len;
        self.chorus_phase = advanceLfo(self.chorus_phase, s.chorus_rate_hz, self.sample_rate);
        const dry = 1.0 - s.chorus_mix;
        return .{
            .left = fclamp(left * dry + wet_l * s.chorus_mix, -1.0, 1.0),
            .right = fclamp(right * dry + wet_r * s.chorus_mix, -1.0, 1.0),
        };
    }

    fn processPingpong(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.delay_enabled) return .{ .left = left, .right = right };
        const s = self.settings;
        const n = self.delay_l.len;
        const read = (self.delay_pos + n - self.delay_samples) % n;
        const dl = self.delay_l[read];
        const dr = self.delay_r[read];
        self.delay_l[self.delay_pos] = fclamp(left + dr * s.delay_feedback, -1.0, 1.0);
        self.delay_r[self.delay_pos] = fclamp(right + dl * s.delay_feedback, -1.0, 1.0);
        self.delay_pos = (self.delay_pos + 1) % n;
        return .{
            .left = fclamp(left + dl * s.delay_mix, -1.0, 1.0),
            .right = fclamp(right + dr * s.delay_mix, -1.0, 1.0),
        };
    }

    fn processReverb(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.reverb_enabled) return .{ .left = left, .right = right };
        const s = self.settings;
        var wet_l: f32 = 0.0;
        var wet_r: f32 = 0.0;
        // As upstream: only two of the four taps are used.
        for (0..2) |i| {
            const len = self.rev_len[i];
            const pos = self.rev_pos[i];
            const fb_l = self.rev_l[pos];
            const fb_r = self.rev_r[pos];
            wet_l += fb_l;
            wet_r += fb_r;
            self.rev_l[pos] = fclamp(left + fb_r * s.reverb_decay, -1.0, 1.0);
            self.rev_r[pos] = fclamp(right + fb_l * s.reverb_decay, -1.0, 1.0);
            self.rev_pos[i] = if (pos + 1 >= len) 0 else pos + 1;
        }
        wet_l *= 0.5;
        wet_r *= 0.5;
        const dry = 1.0 - s.reverb_mix;
        return .{
            .left = fclamp(left * dry + wet_l * s.reverb_mix, -1.0, 1.0),
            .right = fclamp(right * dry + wet_r * s.reverb_mix, -1.0, 1.0),
        };
    }
};

/// A short FIR cabinet stage on the live input (the Rust `CabinetProcessor`). All three impulse
/// responses and the longest history are allocated by `init`; `setModel` and `process` never
/// allocate.
pub const CabinetProcessor = struct {
    impulses: [3][]f32,
    history_buf: []f32,
    /// The active model's history: `history_buf[0..impulses[model].len]`.
    history: []f32,
    pos: usize = 0,
    model: CabinetModel = .vintage,

    pub fn init(gpa: std.mem.Allocator, sample_rate: f32) error{OutOfMemory}!CabinetProcessor {
        var impulses: [3][]f32 = undefined;
        var made: usize = 0;
        errdefer for (impulses[0..made]) |imp| gpa.free(imp);
        var longest: usize = 0;
        inline for (.{ CabinetModel.vintage, CabinetModel.modern, CabinetModel.open }, 0..) |m, k| {
            impulses[k] = try cabinetImpulse(gpa, m, sample_rate);
            made += 1;
            longest = @max(longest, impulses[k].len);
        }
        const buf = try zeroed(gpa, longest);
        return .{ .impulses = impulses, .history_buf = buf, .history = buf[0..impulses[0].len] };
    }

    pub fn deinit(self: *CabinetProcessor, gpa: std.mem.Allocator) void {
        for (self.impulses) |imp| gpa.free(imp);
        gpa.free(self.history_buf);
    }

    fn impulse(self: *const CabinetProcessor) []const f32 {
        return self.impulses[@intFromEnum(self.model)];
    }

    /// Selects a model; a new model starts from silence, as upstream's `set_model`.
    pub fn setModel(self: *CabinetProcessor, model: CabinetModel) void {
        if (self.model == model) return;
        self.model = model;
        self.history = self.history_buf[0..self.impulse().len];
        @memset(self.history, 0.0);
        self.pos = 0;
    }

    pub fn process(self: *CabinetProcessor, input: f32, settings: FxSettings) f32 {
        if (!settings.cabinet_enabled) return input;
        self.history[self.pos] = input;
        var wet: f32 = 0.0;
        var read = self.pos;
        for (self.impulse()) |coefficient| {
            wet += self.history[read] * coefficient;
            read = if (read == 0) self.history.len - 1 else read - 1;
        }
        self.pos = (self.pos + 1) % self.history.len;
        return input * (1.0 - settings.cabinet_mix) + wet * settings.cabinet_mix;
    }
};

/// The Rust `cabinet_impulse`: a damped resonance through a one-pole low-pass and high-pass,
/// faded out over the 6 ms response and peak-normalized. Caller owns the result.
fn cabinetImpulse(gpa: std.mem.Allocator, model: CabinetModel, sample_rate: f32) error{OutOfMemory}![]f32 {
    const p: [4]f32 = switch (model) {
        .vintage => .{ 85.0, 5_200.0, 115.0, 32.0 },
        .modern => .{ 105.0, 6_400.0, 145.0, 42.0 },
        .open => .{ 70.0, 7_200.0, 92.0, 25.0 },
    };
    const low_hz = p[0];
    const high_hz = p[1];
    const resonance = p[2];
    const damping = p[3];
    const sr = @max(sample_rate, 8_000.0);
    const len = std.math.clamp(toUsize(@round(sr * 0.006)), 64, 384);
    const out = try gpa.alloc(f32, len);
    var previous_lp: f32 = 0.0;
    const lp_alpha = 1.0 - @exp(-2.0 * PI * high_hz / sr);
    const hp_decay = @exp(-2.0 * PI * low_hz / sr);
    var hp_state: f32 = 0.0;
    for (out, 0..) |*o, n| {
        const t = @as(f32, @floatFromInt(n)) / sr;
        const delta: f32 = if (n == 0) 1.0 else 0.0;
        const excitation = delta + @sin(2.0 * PI * resonance * t) * @exp(-damping * t) * 0.22;
        previous_lp += lp_alpha * (excitation - previous_lp);
        const high_passed = previous_lp - hp_state;
        hp_state = previous_lp + hp_decay * high_passed;
        o.* = high_passed * @exp(-70.0 * t);
    }
    var peak: f32 = 1e-6;
    for (out) |v| peak = @max(peak, @abs(v));
    for (out) |*v| v.* /= peak;
    return out;
}

fn zeroed(gpa: std.mem.Allocator, n: usize) error{OutOfMemory}![]f32 {
    const buf = try gpa.alloc(f32, n);
    @memset(buf, 0.0);
    return buf;
}

fn advanceLfo(phase: f32, rate_hz: f32, sample_rate: f32) f32 {
    const next = phase + TAU * rate_hz / @max(sample_rate, 1.0);
    return if (next >= TAU) next - TAU else next;
}

fn readDelay(buf: []const f32, write_pos: usize, delay_samples: f32) f32 {
    const len = buf.len;
    var read = @as(f32, @floatFromInt(write_pos)) - delay_samples;
    if (read < 0.0) read += @floatFromInt(len);
    const idx0 = toUsize(@floor(read)) % len;
    const idx1 = (idx0 + 1) % len;
    const frac = read - @floor(read);
    return buf[idx0] * (1.0 - frac) + buf[idx1] * frac;
}

test "modulation_effects_produce_delayed_output" {
    var settings = FxSettings.default();
    settings.flanger_enabled = true;
    settings.chorus_enabled = true;
    var fx = try FxProcessor.init(std.testing.allocator, 48_000.0);
    defer fx.deinit(std.testing.allocator);
    fx.setSettings(settings);

    var peak: f32 = 0.0;
    for (0..2_000) |sample| {
        const input: f32 = if (sample == 0) 1.0 else 0.0;
        const out = fx.process(input, input);
        if (sample > 10) peak = @max(peak, @max(@abs(out.left), @abs(out.right)));
    }
    try std.testing.expect(peak > 0.001);
}

test "reverb and pingpong stay bounded and settings advance within range" {
    var settings = FxSettings.default();
    settings.reverb_enabled = true;
    settings.delay_enabled = true;
    settings.reverb_decay_step_per_tick = 1.0;
    settings.delay_time_step_per_tick = -5.0;
    var fx = try FxProcessor.init(std.testing.allocator, 44_100.0);
    defer fx.deinit(std.testing.allocator);
    fx.setSettings(settings);
    for (0..20_000) |i| {
        const x: f32 = if (i % 100 == 0) 1.0 else 0.0;
        const out = fx.process(x, -x);
        try std.testing.expect(@abs(out.left) <= 1.0 and @abs(out.right) <= 1.0);
    }
    settings.advanceTick();
    try std.testing.expectEqual(@as(f32, 0.98), settings.reverb_decay);
    try std.testing.expectEqual(@as(f32, 0.01), settings.delay_time_secs);
}

test "cabinet_is_bypassed_or_convolves_without_allocating" {
    var cabinet = try CabinetProcessor.init(std.testing.allocator, 48_000.0);
    defer cabinet.deinit(std.testing.allocator);
    var settings = FxSettings.default();
    try std.testing.expectEqual(@as(f32, 0.25), cabinet.process(0.25, settings));

    settings.cabinet_enabled = true;
    settings.cabinet_mix = 1.0;
    const first = cabinet.process(1.0, settings);
    const tail = cabinet.process(0.0, settings);
    try std.testing.expect(std.math.isFinite(first) and @abs(first) > 0.01);
    try std.testing.expect(std.math.isFinite(tail) and @abs(tail) > 0.0001);
}

test "a cabinet model change starts from silence and needs no allocation" {
    var cabinet = try CabinetProcessor.init(std.testing.allocator, 48_000.0);
    defer cabinet.deinit(std.testing.allocator);
    var settings = FxSettings.default();
    settings.cabinet_enabled = true;
    _ = cabinet.process(1.0, settings);
    // 6 ms at 48 kHz is 288 taps for every model; the response is peak-normalized
    try std.testing.expectEqual(@as(usize, 288), cabinet.history.len);
    var peak: f32 = 0;
    for (cabinet.impulse()) |v| peak = @max(peak, @abs(v));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), peak, 1e-6);
    cabinet.setModel(.modern);
    try std.testing.expectEqual(@as(usize, 0), cabinet.pos);
    for (cabinet.history) |h| try std.testing.expectEqual(@as(f32, 0), h);
    try std.testing.expectEqual(CabinetModel.open, CabinetModel.parse("1X12").?);
    try std.testing.expectEqual(@as(?CabinetModel, null), CabinetModel.parse("8x10"));
}
