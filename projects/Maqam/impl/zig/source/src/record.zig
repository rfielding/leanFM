//! Port of maqam-live `src/record.rs` and `src/record_old.rs`: record whole timeline cycles to an
//! MP4 (task record_mp4: requested -> rendering -> encoding -> written -> saved | failed).
//!
//! The recorder does not reuse the live path (specification markdown "doc-disagreements"): it has
//! its own mix loop at a fixed 44.1 kHz without the sympathetic strings, NAM, mic or vol, spawns
//! voices assuming 0.25 s subdivisions, peak-normalizes to 0.9 and writes 16-bit stereo WAV. Over
//! it ffmpeg (run as `nice -n 10 ffmpeg ...`, argv only, never a shell) composes the carpet
//! layers (carpet.zig), the animated border-tick highlights and center-Gosper rotation of the
//! filter script, a waveform, and the ASS subtitles of the timeline rows. The filter strings,
//! ffmpeg arguments, ASS text and messages are the Rust's.
//!
//! It runs on a worker thread the App starts. It touches no audio-engine state: only the
//! recording progress in `Shared` (rec_samples_done, rec_samples_total, rec_active), the files
//! below, and (as upstream) the process-wide synth PRNG that voice spawning draws from.
//!
//! Files: a private directory `<temp_root>/maqam-live-<16 hex>/` (mode 0700) holds
//! maqam-live.wav, maqam-live.ass, maqam-carpet.png, maqam-gosper.png, maqam-jumps.png,
//! maqam-filter.txt (and maqam-filter-plain.txt, see below) and maqam-ffmpeg.log. ffmpeg writes
//! `<out_dir>/.maqam-<secs>.partial.mp4`, renamed to `<out_dir>/maqam-<secs>.mp4` only after
//! ffmpeg succeeded; `out_dir` is "." (so the result is "./maqam-<secs>.mp4", as upstream).
//!
//! Failure (property "A failed recording leaves no partial mp4"): on every failure path the
//! .partial.mp4 is deleted and no maqam-<secs>.mp4 is created; every temp file is deleted,
//! except that when ffmpeg itself failed the private directory is kept holding only
//! maqam-ffmpeg.log, because the (Rust) message tells the performer to read that log. On
//! success the whole private directory is deleted.
//!
//! Bounds (upstream bounds none of these; specification markdown "bounds", "Known gaps"):
//! * `max_render_secs` (600 s) of audio, tail included: 26 460 000 frames, about 212 MB of f32
//!   mix buffers and a 106 MB WAV at the limit; a longer request is rejected before rendering.
//! * `max_sequence_entries` (100 000) played bars over all cycles.
//! * `max_timeline_rows` (1 000 000) subtitle rows (bars x timeline rows) and jump-snapshot cells.
//! * `max_expand_steps` (10 000 000) sequencer steps while expanding one cycle.
//!
//! Deliberate differences from the Rust:
//! * The bounds above, rejected with a new message ("recording too long: ...").
//! * Expanding one cycle stops after `max_expand_steps` steps; upstream loops forever on a cycle of
//!   `j N always` rows that reaches no musical phrase.
//! * Temp files live in a fresh private directory instead of fixed names in the shared temp dir
//!   (two recordings cannot overwrite each other's inputs, and no symlink there is followed); the
//!   default temp root is "/tmp" (Rust's `std::env::temp_dir()` without TMPDIR), and the App passes
//!   another through `Options.temp_root` (the recorder has no environment of its own).
//! * Cleanup as described above; upstream leaves every temp file, leaves the .partial.mp4 when
//!   ffmpeg cannot be started or the rename fails, and leaves REC_ACTIVE set after an early I/O
//!   error. Here rec_active is cleared on every exit once it was set.
//! * ffmpeg gets stdin from /dev/null (upstream inherits the terminal, where ffmpeg reads keys).
//! * The layers are PNG files (maqam-*.png) instead of PPM (maqam-*.ppm); same pixels.
//! * The subtitles path in the filter script is escaped for ffmpeg's filter syntax when it holds a
//!   character outside [A-Za-z0-9/._-] (never for the default temp root: the text is the Rust's).
//! * The fallback filter (without subtitles) goes through a second script file when it is longer
//!   than `max_inline_filter` bytes, instead of failing on the kernel's argument length limit.
//! * Internal errors (I/O, out of memory) are reported as "could not record: <error>; ..." since
//!   the Rust's io::Error texts do not exist here; spawning ffmpeg failing for a reason other than
//!   a missing program reports "could not start ffmpeg: <error>; ...".
//! * Rust `as` float casts are saturating casts here too (NaN -> 0), so no bpm or sustain makes
//!   the render panic; sums saturate and then hit the bounds.
//! * The 16-bit WAV is written by this module (stereo, truncating like Rust `as i16`); wav.zig's
//!   `encode` is mono and rounds.
//! * If the message itself cannot be allocated, `err` is an empty slice (still safe to free).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const analog = @import("analog.zig");
const carpet = @import("carpet.zig");
const command = @import("command.zig");
const fx_mod = @import("fx.zig");
const sequencer = @import("sequencer.zig");
const shared_mod = @import("shared.zig");
const synth = @import("synth.zig");
const vcf_mod = @import("vcf.zig");

const Phrase = sequencer.Phrase;
const ControlSpec = sequencer.ControlSpec;
const FxProcessor = fx_mod.FxProcessor;
const FxSettings = fx_mod.FxSettings;
const MoogLadder = vcf_mod.MoogLadder;
const VcfBank = vcf_mod.VcfBank;
const VcfSettings = vcf_mod.VcfSettings;
const VcfTarget = vcf_mod.VcfTarget;
const Voice = synth.Voice;
const VoiceKind = synth.VoiceKind;
const VoiceList = synth.VoiceList;
const Milestone = synth.Milestone;
const Shared = shared_mod.Shared;

pub const SR: f64 = 44100.0;
const RENDER_COOP_INTERVAL_SAMPLES: usize = 4096;
const ASS_MONO_FONT = "DejaVu Sans Mono";

pub const max_render_secs: usize = 600;
pub const max_render_samples: usize = max_render_secs * 44100;
pub const max_sequence_entries: usize = 100_000;
pub const max_timeline_rows: usize = 1_000_000;
pub const max_expand_steps: usize = 10_000_000;
/// Longest filter passed inline on the command line (Linux limits one argument to 128 KiB).
pub const max_inline_filter: usize = 100_000;

pub const msg_nothing = "nothing to record; add a phrase first, then run m again";
pub const msg_no_musical = "no musical phrases to render; add a non-control phrase first, then run m again";
pub const msg_no_ffmpeg = "video rendering requires ffmpeg on your PATH; install ffmpeg, or add it to PATH, then run m again";
pub const msg_ffmpeg_broken = "ffmpeg is installed but did not run successfully; run ffmpeg -version in your shell, fix that error, then run m again";

/// The Rust `anyhow::Result<String>` of `record_cycle`: the mp4 path, or the message the
/// performer sees. Both are owned by the caller (`deinit`).
pub const RecordResult = union(enum) {
    ok: []u8,
    err: []u8,

    pub fn deinit(self: RecordResult, gpa: Allocator) void {
        switch (self) {
            inline else => |s| gpa.free(s),
        }
    }
};

/// Where the recorder reads and writes; the defaults are the Rust's.
pub const Options = struct {
    /// The ffmpeg program (looked up on PATH). Tests point it at a missing or failing program.
    ffmpeg: []const u8 = "ffmpeg",
    /// Run the encode as `nice -n 10 <ffmpeg> ...` (upstream does on unix).
    nice: bool = builtin.os.tag != .windows,
    /// Directory of the finished mp4 (upstream: the current directory).
    out_dir: []const u8 = ".",
    /// Directory that receives the private temp directory.
    temp_root: []const u8 = "/tmp",
    /// The timestamp in the output name; null reads the real clock.
    now_secs: ?u64 = null,
};

/// The Rust `record_cycle` with upstream's defaults.
pub fn recordCycle(
    gpa: Allocator,
    io: Io,
    shared: *Shared,
    phrases: []const Phrase,
    bpm: f64,
    sustain: f64,
    vcf: VcfBank,
    fx: FxSettings,
    cycle_repeat: usize,
) RecordResult {
    return recordCycleWith(gpa, io, shared, phrases, bpm, sustain, vcf, fx, cycle_repeat, .{});
}

pub fn recordCycleWith(
    gpa: Allocator,
    io: Io,
    shared: *Shared,
    phrases: []const Phrase,
    bpm: f64,
    sustain: f64,
    vcf: VcfBank,
    fx: FxSettings,
    cycle_repeat: usize,
    opts: Options,
) RecordResult {
    return recordInner(gpa, io, shared, phrases, bpm, sustain, vcf, fx, cycle_repeat, opts) catch |err|
        errFmt(gpa, "could not record: {s}; check free disk space and the temp directory, then run m again", .{@errorName(err)});
}

fn errFmt(gpa: Allocator, comptime fmt: []const u8, args: anytype) RecordResult {
    return .{ .err = std.fmt.allocPrint(gpa, fmt, args) catch &.{} };
}

fn errMsg(gpa: Allocator, msg: []const u8) RecordResult {
    return .{ .err = gpa.dupe(u8, msg) catch &.{} };
}

// ── Rust `as` casts ──────────────────────────────────────────────────────────

