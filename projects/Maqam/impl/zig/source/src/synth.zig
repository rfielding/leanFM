//! Port of maqam-live `src/synth.rs`: the shared PRNG (`nextU64`, `randF32`, `randF3201`,
//! `randBool`, `randRange`), group-level degree expansion (`zigzagWalk`, `expandDegrees`), melody
//! evolution (`evolveBar`), the voices (`VoiceKind`, `Voice`) and voice spawning (`Milestone`,
//! `spawnVoices`, `spawnPhraseStart`, `spawnSubBass`).
//!
//! The audio output path calls `evolveBar` and the spawn functions, and it must never allocate or
//! free. So:
//! * `evolveBar` rewrites the bar in place (`zigzagWalkInto`, `Bar.recomputeEvents`); the lengths
//!   of `group_degrees`, `degrees` and `events` are fixed when the phrase is built and evolution
//!   never changes them. `zigzagWalk` / `expandDegrees` (the allocating Rust shapes) remain for
//!   building phrases off the audio path.
//! * The spawn functions append to a `VoiceList` (an unmanaged `std.ArrayList(Voice)`) with
//!   `appendBounded`: the owner reserves capacity up front (`voice_capacity` is plenty) and a voice
//!   that does not fit is dropped instead of growing the list.
//!
//! Deliberate differences from the Rust:
//! * `seedRng(seed)` (new) resets the PRNG so an offline render is deterministic (property
//!   "Renders are deterministic"); the initial state is `default_seed`, the Rust's
//!   `0xdeadbeef_cafef00d`.
//! * Voices beyond the list's reserved capacity are dropped (above), where the Rust grows its Vec.
//! * `evolveBar` clamps with `max(lo, min(x, hi))`, so a scale of one note cannot trap where Rust's
//!   `i32::clamp(1, 0)` would panic, and it keeps every waypoint inside the scale; for scales of two
//!   or more notes (`buildPhrase` accepts only three or more) the result is identical to the Rust.
const std = @import("std");
const sequencer = @import("sequencer.zig");
const vcf = @import("vcf.zig");

const Bar = sequencer.Bar;
const SubdivEvent = sequencer.SubdivEvent;
const VcoWave = vcf.VcoWave;
const TAU: f64 = std.math.tau;

// ── PRNG ─────────────────────────────────────────────────────────────────────

/// The Rust's initial PRNG state.
pub const default_seed: u64 = 0xdeadbeef_cafef00d;

var rng: std.atomic.Value(u64) = .init(default_seed);

/// Reset the PRNG to `seed` (`default_seed` reproduces a fresh Rust process).
pub fn seedRng(seed: u64) void {
    rng.store(seed, .monotonic);
}

pub fn nextU64() u64 {
    const s = rng.fetchAdd(6_364_136_223_846_793_005, .monotonic) *% 2_862_933_555_777_941_757 +% 3_037_000_493;
    rng.store(s, .monotonic);
    return s;
}

pub fn randF32() f32 {
    return @as(f32, @floatFromInt(nextU64() >> 33)) / @as(f32, @floatFromInt(@as(u32, 1) << 31)) - 1.0;
}

