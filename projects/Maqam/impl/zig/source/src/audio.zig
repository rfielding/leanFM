//! Port of maqam-live `src/audio.rs` (the output callback state of `start_audio`, `tick_sequencer`,
//! `SympatheticBank`, `FilterBank`, `StereoFilter`, `make_bar_states`, `vcf_target_for_kind`) and of
//! the audio statics of `src/main.rs` (published through shared.zig), plus the offline render and
//! bench hooks of the specification (markdown "comparison").
//!
//! Three-level hierarchy: subdivision -> group -> phrase.
//! Level 1: every subdivision fires a melody note (degree walk).
//! Level 2: kicks land on structural group degrees (higher-level melody).
//! Level 3: phrase start = root note rings long (highest-level melody);
//!          phrase end   = turnaround accent (highest-level rhythm marker).
//!
//! `Engine` is the callback state. The App pushes `AudioCmd`s into `Engine.cmds` (a lock-free SPSC
//! ring of 512, the specification's bound) and pops what the engine releases from `Engine.garbage`
//! (`collectGarbage`). `Engine.process` matches `device.Process`: it drains the commands with
//! `tryRecv` and renders one block. The process path never allocates, frees, locks, logs, or touches
//! files or the network (proof "The audio callback never blocks"): everything is preallocated by
//! `Engine.create`, and the tests run whole sessions through it with an allocator that fails.
//!
//! Bounds (specification markdown "bounds"; the Rust grows Vecs and HashMaps here):
//! * timeline: `max_phrases` = 4096 playing entries (shared.max_entries); an entry added or
//!   inserted beyond it is handed straight back on the garbage ring.
//! * voices: `max_voices` = 1024 (synth.voice_capacity); a voice that does not fit is dropped,
//!   newest first (synth's `appendBounded`).
//! * jump counters: a fixed open-addressing table of `jump_table_capacity` = 8192 entry ids,
//!   cleared by Clear; a jump whose id does not fit reads as exhausted (it falls through).
//!   Counters are published per entry into `Shared.jump_counters` (atomics, never a lock).
//! * sympathetic targets: at most `max_target_frequencies` = 1024 scale frequencies and
//!   `max_weighted_targets` = 1024 (frequency, weight) pairs per retune (the strings themselves keep
//!   at most 64 targets, as upstream); each partition's mode list lives in a 64 KiB slab (2340
//!   modes) of a preallocated slab allocator, so retuning on the audio path never touches the heap.
//! * garbage: the ring holds 1024; what does not fit waits in a fixed pending list of
//!   `max_pending_garbage` = 4160 and is retried every block, never freed by the engine. A command
//!   is drained only while the pending list could absorb the worst case it may release (the whole
//!   timeline), otherwise it waits in the command ring for the next block.
//! * blocks: `create`'s `max_frames`; a longer device block is processed in chunks of it.
//!
//! Deliberate differences from the Rust:
//! * No cpal: the device is device.Output (ALSA on Linux, CoreAudio on macOS, at 48000 Hz / --bufsize
//!   frames with capture; `startLive`),
//!   and its input arrives per block (`input` frames of the same block; frames past `input.len` are
//!   silence), not through a 16384-frame crossbeam queue.
//! * Mutex `try_lock` on JUMP_COUNTERS and Vec/HashMap growth are replaced by the bounds above.
//!   Released phrases and NAM models go back to the App on the garbage ring instead of being
//!   dropped in the callback.
//! * Stereo output only (device.Process is interleaved stereo; the Rust also handles mono devices).
//! * Block-structured rendering (the 64-frame reverb stutter of upstream, Known gaps): the
//!   sequencer, voice spawning and the voice mix still run per sample exactly as upstream, but the
//!   stages after the voice mix (live input, NAM, sympathetic strings, VCF bus filters, FX, clip) run
//!   over segments of samples between state changes (a control entry, a subdivision event, a
//!   retune), so no state is ever applied earlier or later than upstream. Within a segment:
//!   - NAM runs once per segment with `Model.processBuffer` (upstream: per sample).
//!   - The sympathetic resonators compute their drift, radius and coefficient once per segment
//!     (upstream: `pow`, `cos`, `sin` per mode per sample; the drift LFO is at most 0.32 Hz, a
//!     segment at most `max_frames`), advance the drift phase by the segment length in one step,
//!     skip modes that are exactly at rest with no drive (their output is exactly 0), and drop
//!     silent untargeted modes at the end of the segment instead of after every sample. This
//!     re-implements `SympatheticStrings.process` over a block (sympathetics.zig is unchanged).
//!   - With nothing else sounding, upstream zeroes the output (and resets the VCF filters) at the
//!     first sample the sympathetic strings fall silent; here that is decided at the start of each
//!     segment (strings still ringing at the start keep the segment audible: they are below 1e-5).
//! * Input level and latency publication: every 10 s of rendered samples (upstream: 10 s of the
//!   wall clock, a clock read per sample); levels are published as f32 bit patterns (shared.zig).
//!   Latency: there are no device timestamps, so capture-to-playback latency is estimated as one
//!   block plus the device's reported playback delay (`Engine.device_delay_us`, set by
//!   `startLive`), smoothed per block (upstream per frame); `measure_input_latency` is answered
//!   with that estimate on the App's mailbox at the next block with input.
//! * `Shared.cycles` counts wraps from the last row to the first and `Shared.phrase_starts` counts
//!   PhraseStart milestones (new; the render hook and the event log read them), and
//!   `Engine.stops_seen` counts T (stop) rows the sequencer passed (it skips them, as upstream).
//! * The next-phrase look-ahead of `tick_sequencer` (O(n^2) per sample upstream) is cached and
//!   recomputed only when the timeline, the queued phrase, a jump counter or the current phrase
//!   changes; its result is the same.
//! * ResetSessionState and set_nam_model reset/replace in place (no allocation); a model they
//!   replace goes to the garbage ring.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const analog = @import("analog.zig");
const channel = @import("channel.zig");
const command = @import("command.zig");
const device = @import("device.zig");
const fx_mod = @import("fx.zig");
const nam = @import("nam.zig");
const sequencer = @import("sequencer.zig");
const session = @import("session.zig");
const shared_mod = @import("shared.zig");
const sympathetics = @import("sympathetics.zig");
const synth = @import("synth.zig");
const vcf_mod = @import("vcf.zig");

pub const Shared = shared_mod.Shared;
pub const Frame = device.Frame;
const AudioCmd = sequencer.AudioCmd;
const Garbage = sequencer.Garbage;
const Phrase = sequencer.Phrase;
const ControlSpec = sequencer.ControlSpec;
const SubdivEvent = sequencer.SubdivEvent;
const LatencyResult = sequencer.LatencyResult;
const NamInput = command.NamInput;
const SympatheticChange = command.SympatheticChange;
const SympatheticHarmony = command.SympatheticHarmony;
const SympatheticTarget = command.SympatheticTarget;
const FxSettings = fx_mod.FxSettings;
const FxProcessor = fx_mod.FxProcessor;
const VcfBank = vcf_mod.VcfBank;
const VcfSettings = vcf_mod.VcfSettings;
const VcfTarget = vcf_mod.VcfTarget;
const VcoWave = vcf_mod.VcoWave;
const MoogLadder = vcf_mod.MoogLadder;
const SympatheticStrings = sympathetics.SympatheticStrings;
const WeightedFrequency = sympathetics.WeightedFrequency;
const Mode = std.meta.Child(@FieldType(SympatheticStrings, "modes").Slice);
const Voice = synth.Voice;
const VoiceKind = synth.VoiceKind;
const Milestone = synth.Milestone;

pub const max_phrases: usize = shared_mod.max_entries;
pub const max_voices: usize = synth.voice_capacity;
pub const cmd_capacity: usize = 512;
pub const garbage_capacity: usize = 1024;
pub const max_pending_garbage: usize = max_phrases + 64;
pub const jump_table_capacity: usize = 8192;
pub const max_target_frequencies: usize = 1024;
pub const max_weighted_targets: usize = 1024;
/// Block size of the offline render.
pub const render_block_frames: u32 = 256;
/// Longest offline render, in seconds of audio.
pub const render_cap_seconds: u32 = 600;

const slab_size: usize = 64 * 1024;
const slab_count: usize = 8;
const scratch_bytes: usize = 2048;
const TAU32: f32 = std.math.tau;
const FRAC_PI_4: f32 = std.math.pi / 4.0;

/// Rust `f32::clamp` (NaN passes through).
fn fclamp(x: f32, lo: f32, hi: f32) f32 {
    var v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

/// Rust `f64 as usize` (saturating, NaN -> 0).
fn f64ToUsize(x: f64) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551615.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

// ── Slab allocator (the sympathetic strings' mode lists and their retune scratch) ─────────────

/// A fixed set of equal slabs: `alloc` takes a free slab, `resize`/`remap` succeed in place up to
/// the slab size, `free` returns the slab. Lets `SympatheticStrings.setTargets` (which takes an
/// allocator) run on the audio path without touching the heap.
const SlabAllocator = struct {
    mem: []align(16) u8,
    used: [slab_count]bool = @splat(false),

    fn allocator(self: *SlabAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
        if (len > slab_size or alignment.toByteUnits() > 16) return null;
        for (&self.used, 0..) |*u, i| {
            if (!u.*) {
                u.* = true;
                return self.mem.ptr + i * slab_size;
            }
        }
        return null;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        return new_len <= slab_size;
    }

    fn remap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        return if (new_len <= slab_size) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
        const i = (@intFromPtr(memory.ptr) - @intFromPtr(self.mem.ptr)) / slab_size;
        if (i < slab_count) self.used[i] = false;
    }
};

// ── Playback state ────────────────────────────────────────────────────────────

/// A playing timeline entry: the phrase (owned by the engine until released) and its one bar state
/// (the Rust `bar_states` always holds exactly one).
const PlayingPhrase = struct {
    phrase: *Phrase,
    subdiv_samples: f64,
    bar_pos: usize = 0,
    last_subdiv: ?usize = null,
    plays_done: usize = 0,

    fn init(phrase: *Phrase, sr: f64, bpm: f64) PlayingPhrase {
        var pp: PlayingPhrase = .{ .phrase = phrase, .subdiv_samples = 0 };
        pp.rebuild(sr, bpm);
        return pp;
    }

    /// `make_bar_states`: a fresh bar state at the new tempo.
    fn rebuild(self: *PlayingPhrase, sr: f64, bpm: f64) void {
        const subdiv_secs = 60.0 / (bpm * 2.0);
        self.subdiv_samples = sr * subdiv_secs;
        self.bar_pos = 0;
        self.last_subdiv = null;
    }

    /// Reset to the very beginning of this phrase (plays_done=0, bar_pos=0).
    fn reset(self: *PlayingPhrase) void {
        self.plays_done = 0;
        self.bar_pos = 0;
        self.last_subdiv = null;
    }
};

/// Entry id -> completed jump-backs (the Rust `HashMap<usize, usize>`), fixed capacity.
const JumpTable = struct {
    const empty = std.math.maxInt(usize);
    keys: []usize,
    values: []usize,

    fn init(gpa: Allocator) !JumpTable {
        const keys = try gpa.alloc(usize, jump_table_capacity);
        errdefer gpa.free(keys);
        const values = try gpa.alloc(usize, jump_table_capacity);
        @memset(keys, empty);
        @memset(values, 0);
        return .{ .keys = keys, .values = values };
    }

    fn deinit(self: *JumpTable, gpa: Allocator) void {
        gpa.free(self.keys);
        gpa.free(self.values);
    }

    fn slot(self: *const JumpTable, id: usize) ?usize {
        var i = std.hash.int(id) % jump_table_capacity;
        for (0..jump_table_capacity) |_| {
            if (self.keys[i] == id) return i;
            if (self.keys[i] == empty) return null;
            i = (i + 1) % jump_table_capacity;
        }
        return null;
    }

    fn get(self: *const JumpTable, id: usize) ?usize {
        return if (self.slot(id)) |i| self.values[i] else null;
    }

    /// The counter of `id`, inserted at 0; null when the table is full (or `id` is the sentinel).
    fn getOrPut(self: *JumpTable, id: usize) ?*usize {
        if (id == empty) return null;
        var i = std.hash.int(id) % jump_table_capacity;
        for (0..jump_table_capacity) |_| {
            if (self.keys[i] == id) return &self.values[i];
            if (self.keys[i] == empty) {
                self.keys[i] = id;
                self.values[i] = 0;
                return &self.values[i];
            }
            i = (i + 1) % jump_table_capacity;
        }
        return null;
    }

    fn clear(self: *JumpTable) void {
        @memset(self.keys, empty);
    }
};

// ── Sympathetic strings ───────────────────────────────────────────────────────