fn asUsize(x: f64) usize {
    if (std.math.isNan(x) or x <= 0.0) return 0;
    if (x >= 18446744073709551615.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

fn asU32(x: f64) u32 {
    if (std.math.isNan(x) or x <= 0.0) return 0;
    if (x >= 4294967295.0) return std.math.maxInt(u32);
    return @intFromFloat(x);
}

fn asI16(x: f32) i16 {
    if (std.math.isNan(x)) return 0;
    if (x >= 32767.0) return 32767;
    if (x <= -32768.0) return -32768;
    return @intFromFloat(x);
}

/// Rust's `{:.p}` for floats: the exact binary value rounded to `p` decimals, ties to even (Zig's
/// `{d:.p}` rounds the shortest digits half up, so 1.25 would print as 1.3 instead of 1.2).
const Fixed = struct {
    x: f64,
    p: u3,

    pub fn format(self: Fixed, w: *Io.Writer) Io.Writer.Error!void {
        const x = self.x;
        if (std.math.isNan(x)) return w.writeAll("NaN");
        const neg = std.math.signbit(x);
        if (std.math.isInf(x)) return w.writeAll(if (neg) "-inf" else "inf");
        if (neg) try w.writeByte('-');
        const a = @abs(x);
        var pow10: u128 = 1;
        for (0..self.p) |_| pow10 *= 10;
        var n: u128 = undefined;
        if (a >= 4503599627370496.0) { // 2^52: an integer
            if (a >= 1.0e38) return w.print("{d}", .{a});
            n = @as(u128, @intFromFloat(a)) * pow10;
        } else {
            const bits: u64 = @bitCast(a);
            const exp_field: u64 = bits >> 52;
            const frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
            const m: u128 = if (exp_field == 0) frac else frac | (@as(u64, 1) << 52);
            const s: u64 = if (exp_field == 0) 1074 else 1075 - exp_field; // a < 2^52: s >= 1
            const num = m * pow10; // < 2^53 * 10^7 < 2^77
            if (s >= 100) {
                n = 0;
            } else {
                const sh: u7 = @intCast(s);
                const q = num >> sh;
                const r = num - (q << sh);
                const half = @as(u128, 1) << (sh - 1);
                n = if (r > half or (r == half and q & 1 == 1)) q + 1 else q;
            }
        }
        try w.print("{d}", .{n / pow10});
        if (self.p > 0) {
            try w.writeByte('.');
            var digits: [8]u8 = undefined;
            var f = n % pow10;
            var i: usize = self.p;
            while (i > 0) {
                i -= 1;
                digits[i] = '0' + @as(u8, @intCast(f % 10));
                f /= 10;
            }
            try w.writeAll(digits[0..self.p]);
        }
    }
};

fn fixed(x: f64, p: u3) Fixed {
    return .{ .x = x, .p = p };
}

fn fclamp(x: f32, lo: f32, hi: f32) f32 {
    var v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

// ── Plan: one cycle's occurrences and the full played sequence ───────────────

const RenderOccurrence = struct {
    phrase_idx: usize,
    bpm: f64,
    sustain: f64,
    vcf: VcfBank,
    fx: FxSettings,
    vcf_generation: usize,
    fx_generation: usize,
    arrived_via_jump: ?usize,
};

/// One played bar. Its snapshot index is `occ` (the Rust pushes one snapshot per occurrence).
const RenderEntry = struct {
    phrase_idx: usize,
    play_num: usize,
    occ: usize,
    arrived_via_jump: ?usize,
};

pub const Plan = struct {
    occs: []RenderOccurrence,
    /// Positions (in `phrases`) of the jump rows, the columns of `snap`.
    jump_rows: []usize,
    /// occs.len * jump_rows.len pass counters (the Rust's JumpCounterSnapshot per occurrence).
    snap: []usize,
    seq: []RenderEntry,
    cycles: usize,
    tail_samples: usize,
    /// Played samples (without the tail).
    seq_samples: usize,
    render_samples: usize,

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        gpa.free(self.occs);
        gpa.free(self.jump_rows);
        gpa.free(self.snap);
        gpa.free(self.seq);
        self.* = undefined;
    }

    fn entryBpm(self: *const Plan, e: RenderEntry) f64 {
        return self.occs[e.occ].bpm;
    }
    fn entrySustain(self: *const Plan, e: RenderEntry) f64 {
        return self.occs[e.occ].sustain;
    }

    /// The Rust `snap.get(&jump_id)`: (pass, times) of the (last) jump row with that id.
    fn snapGet(self: *const Plan, phrases: []const Phrase, occ: usize, jump_id: usize) ?struct { usize, usize } {
        const n = self.jump_rows.len;
        var k = n;
        while (k > 0) {
            k -= 1;
            const p = &phrases[self.jump_rows[k]];
            if (p.id == jump_id) return .{ self.snap[occ * n + k], p.jump.?.times };
        }
        return null;
    }
};

pub const PlanResult = union(enum) {
    ok: Plan,
    /// A performer message (static text).
    no_musical,
    /// Render length (samples, saturating) above the bounds.
    too_long: usize,
};

fn barSamples(phrase: *const Phrase, bpm: f64) usize {
    const subdiv_secs = 60.0 / (bpm * 2.0);
    const subdiv_samples = SR * subdiv_secs;
    return @max(asUsize(@round(subdiv_samples * @as(f64, @floatFromInt(phrase.bar.total_subdivs)))), 1);
}

fn positionOfId(phrases: []const Phrase, id: usize) ?usize {
    for (phrases, 0..) |p, i| if (p.id == id) return i;
    return null;
}

/// The Rust `expand_one_cycle` followed by the full-sequence expansion of `record_cycle`.
pub fn buildPlan(
    gpa: Allocator,
    phrases: []const Phrase,
    start_bpm: f64,
    start_sustain: f64,
    start_vcf: VcfBank,
    start_fx: FxSettings,
    cycle_repeat: usize,
) Allocator.Error!PlanResult {
    var occs: std.ArrayList(RenderOccurrence) = .empty;
    defer occs.deinit(gpa);
    var snap: std.ArrayList(usize) = .empty;
    defer snap.deinit(gpa);
    var jump_rows: std.ArrayList(usize) = .empty;
    defer jump_rows.deinit(gpa);
    for (phrases, 0..) |p, i| if (p.jump != null) try jump_rows.append(gpa, i);

    var jc: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer jc.deinit(gpa);
    var cur: usize = 0;
    var bpm = start_bpm;
    var sustain = start_sustain;
    var vcf = start_vcf;
    var fx = start_fx;
    var vcf_generation: usize = 0;
    var fx_generation: usize = 0;
    var arrived_via_jump: ?usize = null;
    const max_items = phrases.len *| 512 +| 1;
    var cycle_samples: usize = 0;
    var steps: usize = 0;
    while (occs.items.len < max_items) {
        steps += 1;
        if (steps > max_expand_steps) break;
        if (cur >= phrases.len) break;
        const phrase = &phrases[cur];
        if (phrase.jump) |js| {
            const pid = phrase.id;
            if (js.times == 0) {
                cur = @min(positionOfId(phrases, js.target_id) orelse 0, phrases.len -| 1);
                arrived_via_jump = pid;
                continue;
            }
            const limit = @max(js.times, 1);
            const gop = try jc.getOrPut(gpa, pid);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            const incremented = gop.value_ptr.* +| 1;
            if (incremented < limit) {
                gop.value_ptr.* = incremented;
                cur = @min(positionOfId(phrases, js.target_id) orelse 0, phrases.len -| 1);
                arrived_via_jump = pid;
            } else {
                gop.value_ptr.* = 0;
                cur = if (js.fail_target_id) |id| (positionOfId(phrases, id) orelse cur + 1) else cur + 1;
            }
            continue;
        }
        if (phrase.control) |ctrl| {
            switch (ctrl) {
                .stop => break,
                .set_bpm => |v| bpm = v,
                .set_sustain => |v| sustain = v,
                .set_vcf => |v| {
                    const r = try command.applyVcfChange(gpa, vcf, v);
                    switch (r) {
                        .ok => |setting| {
                            vcf.apply(setting);
                            vcf_generation += 1;
                        },
                        .err => |m| gpa.free(m),
                    }
                },
                .set_fx => |v| {
                    const r = try command.applyFxChange(gpa, fx, v);
                    switch (r) {
                        .ok => |setting| {
                            fx = setting;
                            fx_generation += 1;
                        },
                        .err => |m| gpa.free(m),
                    }
                },
                .set_sympathetics, .set_sympathetic_decay, .set_sympathetic_gain, .set_sympathetic, .set_nam_enabled, .set_nam_gain, .set_nam_input, .set_vol, .set_bus_vol, .set_dry => {},
            }
            cur += 1;
            continue;
        }
        // Bound the work before it is done: one cycle already longer than the limit, or more
        // snapshot cells than the row bound, cannot be recorded.
        cycle_samples +|= barSamples(phrase, bpm) *| @max(phrase.repeat, 1);
        if (cycle_samples > max_render_samples or occs.items.len >= max_sequence_entries or
            (occs.items.len + 1) *| jump_rows.items.len > max_timeline_rows)
            return .{ .too_long = cycle_samples };
        for (jump_rows.items) |row| try snap.append(gpa, jc.get(phrases[row].id) orelse 0);
        try occs.append(gpa, .{
            .phrase_idx = cur,
            .bpm = bpm,
            .sustain = sustain,
            .vcf = vcf,
            .fx = fx,
            .vcf_generation = vcf_generation,
            .fx_generation = fx_generation,
            .arrived_via_jump = arrived_via_jump,
        });
        arrived_via_jump = null;
        cur += 1;
    }
    if (occs.items.len == 0) return .no_musical;

    const cycles = @max(cycle_repeat, 1);
    var per_cycle_entries: usize = 0;
    for (occs.items) |o| per_cycle_entries +|= @max(phrases[o.phrase_idx].repeat, 1);
    const total_entries = per_cycle_entries *| cycles;
    const tail_sustain = occs.items[occs.items.len - 1].sustain;
    const tail_samples = asUsize(SR * (tail_sustain + 1.0));
    const seq_samples = cycle_samples *| cycles;
    const render_samples = seq_samples +| tail_samples;
    if (total_entries > max_sequence_entries or render_samples > max_render_samples) return .{ .too_long = render_samples };
    // Subtitle rows: every bar shows every timeline row, the active one once per subdivision.
    var rows_per_cycle: usize = 0;
    for (occs.items) |o| rows_per_cycle +|= (phrases.len + phrases[o.phrase_idx].bar.events.len + 4) *| @max(phrases[o.phrase_idx].repeat, 1);
    if (rows_per_cycle *| cycles > max_timeline_rows) return .{ .too_long = render_samples };

    const seq = try gpa.alloc(RenderEntry, total_entries);
    errdefer gpa.free(seq);
    var n: usize = 0;
    for (0..cycles) |_| {
        for (occs.items, 0..) |o, oi| {
            for (0..@max(phrases[o.phrase_idx].repeat, 1)) |play| {
                seq[n] = .{
                    .phrase_idx = o.phrase_idx,
                    .play_num = play,
                    .occ = oi,
                    .arrived_via_jump = if (play == 0) o.arrived_via_jump else null,
                };
                n += 1;
            }
        }
    }
    std.debug.assert(n == total_entries);
    const occ_slice = try occs.toOwnedSlice(gpa);
    errdefer gpa.free(occ_slice);
    const rows_slice = try jump_rows.toOwnedSlice(gpa);
    errdefer gpa.free(rows_slice);
    const snap_slice = try snap.toOwnedSlice(gpa);
    return .{ .ok = .{
        .occs = occ_slice,
        .jump_rows = rows_slice,
        .snap = snap_slice,
        .seq = seq,
        .cycles = cycles,
        .tail_samples = tail_samples,
        .seq_samples = seq_samples,
        .render_samples = render_samples,
    } };
}

// ── Mix ──────────────────────────────────────────────────────────────────────

const StereoFilter = struct {
    left: MoogLadder,
    right: MoogLadder,

    fn new(sr: f32) StereoFilter {
        return .{ .left = MoogLadder.new(sr), .right = MoogLadder.new(sr) };
    }
    fn setSettings(self: *StereoFilter, s: VcfSettings) void {
        self.left.setSettings(s);
        self.right.setSettings(s);
    }
    fn updateSettings(self: *StereoFilter, s: VcfSettings) void {
        self.left.updateSettings(s);
        self.right.updateSettings(s);
    }
    fn reset(self: *StereoFilter) void {
        self.left.reset();
        self.right.reset();
    }
    fn process(self: *StereoFilter, l: f32, r: f32) [2]f32 {
        return .{ self.left.process(l), self.right.process(r) };
    }
};

const FilterBank = struct {
    all: StereoFilter,
    mic: StereoFilter,
    bass: StereoFilter,
    kanun: StereoFilter,
    kick: StereoFilter,
    tanbura: StereoFilter,

    fn new(sr: f32) FilterBank {
        return .{
            .all = .new(sr),
            .mic = .new(sr),
            .bass = .new(sr),
            .kanun = .new(sr),
            .kick = .new(sr),
            .tanbura = .new(sr),
        };
    }
    fn setBank(self: *FilterBank, b: VcfBank) void {
        self.all.setSettings(b.all);
        self.mic.setSettings(b.mic);
        self.bass.setSettings(b.bass);
        self.kanun.setSettings(b.kanun);
        self.kick.setSettings(b.kick);
        self.tanbura.setSettings(b.tanbura);
    }
    fn updateBank(self: *FilterBank, b: VcfBank) void {
        self.all.updateSettings(b.all);
        self.mic.updateSettings(b.mic);
        self.bass.updateSettings(b.bass);
        self.kanun.updateSettings(b.kanun);
        self.kick.updateSettings(b.kick);
        self.tanbura.updateSettings(b.tanbura);
    }
    fn reset(self: *FilterBank) void {
        self.all.reset();
        self.mic.reset();
        self.bass.reset();
        self.kanun.reset();
        self.kick.reset();
        self.tanbura.reset();
    }
};

fn vcfTargetForKind(kind: VoiceKind) ?VcfTarget {
    return switch (kind) {
        .sub_bass => .bass,
        .melody_fm => .kanun,
        .floor_tom => .kick,
        else => null,
    };
}

fn retainLive(voices: *VoiceList) void {
    var j: usize = 0;
    for (voices.items) |v| {
        if (!v.done) {
            voices.items[j] = v;
            j += 1;
        }
    }
    voices.shrinkRetainingCapacity(j);
}

/// One output frame of the recorder's mix: the body shared by the bar loop and the tail loop of
/// the Rust (retain, silent-path or voice sum, per-target VCFs, FX, soft clip, master VCF, clamp).
fn mixFrame(voices: *VoiceList, filters: *FilterBank, fxp: *FxProcessor, bank: VcfBank, fxs: FxSettings) [2]f32 {
    retainLive(voices);
    if (voices.items.len == 0) {
        filters.reset();
        if (fxs.active()) {
            const o = fxp.process(0.0, 0.0);
            const c = analog.softClipStereo(o.left, o.right);
            const f = if (bank.all.enabled) filters.all.process(c.left, c.right) else [2]f32{ c.left, c.right };
            return .{ fclamp(f[0], -1.0, 1.0), fclamp(f[1], -1.0, 1.0) };
        }
        return .{ 0.0, 0.0 };
    }
    var dry = [2]f32{ 0, 0 };
    var mic = [2]f32{ 0, 0 };
    var bass = [2]f32{ 0, 0 };
    var kanun = [2]f32{ 0, 0 };
    var kick = [2]f32{ 0, 0 };
    var tanbura = [2]f32{ 0, 0 };
    for (voices.items) |*v| {
        const setting: ?VcfSettings = if (bank.all.enabled) null else blk: {
            const target = vcfTargetForKind(v.kind) orelse break :blk null;
            const s = bank.get(target);
            break :blk if (s.enabled) s else null;
        };
        const wave = if (setting) |s| (if (s.target != .all) s.wave.oscillator() else null) else null;
        const s = v.sampleWithWave(SR, wave);
        const angle = (v.pan + 1.0) * (std.math.pi / 4.0);
        const l = s * @cos(angle);
        const r = s * @sin(angle);
        const bus: *[2]f32 = if (setting) |st| switch (st.target) {
            // The master VCF is applied after the mix; `all` never reaches here (Rust: unreachable).
            .all => &dry,
            .mic => &mic,
            .bass => &bass,
            .kanun => &kanun,
            .kick => &kick,
            .tanbura => &tanbura,
        } else &dry;
        bus[0] += l;
        bus[1] += r;
    }
    var l = dry[0];
    var r = dry[1];
    if (!bank.all.enabled) {
        if (bank.mic.enabled) {
            const f = filters.mic.process(mic[0], mic[1]);
            l += f[0];
            r += f[1];
        }
        if (bank.bass.enabled) {
            const f = filters.bass.process(bass[0], bass[1]);
            l += f[0];
            r += f[1];
        }
        if (bank.kanun.enabled) {
            const f = filters.kanun.process(kanun[0], kanun[1]);
            l += f[0];
            r += f[1];
        }
        if (bank.kick.enabled) {
            const f = filters.kick.process(kick[0], kick[1]);
            l += f[0];
            r += f[1];
        }
        if (bank.tanbura.enabled) {
            const f = filters.tanbura.process(tanbura[0], tanbura[1]);
            l += f[0];
            r += f[1];
        }
    }
    if (fxs.active()) {
        const o = fxp.process(l, r);
        l = o.left;
        r = o.right;
    }
    const c = analog.softClipStereo(l, r);
    const f = if (bank.all.enabled) filters.all.process(c.left, c.right) else [2]f32{ c.left, c.right };
    retainLive(voices);
    return .{ fclamp(f[0], -1.0, 1.0), fclamp(f[1], -1.0, 1.0) };
}

pub const Mix = struct {
    left: []f32,
    right: []f32,

    pub fn deinit(self: *Mix, gpa: Allocator) void {
        gpa.free(self.left);
        gpa.free(self.right);
        self.* = undefined;
    }

    /// Peak normalization to 0.9 (the Rust's gain).
    pub fn gain(self: Mix) f32 {
        var peak: f32 = 0.0;
        for (self.left) |s| peak = @max(peak, @abs(s));
        for (self.right) |s| peak = @max(peak, @abs(s));
        return if (peak > 0.001) 0.9 / peak else 1.0;
    }
};

fn yieldToAudioThread(io: ?Io, rendered: usize) void {
    if (rendered != 0 and rendered % RENDER_COOP_INTERVAL_SAMPLES == 0) {
        if (io) |i| i.sleep(.fromMicroseconds(250), .awake) catch {};
    }
}

/// The recorder's own mix of `plan` (44.1 kHz stereo, before normalization). Draws from the synth
/// PRNG; seed it (synth.seedRng) for a reproducible mix. `io` null skips the cooperative sleeps.
pub fn renderMix(gpa: Allocator, io: ?Io, shared: ?*Shared, phrases: []const Phrase, plan: *const Plan) Allocator.Error!Mix {
    // The Rust clones the phrases, since evolving a bar mutates it.
    const pv = try gpa.alloc(Phrase, phrases.len);
    var cloned: usize = 0;
    defer {
        for (pv[0..cloned]) |*p| p.deinit(gpa);
        gpa.free(pv);
    }
    for (phrases, 0..) |*p, i| {
        pv[i] = try p.clone(gpa);
        cloned += 1;
    }

    const total = plan.render_samples;
    const left = try gpa.alloc(f32, total);
    errdefer gpa.free(left);
    const right = try gpa.alloc(f32, total);
    errdefer gpa.free(right);
    var len: usize = 0;

    var voices: VoiceList = .empty;
    defer voices.deinit(gpa);
    try voices.ensureTotalCapacity(gpa, synth.voice_capacity);
    var filters = FilterBank.new(@floatCast(SR));
    var fxp = try FxProcessor.init(gpa, @floatCast(SR));
    defer fxp.deinit(gpa);

    const first_occ = plan.occs[plan.seq[0].occ];
    var render_vcf = first_occ.vcf;
    var render_fx = first_occ.fx;
    var render_vcf_generation = first_occ.vcf_generation;
    var render_fx_generation = first_occ.fx_generation;
    filters.setBank(render_vcf);
    fxp.setSettings(render_fx);

    for (plan.seq, 0..) |entry, seq_pos| {
        const occ = plan.occs[entry.occ];
        const phrase_idx = entry.phrase_idx;
        const play_num = entry.play_num;
        const bs = barSamples(&pv[phrase_idx], occ.bpm);
        const is_first = play_num == 0;
        const repeats = @max(pv[phrase_idx].repeat, 1);
        const subdiv_secs = 60.0 / (occ.bpm * 2.0);
        const subdiv_samples = SR * subdiv_secs;
        const sustain = occ.sustain;
        if (occ.vcf_generation != render_vcf_generation) {
            render_vcf = occ.vcf;
            render_vcf_generation = occ.vcf_generation;
            filters.setBank(render_vcf);
        }
        if (occ.fx_generation != render_fx_generation) {
            render_fx = occ.fx;
            render_fx_generation = occ.fx_generation;
            fxp.setSettings(render_fx);
        }
        if (is_first) {
            const root_hz = pv[phrase_idx].bar.root_hz;
            const phrase_secs = @min(@as(f64, @floatFromInt(pv[phrase_idx].bar.total_subdivs)) * subdiv_secs * @as(f64, @floatFromInt(repeats)), 3.0);
            synth.spawnPhraseStart(root_hz, sustain, &voices);
            synth.spawnSubBass(root_hz, phrase_secs, &voices);
        }
        const total_subdivs = pv[phrase_idx].bar.total_subdivs;
        const next_is_different = seq_pos + 1 < plan.seq.len and plan.seq[seq_pos + 1].phrase_idx != phrase_idx;
        var bar_pos: usize = 0;
        var last_subdiv: ?usize = null;
        for (0..bs) |_| {
            yieldToAudioThread(io, len);
            if (total_subdivs > 0) {
                const curr = @min(asUsize(@as(f64, @floatFromInt(bar_pos)) / subdiv_samples), total_subdivs - 1);
                if (last_subdiv != curr) {
                    last_subdiv = curr;
                    const is_last_play = play_num + 1 >= repeats;
                    const is_last_subdiv = curr + 1 >= total_subdivs;
                    const milestone: Milestone = if (is_first and curr == 0)
                        .phrase_start
                    else if (is_last_play and is_last_subdiv)
                        (if (next_is_different) .turnaround else .cross_phrase_warning)
                    else
                        .none;
                    const bar = &pv[phrase_idx].bar;
                    if (curr < bar.events.len) {
                        synth.spawnVoices(bar.events[curr], sustain, &voices, milestone, bar.frequencies, bar.root_hz, 0.25);
                        render_vcf.advanceTick();
                        filters.updateBank(render_vcf);
                        render_fx.advanceTick();
                        fxp.setSettings(render_fx);
                    }
                }
                bar_pos += 1;
            }
            const f = mixFrame(&voices, &filters, &fxp, render_vcf, render_fx);
            left[len] = f[0];
            right[len] = f[1];
            len += 1;
        }
        if (shared) |s| s.rec_samples_done.store(@min(len, total), .monotonic);
        synth.evolveBar(&pv[phrase_idx].bar, true);
    }
    const tail_vcf = render_vcf;
    const tail_fx = render_fx;
    filters.setBank(tail_vcf);
    fxp.setSettings(tail_fx);
    {
        const first = plan.seq[0];
        const root_hz = pv[first.phrase_idx].bar.root_hz;
        const first_sustain = plan.occs[first.occ].sustain;
        synth.spawnPhraseStart(root_hz, first_sustain, &voices);
        synth.spawnSubBass(root_hz, @min(first_sustain, 2.0), &voices);
    }
    for (0..plan.tail_samples) |_| {
        yieldToAudioThread(io, len);
        const f = mixFrame(&voices, &filters, &fxp, tail_vcf, tail_fx);
        left[len] = f[0];
        right[len] = f[1];
        len += 1;
    }
    std.debug.assert(len == total);
    return .{ .left = left, .right = right };
}

/// 16-bit stereo PCM WAV exactly as the Rust writes it (header, then `(s * gain * 32767)`
/// clamped and truncated per channel).
fn writeWav(io: Io, path: []const u8, mix: Mix, gain: f32) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    const n: u32 = @intCast(mix.left.len);
    const sr: u32 = @intFromFloat(SR);
    const dl: u32 = n * 4;
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + dl, .little);
    try w.writeAll("WAVE");
    try w.writeAll("fmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u32, sr, .little);
    try w.writeInt(u32, sr * 4, .little);
    try w.writeInt(u16, 4, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeAll("data");
    try w.writeInt(u32, dl, .little);
    for (mix.left, mix.right) |l, r| {
        try w.writeInt(i16, asI16(fclamp(l * gain * 32767.0, -32768.0, 32767.0)), .little);
        try w.writeInt(i16, asI16(fclamp(r * gain * 32767.0, -32768.0, 32767.0)), .little);
    }
    try w.flush();
    try file.sync(io);
}

// ── Filter graph pieces ──────────────────────────────────────────────────────

const Range = struct { f64, f64 };
const HighlightKey = struct { layer: u8, x: i32, y: i32, w: i32, h: i32 };
const layer_colors = [_][]const u8{ "0x666666@0.72", "0xA0A0A0@0.88", "0x8080FF@0.42", "0xD0D0FF@0.88", "0x44FF88@0.20", "0xD8FFAA@0.82", "0xD8B060@0.70" };

fn keyLess(_: void, a: HighlightKey, b: HighlightKey) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    if (a.w != b.w) return a.w < b.w;
    return a.h < b.h;
}

const Highlights = struct {
    map: std.AutoArrayHashMapUnmanaged(HighlightKey, std.ArrayList(Range)) = .empty,

    fn deinit(self: *Highlights, gpa: Allocator) void {
        for (self.map.values()) |*v| v.deinit(gpa);
        self.map.deinit(gpa);
    }

    fn push(self: *Highlights, gpa: Allocator, key: HighlightKey, r: Range) Allocator.Error!void {
        const gop = try self.map.getOrPut(gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, r);
    }

    /// The two boxes (outer, inner) the Rust draws for one tick in layers (lo, lo + 1).
    fn pushTick(self: *Highlights, gpa: Allocator, lo: u8, tick: carpet.BorderTickLayout, r: Range) Allocator.Error!void {
        const outer: i32 = if (tick.is_kick) 6 else 4;
        const inner: i32 = if (tick.is_kick) 3 else 2;
        const tx = carpet.asI32(@round(tick.x));
        const ty = carpet.asI32(@round(tick.y));
        try self.push(gpa, .{ .layer = lo, .x = tx -| @divTrunc(outer, 2), .y = ty -| @divTrunc(outer, 2), .w = outer, .h = outer }, r);
        try self.push(gpa, .{ .layer = lo + 1, .x = tx -| @divTrunc(inner, 2), .y = ty -| @divTrunc(inner, 2), .w = inner, .h = inner }, r);
    }
};

/// For each bar, the first later bar that plays a different phrase (the Rust's
/// `full_seq[i + 1..].iter().find(...)`, computed in one backward pass).
fn nextDifferent(gpa: Allocator, seq: []const RenderEntry) Allocator.Error![]?usize {
    const out = try gpa.alloc(?usize, seq.len);
    var i = seq.len;
    while (i > 0) {
        i -= 1;
        out[i] = if (i + 1 >= seq.len) null else if (seq[i + 1].phrase_idx != seq[i].phrase_idx) i + 1 else out[i + 1];
    }
    return out;
}

/// The Rust `build_carpet_tick_highlights`: one drawbox per visual cell and chunk of 64 time
/// ranges. Returns the comma-joined chain ("null" when empty). Caller owns the result.
fn buildCarpetTickHighlights(gpa: Allocator, plan: *const Plan, phrases: []const Phrase, next_diff: []const ?usize) ![]u8 {
    var score = try carpet.WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const layout = try carpet.scoreBorderLayout(gpa, &score);
    defer gpa.free(layout);
    const jump_cells = try carpet.jumpLinkCells(gpa, phrases);
    defer gpa.free(jump_cells);

    var hl: Highlights = .{};
    defer hl.deinit(gpa);
    const total_secs = @as(f64, @floatFromInt(plan.seq_samples)) / SR;
    // Base score cells are neutral. Dynamic phrase state is layered over them below: next
    // phrase first, then the current subdivision.
    for (layout) |tick| try hl.pushTick(gpa, 0, tick, .{ 0.0, total_secs });
    var sample: usize = 0;
    for (plan.seq, 0..) |entry, entry_index| {
        const phrase = &phrases[entry.phrase_idx];
        const bpm = plan.entryBpm(entry);
        const subdiv_secs = 60.0 / (bpm * 2.0);
        const bar_samples = barSamples(phrase, bpm);
        const entry_start = @as(f64, @floatFromInt(sample)) / SR;
        const entry_end = @as(f64, @floatFromInt(sample +| bar_samples)) / SR - 0.0001;
        if (next_diff[entry_index]) |ni| {
            const next_id = phrases[plan.seq[ni].phrase_idx].id;
            for (layout) |tick| {
                if (tick.phrase_id == next_id) try hl.pushTick(gpa, 2, tick, .{ entry_start, entry_end });
            }
        }
        const score_ticks = @max(scoreTickCount(&score, phrase.id), 1);
        for (0..phrase.bar.events.len) |subdivision| {
            const score_tick = subdivision % score_ticks;
            const tick = findTick(layout, phrase.id, score_tick) orelse continue;
            const start = @as(f64, @floatFromInt(sample)) / SR + @as(f64, @floatFromInt(subdivision)) * subdiv_secs;
            const end = start + subdiv_secs - 0.0001;
            try hl.pushTick(gpa, 4, tick, .{ start, end });
            if (subdivision == 0) {
                if (entry.arrived_via_jump) |jump_id| {
                    var ji: usize = 0;
                    for (jump_cells) |cell| {
                        if (cell.jump_id != jump_id) continue;
                        defer ji += 1;
                        if (ji % 7 != 0) continue;
                        const size: i32 = @max(cell.size + 3, 8);
                        const x = carpet.asI32(@round(cell.x)) -| @divTrunc(size, 2);
                        const y = carpet.asI32(@round(cell.y)) -| @divTrunc(size, 2);
                        try hl.push(gpa, .{ .layer = 6, .x = x, .y = y, .w = size, .h = size }, .{ start, end });
                    }
                }
            }
        }
        sample +|= bar_samples;
    }

    const keys = try gpa.dupe(HighlightKey, hl.map.keys());
    defer gpa.free(keys);
    std.mem.sort(HighlightKey, keys, {}, keyLess);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    var first = true;
    for (keys) |key| {
        const ranges = hl.map.get(key).?.items;
        var c: usize = 0;
        while (c < ranges.len) : (c += 64) {
            const chunk = ranges[c..@min(c + 64, ranges.len)];
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("drawbox=x={d}:y={d}:w={d}:h={d}:color={s}:t=fill:enable='", .{ key.x, key.y, key.w, key.h, layer_colors[key.layer] });
            for (chunk, 0..) |r, i| {
                if (i > 0) try w.writeByte('+');
                try w.print("between(t,{f},{f})", .{ fixed(r[0], 6), fixed(r[1], 6) });
            }
            try w.writeByte('\'');
        }
    }
    if (first) try w.writeAll("null");
    return out.toOwnedSlice();
}

fn scoreTickCount(score: *const carpet.WeaveScore, id: usize) usize {
    // The Rust collects (phrase_id -> tick_count) into a HashMap: the last phrase with an id wins.
    var n: ?usize = null;
    for (score.phrases) |p| if (p.phrase_id == id) {
        n = p.tick_count;
    };
    return n orelse 1;
}

fn findTick(layout: []const carpet.BorderTickLayout, id: usize, score_tick: usize) ?carpet.BorderTickLayout {
    // HashMap collect: the last tick with this (phrase_id, score_tick) wins.
    var found: ?carpet.BorderTickLayout = null;
    for (layout) |t| if (t.phrase_id == id and t.score_tick == score_tick) {
        found = t;
    };
    return found;
}

/// The Rust `build_center_gosper_rotation_expr`. Caller owns the result.
fn buildCenterGosperRotationExpr(gpa: Allocator, plan: *const Plan, phrases: []const Phrase) ![]u8 {
    var score = try carpet.WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const layout = try carpet.scoreBorderLayout(gpa, &score);
    defer gpa.free(layout);
    const cycle_count = plan.cycles;
    const entries_per_cycle = plan.seq.len / @max(cycle_count, 1);
    const cycle_entries = plan.seq[0..@min(@max(entries_per_cycle, 1), plan.seq.len)];
    var cycle_samples: usize = 0;
    for (cycle_entries) |e| cycle_samples +|= barSamples(&phrases[e.phrase_idx], plan.entryBpm(e));
    const cycle_secs = @as(f64, @floatFromInt(cycle_samples)) / SR;
    var clock_buf: [64]u8 = undefined;
    const clock = if (cycle_count > 1 and cycle_secs > 0.0)
        try std.fmt.bufPrint(&clock_buf, "mod(t,{f})", .{fixed(cycle_secs, 6)})
    else
        "t";

    var terms: std.ArrayList([]u8) = .empty;
    defer {
        for (terms.items) |t| gpa.free(t);
        terms.deinit(gpa);
    }
    var sample: usize = 0;
    for (cycle_entries) |entry| {
        const phrase = &phrases[entry.phrase_idx];
        const bpm = plan.entryBpm(entry);
        const subdiv_secs = 60.0 / (bpm * 2.0);
        const bar_samples = barSamples(phrase, bpm);
        const score_ticks = @max(scoreTickCount(&score, phrase.id), 1);
        for (0..phrase.bar.events.len) |subdivision| {
            const tick = findTick(layout, phrase.id, subdivision % score_ticks) orelse continue;
            const start = @as(f64, @floatFromInt(sample)) / SR + @as(f64, @floatFromInt(subdivision)) * subdiv_secs;
            const end = start + subdiv_secs - 0.0001;
            const angle = @as(f64, @floatCast((tick.start_t + tick.end_t) * 0.5)) * std.math.tau;
            try terms.ensureUnusedCapacity(gpa, 1);
            terms.appendAssumeCapacity(try std.fmt.allocPrint(gpa, "{f}*between({s},{f},{f})", .{ fixed(angle, 6), clock, fixed(start, 6), fixed(end, 6) }));
        }
        sample +|= bar_samples;
    }
    // Balanced pairwise sums, as the Rust's chunks(2) reduction.
    while (terms.items.len > 1) {
        var n: usize = 0;
        var i: usize = 0;
        while (i < terms.items.len) : (i += 2) {
            if (i + 1 < terms.items.len) {
                const joined = try std.fmt.allocPrint(gpa, "({s}+{s})", .{ terms.items[i], terms.items[i + 1] });
                gpa.free(terms.items[i]);
                gpa.free(terms.items[i + 1]);
                terms.items[n] = joined;
            } else {
                terms.items[n] = terms.items[i];
            }
            n += 1;
        }
        terms.shrinkRetainingCapacity(n);
    }
    if (terms.items.len == 0) return gpa.dupe(u8, "0");
    const r = terms.items[0];
    terms.shrinkRetainingCapacity(0);
    return r;
}

/// A path as an ffmpeg filter option value: unchanged when it holds only [A-Za-z0-9/._-],
/// otherwise escaped for the option level and then the filtergraph level.
fn filterPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var safe = true;
    for (path) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-')) safe = false;
    }
    if (safe) return gpa.dupe(u8, path);
    var lvl1: std.ArrayList(u8) = .empty;
    defer lvl1.deinit(gpa);
    for (path) |c| {
        if (c == '\\' or c == '\'' or c == ':') try lvl1.append(gpa, '\\');
        try lvl1.append(gpa, c);
    }
    var lvl2: std.ArrayList(u8) = .empty;
    errdefer lvl2.deinit(gpa);
    for (lvl1.items) |c| {
        if (c == '\\' or c == '\'' or c == '[' or c == ']' or c == ',' or c == ';') try lvl2.append(gpa, '\\');
        try lvl2.append(gpa, c);
    }
    return lvl2.toOwnedSlice(gpa);
}

