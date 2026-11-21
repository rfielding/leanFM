//! Port of maqam-live `src/tuning.rs`: just intonation tuning for oud-based maqam (the D-based oud
//! lattice, the tuning base that `tuneto` rebases, the live jins registry with built-in and custom
//! jins, and pitch parsing).
//!
//! Shared state: the Rust `OnceLock<RwLock<..>>` statics (tuning base, jins registry) are
//! module-level state guarded by `util.SpinLock`. The registry is process-global like the Rust one,
//! so it owns its memory through a module allocator (`std.heap.smp_allocator`); functions that hand
//! data to the caller take `gpa` and the caller owns what they return.
//!
//! `Maqam` holds an interned name: names of jins ever registered are kept for the life of the
//! process (built-ins are literals; a custom name is copied once), so a `Maqam` is a plain value that
//! stays valid after `Maqam.delete` or `Maqam.resetToDefaults`, as the Rust `Maqam(String)` clone does.
//!
//! Deliberate differences from the Rust:
//! * `snapToOudLattice` returns the tuning base for a frequency that is not finite and positive
//!   (the Rust loops forever on 0, a negative value or infinity).
//! * `Maqam.parse` resolves ties deterministically (same-length prefix matches, or names equal
//!   ignoring case, pick the alphabetically first name); the Rust picks by HashMap order.
const std = @import("std");
const util = @import("util.zig");

pub const D_HZ: f64 = 293.6648;

/// A just ratio p/q (the Rust `(u32, u32)`).
pub const Ratio = struct {
    p: u32,
    q: u32,

    pub fn eql(a: Ratio, b: Ratio) bool {
        return a.p == b.p and a.q == b.q;
    }
};

fn r(p: u32, q: u32) Ratio {
    return .{ .p = p, .q = q };
}

fn clampByte(x: f64) u8 {
    const v = std.math.clamp(@round(x), 0.0, 255.0);
    return @intFromFloat(v);
}

// ── Pitch table ───────────────────────────────────────────────────────────────

const PitchEntry = struct { name: []const u8, p: u32, q: u32 };

const PITCH_TABLE = [_]PitchEntry{
    .{ .name = "d", .p = 1, .q = 1 },
    .{ .name = "d+", .p = 256, .q = 243 },
    .{ .name = "e-", .p = 256, .q = 243 },
    .{ .name = "e¾", .p = 12, .q = 11 },
    .{ .name = "e", .p = 9, .q = 8 },
    .{ .name = "f", .p = 32, .q = 27 },
    .{ .name = "f+", .p = 81, .q = 64 },
    .{ .name = "g-", .p = 81, .q = 64 },
    .{ .name = "g", .p = 4, .q = 3 },
    .{ .name = "g+", .p = 1024, .q = 729 },
    .{ .name = "a-", .p = 1024, .q = 729 },
    .{ .name = "a", .p = 3, .q = 2 },
    .{ .name = "a+", .p = 128, .q = 81 },
    .{ .name = "b-", .p = 128, .q = 81 },
    .{ .name = "b", .p = 27, .q = 16 },
    .{ .name = "c-", .p = 27, .q = 16 },
    .{ .name = "c", .p = 16, .q = 9 },
    .{ .name = "c+", .p = 1, .q = 1 },
};

fn pitchRatio(letter: u8, accidental: i8) Ratio {
    var key_buf: [2]u8 = .{ letter, 0 };
    const key: []const u8 = switch (accidental) {
        1 => blk: {
            key_buf[1] = '+';
            break :blk key_buf[0..2];
        },
        -1 => blk: {
            key_buf[1] = '-';
            break :blk key_buf[0..2];
        },
        else => key_buf[0..1],
    };
    for (PITCH_TABLE) |e| {
        if (std.mem.eql(u8, e.name, key)) return r(e.p, e.q);
    }
    for (PITCH_TABLE) |e| {
        if (e.name.len == 1 and e.name[0] == letter) return r(e.p, e.q);
    }
    return r(1, 1);
}

// ── Tuning base ───────────────────────────────────────────────────────────────

var base_lock: util.SpinLock = .{};
var tuning_base: f64 = D_HZ;

fn tuningBaseHz() f64 {
    base_lock.lock();
    defer base_lock.unlock();
    return tuning_base;
}

fn setTuningBase(v: f64) void {
    base_lock.lock();
    defer base_lock.unlock();
    tuning_base = v;
}