const SympatheticPartition = struct {
    strings: SympatheticStrings,
    enabled: bool,
    amount: f32,

    fn reset(self: *SympatheticPartition, sr: f32, amount: f32) void {
        var modes = self.strings.modes;
        modes.clearRetainingCapacity();
        self.strings = SympatheticStrings.new(sr);
        self.strings.modes = modes;
        self.enabled = true;
        self.amount = amount;
    }
};

/// Per-segment scratch of the block resonator.
const SymScratch = struct {
    sust: []f32,
    strike: []f32,
    sum: []f32,
};

const SympatheticBank = struct {
    sr: f32,
    mic: SympatheticPartition,
    kanun: SympatheticPartition,
    bass: SympatheticPartition,
    drums: SympatheticPartition,
    target_frequencies: [max_target_frequencies]f64 = undefined,
    target_len: usize = 0,
    interval_ratio: f64 = 1.0,
    harmony: ?SympatheticHarmony = null,
    weighted: [max_weighted_targets]WeightedFrequency = undefined,
    shifted: [max_target_frequencies]f64 = undefined,
    slab: *SlabAllocator,

    /// `SympatheticBank::new`, with each partition's modes preallocated in its own slab.
    fn init(self: *SympatheticBank, sr: f32, slab: *SlabAllocator) !void {
        self.sr = sr;
        self.slab = slab;
        self.target_len = 0;
        self.interval_ratio = 1.0;
        self.harmony = null;
        const a = slab.allocator();
        const amounts = [4]f32{ 1.0, 0.0, 0.0, 0.0 };
        for (self.partitions(), amounts) |p, amount| {
            p.* = .{ .strings = SympatheticStrings.new(sr), .enabled = true, .amount = amount };
            try p.strings.modes.ensureTotalCapacityPrecise(a, slab_size / @sizeOf(Mode));
        }
    }

    /// `SympatheticBank::new` again, in place (no allocation).
    fn reset(self: *SympatheticBank) void {
        const amounts = [4]f32{ 1.0, 0.0, 0.0, 0.0 };
        for (self.partitions(), amounts) |p, amount| p.reset(self.sr, amount);
        self.target_len = 0;
        self.interval_ratio = 1.0;
        self.harmony = null;
    }

    fn partitions(self: *SympatheticBank) [4]*SympatheticPartition {
        return .{ &self.mic, &self.kanun, &self.bass, &self.drums };
    }

    fn setTargets(self: *SympatheticBank, frequencies: []const f64) void {
        const n = @min(frequencies.len, max_target_frequencies);
        @memcpy(self.target_frequencies[0..n], frequencies[0..n]);
        self.target_len = n;
        self.applyTargets();
    }

    fn applyTargets(self: *SympatheticBank) void {
        const a = self.slab.allocator();
        if (self.harmony) |harmony| {
            const weighted = self.weightedTargets(harmony);
            for (self.partitions()) |p| p.strings.setWeightedTargets(a, weighted) catch {};
        } else {
            const freqs = self.target_frequencies[0..self.target_len];
            for (freqs, 0..) |f, i| self.shifted[i] = f * self.interval_ratio;
            const shifted = self.shifted[0..freqs.len];
            for (self.partitions()) |p| p.strings.setTargets(a, shifted) catch {};
        }
    }

    fn weightedTargets(self: *SympatheticBank, harmony: SympatheticHarmony) []const WeightedFrequency {
        const comps = harmony.items();
        var total: f32 = 0.0;
        for (comps) |c| total += @max(c.weight, 0.0);
        const total_weight = @max(total, 1.0);
        var n: usize = 0;
        outer: for (self.target_frequencies[0..self.target_len]) |frequency| {
            for (comps) |c| {
                if (n >= max_weighted_targets) break :outer;
                self.weighted[n] = .{ .frequency = frequency * c.ratio, .weight = @max(c.weight, 0.0) / total_weight };
                n += 1;
            }
        }
        return self.weighted[0..n];
    }

    fn hasEnergy(self: *SympatheticBank) bool {
        return self.mic.strings.hasEnergy() or self.kanun.strings.hasEnergy() or
            self.bass.strings.hasEnergy() or self.drums.strings.hasEnergy();
    }

    /// `SympatheticBank::process` over a run of samples, added into `out`.
    fn processRun(self: *SympatheticBank, master: bool, mic: []const f32, kanun: []const f32, bass: []const f32, drums: []const f32, out: []f32, s: SymScratch) void {
        partitionRun(&self.mic, master, mic, out, s);
        partitionRun(&self.kanun, master, kanun, out, s);
        partitionRun(&self.bass, master, bass, out, s);
        partitionRun(&self.drums, master, drums, out, s);
    }

    fn applyChange(self: *SympatheticBank, change: SympatheticChange, master_enabled: *bool) void {
        if (change.target == null) {
            if (change.enabled) |value| master_enabled.* = value;
        }
        switch (change.target orelse .all) {
            .all => for ([_]SympatheticTarget{ .mic, .kanun, .bass, .drums }) |t| self.applyPartitionChange(t, change),
            else => |t| self.applyPartitionChange(t, change),
        }
        if (change.mic) |v| self.mic.amount = v;
        if (change.kanun) |v| self.kanun.amount = v;
        if (change.bass) |v| self.bass.amount = v;
        if (change.drums) |v| self.drums.amount = v;
        if (change.interval_ratio) |ratio| {
            self.interval_ratio = ratio;
            self.harmony = null;
            self.applyTargets();
        }
        if (change.harmony) |harmony| {
            self.harmony = harmony;
            self.applyTargets();
        }
    }

    fn applyPartitionChange(self: *SympatheticBank, target: SympatheticTarget, change: SympatheticChange) void {
        const p = switch (target) {
            .all => return,
            .mic => &self.mic,
            .kanun => &self.kanun,
            .bass => &self.bass,
            .drums => &self.drums,
        };
        if (change.target != null) {
            if (change.enabled) |v| p.enabled = v;
        }
        if (change.decay) |v| p.strings.setDecay(v);
        if (change.gain) |v| p.strings.setInputGain(v);
        if (change.amount) |v| p.amount = v;
    }
};

/// `process_sym_partition` followed by `SympatheticStrings::process`, over a run of samples: the
/// excitation per sample exactly as upstream, the resonator coefficients once per run.
fn partitionRun(p: *SympatheticPartition, master: bool, input: []const f32, out: []f32, s: SymScratch) void {
    const st = &p.strings;
    const n = out.len;
    const live = master and p.enabled;
    var any_drive = false;
    for (0..n) |j| {
        const x: f32 = if (live) input[j] * p.amount else 0.0;
        const driven_input = std.math.tanh(x * st.input_gain);
        const magnitude = @abs(driven_input);
        st.envelope += (magnitude - st.envelope) * 0.0025;
        const onset = @max(st.envelope - st.previous_envelope, 0.0);
        st.previous_envelope = st.envelope;
        if (st.envelope < st.noise_floor * 2.0) {
            st.noise_floor += (st.envelope - st.noise_floor) * 0.0002;
        }
        st.noise_floor = fclamp(st.noise_floor, 0.000_05, 0.05);
        const threshold = @max(st.noise_floor * 3.5, 0.0015);
        const wanted_gate: f32 = if (st.envelope > threshold) 1.0 else 0.0;
        const gate_rate: f32 = if (wanted_gate > st.gate) 0.01 else 0.0008;
        st.gate += (wanted_gate - st.gate) * gate_rate;
        const edge = driven_input - st.previous_input;
        st.previous_input = driven_input;
        const sustained = (driven_input * 0.72 + edge * 3.5) * st.gate;
        const strike = onset * 300.0;
        s.sust[j] = sustained;
        s.strike[j] = strike;
        if (sustained != 0.0 or strike != 0.0) any_drive = true;
    }
    const modes = st.modes.items;
    if (modes.len == 0) return;
    const sum = s.sum[0..n];
    @memset(sum, 0.0);
    var any_sound = false;
    const sr = st.sample_rate;
    for (modes) |*mode| {
        const step = TAU32 * mode.modulation_rate / sr;
        mode.modulation_phase = @rem(mode.modulation_phase + step, TAU32);
        const drift_cents = @sin(mode.modulation_phase) * 1.7;
        if (n > 1) mode.modulation_phase = @rem(mode.modulation_phase + step * @as(f32, @floatFromInt(n - 1)), TAU32);
        const drives = mode.targeted and any_drive;
        if (!drives and mode.y1 == 0.0 and mode.y2 == 0.0) continue;
        any_sound = true;
        const sounding_frequency = mode.frequency * std.math.pow(f32, 2.0, drift_cents / 1200.0);
        const frequency_damping = @sqrt(@max(sounding_frequency / 440.0, 0.5));
        const radius = std.math.pow(f32, st.decay, frequency_damping / (sr * 0.001));
        const coefficient = 2.0 * radius * @cos(TAU32 * sounding_frequency / sr);
        const r2 = radius * radius;
        const coupling = mode.coupling;
        var y1 = mode.y1;
        var y2 = mode.y2;
        if (mode.targeted) {
            const one_minus_r = 1.0 - radius;
            for (0..n) |j| {
                const drive = s.sust[j] * one_minus_r + s.strike[j] * 0.003;
                const y = coefficient * y1 - r2 * y2 + drive * coupling;
                y2 = y1;
                y1 = fclamp(y, -4.0, 4.0);
                sum[j] += y1 * coupling;
            }
        } else {
            for (0..n) |j| {
                const y = coefficient * y1 - r2 * y2 + 0.0 * coupling;
                y2 = y1;
                y1 = fclamp(y, -4.0, 4.0);
                sum[j] += y1 * coupling;
            }
        }
        mode.y1 = y1;
        mode.y2 = y2;
    }
    if (any_sound) {
        for (0..n) |j| {
            // Fixed bank normalization so adding strings never turns down a ringing chord.
            const raw = sum[j] / 8.0 * st.wet;
            out[j] += std.math.tanh(raw + std.math.tanh(raw * 3.0) * 0.22);
        }
    }
    // retain: keep targeted modes and modes still ringing.
    var w: usize = 0;
    for (modes) |mode| {
        if (mode.targeted or @max(@abs(mode.y1), @abs(mode.y2)) > 0.000_01) {
            modes[w] = mode;
            w += 1;
        }
    }
    st.modes.shrinkRetainingCapacity(w);
}

// ── VCF bank ──────────────────────────────────────────────────────────────────

