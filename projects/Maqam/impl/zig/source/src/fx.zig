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
    reverb: Reverb,

    /// The Rust `FxProcessor::new`. Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, sample_rate_in: f32) error{OutOfMemory}!FxProcessor {
        const sample_rate = @max(sample_rate_in, 1.0);
        const max_delay = toUsize(@ceil(sample_rate * 2.0)) +| 1;
        const max_flanger = toUsize(@ceil(sample_rate * 0.025)) +| 4;
        const max_chorus = toUsize(@ceil(sample_rate * 0.060)) +| 4;
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
        const reverb = try Reverb.init(gpa, sample_rate);
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
            .reverb = reverb,
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
        self.reverb.deinit(gpa);
        self.* = undefined;
    }

    pub fn setSettings(self: *FxProcessor, settings: FxSettings) void {
        self.settings = settings;
        self.recomputeCachedLengths();
    }

    pub fn process(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.active()) {
            self.reverb.running = false; // off, even though processReverb is skipped
            return .{ .left = left, .right = right };
        }
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
        self.reverb.setDecay(self.settings.reverb_decay);
    }

    /// Silences every effect's memory and returns to the default settings (the engine's Clear).
    pub fn reset(self: *FxProcessor) void {
        inline for (.{ "delay_l", "delay_r", "flanger_l", "flanger_r", "chorus_l", "chorus_r" }) |name| {
            @memset(@field(self, name), 0.0);
        }
        self.delay_pos = 0;
        self.delay_samples = 1;
        self.flanger_pos = 0;
        self.flanger_phase = 0.0;
        self.chorus_pos = 0;
        self.chorus_phase = 0.0;
        self.reverb.clear();
        self.setSettings(.{});
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

    /// The specification's reverb (markdown `reverb`), not upstream's: the wet signal from
    /// `Reverb`, crossfaded by mix; this final clamp is the reverb's only one.
    fn processReverb(self: *FxProcessor, left: f32, right: f32) Stereo {
        if (!self.settings.reverb_enabled) {
            self.reverb.running = false;
            return .{ .left = left, .right = right };
        }
        const s = self.settings;
        if (!self.reverb.running) {
            self.reverb.clear();
            self.reverb.running = true;
        }
        // Per-tick decay steps change settings.reverb_decay; setDecay returns at once if unchanged.
        self.reverb.setDecay(s.reverb_decay);
        const wet = self.reverb.process(left, right);
        const dry = 1.0 - s.reverb_mix;
        return .{
            .left = fclamp(left * dry + wet.left * s.reverb_mix, -1.0, 1.0),
            .right = fclamp(right * dry + wet.right * s.reverb_mix, -1.0, 1.0),
        };
    }
};

/// Every value written into reverb state below this magnitude becomes 0 (no subnormal floats).
const flush_below: f32 = 1e-15;

fn flush(x: f32) f32 {
    return if (@abs(x) < flush_below) 0.0 else x;
}

/// The decay-to-T60 map of the specification: 0.25 s at decay 0, 4 s at 0.98.
pub fn reverbT60(decay: f32) f32 {
    return 0.25 * std.math.pow(f32, 16.0, decay / 0.98);
}