pub fn randF3201() f32 {
    return @as(f32, @floatFromInt(nextU64() >> 33)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Name matching the Rust `rand_f32_01` more literally.
pub const randF32_01 = randF3201;

pub fn randBool(p: f32) bool {
    return randF3201() < p;
}

pub fn randRange(lo: usize, hi: usize) usize {
    if (lo >= hi) return lo;
    return lo + @as(usize, @truncate(nextU64())) % (hi - lo);
}

// ── Group-level degree expansion ──────────────────────────────────────────────

/// Length of `zigzagWalk(n_groups, _)`.
pub fn zigzagLen(n_groups: usize) usize {
    return if (n_groups == 0) 1 else n_groups + 1;
}

/// `zigzagWalk` into `out` (`out.len` must be `zigzagLen(n_groups)`; otherwise nothing is
/// written and false is returned). Never allocates.
pub fn zigzagWalkInto(out: []usize, n_groups: usize, peak_in: usize) bool {
    if (out.len != zigzagLen(n_groups)) return false;
    const peak = @min(peak_in, 4);
    if (n_groups == 0) {
        out[0] = 0;
        return true;
    }
    @memset(out, 0);
    var i: usize = 1;
    while (i < n_groups) : (i += 1) {
        out[i] = if (i % 2 == 1) peak else @max(peak / 2, 1);
    }
    if (n_groups == 1) out[1] = peak;
    out[out.len - 1] = 0;
    return true;
}

/// The Rust `zigzag_walk`; caller owns the result.
pub fn zigzagWalk(gpa: std.mem.Allocator, n_groups: usize, peak: usize) error{OutOfMemory}![]usize {
    const w = try gpa.alloc(usize, zigzagLen(n_groups));
    _ = zigzagWalkInto(w, n_groups, peak);
    return w;
}

/// Length of `expandDegrees(_, groups)` (a group of 0 still contributes its starting waypoint).
pub fn expandDegreesLen(groups: []const u8) usize {
    var n: usize = 0;
    for (groups) |g| n += @max(@as(usize, g), 1);
    return n;
}

/// `expandDegrees` into `out`; writes at most `out.len` entries and returns how many it wrote.
pub fn expandDegreesInto(out: []usize, waypoints: []const usize, groups: []const u8) usize {
    var n: usize = 0;
    for (groups, 0..) |g, gi| {
        const from: usize = if (gi < waypoints.len) waypoints[gi] else 0;
        const to: usize = if (gi + 1 < waypoints.len) waypoints[gi + 1] else from;
        if (n >= out.len) return n;
        out[n] = from;
        n += 1;
        var s: usize = 1;
        while (s < g) : (s += 1) {
            const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(g));
            const fromf: f64 = @floatFromInt(from);
            const d = fromf + t * (@as(f64, @floatFromInt(to)) - fromf);
            if (n >= out.len) return n;
            out[n] = @min(roundToUsize(d), 7);
            n += 1;
        }
    }
    return n;
}

/// The Rust `expand_degrees`; caller owns the result.
pub fn expandDegrees(gpa: std.mem.Allocator, waypoints: []const usize, groups: []const u8) error{OutOfMemory}![]usize {
    const out = try gpa.alloc(usize, expandDegreesLen(groups));
    _ = expandDegreesInto(out, waypoints, groups);
    return out;
}

/// Rust `f64::round() as usize` (saturating; NaN and negatives give 0).
fn roundToUsize(x: f64) usize {
    const r = @round(x);
    if (!(r > 0.0)) return 0;
    if (r >= 18446744073709551615.0) return std.math.maxInt(usize);
    return @intFromFloat(r);
}

// ── Evolution ─────────────────────────────────────────────────────────────────

/// `max(lo, min(x, hi))`: Rust `clamp` without its `lo <= hi` assertion.
fn clampSafe(x: i64, lo: i64, hi: i64) i64 {
    return @max(lo, @min(x, hi));
}

/// Mutate a bar's melody for its next pass, in place (never allocates).
pub fn evolveBar(bar: *Bar, is_last_bar: bool) void {
    const n = bar.group_degrees.len;
    const n_freq = bar.frequencies.len;
    if (n < 2 or n_freq == 0) return;

    const mid_freq = @max(n_freq / 2, 1);

    const r = randF3201();
    if (r < 0.08) {
        const peak = randRange(mid_freq -| 1, @min(mid_freq + 2, n_freq - 1));
        _ = zigzagWalkInto(bar.group_degrees, bar.groups.len, peak);
    } else if (r < 0.20) {
        var i: usize = 1;
        while (i < n -| 1) : (i += 1) {
            if (bar.group_degrees[i] > 0) bar.group_degrees[i] = @min(bar.group_degrees[i] + 1, n_freq - 1);
        }
    } else {
        var i: usize = 1;
        while (i < n -| 1) : (i += 1) {
            if (bar.group_degrees[i] > 0 and randBool(0.15)) {
                const shift: i64 = if (randBool(0.5)) 1 else -1;
                const v = clampSafe(@as(i64, @intCast(bar.group_degrees[i])) + shift, 1, @as(i64, @intCast(n_freq)) - 1);
                bar.group_degrees[i] = @intCast(@max(v, 0));
            }
        }
    }

    bar.group_degrees[0] = 0;
    bar.group_degrees[n - 1] = 0;

    if (is_last_bar and n >= 3 and randBool(0.50)) {
        bar.group_degrees[n - 2] = mid_freq;
    }
    // Keep every waypoint inside the scale (a no-op for scales of two or more notes).
    for (bar.group_degrees) |*d| d.* = @min(d.*, n_freq - 1);

    bar.recomputeEvents();
}

// ── Voice ─────────────────────────────────────────────────────────────────────

pub const VoiceKind = enum {
    floor_tom,
    snare,
    crash,
    phrase_change,
    melody_fm,
    sub_bass,
};

/// A list of voices whose capacity the owner reserves; spawning never grows it.
pub const VoiceList = std.ArrayList(Voice);

/// A comfortable capacity for a `VoiceList` (a dense bar spawns well under a hundred).
pub const voice_capacity: usize = 1024;

pub const Voice = struct {
    kind: VoiceKind,
    age: usize,
    freq: f64,
    phase: f64,
    sustain_secs: f64,
    gain_override: ?f32,
    pan: f32,
    release_frames: ?usize,
    done: bool,

    pub fn snare() Voice {
        return mk(.snare, 0.0, 0.0);
    }

    pub fn melody(hz: f64, sus: f64) Voice {
        return mk(.melody_fm, hz, sus);
    }

    pub fn melodyGain(hz: f64, sus: f64, gain: f32) Voice {
        var v = mk(.melody_fm, hz, sus);
        v.gain_override = gain;
        return v;
    }

    pub fn mk(kind: VoiceKind, freq: f64, sustain_secs: f64) Voice {
        return .{
            .kind = kind,
            .age = 0,
            .freq = freq,
            .phase = 0.0,
            .sustain_secs = sustain_secs,
            .gain_override = null,
            .pan = 0.0,
            .release_frames = null,
            .done = false,
        };
    }

    pub fn sampleWithWave(self: *Voice, sr: f64, wave: ?VcoWave) f32 {
        const dt = 1.0 / sr;
        const t = @as(f64, @floatFromInt(self.age)) * dt;

        var osc: f32 = 0.0;
        var amp: f32 = 0.0;
        var fin = false;
        switch (self.kind) {
            .floor_tom => {
                const freq = self.freq * (1.0 + 1.8 * @exp(-t * 12.0));
                self.phase += freq * dt;
                osc = waveSample(self.phase, wave);
                amp = @floatCast(@exp(-t * 7.0));
                fin = t > 0.55;
            },
            .crash => {
                const shimmer_freq = self.freq * 10.0;
                self.phase += shimmer_freq * dt;
                const shimmer: f32 = @floatCast(@sin(self.phase * TAU));
                const noise = randF32();
                osc = noise * 0.7 + shimmer * 0.3;
                amp = if (t < 0.004) @floatCast(t / 0.004) else @floatCast(@exp(-t * 5.0));
                fin = t > 0.80;
            },
            .phrase_change => {
                const freq = self.freq * 3.0 * (1.0 + 1.5 * @exp(-t * 20.0));
                self.phase += freq * dt;
                osc = waveSample(self.phase, wave);
                amp = @floatCast(@exp(-t * 14.0));
                fin = t > 0.25;
            },
            .snare => {
                osc = randF32();
                amp = @floatCast(@exp(-t * 28.0));
                fin = t > 0.14;
            },
            .sub_bass => {
                const sus = self.sustain_secs;
                self.phase += self.freq * dt;
                osc = waveSample(self.phase, wave);
                amp = if (t < 0.10)
                    @floatCast(t / 0.10)
                else if (t < sus)
                    1.0
                else if (t < sus + 0.20)
                    @floatCast(@max(1.0 - (t - sus) / 0.20, 0.0))
                else
                    0.0;
                fin = t > sus + 0.25;
            },
            .melody_fm => {
                const sus = self.sustain_secs;
                self.phase += self.freq * dt;
                const p = self.phase * TAU;
                osc = if (wave) |w|
                    w.sample(self.phase)
                else
                    @as(f32, @floatCast(@sin(p) + @sin(p * 2.0) * 0.25 + @sin(p * 3.0) * 0.10)) / 1.35;
                amp = if (t < 0.015)
                    @floatCast(t / 0.015)
                else if (t < 0.20)
                    @floatCast(1.0 - (t - 0.015) / 0.185 * 0.5)
                else if (t < sus)
                    0.50
                else if (t < sus + 0.5)
                    @floatCast(@max(0.5 * (1.0 - (t - sus) / 0.5), 0.0))
                else
                    0.0;
                fin = t > sus + 0.55;
            },
        }

        self.age += 1;
        if (fin) self.done = true;

        var release_gain: f32 = 1.0;
        if (self.release_frames) |rf| {
            if (rf == 0) {
                self.done = true;
                release_gain = 0.0;
            } else {
                release_gain = @min(@as(f32, @floatFromInt(rf)) / 441.0, 1.0);
                self.release_frames = rf -| 1;
            }
        }

        const gain: f32 = self.gain_override orelse switch (self.kind) {
            .floor_tom => 0.65,
            .snare => 0.28,
            .crash => 0.42,
            .phrase_change => 0.50,
            .melody_fm => 0.20,
            .sub_bass => 0.50,
        };
        var out = osc * amp * gain * release_gain;
        if (out < -1.0) out = -1.0;
        if (out > 1.0) out = 1.0;
        return out;
    }
};

inline fn waveSample(phase: f64, wave: ?VcoWave) f32 {
    if (wave) |w| return w.sample(phase);
    return @floatCast(@sin(phase * TAU));
}

// ── Milestone ─────────────────────────────────────────────────────────────────

/// Structural event this subdivision marks.
pub const Milestone = enum {
    none,
    /// Last beat of last repeat, same phrase loops next.
    turnaround,
    /// Last beat of last repeat, different phrase comes next.
    cross_phrase_warning,
    phrase_start,
    phrase_change,
};

// ── Voice spawning ────────────────────────────────────────────────────────────

fn snapToScale(hz: f64, scale: []const f64) f64 {
    if (scale.len == 0) return hz;
    var best = hz;
    var best_dist = std.math.floatMax(f64);
    for (scale) |f| {
        var octave: i32 = -2;
        while (octave <= 2) : (octave += 1) {
            const candidate = f * std.math.pow(f64, 2.0, @floatFromInt(octave));
            const dist = @abs(std.math.log2(candidate / hz));
            if (dist < best_dist) {
                best_dist = dist;
                best = candidate;
            }
        }
    }
    return best;
}

/// Append without growing: a voice that does not fit the reserved capacity is dropped.
fn push(voices: *VoiceList, v: Voice) void {
    voices.appendBounded(v) catch {};
}

pub fn spawnVoices(
    event: SubdivEvent,
    sustain: f64,
    voices: *VoiceList,
    milestone: Milestone,
    scale: []const f64,
    root_hz: f64,
    subdiv_secs: f64,
) void {
    // Milestone sounds fire regardless of whether the event is a kick or snare.
    switch (milestone) {
        .turnaround => {
            // Same phrase repeating: double kick, no leading tone.
            push(voices, Voice.mk(.floor_tom, 35.0, 0.2));
            // A fourth down.
            const lt_hz = root_hz * 0.5 * 3.0 / 4.0;
            var lt = Voice.mk(.sub_bass, lt_hz, subdiv_secs * 0.5);
            lt.gain_override = 0.45;
            push(voices, lt);
        },
        .cross_phrase_warning => push(voices, Voice.mk(.floor_tom, 60.0, 0.25)),
        .phrase_start => push(voices, Voice.mk(.crash, 400.0, 0.3)),
        .phrase_change => push(voices, Voice.mk(.phrase_change, 60.0, 0.2)),
        .none => {},
    }

    switch (event) {
        .kick => |hz| {
            push(voices, Voice.mk(.floor_tom, 40.0, 0.25));
            push(voices, panned(Voice.melody(hz, sustain)));
            const octave2 = snapToScale(root_hz / 8.0, scale);
            const octave = snapToScale(root_hz / 4.0, scale);
            push(voices, panned(Voice.melodyGain(octave2, sustain * 0.85, 0.1)));
            push(voices, panned(Voice.melodyGain(octave, sustain * 0.20, 0.1)));
            // Root bass on every kick, one octave down, held one subdivision.
            var bass = Voice.mk(.sub_bass, root_hz * 0.5, subdiv_secs * 0.95);
            bass.gain_override = 0.15;
            push(voices, bass);
        },
        .snare => |hz| {
            push(voices, panned(Voice.snare()));
            push(voices, panned(Voice.melody(hz, sustain)));
            const fifth = snapToScale(hz * 1.5, scale);
            push(voices, panned(Voice.melodyGain(fifth, sustain * 0.50, 0.06)));
        },
    }
}

fn panned(v_in: Voice) Voice {
    var v = v_in;
    v.pan = (randF3201() - 0.5) * 1.8;
    return v;
}

pub fn spawnPhraseStart(hz: f64, sustain: f64, voices: *VoiceList) void {
    push(voices, Voice.melodyGain(hz, sustain * 2.5, 0.22));
    push(voices, Voice.melodyGain(hz * 0.5, sustain * 2.0, 0.14));
}

pub fn spawnSubBass(root_hz: f64, phrase_secs: f64, voices: *VoiceList) void {
    const octaves = [_]struct { f64, f32 }{
        .{ 1.0, 0.04 },
        .{ 0.5, 0.10 },
        .{ 0.25, 0.15 },
        .{ 0.125, 0.11 },
        .{ 0.0625, 0.06 },
        .{ 0.03125, 0.02 },
    };
    for (octaves) |o| {
        const freq = root_hz * o[0];
        if (freq < 8.0) break;
        var v = Voice.mk(.sub_bass, freq, phrase_secs);
        v.gain_override = o[1];
        push(voices, v);
    }
}

// ── Tests (synth.rs has none; these are the port's own) ──────────────────────

const testing = std.testing;

test "the PRNG starts from the Rust state and seedRng reproduces it" {
    seedRng(default_seed);
    // First value of the Rust generator: (seed + inc) * mul + add, all wrapping (the Rust stores
    // the product of the *previous* value, fetch_add returns the old state).
    const expected0 = default_seed *% 2_862_933_555_777_941_757 +% 3_037_000_493;
    try testing.expectEqual(expected0, nextU64());
    const a = [_]u64{ nextU64(), nextU64(), nextU64() };
    seedRng(default_seed);
    _ = nextU64();
    const b = [_]u64{ nextU64(), nextU64(), nextU64() };
    try testing.expectEqualSlices(u64, &a, &b);
}

test "random helpers stay in their ranges" {
    seedRng(42);
    for (0..10_000) |_| {
        const x = randF32();
        try testing.expect(x >= -1.0 and x <= 1.0);
        const y = randF3201();
        try testing.expect(y >= 0.0 and y <= 1.0);
        const z = randRange(3, 7);
        try testing.expect(z >= 3 and z < 7);
    }
    try testing.expectEqual(@as(usize, 5), randRange(5, 5));
    try testing.expectEqual(@as(usize, 9), randRange(9, 2));
    try testing.expect(!randBool(0.0));
    seedRng(default_seed);
}

test "zigzag walk" {
    const gpa = testing.allocator;
    const w0 = try zigzagWalk(gpa, 0, 3);
    defer gpa.free(w0);
    try testing.expectEqualSlices(usize, &.{0}, w0);
    const w1 = try zigzagWalk(gpa, 1, 3);
    defer gpa.free(w1);
    try testing.expectEqualSlices(usize, &.{ 0, 0 }, w1); // last waypoint wins over the peak
    const w3 = try zigzagWalk(gpa, 3, 9);
    defer gpa.free(w3);
    try testing.expectEqualSlices(usize, &.{ 0, 4, 2, 0 }, w3);
    const w4 = try zigzagWalk(gpa, 4, 1);
    defer gpa.free(w4);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 1, 1, 0 }, w4);
    var bad: [2]usize = undefined;
    try testing.expect(!zigzagWalkInto(&bad, 3, 2));
}