const StereoOut = struct { left: f32, right: f32 };

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
    inline fn process(self: *StereoFilter, l: f32, r: f32) StereoOut {
        return .{ .left = self.left.process(l), .right = self.right.process(r) };
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
            .all = StereoFilter.new(sr),
            .mic = StereoFilter.new(sr),
            .bass = StereoFilter.new(sr),
            .kanun = StereoFilter.new(sr),
            .kick = StereoFilter.new(sr),
            .tanbura = StereoFilter.new(sr),
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
    fn apply(self: *FilterBank, s: VcfSettings) void {
        switch (s.target) {
            .all => self.all.setSettings(s),
            .mic => self.mic.setSettings(s),
            .bass => self.bass.setSettings(s),
            .kanun => self.kanun.setSettings(s),
            .kick => self.kick.setSettings(s),
            .tanbura => self.tanbura.setSettings(s),
        }
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

const all_kinds = [_]VoiceKind{ .floor_tom, .snare, .crash, .phrase_change, .melody_fm, .sub_bass };

const Bus = enum { dry, bass, kanun, kick };
/// How a voice kind renders and where it mixes, fixed while the VCF bank does not change.
const Route = struct { wave: ?VcoWave = null, bus: Bus = .dry };
const PanGain = struct { l: f32, r: f32 };

const Tick = struct {
    event: ?SubdivEvent = null,
    milestone: Milestone = .none,
    control: ?ControlSpec = null,
};

/// Block buffers, `max_frames` each.
const Buffers = struct {
    dry_l: []f32,
    dry_r: []f32,
    bass_l: []f32,
    bass_r: []f32,
    kanun_l: []f32,
    kanun_r: []f32,
    kick_l: []f32,
    kick_r: []f32,
    sym_bass: []f32,
    sym_kanun: []f32,
    sym_drums: []f32,
    live: []f32,
    /// The selected raw input of each sample, before NAM: the dry side of the dry mix.
    raw: []f32,
    nam_buf: []f32,
    sym_out: []f32,
    sust: []f32,
    strike: []f32,
    sum: []f32,
    voices_empty: []bool,
    const f32_names = .{ "dry_l", "dry_r", "bass_l", "bass_r", "kanun_l", "kanun_r", "kick_l", "kick_r", "sym_bass", "sym_kanun", "sym_drums", "live", "raw", "nam_buf", "sym_out", "sust", "strike", "sum" };
    const n_f32 = f32_names.len;
};

// ── Engine ────────────────────────────────────────────────────────────────────

pub const Engine = struct {
    /// App -> audio commands. The App is the only producer (`trySend`/`send`).
    cmds: channel.Ring(AudioCmd, cmd_capacity) = .{},
    /// Audio -> App: what the engine released. The App is the only consumer (`collectGarbage`).
    garbage: channel.Ring(Garbage, garbage_capacity) = .{},
    shared: *Shared,
    /// Playback delay the device reports (startLive points it at device.Output.latency_us).
    device_delay_us: ?*const std.atomic.Value(u64) = null,
    /// T (stop) rows the sequencer has passed (the offline render ends at the first).
    stops_seen: u64 = 0,

    sr: f64,
    sr32: f32,
    rate: u32,
    max_frames: usize,

    phrases: []PlayingPhrase,
    phrase_len: usize = 0,
    voices: synth.VoiceList,
    pans: []PanGain,
    routes: [all_kinds.len]Route = @splat(.{}),
    cur_phrase: usize = 0,
    bpm: f64 = 120.0,
    sustain: f64 = 1.25,
    vol: f32 = 1.0,
    /// Per-bus volume after each bus's VCF, indexed by VcfTarget (all, mic, bass, kanun, kick, tanbura).
    bus_vol: [6]f32 = @splat(1.0),
    /// Fraction 0..1 of the raw input crossfaded into the output last (`dry <percent>` / 100).
    dry_mix: f32 = 0.0,
    /// Whether a live input device feeds `process` (the Rust `has_input_stream`): with one, a
    /// block is never short-cut to silence, since the input may be heard through the dry mix.
    has_input_stream: bool = false,
    vcf: VcfBank = .{},
    vcf_filters: FilterBank,
    fx: FxSettings = .{},
    fx_processor: FxProcessor,
    cabinet: fx_mod.CabinetProcessor,
    paused: bool = false,
    jumps: JumpTable,
    pending_next_id: ?usize = null,
    sympathetics_enabled: bool = false,
    sym: SympatheticBank,
    sympathetic_phrase_id: ?usize = null,
    nam_model: ?*nam.Model = null,
    nam_enabled: bool = true,
    nam_gain: f32 = 1.0,
    nam_input: NamInput = .stereo,
    latency_test: ?*channel.Mailbox(LatencyResult) = null,
    latency_ms_ema: ?f64 = null,
    meter_peaks: [3]f32 = .{ 0, 0, 0 },
    samples_since_publish: u64 = 0,

    pending: []Garbage,
    pending_len: usize = 0,
    slab: SlabAllocator,
    scratch: [scratch_bytes]u8 = undefined,
    seq_version: u64 = 0,
    next_cache: struct { valid: bool = false, version: u64 = 0, cur: usize = 0, value: ?usize = null } = .{},
    floats: []f32,
    buf: Buffers,

    /// Preallocates everything the process path uses. `max_frames` is the largest block rendered
    /// in one piece (longer device blocks are chunked). Free with `destroy`.
    pub fn create(gpa: Allocator, rate: u32, max_frames: u32, shared: *Shared) !*Engine {
        const mf: usize = @max(max_frames, 1);
        const sr: f64 = @floatFromInt(@max(rate, 1));
        const sr32: f32 = @floatCast(sr);
        const self = try gpa.create(Engine);
        errdefer gpa.destroy(self);

        const phrases = try gpa.alloc(PlayingPhrase, max_phrases);
        errdefer gpa.free(phrases);
        var voices = try synth.VoiceList.initCapacity(gpa, max_voices);
        errdefer voices.deinit(gpa);
        const pans = try gpa.alloc(PanGain, max_voices);
        errdefer gpa.free(pans);
        var jumps = try JumpTable.init(gpa);
        errdefer jumps.deinit(gpa);
        var fxp = try FxProcessor.init(gpa, sr32);
        errdefer fxp.deinit(gpa);
        var cab = try fx_mod.CabinetProcessor.init(gpa, sr32);
        errdefer cab.deinit(gpa);
        const pending = try gpa.alloc(Garbage, max_pending_garbage);
        errdefer gpa.free(pending);
        const slab_mem = try gpa.alignedAlloc(u8, .@"16", slab_size * slab_count);
        errdefer gpa.free(slab_mem);
        const floats = try gpa.alloc(f32, mf * Buffers.n_f32);
        errdefer gpa.free(floats);
        @memset(floats, 0.0);
        const empties = try gpa.alloc(bool, mf);
        errdefer gpa.free(empties);
        @memset(empties, true);

        self.* = .{
            .shared = shared,
            .sr = sr,
            .sr32 = sr32,
            .rate = @max(rate, 1),
            .max_frames = mf,
            .phrases = phrases,
            .voices = voices,
            .pans = pans,
            .vcf_filters = FilterBank.new(sr32),
            .fx_processor = fxp,
            .cabinet = cab,
            .jumps = jumps,
            .sym = undefined,
            .pending = pending,
            .slab = .{ .mem = slab_mem },
            .floats = floats,
            .buf = undefined,
        };
        inline for (Buffers.f32_names, 0..) |name, k| {
            @field(self.buf, name) = floats[k * mf .. (k + 1) * mf];
        }
        self.buf.voices_empty = empties;
        try self.sym.init(sr32, &self.slab);
        self.computeRoutes();
        return self;
    }

    /// Frees everything the engine owns: the playing phrases, the NAM model, undelivered commands
    /// and released objects nobody collected. Only after the device stopped calling `process`.
    pub fn destroy(self: *Engine, gpa: Allocator) void {
        while (self.cmds.tryRecv()) |c| c.deinit(gpa);
        self.collectGarbage(gpa);
        for (self.pending[0..self.pending_len]) |g| g.deinit(gpa);
        for (self.phrases[0..self.phrase_len]) |pp| pp.phrase.destroy(gpa);
        if (self.nam_model) |m| m.deinit();
        gpa.free(self.phrases);
        self.voices.deinit(gpa);
        gpa.free(self.pans);
        self.jumps.deinit(gpa);
        self.fx_processor.deinit(gpa);
        self.cabinet.deinit(gpa);
        gpa.free(self.pending);
        gpa.free(self.slab.mem);
        gpa.free(self.floats);
        gpa.free(self.buf.voices_empty);
        gpa.destroy(self);
    }

    /// App side: free everything the engine handed back.
    pub fn collectGarbage(self: *Engine, gpa: Allocator) void {
        while (self.garbage.tryRecv()) |g| g.deinit(gpa);
    }

    /// The output callback (`device.Process`): drain commands, then render `out` (interleaved
    /// stereo) with the live input `input`. Never allocates, frees, locks, logs or does I/O.
    pub fn process(ctx: *anyopaque, out: []f32, input: []const Frame) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.flushPending();
        self.drainCommands();
        const frames = out.len / 2;
        if (out.len % 2 == 1) out[out.len - 1] = 0.0;
        var off: usize = 0;
        while (off < frames) {
            const n = @min(self.max_frames, frames - off);
            const in_lo = @min(off, input.len);
            const in_hi = @min(off + n, input.len);
            self.renderBlock(out[2 * off .. 2 * (off + n)], input[in_lo..in_hi]);
            off += n;
        }
        self.flushPending();
    }

    // ── garbage ──

    fn release(self: *Engine, g: Garbage) void {
        if (self.pending_len == 0 and self.garbage.trySend(g)) return;
        if (self.pending_len < self.pending.len) {
            self.pending[self.pending_len] = g;
            self.pending_len += 1;
        }
        // Unreachable by construction: drainCommands only takes a command while the pending list
        // can absorb everything it may release.
    }

    fn flushPending(self: *Engine) void {
        var i: usize = 0;
        while (i < self.pending_len and self.garbage.trySend(self.pending[i])) i += 1;
        if (i == 0) return;
        std.mem.copyForwards(Garbage, self.pending[0 .. self.pending_len - i], self.pending[i..self.pending_len]);
        self.pending_len -= i;
    }

    // ── commands ──

    fn drainCommands(self: *Engine) void {
        while (self.pending.len - self.pending_len >= self.phrase_len + 1) {
            const cmd = self.cmds.tryRecv() orelse return;
            self.handleCommand(cmd);
        }
    }

    fn positionOf(self: *const Engine, id: usize) ?usize {
        for (self.phrases[0..self.phrase_len], 0..) |pp, i| {
            if (pp.phrase.id == id) return i;
        }
        return null;
    }

    fn curId(self: *const Engine) ?usize {
        return if (self.cur_phrase < self.phrase_len) self.phrases[self.cur_phrase].phrase.id else null;
    }

    fn storeCur(self: *Engine) void {
        self.shared.cur_phrase.store(self.cur_phrase, .monotonic);
    }

    fn changed(self: *Engine) void {
        self.seq_version +%= 1;
    }

    fn rebuildAll(self: *Engine) void {
        for (self.phrases[0..self.phrase_len]) |*pp| pp.rebuild(self.sr, self.bpm);
    }

    fn applyVcfChange(self: *Engine, change: command.VcfChange) void {
        var fba = std.heap.FixedBufferAllocator.init(&self.scratch);
        const r = command.applyVcfChange(fba.allocator(), self.vcf, change) catch return;
        switch (r) {
            .ok => |setting| {
                self.vcf.apply(setting);
                self.vcf_filters.apply(setting);
            },
            .err => {},
        }
    }

    fn applyFxChange(self: *Engine, change: command.FxChange) void {
        var fba = std.heap.FixedBufferAllocator.init(&self.scratch);
        const r = command.applyFxChange(fba.allocator(), self.fx, change) catch return;
        switch (r) {
            .ok => |setting| {
                self.fx = setting;
                self.fx_processor.setSettings(setting);
                self.cabinet.setModel(setting.cabinet_model);
            },
            .err => {},
        }
    }

    fn resetFxProcessor(self: *Engine) void {
        const p = &self.fx_processor;
        inline for (.{ "delay_l", "delay_r", "flanger_l", "flanger_r", "chorus_l", "chorus_r", "rev_l", "rev_r" }) |name| {
            @memset(@field(p, name), 0.0);
        }
        p.delay_pos = 0;
        p.delay_samples = 1;
        p.flanger_pos = 0;
        p.flanger_phase = 0.0;
        p.chorus_pos = 0;
        p.chorus_phase = 0.0;
        p.rev_pos = .{ 0, 0, 0, 0 };
        p.rev_len = .{ 1, 1, 1, 1 };
        p.setSettings(.{});
    }

    fn insertAt(self: *Engine, pos: usize, pp: PlayingPhrase) void {
        var i = self.phrase_len;
        while (i > pos) : (i -= 1) self.phrases[i] = self.phrases[i - 1];
        self.phrases[pos] = pp;
        self.phrase_len += 1;
    }

    fn handleCommand(self: *Engine, cmd: AudioCmd) void {
        switch (cmd) {
            .add_phrase => |p| {
                if (self.phrase_len < self.phrases.len) {
                    self.phrases[self.phrase_len] = PlayingPhrase.init(p, self.sr, self.bpm);
                    self.phrase_len += 1;
                } else self.release(.{ .phrase = p });
                self.changed();
            },
            .remove_phrase => |id| {
                const pid = self.curId();
                var w: usize = 0;
                for (self.phrases[0..self.phrase_len]) |pp| {
                    if (pp.phrase.id == id) {
                        self.release(.{ .phrase = pp.phrase });
                    } else {
                        self.phrases[w] = pp;
                        w += 1;
                    }
                }
                self.phrase_len = w;
                if (w == 0) {
                    self.cur_phrase = 0;
                } else if (pid) |p| {
                    self.cur_phrase = self.positionOf(p) orelse 0;
                }
                self.changed();
            },
            .set_bpm => |b| {
                self.bpm = b;
                self.rebuildAll();
            },
            .set_sustain => |s| self.sustain = s,
            .set_vcf_bank => |v| {
                self.vcf = v;
                self.vcf_filters.setBank(v);
            },
            .set_vcf => |change| self.applyVcfChange(change),
            .set_fx_settings => |v| {
                self.fx = v;
                self.fx_processor.setSettings(v);
                self.cabinet.setModel(v.cabinet_model);
            },
            .set_fx => |change| self.applyFxChange(change),
            .set_nam_model => |model| {
                if (self.nam_model) |old| self.release(.{ .nam_model = old });
                self.nam_model = model;
                self.nam_enabled = model != null;
                self.shared.nam_model_active.store(self.nam_enabled, .monotonic);
                self.shared.nam_status.store(if (self.nam_enabled) 1 else 0, .monotonic);
            },
            .set_nam_enabled => |enabled| {
                self.nam_enabled = enabled;
                self.shared.nam_model_active.store(enabled and self.nam_model != null, .monotonic);
                self.shared.nam_status.store(if (self.nam_model == null) 0 else if (enabled) 1 else 5, .monotonic);
            },
            .set_nam_gain => |gain| self.nam_gain = fclamp(gain, 0.0, command.nam_gain_max),
            .set_nam_input => |route| self.nam_input = route,
            .measure_input_latency => |m| self.latency_test = m.result,
            .set_vol => |v| self.vol = v,
            .set_bus_vol => |v| self.bus_vol[@intFromEnum(v.target)] = v.value,
            .set_dry => |percent| self.dry_mix = fclamp(percent / 100.0, 0.0, 1.0),
            .set_paused => |p| self.paused = p,
            .set_cur_phrase => |pos| {
                if (pos < self.phrase_len) {
                    self.pending_next_id = null;
                    self.cur_phrase = pos;
                    // Reset the target phrase to its very beginning.
                    self.phrases[pos].reset();
                    self.storeCur();
                    self.shared.cur_subdiv.store(0, .monotonic);
                    self.shared.cur_plays.store(0, .monotonic);
                    self.changed();
                }
            },
            .queue_next_phrase => |id| {
                if (self.positionOf(id)) |pos| {
                    self.pending_next_id = id;
                    self.shared.exit_phrase.store(pos, .monotonic);
                    self.changed();
                }
            },
            .set_sympathetics => |enabled| self.sympathetics_enabled = enabled,
            .set_sympathetic_decay => |decay| self.sym.applyChange(.{ .decay = decay }, &self.sympathetics_enabled),
            .set_sympathetic_gain => |gain| self.sym.applyChange(.{ .gain = gain }, &self.sympathetics_enabled),
            .set_sympathetic => |change| self.sym.applyChange(change, &self.sympathetics_enabled),
            .replace_phrase => |p| {
                if (self.positionOf(p.id)) |i| {
                    const old = self.phrases[i].phrase;
                    self.phrases[i].phrase = p;
                    self.phrases[i].rebuild(self.sr, self.bpm);
                    self.release(.{ .phrase = old });
                } else self.release(.{ .phrase = p });
                self.changed();
            },
            .insert_phrase => |v| {
                if (self.phrase_len >= self.phrases.len) {
                    self.release(.{ .phrase = v.phrase });
                    return;
                }
                const insert_pos = @min(v.pos, self.phrase_len);
                self.insertAt(insert_pos, PlayingPhrase.init(v.phrase, self.sr, self.bpm));
                if (insert_pos <= self.cur_phrase and self.cur_phrase + 1 < self.phrase_len) {
                    self.cur_phrase += 1;
                    self.storeCur();
                }
                self.changed();
            },
            .rotate => {
                if (self.phrase_len > 1) {
                    const playing_id = self.curId();
                    std.mem.rotate(PlayingPhrase, self.phrases[0..self.phrase_len], 1);
                    if (playing_id) |pid| {
                        self.cur_phrase = self.positionOf(pid) orelse 0;
                        self.storeCur();
                    }
                    self.changed();
                }
            },
            .move_phrase => |v| {
                const playing_id = self.curId();
                if (self.positionOf(v.id)) |pos| {
                    const other: ?usize = if (v.down)
                        (if (pos + 1 < self.phrase_len) pos + 1 else null)
                    else if (pos > 0) pos - 1 else null;
                    if (other) |o| {
                        std.mem.swap(PlayingPhrase, &self.phrases[pos], &self.phrases[o]);
                        if (playing_id) |pid| {
                            self.cur_phrase = self.positionOf(pid) orelse self.cur_phrase;
                            self.storeCur();
                        }
                        self.changed();
                    }
                }
            },
            .clear => {
                for (self.phrases[0..self.phrase_len]) |pp| self.release(.{ .phrase = pp.phrase });
                self.phrase_len = 0;
                self.voices.clearRetainingCapacity();
                self.cur_phrase = 0;
                self.pending_next_id = null;
                self.jumps.clear();
                self.shared.clearJumpCounters();
                self.changed();
            },
            .reset_session_state => {
                if (self.nam_model) |old| self.release(.{ .nam_model = old });
                self.nam_model = null;
                self.nam_enabled = false;
                self.nam_gain = 1.0;
                self.nam_input = .stereo;
                self.shared.nam_model_active.store(false, .monotonic);
                self.shared.nam_status.store(0, .monotonic);
                self.sympathetics_enabled = false;
                self.sym.reset();
                self.sympathetic_phrase_id = null;
                self.vcf = .{};
                self.vcf_filters = FilterBank.new(self.sr32);
                self.fx = .{};
                self.resetFxProcessor();
                self.dry_mix = 0.0;
            },
        }
    }

    fn applyControl(self: *Engine, ctrl: ControlSpec) void {
        switch (ctrl) {
            .stop => {},
            .set_bpm => |v| {
                self.bpm = v;
                self.rebuildAll();
            },
            .set_sustain => |v| self.sustain = v,
            .set_vcf => |change| self.applyVcfChange(change),
            .set_fx => |change| self.applyFxChange(change),
            .set_vol => |v| self.vol = v,
            .set_bus_vol => |v| self.bus_vol[@intFromEnum(v.target)] = v.value,
            .set_dry => |percent| self.dry_mix = fclamp(percent / 100.0, 0.0, 1.0),
            .set_nam_enabled => |v| self.nam_enabled = v,
            .set_nam_gain => |v| self.nam_gain = fclamp(v, 0.0, command.nam_gain_max),
            .set_nam_input => |v| self.nam_input = v,
            .set_sympathetics => |v| self.sympathetics_enabled = v,
            .set_sympathetic_decay => |v| self.sym.applyChange(.{ .decay = v }, &self.sympathetics_enabled),
            .set_sympathetic_gain => |v| self.sym.applyChange(.{ .gain = v }, &self.sympathetics_enabled),
            .set_sympathetic => |v| self.sym.applyChange(v, &self.sympathetics_enabled),
        }
    }

    // ── sequencer ──

    /// `(cur + 1) % len`, counting a wrap from the last row to the first as a cycle.
    fn advance(self: *Engine, cur: usize) usize {
        const next = cur + 1;
        if (next >= self.phrase_len) {
            _ = self.shared.cycles.fetchAdd(1, .monotonic);
            return 0;
        }
        return next;
    }

    /// Look ahead: simulate what the sequencer will actually do next (a live jump loops back, an
    /// exhausted jump falls through to the next musical phrase). Cached; see the header.
    fn computedNext(self: *Engine) ?usize {
        const c = &self.next_cache;
        if (c.valid and c.version == self.seq_version and c.cur == self.cur_phrase) return c.value;
        const value = self.computeNext();
        c.* = .{ .valid = true, .version = self.seq_version, .cur = self.cur_phrase, .value = value };
        return value;
    }

    fn computeNext(self: *Engine) ?usize {
        if (self.pending_next_id) |id| return self.positionOf(id);
        const n = self.phrase_len;
        const phrases = self.phrases[0..n];
        const curr_id = phrases[self.cur_phrase].phrase.id;
        var pos = (self.cur_phrase + 1) % n;
        var result: ?usize = null;
        for (0..n) |_| {
            const p = phrases[pos].phrase;
            if (p.jump) |js| {
                const value = self.jumps.get(p.id) orelse 0;
                if (js.times == 0 or value +| 1 < @max(js.times, 1)) {
                    // A jump may target a control or another jump. Continue simulating until
                    // prediction reaches a musical phrase.
                    pos = self.positionOf(js.target_id) orelse 0;
                    continue;
                } else if (js.fail_target_id) |fail_id| {
                    pos = self.positionOf(fail_id) orelse (pos + 1) % n;
                    continue;
                }
                pos = (pos + 1) % n;
            } else if (p.control != null) {
                pos = (pos + 1) % n;
            } else {
                result = pos;
                break;
            }
        }
        if (result) |r| if (phrases[r].phrase.id != curr_id) return r;
        return null;
    }

    fn tickSequencer(self: *Engine) Tick {
        const n = self.phrase_len;
        if (n == 0) return .{};
        const sh = self.shared;

        var iter: usize = 0;
        while (iter < n + 1) : (iter += 1) {
            if (self.cur_phrase >= n) self.cur_phrase = 0;
            const p = self.phrases[self.cur_phrase].phrase;
            const pid = p.id;
            if (p.jump) |js| {
                if (js.times == 0) {
                    self.cur_phrase = @min(self.positionOf(js.target_id) orelse 0, n - 1);
                    self.storeCur();
                    continue;
                }
                const limit = @max(js.times, 1);
                // A full table (more distinct jump ids than it holds since the last Clear) counts
                // in a temporary that reads as exhausted, so the jump falls through.
                var overflow: usize = std.math.maxInt(usize);
                const value = self.jumps.getOrPut(pid) orelse &overflow;
                const incremented = value.* +| 1;
                if (incremented < limit) {
                    value.* = incremented;
                    sh.cur_jump_value.store(value.*, .monotonic);
                    self.cur_phrase = @min(self.positionOf(js.target_id) orelse 0, n - 1);
                } else {
                    value.* = 0;
                    sh.cur_jump_value.store(0, .monotonic);
                    const fail_pos = if (js.fail_target_id) |id| self.positionOf(id) else null;
                    self.cur_phrase = fail_pos orelse self.advance(self.cur_phrase);
                }
                self.storeCur();
                sh.setJumpCounter(pid, value.*);
                self.changed();
                continue;
            }
            if (p.control) |ctrl| {
                if (ctrl == .stop) {
                    self.stops_seen += 1;
                    self.cur_phrase = self.advance(self.cur_phrase);
                    self.storeCur();
                    continue;
                }
                self.cur_phrase = self.advance(self.cur_phrase);
                self.storeCur();
                return .{ .control = ctrl };
            }
            break;
        }

        if (self.cur_phrase >= n) self.cur_phrase = 0;
        const computed_next = self.computedNext();

        const cur = self.cur_phrase;
        const pp = &self.phrases[cur];
        const bar = &pp.phrase.bar;
        const curr: usize = if (bar.total_subdivs > 0)
            @min(f64ToUsize(@as(f64, @floatFromInt(pp.bar_pos)) / pp.subdiv_samples), bar.total_subdivs - 1)
        else
            0;

        const is_last_play = pp.plays_done + 1 >= pp.phrase.repeat;
        const is_last_subdiv = curr + 1 >= bar.total_subdivs;
        // A phrase repeat is an actual self-loop. Until its final play, the next phrase is the
        // current phrase; only [n/n] exposes the following score entry.
        const next_phrase = if (is_last_play) computed_next orelse cur else cur;
        sh.next_phrase.store(next_phrase, .monotonic);
        sh.exit_phrase.store(computed_next orelse cur, .monotonic);
        const next_is_different = next_phrase != cur;

        var milestone: Milestone = .none;
        var ev: ?SubdivEvent = null;
        if (pp.last_subdiv == null or pp.last_subdiv.? != curr) {
            pp.last_subdiv = curr;
            if (pp.plays_done == 0 and curr == 0) {
                milestone = .phrase_start;
            } else if (is_last_play and is_last_subdiv) {
                milestone = if (next_is_different) .turnaround else .cross_phrase_warning;
            }
            sh.cur_subdiv.store(curr, .monotonic);
            sh.cur_plays.store(pp.plays_done, .monotonic);
            ev = if (curr < bar.events.len) bar.events[curr] else null;
        }

        pp.bar_pos += 1;
        const bar_samples = f64ToUsize(@round(pp.subdiv_samples * @as(f64, @floatFromInt(bar.total_subdivs))));
        if (pp.bar_pos >= @max(bar_samples, 1)) {
            pp.bar_pos = 0;
            pp.last_subdiv = null;
            pp.plays_done += 1;
            synth.evolveBar(bar, true);
            if (pp.plays_done >= pp.phrase.repeat) {
                pp.plays_done = 0;
                // Publish the completed-count reset before following control or jump entries are
                // evaluated. Every phrase is entered at [0/n].
                sh.cur_plays.store(0, .monotonic);
                const prev = cur;
                var queued: ?usize = null;
                if (self.pending_next_id) |id| {
                    self.pending_next_id = null;
                    self.changed();
                    queued = self.positionOf(id);
                }
                self.cur_phrase = queued orelse self.advance(cur);
                self.storeCur();
                if (self.cur_phrase != prev and milestone == .none) milestone = .phrase_change;
            }
        }
        if (milestone == .phrase_start) _ = sh.phrase_starts.fetchAdd(1, .monotonic);
        return .{ .event = ev, .milestone = milestone };
    }

    // ── rendering ──

    fn computeRoutes(self: *Engine) void {
        for (all_kinds) |kind| {
            var route: Route = .{};
            if (!self.vcf.all.enabled) {
                if (vcfTargetForKind(kind)) |t| {
                    const setting = self.vcf.get(t);
                    if (setting.enabled) {
                        if (setting.target != .all) route.wave = setting.wave.oscillator();
                        route.bus = switch (setting.target) {
                            .bass => .bass,
                            .kanun => .kanun,
                            .kick => .kick,
                            else => .dry, // mic and tanbura voices mix dry; `all` cannot occur here
                        };
                    }
                }
            }
            self.routes[@backingInt(kind)] = route;
        }
    }

    fn panNew(self: *Engine, from: usize) void {
        for (self.voices.items[from..], from..) |v, i| {
            const angle = (v.pan + 1.0) * FRAC_PI_4;
            self.pans[i] = .{ .l = @cos(angle), .r = @sin(angle) };
        }
    }

    fn retainVoices(self: *Engine) void {
        const items = self.voices.items;
        var w: usize = 0;
        for (items, 0..) |v, i| {
            if (!v.done) {
                items[w] = v;
                self.pans[w] = self.pans[i];
                w += 1;
            }
        }
        self.voices.shrinkRetainingCapacity(w);
    }

    fn renderBlock(self: *Engine, out: []f32, input: []const Frame) void {
        const n = out.len / 2;
        const b = &self.buf;
        var seg: usize = 0;
        self.computeRoutes();
        for (0..n) |j| {
            const t = self.tickSequencer();
            if (t.control) |ctrl| {
                self.flush(seg, j, out, input, n);
                seg = j;
                self.applyControl(ctrl);
                self.computeRoutes();
            }

            const cur_id = self.curId();
            if (!std.meta.eql(cur_id, self.sympathetic_phrase_id)) {
                self.flush(seg, j, out, input, n);
                seg = j;
                if (cur_id != null) self.sym.setTargets(self.phrases[self.cur_phrase].phrase.bar.frequencies);
                self.sympathetic_phrase_id = cur_id;
            }

            if (t.milestone == .phrase_start and !self.paused) {
                if (self.cur_phrase < self.phrase_len) {
                    const pp = &self.phrases[self.cur_phrase];
                    const root_hz = pp.phrase.bar.root_hz;
                    const from = self.voices.items.len;
                    synth.spawnPhraseStart(root_hz, self.sustain, &self.voices);
                    const subdiv_secs = 60.0 / (self.bpm * 2.0);
                    const phrase_secs = @min(@as(f64, @floatFromInt(pp.phrase.bar.total_subdivs)) * subdiv_secs * @as(f64, @floatFromInt(pp.phrase.repeat)), 3.0);
                    synth.spawnSubBass(root_hz, phrase_secs, &self.voices);
                    self.panNew(from);
                }
            }

            if (t.event) |ev| {
                if (!self.paused) {
                    self.flush(seg, j, out, input, n);
                    seg = j;
                    var scale: []const f64 = &.{};
                    var root_hz: f64 = 0.0;
                    if (self.cur_phrase < self.phrase_len) {
                        scale = self.phrases[self.cur_phrase].phrase.bar.frequencies;
                        root_hz = self.phrases[self.cur_phrase].phrase.bar.root_hz;
                    }
                    const subdiv_secs = 60.0 / (self.bpm * 2.0);
                    const from = self.voices.items.len;
                    synth.spawnVoices(ev, self.sustain, &self.voices, t.milestone, scale, root_hz, subdiv_secs);
                    self.panNew(from);
                    self.vcf.advanceTick();
                    self.vcf_filters.updateBank(self.vcf);
                    self.fx.advanceTick();
                    self.fx_processor.setSettings(self.fx);
                    self.computeRoutes();
                }
            }

            self.retainVoices();

            // The voice mix of this sample (pass 1).
            var dl: f32 = 0;
            var dr: f32 = 0;
            var bl: f32 = 0;
            var br: f32 = 0;
            var kl: f32 = 0;
            var kr: f32 = 0;
            var il: f32 = 0;
            var ir: f32 = 0;
            var sym_bass: f32 = 0;
            var sym_kanun: f32 = 0;
            var sym_drums: f32 = 0;
            for (self.voices.items, self.pans[0..self.voices.items.len]) |*v, pan| {
                const route = self.routes[@backingInt(v.kind)];
                const s = v.sampleWithWave(self.sr, route.wave);
                const left = s * pan.l;
                const right = s * pan.r;
                const mono = (left + right) * 0.5;
                switch (v.kind) {
                    .sub_bass => sym_bass += mono,
                    .melody_fm => sym_kanun += mono,
                    .floor_tom, .snare, .crash => sym_drums += mono,
                    .phrase_change => {},
                }
                switch (route.bus) {
                    .dry => {
                        dl += left;
                        dr += right;
                    },
                    .bass => {
                        bl += left;
                        br += right;
                    },
                    .kanun => {
                        kl += left;
                        kr += right;
                    },
                    .kick => {
                        il += left;
                        ir += right;
                    },
                }
            }
            b.dry_l[j] = dl;
            b.dry_r[j] = dr;
            b.bass_l[j] = bl;
            b.bass_r[j] = br;
            b.kanun_l[j] = kl;
            b.kanun_r[j] = kr;
            b.kick_l[j] = il;
            b.kick_r[j] = ir;
            b.sym_bass[j] = sym_bass;
            b.sym_kanun[j] = sym_kanun;
            b.sym_drums[j] = sym_drums;
            b.voices_empty[j] = self.voices.items.len == 0;
        }
        self.flush(seg, n, out, input, n);
    }

    /// Pass 2 over samples [a, b) of the block: live input, NAM, meters, then the mix of each run
    /// of audible samples (sympathetic strings, VCF buses, FX, clip) or silence.
    fn flush(self: *Engine, a: usize, b_end: usize, out: []f32, input: []const Frame, block_frames: usize) void {
        if (a >= b_end) return;
        const b = &self.buf;
        const len = b_end - a;
        var have_input = false;
        for (a..b_end) |j| {
            const in: Frame = if (j < input.len) input[j] else .{ 0.0, 0.0 };
            if (j < input.len) have_input = true;
            self.meter_peaks[0] = @max(self.meter_peaks[0], @abs(in[0]));
            self.meter_peaks[1] = @max(self.meter_peaks[1], @abs(in[1]));
            b.live[j] = switch (self.nam_input) {
                .left => in[0],
                .right => in[1],
                .stereo => (in[0] + in[1]) * 0.5,
            };
            b.raw[j] = b.live[j];
        }
        if (have_input) self.onInput(block_frames);
        const model = self.nam_model;
        if (model) |m| {
            for (a..b_end) |j| b.nam_buf[j] = b.live[j] * self.nam_gain;
            m.processBuffer(b.nam_buf[a..b_end]);
        }
        // NAM on selects only the modeled input, NAM off only the clean input: never both. Then
        // the cabinet stage, which runs every sample (bypassed while off).
        const nam_selected = self.nam_enabled and model != null;
        for (a..b_end) |j| {
            const dry = b.raw[j];
            const modeled = fclamp(if (model != null) b.nam_buf[j] else dry, -1.0, 1.0);
            const selected = selectNamOutput(dry, modeled, nam_selected);
            const live = fclamp(self.cabinet.process(selected, self.fx), -1.0, 1.0);
            b.live[j] = live;
            self.meter_peaks[2] = @max(self.meter_peaks[2], @abs(live));
        }
        self.samples_since_publish += len;
        if (self.samples_since_publish >= @as(u64, self.rate) * 10) self.publishMetrics();

        const nam_active = self.nam_enabled and model != null;
        const quiet = !self.has_input_stream and !self.fx.active() and !self.sympathetics_enabled and
            !self.vcf.all.enabled and !self.vcf.mic.enabled and !nam_active;
        const sym_energy = quiet and self.sym.hasEnergy();
        var j = a;
        while (j < b_end) {
            const silent = quiet and b.voices_empty[j] and !sym_energy;
            var k = j + 1;
            while (k < b_end and (quiet and b.voices_empty[k] and !sym_energy) == silent) k += 1;
            if (silent) {
                self.vcf_filters.reset();
                @memset(out[2 * j .. 2 * k], 0.0);
            } else {
                self.mixRun(j, k, out);
            }
            j = k;
        }
    }

    fn mixRun(self: *Engine, a: usize, b_end: usize, out: []f32) void {
        const b = &self.buf;
        const sym_out = b.sym_out[a..b_end];
        @memset(sym_out, 0.0);
        const scratch: SymScratch = .{ .sust = b.sust, .strike = b.strike, .sum = b.sum };
        // Disabling sym closes the bridge to new energy; already ringing strings still decay into
        // the output.
        self.sym.processRun(self.sympathetics_enabled, b.live[a..b_end], b.sym_kanun[a..b_end], b.sym_bass[a..b_end], b.sym_drums[a..b_end], sym_out, scratch);
        const v = self.vcf;
        const f = &self.vcf_filters;
        const fx_active = self.fx.active();
        for (a..b_end) |j| {
            var dry_l = b.dry_l[j];
            var dry_r = b.dry_r[j];
            var mic_l: f32 = 0;
            var mic_r: f32 = 0;
            var tan_l: f32 = 0;
            var tan_r: f32 = 0;
            const live = b.live[j];
            if (!v.all.enabled) {
                // NAM on selects only modeled input; NAM off selects only clean input. Both use
                // the same mic output bus and trim.
                mic_l += live;
                mic_r += live;
            } else {
                dry_l += live;
                dry_r += live;
            }
            const sympathetic = sym_out[j - a];
            if (v.all.enabled) {
                dry_l += sympathetic;
                dry_r += sympathetic;
            } else if (v.tanbura.enabled) {
                tan_l += sympathetic;
                tan_r += sympathetic;
            } else {
                dry_l += sympathetic;
                dry_r += sympathetic;
            }
            var left = dry_l;
            var right = dry_r;
            const bv = self.bus_vol;
            var post_vcf_mic: [2]f32 = .{ 0, 0 };
            if (!v.all.enabled) {
                if (v.mic.enabled) {
                    const o = f.mic.process(mic_l, mic_r);
                    post_vcf_mic = .{ o.left, o.right };
                } else {
                    post_vcf_mic = .{ mic_l, mic_r };
                }
                if (v.bass.enabled) {
                    const o = f.bass.process(b.bass_l[j], b.bass_r[j]);
                    left += o.left * bv[@intFromEnum(VcfTarget.bass)];
                    right += o.right * bv[@intFromEnum(VcfTarget.bass)];
                }
                if (v.kanun.enabled) {
                    const o = f.kanun.process(b.kanun_l[j], b.kanun_r[j]);
                    left += o.left * bv[@intFromEnum(VcfTarget.kanun)];
                    right += o.right * bv[@intFromEnum(VcfTarget.kanun)];
                }
                if (v.kick.enabled) {
                    const o = f.kick.process(b.kick_l[j], b.kick_r[j]);
                    left += o.left * bv[@intFromEnum(VcfTarget.kick)];
                    right += o.right * bv[@intFromEnum(VcfTarget.kick)];
                }
                if (v.tanbura.enabled) {
                    const o = f.tanbura.process(tan_l, tan_r);
                    left += o.left * bv[@intFromEnum(VcfTarget.tanbura)];
                    right += o.right * bv[@intFromEnum(VcfTarget.tanbura)];
                }
            }
            if (fx_active) {
                const o = self.fx_processor.process(left, right);
                left = o.left;
                right = o.right;
            }
            const sat = analog.softClipStereo(left * self.vol, right * self.vol);
            if (v.all.enabled) {
                const o = f.all.process(sat.left, sat.right);
                left = fclamp(o.left * bv[@intFromEnum(VcfTarget.all)], -1.0, 1.0);
                right = fclamp(o.right * bv[@intFromEnum(VcfTarget.all)], -1.0, 1.0);
            } else {
                left = fclamp(sat.left, -1.0, 1.0);
                right = fclamp(sat.right, -1.0, 1.0);
                // The mic bus joins after the clip, so its trim is linear.
                const mic_out = postVcfOutputStem(post_vcf_mic, self.vol, bv[@intFromEnum(VcfTarget.mic)]);
                left = fclamp(left + mic_out[0], -1.0, 1.0);
                right = fclamp(right + mic_out[1], -1.0, 1.0);
            }
            // The dry mix is applied last: its dry side is the selected raw input, untouched by
            // NAM, VCF, FX or gain.
            const mixed = applyDryMix(.{ left, right }, b.raw[j], self.dry_mix);
            out[2 * j] = mixed[0];
            out[2 * j + 1] = mixed[1];
        }
    }

    /// An input block arrived: update the latency estimate and answer a pending measurement.
    fn onInput(self: *Engine, block_frames: usize) void {
        var measured_ms = @as(f64, @floatFromInt(block_frames)) * 1000.0 / self.sr;
        if (self.device_delay_us) |d| measured_ms += @as(f64, @floatFromInt(d.load(.monotonic))) / 1000.0;
        self.latency_ms_ema = if (self.latency_ms_ema) |prev| prev * 0.9 + measured_ms * 0.1 else measured_ms;
        if (self.latency_test) |mb| {
            _ = mb.put(.{ .ok = measured_ms });
            self.latency_test = null;
        }
    }

    fn publishMetrics(self: *Engine) void {
        const sh = self.shared;
        if (self.latency_ms_ema) |ms| {
            const us: u64 = @intFromFloat(@max(@round(ms * 1000.0), 1.0));
            sh.latency_left_us.store(us, .monotonic);
            sh.latency_right_us.store(us, .monotonic);
        }
        Shared.storeLevel(&sh.input_left_level, @min(self.meter_peaks[0], 4.0));
        Shared.storeLevel(&sh.input_right_level, @min(self.meter_peaks[1], 4.0));
        Shared.storeLevel(&sh.nam_output_level, @min(self.meter_peaks[2], 4.0));
        self.meter_peaks = .{ 0, 0, 0 };
        self.samples_since_publish = 0;
    }
};

/// The Rust `post_vcf_output_stem`: a bus clamped to [-1, 1], then scaled linearly.
fn postVcfOutputStem(stem: [2]f32, master_gain: f32, output_gain: f32) [2]f32 {
    const gain = master_gain * output_gain;
    return .{ fclamp(stem[0], -1.0, 1.0) * gain, fclamp(stem[1], -1.0, 1.0) * gain };
}

/// The Rust `apply_dry_mix`: crossfade the processed output with the raw input.
fn applyDryMix(processed: [2]f32, dry: f32, amount: f32) [2]f32 {
    const a = fclamp(amount, 0.0, 1.0);
    return .{
        fclamp(processed[0] * (1.0 - a) + dry * a, -1.0, 1.0),
        fclamp(processed[1] * (1.0 - a) + dry * a, -1.0, 1.0),
    };
}

/// The Rust `select_nam_output`: an active NAM replaces the clean input; no parallel dry signal.
fn selectNamOutput(dry: f32, modeled: f32, active: bool) f32 {
    return if (active) modeled else dry;
}

// ── Live device ───────────────────────────────────────────────────────────────

pub const Live = struct {
    gpa: Allocator,
    engine: *Engine,
    output: *device.Output,

    /// Stops the device, then frees the engine (and everything it still holds).
    pub fn stop(self: *Live) void {
        self.output.close(self.gpa);
        self.engine.destroy(self.gpa);
    }
};

/// Opens the output device (device.Output: ALSA on Linux, CoreAudio on macOS) at 48000 Hz with a
/// period of `bufsize` frames (`--bufsize=`, default 64; the device may choose the nearest size it
/// supports) and capture, and runs `Engine.process` once per block. A device failure is returned
/// (the caller falls back to command mode without playback, like run_cli).
pub fn startLive(gpa: Allocator, io: std.Io, shared: *Shared, bufsize: u32) !Live {
    const output = try device.Output.open(gpa, .{ .rate = 48000, .period_frames = @max(bufsize, 1), .capture = true, .underruns = &shared.underruns });
    errdefer output.close(gpa);
    const engine = try Engine.create(gpa, output.rate, output.period, shared);
    errdefer engine.destroy(gpa);
    engine.device_delay_us = &output.latency_us;
    engine.has_input_stream = output.hasInput();
    try output.start(io, Engine.process, engine);
    return .{ .gpa = gpa, .engine = engine, .output = output };
}

// ── Offline hooks ─────────────────────────────────────────────────────────────

/// Mono samples (owned by the caller), or the session's load error (owned by the caller).
pub const RenderResult = union(enum) {
    ok: []f32,
    err: []const u8,

    pub fn deinit(self: RenderResult, gpa: Allocator) void {
        switch (self) {
            .ok => |s| gpa.free(s),
            .err => |m| gpa.free(m),
        }
    }
};

const LoadPurpose = enum { render, bench };

/// Send a command the way the App does, draining the ring (one empty process call) when full.
fn sendCmd(engine: *Engine, gpa: Allocator, cmd: AudioCmd) void {
    while (!engine.cmds.trySend(cmd)) {
        Engine.process(engine, &.{}, &.{});
        engine.collectGarbage(gpa);
    }
}

/// The AudioCmds the App sends after loading a session (app.rs load_session_v3), with the NAM
/// rows that need no model file (off, gain, input).
fn sendLoad(engine: *Engine, gpa: Allocator, loaded: *const session.Loaded) !void {
    sendCmd(engine, gpa, .clear);
    sendCmd(engine, gpa, .reset_session_state);
    sendCmd(engine, gpa, .{ .set_bpm = loaded.start.bpm });
    sendCmd(engine, gpa, .{ .set_sustain = loaded.start.sustain });
    sendCmd(engine, gpa, .{ .set_vcf_bank = loaded.start.vcf });
    sendCmd(engine, gpa, .{ .set_fx_settings = loaded.start.fx });
    sendCmd(engine, gpa, .{ .set_vol = 1.0 });
    sendCmd(engine, gpa, .{ .set_paused = false });
    for (loaded.nam_rows) |row| switch (row.command) {
        .off => sendCmd(engine, gpa, .{ .set_nam_enabled = false }),
        .gain => |g| sendCmd(engine, gpa, .{ .set_nam_gain = g }),
        .input => |r| sendCmd(engine, gpa, .{ .set_nam_input = r }),
        else => {},
    };
    for (loaded.phrases) |*p| {
        var copy = try p.clone(gpa);
        const heap = Phrase.create(gpa, copy) catch |e| {
            copy.deinit(gpa);
            return e;
        };
        sendCmd(engine, gpa, .{ .add_phrase = heap });
    }
    sendCmd(engine, gpa, .{ .set_cur_phrase = 0 });
}

/// The offline render hook: `session_text` loaded as the App would, the PRNG seeded with
/// synth.default_seed, no device and no live input, rendered in 256-frame blocks until
/// `Shared.cycles` reaches `cycles`, the sequencer passes a T (stop) row, or 600 s of audio.
/// Mono = (L+R)/2. The same samples on every run.
pub fn render(gpa: Allocator, io: std.Io, session_text: []const u8, cycles: u32, rate: u32) !RenderResult {
    _ = io;
    var loaded_r = try session.load(gpa, session_text, .{});
    switch (loaded_r) {
        .err => |m| return .{ .err = m },
        .ok => {},
    }
    defer loaded_r.deinit(gpa);
    synth.seedRng(synth.default_seed);

    const shared = try gpa.create(Shared);
    defer gpa.destroy(shared);
    shared.* = .{};
    const engine = try Engine.create(gpa, rate, render_block_frames, shared);
    defer engine.destroy(gpa);
    try sendLoad(engine, gpa, &loaded_r.ok);

    var samples: std.ArrayList(f32) = .empty;
    errdefer samples.deinit(gpa);
    const cap: usize = @as(usize, render_cap_seconds) * @max(rate, 1);
    var block: [2 * render_block_frames]f32 = undefined;
    while (shared.cycles.load(.monotonic) < cycles and engine.stops_seen == 0 and samples.items.len < cap) {
        Engine.process(engine, &block, &.{});
        engine.collectGarbage(gpa);
        try samples.ensureUnusedCapacity(gpa, render_block_frames);
        var i: usize = 0;
        while (i < block.len) : (i += 2) samples.appendAssumeCapacity((block[i] + block[i + 1]) * 0.5);
    }
    return .{ .ok = try samples.toOwnedSlice(gpa) };
}

/// A deterministic guitar-like live input: plucked strings (Karplus-Strong) over a D-based phrase,
/// one pluck every 0.4 s, with some string noise. Owned by the caller.
pub fn syntheticGuitar(gpa: Allocator, rate: u32, seconds: f64) ![]Frame {
    const sr: f64 = @floatFromInt(@max(rate, 1));
    const n: usize = @max(@as(usize, @intFromFloat(seconds * sr)), 1);
    const out = try gpa.alloc(Frame, n);
    errdefer gpa.free(out);
    const notes = [_]f64{ 146.83, 164.81, 174.61, 196.0, 220.0, 233.08, 261.63, 293.66 };
    const max_period: usize = @as(usize, @intFromFloat(sr / 60.0)) + 2;
    const line = try gpa.alloc(f32, max_period);
    defer gpa.free(line);
    @memset(line, 0.0);
    var state: u64 = 0x9e3779b97f4a7c15;
    const noise = struct {
        fn next(s: *u64) f32 {
            s.* = s.* *% 6364136223846793005 +% 1442695040888963407;
            return @as(f32, @floatFromInt(s.* >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24)) * 2.0 - 1.0;
        }
    }.next;
    const pluck_every: usize = @intFromFloat(sr * 0.4);
    var period: usize = 2;
    var pos: usize = 0;
    var note_index: usize = 0;
    for (0..n) |i| {
        if (i % pluck_every == 0) {
            const f = notes[note_index % notes.len] * (if (note_index % 16 >= 8) @as(f64, 2.0) else 1.0);
            note_index += 1;
            period = @min(@max(@as(usize, @intFromFloat(sr / f)), 2), max_period);
            for (line[0..period]) |*x| x.* = noise(&state) * 0.5;
            pos = 0;
        }
        const nxt = (pos + 1) % period;
        const y = line[pos];
        line[pos] = 0.996 * 0.5 * (line[pos] + line[nxt]);
        pos = nxt;
        const hiss = noise(&state) * 0.0005;
        out[i] = .{ y + hiss, y * 0.97 + hiss };
    }
    return out;
}

/// The bench hook: `session_text` loaded as for `render`, the sympathetic strings and the reverb on,
/// the NAM capture at `nam_path` loaded and enabled when given, a synthetic guitar on the live
/// input, timed by device.bench against a null device.
pub fn bench(gpa: Allocator, io: std.Io, session_text: []const u8, seconds: f64, frames: u32, rate: u32, nam_path: ?[]const u8, trace: ?[]device.BlockTime, want_realtime: bool) !device.BenchResult {
    var loaded_r = try session.load(gpa, session_text, .{});
    defer loaded_r.deinit(gpa);
    const loaded = switch (loaded_r) {
        .err => return error.InvalidSession,
        .ok => |*l| l,
    };
    synth.seedRng(synth.default_seed);
    const model: ?*nam.Model = if (nam_path) |path| try nam.Model.loadFile(gpa, io, path, null) else null;
    var model_owned = model != null;
    errdefer if (model_owned) model.?.deinit();

    const shared = try gpa.create(Shared);
    defer gpa.destroy(shared);
    shared.* = .{};
    const engine = try Engine.create(gpa, rate, frames, shared);
    defer {
        engine.collectGarbage(gpa);
        engine.destroy(gpa);
    }
    try sendLoad(engine, gpa, loaded);
    var fx = loaded.start.fx;
    fx.reverb_enabled = true;
    sendCmd(engine, gpa, .{ .set_fx_settings = fx });
    sendCmd(engine, gpa, .{ .set_sympathetics = true });
    if (model) |m| {
        sendCmd(engine, gpa, .{ .set_nam_model = m });
        model_owned = false;
    }
    const input = try syntheticGuitar(gpa, rate, 4.0);
    defer gpa.free(input);
    engine.has_input_stream = true; // the bench feeds a live input, as the device would
    return device.bench(gpa, io, Engine.process, engine, frames, rate, seconds, input, trace, want_realtime);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const tuning = @import("tuning.zig");

test "sympathetic_harmony_weights_are_normalized" {
    var slab_mem: [slab_size * slab_count]u8 align(16) = undefined;
    var slab: SlabAllocator = .{ .mem = &slab_mem };
    const bank = try testing.allocator.create(SympatheticBank);
    defer testing.allocator.destroy(bank);
    try bank.init(48_000.0, &slab);
    bank.setTargets(&.{220.0});
    var harmony: SympatheticHarmony = .{};
    try testing.expectEqual(@as(?[]const u8, null), harmony.push(.{ .ratio = 1.0, .weight = 0.50 }));
    try testing.expectEqual(@as(?[]const u8, null), harmony.push(.{ .ratio = 6.0 / 5.0, .weight = 0.25 }));
    try testing.expectEqual(@as(?[]const u8, null), harmony.push(.{ .ratio = 3.0 / 2.0, .weight = 0.25 }));

    const weighted = bank.weightedTargets(harmony);

    try testing.expectEqual(@as(usize, 3), weighted.len);
    try testing.expect(@abs(weighted[0].frequency - 220.0) < std.math.floatEps(f64));
    try testing.expect(@abs(weighted[0].weight - 0.50) < std.math.floatEps(f32));
    try testing.expect(@abs(weighted[1].frequency - 264.0) < std.math.floatEps(f64));
    try testing.expect(@abs(weighted[1].weight - 0.25) < std.math.floatEps(f32));
    try testing.expect(@abs(weighted[2].frequency - 330.0) < std.math.floatEps(f64));
    try testing.expect(@abs(weighted[2].weight - 0.25) < std.math.floatEps(f32));
    var total: f32 = 0;
    for (weighted) |w| total += w.weight;
    try testing.expect(@abs(total - 1.0) < std.math.floatEps(f32));
}

const T = struct {
    shared: *Shared,
    engine: *Engine,
    block: [512]f32 = undefined,

    fn init(gpa: Allocator) !T {
        const shared = try testing.allocator.create(Shared);
        errdefer testing.allocator.destroy(shared);
        shared.* = .{};
        return .{ .shared = shared, .engine = try Engine.create(gpa, 48_000, 256, shared) };
    }

    fn deinit(self: *T, gpa: Allocator) void {
        self.engine.collectGarbage(testing.allocator);
        self.engine.destroy(gpa);
        testing.allocator.destroy(self.shared);
    }

    fn send(self: *T, cmd: AudioCmd) !void {
        try testing.expect(self.engine.cmds.trySend(cmd));
    }

    fn run(self: *T, blocks: usize) void {
        for (0..blocks) |_| Engine.process(self.engine, &self.block, &.{});
    }

    fn runInput(self: *T, blocks: usize, input: []const Frame) void {
        for (0..blocks) |_| Engine.process(self.engine, &self.block, input);
    }

    fn peak(self: *const T) f32 {
        var m: f32 = 0;
        for (self.block) |x| m = @max(m, @abs(x));
        return m;
    }

    fn ids(self: *const T, out: []usize) []usize {
        for (self.engine.phrases[0..self.engine.phrase_len], 0..) |pp, i| out[i] = pp.phrase.id;
        return out[0..self.engine.phrase_len];
    }
};

/// Heap phrases (testing.allocator) from V3 session rows.
fn testPhrases(rows: []const u8) ![]*Phrase {
    const gpa = testing.allocator;
    const text = try std.fmt.allocPrint(gpa, "MAQAM_SESSION_V3\n{s}", .{rows});
    defer gpa.free(text);
    var r = try session.load(gpa, text, .{});
    defer r.deinit(gpa);
    const l = switch (r) {
        .ok => |*l| l,
        .err => |m| {
            std.debug.print("test session rejected: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
    const out = try gpa.alloc(*Phrase, l.phrases.len);
    for (l.phrases, 0..) |*p, i| out[i] = try Phrase.create(gpa, try p.clone(gpa));
    return out;
}

fn addAll(t: *T, rows: []const u8) !void {
    const ps = try testPhrases(rows);
    defer testing.allocator.free(ps);
    for (ps) |p| try t.send(.{ .add_phrase = p });
}

test "the process path never allocates or frees after create" {
    defer tuning.Maqam.resetToDefaults();
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = fa.allocator();
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const allocs = fa.allocations;
    const frees = fa.deallocations;
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = 0;

    const input = try syntheticGuitar(testing.allocator, 48_000, 0.2);
    defer testing.allocator.free(input);
    const model = try nam.Model.loadFile(testing.allocator, testing.io, "testdata/nam/tiny_wavenet_a2.nam", null);
    var mailbox: channel.Mailbox(LatencyResult) = .{};

    try t.send(.clear);
    try t.send(.reset_session_state);
    try t.send(.{ .set_bpm = 240 });
    try t.send(.{ .set_sustain = 0.5 });
    try t.send(.{ .set_vcf_bank = .{} });
    try t.send(.{ .set_fx_settings = .{ .reverb_enabled = true, .delay_enabled = true, .flanger_enabled = true, .chorus_enabled = true } });
    try t.send(.{ .set_vol = 0.8 });
    try t.send(.{ .set_paused = false });
    try t.send(.{ .set_nam_model = model });
    try t.send(.{ .set_nam_gain = 2.0 });
    try t.send(.{ .set_nam_input = .left });
    try t.send(.{ .set_nam_enabled = true });
    try t.send(.{ .measure_input_latency = .{ .input = .left, .result = &mailbox } });
    try t.send(.{ .set_sympathetics = true });
    try t.send(.{ .set_sympathetic_decay = 0.995 });
    try t.send(.{ .set_sympathetic_gain = 4.0 });
    var harmony: SympatheticHarmony = .{};
    _ = harmony.push(.{ .ratio = 1.0, .weight = 0.5 });
    _ = harmony.push(.{ .ratio = 1.5, .weight = 0.5 });
    try t.send(.{ .set_sympathetic = .{ .harmony = harmony, .kanun = 0.3 } });
    try t.send(.{ .set_vcf = .{ .enabled = true, .target = .bass, .cutoff_hz = .{ .set = 900 } } });
    try t.send(.{ .set_vcf = .{ .enabled = true, .target = .bass, .cutoff_hz = .{ .set = 99999 } } }); // rejected
    try t.send(.{ .set_fx = .{ .reverb_mix = .{ .set = 0.4 } } });
    try t.send(.{ .set_fx = .{ .reverb_mix = .{ .set = 7 } } }); // rejected
    try addAll(&t,
        \\B|1|300
        \\Y|2|sym on
        \\V|3|vcf kanun cut 800 res 0.5
        \\F|4|reverb mix 0.3
        \\P|5|1|d bayati 332
        \\P|6|2|c rast 44
        \\J|7|5|2
        \\P|8|1|g hijaz 3
        \\T|9|stop
    );
    try t.send(.{ .set_cur_phrase = 0 });
    t.runInput(400, input[0..256]);

    const more = try testPhrases("P|10|1|a saba 22\nP|11|1|e kurd 4");
    defer testing.allocator.free(more);
    try t.send(.{ .insert_phrase = .{ .pos = 1, .phrase = more[0] } });
    try t.send(.{ .replace_phrase = more[1] }); // no id 11 yet: handed back
    try t.send(.rotate);
    try t.send(.{ .move_phrase = .{ .id = 5, .down = true } });
    try t.send(.{ .queue_next_phrase = 8 });
    try t.send(.{ .remove_phrase = 6 });
    try t.send(.{ .set_nam_model = null });
    t.runInput(200, input[0..256]);
    try t.send(.{ .set_paused = true });
    t.run(10);
    try t.send(.reset_session_state);
    try t.send(.clear);
    t.run(10);

    try testing.expectEqual(allocs, fa.allocations);
    try testing.expectEqual(frees, fa.deallocations);
    try testing.expect(mailbox.take() != null);
}

test "phrases: add, insert, replace, remove, rotate, move, clear" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    var buf: [16]usize = undefined;
    try addAll(&t, "P|1|1|d bayati 332\nP|2|1|c rast 332\nP|3|1|g hijaz 332");
    t.run(1);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, t.ids(&buf));

    const ins = try testPhrases("P|4|1|a saba 4");
    defer gpa.free(ins);
    try t.send(.{ .insert_phrase = .{ .pos = 0, .phrase = ins[0] } });
    t.run(1);
    try testing.expectEqualSlices(usize, &.{ 4, 1, 2, 3 }, t.ids(&buf));
    try testing.expectEqual(@as(usize, 1), t.engine.cur_phrase); // the playing phrase stays current

    const rep = try testPhrases("P|2|3|f kurd 22");
    defer gpa.free(rep);
    try t.send(.{ .replace_phrase = rep[0] });
    t.run(1);
    try testing.expectEqual(@as(usize, 3), t.engine.phrases[2].phrase.repeat);
    try testing.expectEqual(@as(usize, 1), t.engine.garbage.len()); // the replaced phrase came back
    t.engine.collectGarbage(gpa);

    try t.send(.rotate);
    t.run(1);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, t.ids(&buf));
    try t.send(.{ .move_phrase = .{ .id = 1, .down = true } });
    t.run(1);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 3, 4 }, t.ids(&buf));
    try t.send(.{ .move_phrase = .{ .id = 2, .down = false } }); // already first: nothing
    t.run(1);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 3, 4 }, t.ids(&buf));
    try t.send(.{ .remove_phrase = 3 });
    t.run(1);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 4 }, t.ids(&buf));
    try testing.expectEqual(@as(usize, 1), t.engine.garbage.len());
    t.engine.collectGarbage(gpa);

    try t.send(.clear);
    t.run(1);
    try testing.expectEqual(@as(usize, 0), t.engine.phrase_len);
    try testing.expectEqual(@as(usize, 0), t.engine.voices.items.len);
    try testing.expectEqual(@as(usize, 3), t.engine.garbage.len());
}