/// The specification's reverb (spec/Requirements.lean, markdown `reverb`): two one-pole
/// high-passes at 120 Hz and four allpass diffusers per channel, then an eight-line tank with a
/// Householder feedback matrix, per-line decay gains and a one-pole damping low-pass at 5 kHz.
/// `process` returns the wet pair only; it is linear (no clamp) and never allocates. All delay
/// memory is one buffer allocated by `init`, cut into disjoint lines.
pub const Reverb = struct {
    pub const line_ms = [8]f32{ 29.7, 37.1, 41.1, 43.7, 53.3, 59.9, 67.7, 73.3 };
    pub const allpass_ms = [4]f32{ 4.77, 3.59, 12.73, 9.31 };
    pub const right_stretch: f32 = 1.07;
    pub const allpass_gain: f32 = 0.6;
    pub const highpass_hz: f32 = 120.0;
    pub const damping_hz: f32 = 5000.0;

    const V = @Vector(8, f32);
    /// Lanes fed by the left input (even lines); the others are fed by the right.
    const even: @Vector(8, bool) = .{ true, false, true, false, true, false, true, false };

    /// A delay of `buf.len` samples: `buf[pos]` is the sample written `buf.len` samples ago.
    const Line = struct {
        buf: []f32,
        pos: usize = 0,

        inline fn read(self: *const Line) f32 {
            return self.buf[self.pos];
        }

        inline fn write(self: *Line, v: f32) void {
            self.buf[self.pos] = v;
            self.pos = if (self.pos + 1 >= self.buf.len) 0 else self.pos + 1;
        }
    };

    storage: []f32,
    lines: [8]Line,
    allpasses: [2][4]Line,
    /// Damped line outputs z_i.
    z: V = @splat(0.0),
    /// Per channel: input of stage 1, output of stage 1, output of stage 2 (stage 2's input is
    /// stage 1's output, so x', y1', y2').
    hp: [2][3]f32 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } },
    gains: V = @splat(0.0),
    wet_gain: f32 = 0.0,
    decay: f32 = std.math.nan(f32),
    hp_a: f32,
    damp_c: f32,
    sample_rate: f32,
    /// Whether it ran in the previous sample; turning it on clears it first.
    running: bool = false,

    fn samples(ms: f32, sample_rate: f32) usize {
        return @max(toUsize(@round(ms * sample_rate / 1000.0)), 1);
    }

    pub fn init(gpa: std.mem.Allocator, sample_rate_in: f32) error{OutOfMemory}!Reverb {
        const sr = @max(sample_rate_in, 1.0);
        var total: usize = 0;
        for (line_ms) |ms| total += samples(ms, sr);
        for (allpass_ms) |ms| total += samples(ms, sr) + samples(ms * right_stretch, sr);
        const storage = try zeroed(gpa, total);
        var at: usize = 0;
        var r: Reverb = .{
            .storage = storage,
            .lines = undefined,
            .allpasses = undefined,
            .hp_a = @exp(-2.0 * PI * highpass_hz / sr),
            .damp_c = 1.0 - @exp(-2.0 * PI * damping_hz / sr),
            .sample_rate = sr,
        };
        for (line_ms, 0..) |ms, i| {
            const n = samples(ms, sr);
            r.lines[i] = .{ .buf = storage[at..][0..n] };
            at += n;
        }
        for (allpass_ms, 0..) |ms, k| {
            inline for (.{ 1.0, right_stretch }, 0..) |stretch, ch| {
                const n = samples(ms * stretch, sr);
                r.allpasses[ch][k] = .{ .buf = storage[at..][0..n] };
                at += n;
            }
        }
        std.debug.assert(at == total);
        r.setDecay(0.65);
        return r;
    }

    pub fn deinit(self: *Reverb, gpa: std.mem.Allocator) void {
        gpa.free(self.storage);
        self.* = undefined;
    }

    /// Silence: no tail, no filter memory. Never allocates.
    pub fn clear(self: *Reverb) void {
        @memset(self.storage, 0.0);
        for (&self.lines) |*l| l.pos = 0;
        for (&self.allpasses) |*chan| for (chan) |*a| {
            a.pos = 0;
        };
        self.z = @splat(0.0);
        self.hp = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    }

    /// Recomputes the per-line gains and the wet gain for `decay`; returns at once if unchanged.
    pub fn setDecay(self: *Reverb, decay: f32) void {
        if (decay == self.decay) return;
        self.decay = decay;
        const t60 = reverbT60(fclamp(decay, 0.0, 0.98));
        var gains: [8]f32 = undefined;
        for (self.lines, &gains) |l, *g| {
            const d: f32 = @floatFromInt(l.buf.len);
            g.* = std.math.pow(f32, 10.0, -3.0 * d / (self.sample_rate * t60));
        }
        self.gains = gains;
        self.wet_gain = 0.6 / @sqrt(t60);
    }

    fn highpass(self: *Reverb, ch: usize, x: f32) f32 {
        const h = &self.hp[ch];
        const y1 = flush(self.hp_a * (h[1] + x - h[0]));
        const y2 = flush(self.hp_a * (h[2] + y1 - h[1]));
        h[0] = flush(x);
        h[1] = y1;
        h[2] = y2;
        return y2;
    }

    fn diffuse(self: *Reverb, ch: usize, x: f32) f32 {
        var v = x;
        for (&self.allpasses[ch]) |*a| {
            const b = a.read();
            const w = v + allpass_gain * b;
            v = b - allpass_gain * w;
            a.write(flush(w));
        }
        return v;
    }

    /// One stereo sample in, the wet pair out.
    pub fn process(self: *Reverb, left: f32, right: f32) Stereo {
        const il = self.diffuse(0, self.highpass(0, left));
        const ir = self.diffuse(1, self.highpass(1, right));
        var s: V = undefined;
        inline for (0..8) |i| s[i] = self.lines[i].read();
        const zero: V = @splat(0.0);
        const tiny: V = @splat(flush_below);
        var z = self.z + @as(V, @splat(self.damp_c)) * (self.gains * s - self.z);
        z = @select(f32, @abs(z) < tiny, zero, z);
        self.z = z;
        const mean: V = @splat(@reduce(.Add, z) * 0.25);
        const inject = @select(f32, even, @as(V, @splat(il)), @as(V, @splat(ir)));
        var fb = z - mean + inject;
        fb = @select(f32, @abs(fb) < tiny, zero, fb);
        inline for (0..8) |i| self.lines[i].write(fb[i]);
        const evens = @select(f32, even, z, zero);
        const sum_l = @reduce(.Add, evens);
        const sum_r = @reduce(.Add, z) - sum_l;
        return .{ .left = self.wet_gain * sum_l, .right = self.wet_gain * sum_r };
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

/// The wet impulse response of a fresh reverb (`amp` into both channels at sample 0).
fn reverbImpulse(gpa: std.mem.Allocator, sr: f32, decay: f32, amp: f32, n: usize) ![2][]f32 {
    var r = try Reverb.init(gpa, sr);
    defer r.deinit(gpa);
    r.setDecay(decay);
    const l = try gpa.alloc(f32, n);
    errdefer gpa.free(l);
    const rr = try gpa.alloc(f32, n);
    for (0..n) |t| {
        const x: f32 = if (t == 0) amp else 0.0;
        const w = r.process(x, x);
        l[t] = w.left;
        rr[t] = w.right;
    }
    return .{ l, rr };
}

fn rmsOf(xs: []const f32) f64 {
    var acc: f64 = 0;
    for (xs) |x| acc += @as(f64, x) * x;
    return @sqrt(acc / @as(f64, @floatFromInt(@max(xs.len, 1))));
}

fn dbOf(ratio: f64) f64 {
    return 20.0 * std.math.log10(@max(ratio, 1e-30));
}

test "reverb tail follows its decay" {
    const gpa = std.testing.allocator;
    const sr: f32 = 48_000.0;
    const w: usize = 2400; // 50 ms
    for ([_]f32{ 0.0, 0.65 }) |decay| {
        const t60 = reverbT60(decay);
        const n = toUsize(sr * t60 * 1.5) + w + 1;
        const ir = try reverbImpulse(gpa, sr, decay, 1.0, n);
        defer gpa.free(ir[0]);
        defer gpa.free(ir[1]);
        const early = rmsOf(ir[0][1440..][0..w]); // 30..80 ms
        const half = rmsOf(ir[0][toUsize(sr * t60 * 0.5)..][0..w]);
        const late = rmsOf(ir[0][toUsize(sr * t60 * 1.5)..][0..w]);
        try std.testing.expect(dbOf(late / early) <= -60.0);
        try std.testing.expect(dbOf(half / early) > -60.0);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), reverbT60(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), reverbT60(0.98), 1e-5);
}

