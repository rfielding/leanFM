//! Port of maqam-live `src/sequencer.rs`: the phrase and bar data structures (`SubdivEvent`, `Bar`,
//! `JumpSpec`, `ControlSpec`, `Phrase` with `displaySrc` etc.), the entry builders
//! (`buildJumpEntry`, `buildControlEntry`, `BarSpec`, `buildPhrase`), `eventsFromFreqs`,
//! `melodyWalk` and the app-to-audio command `AudioCmd`. It also holds `resolveRhythms` (a helper
//! of app.rs that turns parsed jins specs into `BarSpec`s), since the phrase builders and the
//! session loaders both need it.
//!
//! Comma-separated ajnas form ONE combined scale (stacked, not sequential); the melody walks
//! through all frequencies of all ajnas together.
//!
//! Ownership: a `Phrase` owns its `src` and every slice of its `Bar` (`maqam_names` owns only the
//! outer slice; the names are interned by tuning.zig). Free with `Phrase.deinit(gpa)`, or
//! `Phrase.destroy(gpa)` for a heap phrase made with `Phrase.create`. `BarSpec` borrows. Rejection
//! messages of the builders are owned by the caller.
//!
//! The audio output path rewrites a bar in place (`Bar.recomputeEvents`, synth.evolveBar) and
//! never allocates; `Bar.recomputeEventsAlloc` is the off-audio variant for a bar whose groups
//! changed.
//!
//! Deliberate differences from the Rust (each so that no input can crash the app, or to bound what
//! the specification lists as unbounded upstream):
//! * `buildPhrase` returns `BuildResult` instead of panicking: a combined scale of fewer than 3
//!   notes is rejected (the Rust's `clamp(2, n - 1)` panics for 0, 1 or 2 notes, e.g.
//!   `create Zz 1/1` then `d zz 4`; the specification says impl/zig rejects it), as are an empty
//!   spec list (a Rust assertion) and more than `max_repeat` (20) repeats (the grammar's rN, N<=20).
//! * `buildJumpEntry` returns `BuildResult` and rejects more than `max_jump_times` (10000) passes.
//! * `eventsFromFreqs` reads a missing degree as 0 instead of indexing out of bounds.
//! * `AudioCmd` carries pointers (see its doc comment) where the Rust moves values, and
//!   `measure_input_latency` answers on a `channel.Mailbox(LatencyResult)` instead of a crossbeam
//!   sender; `Garbage` (new) is what the audio side hands back for the App to free.
const std = @import("std");
const Allocator = std.mem.Allocator;
const channel = @import("channel.zig");
const command = @import("command.zig");
const fx = @import("fx.zig");
const nam = @import("nam.zig");
const synth = @import("synth.zig");
const tuning = @import("tuning.zig");
const vcf = @import("vcf.zig");

const FxChange = command.FxChange;
const NamInput = command.NamInput;
const SympatheticChange = command.SympatheticChange;
const VcfChange = command.VcfChange;
const FxSettings = fx.FxSettings;
const Maqam = tuning.Maqam;
const Pitch = tuning.Pitch;
const VcfBank = vcf.VcfBank;

/// Most repeats a phrase row may have (the grammar's rN, N <= 20).
pub const max_repeat: usize = 20;
/// Most passes a jump row may count.
pub const max_jump_times: usize = 10_000;

// ── Rust str helpers (Unicode whitespace, as Rust's trim / split_whitespace) ──

pub const rust_str = struct {
    /// Byte length of the Unicode whitespace character at `s[i]`, or 0.
    pub fn wsLen(s: []const u8, i: usize) usize {
        const b = s[i];
        if (b < 0x80) return if ((b >= 0x09 and b <= 0x0D) or b == 0x20) 1 else 0;
        const n = std.unicode.utf8ByteSequenceLength(b) catch return 0;
        if (i + n > s.len) return 0;
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return 0;
        const ws = switch (cp) {
            0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
            0x2000...0x200A => true,
            else => false,
        };
        return if (ws) n else 0;
    }

    fn charLen(s: []const u8, i: usize) usize {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
        if (i + n > s.len) return 1;
        return n;
    }

    const Span = struct { start: usize, end: usize };

    /// First non-whitespace byte and the end of the last non-whitespace character.
    fn span(s: []const u8) Span {
        var i: usize = 0;
        var start: ?usize = null;
        var end: usize = 0;
        while (i < s.len) {
            const w = wsLen(s, i);
            if (w > 0) {
                i += w;
                continue;
            }
            const n = charLen(s, i);
            if (start == null) start = i;
            i += n;
            end = i;
        }
        return .{ .start = start orelse s.len, .end = if (start == null) s.len else end };
    }

    pub fn trim(s: []const u8) []const u8 {
        const sp = span(s);
        return s[sp.start..sp.end];
    }

    pub fn trimEnd(s: []const u8) []const u8 {
        const sp = span(s);
        return if (sp.start == s.len) s[0..0] else s[0..sp.end];
    }

    /// Iterator over whitespace-separated words (Rust `split_whitespace`).
    pub const Words = struct {
        s: []const u8,
        i: usize = 0,

        pub fn next(self: *Words) ?[]const u8 {
            while (self.i < self.s.len) {
                const w = wsLen(self.s, self.i);
                if (w == 0) break;
                self.i += w;
            }
            if (self.i >= self.s.len) return null;
            const start = self.i;
            while (self.i < self.s.len and wsLen(self.s, self.i) == 0) self.i += charLen(self.s, self.i);
            return self.s[start..self.i];
        }
    };

    pub fn words(s: []const u8) Words {
        return .{ .s = s };
    }

    pub fn firstWord(s: []const u8) ?[]const u8 {
        var it = words(s);
        return it.next();
    }

    pub fn lastWord(s: []const u8) ?[]const u8 {
        var it = words(s);
        var last: ?[]const u8 = null;
        while (it.next()) |w| last = w;
        return last;
    }
};

