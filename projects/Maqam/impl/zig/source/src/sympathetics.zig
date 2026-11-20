//! Port of maqam-live `src/sympathetics.rs`: the taraf (sympathetic string) resonator bank.
//!
//! The bank owns its mode list: `setTargets` / `setWeightedTargets` take `gpa` (they may grow the
//! list) and `deinit(gpa)` frees it; `process` never allocates (it only drops silent untargeted
//! modes in place).
//!
//! Deliberate difference from the Rust: a target frequency that is not finite is skipped (the Rust
//! loops forever folding an infinite frequency into the 320..640 Hz octave).
const std = @import("std");

const TAU: f32 = std.math.tau;

fn fclamp(x: f32, lo: f32, hi: f32) f32 {
    var v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

/// Rust `f32::fract`.
fn fract(x: f32) f32 {
    return x - @trunc(x);
}

/// Rust `f32::total_cmp` as a less-than.
fn totalLess(a: f32, b: f32) bool {
    var l: i32 = @bitCast(a);
    var rr: i32 = @bitCast(b);
    l ^= @bitCast(@as(u32, @bitCast(l >> 31)) >> 1);
    rr ^= @bitCast(@as(u32, @bitCast(rr >> 31)) >> 1);
    return l < rr;
}

const Mode = struct {
    frequency: f32,
    coupling: f32,
    targeted: bool,
    modulation_phase: f32,
    modulation_rate: f32,
    y1: f32,
    y2: f32,
};

/// One weighted target (the Rust `(f64, f32)` pair of `set_weighted_targets`).
pub const WeightedFrequency = struct {
    frequency: f64,
    weight: f32,
};

const Target = struct { frequency: f32, coupling: f32 };

fn targetLess(_: void, a: Target, b: Target) bool {
    return totalLess(a.frequency, b.frequency);
}

pub const SympatheticStrings = struct {
    sample_rate: f32,
    modes: std.ArrayList(Mode),
    envelope: f32,
    previous_envelope: f32,
    noise_floor: f32,
    gate: f32,
    wet: f32,
    input_gain: f32,
    decay: f32,
    previous_input: f32,

    pub fn new(sample_rate: f32) SympatheticStrings {
        return .{
            .sample_rate = sample_rate,
            .modes = .empty,
            .envelope = 0.0,
            .previous_envelope = 0.0,
            .noise_floor = 0.002,
            .gate = 0.0,
            .wet = 0.65,
            .input_gain = 2.0,
            .decay = 0.999,
            .previous_input = 0.0,
        };
    }

    pub fn deinit(self: *SympatheticStrings, gpa: std.mem.Allocator) void {
        self.modes.deinit(gpa);
    }

    pub fn setTargets(self: *SympatheticStrings, gpa: std.mem.Allocator, frequencies: []const f64) error{OutOfMemory}!void {
        var weighted: std.ArrayList(WeightedFrequency) = .empty;
        defer weighted.deinit(gpa);
        try weighted.ensureTotalCapacity(gpa, frequencies.len + 2);
        for (frequencies) |f| weighted.appendAssumeCapacity(.{ .frequency = f, .weight = 1.0 });
        if (frequencies.len > 0) {
            // Taraf strings prominently reinforce the tonic, fourth, and
            // fifth. Add the latter two explicitly even when the current
            // maqam's degree list does not land exactly on those ratios.
            const tonic = frequencies[0];
            weighted.appendAssumeCapacity(.{ .frequency = tonic * 4.0 / 3.0, .weight = 1.0 });
            weighted.appendAssumeCapacity(.{ .frequency = tonic * 3.0 / 2.0, .weight = 1.0 });
        }
        try self.setWeightedTargets(gpa, weighted.items);
    }

    pub fn setWeightedTargets(self: *SympatheticStrings, gpa: std.mem.Allocator, frequencies: []const WeightedFrequency) error{OutOfMemory}!void {
        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(gpa);
        const partials = [_][2]f32{
            .{ 1.0, 1.0 },  .{ 2.0, 0.92 }, .{ 3.0, 0.78 },  .{ 4.0, 0.66 },  .{ 5.0, 0.56 },
            .{ 6.0, 0.46 }, .{ 8.0, 0.38 }, .{ 10.0, 0.30 }, .{ 12.0, 0.24 },
        };
        for (frequencies) |fw| {
            const target_weight = @max(fw.weight, 0.0);
            if (target_weight <= std.math.floatEps(f32)) continue;
            var hz: f32 = @floatCast(fw.frequency);
            if (!std.math.isFinite(hz)) continue; // deliberate: the Rust never terminates on infinity
            // Keep the sympathetic bank well above the main instrument's body:
            // its lowest course lives in the 320–640 Hz octave.
            while (hz >= 320.0) hz *= 0.5;
            while (hz > 0.0 and hz < 320.0) hz *= 2.0;
            // A metal sympathetic course radiates a family of partials, not
            // just a single sine resonance.
            for (partials) |hc| {
                const partial = hz * hc[0];
                if (partial > 4_500.0) continue;
                const coupling = hc[1] * target_weight;
                var found = false;
                for (targets.items) |*existing| {
                    if (1200.0 * @abs(@log2(partial / existing.frequency)) < 8.0) {
                        existing.coupling += coupling;
                        found = true;
                        break;
                    }
                }
                if (!found) try targets.append(gpa, .{ .frequency = partial, .coupling = coupling });
            }
        }
        std.mem.sort(Target, targets.items, {}, targetLess);
        if (targets.items.len > 64) targets.shrinkRetainingCapacity(64);
        try self.modes.ensureUnusedCapacity(gpa, targets.items.len);
        for (self.modes.items) |*mode| mode.targeted = false;
        for (targets.items) |t| {
            var found = false;
            for (self.modes.items) |*mode| {
                if (1200.0 * @abs(@log2(t.frequency / mode.frequency)) < 8.0) {
                    mode.frequency = t.frequency;
                    mode.coupling = t.coupling;
                    mode.targeted = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.modes.appendAssumeCapacity(.{
                    .frequency = t.frequency,
                    .coupling = t.coupling,
                    .targeted = true,
                    .modulation_phase = fract(t.frequency * 0.071) * TAU,
                    .modulation_rate = 0.08 + fract(t.frequency * 0.013) * 0.24,
                    .y1 = 0.0,
                    .y2 = 0.0,
                });
            }
        }
    }

    pub fn setDecay(self: *SympatheticStrings, decay: f32) void {
        self.decay = fclamp(decay, 0.9, 0.999_99);
    }

    pub fn setInputGain(self: *SympatheticStrings, gain: f32) void {
        self.input_gain = fclamp(gain, 0.0, 512.0);
    }

    pub fn hasEnergy(self: *const SympatheticStrings) bool {
        for (self.modes.items) |mode| {
            if (@max(@abs(mode.y1), @abs(mode.y2)) > 0.000_01) return true;
        }
        return false;
    }

    pub fn process(self: *SympatheticStrings, input: f32) f32 {
        const driven_input = std.math.tanh(input * self.input_gain);
        const magnitude = @abs(driven_input);
        self.envelope += (magnitude - self.envelope) * 0.0025;
        const onset = @max(self.envelope - self.previous_envelope, 0.0);
        self.previous_envelope = self.envelope;
        // Learn the floor only while input is close to quiet.
        if (self.envelope < self.noise_floor * 2.0) {
            self.noise_floor += (self.envelope - self.noise_floor) * 0.0002;
        }
        self.noise_floor = fclamp(self.noise_floor, 0.000_05, 0.05);
        const threshold = @max(self.noise_floor * 3.5, 0.0015);
        const wanted_gate: f32 = if (self.envelope > threshold) 1.0 else 0.0;
        const gate_rate: f32 = if (wanted_gate > self.gate) 0.01 else 0.0008;
        self.gate += (wanted_gate - self.gate) * gate_rate;
        const edge = driven_input - self.previous_input;
        self.previous_input = driven_input;
        const sustained_excitation = (driven_input * 0.72 + edge * 3.5) * self.gate;
        const bridge_strike = onset * 300.0;

        if (self.modes.items.len == 0) return 0.0;
        var sum: f32 = 0.0;
        for (self.modes.items) |*mode| {
            // `decay` is retention per millisecond, not per sample.
            mode.modulation_phase = @rem(mode.modulation_phase + TAU * mode.modulation_rate / self.sample_rate, TAU);
            const drift_cents = @sin(mode.modulation_phase) * 1.7;
            const sounding_frequency = mode.frequency * std.math.pow(f32, 2.0, drift_cents / 1200.0);
            const frequency_damping = @sqrt(@max(sounding_frequency / 440.0, 0.5));
            const radius = std.math.pow(f32, self.decay, frequency_damping / (self.sample_rate * 0.001));
            const coefficient = 2.0 * radius * @cos(TAU * sounding_frequency / self.sample_rate);
            const drive: f32 = if (mode.targeted)
                sustained_excitation * (1.0 - radius) + bridge_strike * 0.003
            else
                0.0;
            const y = coefficient * mode.y1 - radius * radius * mode.y2 + drive * mode.coupling;
            mode.y2 = mode.y1;
            mode.y1 = fclamp(y, -4.0, 4.0);
            sum += mode.y1 * mode.coupling;
        }
        // Fixed bank normalization so adding strings never turns down a ringing chord.
        const raw = sum / 8.0 * self.wet;
        const output = std.math.tanh(raw + std.math.tanh(raw * 3.0) * 0.22);
        // retain: keep targeted modes and modes still ringing.
        var w: usize = 0;
        for (self.modes.items) |mode| {
            if (mode.targeted or @max(@abs(mode.y1), @abs(mode.y2)) > 0.000_01) {
                self.modes.items[w] = mode;
                w += 1;
            }
        }
        self.modes.shrinkRetainingCapacity(w);
        return output;
    }
};

const testing = std.testing;

test "target_bank_is_bounded_and_silent_without_excitation" {
    var strings = SympatheticStrings.new(48_000.0);
    defer strings.deinit(testing.allocator);
    try strings.setTargets(testing.allocator, &.{ 220.0, 275.0, 330.0 });
    try testing.expect(strings.modes.items.len != 0);
    try testing.expect(strings.modes.items.len <= 64);
    try testing.expectEqual(@as(f32, 0.0), strings.process(0.0));
}

test "matching_input_audibly_excites_the_bank" {
    var strings = SympatheticStrings.new(48_000.0);
    defer strings.deinit(testing.allocator);
    try strings.setTargets(testing.allocator, &.{440.0});
    var peak: f32 = 0.0;
    for (0..48_000) |sample| {
        const input: f32 = if (sample < 12_000)
            @sin(TAU * 440.0 * @as(f32, @floatFromInt(sample)) / 48_000.0) * 0.05
        else
            0.0;
        peak = @max(peak, @abs(strings.process(input)));
    }
    try testing.expect(peak > 0.01);
}

test "taraf_bank_is_high_and_includes_tonic_fourth_and_fifth" {
    var strings = SympatheticStrings.new(48_000.0);
    defer strings.deinit(testing.allocator);
    try strings.setTargets(testing.allocator, &.{220.0});
    for (strings.modes.items) |mode| try testing.expect(mode.frequency >= 320.0);
    for ([_]f32{ 220.0 * 4.0 / 3.0, 220.0 * 3.0 / 2.0 }) |w| {
        const wanted = if (w < 320.0) w * 2.0 else w;
        var any = false;
        for (strings.modes.items) |mode| {
            if (1200.0 * @abs(@log2(mode.frequency / wanted)) < 8.0) any = true;
        }
        try testing.expect(any);
    }
}

test "bridge_strike_leaves_a_ringing_tail" {
    var strings = SympatheticStrings.new(48_000.0);
    defer strings.deinit(testing.allocator);
    try strings.setTargets(testing.allocator, &.{ 220.0, 275.0, 330.0 });
    _ = strings.process(0.2);
    var tail_energy: f32 = 0.0;
    for (0..9_600) |sample| {
        const output = strings.process(0.0);
        if (sample >= 2_400) tail_energy += output * output;
    }
    const tail_rms = @sqrt(tail_energy / 7_200.0);
    try testing.expect(tail_rms > 0.0001);
}

test "retuning_preserves_energy_in_old_strings" {
    var strings = SympatheticStrings.new(48_000.0);
    defer strings.deinit(testing.allocator);
    try strings.setTargets(testing.allocator, &.{440.0});
    for (0..4_800) |sample| {
        const input = @sin(TAU * 440.0 * @as(f32, @floatFromInt(sample)) / 48_000.0) * 0.1;
        _ = strings.process(input);
    }
    try strings.setTargets(testing.allocator, &.{554.0});
    var old: ?Mode = null;
    for (strings.modes.items) |mode| {
        if (@abs(mode.frequency - 440.0) < 1.0) {
            old = mode;
            break;
        }
    }
    try testing.expect(old != null); // old tonic string should remain while ringing
    try testing.expect(!old.?.targeted);
    try testing.expect(@max(@abs(old.?.y1), @abs(old.?.y2)) > 0.000_01);
    try testing.expect(@abs(strings.process(0.0)) > 0.000_01);
}

test "non-finite and zero-weight targets are skipped" {
    var strings = SympatheticStrings.new(48_000.0);
    defer strings.deinit(testing.allocator);
    try strings.setWeightedTargets(testing.allocator, &.{
        .{ .frequency = std.math.inf(f64), .weight = 1.0 },
        .{ .frequency = 440.0, .weight = 0.0 },
    });
    try testing.expectEqual(@as(usize, 0), strings.modes.items.len);
    strings.setDecay(2.0);
    try testing.expectEqual(@as(f32, 0.99999), strings.decay);
    strings.setInputGain(-1.0);
    try testing.expectEqual(@as(f32, 0.0), strings.input_gain);
}