test "reverb is dense and wide" {
    const gpa = std.testing.allocator;
    const ir = try reverbImpulse(gpa, 48_000.0, 0.65, 1.0, 9600);
    defer gpa.free(ir[0]);
    defer gpa.free(ir[1]);
    const l = ir[0][4800..9600];
    const r = ir[1][4800..9600];
    for (l, r) |a, b| try std.testing.expect(a != 0.0 and b != 0.0);
    var ml: f64 = 0;
    var mr: f64 = 0;
    for (l, r) |a, b| {
        ml += a;
        mr += b;
    }
    ml /= @floatFromInt(l.len);
    mr /= @floatFromInt(r.len);
    var sab: f64 = 0;
    var saa: f64 = 0;
    var sbb: f64 = 0;
    for (l, r) |a, b| {
        const da = a - ml;
        const db = b - mr;
        sab += da * db;
        saa += da * da;
        sbb += db * db;
    }
    const rho = sab / @sqrt(saa * sbb);
    try std.testing.expect(@abs(rho) < 0.3);
}

test "reverb is linear" {
    const gpa = std.testing.allocator;
    const full = try reverbImpulse(gpa, 48_000.0, 0.98, 1.0, 24_000);
    defer gpa.free(full[0]);
    defer gpa.free(full[1]);
    const half = try reverbImpulse(gpa, 48_000.0, 0.98, 0.5, 24_000);
    defer gpa.free(half[0]);
    defer gpa.free(half[1]);
    var peak: f32 = 0;
    for (full[0], half[0], full[1], half[1]) |a, b, c, d| {
        peak = @max(peak, @abs(a));
        // Halving the input halves every sample (exactly, up to rounding and the flush to 0).
        try std.testing.expectApproxEqAbs(a * 0.5, b, 1e-6 + @abs(a) * 1e-5);
        try std.testing.expectApproxEqAbs(c * 0.5, d, 1e-6 + @abs(c) * 1e-5);
    }
    try std.testing.expect(peak > 0.01);
    var r = try Reverb.init(gpa, 48_000.0);
    defer r.deinit(gpa);
    r.setDecay(0.98);
    const gains: [8]f32 = r.gains;
    for (gains) |g| try std.testing.expect(g > 0.0 and g < 1.0);
    // The lines and allpasses are disjoint slices of one buffer.
    var covered: usize = 0;
    for (r.lines) |l| covered += l.buf.len;
    for (r.allpasses) |chan| for (chan) |a| {
        covered += a.buf.len;
    };
    try std.testing.expectEqual(r.storage.len, covered);
}