test "set_cur_phrase, queue_next_phrase and the published position" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    try addAll(&t, "P|1|1|d bayati 332\nP|2|1|c rast 332\nP|3|1|g hijaz 332");
    try t.send(.{ .set_cur_phrase = 1 });
    t.run(1);
    try testing.expectEqual(@as(usize, 1), t.shared.cur_phrase.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), t.shared.next_phrase.load(.monotonic));
    try t.send(.{ .queue_next_phrase = 1 });
    t.run(1);
    try testing.expectEqual(@as(usize, 0), t.shared.exit_phrase.load(.monotonic));
    // Play out phrase 2 (8 subdivisions at 120 bpm = 2 s): the queued phrase follows.
    t.run(48_000 * 2 / 256 + 2);
    try testing.expectEqual(@as(usize, 0), t.shared.cur_phrase.load(.monotonic));
    try testing.expectEqual(@as(?usize, null), t.engine.pending_next_id);
    try t.send(.{ .set_cur_phrase = 99 }); // out of range: ignored
    t.run(1);
    try testing.expectEqual(@as(usize, 0), t.engine.cur_phrase);
}

test "jumps count passes, publish counters and wraps count cycles" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    // bpm 400: a subdivision is 3600 samples; each phrase lasts 8 subdivisions (rhythm 332).
    try addAll(&t, "B|1|400\nP|2|1|d bayati 2\nJ|3|2|3\nP|4|1|c rast 2");
    try t.send(.{ .set_cur_phrase = 0 });
    var max_counter: usize = 0;
    for (0..(4 * 8 * 3600) / 256 + 20) |_| {
        t.run(1);
        max_counter = @max(max_counter, t.shared.jumpCounter(3));
    }
    try testing.expectEqual(@as(usize, 2), max_counter); // two jump-backs, then fall through
    try testing.expect(t.shared.cycles.load(.monotonic) >= 1);
    try testing.expect(t.shared.phrase_starts.load(.monotonic) >= 3);
    try t.send(.clear);
    t.run(1);
    try testing.expectEqual(@as(usize, 0), t.shared.jumpCounter(3));
}