// ── ASS subtitles ────────────────────────────────────────────────────────────

fn charCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += if (i + len <= s.len) len else 1;
        n += 1;
    }
    return n;
}

/// Rust `{:<width$}` for a string (padding counts characters).
fn padRight(w: *Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    const n = charCount(s);
    if (n < width) try w.splatByteAll(' ', width - n);
}

/// The Rust `fmt_t` (h:mm:ss.cc).
fn fmtT(buf: *[48]u8, s: f64) []const u8 {
    const hh = asU32(s / 3600.0);
    const mm = asU32(@rem(s, 3600.0) / 60.0);
    const ss = asU32(@rem(s, 60.0));
    const cs = asU32(@rem(s, 1.0) * 100.0);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>2}", .{ hh, mm, ss, cs }) catch "0:00:00.00";
}

/// Writes one Dialogue line whose text has its spaces replaced by ASS hard spaces (`\h`).
fn dialogueRow(w: *Io.Writer, t0: []const u8, t1: []const u8, margin_v: usize, text: []const u8) !void {
    try w.print("Dialogue: 2,{s},{s},Line,,0,0,{d},,", .{ t0, t1, margin_v });
    for (text) |c| {
        if (c == ' ') try w.writeAll("\\h") else try w.writeByte(c);
    }
    try w.writeByte('\n');
}

