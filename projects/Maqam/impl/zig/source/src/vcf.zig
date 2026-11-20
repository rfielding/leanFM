//! Port of maqam-live `src/vcf.rs`: Moog-ish resonant 4-pole low-pass VCF (settings per target,
//! the VCF bank with its focus, VCO waveforms, and the `MoogLadder` filter).
//!
//! Float clamps follow Rust `f32::clamp` (NaN passes through). No deliberate behavioral differences
//! from the Rust.
const std = @import("std");

const TAU32: f32 = std.math.tau;

fn fclamp(x: f32, lo: f32, hi: f32) f32 {
    var v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

fn tanh32(x: f32) f32 {
    return std.math.tanh(x);
}

pub const VcfTarget = enum {
    all,
    mic,
    bass,
    kanun,
    kick,
    tanbura,

    pub fn parse(s: []const u8) ?VcfTarget {
        const table = [_]struct { []const u8, VcfTarget }{
            .{ "all", .all },     .{ "mix", .all },              .{ "master", .all },
            .{ "mic", .mic },     .{ "input", .mic },            .{ "live", .mic },
            .{ "bass", .bass },   .{ "sub", .bass },             .{ "subbass", .bass },
            .{ "kanun", .kanun }, .{ "qanun", .kanun },          .{ "melody", .kanun },
            .{ "drums", .kick },  .{ "drum", .kick },            .{ "kick", .kick },
            .{ "kicks", .kick },  .{ "tanbura", .tanbura },      .{ "tambura", .tanbura },
            .{ "sym", .tanbura }, .{ "sympathetics", .tanbura },
        };
        for (table) |e| {
            if (std.ascii.eqlIgnoreCase(s, e[0])) return e[1];
        }
        return null;
    }

    pub fn asStr(self: VcfTarget) []const u8 {
        return switch (self) {
            .all => "all",
            .mic => "mic",
            .bass => "bass",
            .kanun => "kanun",
            .kick => "drums",
            .tanbura => "sym",
        };
    }
};

pub const VcoWave = enum {
    sin,
    tri,
    squ,
    saw,
    mic,

    pub fn parse(s: []const u8) ?VcoWave {
        const table = [_]struct { []const u8, VcoWave }{
            .{ "sin", .sin },      .{ "sine", .sin },   .{ "tri", .tri },   .{ "triangle", .tri },
            .{ "squ", .squ },      .{ "square", .squ }, .{ "sq", .squ },    .{ "saw", .saw },
            .{ "sawtooth", .saw }, .{ "mic", .mic },    .{ "input", .mic }, .{ "live", .mic },
        };
        for (table) |e| {
            if (std.ascii.eqlIgnoreCase(s, e[0])) return e[1];
        }
        return null;
    }

    pub fn asStr(self: VcoWave) []const u8 {
        return switch (self) {
            .sin => "sin",
            .tri => "tri",
            .squ => "squ",
            .saw => "saw",
            .mic => "mic",
        };
    }

    pub fn oscillator(self: VcoWave) ?VcoWave {
        return switch (self) {
            .mic => null,
            else => self,
        };
    }

    pub inline fn sample(self: VcoWave, phase: f64) f32 {
        const p = phase - @floor(phase);
        return switch (self) {
            .sin => @floatCast(@sin(p * std.math.tau)),
            .tri => @floatCast(1.0 - 4.0 * @abs(p - 0.5)),
            .squ => if (p < 0.5) 1.0 else -1.0,
            .saw => @floatCast(2.0 * p - 1.0),
            .mic => 0.0,
        };
    }
};

pub const VcfSettings = struct {
    enabled: bool = false,
    target: VcfTarget = .all,
    cutoff_hz: f32 = 1200.0,
    resonance: f32 = 0.35,
    drive: f32 = 1.5,
    cutoff_step_per_tick: f32 = 0.0,
    resonance_step_per_tick: f32 = 0.0,
    drive_step_per_tick: f32 = 0.0,
    wave: VcoWave = .sin,

    /// The Rust `VcfSettings::default()`.
    pub fn default() VcfSettings {
        return .{};
    }

    pub fn forTarget(target: VcfTarget) VcfSettings {
        var s: VcfSettings = .{};
        s.target = target;
        s.wave = if (target == .mic) .mic else (VcfSettings{}).wave;
        return s;
    }
};

pub const VcfBank = struct {
    focus: VcfTarget = .all,
    all: VcfSettings = VcfSettings.forTarget(.all),
    mic: VcfSettings = VcfSettings.forTarget(.mic),
    bass: VcfSettings = VcfSettings.forTarget(.bass),
    kanun: VcfSettings = VcfSettings.forTarget(.kanun),
    kick: VcfSettings = VcfSettings.forTarget(.kick),
    tanbura: VcfSettings = VcfSettings.forTarget(.tanbura),

    /// The Rust `VcfBank::default()`.
    pub fn default() VcfBank {
        return .{};
    }

    pub fn get(self: VcfBank, target: VcfTarget) VcfSettings {
        return switch (target) {
            .all => self.all,
            .mic => self.mic,
            .bass => self.bass,
            .kanun => self.kanun,
            .kick => self.kick,
            .tanbura => self.tanbura,
        };
    }

    pub fn apply(self: *VcfBank, setting_in: VcfSettings) void {
        var setting = setting_in;
        self.focus = setting.target;
        switch (setting.target) {
            .all => {
                self.all = setting;
                self.mic.enabled = false;
                self.bass.enabled = false;
                self.kanun.enabled = false;
                self.kick.enabled = false;
                self.tanbura.enabled = false;
            },
            .mic => {
                self.all.enabled = false;
                setting.target = .mic;
                self.mic = setting;
            },
            .bass => {
                self.all.enabled = false;
                setting.target = .bass;
                self.bass = setting;
            },
            .kanun => {
                self.all.enabled = false;
                setting.target = .kanun;
                self.kanun = setting;
            },
            .kick => {
                self.all.enabled = false;
                setting.target = .kick;
                self.kick = setting;
            },
            .tanbura => {
                self.all.enabled = false;
                setting.target = .tanbura;
                self.tanbura = setting;
            },
        }
    }

    pub fn advanceTick(self: *VcfBank) void {
        const targets = [_]VcfTarget{ .all, .mic, .bass, .kanun, .kick, .tanbura };
        for (targets) |target| {
            var setting = self.get(target);
            if (setting.enabled) {
                setting.cutoff_hz = fclamp(setting.cutoff_hz + setting.cutoff_step_per_tick, 10.0, 22_000.0);
                setting.resonance = fclamp(setting.resonance + setting.resonance_step_per_tick, 0.0, 0.98);
                setting.drive = fclamp(setting.drive + setting.drive_step_per_tick, 0.1, 12.0);
                self.applyToSlot(setting);
            }
        }
    }

    fn applyToSlot(self: *VcfBank, setting: VcfSettings) void {
        switch (setting.target) {
            .all => self.all = setting,
            .mic => self.mic = setting,
            .bass => self.bass = setting,
            .kanun => self.kanun = setting,
            .kick => self.kick = setting,
            .tanbura => self.tanbura = setting,
        }
    }
};

pub const MoogLadder = struct {
    sample_rate: f32,
    cutoff_hz: f32,
    target_cutoff_hz: f32,
    resonance: f32,
    drive: f32,
    z1: f32,
    z2: f32,
    z3: f32,
    z4: f32,
    cutoff_smooth_coeff: f32,

    pub fn new(sample_rate: f32) MoogLadder {
        const d = VcfSettings{};
        var f: MoogLadder = .{
            .sample_rate = @max(sample_rate, 1.0),
            .cutoff_hz = d.cutoff_hz,
            .target_cutoff_hz = d.cutoff_hz,
            .resonance = d.resonance,
            .drive = d.drive,
            .z1 = 0.0,
            .z2 = 0.0,
            .z3 = 0.0,
            .z4 = 0.0,
            .cutoff_smooth_coeff = 0.0,
        };
        f.recomputeSmoothing();
        return f;
    }

    pub fn reset(self: *MoogLadder) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
        self.z3 = 0.0;
        self.z4 = 0.0;
    }

    pub fn setSettings(self: *MoogLadder, s: VcfSettings) void {
        self.updateSettings(s);
        self.reset();
    }

    pub fn updateSettings(self: *MoogLadder, s: VcfSettings) void {
        self.setCutoffHz(s.cutoff_hz);
        self.setResonance(s.resonance);
        self.setDrive(s.drive);
    }

    pub fn setCutoffHz(self: *MoogLadder, hz: f32) void {
        const nyquist_safe = self.sample_rate * 0.45;
        self.target_cutoff_hz = fclamp(hz, 10.0, nyquist_safe);
    }

    pub fn setResonance(self: *MoogLadder, resonance_0_to_1: f32) void {
        self.resonance = fclamp(resonance_0_to_1, 0.0, 0.98);
    }

    pub fn setDrive(self: *MoogLadder, drive: f32) void {
        self.drive = fclamp(drive, 0.1, 12.0);
    }

    pub inline fn process(self: *MoogLadder, input: f32) f32 {
        self.cutoff_hz = self.target_cutoff_hz + self.cutoff_smooth_coeff * (self.cutoff_hz - self.target_cutoff_hz);

        const cutoff = fclamp(self.cutoff_hz, 10.0, self.sample_rate * 0.45);
        const g = fclamp(1.0 - @exp(-TAU32 * cutoff / self.sample_rate), 0.0001, 0.98);
        const k = self.resonance * 1.65;

        const x = fclamp(input - k * self.z4, -8.0, 8.0);
        var y = tanh32(x * self.drive);

        y = onePole(y, &self.z1, g);
        y = softStage(y);
        y = onePole(y, &self.z2, g);
        y = softStage(y);
        y = onePole(y, &self.z3, g);
        y = softStage(y);
        y = onePole(y, &self.z4, g);

        const makeup = 1.0 + 0.15 * self.resonance;
        return fclamp(y * makeup, -1.0, 1.0);
    }

    fn recomputeSmoothing(self: *MoogLadder) void {
        const tau_seconds: f32 = 0.005;
        self.cutoff_smooth_coeff = @exp(-1.0 / (tau_seconds * self.sample_rate));
    }
};