test "controls on the timeline apply as the sequencer passes them; stop rows are counted" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    try addAll(&t,
        \\B|1|200
        \\S|2|0.7
        \\V|3|vcf bass cut 700
        \\F|4|reverb mix 0.25
        \\Y|5|sym on
        \\Y|6|sym bass amount 0.4
        \\P|7|1|d bayati 332
        \\T|8|stop
    );
    try t.send(.{ .set_cur_phrase = 0 });
    t.run(2);
    const e = t.engine;
    try testing.expectEqual(@as(f64, 200), e.bpm);
    try testing.expectEqual(@as(f64, 0.7), e.sustain);
    try testing.expectEqual(@as(f32, 700), e.vcf.bass.cutoff_hz);
    try testing.expect(e.fx.reverb_enabled);
    try testing.expectEqual(@as(f32, 0.25), e.fx.reverb_mix);
    try testing.expect(e.sympathetics_enabled);
    try testing.expectEqual(@as(f32, 0.4), e.sym.bass.amount);
    try testing.expect(t.peak() > 0.0);
    try testing.expectEqual(@as(u64, 0), e.stops_seen);
    t.run(48_000 * 3 / 256);
    try testing.expect(e.stops_seen >= 1);
}

test "settings commands: bpm, sustain, vcf, fx, vol, pause, sympathetics" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const e = t.engine;
    try addAll(&t, "P|1|1|d bayati 332");
    try t.send(.{ .set_bpm = 90 });
    try t.send(.{ .set_sustain = 2.0 });
    try t.send(.{ .set_vcf_bank = .{ .kick = .{ .enabled = true, .target = .kick, .cutoff_hz = 300 } } });
    try t.send(.{ .set_vcf = .{ .target = .kick, .resonance = .{ .set = 0.5 } } });
    try t.send(.{ .set_fx_settings = .{ .delay_enabled = true } });
    try t.send(.{ .set_fx = .{ .delay_time_secs = .{ .set = 0.25 } } });
    try t.send(.{ .set_vol = 0.5 });
    try t.send(.{ .set_sympathetics = true });
    try t.send(.{ .set_sympathetic_decay = 0.95 });
    try t.send(.{ .set_sympathetic_gain = 8.0 });
    try t.send(.{ .set_sympathetic = .{ .target = .drums, .enabled = false, .amount = 0.7 } });
    try t.send(.{ .set_cur_phrase = 0 });
    t.run(1);
    try testing.expectEqual(@as(f64, 90), e.bpm);
    try testing.expectEqual(48_000.0 * 60.0 / 180.0, e.phrases[0].subdiv_samples);
    try testing.expectEqual(@as(f64, 2.0), e.sustain);
    try testing.expect(e.vcf.kick.enabled);
    try testing.expectEqual(@as(f32, 0.5), e.vcf.kick.resonance);
    try testing.expectEqual(Bus.kick, e.routes[@backingInt(VoiceKind.floor_tom)].bus);
    try testing.expectEqual(@as(f32, 0.25), e.fx.delay_time_secs);
    try testing.expectEqual(@as(f32, 0.5), e.vol);
    try testing.expect(e.sympathetics_enabled);
    try testing.expectEqual(@as(f32, 0.95), e.sym.mic.strings.decay);
    try testing.expectEqual(@as(f32, 8.0), e.sym.kanun.strings.input_gain);
    try testing.expect(!e.sym.drums.enabled);
    try testing.expectEqual(@as(f32, 0.7), e.sym.drums.amount);
    try testing.expect(e.sym.mic.strings.modes.items.len > 0); // retuned to the playing phrase
    try testing.expect(t.peak() > 0.0);

    try t.send(.{ .set_paused = true });
    try t.send(.{ .set_sympathetics = false });
    try t.send(.{ .set_fx_settings = .{} });
    try t.send(.{ .set_vcf_bank = .{} });
    t.run(48_000 * 10 / 256); // voices and strings die away
    try testing.expect(e.paused);
    try testing.expectEqual(@as(f32, 0.0), t.peak());
}