// ── Bar event ─────────────────────────────────────────────────────────────────

pub const SubdivEvent = union(enum) {
    kick: f64,
    snare: f64,
};

// ── Bar ───────────────────────────────────────────────────────────────────────
// One bar represents the full combined scale of all ajnas in a phrase.

pub const Bar = struct {
    /// Original pitch (for display).
    root: Pitch,
    /// Actual lattice-snapped root Hz.
    root_hz: f64,
    /// First jins: for display.
    maqam: Maqam,
    /// All jins names (interned; the slice is owned).
    maqam_names: []const []const u8,
    /// Actual JI ratios per jins, for display.
    ratio_strs: []const []const u8,
    /// Scale-index handoffs between stacked ajnas.
    jins_boundaries: []const usize,
    /// Rhythm groups.
    groups: []const u8,
    /// Combined JI scale (tonic first).
    frequencies: []const f64,
    /// Waypoints (n_groups + 1), index into frequencies. Rewritten in place by evolution.
    group_degrees: []usize,
    /// Per-subdivision index into frequencies.
    degrees: []usize,
    events: []SubdivEvent,
    total_subdivs: usize,

    /// Recompute `degrees` and `events` from `group_degrees`, in place (never allocates; the
    /// slices keep the lengths they were built with).
    pub fn recomputeEvents(self: *Bar) void {
        _ = synth.expandDegreesInto(self.degrees, self.group_degrees, self.groups);
        _ = eventsFromFreqsInto(self.events, self.degrees, self.frequencies, self.groups);
    }

    /// Like the Rust `recompute_events` for a bar whose `groups` changed: resizes `degrees` and
    /// `events` first. Not for the audio path.
    pub fn recomputeEventsAlloc(self: *Bar, gpa: Allocator) Allocator.Error!void {
        const nd = synth.expandDegreesLen(self.groups);
        if (nd != self.degrees.len) {
            const d = try gpa.alloc(usize, nd);
            gpa.free(self.degrees);
            self.degrees = d;
        }
        const ne = eventsFromFreqsLen(self.frequencies, self.groups);
        if (ne != self.events.len) {
            const e = try gpa.alloc(SubdivEvent, ne);
            gpa.free(self.events);
            self.events = e;
        }
        self.recomputeEvents();
    }

    /// 'X' for a kick, '.' for a snare. Caller owns the result.
    pub fn rhythmDisplay(self: *const Bar, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, self.events.len);
        for (self.events, 0..) |e, i| out[i] = switch (e) {
            .kick => 'X',
            .snare => '.',
        };
        return out;
    }

    pub fn deinit(self: *Bar, gpa: Allocator) void {
        gpa.free(self.maqam_names);
        for (self.ratio_strs) |s| gpa.free(s);
        gpa.free(self.ratio_strs);
        gpa.free(self.jins_boundaries);
        gpa.free(self.groups);
        gpa.free(self.frequencies);
        gpa.free(self.group_degrees);
        gpa.free(self.degrees);
        gpa.free(self.events);
        self.* = undefined;
    }

    pub fn clone(self: *const Bar, gpa: Allocator) Allocator.Error!Bar {
        var b: Bar = emptyBarValue(self.maqam);
        b.root = self.root;
        b.root_hz = self.root_hz;
        b.total_subdivs = self.total_subdivs;
        errdefer b.deinit(gpa);
        b.maqam_names = try gpa.dupe([]const u8, self.maqam_names);
        b.ratio_strs = try dupeStrs(gpa, self.ratio_strs);
        b.jins_boundaries = try gpa.dupe(usize, self.jins_boundaries);
        b.groups = try gpa.dupe(u8, self.groups);
        b.frequencies = try gpa.dupe(f64, self.frequencies);
        b.group_degrees = try gpa.dupe(usize, self.group_degrees);
        b.degrees = try gpa.dupe(usize, self.degrees);
        b.events = try gpa.dupe(SubdivEvent, self.events);
        return b;
    }
};

// ── Phrase ────────────────────────────────────────────────────────────────────

/// A jump instruction stored as a sequence entry.
pub const JumpSpec = struct {
    /// Stable phrase id of the jump target.
    target_id: usize,
    fail_target_id: ?usize,
    times: usize,
};

/// A settings/timeline entry (plain values only).
pub const ControlSpec = union(enum) {
    stop,
    set_bpm: f64,
    set_sustain: f64,
    set_vcf: VcfChange,
    set_fx: FxChange,
    set_vol: f32,
    set_bus_vol: BusVol,
    set_dry: f32,
    set_nam_enabled: bool,
    set_nam_gain: f32,
    set_nam_input: NamInput,
    set_sympathetics: bool,
    set_sympathetic_decay: f32,
    set_sympathetic_gain: f32,
    set_sympathetic: SympatheticChange,
};