test "expand degrees interpolates within groups" {
    const gpa = testing.allocator;
    const d = try expandDegrees(gpa, &.{ 0, 4, 2, 0 }, &.{ 3, 3, 2 });
    defer gpa.free(d);
    // group 0: 0 -> 4 over 3: 0, 1.33->1, 2.67->3; group 1: 4 -> 2: 4, 3.33->3, 2.67->3;
    // group 2: 2 -> 0: 2, 1
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 3, 3, 2, 1 }, d);
    try testing.expectEqual(@as(usize, 8), expandDegreesLen(&.{ 3, 3, 2 }));
    // missing waypoints fall back to 0 / from
    const e = try expandDegrees(gpa, &.{}, &.{2});
    defer gpa.free(e);
    try testing.expectEqualSlices(usize, &.{ 0, 0 }, e);
}

test "voices finish and stay within -1..1" {
    seedRng(7);
    const kinds = [_]VoiceKind{ .floor_tom, .snare, .crash, .phrase_change, .melody_fm, .sub_bass };
    for (kinds) |k| {
        var v = Voice.mk(k, 220.0, 0.1);
        var n: usize = 0;
        while (!v.done and n < 48_000 * 2) : (n += 1) {
            const s = v.sampleWithWave(48_000.0, if (k == .melody_fm) null else .saw);
            try testing.expect(s >= -1.0 and s <= 1.0);
        }
        try testing.expect(v.done);
    }
    var r = Voice.melody(440.0, 5.0);
    r.release_frames = 3;
    var n: usize = 0;
    while (!r.done) : (n += 1) _ = r.sampleWithWave(48_000.0, .sin);
    try testing.expectEqual(@as(usize, 4), n);
    seedRng(default_seed);
}