const TextRoute = struct { target: usize, source: usize, jump_id: usize, times: usize };

/// Writes the Rust's maqam-live.ass text. Caller owns the result.
fn buildAss(gpa: Allocator, plan: *const Plan, phrases: []const Phrase, next_diff: []const ?usize, total_secs: f64) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const f = &out.writer;
    try f.writeAll("[Script Info]\n");
    try f.writeAll("ScriptType: v4.00+\n");
    try f.writeAll("PlayResX: 1280\n");
    try f.writeAll("PlayResY: 720\n");
    try f.writeAll("WrapStyle: 2\n");
    try f.writeAll("[V4+ Styles]\n");
    try f.writeAll("Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,Strikeout,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding\n");
    try f.writeAll("Style: Line," ++ ASS_MONO_FONT ++ ",24,&H00000000,&H00000000,&H00102004,&H00102004,-1,0,0,0,100,100,0,0,1,0,0,7,20,20,10,1\n");
    try f.writeAll("Style: URL,Arial,20,&H0078DD78,&H0078DD78,&H00102004,&H00102004,-1,0,0,0,110,102,0,0,1,3,1,1,20,20,38,1\n");
    try f.writeAll("Style: JumpCounter," ++ ASS_MONO_FONT ++ ",18,&H00909090,&H00909090,&H00102004,&H00102004,-1,0,0,0,100,100,0,0,1,3,1,5,0,0,0,1\n");
    try f.writeAll("[Events]\n");
    try f.writeAll("Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\n");

    var one_len: usize = 0;
    for (plan.occs) |o| one_len += @max(phrases[o.phrase_idx].repeat, 1);
    const cycles = plan.cycles;

    // phrase id -> position (HashMap collect: the last phrase with an id wins).
    const lastPosition = struct {
        fn find(ps: []const Phrase, id: usize) ?usize {
            var found: ?usize = null;
            for (ps, 0..) |p, i| if (p.id == id) {
                found = i;
            };
            return found;
        }
    }.find;
    var routes: std.ArrayList(TextRoute) = .empty;
    defer routes.deinit(gpa);
    for (phrases, 0..) |p, source| {
        const jump = p.jump orelse continue;
        const target = lastPosition(phrases, jump.target_id) orelse continue;
        if (target != source) try routes.append(gpa, .{ .target = target, .source = source, .jump_id = p.id, .times = jump.times });
    }
    var status_width: usize = "[settings]".len;
    for (phrases) |p| {
        const total = if (p.jump) |j| j.times else @max(p.repeat, 1);
        var tb: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&tb, "[{d}/{d}]", .{ total, total }) catch unreachable;
        status_width = @max(status_width, s.len);
    }
    const jump_counter_positions = try carpet.jumpCounterLayout(gpa, phrases);
    defer gpa.free(jump_counter_positions);
    const final_phrase_idx = plan.seq[plan.seq.len - 1].phrase_idx;
    var explicit_stop_idx: ?usize = null;
    for (phrases, 0..) |p, i| {
        if (p.control) |c| if (c == .stop) {
            explicit_stop_idx = i;
            break;
        };
    }

    // Per-phrase display strings, computed once.
    const labels = try gpa.alloc([]u8, phrases.len);
    const ratio_strs = try gpa.alloc([]u8, phrases.len);
    const rhythms = try gpa.alloc([]u8, phrases.len);
    var made: usize = 0;
    defer {
        for (0..made) |i| {
            gpa.free(labels[i]);
            gpa.free(ratio_strs[i]);
            gpa.free(rhythms[i]);
        }
        gpa.free(labels);
        gpa.free(ratio_strs);
        gpa.free(rhythms);
    }
    for (phrases, 0..) |*p, i| {
        labels[i] = try p.displaySrc(gpa);
        errdefer gpa.free(labels[i]);
        ratio_strs[i] = try p.pitchRatiosDisplay(gpa);
        errdefer gpa.free(ratio_strs[i]);
        rhythms[i] = try p.bar.rhythmDisplay(gpa);
        made += 1;
    }

    var row: Io.Writer.Allocating = .init(gpa);
    defer row.deinit();
    const rw = &row.writer;
    var tb0: [48]u8 = undefined;
    var tb1: [48]u8 = undefined;

    var sample: usize = 0;
    for (plan.seq, 0..) |entry, i| {
        const phrase_idx = entry.phrase_idx;
        const stopping = i + 1 == plan.seq.len;
        const next_phrase_idx: ?usize = if (next_diff[i]) |ni| plan.seq[ni].phrase_idx else if (stopping) explicit_stop_idx else null;
        const play_num = entry.play_num;
        const occ = plan.occs[entry.occ];
        const bs = barSamples(&phrases[phrase_idx], occ.bpm);
        const start_s = @as(f64, @floatFromInt(sample)) / SR;
        const end_s = @as(f64, @floatFromInt(sample +| bs)) / SR;
        const t0 = fmtT(&tb0, start_s);
        const t1 = fmtT(&tb1, end_s);
        const cycle_num = if (one_len > 0) i / one_len else 0;
        try f.print("Dialogue: 2,{s},{s},Line,,0,0,0,,{{\\1c&H00A0FF70&}}   bpm:{d:<4} sus:{f}s", .{ t0, t1, asU32(@round(occ.bpm)), fixed(occ.sustain, 1) });
        if (cycles > 1) try f.print("  cycle {d}/{d}", .{ cycle_num + 1, cycles });
        try f.writeByte('\n');
        try f.print("Dialogue: 2,{s},{s},URL,,0,0,0,,https://github.com/rfielding/maqam\n", .{ t0, t1 });
        const subdiv_secs = 60.0 / (occ.bpm * 2.0);
        const line_h: usize = 26;
        var margin_v: usize = 30;
        const snap_occ = entry.occ;
        for (jump_counter_positions) |counter| {
            const jp = blk: {
                for (phrases) |*p| if (p.id == counter.jump_id) break :blk p;
                break :blk null;
            } orelse continue;
            const jump = jp.jump orelse continue;
            const pass, const total = plan.snapGet(phrases, snap_occ, counter.jump_id) orelse .{ 0, jump.times };
            try f.print("Dialogue: 1,{s},{s},JumpCounter,,0,0,0,,{{\\pos({f},{f})}}[{d}/{d}]\n", .{ t0, t1, fixed(counter.x, 0), fixed(counter.y, 0), @min(pass +| 1, @max(total, 1)), total });
        }
        const upcoming_jump_source: ?usize = blk: {
            if (phrases.len == 0) break :blk null;
            var position = (phrase_idx + 1) % phrases.len;
            for (0..phrases.len) |_| {
                const p = &phrases[position];
                if (p.jump != null) break :blk position;
                if (p.control == null) break :blk null;
                position = (position + 1) % phrases.len;
            }
            break :blk null;
        };
        const leaving_current = play_num + 1 >= @max(phrases[phrase_idx].repeat, 1);
        const Lanes = struct {
            fn write(lw: *Io.Writer, rts: []const TextRoute, pl: *const Plan, ps: []const Phrase, occ_i: usize, display_pi: usize, upcoming: ?usize, leaving: bool) !void {
                for (rts) |r| {
                    const on_path = @min(r.target, r.source) <= display_pi and display_pi <= @max(r.target, r.source);
                    if (!on_path) {
                        try lw.writeAll("    ");
                        continue;
                    }
                    const pass, const total = pl.snapGet(ps, occ_i, r.jump_id) orelse .{ 0, r.times };
                    const will_jump = upcoming != null and upcoming.? == r.source and pass +| 1 < @max(total, 1);
                    if (display_pi == r.target) {
                        try lw.writeAll(if (r.target < r.source) "┌──>" else "└──>");
                    } else if (display_pi == r.source and will_jump and leaving) {
                        try lw.writeAll("●   ");
                    } else {
                        try lw.writeAll("│   ");
                    }
                }
            }
        };
        for (phrases, 0..) |*p, pi| {
            const display_pi = pi;
            const active = p.jump == null and pi == phrase_idx;
            const is_next = next_phrase_idx != null and next_phrase_idx.? == pi;
            const color = if (active) "{\\1c&H0000FF00&}" else if (is_next) "{\\1c&H00FF8080&}" else "{\\1c&H00909090&}";
            // One isolated two-cell marker column. Keep it outside the jump lanes and counters
            // so every following field remains on the same monospaced tab regardless of state.
            const row_guard = "•";
            const marker_head = if (active) "▶" else if (is_next) (if (leaving_current) "▸" else "▷") else "·";
            row.clearRetainingCapacity();
            try rw.print("{s}{s}{d:>3}: {s} ", .{ row_guard, color, p.id, marker_head });
            try Lanes.write(rw, routes.items, plan, phrases, snap_occ, display_pi, upcoming_jump_source, leaving_current);
            if (p.jump) |js| {
                const pass, const total = plan.snapGet(phrases, snap_occ, p.id) orelse .{ 0, js.times };
                var cb: [64]u8 = undefined;
                const ctr = std.fmt.bufPrint(&cb, "[{d}/{d}]", .{ @min(pass +| 1, @max(total, 1)), total }) catch unreachable;
                try padRight(rw, ctr, status_width);
                try rw.writeByte(' ');
                try rw.writeAll(labels[pi]);
                if (positionOfId(phrases, js.target_id) == null) try rw.writeAll("  [missing target]");
                try dialogueRow(f, t0, t1, margin_v, row.written());
            } else if (p.control) |c| {
                try padRight(rw, if (c == .stop) "[stop]" else "[settings]", status_width);
                try rw.writeByte(' ');
                try rw.writeAll(labels[pi]);
                try dialogueRow(f, t0, t1, margin_v, row.written());
            } else if (active) {
                const head_len = row.written().len;
                var cb: [64]u8 = undefined;
                const ctr = std.fmt.bufPrint(&cb, "[{d}/{d}]", .{ play_num + 1, @max(p.repeat, 1) }) catch unreachable;
                const n = @max(p.bar.events.len, 1);
                const rhythm_plain = rhythms[pi];
                for (0..n) |si| {
                    row.shrinkRetainingCapacity(head_len);
                    var sb0: [48]u8 = undefined;
                    var sb1: [48]u8 = undefined;
                    const ts0 = fmtT(&sb0, start_s + @as(f64, @floatFromInt(si)) * subdiv_secs);
                    const ts1 = fmtT(&sb1, @min(start_s + @as(f64, @floatFromInt(si + 1)) * subdiv_secs, end_s));
                    try padRight(rw, ctr, status_width);
                    try rw.writeByte(' ');
                    try padRight(rw, labels[pi], 28);
                    try rw.writeByte(' ');
                    for (rhythm_plain, 0..) |ch, ci| {
                        if (ci == si) {
                            try rw.print("{{\\1c&H00000000&\\3c&H00FFFFFF&\\bord6\\shad0}}{c}{{\\1c&H0000FF00&\\3c&H00000000&\\bord0\\shad0}}", .{ch});
                        } else try rw.writeByte(ch);
                    }
                    if (ratio_strs[pi].len > 0) {
                        try rw.writeAll("  ");
                        try rw.writeAll(ratio_strs[pi]);
                    }
                    try dialogueRow(f, ts0, ts1, margin_v, row.written());
                }
                const phrase_end_s = start_s + @as(f64, @floatFromInt(n)) * subdiv_secs;
                if (phrase_end_s < end_s) {
                    row.shrinkRetainingCapacity(head_len);
                    var sb0: [48]u8 = undefined;
                    const ts0 = fmtT(&sb0, phrase_end_s);
                    try padRight(rw, ctr, status_width);
                    try rw.writeByte(' ');
                    try padRight(rw, labels[pi], 28);
                    try rw.writeByte(' ');
                    try rw.writeAll(rhythm_plain);
                    if (ratio_strs[pi].len > 0) {
                        try rw.writeAll("  ");
                        try rw.writeAll(ratio_strs[pi]);
                    }
                    try dialogueRow(f, ts0, t1, margin_v, row.written());
                }
            } else {
                var cb: [64]u8 = undefined;
                const ctr = std.fmt.bufPrint(&cb, "[1/{d}]", .{@max(p.repeat, 1)}) catch unreachable;
                try padRight(rw, ctr, status_width);
                try rw.writeByte(' ');
                try padRight(rw, labels[pi], 28);
                try rw.writeByte(' ');
                try rw.writeAll(rhythms[pi]);
                if (ratio_strs[pi].len > 0) {
                    try rw.writeAll("  ");
                    try rw.writeAll(ratio_strs[pi]);
                }
                try dialogueRow(f, t0, t1, margin_v, row.written());
            }
            margin_v += line_h;
            if (pi == final_phrase_idx and explicit_stop_idx == null) {
                const stop_color = if (stopping) "{\\1c&H00FF8080&}" else "{\\1c&H00909090&}";
                const stop_marker = if (stopping) "▸ " else "· ";
                row.clearRetainingCapacity();
                try rw.print("•{s}---: {s}", .{ stop_color, stop_marker });
                try Lanes.write(rw, routes.items, plan, phrases, snap_occ, display_pi + 1, upcoming_jump_source, leaving_current);
                try padRight(rw, "[stop]", status_width);
                try rw.writeAll(" stop");
                try dialogueRow(f, t0, t1, margin_v, row.written());
                margin_v += line_h;
            }
        }
        sample +|= bs;
    }
    // The renderer tail is a real virtual stop step. It begins only after sequence expansion has
    // processed the final jump and gives users a visible current command to stop on.
    const stop_start_s = @as(f64, @floatFromInt(sample)) / SR;
    if (stop_start_s < total_secs) {
        const stop_start = fmtT(&tb0, stop_start_s);
        const stop_end = fmtT(&tb1, total_secs);
        row.clearRetainingCapacity();
        try rw.writeAll("•{\\1c&H0000FF00&}");
        if (explicit_stop_idx) |si| {
            try rw.print("{d:>3}: ", .{phrases[si].id});
        } else try rw.writeAll("---: ");
        try rw.writeAll("▶ ");
        for (routes.items) |r| {
            if (explicit_stop_idx) |stop_idx| {
                if (@min(r.target, r.source) <= stop_idx and stop_idx <= @max(r.target, r.source)) {
                    if (stop_idx == r.target) {
                        try rw.writeAll(if (r.target < r.source) "┌──>" else "└──>");
                    } else try rw.writeAll("│   ");
                } else try rw.writeAll("    ");
            } else try rw.writeAll("    ");
        }
        try padRight(rw, "[stop]", status_width);
        try rw.writeByte(' ');
        if (explicit_stop_idx) |si| try rw.writeAll(labels[si]) else try rw.writeAll("stop");
        try dialogueRow(f, stop_start, stop_end, 30 + (phrases.len / 2) * 26, row.written());
    }
    return out.toOwnedSlice();
}