/// One bus's volume (the Rust `SetBusVol(VcfTarget, f32)`).
pub const BusVol = struct { target: vcf.VcfTarget, value: f32 };

pub const Phrase = struct {
    id: usize,
    src: []const u8,
    bar: Bar,
    repeat: usize,
    /// If set, this is a control-flow entry (no audio).
    jump: ?JumpSpec,
    /// If set, this is a settings/timeline entry (no audio).
    control: ?ControlSpec,

    pub fn deinit(self: *Phrase, gpa: Allocator) void {
        gpa.free(self.src);
        self.bar.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const Phrase, gpa: Allocator) Allocator.Error!Phrase {
        const src = try gpa.dupe(u8, self.src);
        errdefer gpa.free(src);
        return .{
            .id = self.id,
            .src = src,
            .bar = try self.bar.clone(gpa),
            .repeat = self.repeat,
            .jump = self.jump,
            .control = self.control,
        };
    }

    /// Move `phrase` to the heap (for `AudioCmd`). On failure `phrase` is still the caller's.
    pub fn create(gpa: Allocator, phrase: Phrase) Allocator.Error!*Phrase {
        const p = try gpa.create(Phrase);
        p.* = phrase;
        return p;
    }

    /// Free a heap phrase made with `create`.
    pub fn destroy(self: *Phrase, gpa: Allocator) void {
        self.deinit(gpa);
        gpa.destroy(self);
    }

    /// The source as the user wrote it, with ` rN` appended when the repeat is not visible in it.
    /// Caller owns the result.
    pub fn displaySrc(self: *const Phrase, gpa: Allocator) Allocator.Error![]u8 {
        if (self.repeat <= 1 or self.jump != null or self.control != null) return gpa.dupe(u8, self.src);
        const trimmed = rust_str.trimEnd(self.src);
        const last = rust_str.lastWord(trimmed) orelse "";
        if (last.len >= 2 and std.ascii.toLower(last[0]) == 'r') {
            var all_digits = true;
            for (last[1..]) |c| {
                if (!std.ascii.isDigit(c)) all_digits = false;
            }
            if (all_digits) return gpa.dupe(u8, self.src);
        }
        if (last.len == 1 and std.ascii.toLower(last[0]) == 'r') {
            const prefix = rust_str.trimEnd(trimmed[0..trimmed.len -| last.len]);
            return std.fmt.allocPrint(gpa, "{s} r{d}", .{ prefix, self.repeat });
        }
        return std.fmt.allocPrint(gpa, "{s} r{d}", .{ trimmed, self.repeat });
    }

    pub fn rhythmDisplay(self: *const Phrase, gpa: Allocator) Allocator.Error![]u8 {
        return self.bar.rhythmDisplay(gpa);
    }

    /// The jins ratio strings joined with " | ". Caller owns the result.
    pub fn pitchRatiosDisplay(self: *const Phrase, gpa: Allocator) Allocator.Error![]u8 {
        return std.mem.join(gpa, " | ", self.bar.ratio_strs);
    }
};

fn emptyBarValue(maqam: Maqam) Bar {
    return .{
        .root = .{ .letter = 'd', .accidental = 0, .octave = 4 },
        .root_hz = 293.6648,
        .maqam = maqam,
        .maqam_names = &.{},
        .ratio_strs = &.{},
        .jins_boundaries = &.{},
        .groups = &.{},
        .frequencies = &.{},
        .group_degrees = &.{},
        .degrees = &.{},
        .events = &.{},
        .total_subdivs = 0,
    };
}

/// The Rust `empty_bar` (empty slices need no freeing; `Bar.deinit` accepts them).
pub fn emptyBar() Allocator.Error!Bar {
    return emptyBarValue(try Maqam.new("Nahawand"));
}

/// The Rust `Result<Phrase, String>` of the builders; `err` is owned by the caller.
pub const BuildResult = union(enum) {
    ok: Phrase,
    err: []u8,

    pub fn deinit(self: *BuildResult, gpa: Allocator) void {
        switch (self.*) {
            .ok => |*p| p.deinit(gpa),
            .err => |m| gpa.free(m),
        }
    }
};

/// Build a jump-entry phrase (no audio: pure sequencer control flow). Rejects more than
/// `max_jump_times` passes.
pub fn buildJumpEntry(gpa: Allocator, id: usize, target_id: usize, fail_target_id: ?usize, times: usize) Allocator.Error!BuildResult {
    if (times > max_jump_times) {
        return .{ .err = try std.fmt.allocPrint(gpa, "jump times {d} is too many; use 1..{d}, or always", .{ times, max_jump_times }) };
    }
    const src = if (times == 0)
        try std.fmt.allocPrint(gpa, "j {d} always", .{target_id})
    else if (fail_target_id) |fail|
        try std.fmt.allocPrint(gpa, "j {d} else {d} {d}", .{ target_id, fail, times })
    else
        try std.fmt.allocPrint(gpa, "j {d} {d}", .{ target_id, times });
    errdefer gpa.free(src);
    return .{ .ok = .{
        .id = id,
        .src = src,
        .bar = try emptyBar(),
        .repeat = 1,
        .jump = .{ .target_id = target_id, .fail_target_id = fail_target_id, .times = times },
        .control = null,
    } };
}