pub fn resetTuningBase() void {
    setTuningBase(D_HZ);
}

pub fn tuneToStandardPitch(pitch: Pitch) void {
    const pq = pitchRatio(pitch.letter, pitch.accidental);
    const ratio = @as(f64, @floatFromInt(pq.p)) / @as(f64, @floatFromInt(pq.q));
    const octave = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(@as(i32, pitch.octave) - 4)));
    setTuningBase(pitch.standardMidiHz() / (ratio * octave));
}

pub fn pitchToHz(letter: u8, accidental: i8, octave: u8) f64 {
    const pq = pitchRatio(letter, accidental);
    const oct = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(@as(i32, octave) - 4)));
    return tuningBaseHz() * @as(f64, @floatFromInt(pq.p)) / @as(f64, @floatFromInt(pq.q)) * oct;
}

pub fn snapToOudLattice(nominal_hz: f64) f64 {
    const base_hz = tuningBaseHz();
    // Deliberate: the Rust never terminates for 0, negative or infinite input.
    if (!(nominal_hz > 0.0) or !std.math.isFinite(nominal_hz)) return base_hz;
    var hz = nominal_hz;
    while (hz < base_hz) hz *= 2.0;
    while (hz >= base_hz * 2.0) hz /= 2.0;
    const ratio = hz / base_hz;
    var best_hz = hz;
    var best_dist = std.math.floatMax(f64);
    for (PITCH_TABLE) |e| {
        const rr = @as(f64, @floatFromInt(e.p)) / @as(f64, @floatFromInt(e.q));
        const dist = @abs(@log2(rr / ratio));
        if (dist < best_dist) {
            best_dist = dist;
            best_hz = base_hz * rr;
        }
    }
    return best_hz;
}

// ── Jins registry ─────────────────────────────────────────────────────────────

const Default = struct { name: []const u8, ratios: []const Ratio };

const DEFAULTS = [_]Default{
    .{ .name = "Nahawand", .ratios = &.{ r(1, 1), r(9, 8), r(32, 27), r(4, 3), r(3, 2) } },
    .{ .name = "Bayati", .ratios = &.{ r(1, 1), r(12, 11), r(32, 27), r(4, 3), r(3, 2) } },
    .{ .name = "Hijaz", .ratios = &.{ r(1, 1), r(256, 243), r(81, 64), r(4, 3), r(3, 2) } },
    .{ .name = "Rast", .ratios = &.{ r(1, 1), r(9, 8), r(27, 22), r(4, 3), r(3, 2) } },
    .{ .name = "Kurd", .ratios = &.{ r(1, 1), r(256, 243), r(32, 27), r(4, 3), r(3, 2) } },
    .{ .name = "Saba", .ratios = &.{ r(1, 1), r(13, 12), r(32, 27), r(5, 4) } },
    .{ .name = "Zaba", .ratios = &.{ r(1, 1), r(12, 11), r(32, 27), r(11, 8) } },
    .{ .name = "Zamzam", .ratios = &.{ r(1, 1), r(16, 15), r(32, 27), r(6, 5) } },
    .{ .name = "Ajam", .ratios = &.{ r(1, 1), r(9, 8), r(5, 4), r(4, 3), r(3, 2) } },
    .{ .name = "Nikriz", .ratios = &.{ r(1, 1), r(256, 243), r(81, 64), r(4, 3), r(3, 2) } },
    .{ .name = "Suznak", .ratios = &.{ r(1, 1), r(9, 8), r(27, 22), r(4, 3), r(3, 2) } },
    .{ .name = "Jiharkah", .ratios = &.{ r(1, 1), r(9, 8), r(5, 4), r(4, 3), r(3, 2) } },
    .{ .name = "Major", .ratios = &.{ r(1, 1), r(9, 8), r(5, 4), r(4, 3), r(3, 2), r(5, 3), r(15, 8) } },
    .{ .name = "Ionian", .ratios = &.{ r(1, 1), r(9, 8), r(81, 64), r(4, 3), r(3, 2), r(27, 16), r(243, 128) } },
    .{ .name = "Dorian", .ratios = &.{ r(1, 1), r(9, 8), r(32, 27), r(4, 3), r(3, 2), r(27, 16), r(16, 9) } },
    .{ .name = "Phrygian", .ratios = &.{ r(1, 1), r(256, 243), r(32, 27), r(4, 3), r(3, 2), r(128, 81), r(16, 9) } },
    .{ .name = "Lydian", .ratios = &.{ r(1, 1), r(9, 8), r(81, 64), r(729, 512), r(3, 2), r(27, 16), r(243, 128) } },
    .{ .name = "Mixolydian", .ratios = &.{ r(1, 1), r(9, 8), r(81, 64), r(4, 3), r(3, 2), r(27, 16), r(16, 9) } },
    .{ .name = "Minor", .ratios = &.{ r(1, 1), r(9, 8), r(32, 27), r(4, 3), r(3, 2), r(27, 16), r(16, 9) } },
    .{ .name = "Aeolian", .ratios = &.{ r(1, 1), r(9, 8), r(32, 27), r(4, 3), r(3, 2), r(128, 81), r(16, 9) } },
    .{ .name = "Locrian", .ratios = &.{ r(1, 1), r(256, 243), r(32, 27), r(4, 3), r(1024, 729), r(128, 81), r(16, 9) } },
    .{ .name = "Diminished", .ratios = &.{ r(1, 1), r(9, 8), r(6, 5), r(4, 3), r(64, 45), r(8, 5), r(5, 3), r(15, 8) } },
};