// ── ffmpeg ───────────────────────────────────────────────────────────────────

const FfmpegCheck = union(enum) { ok, err: []const u8, err_other: anyerror };

fn ensureFfmpegAvailable(io: Io, opts: Options) FfmpegCheck {
    var child = std.process.spawn(io, .{
        .argv = &.{ opts.ffmpeg, "-version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .err = msg_no_ffmpeg },
        else => return .{ .err_other = err },
    };
    const term = child.wait(io) catch |err| {
        child.kill(io);
        return .{ .err_other = err };
    };
    return if (term.success()) .ok else .{ .err = msg_ffmpeg_broken };
}

const EncodeStatus = union(enum) { done: bool, not_found, err: anyerror };

fn runFfmpeg(gpa: Allocator, io: Io, opts: Options, args: []const []const u8, log_path: []const u8) Allocator.Error!EncodeStatus {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    if (opts.nice) try argv.appendSlice(gpa, &.{ "nice", "-n", "10" });
    try argv.append(gpa, opts.ffmpeg);
    try argv.appendSlice(gpa, args);
    const log: ?Io.File = Io.Dir.cwd().createFile(io, log_path, .{}) catch null;
    defer if (log) |l| l.close(io);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = if (log) |l| .{ .file = l } else .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return .{ .err = err },
    };
    const term = child.wait(io) catch |err| {
        child.kill(io);
        return .{ .err = err };
    };
    return .{ .done = term.success() };
}

fn nowSecs(io: Io, opts: Options) u64 {
    if (opts.now_secs) |s| return s;
    const t = Io.Clock.real.now(io).toSeconds();
    return if (t > 0) @intCast(t) else 0;
}

/// A directory argument safe to prefix onto file names given to ffmpeg (never read as an option).
fn safeDir(d: []const u8, default: []const u8) []const u8 {
    if (d.len == 0) return default;
    return d;
}

fn joinPath(gpa: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    const lead: []const u8 = if (dir[0] == '-') "./" else "";
    if (dir[dir.len - 1] == '/') return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ lead, dir, name });
    return std.fmt.allocPrint(gpa, "{s}{s}/{s}", .{ lead, dir, name });
}