/// Build a control entry; `src` is copied.
pub fn buildControlEntry(gpa: Allocator, id: usize, src: []const u8, control: ControlSpec) Allocator.Error!Phrase {
    const s = try gpa.dupe(u8, src);
    errdefer gpa.free(s);
    return .{
        .id = id,
        .src = s,
        .bar = try emptyBar(),
        .repeat = 1,
        .jump = null,
        .control = control,
    };
}

// ── Builder ───────────────────────────────────────────────────────────────────

/// One jins of a phrase with its resolved rhythm. Borrows `src` and `groups`.
pub const BarSpec = struct {
    src: []const u8,
    root: Pitch,
    maqam: Maqam,
    groups: []const u8,
};

/// The app.rs `resolve_rhythms`: a spec without a rhythm takes the next later one's, and the
/// last ones without any take `default`. The result borrows from `specs` and `default`; free the
/// slice with `gpa.free`.
pub fn resolveRhythms(gpa: Allocator, specs: []const command.JinsSpec, default: []const u8) Allocator.Error![]BarSpec {
    const out = try gpa.alloc(BarSpec, specs.len);
    var carry: ?[]const u8 = null;
    var i = specs.len;
    while (i > 0) {
        i -= 1;
        if (specs[i].groups) |g| carry = g;
        out[i] = .{
            .src = specs[i].src,
            .root = specs[i].root,
            .maqam = specs[i].maqam,
            .groups = specs[i].groups orelse (carry orelse default),
        };
    }
    return out;
}

fn dupeStrs(gpa: Allocator, strs: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, strs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |x| gpa.free(x);
        gpa.free(out);
    }
    for (strs) |x| {
        out[filled] = try gpa.dupe(u8, x);
        filled += 1;
    }
    return out;
}

fn ratioStrings(gpa: Allocator, specs: []const BarSpec) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, specs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |x| gpa.free(x);
        gpa.free(out);
    }
    for (specs) |sp| {
        const ratios = try sp.maqam.ratios(gpa);
        defer gpa.free(ratios);
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(gpa);
        for (ratios, 0..) |r, i| {
            if (i > 0) try line.append(gpa, ' ');
            try line.print(gpa, "{d}/{d}", .{ r.p, r.q });
        }
        out[filled] = try line.toOwnedSlice(gpa);
        filled += 1;
    }
    return out;
}

const Owned = struct { f: f64, owner: usize };

fn ownedLess(_: void, a: Owned, b: Owned) bool {
    return a.f < b.f;
}