test "nam commands, input routing, meters and the latency mailbox" {
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const e = t.engine;
    const model = try nam.Model.loadFile(gpa, testing.io, "testdata/nam/tiny_wavenet_a1.nam", null);
    try t.send(.{ .set_nam_model = model });
    t.run(1);
    try testing.expect(e.nam_enabled);
    try testing.expect(t.shared.nam_model_active.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), t.shared.nam_status.load(.monotonic));

    var input: [256]Frame = undefined;
    for (&input, 0..) |*f, i| f.* = .{ 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.05), 0.0 };
    try t.send(.{ .set_nam_input = .left });
    try t.send(.{ .set_nam_gain = 400.0 }); // clamped
    t.runInput(20, &input);
    try testing.expectEqual(@as(f32, 100.0), e.nam_gain);
    try t.send(.{ .set_nam_gain = 40.0 });
    t.runInput(20, &input);
    try testing.expectEqual(@as(f32, 40.0), e.nam_gain);
    try testing.expect(t.peak() > 0.0); // NAM keeps the live input audible
    try t.send(.{ .set_nam_input = .right }); // the silent channel
    t.runInput(2, &input);
    try testing.expectEqual(e.buf.live[10], e.buf.live[200]); // a constant: the model's answer to silence

    try t.send(.{ .set_nam_enabled = false });
    t.run(1);
    try testing.expectEqual(@as(usize, 5), t.shared.nam_status.load(.monotonic));
    try testing.expect(!t.shared.nam_model_active.load(.monotonic));

    var mailbox: channel.Mailbox(LatencyResult) = .{};
    try t.send(.{ .measure_input_latency = .{ .input = .stereo, .result = &mailbox } });
    t.run(1);
    try testing.expectEqual(@as(?LatencyResult, null), mailbox.take()); // no input yet
    t.runInput(1, &input);
    const got = mailbox.take().?;
    try testing.expectApproxEqAbs(@as(f64, 256.0 * 1000.0 / 48_000.0), got.ok, 1e-9);

    t.runInput(48_000 * 10 / 256 + 1, &input); // meters publish every 10 s of audio
    try testing.expect(Shared.loadLevel(&t.shared.input_left_level) > 0.25);
    try testing.expectEqual(@as(f32, 0.0), Shared.loadLevel(&t.shared.input_right_level));
    try testing.expect(t.shared.latency_left_us.load(.monotonic) > 0);

    try t.send(.{ .set_nam_model = null });
    t.run(1);
    try testing.expectEqual(@as(usize, 1), e.garbage.len());
    try testing.expectEqual(@as(usize, 0), t.shared.nam_status.load(.monotonic));
}