/// Creates `<temp_root>/maqam-live-<16 hex>` with mode 0700. Caller owns the path.
fn makePrivateTempDir(gpa: Allocator, io: Io, temp_root: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        var name: [11 + 16]u8 = undefined;
        const n = std.fmt.bufPrint(&name, "maqam-live-{x:0>16}", .{std.mem.readInt(u64, &rnd, .little)}) catch unreachable;
        const path = try joinPath(gpa, temp_root, n);
        Io.Dir.cwd().createDir(io, path, @fromBackingInt(@intCast(0o700))) catch |err| {
            gpa.free(path);
            if (err == error.PathAlreadyExists and attempt < 8) continue;
            return err;
        };
        return path;
    }
}

fn deleteFileQuiet(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Deletes every file in the private temp dir except `keep` (when given); deletes the directory
/// when nothing is kept.
fn cleanTempDir(io: Io, dir_path: []const u8, names: []const []const u8, keep: ?[]const u8) void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    for (names) |n| {
        if (keep) |k| if (std.mem.eql(u8, k, n)) continue;
        dir.deleteFile(io, n) catch {};
    }
    if (keep == null) Io.Dir.cwd().deleteTree(io, dir_path) catch {};
}

const temp_names = [_][]const u8{
    "maqam-live.wav",  "maqam-live.ass",   "maqam-carpet.png",       "maqam-gosper.png",
    "maqam-jumps.png", "maqam-filter.txt", "maqam-filter-plain.txt", "maqam-ffmpeg.log",
};