/// Build an audio phrase from its jins specs. `src` is copied; `specs` is borrowed.
///
/// Tetrachord stacking: each jins contributes its ratios from its own (lattice-snapped) root,
/// dropping notes above the octave over the first root and notes within 70 cents of the next
/// jins's root; notes within 50 cents (23 cents for a single jins) of an earlier note are deduped
/// (the earlier jins wins). The tonic is kept as degree 0.
pub fn buildPhrase(
    gpa: Allocator,
    phrase_id: usize,
    src: []const u8,
    specs: []const BarSpec,
    peak_degree: usize,
    repeat: usize,
) Allocator.Error!BuildResult {
    if (specs.len == 0) return .{ .err = try gpa.dupe(u8, "a phrase needs at least one jins, e.g. d bayati 332") };
    if (repeat > max_repeat) {
        return .{ .err = try std.fmt.allocPrint(gpa, "repeat {d} is too many; a phrase repeats at most r{d} (use a jump for longer loops)", .{ repeat, max_repeat }) };
    }
    const root_hz_0 = tuning.snapToOudLattice(specs[0].root.toHz());

    const n_specs = specs.len;
    const roots_hz = try gpa.alloc(f64, n_specs);
    defer gpa.free(roots_hz);
    for (specs, 0..) |s, i| roots_hz[i] = tuning.snapToOudLattice(s.root.toHz());
    const upper_bound = roots_hz[0] * 2.0;
    const dedup_thresh: f64 = if (n_specs > 1) 50.0 / 1200.0 else 23.0 / 1200.0;

    var deduped: std.ArrayList(Owned) = .empty;
    defer deduped.deinit(gpa);

    for (specs, 0..) |spec, i| {
        const root = roots_hz[i];
        const next_root: ?f64 = if (i + 1 < n_specs) roots_hz[i + 1] else null;
        const ratios = try spec.maqam.ratios(gpa);
        defer gpa.free(ratios);
        for (ratios) |r| {
            const f = root * @as(f64, @floatFromInt(r.p)) / @as(f64, @floatFromInt(r.q));
            if (f > upper_bound * 1.001) continue;
            if (next_root) |nr| {
                if (@abs(std.math.log2(f / nr)) < 70.0 / 1200.0) continue;
            }
            var distinct = true;
            for (deduped.items) |prev| {
                if (!(@abs(std.math.log2(f / prev.f)) > dedup_thresh)) {
                    distinct = false;
                    break;
                }
            }
            if (distinct) try deduped.append(gpa, .{ .f = f, .owner = i });
        }
    }

    const n_freqs = deduped.items.len;
    if (n_freqs < 3) {
        return .{ .err = try std.fmt.allocPrint(
            gpa,
            "a phrase needs at least 3 notes in its scale, but this one has {d}; give the jins more ratios (create {s} 1/1 9/8 5/4) or stack another jins after a comma",
            .{ n_freqs, specs[0].maqam.name() },
        ) };
    }

    std.mem.sort(Owned, deduped.items, {}, ownedLess);
    for (deduped.items, 0..) |o, idx| {
        if (@abs(std.math.log2(o.f / root_hz_0)) < 1.0 / 1200.0) {
            // Keep the tonic as degree 0 so lower leading tones like 8/9 wrap to the end of the
            // scale instead of redefining the melodic center.
            std.mem.rotate(Owned, deduped.items, idx);
            break;
        }
    }

    var bar: Bar = emptyBarValue(specs[0].maqam);
    bar.root = specs[0].root;
    bar.root_hz = root_hz_0;
    errdefer bar.deinit(gpa);

    const frequencies = try gpa.alloc(f64, n_freqs);
    for (deduped.items, 0..) |o, i| frequencies[i] = o.f;
    bar.frequencies = frequencies;

    var boundaries: std.ArrayList(usize) = .empty;
    errdefer boundaries.deinit(gpa);
    var prev_owner = deduped.items[0].owner;
    for (deduped.items[1..], 1..) |o, idx| {
        if (o.owner != prev_owner) {
            try boundaries.append(gpa, idx);
            prev_owner = o.owner;
        }
    }
    bar.jins_boundaries = try boundaries.toOwnedSlice(gpa);

    bar.groups = try gpa.dupe(u8, specs[n_specs - 1].groups);
    const n_groups = bar.groups.len;
    const peak = @max(2, @min(peak_degree * n_freqs / 8, n_freqs - 1)); // n_freqs >= 3: the Rust clamp
    bar.group_degrees = try synth.zigzagWalk(gpa, n_groups, peak);
    bar.degrees = try synth.expandDegrees(gpa, bar.group_degrees, bar.groups);
    bar.total_subdivs = bar.degrees.len;
    bar.events = try eventsFromFreqs(gpa, bar.degrees, bar.frequencies, bar.groups);

    const names = try gpa.alloc([]const u8, n_specs);
    for (specs, 0..) |s, i| names[i] = s.maqam.name();
    bar.maqam_names = names;

    // ratio_strs: one entry per jins spec, e.g. "1/1 12/11 32/27 4/3 3/2".
    bar.ratio_strs = try ratioStrings(gpa, specs);

    const s = try gpa.dupe(u8, src);
    return .{ .ok = .{
        .id = phrase_id,
        .src = s,
        .bar = bar,
        .repeat = repeat,
        .jump = null,
        .control = null,
    } };
}

// ── Event computation ─────────────────────────────────────────────────────────

/// Length of `eventsFromFreqs(_, frequencies, groups)`.
pub fn eventsFromFreqsLen(frequencies: []const f64, groups: []const u8) usize {
    if (frequencies.len == 0) return 0;
    var n: usize = 0;
    for (groups) |g| n += g;
    return n;
}

/// `eventsFromFreqs` into `out`; writes at most `out.len` events and returns how many.
pub fn eventsFromFreqsInto(out: []SubdivEvent, degrees: []const usize, frequencies: []const f64, groups: []const u8) usize {
    const n = frequencies.len;
    if (n == 0) return 0;
    var pos: usize = 0;
    for (groups) |g| {
        var i: usize = 0;
        while (i < g) : (i += 1) {
            if (pos >= out.len) return pos;
            const d = if (pos < degrees.len) degrees[pos] else 0;
            const hz = frequencies[@min(d, n - 1)];
            out[pos] = if (g == 1) .{ .snare = hz } else if (i == 0) .{ .kick = hz } else .{ .snare = hz };
            pos += 1;
        }
    }
    return pos;
}