test "spawning follows the Rust voice layout and never grows the list" {
    const gpa = testing.allocator;
    var voices: VoiceList = try .initCapacity(gpa, 16);
    defer voices.deinit(gpa);
    const scale = [_]f64{ 293.6648, 330.0, 352.0 };
    spawnVoices(.{ .kick = 293.6648 }, 1.0, &voices, .turnaround, &scale, 293.6648, 0.25);
    try testing.expectEqual(@as(usize, 7), voices.items.len);
    try testing.expectEqual(VoiceKind.floor_tom, voices.items[0].kind);
    try testing.expectEqual(@as(f64, 35.0), voices.items[0].freq);
    try testing.expectEqual(VoiceKind.sub_bass, voices.items[1].kind);
    try testing.expectEqual(@as(?f32, 0.45), voices.items[1].gain_override);
    try testing.expectEqual(@as(?f32, 0.15), voices.items[6].gain_override);
    // root/8 snaps to the nearest scale note within +-2 octaves
    try testing.expectApproxEqAbs(@as(f64, 293.6648 / 4.0), voices.items[4].freq, 1e-9);
    voices.clearRetainingCapacity();
    spawnVoices(.{ .snare = 330.0 }, 1.0, &voices, .none, &scale, 293.6648, 0.25);
    try testing.expectEqual(@as(usize, 3), voices.items.len);
    try testing.expectEqual(VoiceKind.snare, voices.items[0].kind);
    try testing.expect(voices.items[0].pan >= -0.9 and voices.items[0].pan <= 0.9);
    // Full list: nothing is appended and nothing allocates.
    while (voices.items.len < voices.capacity) voices.appendAssumeCapacity(Voice.snare());
    const cap = voices.capacity;
    spawnVoices(.{ .kick = 293.6648 }, 1.0, &voices, .phrase_start, &scale, 293.6648, 0.25);
    try testing.expectEqual(cap, voices.items.len);
    try testing.expectEqual(cap, voices.capacity);
    voices.clearRetainingCapacity();
    spawnPhraseStart(440.0, 1.0, &voices);
    try testing.expectEqual(@as(usize, 2), voices.items.len);
    voices.clearRetainingCapacity();
    spawnSubBass(100.0, 2.0, &voices); // 100, 50, 25, 12.5 (6.25 < 8 stops)
    try testing.expectEqual(@as(usize, 4), voices.items.len);
    seedRng(default_seed);
}