fn recordInner(
    gpa: Allocator,
    io: Io,
    shared: *Shared,
    phrases: []const Phrase,
    bpm: f64,
    sustain: f64,
    vcf: VcfBank,
    fx: FxSettings,
    cycle_repeat: usize,
    opts: Options,
) !RecordResult {
    if (phrases.len == 0) return errMsg(gpa, msg_nothing);
    switch (ensureFfmpegAvailable(io, opts)) {
        .ok => {},
        .err => |m| return errMsg(gpa, m),
        .err_other => |e| return errFmt(gpa, "could not check ffmpeg: {s}; make sure ffmpeg runs from your shell, then run m again", .{@errorName(e)}),
    }
    var plan = switch (try buildPlan(gpa, phrases, bpm, sustain, vcf, fx, cycle_repeat)) {
        .ok => |p| p,
        .no_musical => return errMsg(gpa, msg_no_musical),
        .too_long => |samples| return errFmt(gpa, "recording too long: {d:.1} s exceeds the {d} s limit; record fewer cycles or shorter phrases, then run m again", .{ @min(@as(f64, @floatFromInt(samples)) / SR, 1e12), max_render_secs }),
    };
    defer plan.deinit(gpa);

    shared.rec_samples_total.store(plan.render_samples, .monotonic);
    shared.rec_samples_done.store(0, .monotonic);
    shared.rec_active.store(true, .monotonic);
    defer {
        shared.rec_active.store(false, .monotonic);
        shared.rec_samples_done.store(plan.render_samples, .monotonic);
    }

    // rendering
    var mix = try renderMix(gpa, io, shared, phrases, &plan);
    defer mix.deinit(gpa);
    const gain = mix.gain();
    const total_secs = @as(f64, @floatFromInt(mix.left.len)) / SR;

    const temp_root = safeDir(opts.temp_root, "/tmp");
    const out_dir = safeDir(opts.out_dir, ".");
    const tmp = try makePrivateTempDir(gpa, io, temp_root);
    defer gpa.free(tmp);
    var keep_log = false;
    defer cleanTempDir(io, tmp, &temp_names, if (keep_log) "maqam-ffmpeg.log" else null);

    const wav_path = try joinPath(gpa, tmp, "maqam-live.wav");
    defer gpa.free(wav_path);
    try writeWav(io, wav_path, mix, gain);

    const next_diff = try nextDifferent(gpa, plan.seq);
    defer gpa.free(next_diff);

    const ass_path = try joinPath(gpa, tmp, "maqam-live.ass");
    defer gpa.free(ass_path);
    {
        const ass = try buildAss(gpa, &plan, phrases, next_diff, total_secs);
        defer gpa.free(ass);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = ass_path, .data = ass });
    }

    const carpet_path = try joinPath(gpa, tmp, "maqam-carpet.png");
    defer gpa.free(carpet_path);
    _ = try carpet.writeCarpetBackground(gpa, io, Io.Dir.cwd(), carpet_path, &.{}, phrases);
    const gosper_path = try joinPath(gpa, tmp, "maqam-gosper.png");
    defer gpa.free(gosper_path);
    _ = try carpet.writeCenterGosperOverlay(gpa, io, Io.Dir.cwd(), gosper_path, phrases);
    const jumps_path = try joinPath(gpa, tmp, "maqam-jumps.png");
    defer gpa.free(jumps_path);
    _ = try carpet.writeJumpArrowsOverlay(gpa, io, Io.Dir.cwd(), jumps_path, phrases);

    const highlight_chain = try buildCarpetTickHighlights(gpa, &plan, phrases, next_diff);
    defer gpa.free(highlight_chain);
    const gosper_rotation = try buildCenterGosperRotationExpr(gpa, &plan, phrases);
    defer gpa.free(gosper_rotation);
    const gosper_chain = try std.fmt.allocPrint(gpa, "[2:v]format=rgba,colorkey=0x000000:0.02:0.05,rotate='{s}':ow=iw:oh=ih:c=black@0[gosper];[3:v]format=rgba,colorkey=0x000000:0.003:0.02[jumps];[1:v][gosper]overlay=format=auto[carpet0];[carpet0][jumps]overlay=format=auto[carpet1];[carpet1]{s}[carpet]", .{ gosper_rotation, highlight_chain });
    defer gpa.free(gosper_chain);
    const ass_filter_path = try filterPath(gpa, ass_path);
    defer gpa.free(ass_filter_path);
    const filter_with_subs = try std.fmt.allocPrint(gpa, "{s};[0:a]showwaves=s=1280x360:mode=cline:rate=30:colors=0x20140C,pad=1280:720:0:360:color=black,colorkey=0x000000:0.04:0.25,format=rgba,colorchannelmixer=aa=0.16[wv];[carpet][wv]overlay=format=auto[base];[base]subtitles={s}[v]", .{ gosper_chain, ass_filter_path });
    defer gpa.free(filter_with_subs);
    const filter_plain = try std.fmt.allocPrint(gpa, "{s};[0:a]showwaves=s=1280x360:mode=cline:rate=30:colors=0x20140C,pad=1280:720:0:360:color=black,colorkey=0x000000:0.04:0.25,format=rgba,colorchannelmixer=aa=0.16[wv];[carpet][wv]overlay=format=auto[v]", .{gosper_chain});
    defer gpa.free(filter_plain);
    const fscript_path = try joinPath(gpa, tmp, "maqam-filter.txt");
    defer gpa.free(fscript_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fscript_path, .data = filter_with_subs });
    const plain_inline = filter_plain.len <= max_inline_filter;
    const fplain_path = try joinPath(gpa, tmp, "maqam-filter-plain.txt");
    defer gpa.free(fplain_path);
    if (!plain_inline) try Io.Dir.cwd().writeFile(io, .{ .sub_path = fplain_path, .data = filter_plain });

    const ts = nowSecs(io, opts);
    var name_buf: [64]u8 = undefined;
    const out = try joinPath(gpa, out_dir, std.fmt.bufPrint(&name_buf, "maqam-{d}.mp4", .{ts}) catch unreachable);
    var out_returned = false;
    defer if (!out_returned) gpa.free(out);
    // ffmpeg creates its output before it has written the MP4's moov atom. Encode to a hidden
    // staging file so a failed or interrupted recording is never presented as a finished movie.
    const staged_out = try joinPath(gpa, out_dir, std.fmt.bufPrint(&name_buf, ".maqam-{d}.partial.mp4", .{ts}) catch unreachable);
    defer gpa.free(staged_out);
    const log_path = try joinPath(gpa, tmp, "maqam-ffmpeg.log");
    defer gpa.free(log_path);

    // encoding
    var renamed = false;
    defer if (!renamed) deleteFileQuiet(io, staged_out);
    const head = [_][]const u8{
        "-y",    "-i", wav_path,
        "-loop", "1",  "-framerate",
        "30",    "-i", carpet_path,
        "-loop", "1",  "-framerate",
        "30",    "-i", gosper_path,
        "-loop", "1",  "-framerate",
        "30",    "-i", jumps_path,
    };
    const tail = [_][]const u8{
        "-map",     "[v]", "-map", "0:a",  "-c:v",     "libx264", "-preset",   "veryfast",
        "-threads", "1",   "-crf", "18",   "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        "-c:a",     "aac", "-b:a", "320k", "-r",       "30",      "-shortest", staged_out,
    };
    const args1 = head ++ [_][]const u8{ "-filter_complex_script", fscript_path } ++ tail;
    var encoded = switch (try runFfmpeg(gpa, io, opts, &args1, log_path)) {
        .done => |ok| ok,
        .not_found => return errMsg(gpa, msg_no_ffmpeg),
        .err => |e| return errFmt(gpa, "could not start ffmpeg: {s}; make sure ffmpeg runs from your shell, then run m again", .{@errorName(e)}),
    };
    if (!encoded) {
        const args2 = head ++ (if (plain_inline)
            [_][]const u8{ "-filter_complex", filter_plain }
        else
            [_][]const u8{ "-filter_complex_script", fplain_path }) ++ tail;
        encoded = switch (try runFfmpeg(gpa, io, opts, &args2, log_path)) {
            .done => |ok| ok,
            .not_found => return errMsg(gpa, msg_no_ffmpeg),
            .err => |e| return errFmt(gpa, "could not start ffmpeg: {s}; make sure ffmpeg runs from your shell, then run m again", .{@errorName(e)}),
        };
    }
    if (!encoded) {
        keep_log = true;
        return errFmt(gpa, "ffmpeg failed to create MP4; read {s}, fix the ffmpeg error shown there, then run m again", .{log_path});
    }
    // written -> saved
    try Io.Dir.cwd().rename(staged_out, Io.Dir.cwd(), out, io);
    renamed = true;
    out_returned = true;
    return .{ .ok = out };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "floats format as Rust {:.p} does (exact value, ties to even)" {
    var buf: [128]u8 = undefined;
    const got = try std.fmt.bufPrint(&buf, "{f} {f} {f} {f} {f} {f} {f} {f} {f} {f}", .{
        fixed(1.25, 1),              fixed(0.35, 1), fixed(@as(f32, 552.5), 0), fixed(@as(f32, 553.5), 0),
        fixed(0.0, 6),               fixed(9.0, 6),  fixed(0.2499, 6),          fixed(-0.04, 1),
        fixed(std.math.nan(f64), 1), fixed(2.5, 0),
    });
    try testing.expectEqualStrings("1.2 0.3 552 554 0.000000 9.000000 0.249900 -0.0 NaN 2", got);
}

test "empty_recording_error_tells_user_what_to_do" {
    const gpa = testing.allocator;
    var shared: Shared = .{};
    const r = recordCycle(gpa, testing.io, &shared, &.{}, 120.0, 1.25, .{}, .{}, 1);
    defer r.deinit(gpa);
    try testing.expectEqualStrings(msg_nothing, r.err);
}

test "missing_ffmpeg_error_tells_user_what_to_do" {
    const gpa = testing.allocator;
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var shared: Shared = .{};
    const r = recordCycleWith(gpa, testing.io, &shared, phrases, 120.0, 1.25, .{}, .{}, 1, .{
        .ffmpeg = "maqam-live-definitely-missing-ffmpeg-test-binary",
    });
    defer r.deinit(gpa);
    try testing.expectEqualStrings(msg_no_ffmpeg, r.err);
    try testing.expect(!shared.rec_active.load(.monotonic));
}

test "the mix is deterministic for a seed, 44.1 kHz, and peak-normalized to 0.9" {
    const gpa = testing.allocator;
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var plan = switch (try buildPlan(gpa, phrases, 120.0, 1.25, .{}, .{}, 1)) {
        .ok => |p| p,
        else => return error.TestUnexpectedResult,
    };
    defer plan.deinit(gpa);
    // j 0 2: phrase 0, phrase 1, back once, phrase 0, phrase 1, then on.
    try testing.expectEqual(@as(usize, 4), plan.seq.len);
    try testing.expectEqual(@as(?usize, 2), plan.seq[2].arrived_via_jump);
    // Length: the bars at 120 bpm (0.25 s subdivisions: 8 and 10 of them) plus sustain + 1 s.
    const expect_samples = 2 * (88200 + 110250) + 99225;
    try testing.expectEqual(@as(usize, expect_samples), plan.render_samples);

    var shared: Shared = .{};
    synth.seedRng(42);
    var a = try renderMix(gpa, null, &shared, phrases, &plan);
    defer a.deinit(gpa);
    synth.seedRng(42);
    var b = try renderMix(gpa, null, null, phrases, &plan);
    defer b.deinit(gpa);
    try testing.expectEqualSlices(f32, a.left, b.left);
    try testing.expectEqualSlices(f32, a.right, b.right);
    try testing.expectEqual(plan.render_samples, a.left.len);
    try testing.expectEqual(plan.render_samples, shared.rec_samples_done.load(.monotonic) + plan.tail_samples);
    synth.seedRng(43);
    var c = try renderMix(gpa, null, null, phrases, &plan);
    defer c.deinit(gpa);
    try testing.expect(!std.mem.eql(f32, a.left, c.left));

    const g = a.gain();
    var peak: f32 = 0;
    for (a.left, a.right) |l, r| peak = @max(peak, @max(@abs(l * g), @abs(r * g)));
    try testing.expectApproxEqAbs(@as(f32, 0.9), peak, 1e-5);

    // The WAV the recorder hands ffmpeg is 44100 Hz stereo 16-bit with that peak.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/m.wav", .{tmp.sub_path});
    defer gpa.free(path);
    try writeWav(testing.io, path, a, g);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "m.wav", gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 44 + 4 * plan.render_samples), bytes.len);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little));
    try testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, bytes[24..28], .little));
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little));
    var max_abs: i32 = 0;
    var i: usize = 44;
    while (i < bytes.len) : (i += 2) max_abs = @max(max_abs, @as(i32, @intCast(@abs(std.mem.readInt(i16, bytes[i..][0..2], .little)))));
    try testing.expect(max_abs >= 29489 and max_abs <= 29491); // 0.9 * 32767, truncated
}