/// In each group the first subdivision is a kick and the rest snares (a group of 1 is a snare).
/// Caller owns the result.
pub fn eventsFromFreqs(gpa: Allocator, degrees: []const usize, frequencies: []const f64, groups: []const u8) Allocator.Error![]SubdivEvent {
    const out = try gpa.alloc(SubdivEvent, eventsFromFreqsLen(frequencies, groups));
    _ = eventsFromFreqsInto(out, degrees, frequencies, groups);
    return out;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Up to the middle then back down to 0 (unused upstream, kept as a port). Caller owns it.
pub fn melodyWalk(gpa: Allocator, n: usize, peak_in: usize) Allocator.Error![]usize {
    if (n == 0) return gpa.alloc(usize, 0);
    if (n == 1) return gpa.dupe(usize, &.{0});
    const peak = @min(peak_in, 7);
    const mid = n / 2;
    const walk = try gpa.alloc(usize, n);
    for (0..n) |i| {
        const d = if (i <= mid)
            (if (mid == 0) 0 else (i * peak + mid / 2) / mid)
        else blk: {
            const rest = n - 1 - i;
            const down = n - 1 - mid;
            break :blk if (down == 0) 0 else (rest * peak + down / 2) / down;
        };
        walk[i] = @min(d, 7);
    }
    walk[n - 1] = 0;
    return walk;
}

// ── Audio commands ────────────────────────────────────────────────────────────

/// The answer to `measure_input_latency`: milliseconds, or a static message.
pub const LatencyResult = union(enum) { ok: f64, err: []const u8 };

/// A command from the App to the audio output path, sent through a lock-free `channel.Ring`.
/// Every payload is a small plain value or a pointer, so sending never copies a phrase and the
/// audio side never allocates or frees:
/// * `add_phrase`, `insert_phrase` and `replace_phrase` carry a heap `*Phrase` (from
///   `Phrase.create`), and `set_nam_model` a `?*nam.Model`. Ownership of the pointee moves to the
///   audio side when the command is sent. The audio side never frees: a phrase it removes or
///   replaces, and a model it replaces, go back to the App on a separate garbage ring as a
///   `Garbage` value, and the App frees them (`Garbage.deinit`).
/// * `measure_input_latency` carries a `*channel.Mailbox(LatencyResult)` the App owns and polls;
///   the audio side fills it once and never frees it.
/// A command that is never delivered (the channel closed) is freed by the sender with `deinit`.
pub const AudioCmd = union(enum) {
    add_phrase: *Phrase,
    remove_phrase: usize,
    insert_phrase: struct { pos: usize, phrase: *Phrase },
    replace_phrase: *Phrase,
    rotate,
    move_phrase: struct { id: usize, down: bool },
    set_bpm: f64,
    set_sustain: f64,
    set_vcf: VcfChange,
    set_vcf_bank: VcfBank,
    set_fx: FxChange,
    set_fx_settings: FxSettings,
    set_nam_model: ?*nam.Model,
    set_nam_enabled: bool,
    set_nam_gain: f32,
    set_nam_input: NamInput,
    measure_input_latency: struct { input: NamInput, result: *channel.Mailbox(LatencyResult) },
    clear,
    reset_session_state,
    set_vol: f32,
    set_bus_vol: BusVol,
    set_dry: f32,
    set_paused: bool,
    set_cur_phrase: usize,
    queue_next_phrase: usize,
    set_sympathetics: bool,
    set_sympathetic_decay: f32,
    set_sympathetic_gain: f32,
    set_sympathetic: SympatheticChange,

    /// Free what the command owns (only for a command that was never delivered; never on the
    /// audio path).
    pub fn deinit(self: AudioCmd, gpa: Allocator) void {
        switch (self) {
            .add_phrase, .replace_phrase => |p| p.destroy(gpa),
            .insert_phrase => |v| v.phrase.destroy(gpa),
            .set_nam_model => |m| if (m) |model| model.deinit(),
            else => {},
        }
    }
};

/// What the audio side hands back to the App to free (it never frees itself).
pub const Garbage = union(enum) {
    phrase: *Phrase,
    nam_model: *nam.Model,

    pub fn deinit(self: Garbage, gpa: Allocator) void {
        switch (self) {
            .phrase => |p| p.destroy(gpa),
            .nam_model => |m| m.deinit(),
        }
    }
};

// ── Tests (sequencer.rs has none; these are the port's own) ──────────────────

const testing = std.testing;

/// Parse a phrase command and build it the way the app does (rhythm default 3 3 2).
fn buildFromSource(gpa: Allocator, id: usize, src: []const u8) !BuildResult {
    var parsed = try command.parse(gpa, src);
    defer parsed.deinit(gpa);
    const ap = switch (parsed) {
        .ok => |c| switch (c) {
            .add_phrase => |v| v,
            else => return error.TestUnexpectedResult,
        },
        .err => |m| {
            std.debug.print("parse failed: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
    const specs = try resolveRhythms(gpa, ap.specs, &.{ 3, 3, 2 });
    defer gpa.free(specs);
    return buildPhrase(gpa, id, ap.source, specs, 4, @max(ap.repeat, 1));
}

test "build phrase: one jins keeps its tetrachord with the tonic first" {
    const gpa = testing.allocator;
    var r = try buildFromSource(gpa, 3, "d bayati 332");
    defer r.deinit(gpa);
    const p = &r.ok;
    try testing.expectEqual(@as(usize, 3), p.id);
    try testing.expectEqualStrings("d bayati 332", p.src);
    try testing.expect(p.bar.frequencies.len >= 3);
    try testing.expectApproxEqAbs(p.bar.root_hz, p.bar.frequencies[0], 1e-9);
    try testing.expectEqualSlices(u8, &.{ 3, 3, 2 }, p.bar.groups);
    try testing.expectEqual(@as(usize, 8), p.bar.total_subdivs);
    try testing.expectEqual(@as(usize, 8), p.bar.events.len);
    try testing.expectEqual(@as(usize, 4), p.bar.group_degrees.len);
    const rh = try p.rhythmDisplay(gpa);
    defer gpa.free(rh);
    try testing.expectEqualStrings("X..X..X.", rh);
    const ratios = try p.pitchRatiosDisplay(gpa);
    defer gpa.free(ratios);
    try testing.expect(std.mem.startsWith(u8, ratios, "1/1 "));
    // Every frequency is the snapped root times a ratio of the jins (property "Just intonation").
    const bay = try p.bar.maqam.ratios(gpa);
    defer gpa.free(bay);
    for (p.bar.frequencies) |f| {
        var found = false;
        for (bay) |x| {
            const g = p.bar.root_hz * @as(f64, @floatFromInt(x.p)) / @as(f64, @floatFromInt(x.q));
            if (@abs(g - f) < 1e-9) found = true;
        }
        try testing.expect(found);
    }
}

test "build phrase: stacked ajnas record their boundaries" {
    const gpa = testing.allocator;
    var r = try buildFromSource(gpa, 0, "d bayati, a nahawand 332");
    defer r.deinit(gpa);
    const p = &r.ok;
    try testing.expectEqual(@as(usize, 2), p.bar.maqam_names.len);
    try testing.expectEqual(@as(usize, 2), p.bar.ratio_strs.len);
    try testing.expect(p.bar.jins_boundaries.len >= 1);
    try testing.expect(p.bar.frequencies.len > 4);
    for (p.bar.frequencies) |f| try testing.expect(f <= p.bar.root_hz * 2.0 * 1.001);
    var c = try p.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqualSlices(f64, p.bar.frequencies, c.bar.frequencies);
    try testing.expectEqualStrings(p.bar.ratio_strs[1], c.bar.ratio_strs[1]);
}

test "build phrase: create Zz 1/1 then d zz 4 is rejected, not a crash" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    var created = try command.parse(gpa, "create Zz 1/1");
    defer created.deinit(gpa);
    const cj = created.ok.create_jins;
    try testing.expect((try Maqam.create(cj.name, cj.ratios)) == .ok);
    var r = try buildFromSource(gpa, 0, "d zz 4");
    defer r.deinit(gpa);
    try testing.expectEqualStrings(
        "a phrase needs at least 3 notes in its scale, but this one has 1; give the jins more ratios (create Zz 1/1 9/8 5/4) or stack another jins after a comma",
        r.err,
    );
    // Two notes panic upstream too (clamp(2, 1)); three are fine.
    try testing.expect((try Maqam.create("Zz", &.{ .{ .p = 1, .q = 1 }, .{ .p = 9, .q = 8 } })) == .ok);
    var r2 = try buildFromSource(gpa, 0, "d zz 4");
    defer r2.deinit(gpa);
    try testing.expect(r2 == .err);
    try testing.expect((try Maqam.create("Zz", &.{ .{ .p = 1, .q = 1 }, .{ .p = 9, .q = 8 }, .{ .p = 5, .q = 4 } })) == .ok);
    var r3 = try buildFromSource(gpa, 0, "d zz 4");
    defer r3.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), r3.ok.bar.frequencies.len);
    // The stacked case where the first jins's only note is dropped next to the second root.
    try testing.expect((try Maqam.create("Zz", &.{.{ .p = 1, .q = 1 }})) == .ok);
    var r4 = try buildFromSource(gpa, 0, "d zz, d zz 4");
    defer r4.deinit(gpa);
    try testing.expect(r4 == .err);
    var r5 = try buildPhrase(gpa, 0, "", &.{}, 4, 1);
    defer r5.deinit(gpa);
    try testing.expect(r5 == .err);
}

test "build phrase: repeats are bounded by r20" {
    const gpa = testing.allocator;
    var ok20 = try buildFromSource(gpa, 0, "d bayati 4 r20");
    defer ok20.deinit(gpa);
    try testing.expectEqual(@as(usize, 20), ok20.ok.repeat);
    var big = try buildFromSource(gpa, 0, "d bayati 4 r21");
    defer big.deinit(gpa);
    try testing.expectEqualStrings("repeat 21 is too many; a phrase repeats at most r20 (use a jump for longer loops)", big.err);
}

test "jump entries" {
    const gpa = testing.allocator;
    var a = try buildJumpEntry(gpa, 5, 2, null, 0);
    defer a.deinit(gpa);
    try testing.expectEqualStrings("j 2 always", a.ok.src);
    var b = try buildJumpEntry(gpa, 5, 2, 7, 3);
    defer b.deinit(gpa);
    try testing.expectEqualStrings("j 2 else 7 3", b.ok.src);
    try testing.expectEqual(@as(?usize, 7), b.ok.jump.?.fail_target_id);
    var c = try buildJumpEntry(gpa, 5, 2, null, 10_000);
    defer c.deinit(gpa);
    try testing.expectEqualStrings("j 2 10000", c.ok.src);
    var d = try buildJumpEntry(gpa, 5, 2, null, 10_001);
    defer d.deinit(gpa);
    try testing.expectEqualStrings("jump times 10001 is too many; use 1..10000, or always", d.err);
    var e = try buildControlEntry(gpa, 1, "bpm 90", .{ .set_bpm = 90 });
    defer e.deinit(gpa);
    try testing.expectEqualStrings("bpm 90", e.src);
    try testing.expectEqual(@as(usize, 0), e.bar.events.len);
}

test "display source preserves the user's text and shows hidden repeats" {
    // app.rs phrase_display_source_preserves_the_users_text: the source is kept as typed.
    const gpa = testing.allocator;
    var r = try buildFromSource(gpa, 0, "d nah 332,   a hij 44 r3");
    defer r.deinit(gpa);
    try testing.expectEqualStrings("d nah 332,   a hij 44 r3", r.ok.src);
    try testing.expectEqual(@as(usize, 3), r.ok.repeat);
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "d nah 332,   a hij 44 r3", 3, "d nah 332,   a hij 44 r3" },
        .{ "d bayati 4", 2, "d bayati 4 r2" },
        .{ "d bayati 4  ", 4, "d bayati 4 r4" },
        .{ "d bayati 4 r", 5, "d bayati 4 r5" },
        .{ "d bayati 4 R12", 12, "d bayati 4 R12" },
        .{ "d bayati 4", 1, "d bayati 4" },
    };
    for (cases) |cs| {
        var p = r.ok;
        p.src = cs[0];
        p.repeat = cs[1];
        const shown = try p.displaySrc(gpa);
        defer gpa.free(shown);
        try testing.expectEqualStrings(cs[2], shown);
    }
}