test "reverb keeps the low end dry" {
    const gpa = std.testing.allocator;
    const sr: f32 = 48_000.0;
    var levels: [2]f64 = undefined;
    for ([_]f32{ 40.0, 1000.0 }, 0..) |hz, k| {
        var r = try Reverb.init(gpa, sr);
        defer r.deinit(gpa);
        r.setDecay(0.65);
        var acc: f64 = 0;
        const n: usize = 48_000;
        for (0..n) |t| {
            const x = 0.5 * @sin(2.0 * PI * hz * @as(f32, @floatFromInt(t)) / sr);
            const w = r.process(x, x);
            if (t >= n / 2) acc += @as(f64, w.left) * w.left;
        }
        levels[k] = @sqrt(acc / @as(f64, n / 2));
    }
    try std.testing.expect(dbOf(levels[0] / levels[1]) <= -12.0);
}

test "reverb state fades to exact zero" {
    const gpa = std.testing.allocator;
    var r = try Reverb.init(gpa, 48_000.0);
    defer r.deinit(gpa);
    r.setDecay(0.0);
    _ = r.process(1.0, -1.0);
    for (0..48_000 * 4) |_| _ = r.process(0.0, 0.0);
    for (r.storage) |v| try std.testing.expect(v == 0.0 or @abs(v) >= flush_below);
    const z: [8]f32 = r.z;
    for (z) |v| try std.testing.expect(v == 0.0 or @abs(v) >= flush_below);
    for (r.hp) |h| for (h) |v| try std.testing.expect(v == 0.0 or @abs(v) >= flush_below);
    // After 4 s at T60 = 0.25 s (-960 dB) everything has been flushed.
    for (r.storage) |v| try std.testing.expectEqual(@as(f32, 0.0), v);
}

test "turning the reverb on starts from silence" {
    var fx = try FxProcessor.init(std.testing.allocator, 48_000.0);
    defer fx.deinit(std.testing.allocator);
    var settings = FxSettings.default();
    settings.reverb_enabled = true;
    settings.reverb_mix = 1.0;
    settings.reverb_decay = 0.98;
    fx.setSettings(settings);
    _ = fx.process(1.0, 1.0);
    for (0..4800) |_| _ = fx.process(0.0, 0.0);
    try std.testing.expect(@abs(fx.process(0.0, 0.0).left) > 1e-4); // a tail is ringing
    settings.reverb_enabled = false;
    fx.setSettings(settings);
    _ = fx.process(0.0, 0.0);
    settings.reverb_enabled = true;
    fx.setSettings(settings);
    for (0..4800) |_| try std.testing.expectEqual(@as(f32, 0.0), fx.process(0.0, 0.0).left);
    // The Clear before a load silences it too.
    _ = fx.process(1.0, 1.0);
    for (0..4800) |_| _ = fx.process(0.0, 0.0);
    fx.reset();
    settings.reverb_enabled = true;
    fx.setSettings(settings);
    for (0..4800) |_| try std.testing.expectEqual(@as(f32, 0.0), fx.process(0.0, 0.0).right);
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