test "long sessions are bounded" {
    const gpa = testing.allocator;
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    // 1000 cycles of ~9 s is far past 600 s.
    const r = try buildPlan(gpa, phrases, 120.0, 1.25, .{}, .{}, 1000);
    try testing.expect(r == .too_long);
    // Absurd inputs saturate instead of overflowing or panicking.
    try testing.expect((try buildPlan(gpa, phrases, 120.0, 1.25, .{}, .{}, std.math.maxInt(usize))) == .too_long);
    try testing.expect((try buildPlan(gpa, phrases, 0.0, 1.25, .{}, .{}, 1)) == .too_long);
    try testing.expect((try buildPlan(gpa, phrases, std.math.nan(f64), std.math.inf(f64), .{}, .{}, 1)) == .too_long);
    // Through the public entry point (the ffmpeg check comes first, as upstream, so the stand-in
    // is `true`, which answers -version successfully), with the message.
    var shared: Shared = .{};
    const rr = recordCycleWith(gpa, testing.io, &shared, phrases, 120.0, 1.25, .{}, .{}, 1000, .{ .ffmpeg = "true" });
    defer rr.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, rr.err, "recording too long: "));
    try testing.expect(!shared.rec_active.load(.monotonic));
}

test "a cycle of always-jumps without music ends instead of hanging" {
    const gpa = testing.allocator;
    var phrases: [2]Phrase = undefined;
    var j0 = try sequencer.buildJumpEntry(gpa, 0, 1, null, 0);
    phrases[0] = j0.ok;
    var j1 = try sequencer.buildJumpEntry(gpa, 1, 0, null, 0);
    phrases[1] = j1.ok;
    defer j0.deinit(gpa);
    defer j1.deinit(gpa);
    try testing.expect((try buildPlan(gpa, &phrases, 120.0, 1.0, .{}, .{}, 1)) == .no_musical);
}

test "filter pieces: highlights, rotation, subtitles path" {
    const gpa = testing.allocator;
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var plan = (try buildPlan(gpa, phrases, 120.0, 1.25, .{}, .{}, 2)).ok;
    defer plan.deinit(gpa);
    const nd = try nextDifferent(gpa, plan.seq);
    defer gpa.free(nd);
    try testing.expectEqual(@as(?usize, 1), nd[0]);
    try testing.expectEqual(@as(?usize, null), nd[nd.len - 1]);
    const hl = try buildCarpetTickHighlights(gpa, &plan, phrases, nd);
    defer gpa.free(hl);
    try testing.expect(std.mem.startsWith(u8, hl, "drawbox=x="));
    try testing.expect(std.mem.indexOf(u8, hl, ":color=0x666666@0.72:t=fill:enable='between(t,0.000000,") != null);
    try testing.expect(std.mem.indexOf(u8, hl, "0xD8B060@0.70") != null); // the arrival via j 0 2
    const rot = try buildCenterGosperRotationExpr(gpa, &plan, phrases);
    defer gpa.free(rot);
    try testing.expect(std.mem.indexOf(u8, rot, "between(mod(t,") != null);
    try testing.expectEqual(std.mem.count(u8, rot, "("), std.mem.count(u8, rot, ")"));
    const p1 = try filterPath(gpa, "/tmp/maqam-live-00ff/maqam-live.ass");
    defer gpa.free(p1);
    try testing.expectEqualStrings("/tmp/maqam-live-00ff/maqam-live.ass", p1);
    const p2 = try filterPath(gpa, "/t m:p/a'b,c");
    defer gpa.free(p2);
    try testing.expectEqualStrings("/t m\\\\:p/a\\\\\\'b\\,c", p2);
}

test "subtitles show every timeline row and the virtual stop" {
    const gpa = testing.allocator;
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var plan = (try buildPlan(gpa, phrases, 120.0, 1.25, .{}, .{}, 1)).ok;
    defer plan.deinit(gpa);
    const nd = try nextDifferent(gpa, plan.seq);
    defer gpa.free(nd);
    const total_secs = @as(f64, @floatFromInt(plan.render_samples)) / SR;
    const ass = try buildAss(gpa, &plan, phrases, nd, total_secs);
    defer gpa.free(ass);
    try testing.expect(std.mem.startsWith(u8, ass, "[Script Info]\nScriptType: v4.00+\n"));
    // Rust's {:.1} rounds the exact 1.25 to even: "1.2".
    try testing.expect(std.mem.indexOf(u8, ass, "Dialogue: 2,0:00:00.00,0:00:02.00,Line,,0,0,0,,{\\1c&H00A0FF70&}   bpm:120  sus:1.2s\n") != null);
    try testing.expect(std.mem.indexOf(u8, ass, "JumpCounter,,0,0,0,,{\\pos(") != null);
    try testing.expect(std.mem.indexOf(u8, ass, "•{\\1c&H0000FF00&}\\h\\h0:\\h▶\\h") != null);
    try testing.expect(std.mem.indexOf(u8, ass, "---:\\h▶\\h") != null); // the virtual stop
    try testing.expect(std.mem.indexOf(u8, ass, "┌──>") != null);
}

/// Names in `dir` starting with `prefix`.
fn countPrefixed(io: Io, dir: Io.Dir, prefix: []const u8, contains: []const u8) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, prefix) and std.mem.indexOf(u8, e.name, contains) != null) n += 1;
    }
    return n;
}

test "a forced ffmpeg failure leaves no mp4, no partial and no temp files but the log" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    try tmp.dir.createDir(io, "out", .default_dir);
    try tmp.dir.createDir(io, "temp", .default_dir);
    // A stand-in ffmpeg that answers -version, then creates the partial output and fails.
    try tmp.dir.writeFile(io, .{
        .sub_path = "fake-ffmpeg",
        .data = "#!/bin/sh\n[ \"$1\" = -version ] && exit 0\nfor a; do last=$a; done\n: > \"$last\"\necho boom >&2\nexit 1\n",
        .flags = .{ .permissions = .executable_file },
    });
    const fake = try std.fmt.allocPrint(gpa, "{s}/fake-ffmpeg", .{base});
    defer gpa.free(fake);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/out", .{base});
    defer gpa.free(out_dir);
    const temp_root = try std.fmt.allocPrint(gpa, "{s}/temp", .{base});
    defer gpa.free(temp_root);

    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var shared: Shared = .{};
    const r = recordCycleWith(gpa, io, &shared, phrases, 240.0, 0.2, .{}, .{}, 1, .{
        .ffmpeg = fake,
        .nice = false,
        .out_dir = out_dir,
        .temp_root = temp_root,
        .now_secs = 1234,
    });
    defer r.deinit(gpa);
    try testing.expect(r == .err);
    try testing.expect(std.mem.startsWith(u8, r.err, "ffmpeg failed to create MP4; read "));
    try testing.expect(std.mem.endsWith(u8, r.err, "/maqam-ffmpeg.log, fix the ffmpeg error shown there, then run m again"));
    try testing.expect(!shared.rec_active.load(.monotonic));
    try testing.expectEqual(shared.rec_samples_total.load(.monotonic), shared.rec_samples_done.load(.monotonic));

    var od = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer od.close(io);
    try testing.expectEqual(@as(usize, 0), try countPrefixed(io, od, "", ""));
    // The temp root holds only the private dir with the log the message names.
    var td = try tmp.dir.openDir(io, "temp", .{ .iterate = true });
    defer td.close(io);
    var it = td.iterate();
    var dirs: usize = 0;
    while (try it.next(io)) |e| {
        dirs += 1;
        try testing.expect(std.mem.startsWith(u8, e.name, "maqam-live-"));
        var pd = try td.openDir(io, e.name, .{ .iterate = true });
        defer pd.close(io);
        var pit = pd.iterate();
        var files: usize = 0;
        while (try pit.next(io)) |f| {
            files += 1;
            try testing.expectEqualStrings("maqam-ffmpeg.log", f.name);
        }
        try testing.expectEqual(@as(usize, 1), files);
        const log = try pd.readFileAlloc(io, "maqam-ffmpeg.log", gpa, .limited(4096));
        defer gpa.free(log);
        try testing.expectEqualStrings("boom\n", log);
    }
    try testing.expectEqual(@as(usize, 1), dirs);
}

test "a failure before encoding leaves nothing at all" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    try tmp.dir.createDir(io, "temp", .default_dir);
    const temp_root = try std.fmt.allocPrint(gpa, "{s}/temp", .{base});
    defer gpa.free(temp_root);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/no-such-dir/out", .{base});
    defer gpa.free(out_dir);
    // `true` passes -version and "encodes" successfully without writing; the rename then fails
    // because the output directory does not exist.
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var shared: Shared = .{};
    const r = recordCycleWith(gpa, io, &shared, phrases, 240.0, 0.2, .{}, .{}, 1, .{
        .ffmpeg = "true",
        .nice = false,
        .out_dir = out_dir,
        .temp_root = temp_root,
    });
    defer r.deinit(gpa);
    try testing.expect(r == .err);
    try testing.expect(std.mem.startsWith(u8, r.err, "could not record: "));
    var td = try tmp.dir.openDir(io, "temp", .{ .iterate = true });
    defer td.close(io);
    try testing.expectEqual(@as(usize, 0), try countPrefixed(io, td, "", ""));
}

test "end to end: a two-phrase timeline becomes an mp4 when ffmpeg is installed" {
    const gpa = testing.allocator;
    const io = testing.io;
    switch (ensureFfmpegAvailable(io, .{})) {
        .ok => {},
        else => return, // no ffmpeg: only the encode step is skipped (the tests above cover the rest)
    }
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    try tmp.dir.createDir(io, "temp", .default_dir);
    const temp_root = try std.fmt.allocPrint(gpa, "{s}/temp", .{base});
    defer gpa.free(temp_root);
    const phrases = try carpet.testTimeline(gpa);
    defer carpet.freeTimeline(gpa, phrases);
    var shared: Shared = .{};
    const r = recordCycleWith(gpa, io, &shared, phrases, 240.0, 0.2, .{}, .{}, 1, .{
        .out_dir = base,
        .temp_root = temp_root,
        .now_secs = 42,
    });
    defer r.deinit(gpa);
    switch (r) {
        .ok => |path| {
            const want = try std.fmt.allocPrint(gpa, "{s}/maqam-42.mp4", .{base});
            defer gpa.free(want);
            try testing.expectEqualStrings(want, path);
            const st = try tmp.dir.statFile(io, "maqam-42.mp4", .{});
            try testing.expect(st.size > 1000);
            try tmp.dir.deleteFile(io, "maqam-42.mp4");
        },
        .err => |m| {
            std.debug.print("recording failed: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqual(@as(usize, 0), try countPrefixed(io, tmp.dir, ".maqam-", "partial"));
    var td = try tmp.dir.openDir(io, "temp", .{ .iterate = true });
    defer td.close(io);
    try testing.expectEqual(@as(usize, 0), try countPrefixed(io, td, "", ""));
}