/// Built-in ratios of a jins (the Rust `default_registry_map().get(name)`).
fn defaultRatios(name: []const u8) ?[]const Ratio {
    for (DEFAULTS) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.ratios;
    }
    return null;
}

fn ratiosEql(a: []const Ratio, b: []const Ratio) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

const Entry = struct {
    name: []const u8, // interned
    ratios: []const Ratio,
    owned: bool, // ratios allocated by registry_alloc
};

const registry_alloc = std.heap.smp_allocator;
var registry_lock: util.SpinLock = .{};
var registry_ready: bool = false;
var registry: std.ArrayList(Entry) = .empty;
var interned: std.ArrayList([]const u8) = .empty; // custom names copied once, never freed

/// Caller holds registry_lock.
fn ensureRegistry() void {
    if (registry_ready) return;
    registry.ensureTotalCapacity(registry_alloc, DEFAULTS.len) catch {
        // Out of memory: the registry stays empty and is retried on the next call.
        return;
    };
    for (DEFAULTS) |d| registry.appendAssumeCapacity(.{ .name = d.name, .ratios = d.ratios, .owned = false });
    registry_ready = true;
}

/// Caller holds registry_lock.
fn findEntry(name: []const u8) ?usize {
    for (registry.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// Returns an interned copy of `name` that lives for the process. Caller holds registry_lock.
fn internLocked(name: []const u8) error{OutOfMemory}![]const u8 {
    for (DEFAULTS) |d| if (std.mem.eql(u8, d.name, name)) return d.name;
    for (interned.items) |n| if (std.mem.eql(u8, n, name)) return n;
    const copy = try registry_alloc.dupe(u8, name);
    errdefer registry_alloc.free(copy);
    try interned.append(registry_alloc, copy);
    return copy;
}

/// A registered jins as returned by `Maqam.listAll` / `Maqam.listCustom`: `name` is interned (not
/// owned), `ratios` is owned by the caller (free with `freeList`).
pub const JinsEntry = struct {
    name: []const u8,
    ratios: []Ratio,
};

pub fn freeList(gpa: std.mem.Allocator, list: []JinsEntry) void {
    for (list) |e| gpa.free(e.ratios);
    gpa.free(list);
}

fn entryLess(_: void, a: JinsEntry, b: JinsEntry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub const ValidateResult = union(enum) { ok: void, err: []const u8 };

// ── Maqam ─────────────────────────────────────────────────────────────────────

pub const Maqam = struct {
    /// Interned jins name; valid for the life of the process.
    name_: []const u8,

    /// The Rust `Maqam::new`: interns `name`.
    pub fn new(name_in: []const u8) error{OutOfMemory}!Maqam {
        registry_lock.lock();
        defer registry_lock.unlock();
        return .{ .name_ = try internLocked(name_in) };
    }

    pub fn eql(a: Maqam, b: Maqam) bool {
        return std.mem.eql(u8, a.name_, b.name_);
    }

    /// Case-insensitive prefix match against registry names.
    pub fn parse(s: []const u8) ?Maqam {
        if (s.len < 2) return null;
        registry_lock.lock();
        defer registry_lock.unlock();
        ensureRegistry();
        // Exact match first (ties: alphabetically first).
        var exact: ?[]const u8 = null;
        for (registry.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, s)) {
                if (exact == null or std.mem.order(u8, e.name, exact.?) == .lt) exact = e.name;
            }
        }
        if (exact) |n| return .{ .name_ = n };
        // Prefix match: pick shortest (ties: alphabetically first).
        var best: ?[]const u8 = null;
        for (registry.items) |e| {
            if (e.name.len >= s.len and std.ascii.eqlIgnoreCase(e.name[0..s.len], s)) {
                if (best == null or e.name.len < best.?.len or
                    (e.name.len == best.?.len and std.mem.order(u8, e.name, best.?) == .lt))
                    best = e.name;
            }
        }
        if (best) |n| return .{ .name_ = n };
        return null;
    }

    pub fn name(self: Maqam) []const u8 {
        return self.name_;
    }

    /// Messages are static (not owned).
    pub fn validateRatios(rs: []const Ratio) ValidateResult {
        if (rs.len == 0) return .{ .err = "need at least one ratio" };
        var has_unison = false;
        for (rs) |x| {
            if (x.p == x.q) has_unison = true;
        }
        if (!has_unison) return .{ .err = "scale must include 1/1" };
        var prev: ?f64 = null;
        for (rs) |x| {
            if (x.q == 0) return .{ .err = "ratio denominator cannot be zero" };
            const cur = @as(f64, @floatFromInt(x.p)) / @as(f64, @floatFromInt(x.q));
            if (prev) |last| {
                if (cur <= last) return .{ .err = "scale ratios must be strictly ascending" };
            }
            prev = cur;
        }
        return .ok;
    }

    /// Ratios from the live registry (reflects runtime create/delete). Caller owns the slice.
    pub fn ratios(self: Maqam, gpa: std.mem.Allocator) error{OutOfMemory}![]Ratio {
        registry_lock.lock();
        defer registry_lock.unlock();
        ensureRegistry();
        if (findEntry(self.name_)) |i| return gpa.dupe(Ratio, registry.items[i].ratios);
        return gpa.alloc(Ratio, 0);
    }

    /// Sorted list of all registered jins.
    pub fn listAll(gpa: std.mem.Allocator) error{OutOfMemory}![]JinsEntry {
        return list(gpa, false);
    }

    /// Sorted list of jins that differ from the built-in defaults.
    pub fn listCustom(gpa: std.mem.Allocator) error{OutOfMemory}![]JinsEntry {
        return list(gpa, true);
    }

    fn list(gpa: std.mem.Allocator, custom_only: bool) error{OutOfMemory}![]JinsEntry {
        var out: std.ArrayList(JinsEntry) = .empty;
        errdefer {
            for (out.items) |e| gpa.free(e.ratios);
            out.deinit(gpa);
        }
        {
            registry_lock.lock();
            defer registry_lock.unlock();
            ensureRegistry();
            for (registry.items) |e| {
                if (custom_only) {
                    if (defaultRatios(e.name)) |d| {
                        if (ratiosEql(d, e.ratios)) continue;
                    }
                }
                const copy = try gpa.dupe(Ratio, e.ratios);
                out.append(gpa, .{ .name = e.name, .ratios = copy }) catch |err| {
                    gpa.free(copy);
                    return err;
                };
            }
        }
        std.mem.sort(JinsEntry, out.items, {}, entryLess);
        return out.toOwnedSlice(gpa);
    }

    pub fn colorForRatios(rs: []const Ratio) [3]u8 {
        var h: u32 = 2166136261;
        var buf: [32]u8 = undefined;
        for (rs, 0..) |x, i| {
            if (i > 0) h = fnvStep(h, '|');
            const s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ x.p, x.q }) catch unreachable;
            for (s) |b| h = fnvStep(h, b);
        }
        return colorForHash(h);
    }

    pub fn colorForRatioStrs(rs: []const []const u8) [3]u8 {
        var h: u32 = 2166136261;
        for (rs, 0..) |s, i| {
            if (i > 0) h = fnvStep(h, '|');
            for (s) |b| h = fnvStep(h, b);
        }
        return colorForHash(h);
    }

    /// Create or overwrite a jins entry. The ratios are copied. Messages are static.
    pub fn create(name_in: []const u8, rs: []const Ratio) error{OutOfMemory}!ValidateResult {
        switch (validateRatios(rs)) {
            .ok => {},
            .err => |m| return .{ .err = m },
        }
        const copy = try registry_alloc.dupe(Ratio, rs);
        var old: ?[]const Ratio = null;
        {
            registry_lock.lock();
            defer registry_lock.unlock();
            ensureRegistry();
            if (!registry_ready) {
                registry_alloc.free(copy);
                return error.OutOfMemory;
            }
            if (findEntry(name_in)) |i| {
                const e = &registry.items[i];
                if (e.owned) old = e.ratios;
                e.ratios = copy;
                e.owned = true;
            } else {
                const n = internLocked(name_in) catch |err| {
                    registry_alloc.free(copy);
                    return err;
                };
                registry.append(registry_alloc, .{ .name = n, .ratios = copy, .owned = true }) catch |err| {
                    registry_alloc.free(copy);
                    return err;
                };
            }
        }
        if (old) |o| registry_alloc.free(o);
        return .ok;
    }

    /// Delete a jins entry. Returns false if it didn't exist.
    pub fn delete(name_in: []const u8) bool {
        var old: ?[]const Ratio = null;
        {
            registry_lock.lock();
            defer registry_lock.unlock();
            ensureRegistry();
            const i = findEntry(name_in) orelse return false;
            const e = registry.orderedRemove(i);
            if (e.owned) old = e.ratios;
        }
        if (old) |o| registry_alloc.free(o);
        return true;
    }

    /// Replace the live registry with built-in defaults.
    pub fn resetToDefaults() void {
        registry_lock.lock();
        defer registry_lock.unlock();
        ensureRegistry();
        for (registry.items) |e| {
            if (e.owned) registry_alloc.free(e.ratios);
        }
        registry.clearRetainingCapacity();
        registry_ready = false;
        ensureRegistry();
    }

    pub fn degreeHz(self: Maqam, root_hz: f64, degree: usize) f64 {
        registry_lock.lock();
        defer registry_lock.unlock();
        ensureRegistry();
        const i = findEntry(self.name_) orelse return root_hz;
        const rs = registry.items[i].ratios;
        if (rs.len == 0) return root_hz;
        const x = rs[@min(degree, rs.len - 1)];
        return root_hz * @as(f64, @floatFromInt(x.p)) / @as(f64, @floatFromInt(x.q));
    }
};