test "events from freqs: kick first, snares after, a group of one is a snare" {
    const gpa = testing.allocator;
    const ev = try eventsFromFreqs(gpa, &.{ 0, 1, 2, 9 }, &.{ 100, 200, 300 }, &.{ 3, 1 });
    defer gpa.free(ev);
    try testing.expectEqual(@as(usize, 4), ev.len);
    try testing.expectEqual(SubdivEvent{ .kick = 100 }, ev[0]);
    try testing.expectEqual(SubdivEvent{ .snare = 200 }, ev[1]);
    try testing.expectEqual(SubdivEvent{ .snare = 300 }, ev[2]);
    try testing.expectEqual(SubdivEvent{ .snare = 300 }, ev[3]); // degree clamped to the scale
    const none = try eventsFromFreqs(gpa, &.{0}, &.{}, &.{4});
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    const short = try eventsFromFreqs(gpa, &.{}, &.{ 100, 200 }, &.{2});
    defer gpa.free(short);
    try testing.expectEqual(SubdivEvent{ .kick = 100 }, short[0]);
}

test "melody walk" {
    const gpa = testing.allocator;
    const a = try melodyWalk(gpa, 0, 3);
    defer gpa.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try melodyWalk(gpa, 1, 3);
    defer gpa.free(b);
    try testing.expectEqualSlices(usize, &.{0}, b);
    const c = try melodyWalk(gpa, 5, 4);
    defer gpa.free(c);
    try testing.expectEqualSlices(usize, &.{ 0, 2, 4, 2, 0 }, c);
}