inline fn onePole(input: f32, z: *f32, g: f32) f32 {
    z.* += g * (input - z.*);
    z.* *= 0.9995;
    return z.*;
}

inline fn softStage(x: f32) f32 {
    return tanh32(x);
}

test "resonant_filter_decays_after_impulse" {
    var filter = MoogLadder.new(44_100.0);
    filter.setSettings(.{
        .enabled = true,
        .target = .all,
        .cutoff_hz = 900.0,
        .resonance = 0.65,
        .drive = 3.5,
        .cutoff_step_per_tick = 0.0,
        .resonance_step_per_tick = 0.0,
        .drive_step_per_tick = 0.0,
        .wave = .sin,
    });

    var max_tail: f32 = 0.0;
    _ = filter.process(1.0);
    for (0..44_100 * 3) |i| {
        const y = @abs(filter.process(0.0));
        if (i > 44_100) max_tail = @max(max_tail, y);
    }
    try std.testing.expect(max_tail < 0.001);
}

test "target and wave parsing, bank focus" {
    try std.testing.expectEqual(VcfTarget.kick, VcfTarget.parse("KICKS").?);
    try std.testing.expectEqual(VcfTarget.tanbura, VcfTarget.parse("sym").?);
    try std.testing.expect(VcfTarget.parse("nope") == null);
    try std.testing.expectEqualStrings("drums", VcfTarget.kick.asStr());
    try std.testing.expectEqual(VcoWave.squ, VcoWave.parse("Sq").?);
    try std.testing.expect(VcoWave.mic.oscillator() == null);
    try std.testing.expectEqual(VcoWave.mic, (VcfBank{}).mic.wave);
    var bank: VcfBank = .{};
    var s = VcfSettings.forTarget(.bass);
    s.enabled = true;
    s.cutoff_step_per_tick = 100_000.0;
    bank.apply(s);
    try std.testing.expectEqual(VcfTarget.bass, bank.focus);
    bank.advanceTick();
    try std.testing.expectEqual(@as(f32, 22_000.0), bank.bass.cutoff_hz);
    var all = VcfSettings.forTarget(.all);
    all.enabled = true;
    bank.apply(all);
    try std.testing.expect(!bank.bass.enabled);
    try std.testing.expectEqual(@as(f32, -1.0), VcoWave.squ.sample(0.75));
}