fn fnvStep(h: u32, b: u8) u32 {
    return (h *% 16777619) ^ @as(u32, b);
}

const PALETTE = [8][3]u8{
    .{ 188, 72, 84 },
    .{ 58, 136, 92 },
    .{ 72, 116, 184 },
    .{ 188, 136, 52 },
    .{ 120, 86, 188 },
    .{ 48, 154, 154 },
    .{ 196, 92, 44 },
    .{ 150, 124, 60 },
};

fn colorForHash(h: u32) [3]u8 {
    const base = PALETTE[h % PALETTE.len];
    const bump = @as(f64, @floatFromInt((h >> 8) % 23)) - 11.0;
    return .{
        clampByte(@as(f64, @floatFromInt(base[0])) + bump),
        clampByte(@as(f64, @floatFromInt(base[1])) - bump * 0.4),
        clampByte(@as(f64, @floatFromInt(base[2])) + bump * 0.2),
    };
}

// ── Pitch ─────────────────────────────────────────────────────────────────────

pub const Pitch = struct {
    letter: u8,
    accidental: i8,
    octave: u8,

    pub fn parse(s: []const u8) ?Pitch {
        if (s.len == 0) return null;
        const letter = std.ascii.toLower(s[0]);
        if (std.mem.indexOfScalar(u8, "cdefgab", letter) == null) return null;
        var i: usize = 1;
        var accidental: i8 = 0;
        if (i < s.len) {
            switch (s[i]) {
                '+', '#' => {
                    accidental = 1;
                    i += 1;
                },
                '-' => {
                    accidental = -1;
                    i += 1;
                },
                else => {},
            }
        }
        var octave: u8 = 4;
        if (i < s.len) {
            const d = s[i];
            if (!std.ascii.isDigit(d)) return null;
            octave = d - '0';
        }
        return .{ .letter = letter, .accidental = accidental, .octave = octave };
    }

    pub fn eql(a: Pitch, b: Pitch) bool {
        return a.letter == b.letter and a.accidental == b.accidental and a.octave == b.octave;
    }

    pub fn toHz(self: Pitch) f64 {
        return pitchToHz(self.letter, self.accidental, self.octave);
    }

    pub fn standardMidiHz(self: Pitch) f64 {
        const pc: i32 = switch (std.ascii.toLower(self.letter)) {
            'c' => 0,
            'd' => 2,
            'e' => 4,
            'f' => 5,
            'g' => 7,
            'a' => 9,
            'b' => 11,
            else => 0,
        };
        const pitch_class = pc + @as(i32, self.accidental);
        const midi = (@as(i32, self.octave) + 1) * 12 + pitch_class;
        return 440.0 * std.math.pow(f64, 2.0, (@as(f64, @floatFromInt(midi)) - 69.0) / 12.0);
    }

    /// Writes the session token (e.g. "b-", "d5") into `buf` and returns it.
    pub fn sourceTokenBuf(self: Pitch, buf: *[3]u8) []const u8 {
        var n: usize = 0;
        buf[n] = std.ascii.toLower(self.letter);
        n += 1;
        switch (self.accidental) {
            1 => {
                buf[n] = '+';
                n += 1;
            },
            -1 => {
                buf[n] = '-';
                n += 1;
            },
            else => {},
        }
        if (self.octave != 4) {
            buf[n] = '0' +% self.octave;
            n += 1;
        }
        return buf[0..n];
    }

    /// Caller owns the returned slice.
    pub fn sourceToken(self: Pitch, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: [3]u8 = undefined;
        return gpa.dupe(u8, self.sourceTokenBuf(&buf));
    }

    /// Caller owns the returned slice.
    pub fn display(self: Pitch, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: [2]u8 = undefined;
        var n: usize = 0;
        buf[n] = std.ascii.toUpper(self.letter);
        n += 1;
        switch (self.accidental) {
            1 => {
                buf[n] = '+';
                n += 1;
            },
            -1 => {
                buf[n] = '-';
                n += 1;
            },
            else => {},
        }
        return gpa.dupe(u8, buf[0..n]);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "zamzam_is_a_builtin_jins" {
    try testing.expect(ratiosEql(defaultRatios("Zamzam").?, &.{ r(1, 1), r(16, 15), r(32, 27), r(6, 5) }));
}

test "western_modes_are_builtin_jins" {
    try testing.expect(ratiosEql(defaultRatios("Major").?, &.{ r(1, 1), r(9, 8), r(5, 4), r(4, 3), r(3, 2), r(5, 3), r(15, 8) }));
    try testing.expect(ratiosEql(defaultRatios("Minor").?, &.{ r(1, 1), r(9, 8), r(32, 27), r(4, 3), r(3, 2), r(27, 16), r(16, 9) }));
    try testing.expect(ratiosEql(defaultRatios("Locrian").?, &.{ r(1, 1), r(256, 243), r(32, 27), r(4, 3), r(1024, 729), r(128, 81), r(16, 9) }));
    // The church modes are Pythagorean (upstream a2cdac8).
    try testing.expect(std.meta.eql(defaultRatios("Ionian").?[2], r(81, 64)));
    try testing.expect(std.meta.eql(defaultRatios("Dorian").?[2], r(32, 27)));
    try testing.expect(std.meta.eql(defaultRatios("Phrygian").?[1], r(256, 243)));
    try testing.expect(std.meta.eql(defaultRatios("Lydian").?[3], r(729, 512)));
    try testing.expect(std.meta.eql(defaultRatios("Mixolydian").?[6], r(16, 9)));
    try testing.expect(std.meta.eql(defaultRatios("Aeolian").?[5], r(128, 81)));
    try testing.expect(ratiosEql(defaultRatios("Diminished").?, &.{ r(1, 1), r(9, 8), r(6, 5), r(4, 3), r(64, 45), r(8, 5), r(5, 3), r(15, 8) }));
}

test "tuneto_anchors_lattice_pitch_to_standard_midi_pitch" {
    resetTuningBase();
    try testing.expect(@abs(pitchToHz('d', 0, 4) - 293.6648) < 0.0001);
    tuneToStandardPitch(Pitch.parse("a").?);
    try testing.expect(@abs(pitchToHz('a', 0, 4) - 440.0) < 0.0001);
    tuneToStandardPitch(Pitch.parse("c").?);
    try testing.expect(@abs(pitchToHz('c', 0, 4) - 261.625_565) < 0.0001);
    resetTuningBase();
}

test "pitch parsing" {
    try testing.expect(Pitch.parse("B-").?.eql(.{ .letter = 'b', .accidental = -1, .octave = 4 }));
    try testing.expect(Pitch.parse("c#5").?.eql(.{ .letter = 'c', .accidental = 1, .octave = 5 }));
    try testing.expect(Pitch.parse("d3xyz").?.eql(.{ .letter = 'd', .accidental = 0, .octave = 3 }));
    try testing.expect(Pitch.parse("") == null);
    try testing.expect(Pitch.parse("h") == null);
    try testing.expect(Pitch.parse("dx") == null);
    try testing.expect(Pitch.parse("d+x") == null);
    var buf: [3]u8 = undefined;
    try testing.expectEqualStrings("b-", Pitch.parse("b-").?.sourceTokenBuf(&buf));
    try testing.expectEqualStrings("e5", Pitch.parse("E5").?.sourceTokenBuf(&buf));
}

test "maqam parse, create, delete, list" {
    Maqam.resetToDefaults();
    defer Maqam.resetToDefaults();
    try testing.expectEqualStrings("Bayati", Maqam.parse("bay").?.name());
    try testing.expectEqualStrings("Zaba", Maqam.parse("za").?.name());
    try testing.expectEqualStrings("Major", Maqam.parse("MAJOR").?.name());
    try testing.expect(Maqam.parse("b") == null);
    try testing.expect(Maqam.parse("zz") == null);

    try testing.expectEqualStrings("scale must include 1/1", (try Maqam.create("X", &.{r(9, 8)})).err);
    try testing.expectEqualStrings("need at least one ratio", (try Maqam.create("X", &.{})).err);
    try testing.expectEqualStrings("scale ratios must be strictly ascending", (try Maqam.create("X", &.{ r(1, 1), r(1, 1) })).err);
    try testing.expectEqualStrings("ratio denominator cannot be zero", (try Maqam.create("X", &.{ r(1, 1), r(3, 0) })).err);
    try testing.expect((try Maqam.create("Mine", &.{ r(1, 1), r(7, 6) })) == .ok);
    const m = Maqam.parse("min").?; // "Mine" (4) is shorter than "Minor" (5)
    try testing.expectEqualStrings("Mine", m.name());
    const rs = try m.ratios(testing.allocator);
    defer testing.allocator.free(rs);
    try testing.expect(ratiosEql(rs, &.{ r(1, 1), r(7, 6) }));

    const custom = try Maqam.listCustom(testing.allocator);
    defer freeList(testing.allocator, custom);
    try testing.expectEqual(@as(usize, 1), custom.len);
    try testing.expectEqualStrings("Mine", custom[0].name);

    const all = try Maqam.listAll(testing.allocator);
    defer freeList(testing.allocator, all);
    try testing.expectEqual(DEFAULTS.len + 1, all.len);
    try testing.expectEqualStrings("Aeolian", all[0].name);

    try testing.expect(Maqam.delete("Mine"));
    try testing.expect(!Maqam.delete("Mine"));
    try testing.expectEqualStrings("Mine", m.name()); // interned name still valid
    const gone = try m.ratios(testing.allocator);
    defer testing.allocator.free(gone);
    try testing.expectEqual(@as(usize, 0), gone.len);
    try testing.expectEqual(@as(f64, 100.0), m.degreeHz(100.0, 3));
    try testing.expectEqual(@as(f64, 150.0), Maqam.parse("hijaz").?.degreeHz(100.0, 4));
    try testing.expectEqual(@as(f64, 150.0), Maqam.parse("hijaz").?.degreeHz(100.0, 99));
}

test "snap to oud lattice" {
    resetTuningBase();
    try testing.expectApproxEqAbs(D_HZ * 1.5, snapToOudLattice(440.0), 1e-9);
    try testing.expectApproxEqAbs(D_HZ, snapToOudLattice(0.0), 1e-9);
    try testing.expectApproxEqAbs(D_HZ, snapToOudLattice(std.math.inf(f64)), 1e-9);
    try testing.expectApproxEqAbs(D_HZ, snapToOudLattice(-5.0), 1e-9);
}

test "color for ratios matches string form" {
    const a = Maqam.colorForRatios(&.{ r(1, 1), r(9, 8) });
    const b = Maqam.colorForRatioStrs(&.{ "1/1", "9/8" });
    try testing.expectEqual(a, b);
}