test "recompute events in place and after a rhythm change" {
    const gpa = testing.allocator;
    var r = try buildFromSource(gpa, 0, "d rast 44");
    defer r.deinit(gpa);
    var bar = &r.ok.bar;
    const before = bar.events.len;
    bar.group_degrees[1] = 1;
    bar.recomputeEvents();
    try testing.expectEqual(before, bar.events.len);
    // the app's audition rewrites groups: the allocating variant resizes
    gpa.free(bar.groups);
    bar.groups = try gpa.dupe(u8, &.{ 1, 1, 1 });
    gpa.free(bar.group_degrees);
    bar.group_degrees = try gpa.dupe(usize, &.{ 0, 1, 2, 0 });
    try bar.recomputeEventsAlloc(gpa);
    try testing.expectEqual(@as(usize, 3), bar.events.len);
    try testing.expectEqual(@as(usize, 3), bar.degrees.len);
}

test "audio commands are small and free what they own" {
    const gpa = testing.allocator;
    try testing.expect(@sizeOf(AudioCmd) <= 512); // the bank and fx settings are the largest payloads
    const r = try buildFromSource(gpa, 0, "d hijaz 332");
    const boxed = try Phrase.create(gpa, r.ok);
    const cmd: AudioCmd = .{ .add_phrase = boxed };
    var ring: channel.Ring(AudioCmd, 4) = .{};
    try testing.expect(ring.trySend(cmd));
    try testing.expect(ring.trySend(.{ .set_bpm = 90 }));
    const got = ring.tryRecv().?;
    // The audio side would keep it and later return it as garbage.
    const garbage: Garbage = .{ .phrase = got.add_phrase };
    garbage.deinit(gpa);
    try testing.expectEqual(@as(f64, 90), ring.tryRecv().?.set_bpm);
    var mailbox: channel.Mailbox(LatencyResult) = .{};
    const m: AudioCmd = .{ .measure_input_latency = .{ .input = .left, .result = &mailbox } };
    try testing.expect(m.measure_input_latency.result.put(.{ .err = "audio device timestamps use incompatible clocks" }));
    m.deinit(gpa); // owns nothing
    const r2 = try buildJumpEntry(gpa, 1, 0, null, 2);
    const undelivered: AudioCmd = .{ .insert_phrase = .{ .pos = 0, .phrase = try Phrase.create(gpa, r2.ok) } };
    undelivered.deinit(gpa);
    const no_model: AudioCmd = .{ .set_nam_model = null };
    no_model.deinit(gpa);
}

test "rust str helpers" {
    try testing.expectEqualStrings("a b", rust_str.trim(" \u{3000}a b\t\u{00A0}"));
    try testing.expectEqualStrings(" a", rust_str.trimEnd(" a  "));
    try testing.expectEqualStrings("", rust_str.trimEnd("   "));
    try testing.expectEqualStrings("c", rust_str.lastWord("a  b\u{2003}c ").?);
    try testing.expectEqual(@as(?[]const u8, null), rust_str.firstWord(" \n"));
}