test "reset_session_state restores the defaults and hands the model back" {
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const e = t.engine;
    try t.send(.{ .set_nam_model = try nam.Model.loadFile(gpa, testing.io, "testdata/nam/tiny_lstm.nam", null) });
    try t.send(.{ .set_sympathetics = true });
    try t.send(.{ .set_sympathetic_gain = 9.0 });
    try t.send(.{ .set_vcf_bank = .{ .all = .{ .enabled = true } } });
    try t.send(.{ .set_fx_settings = .{ .reverb_enabled = true } });
    t.run(2);
    try t.send(.reset_session_state);
    t.run(1);
    try testing.expectEqual(@as(?*nam.Model, null), e.nam_model);
    try testing.expect(!e.nam_enabled);
    try testing.expect(!e.sympathetics_enabled);
    try testing.expectEqual(@as(f32, 2.0), e.sym.mic.strings.input_gain);
    try testing.expect(!e.vcf.all.enabled);
    try testing.expect(!e.fx.active());
    for (e.fx_processor.rev_l) |x| try testing.expectEqual(@as(f32, 0.0), x);
    try testing.expectEqual(@as(usize, 1), e.garbage.len());
}

test "a full garbage ring parks releases and never frees" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const ps = try testPhrases("P|1|1|d bayati 332");
    defer gpa.free(ps);
    // Fill the timeline with 1100 copies (more than the garbage ring holds), then clear.
    var added: usize = 0;
    while (added < 1100) : (added += 1) {
        const p = try Phrase.create(gpa, try ps[0].clone(gpa));
        p.id = added + 1;
        if (!t.engine.cmds.trySend(.{ .add_phrase = p })) {
            t.run(1);
            try t.send(.{ .add_phrase = p });
        }
    }
    ps[0].destroy(gpa);
    t.run(1);
    try testing.expectEqual(@as(usize, 1100), t.engine.phrase_len);
    try t.send(.clear);
    t.run(1);
    try testing.expectEqual(garbage_capacity, t.engine.garbage.len());
    try testing.expectEqual(@as(usize, 1100 - garbage_capacity), t.engine.pending_len);
    t.engine.collectGarbage(gpa);
    t.run(1);
    try testing.expectEqual(@as(usize, 0), t.engine.pending_len);
}