test "evolve bar keeps shapes and the scale" {
    const gpa = testing.allocator;
    const groups = try gpa.dupe(u8, &.{ 3, 3, 2 });
    const freqs = try gpa.dupe(f64, &.{ 100, 110, 120, 130, 140, 150 });
    const gd = try zigzagWalk(gpa, 3, 3);
    const degrees = try expandDegrees(gpa, gd, groups);
    const events = try sequencer.eventsFromFreqs(gpa, degrees, freqs, groups);
    var bar: Bar = .{
        .root = .{ .letter = 'd', .accidental = 0, .octave = 4 },
        .root_hz = 100,
        .maqam = try @import("tuning.zig").Maqam.new("Nahawand"),
        .maqam_names = &.{},
        .ratio_strs = &.{},
        .jins_boundaries = &.{},
        .groups = groups,
        .frequencies = freqs,
        .group_degrees = gd,
        .degrees = degrees,
        .events = events,
        .total_subdivs = degrees.len,
    };
    defer {
        gpa.free(groups);
        gpa.free(freqs);
        gpa.free(gd);
        gpa.free(degrees);
        gpa.free(events);
    }
    seedRng(1234);
    for (0..2000) |_| {
        evolveBar(&bar, true);
        try testing.expectEqual(@as(usize, 4), bar.group_degrees.len);
        try testing.expectEqual(@as(usize, 0), bar.group_degrees[0]);
        try testing.expectEqual(@as(usize, 0), bar.group_degrees[3]);
        for (bar.group_degrees) |d| try testing.expect(d < freqs.len);
        try testing.expect(std.meta.activeTag(bar.events[0]) == .kick);
    }
    // A one-note scale cannot trap (the Rust clamp(1, 0) would panic).
    bar.frequencies = freqs[0..1];
    for (0..500) |_| {
        evolveBar(&bar, true);
        for (bar.group_degrees) |d| try testing.expectEqual(@as(usize, 0), d);
    }
    seedRng(default_seed);
}