const tiny_session =
    \\MAQAM_SESSION_V3
    \\Y|1|sym on
    \\F|2|reverb mix 0.3
    \\B|3|300
    \\P|4|1|d bayati 332
    \\P|5|2|c rast 44
;

test "renders are deterministic" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    const a = try render(gpa, testing.io, tiny_session, 1, 48_000);
    defer a.deinit(gpa);
    const b = try render(gpa, testing.io, tiny_session, 1, 48_000);
    defer b.deinit(gpa);
    try testing.expect(a.ok.len > 0);
    try testing.expectEqual(@as(usize, 0), a.ok.len % render_block_frames);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.ok), std.mem.sliceAsBytes(b.ok));
    var peak: f32 = 0;
    for (a.ok) |x| peak = @max(peak, @abs(x));
    try testing.expect(peak > 0.01 and peak <= 1.0);
    // One cycle at 300 bpm: 8 + 2 * 8 subdivisions of 0.1 s.
    try testing.expect(a.ok.len >= 48_000 * 24 / 10 and a.ok.len < 48_000 * 26 / 10);

    const two = try render(gpa, testing.io, tiny_session, 2, 48_000);
    defer two.deinit(gpa);
    try testing.expect(two.ok.len > a.ok.len);

    const bad = try render(gpa, testing.io, "nonsense", 1, 48_000);
    defer bad.deinit(gpa);
    try testing.expect(bad == .err);
}

test "render default.mq ends at its stop row" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "default.mq", gpa, .limited(1 << 20));
    defer gpa.free(text);
    const r = try render(gpa, testing.io, text, 1, 48_000);
    defer r.deinit(gpa);
    const s = r.ok;
    try testing.expect(s.len > 48_000 * 5 and s.len < 48_000 * render_cap_seconds);
    var peak: f32 = 0;
    for (s) |x| {
        try testing.expect(std.math.isFinite(x));
        peak = @max(peak, @abs(x));
    }
    try testing.expect(peak > 0.05 and peak <= 1.0);
}

test "bench runs the live path with sympathetics, reverb and a NAM capture" {
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    const r = try bench(gpa, testing.io, tiny_session, 0.05, 64, 48_000, "testdata/nam/tiny_wavenet_a2.nam", null, false);
    try testing.expectEqual(@as(u64, 38), r.callbacks);
    try testing.expectEqual(@as(u32, 64), r.frames);
    try testing.expect(r.callback_max_us >= r.callback_p50_us);
}

test "bench default.mq at 64 frames (timings printed in ReleaseFast only)" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    defer tuning.Maqam.resetToDefaults();
    const gpa = testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "default.mq", gpa, .limited(1 << 20));
    defer gpa.free(text);
    const cases = [_]?[]const u8{ null, "testdata/nam/marshall_jcm800.nam" };
    for (cases) |nam_path| {
        const r = try bench(gpa, testing.io, text, 20.0, 64, 48_000, nam_path, null, false);
        std.debug.print("bench default.mq 64 frames nam={s}: callbacks={d} misses={d} p50={d:.1}us p99={d:.1}us max={d:.1}us late_start={d:.1}us slack={d:.1}us\n", .{ nam_path orelse "none", r.callbacks, r.deadline_misses, r.callback_p50_us, r.callback_p99_us, r.callback_max_us, r.release_late_max_us, r.slack_min_us });
        try testing.expectEqual(@as(u64, 0), r.deadline_misses);
    }
}

test "post_vcf_trim_is_strictly_linear" {
    const full = postVcfOutputStem(.{ 4.0, -4.0 }, 1.0, 1.0);
    const quiet = postVcfOutputStem(.{ 4.0, -4.0 }, 1.0, 0.125);
    try testing.expectEqual([2]f32{ 1.0, -1.0 }, full);
    try testing.expectApproxEqAbs(full[0] * 0.125, quiet[0], 1e-6);
    try testing.expectApproxEqAbs(full[1] * 0.125, quiet[1], 1e-6);
}

test "active_nam_has_no_parallel_dry_signal" {
    try testing.expectEqual(@as(f32, -0.25), selectNamOutput(0.75, -0.25, true));
    try testing.expectEqual(@as(f32, 0.75), selectNamOutput(0.75, -0.25, false));
}

test "dry_mix_crossfades_after_all_processing" {
    try testing.expectEqual([2]f32{ 0.8, -0.4 }, applyDryMix(.{ 0.8, -0.4 }, 0.2, 0.0));
    try testing.expectEqual([2]f32{ 0.2, 0.2 }, applyDryMix(.{ 0.8, -0.4 }, 0.2, 1.0));
    const half = applyDryMix(.{ 0.8, -0.4 }, 0.2, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), half[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.1), half[1], 1e-6);
}

test "dry 100 plays the raw input alone, with or without a NAM model, and vol mic trims the input" {
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const e = t.engine;
    e.has_input_stream = true;
    var input: [256]Frame = undefined;
    for (&input, 0..) |*f, i| f.* = .{ 0.4 * @sin(@as(f32, @floatFromInt(i)) * 0.07), 0.0 };
    try t.send(.{ .set_nam_input = .left });
    try t.send(.{ .set_dry = 100 });
    t.runInput(1, &input);
    for (0..256) |j| {
        try testing.expectApproxEqAbs(input[j][0], t.block[2 * j], 1e-6);
        try testing.expectApproxEqAbs(input[j][0], t.block[2 * j + 1], 1e-6);
    }
    const model = try nam.Model.loadFile(gpa, testing.io, "testdata/nam/tiny_wavenet_a1.nam", null);
    try t.send(.{ .set_nam_model = model });
    t.runInput(1, &input);
    for (0..256) |j| try testing.expectApproxEqAbs(input[j][0], t.block[2 * j], 1e-6);
    // dry 0: the modeled input on the mic bus, silenced by vol mic 0
    try t.send(.{ .set_dry = 0 });
    try t.send(.{ .set_bus_vol = .{ .target = .mic, .value = 0.0 } });
    t.runInput(2, &input);
    try testing.expectEqual(@as(f32, 0.0), t.peak());
    try t.send(.{ .set_bus_vol = .{ .target = .mic, .value = 1.0 } });
    t.runInput(2, &input);
    try testing.expect(t.peak() > 0.0);
    // a session reset puts the dry mix back to 0
    try t.send(.{ .set_dry = 40 });
    t.run(1);
    try testing.expectApproxEqAbs(@as(f32, 0.4), e.dry_mix, 1e-6);
    try t.send(.reset_session_state);
    t.run(1);
    try testing.expectEqual(@as(f32, 0.0), e.dry_mix);
}

test "the cabinet stage follows the fx settings and fx off turns it off" {
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit(gpa);
    const e = t.engine;
    try t.send(.{ .set_fx = .{ .cabinet_enabled = true, .cabinet_model = .open } });
    t.run(1);
    try testing.expect(e.fx.cabinet_enabled);
    try testing.expectEqual(fx_mod.CabinetModel.open, e.cabinet.model);
    try t.send(.{ .set_fx = .{ .flanger_enabled = false, .chorus_enabled = false, .reverb_enabled = false, .delay_enabled = false, .cabinet_enabled = false } });
    t.run(1);
    try testing.expect(!e.fx.cabinet_enabled);
}
