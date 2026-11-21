//! Port of maqam-live `src/command.rs`: the command-language parser (the `Cmd` union, every change
//! type, value forms absolute / +n / -n / *k / /k / per-tick `nt`, the language reference and the
//! metadata used for completion, and `applyVcfChange` / `applyFxChange`).
//!
//! Ownership: `parse(gpa, line)` returns a `ParseResult`; everything in it (strings, spec lists, id
//! lists, ratio lists and the rejection message) is allocated with `gpa` and freed by
//! `ParseResult.deinit(gpa)` (or `Cmd.deinit(gpa)` once the `ok` payload has been taken). The
//! rejection messages of `applyVcfChange` / `applyFxChange` are owned by the caller too; the messages
//! of `ValueChange.apply` and `SympatheticHarmony.push` are static. `Maqam` values are interned (see
//! tuning.zig) and need no freeing. Text is handled with Rust `str` semantics: whitespace is Unicode
//! whitespace, numbers follow Rust's `parse` grammar (no `_`, no hex), case folding is ASCII.
//!
//! Deliberate differences from the Rust (each only to avoid a panic or crash):
//! * A value token whose first byte is not ASCII (e.g. `bpm é`) is rejected with the command's usage
//!   message; the Rust panics slicing inside a UTF-8 character (`split_at(1)`).
//! * `edit` / `insert` nested more than 64 levels deep is rejected with "unsupported command after
//!   edit" / "unsupported command after insert" (what any nesting yields) instead of recursing
//!   without bound; the Rust overflows its stack on a long enough line.
//!
//! Following the specification's ranges where the Rust disagrees with itself: the NAM gain range is
//! 0..100 (as the Rust parser and the specification say), so the `nam gain` help metadata reads
//! "range 0..100" and the non-number rejection reads "bad NAM gain '<v>'; type a number from 0 to 100"
//! (the Rust says 8 in both places).
const std = @import("std");
const Allocator = std.mem.Allocator;
const fx = @import("fx.zig");
const tuning = @import("tuning.zig");
const vcf = @import("vcf.zig");

const FxSettings = fx.FxSettings;
const Maqam = tuning.Maqam;
const Pitch = tuning.Pitch;
const Ratio = tuning.Ratio;
const VcfBank = vcf.VcfBank;
const VcfSettings = vcf.VcfSettings;
const VcfTarget = vcf.VcfTarget;
const VcoWave = vcf.VcoWave;

pub const START_REF: isize = std.math.minInt(isize);

const max_nesting: usize = 64;

// ── Rust str helpers ──────────────────────────────────────────────────────────

/// Byte length of the Unicode whitespace character (Rust `char::is_whitespace`) at `s[i]`, or 0.
fn wsLen(s: []const u8, i: usize) usize {
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

/// Byte length of the character at `s[i]` (1 for a byte that does not start valid UTF-8).
fn charLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len) return 1;
    return n;
}

fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const l = wsLen(s, i);
        if (l == 0) break;
        i += l;
    }
    return s[i..];
}

fn trimEnd(s: []const u8) []const u8 {
    var i: usize = 0;
    var end: usize = 0;
    while (i < s.len) {
        const l = wsLen(s, i);
        if (l > 0) {
            i += l;
        } else {
            i += charLen(s, i);
            end = i;
        }
    }
    return s[0..end];
}

fn trim(s: []const u8) []const u8 {
    return trimEnd(trimStart(s));
}

/// Rust `split_whitespace`.
const Tokens = struct {
    s: []const u8,
    i: usize = 0,

    fn init(s: []const u8) Tokens {
        return .{ .s = s };
    }

    fn next(self: *Tokens) ?[]const u8 {
        while (self.i < self.s.len) {
            const l = wsLen(self.s, self.i);
            if (l == 0) break;
            self.i += l;
        }
        if (self.i >= self.s.len) return null;
        const start = self.i;
        while (self.i < self.s.len and wsLen(self.s, self.i) == 0) self.i += charLen(self.s, self.i);
        return self.s[start..self.i];
    }
};

fn nthToken(s: []const u8, n: usize) ?[]const u8 {
    var it = Tokens.init(s);
    var k: usize = 0;
    while (it.next()) |t| : (k += 1) {
        if (k == n) return t;
    }
    return null;
}

fn countTokens(s: []const u8) usize {
    var it = Tokens.init(s);
    var k: usize = 0;
    while (it.next()) |_| k += 1;
    return k;
}

const Split = struct { a: []const u8, b: []const u8 };

/// Rust `split_once(char::is_whitespace)`.
fn splitOnceWs(s: []const u8) ?Split {
    var i: usize = 0;
    while (i < s.len) {
        const l = wsLen(s, i);
        if (l > 0) return .{ .a = s[0..i], .b = s[i + l ..] };
        i += charLen(s, i);
    }
    return null;
}

/// Rust `splitn(3, char::is_whitespace)`.
fn splitn3Ws(s: []const u8) [3]?[]const u8 {
    var out: [3]?[]const u8 = .{ null, null, null };
    const first = splitOnceWs(s) orelse {
        out[0] = s;
        return out;
    };
    out[0] = first.a;
    const second = splitOnceWs(first.b) orelse {
        out[1] = first.b;
        return out;
    };
    out[1] = second.a;
    out[2] = second.b;
    return out;
}

fn eqlAnyIgnoreCase(s: []const u8, comptime words: []const []const u8) bool {
    inline for (words) |w| {
        if (std.ascii.eqlIgnoreCase(s, w)) return true;
    }
    return false;
}

/// Rust `str::parse::<f32|f64>` grammar: [+-] (inf | infinity | nan | digits[.digits][e[+-]digits]).
fn parseFloatRust(comptime T: type, s: []const u8) ?T {
    var i: usize = 0;
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        i = 1;
    }
    const body = s[i..];
    if (std.ascii.eqlIgnoreCase(body, "inf") or std.ascii.eqlIgnoreCase(body, "infinity"))
        return if (neg) -std.math.inf(T) else std.math.inf(T);
    if (std.ascii.eqlIgnoreCase(body, "nan")) return std.math.nan(T);
    var j: usize = 0;
    var digits: usize = 0;
    while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) digits += 1;
    if (j < body.len and body[j] == '.') {
        j += 1;
        while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (j < body.len and (body[j] == 'e' or body[j] == 'E')) {
        j += 1;
        if (j < body.len and (body[j] == '+' or body[j] == '-')) j += 1;
        var exp_digits: usize = 0;
        while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) exp_digits += 1;
        if (exp_digits == 0) return null;
    }
    if (j != body.len) return null;
    const v = std.fmt.parseFloat(T, body) catch return null;
    return if (neg) -v else v;
}

/// Rust `str::parse::<integer>` grammar: [+] digits, or [+-] digits for a signed type.
fn parseIntRust(comptime T: type, s: []const u8) ?T {
    var i: usize = 0;
    if (s.len > 0 and (s[0] == '+' or (s[0] == '-' and @typeInfo(T).int.signedness == .signed))) i = 1;
    if (i == s.len) return null;
    for (s[i..]) |b| if (!std.ascii.isDigit(b)) return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// Formats a float as Rust `Display` does (shortest round-trip decimal, `NaN`, `inf`).
fn RustFloat(comptime T: type) type {
    return struct {
        v: T,
        pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (std.math.isNan(self.v)) return w.writeAll("NaN");
            if (std.math.isInf(self.v)) return w.writeAll(if (self.v > 0) "inf" else "-inf");
            return w.print("{d}", .{self.v});
        }
    };
}

fn rf(v: anytype) RustFloat(@TypeOf(v)) {
    return .{ .v = v };
}

fn inRange(comptime T: type, v: T, lo: T, hi: T) bool {
    return v >= lo and v <= hi;
}

// ── Rejection context ─────────────────────────────────────────────────────────

const Error = error{ Rejected, OutOfMemory };

const Ctx = struct {
    gpa: Allocator,
    msg: ?[]u8 = null,

    fn setMsg(c: *Ctx, m: []u8) void {
        if (c.msg) |old| c.gpa.free(old);
        c.msg = m;
    }

    fn rejectStatic(c: *Ctx, m: []const u8) Error {
        c.setMsg(c.gpa.dupe(u8, m) catch return error.OutOfMemory);
        return error.Rejected;
    }

    fn reject(c: *Ctx, comptime f: []const u8, args: anytype) Error {
        c.setMsg(std.fmt.allocPrint(c.gpa, f, args) catch return error.OutOfMemory);
        return error.Rejected;
    }

    /// Rejects with `name` ASCII-lowercased in the message.
    fn rejectLower(c: *Ctx, comptime f: []const u8, name: []const u8) Error {
        const low = c.gpa.alloc(u8, name.len) catch return error.OutOfMemory;
        defer c.gpa.free(low);
        _ = std.ascii.lowerString(low, name);
        return c.reject(f, .{low});
    }

    fn dupe(c: *Ctx, s: []const u8) Error![]u8 {
        return c.gpa.dupe(u8, s);
    }

    fn finish(c: *Ctx, comptime T: type, r: Error!T) Allocator.Error!Result(T) {
        const v = r catch |e| switch (e) {
            error.OutOfMemory => {
                if (c.msg) |m| c.gpa.free(m);
                c.msg = null;
                return error.OutOfMemory;
            },
            error.Rejected => return .{ .err = c.msg.? },
        };
        return .{ .ok = v };
    }
};

/// The Rust `Result<T, String>`; `err` is owned by the caller.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: []u8,
    };
}

// ── Types ─────────────────────────────────────────────────────────────────────

pub const JinsSpec = struct {
    src: []const u8,
    root: Pitch,
    maqam: Maqam,
    groups: ?[]const u8,

    pub fn deinit(self: JinsSpec, gpa: Allocator) void {
        gpa.free(self.src);
        if (self.groups) |g| gpa.free(g);
    }
};

pub fn freeSpecs(gpa: Allocator, specs: []const JinsSpec) void {
    for (specs) |s| s.deinit(gpa);
    gpa.free(specs);
}

pub const VcfChange = struct {
    enabled: ?bool = null,
    target: ?VcfTarget = null,
    cutoff_hz: ?ValueChange = null,
    resonance: ?ValueChange = null,
    drive: ?ValueChange = null,
    wave: ?VcoWave = null,
};

/// The largest `nam gain` (the Rust `NAM_GAIN_MAX`).
pub const nam_gain_max: f32 = 100.0;

pub const FxChange = struct {
    flanger_enabled: ?bool = null,
    flanger_rate_hz: ?ValueChange = null,
    flanger_depth: ?ValueChange = null,
    flanger_delay_ms: ?ValueChange = null,
    flanger_feedback: ?ValueChange = null,
    flanger_mix: ?ValueChange = null,
    chorus_enabled: ?bool = null,
    chorus_rate_hz: ?ValueChange = null,
    chorus_depth: ?ValueChange = null,
    chorus_delay_ms: ?ValueChange = null,
    chorus_mix: ?ValueChange = null,
    reverb_enabled: ?bool = null,
    reverb_mix: ?ValueChange = null,
    reverb_decay: ?ValueChange = null,
    delay_enabled: ?bool = null,
    delay_time_secs: ?ValueChange = null,
    delay_feedback: ?ValueChange = null,
    delay_mix: ?ValueChange = null,
    cabinet_enabled: ?bool = null,
    cabinet_model: ?fx.CabinetModel = null,
    cabinet_mix: ?ValueChange = null,
};

pub const SympatheticChange = struct {
    target: ?SympatheticTarget = null,
    enabled: ?bool = null,
    decay: ?f32 = null,
    gain: ?f32 = null,
    interval_ratio: ?f64 = null,
    harmony: ?SympatheticHarmony = null,
    amount: ?f32 = null,
    mic: ?f32 = null,
    kanun: ?f32 = null,
    bass: ?f32 = null,
    drums: ?f32 = null,
};

pub const NamCommand = union(enum) {
    login,
    logout,
    load: struct { path: []const u8 },
    import: struct { path: []const u8, name: ?[]const u8 },
    pin: struct { url: []const u8, name: []const u8 },
    tone3000: struct { tone_id: u64, name: []const u8 },
    search: struct { query: []const u8 },
    list,
    off,
    gain: f32,
    input: NamInput,
    latency: NamInput,

    pub fn deinit(self: NamCommand, gpa: Allocator) void {
        switch (self) {
            .load => |v| gpa.free(v.path),
            .import => |v| {
                gpa.free(v.path);
                if (v.name) |n| gpa.free(n);
            },
            .pin => |v| {
                gpa.free(v.url);
                gpa.free(v.name);
            },
            .tone3000 => |v| gpa.free(v.name),
            .search => |v| gpa.free(v.query),
            else => {},
        }
    }

    /// The Rust derived `PartialEq`.
    pub fn eql(a: NamCommand, b: NamCommand) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .load => |v| std.mem.eql(u8, v.path, b.load.path),
            .import => |v| std.mem.eql(u8, v.path, b.import.path) and optEql(v.name, b.import.name),
            .pin => |v| std.mem.eql(u8, v.url, b.pin.url) and std.mem.eql(u8, v.name, b.pin.name),
            .tone3000 => |v| v.tone_id == b.tone3000.tone_id and std.mem.eql(u8, v.name, b.tone3000.name),
            .search => |v| std.mem.eql(u8, v.query, b.search.query),
            .gain => |v| v == b.gain,
            .input => |v| v == b.input,
            .latency => |v| v == b.latency,
            .login, .logout, .list, .off => true,
        };
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const NamInput = enum { left, right, stereo };

pub const SympatheticHarmonyComponent = struct {
    ratio: f64 = 0.0,
    weight: f32 = 0.0,
};

pub const SympatheticHarmony = struct {
    components: [8]SympatheticHarmonyComponent = @splat(.{}),
    len: usize = 0,

    /// Returns null on success, or the (static) rejection message when 8 intervals are already held.
    pub fn push(self: *SympatheticHarmony, component: SympatheticHarmonyComponent) ?[]const u8 {
        if (self.len >= self.components.len) return "sym harmony can contain at most 8 intervals";
        self.components[self.len] = component;
        self.len += 1;
        return null;
    }

    /// The Rust `iter()`: the components in use.
    pub fn items(self: *const SympatheticHarmony) []const SympatheticHarmonyComponent {
        return self.components[0..@min(self.len, self.components.len)];
    }
};

pub const SympatheticTarget = enum {
    all,
    mic,
    kanun,
    bass,
    drums,

    pub fn parse(s: []const u8) ?SympatheticTarget {
        if (eqlAnyIgnoreCase(s, &.{ "all", "mix", "master" })) return .all;
        if (eqlAnyIgnoreCase(s, &.{ "mic", "input", "live" })) return .mic;
        if (eqlAnyIgnoreCase(s, &.{ "kanun", "qanun", "melody" })) return .kanun;
        if (eqlAnyIgnoreCase(s, &.{ "bass", "sub", "subbass" })) return .bass;
        if (eqlAnyIgnoreCase(s, &.{ "drums", "drum", "kick", "kicks" })) return .drums;
        return null;
    }

    pub fn asStr(self: SympatheticTarget) []const u8 {
        return switch (self) {
            .all => "all",
            .mic => "mic",
            .kanun => "kanun",
            .bass => "bass",
            .drums => "drums",
        };
    }
};

// ── Metadata ──────────────────────────────────────────────────────────────────

pub const CommandMetadata = struct {
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    targets: []const CommandTokenMetadata,
    parameters: []const CommandParameterMetadata,
    first_parameter: []const u8,
    notes: []const []const u8,
};

pub const CommandTokenMetadata = struct {
    name: []const u8,
    aliases: []const []const u8,
};

pub const CommandParameterMetadata = struct {
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    values: []const []const u8,
    units: []const u8,
    lower: ?f64,
    upper: ?f64,
    typical: []const u8,
    notes: []const []const u8,
};

pub const LanguagePatternMetadata = struct {
    syntax: []const u8,
    description: []const u8,
    notes: []const []const u8,
};

const VCF_TARGETS = [_]CommandTokenMetadata{
    .{
        .name = "all",
        .aliases = &.{ "mix", "master" },
    },
    .{
        .name = "mic",
        .aliases = &.{ "input", "live" },
    },
    .{
        .name = "bass",
        .aliases = &.{ "sub", "subbass" },
    },
    .{
        .name = "kanun",
        .aliases = &.{ "qanun", "melody" },
    },
    .{
        .name = "drums",
        .aliases = &.{ "drum", "kick", "kicks" },
    },
    .{
        .name = "sym",
        .aliases = &.{ "tanbura", "tambura", "sympathetics" },
    },
};

const VCF_PARAMETERS = [_]CommandParameterMetadata{
    .{
        .name = "cut",
        .aliases = &.{ "cutoff", "freq", "frequency" },
        .description = "filter cutoff frequency",
        .values = &.{},
        .units = "Hz",
        .lower = 10.0,
        .upper = 22000.0,
        .typical = "700..4000 for audible sweeps",
        .notes = &.{},
    },
    .{
        .name = "res",
        .aliases = &.{ "q", "reso", "resonance" },
        .description = "filter resonance",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 0.98,
        .typical = "0.2..0.75",
        .notes = &.{"values near 0.98 can ring sharply"},
    },
    .{
        .name = "drive",
        .aliases = &.{"drv"},
        .description = "filter input drive",
        .values = &.{},
        .units = "",
        .lower = 0.1,
        .upper = 12.0,
        .typical = "1..4",
        .notes = &.{},
    },
    .{
        .name = "wave",
        .aliases = &.{ "wav", "shape" },
        .description = "VCO/source waveform used by instrument VCFs",
        .values = &.{ "sin", "tri", "squ", "saw", "mic" },
        .units = "",
        .lower = null,
        .upper = null,
        .typical = "target instrument defaults to its own source",
        .notes = &.{"vcf all ignores wave because it filters the final outgoing mix"},
    },
    .{
        .name = "off",
        .aliases = &.{},
        .description = "turn the selected VCF off",
        .values = &.{},
        .units = "",
        .lower = null,
        .upper = null,
        .typical = "",
        .notes = &.{},
    },
};

const SYM_TARGETS = [_]CommandTokenMetadata{
    .{
        .name = "all",
        .aliases = &.{ "mix", "master" },
    },
    .{
        .name = "mic",
        .aliases = &.{ "input", "live" },
    },
    .{
        .name = "kanun",
        .aliases = &.{ "qanun", "melody" },
    },
    .{
        .name = "bass",
        .aliases = &.{ "sub", "subbass" },
    },
    .{
        .name = "drums",
        .aliases = &.{ "drum", "kick", "kicks" },
    },
};

const SYM_PARAMETERS = [_]CommandParameterMetadata{
    .{
        .name = "decay",
        .aliases = &.{},
        .description = "sympathetic string decay time",
        .values = &.{},
        .units = "",
        .lower = 0.9,
        .upper = 0.99999,
        .typical = "0.999",
        .notes = &.{"higher values ring longer"},
    },
    .{
        .name = "drive",
        .aliases = &.{"gain"},
        .description = "sympathetic resonator excitation drive",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 512.0,
        .typical = "0.5..8",
        .notes = &.{
            "default is 2",
            "values above 16 are extreme unless the user explicitly asks",
        },
    },
    .{
        .name = "amount",
        .aliases = &.{ "amt", "level", "send" },
        .description = "source send amount into a target sympathetic partition",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 512.0,
        .typical = "0..4",
        .notes = &.{"hard range is wide for sound design; ordinary edits should stay small"},
    },
    .{
        .name = "up",
        .aliases = &.{ "interval", "transpose" },
        .description = "multiply sympathetic resonator target strings upward by an ideal interval ratio",
        .values = &.{
            "unison", "second", "third", "fourth", "fifth", "sixth", "seventh", "octave",
        },
        .units = "ratio",
        .lower = 0.25,
        .upper = 4.0,
        .typical = "third, fourth, fifth, octave",
        .notes = &.{
            "`sym down <interval>` uses the reciprocal interval",
            "`sym harmony root third fourth octave` combines weighted target intervals",
            "explicit ratios are accepted, e.g. `sym interval 3/2`",
            "third and sixth quality matters; use minor-third/major-third or minor-sixth/major-sixth",
        },
    },
    .{
        .name = "mic",
        .aliases = &.{ "input", "live" },
        .description = "mic source send amount",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 512.0,
        .typical = "0..4",
        .notes = &.{},
    },
    .{
        .name = "kanun",
        .aliases = &.{ "qanun", "melody" },
        .description = "kanun source send amount",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 512.0,
        .typical = "0..4",
        .notes = &.{},
    },
    .{
        .name = "bass",
        .aliases = &.{ "sub", "subbass" },
        .description = "bass source send amount",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 512.0,
        .typical = "0..4",
        .notes = &.{},
    },
    .{
        .name = "drums",
        .aliases = &.{ "drum", "kick", "kicks" },
        .description = "drum source send amount",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = 512.0,
        .typical = "0..4",
        .notes = &.{},
    },
    .{
        .name = "on",
        .aliases = &.{},
        .description = "turn sympathetics on",
        .values = &.{},
        .units = "",
        .lower = null,
        .upper = null,
        .typical = "",
        .notes = &.{},
    },
    .{
        .name = "off",
        .aliases = &.{},
        .description = "turn sympathetics off",
        .values = &.{},
        .units = "",
        .lower = null,
        .upper = null,
        .typical = "",
        .notes = &.{},
    },
};

pub const VCF_METADATA: CommandMetadata = .{
    .name = "vcf",
    .aliases = &.{
        "filter", "filt", "cut", "cutoff", "res", "q", "drive", "drv",
    },
    .description = "voltage-controlled filter lines; each target can have its own partition, and vcf all filters the final outgoing mix",
    .targets = &VCF_TARGETS,
    .parameters = &VCF_PARAMETERS,
    .first_parameter = "cut",
    .notes = &.{
        "named parameters may be combined on one line; omitted values keep their current value",
        "instrument targets default wave to their own source, so `vcf mic ... wave mic` is redundant",
        "relative values like cut=+100, res=-0.1, drive=*1.5, and tick values like cut=+2t are accepted",
    },
};

pub const SYM_METADATA: CommandMetadata = .{
    .name = "sym",
    .aliases = &.{ "sympathetics", "tanbura", "tambura" },
    .description = "sympathetic resonator lines partitioned by all, mic, kanun, bass, and drums",
    .targets = &SYM_TARGETS,
    .parameters = &SYM_PARAMETERS,
    .first_parameter = "decay",
    .notes = &.{
        "named parameters may be combined on one line; omitted values keep their current value",
        "partitioned lines let mic have different decay, drive, and amount from kanun, bass, or drums",
        "`gain` is accepted as an alias for `drive`, but prefer `drive` when generating commands",
    },
};

const NAM_PARAMETERS = [_]CommandParameterMetadata{
    .{
        .name = "load",
        .aliases = &.{},
        .description = "load a cached NAM capture name, .nam file path, or URL for live mic input",
        .values = &.{},
        .units = "name/path/url",
        .lower = null,
        .upper = null,
        .typical = "nam metallica",
        .notes = &.{
            "the `load` word is optional; `nam metallica` and `nam load metallica` are accepted",
            "use `nam import FILENAME.nam as name` before loading by cached name",
            "URL loads download into the local cache first and show progress",
        },
    },
    .{
        .name = "import",
        .aliases = &.{"pull"},
        .description = "copy or download a .nam file into the local NAM capture cache",
        .values = &.{},
        .units = "path/url/name",
        .lower = null,
        .upper = null,
        .typical = "nam import https://example.com/amp.nam as amp",
        .notes = &.{
            "without `as name`, the cache name is derived from the file name or URL",
            "by default captures are cached in ./.nam, which is created automatically",
            "URL imports show a progress meter while downloading",
        },
    },
    .{
        .name = "ls",
        .aliases = &.{"list"},
        .description = "list cached NAM captures and .nam files in the current directory",
        .values = &.{},
        .units = "",
        .lower = null,
        .upper = null,
        .typical = "",
        .notes = &.{},
    },
    .{
        .name = "gain",
        .aliases = &.{"drive"},
        .description = "input gain before the NAM model",
        .values = &.{},
        .units = "",
        .lower = 0.0,
        .upper = nam_gain_max, // spec range nam gain 0..100 (the Rust help text says 8)
        .typical = "0.5..2",
        .notes = &.{"use this to control how hard the amp model is driven"},
    },
    .{
        .name = "off",
        .aliases = &.{},
        .description = "bypass the live input NAM model",
        .values = &.{},
        .units = "",
        .lower = null,
        .upper = null,
        .typical = "",
        .notes = &.{},
    },
};

pub const NAM_METADATA: CommandMetadata = .{
    .name = "nam",
    .aliases = &.{},
    .description = "live mic-input Neural Amp Modeler A1/A2 amp stage",
    .targets = &.{},
    .parameters = &NAM_PARAMETERS,
    .first_parameter = "load",
    .notes = &.{
        "NAM is live input state and is not saved in .mq files",
        "the chain is mic input -> NAM -> cabinet IR -> vcf mic or vcf all -> output",
        "cached captures live under ./.nam unless MAQAM_NAM_CACHE_DIR is set",
        "NAM models have an expected sample rate; set the audio device to that rate if the model sounds wrong",
    },
};

pub const LANGUAGE_PATTERNS = [_]LanguagePatternMetadata{
    .{
        .syntax = "<root> <jins> [rhythm]",
        .description = "add a phrase using one jins or Western mode",
        .notes = &.{
            "roots are c d e f g a b with optional + or -, e.g. b-",
            "jins/modes include bayati, hijaz, rast, kurd, saba, ajam, nahawand, major, minor, dorian, phrygian, lydian, mixolydian, aeolian, locrian, diminished",
            "rhythm is a run of group lengths such as 4444 or 332332",
            "there is no time signature setting; express time signatures and meter by grouping rhythm chunks",
            "for 7/8 use 43, 34, 223, or similar groupings; 4433 is two 7/8 bars",
        },
    },
    .{
        .syntax = "<root> <jins>, <root> <jins> [rhythm]",
        .description = "add a phrase that changes jins inside the phrase",
        .notes = &.{"use this for compact turnarounds and mixed modal phrases"},
    },
    .{
        .syntax = "<phrase> r<N>",
        .description = "repeat a phrase locally before moving to the next timeline row",
        .notes = &.{
            "prefer repeats over many duplicated phrase rows",
            "when the user asks for N bars of one phrase, use r<N>",
            "16 bars in 7/8 is usually `<root> <jins> 43 r16`; if using a two-bar grouping like 4433, use r8",
        },
    },
    .{
        .syntax = "j <success-id> [else <fail-id>] <times|always>",
        .description = "jump back or forward to an existing timeline id",
        .notes = &.{
            "use jumps only to restart a multi-row section after its intended duration",
            "do not use a jump where one phrase repeat like r16 expresses the requested bars",
            "jump times count passes through the jump row, not phrase rows and not bars",
            "for a restart after 16 bars, count 16 steps in time, not 16 phrase rows; count time bars from rhythm group totals and phrase repeats, then place one jump at that point",
            "a jump with times 1 is a no-op; do not generate `j <id> 1`",
            "`else <id>` replaces fall-through with an explicit failure address when the counter exhausts",
            "keep generated scores readable in about a dozen timeline rows",
        },
    },
    .{
        .syntax = "i <id> <command>",
        .description = "insert a phrase or control command before an existing id",
        .notes = &.{"the current timeline id may be used as the insertion point"},
    },
    .{
        .syntax = "edit <id> <command>",
        .description = "replace an existing timeline row",
        .notes = &.{"tab completion after edit id should offer the row's current command"},
    },
    .{
        .syntax = "x <id> [id ...]",
        .description = "delete one or more timeline rows",
        .notes = &.{},
    },
    .{
        .syntax = "up <id> | down <id> | rot | stop",
        .description = "move rows, rotate the timeline, or insert a stop line",
        .notes = &.{},
    },
    .{
        .syntax = "bpm <20..400>",
        .description = "add a tempo control line",
        .notes = &.{"write `bpm 180`, never `set tempo 180`"},
    },
    .{
        .syntax = "s <0.05..10> | sus <0.05..10>",
        .description = "add a sustain control line in seconds",
        .notes = &.{},
    },
    .{
        .syntax = "sym on | sym off",
        .description = "turn sympathetic resonators on or off",
        .notes = &.{
            "if the user says `add in sympathetics`, make the edit; do not merely explain it",
            "a useful default is `sym on` followed by `sym decay 0.999 drive 2 kanun 0.5 bass 0.5`",
        },
    },
    .{
        .syntax = "sym decay <0.9..0.99999> drive <0..512>",
        .description = "set global sympathetic decay and drive on one control line",
        .notes = &.{
            "`sym gain <0..512>` is accepted as an alias for drive",
            "decay 0.999 is typical",
            "drive practical edit values are usually 0.5..8",
            "drive values above 16 are extreme unless the user explicitly asks",
        },
    },
    .{
        .syntax = "sym decay <n> drive <n> kanun <n> bass <n>",
        .description = "set multiple sympathetic parameters on a compressed global line",
        .notes = &.{"only mentioned values change; omitted values keep their current value"},
    },
    .{
        .syntax = "sym up <interval> | sym down <interval> | sym interval <ratio>",
        .description = "transpose sympathetic resonator target strings",
        .notes = &.{
            "named intervals include second, third, fourth, fifth, sixth, seventh, and octave",
            "named intervals use ideal ratios: minor-third=6/5, major-third=5/4, fourth=4/3, fifth=3/2, octave=2/1",
            "generic third means minor-third; use major-third when the harmony needs 5/4",
            "explicit ratios like `sym interval 3/2` are accepted",
        },
    },
    .{
        .syntax = "sym harmony <interval> [weight] [interval weight ...]",
        .description = "combine multiple sympathetic target harmonies with weighted energy",
        .notes = &.{
            "example: `sym harmony root third fourth octave`",
            "example with explicit split: `sym harmony root 0.50 third 0.25 fifth 0.25`",
            "default behavior is equivalent to `sym harmony root 1.0`",
            "weights are normalized to a total energy of 1.0 before retuning",
        },
    },
    .{
        .syntax = "sym <all|mic|kanun|bass|drums> decay <n> drive <n> amount <n>",
        .description = "set one sympathetic partition independently",
        .notes = &.{
            "amount/source sends have hard range 0..512",
            "practical amount/source send values are usually 0..4",
        },
    },
    .{
        .syntax = "vcf off | vcf <all|mic|bass|kanun|drums|sym> off",
        .description = "turn all VCFs off or turn one VCF partition off",
        .notes = &.{},
    },
    .{
        .syntax = "vcf <target> cut <10..22000> res <0..0.98> drive <0.1..12> wave <sin|tri|squ|saw|mic>",
        .description = "set one VCF partition with named parameters",
        .notes = &.{
            "only mentioned values change; omitted values keep their current value",
            "instrument targets default wave to their own source",
            "vcf all ignores wave and filters the final outgoing mix",
        },
    },
    .{
        .syntax = "flanger on/off | flanger rate <0.01..8> depth <0..1> delay <0.1..10> feedback <-0.95..0.95> mix <0..1>",
        .description = "turn the post-amp flanger on or off and edit modulation parameters",
        .notes = &.{"named parameters may be combined on one line"},
    },
    .{
        .syntax = "chorus on/off | chorus rate <0.01..8> depth <0..1> delay <5..35> mix <0..1>",
        .description = "turn the post-amp chorus on or off and edit modulation parameters",
        .notes = &.{"named parameters may be combined on one line"},
    },
    .{
        .syntax = "reverb on/off | reverb mix <0..1> decay <0..0.98>",
        .description = "turn reverb on or off and edit reverb parameters",
        .notes = &.{"named parameters may be combined on one line"},
    },
    .{
        .syntax = "delay on/off | delay time <0.01..2> feedback <0..0.95> mix <0..1>",
        .description = "turn ping-pong delay on or off and edit delay parameters",
        .notes = &.{"`pingpong` is accepted as an alias for delay"},
    },
    .{
        .syntax = "cab <vintage|modern|open> [mix <0..1>] | cab off",
        .description = "apply a portable cabinet impulse response after the live NAM amp",
        .notes = &.{"vintage is a warm 4x12, modern is a tight 4x12, and open is an open-back 1x12"},
    },
    .{
        .syntax = "fx off",
        .description = "turn all effects and the cabinet stage off",
        .notes = &.{},
    },
    .{
        .syntax = "nam login | nam logout | nam tone3000 ID as name | nam pin URL as name | nam import FILENAME.nam [as name] | nam input left|right|stereo | nam latency left|right | nam search <query> | nam <name|FILENAME.nam|URL> | nam load <name|FILENAME.nam|URL> | nam ls | nam off | nam gain <0..100>",
        .description = "cache, load, list, or bypass Neural Amp Modeler A1/A2 captures on live mic input",
        .notes = &.{
            "`nam pin URL as name` writes an unambiguous downloadable dependency into the loaded .mq file",
            "`nam login` opens TONE3000 OAuth in a browser while the TUI keeps running; `nam logout` forgets it",
            "do not invent fake NAM paths; use a real local .nam file or URL",
            "import a capture once, then load it later by cached name",
            "`nam ls` browses cached captures plus .nam files in the current directory",
            "`nam search Fender clean A2` searches for real capture pages and direct .nam links",
            "use `vcf mic` to filter the modeled input bus or `vcf all` to filter the final mix",
        },
    },
    .{
        .syntax = "create <Name> <ratios...> | delete <Name>",
        .description = "create or delete a custom jins",
        .notes = &.{"ratios use forms like 1/1 9/8 5/4"},
    },
};

/// The language reference shown to performers and LLMs. Caller owns the returned text.
pub fn languageReference(gpa: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "maqam-live command language reference\n\n");
    try out.appendSlice(gpa, "Core rule: use only this command language; do not invent English aliases.\n\n");
    try out.appendSlice(gpa, "Patterns:\n");
    for (LANGUAGE_PATTERNS) |pattern| {
        try out.appendSlice(gpa, "- `");
        try out.appendSlice(gpa, pattern.syntax);
        try out.appendSlice(gpa, "`: ");
        try out.appendSlice(gpa, pattern.description);
        try appendNotes(gpa, &out, pattern.notes);
        try out.append(gpa, '\n');
    }
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, "Nouns:\n");
    for ([_]*const CommandMetadata{ &VCF_METADATA, &SYM_METADATA, &NAM_METADATA }) |meta| {
        try out.appendSlice(gpa, "- `");
        try out.appendSlice(gpa, meta.name);
        try out.appendSlice(gpa, "`: ");
        try out.appendSlice(gpa, meta.description);
        try appendAliases(gpa, &out, meta.aliases);
        try out.append(gpa, '\n');
        if (meta.targets.len != 0) {
            try out.appendSlice(gpa, "  targets: ");
            try appendTokens(gpa, &out, meta.targets);
            try out.append(gpa, '\n');
        }
        try out.appendSlice(gpa, "  first parameter for completion: `");
        try out.appendSlice(gpa, meta.first_parameter);
        try out.appendSlice(gpa, "`\n");
        try out.appendSlice(gpa, "  parameters:\n");
        for (meta.parameters) |*param| {
            try out.appendSlice(gpa, "  - `");
            try out.appendSlice(gpa, param.name);
            try out.append(gpa, '`');
            try appendAliases(gpa, &out, param.aliases);
            try out.appendSlice(gpa, ": ");
            try out.appendSlice(gpa, param.description);
            try appendLimits(gpa, &out, param);
            if (param.typical.len != 0) {
                try out.appendSlice(gpa, "; typical ");
                try out.appendSlice(gpa, param.typical);
            }
            try appendNotes(gpa, &out, param.notes);
            try out.append(gpa, '\n');
        }
        for (meta.notes) |note| {
            try out.appendSlice(gpa, "  note: ");
            try out.appendSlice(gpa, note);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

fn appendAliases(gpa: Allocator, out: *std.ArrayList(u8), aliases: []const []const u8) Allocator.Error!void {
    if (aliases.len == 0) return;
    try out.appendSlice(gpa, " (aliases: ");
    for (aliases, 0..) |alias, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, alias);
    }
    try out.append(gpa, ')');
}

fn appendTokens(gpa: Allocator, out: *std.ArrayList(u8), tokens: []const CommandTokenMetadata) Allocator.Error!void {
    for (tokens, 0..) |token, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, token.name);
        try appendAliases(gpa, out, token.aliases);
    }
}

fn appendLimits(gpa: Allocator, out: *std.ArrayList(u8), param: *const CommandParameterMetadata) Allocator.Error!void {
    if (param.values.len != 0) {
        try out.appendSlice(gpa, "; values ");
        for (param.values, 0..) |value, i| {
            if (i > 0) try out.append(gpa, '|');
            try out.appendSlice(gpa, value);
        }
    }
    var buf: [64]u8 = undefined;
    if (param.lower != null and param.upper != null) {
        try out.appendSlice(gpa, "; range ");
        try out.appendSlice(gpa, formatNumber(&buf, param.lower.?));
        try out.appendSlice(gpa, "..");
        try out.appendSlice(gpa, formatNumber(&buf, param.upper.?));
    } else if (param.lower) |lower| {
        try out.appendSlice(gpa, "; minimum ");
        try out.appendSlice(gpa, formatNumber(&buf, lower));
    } else if (param.upper) |upper| {
        try out.appendSlice(gpa, "; maximum ");
        try out.appendSlice(gpa, formatNumber(&buf, upper));
    }
    if (param.units.len != 0) {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, param.units);
    }
}

fn appendNotes(gpa: Allocator, out: *std.ArrayList(u8), notes: []const []const u8) Allocator.Error!void {
    if (notes.len == 0) return;
    try out.appendSlice(gpa, "; ");
    for (notes, 0..) |note, i| {
        if (i > 0) try out.appendSlice(gpa, "; ");
        try out.appendSlice(gpa, note);
    }
}

/// `{n:.5}` with trailing zeros and a trailing point removed (metadata limits only).
fn formatNumber(buf: *[64]u8, n: f64) []const u8 {
    var s: []const u8 = std.fmt.bufPrint(buf, "{d:.5}", .{n}) catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (s.len > 0 and s[s.len - 1] == '0') s = s[0 .. s.len - 1];
    }
    if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    return s;
}

pub fn commandMetadata(head: []const u8) ?*const CommandMetadata {
    for ([_]*const CommandMetadata{ &VCF_METADATA, &SYM_METADATA, &NAM_METADATA }) |meta| {
        if (matchesNameOrAlias(head, meta.name, meta.aliases)) return meta;
    }
    return null;
}

/// The Rust lowercases the token and compares it with the (all-lowercase) names: ASCII
/// case-insensitive.
fn matchesNameOrAlias(token: []const u8, name: []const u8, aliases: []const []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, name)) return true;
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(token, a)) return true;
    }
    return false;
}

pub fn commandTokenName(tokens: []const CommandTokenMetadata, token: []const u8) ?[]const u8 {
    for (tokens) |item| {
        if (matchesNameOrAlias(token, item.name, item.aliases)) return item.name;
    }
    return null;
}

pub fn commandParameter(meta: *const CommandMetadata, token: []const u8) ?*const CommandParameterMetadata {
    for (meta.parameters) |*param| {
        if (matchesNameOrAlias(token, param.name, param.aliases)) return param;
    }
    return null;
}

// ── ValueChange ───────────────────────────────────────────────────────────────

pub const ValueChange = union(enum) {
    set: f64,
    add: f64,
    mul: f64,
    div: f64,
    tick: f64,

    fn parseIn(c: *Ctx, token: []const u8, usage: []const u8) Error!ValueChange {
        const t = trim(token);
        if (t.len > 0 and t[t.len - 1] == 't') {
            const n = parseFloatRust(f64, t[0 .. t.len - 1]) orelse return c.rejectStatic(usage);
            return .{ .tick = n };
        }
        if (t.len >= 2) {
            // Deliberate: a non-ASCII first byte falls through to the usage rejection (the Rust
            // panics in split_at(1)).
            const op = t[0];
            const n = parseFloatRust(f64, t[1..]) orelse return c.rejectStatic(usage);
            return switch (op) {
                '+' => .{ .add = n },
                '-' => .{ .add = -n },
                '*' => .{ .mul = n },
                '/' => .{ .div = n },
                else => .{ .set = parseFloatRust(f64, t) orelse return c.rejectStatic(usage) },
            };
        }
        return .{ .set = parseFloatRust(f64, t) orelse return c.rejectStatic(usage) };
    }

    /// Public parse for other modules: the usage message is returned on rejection (owned).
    pub fn parseToken(gpa: Allocator, token: []const u8, usage: []const u8) Allocator.Error!Result(ValueChange) {
        var c: Ctx = .{ .gpa = gpa };
        return c.finish(ValueChange, parseIn(&c, token, usage));
    }

    pub const ApplyResult = union(enum) { ok: f64, err: []const u8 };

    /// The rejection message is static.
    pub fn apply(self: ValueChange, current: f64) ApplyResult {
        return switch (self) {
            .set => |n| .{ .ok = n },
            .add => |n| .{ .ok = current + n },
            .mul => |n| .{ .ok = current * n },
            .div => |n| if (n == 0.0) .{ .err = "division by zero" } else .{ .ok = current / n },
            .tick => .{ .ok = current },
        };
    }
};

// ── Cmd ───────────────────────────────────────────────────────────────────────

pub const LlmProvider = enum { chat_gpt, claude };

pub const Cmd = union(enum) {
    add_phrase: struct { source: []const u8, specs: []JinsSpec, repeat: usize },
    jump: struct { to: isize, fail_to: ?isize, times: usize },
    insert: struct { before: isize, source: []const u8, specs: []JinsSpec, repeat: usize },
    insert_bpm: struct { before: isize, change: ValueChange },
    insert_sustain: struct { before: isize, change: ValueChange },
    insert_vcf: struct { before: isize, change: VcfChange },
    insert_fx: struct { before: isize, change: FxChange },
    insert_vol: struct { before: isize, value: f32 },
    insert_bus_vol: struct { before: isize, target: VcfTarget, value: f32 },
    insert_dry: struct { before: isize, percent: f32 },
    insert_nam: struct { before: isize, command: NamCommand },
    insert_sympathetics: struct { before: isize, enabled: bool },
    insert_sympathetic_decay: struct { before: isize, decay: f32 },
    insert_sympathetic_gain: struct { before: isize, gain: f32 },
    insert_sympathetic: struct { before: isize, change: SympatheticChange },
    move_up: isize,
    move_down: isize,
    edit: struct { id: isize, source: []const u8, specs: []JinsSpec, repeat: usize },
    edit_jump: struct { id: isize, to: isize, fail_to: ?isize, times: usize },
    edit_bpm: struct { id: isize, change: ValueChange },
    edit_sustain: struct { id: isize, change: ValueChange },
    edit_vcf: struct { id: isize, change: VcfChange },
    edit_fx: struct { id: isize, change: FxChange },
    edit_vol: struct { id: isize, value: f32 },
    edit_bus_vol: struct { id: isize, target: VcfTarget, value: f32 },
    edit_dry: struct { id: isize, percent: f32 },
    edit_nam: struct { id: isize, command: NamCommand },
    edit_sympathetics: struct { id: isize, enabled: bool },
    edit_sympathetic_decay: struct { id: isize, decay: f32 },
    edit_sympathetic_gain: struct { id: isize, gain: f32 },
    edit_sympathetic: struct { id: isize, change: SympatheticChange },
    insert_jump: struct { before: isize, to: isize, fail_to: ?isize, times: usize },
    delete_bars: []isize,
    rotate,
    stop,
    sympathetics: bool,
    sympathetic_decay: f32,
    sympathetic_gain: f32,
    sympathetic: SympatheticChange,
    set_bpm: ValueChange,
    tune_to: Pitch,
    set_sustain: ValueChange,
    set_vcf: VcfChange,
    set_fx: FxChange,
    set_nam: NamCommand,
    set_vol: f32,
    set_bus_vol: struct { target: VcfTarget, value: f32 },
    set_dry: f32,
    record: usize,
    toggle_pause: struct { start_id: ?isize },
    list_jins,
    audition_jins: struct { specs: []JinsSpec },
    create_jins: struct { name: []const u8, ratios: []Ratio },
    delete_jins: struct { name: []const u8 },
    save: struct { path: ?[]const u8 },
    load: struct { path: []const u8 },
    ask_llm: struct { provider: LlmProvider, prompt: []const u8 },
    clear,
    help,
    quit,

    pub fn deinit(self: Cmd, gpa: Allocator) void {
        switch (self) {
            .add_phrase => |v| {
                gpa.free(v.source);
                freeSpecs(gpa, v.specs);
            },
            .insert => |v| {
                gpa.free(v.source);
                freeSpecs(gpa, v.specs);
            },
            .edit => |v| {
                gpa.free(v.source);
                freeSpecs(gpa, v.specs);
            },
            .insert_nam => |v| v.command.deinit(gpa),
            .edit_nam => |v| v.command.deinit(gpa),
            .set_nam => |v| v.deinit(gpa),
            .delete_bars => |v| gpa.free(v),
            .audition_jins => |v| freeSpecs(gpa, v.specs),
            .create_jins => |v| {
                gpa.free(v.name);
                gpa.free(v.ratios);
            },
            .delete_jins => |v| gpa.free(v.name),
            .save => |v| if (v.path) |p| gpa.free(p),
            .load => |v| gpa.free(v.path),
            .ask_llm => |v| gpa.free(v.prompt),
            else => {},
        }
    }
};

/// Name used by the porting brief; the Rust type is `Cmd`.
pub const Command = Cmd;

/// The result of `parse`: `ok` holds the command, `err` the rejection message shown to the
/// performer (text identical to the Rust). Everything is owned; free with `deinit`.
pub const ParseResult = union(enum) {
    ok: Cmd,
    err: []u8,

    pub fn deinit(self: ParseResult, gpa: Allocator) void {
        switch (self) {
            .ok => |c| c.deinit(gpa),
            .err => |m| gpa.free(m),
        }
    }
};

/// Parse one command line (the Rust `command::parse`).
pub fn parse(gpa: Allocator, raw: []const u8) Allocator.Error!ParseResult {
    var c: Ctx = .{ .gpa = gpa };
    return switch (try c.finish(Cmd, parseInner(&c, raw, 0))) {
        .ok => |v| .{ .ok = v },
        .err => |m| .{ .err = m },
    };
}

fn parseInner(c: *Ctx, raw: []const u8, depth: usize) Error!Cmd {
    const input = trim(raw);
    if (input.len == 0) return c.rejectStatic("empty");

    if (parseLlmPrompt(input)) |lp| {
        if (lp.prompt.len == 0)
            return c.rejectStatic("type a question after the colon, like chatgpt: how do i set a vcf filter?");
        return .{ .ask_llm = .{ .provider = lp.provider, .prompt = try c.dupe(lp.prompt) } };
    }

    // ── Exact keyword matches ─────────────────────────────────────────────
    const eql = std.mem.eql;
    if (eql(u8, input, "q") or eql(u8, input, "quit")) return .quit;
    if (eql(u8, input, "?") or eql(u8, input, "help")) return .help;
    if (eql(u8, input, "clear")) return .clear;
    if (eql(u8, input, "rot")) return .rotate;
    if (eql(u8, input, "stop")) return .stop;
    inline for (.{ "sym", "sympathetics", "tanbura", "tambura" }) |w| {
        if (eql(u8, input, w) or eql(u8, input, w ++ " on")) return .{ .sympathetics = true };
        if (eql(u8, input, w ++ " off")) return .{ .sympathetics = false };
    }
    if (eql(u8, input, "start")) return .{ .toggle_pause = .{ .start_id = START_REF } };
    if (eql(u8, input, "pause")) return .{ .toggle_pause = .{ .start_id = null } };
    if (eql(u8, input, "m")) return .{ .record = 1 };

    // ── m<N> / m <N> ─────────────────────────────────────────────────────
    {
        var it = Tokens.init(input);
        if (it.next()) |tok| {
            if (std.ascii.toLower(tok[0]) == 'm' and !(tok.len >= 2 and std.ascii.toLower(tok[1]) == 'a')) {
                const d = tok[1..];
                const repeat: usize = if (d.len != 0)
                    parseIntRust(usize, d) orelse 1
                else if (it.next()) |s|
                    parseIntRust(usize, s) orelse 1
                else
                    1;
                return .{ .record = @max(repeat, 1) };
            }
        }
    }

    const first = nthToken(input, 0) orelse "";
    var alpha_len: usize = 0;
    while (alpha_len < first.len and std.ascii.isAlphabetic(first[alpha_len])) alpha_len += 1;
    const al = first[0..alpha_len];
    const digits = first[alpha_len..];
    const isAl = struct {
        fn f(a: []const u8, comptime words: []const []const u8) bool {
            return eqlAnyIgnoreCase(a, words);
        }
    }.f;

    if (isAl(al, &.{ "sym", "sympathetics", "tanbura", "tambura" })) {
        const ch = try parseSympatheticChange(c, input);
        const sources_none = ch.amount == null and ch.mic == null and ch.kanun == null and
            ch.bass == null and ch.drums == null;
        if (ch.enabled != null and ch.enabled.? and ch.target == null and ch.decay == null and
            ch.gain == null and sources_none)
            return .{ .sympathetics = true };
        if (ch.enabled != null and !ch.enabled.? and ch.target == null and ch.decay == null and
            ch.gain == null and sources_none)
            return .{ .sympathetics = false };
        if (ch.decay) |decay| {
            if (ch.target == null and ch.enabled == null and ch.gain == null and sources_none)
                return .{ .sympathetic_decay = decay };
            return .{ .sympathetic = ch };
        }
        if (ch.gain) |gain| {
            if (ch.target == null and ch.enabled == null and ch.decay == null and sources_none)
                return .{ .sympathetic_gain = gain };
            return .{ .sympathetic = ch };
        }
        return .{ .sympathetic = ch };
    }

    // ── SOUND TOGGLE / TRANSPORT: z [phrase-id] ──────────────────────────
    if (isAl(al, &.{"z"})) {
        const usage = "usage: z [phrase-id]";
        const start_id: ?isize = if (digits.len != 0)
            try parseIdRef(c, digits, usage)
        else if (nthToken(input, 1)) |v|
            try parseIdRef(c, v, usage)
        else
            null;
        return .{ .toggle_pause = .{ .start_id = start_id } };
    }

    // ── JUMP: j <pos> [<times>] ───────────────────────────────────────────
    if (isAl(al, &.{"j"})) {
        const usage = "usage: j <pos> [times]";
        const to: isize = if (digits.len != 0)
            try parseIdRef(c, digits, usage)
        else
            try parseIdRef(c, nthToken(input, 1) orelse return c.rejectStatic(usage), usage);
        const base: usize = if (digits.len == 0) 2 else 1;
        var fail_to: ?isize = null;
        var times_token: ?[]const u8 = nthToken(input, base);
        if (times_token) |w| {
            if (std.ascii.eqlIgnoreCase(w, "else")) {
                const f = nthToken(input, base + 1) orelse
                    return c.rejectStatic("usage: j <success> else <fail> [times]");
                fail_to = parseIntRust(isize, f) orelse return c.rejectStatic("bad jump failure address");
                times_token = nthToken(input, base + 2);
            }
        }
        const times: usize = if (times_token) |v|
            (if (eqlAnyIgnoreCase(v, &.{ "always", "forever", "∞" }))
                0
            else
                parseIntRust(usize, v) orelse return c.rejectStatic("jump times must be a number or `always`"))
        else
            1;
        return .{ .jump = .{ .to = to, .fail_to = fail_to, .times = times } };
    }

    // ── EDIT: edit <id> <cmd> ─────────────────────────────────────────────
    if (isAl(al, &.{"edit"})) {
        const usage = "usage: edit <id> <phrase|j target [times]|bpm n|s n>";
        const parts = splitn3Ws(input);
        const id = parseIntRust(isize, parts[1] orelse return c.rejectStatic(usage)) orelse
            return c.rejectStatic(usage);
        const rest = trim(parts[2] orelse "");
        if (rest.len == 0) return c.rejectStatic(usage);
        if (depth >= max_nesting) return c.rejectStatic("unsupported command after edit");
        const inner = try parseInner(c, rest, depth + 1);
        return switch (inner) {
            .add_phrase => |v| .{ .edit = .{ .id = id, .source = v.source, .specs = v.specs, .repeat = v.repeat } },
            .jump => |v| .{ .edit_jump = .{ .id = id, .to = v.to, .fail_to = v.fail_to, .times = v.times } },
            .set_bpm => |v| .{ .edit_bpm = .{ .id = id, .change = v } },
            .set_sustain => |v| .{ .edit_sustain = .{ .id = id, .change = v } },
            .set_vcf => |v| .{ .edit_vcf = .{ .id = id, .change = v } },
            .set_fx => |v| .{ .edit_fx = .{ .id = id, .change = v } },
            .set_vol => |v| .{ .edit_vol = .{ .id = id, .value = v } },
            .set_bus_vol => |v| .{ .edit_bus_vol = .{ .id = id, .target = v.target, .value = v.value } },
            .set_dry => |v| .{ .edit_dry = .{ .id = id, .percent = v } },
            .set_nam => |v| .{ .edit_nam = .{ .id = id, .command = v } },
            .sympathetics => |v| .{ .edit_sympathetics = .{ .id = id, .enabled = v } },
            .sympathetic_decay => |v| .{ .edit_sympathetic_decay = .{ .id = id, .decay = v } },
            .sympathetic_gain => |v| .{ .edit_sympathetic_gain = .{ .id = id, .gain = v } },
            .sympathetic => |v| .{ .edit_sympathetic = .{ .id = id, .change = v } },
            else => {
                inner.deinit(c.gpa);
                return c.rejectStatic("unsupported command after edit");
            },
        };
    }

    // ── REORDER: up/down <id> ─────────────────────────────────────────────
    if (isAl(al, &.{"up"})) {
        const id = parseIntRust(isize, nthToken(input, 1) orelse "") orelse return c.rejectStatic("usage: up <id>");
        return .{ .move_up = id };
    }
    if (isAl(al, &.{"down"})) {
        const id = parseIntRust(isize, nthToken(input, 1) orelse "") orelse return c.rejectStatic("usage: down <id>");
        return .{ .move_down = id };
    }

    // ── INSERT: i<pos> <cmd> ──────────────────────────────────────────────
    if (isAl(al, &.{"i"})) {
        var before: isize = undefined;
        var rest: []const u8 = undefined;
        if (digits.len != 0) {
            before = try parseIdRef(c, digits, "usage: i<pos> <phrase|j target times|bpm n|s n>");
            rest = trim(input[first.len..]);
        } else {
            const parts = splitn3Ws(input);
            before = parseIntRust(isize, parts[1] orelse "") orelse
                return c.rejectStatic("usage: i <pos> <phrase|j target times|bpm n|s n>");
            rest = trim(parts[2] orelse "");
        }
        if (rest.len == 0) return c.rejectStatic("usage: i <pos> <phrase|j target times|bpm n|s n>");
        if (depth >= max_nesting) return c.rejectStatic("unsupported command after insert");
        const inner = try parseInner(c, rest, depth + 1);
        return switch (inner) {
            .add_phrase => |v| .{ .insert = .{ .before = before, .source = v.source, .specs = v.specs, .repeat = v.repeat } },
            .jump => |v| .{ .insert_jump = .{ .before = before, .to = v.to, .fail_to = v.fail_to, .times = v.times } },
            .set_bpm => |v| .{ .insert_bpm = .{ .before = before, .change = v } },
            .set_sustain => |v| .{ .insert_sustain = .{ .before = before, .change = v } },
            .set_vcf => |v| .{ .insert_vcf = .{ .before = before, .change = v } },
            .set_fx => |v| .{ .insert_fx = .{ .before = before, .change = v } },
            .set_vol => |v| .{ .insert_vol = .{ .before = before, .value = v } },
            .set_bus_vol => |v| .{ .insert_bus_vol = .{ .before = before, .target = v.target, .value = v.value } },
            .set_dry => |v| .{ .insert_dry = .{ .before = before, .percent = v } },
            .set_nam => |v| .{ .insert_nam = .{ .before = before, .command = v } },
            .sympathetics => |v| .{ .insert_sympathetics = .{ .before = before, .enabled = v } },
            .sympathetic_decay => |v| .{ .insert_sympathetic_decay = .{ .before = before, .decay = v } },
            .sympathetic_gain => |v| .{ .insert_sympathetic_gain = .{ .before = before, .gain = v } },
            .sympathetic => |v| .{ .insert_sympathetic = .{ .before = before, .change = v } },
            else => {
                inner.deinit(c.gpa);
                return c.rejectStatic("unsupported command after insert");
            },
        };
    }

    // ── BPM ───────────────────────────────────────────────────────────────
    if (isAl(al, &.{"bpm"})) {
        const usage = "usage: bpm <tempo|*k|/k|+n|-n>";
        const tok = nthToken(input, 1) orelse return c.rejectStatic(usage);
        return .{ .set_bpm = try ValueChange.parseIn(c, tok, usage) };
    }

    // ── TUNE REFERENCE ───────────────────────────────────────────────────
    if (isAl(al, &.{"tuneto"})) {
        const tok = nthToken(input, 1) orelse
            return c.rejectStatic("type a pitch after tuneto, like tuneto c or tuneto b-");
        const pitch = Pitch.parse(tok) orelse
            return c.reject("unknown pitch '{s}'; type a pitch like c, d, a, or b- after tuneto", .{tok});
        return .{ .tune_to = pitch };
    }

    // ── SUSTAIN ───────────────────────────────────────────────────────────
    if (isAl(al, &.{ "s", "sus" }) and digits.len == 0) {
        const usage = "usage: s <secs|*k|/k|+n|-n>";
        const tok = nthToken(input, 1) orelse return c.rejectStatic(usage);
        return .{ .set_sustain = try ValueChange.parseIn(c, tok, usage) };
    }

    // ── VCF ──────────────────────────────────────────────────────────────
    if (isAl(al, &.{ "vcf", "filter", "filt", "cut", "cutoff", "res", "q", "drive", "drv" }) and digits.len == 0) {
        return .{ .set_vcf = try parseVcfChange(c, input) };
    }

    // ── FX ───────────────────────────────────────────────────────────────
    if (isAl(al, &.{ "fx", "flanger", "flange", "chorus", "choir", "reverb", "rev", "delay", "pingpong", "cab", "cabinet" }) and digits.len == 0) {
        return .{ .set_fx = try parseFxChange(c, input) };
    }

    // ── NAM input amp model ──────────────────────────────────────────────
    if (isAl(al, &.{"nam"})) {
        return .{ .set_nam = try parseNam(c, input) };
    }

    // ── VOL ───────────────────────────────────────────────────────────────
    if (isAl(al, &.{"vol"})) {
        const nargs = countTokens(input) - 1;
        if (nargs == 2) {
            const t = nthToken(input, 1).?;
            const v = nthToken(input, 2).?;
            const target = VcfTarget.parse(t) orelse
                return c.reject("unknown volume target '{s}'; use all, mic, bass, kanun, drums, or sym", .{t});
            const n = parseFloatRust(f32, v) orelse return c.reject("bad volume '{s}'", .{v});
            if (!inRange(f32, n, 0.0, 2.0)) return c.reject("vol {s} {f} out of range 0–2", .{ target.asStr(), rf(n) });
            return .{ .set_bus_vol = .{ .target = target, .value = n } };
        }
        const n: f32 = if (digits.len != 0)
            parseFloatRust(f32, digits) orelse 1.0
        else switch (nargs) {
            0 => 1.0,
            1 => parseFloatRust(f32, nthToken(input, 1).?) orelse return c.reject("bad volume '{s}'", .{nthToken(input, 1).?}),
            else => return c.rejectStatic("usage: vol <0..2> | vol <all|mic|bass|kanun|drums|sym> <0..2>"),
        };
        if (!inRange(f32, n, 0.0, 2.0)) return c.reject("vol {f} out of range 0–2", .{rf(n)});
        return .{ .set_vol = n };
    }

    // ── DRY/WET INPUT MIX ────────────────────────────────────────────────
    if (isAl(al, &.{"dry"})) {
        const value = nthToken(input, 1) orelse return c.rejectStatic("usage: dry <0..100>");
        const percent = parseFloatRust(f32, std.mem.trimEnd(u8, value, "%")) orelse
            return c.reject("bad dry percentage '{s}'", .{value});
        if (!inRange(f32, percent, 0.0, 100.0)) return c.reject("dry {f} out of range 0–100", .{rf(percent)});
        return .{ .set_dry = percent };
    }

    // ── DELETE: x<N> [N …] ───────────────────────────────────────────────
    if (isAl(al, &.{"x"})) {
        var ids: std.ArrayList(isize) = .empty;
        errdefer ids.deinit(c.gpa);
        if (digits.len != 0) try ids.append(c.gpa, try parseIdRef(c, digits, "usage: x<N> [N …]"));
        var it = Tokens.init(input);
        _ = it.next();
        while (it.next()) |tok| {
            try ids.append(c.gpa, parseIntRust(isize, tok) orelse return c.reject("bad id '{s}'", .{tok}));
        }
        if (ids.items.len == 0) return c.rejectStatic("usage: x<N>");
        return .{ .delete_bars = try ids.toOwnedSlice(c.gpa) };
    }

    // ── LS: list all jins ─────────────────────────────────────────────────
    if (eql(u8, input, "ls")) return .list_jins;

    // ── AUDITION: audition <phrase-spec> ─────────────────────────────────
    if (isAl(al, &.{"audition"})) {
        const usage = "usage: audition <Name> | audition <root> <Name> [, <root> <Name> ...]";
        const so = splitOnceWs(input) orelse return c.rejectStatic(usage);
        const rest = trim(so.b);
        if (rest.len == 0) return c.rejectStatic(usage);
        if (Pitch.parse(nthToken(rest, 0) orelse "") != null) {
            return .{ .audition_jins = .{ .specs = try parseSpecList(c, rest) } };
        }
        const maqam = Maqam.parse(rest) orelse return c.reject("unknown maqam '{s}'", .{rest});
        const specs = try c.gpa.alloc(JinsSpec, 1);
        errdefer c.gpa.free(specs);
        specs[0] = .{
            .src = try std.fmt.allocPrint(c.gpa, "d {s}", .{maqam.name()}),
            .root = .{ .letter = 'd', .accidental = 0, .octave = 4 },
            .maqam = maqam,
            .groups = null,
        };
        return .{ .audition_jins = .{ .specs = specs } };
    }

    // ── CREATE: create <Name> <p/q> <p/q> … ──────────────────────────────
    if (isAl(al, &.{"create"})) {
        var it = Tokens.init(input);
        _ = it.next();
        const name_tok = it.next() orelse return c.rejectStatic("usage: create <Name> <ratios…>");
        var ratios: std.ArrayList(Ratio) = .empty;
        errdefer ratios.deinit(c.gpa);
        while (it.next()) |t| {
            try ratios.append(c.gpa, parseRatio(t) orelse return c.reject("bad ratio '{s}'", .{t}));
        }
        if (ratios.items.len == 0) return c.rejectStatic("need at least one ratio");
        const name = try c.dupe(name_tok);
        errdefer c.gpa.free(name);
        return .{ .create_jins = .{ .name = name, .ratios = try ratios.toOwnedSlice(c.gpa) } };
    }

    // ── DELETE: delete <Name> ─────────────────────────────────────────────
    if (isAl(al, &.{"delete"})) {
        const name = nthToken(input, 1) orelse return c.rejectStatic("usage: delete <Name>");
        return .{ .delete_jins = .{ .name = try c.dupe(name) } };
    }

    // ── SAVE / LOAD ───────────────────────────────────────────────────────
    if (isAl(al, &.{"save"})) {
        var path: ?[]const u8 = null;
        if (splitOnceWs(input)) |so| {
            const p = trim(so.b);
            if (p.len != 0) path = try c.dupe(p);
        }
        return .{ .save = .{ .path = path } };
    }
    if (isAl(al, &.{"load"})) {
        const so = splitOnceWs(input) orelse return c.rejectStatic("usage: load <path>");
        const p = trim(so.b);
        if (p.len == 0) return c.rejectStatic("usage: load <path>");
        return .{ .load = .{ .path = try c.dupe(p) } };
    }

    // ── ADD PHRASE ────────────────────────────────────────────────────────
    const sr = stripRepeat(input);
    if (sr.part.len == 0) return c.rejectStatic("empty phrase");
    const specs = try parseSpecList(c, sr.part);
    errdefer freeSpecs(c.gpa, specs);
    return .{ .add_phrase = .{ .source = try c.dupe(trim(input)), .specs = specs, .repeat = sr.repeat } };
}

fn parseSpecList(c: *Ctx, text: []const u8) Error![]JinsSpec {
    var specs: std.ArrayList(JinsSpec) = .empty;
    errdefer {
        for (specs.items) |s| s.deinit(c.gpa);
        specs.deinit(c.gpa);
    }
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |p| {
        const spec = try parseJinsSpec(c, trim(p));
        specs.append(c.gpa, spec) catch |e| {
            spec.deinit(c.gpa);
            return e;
        };
    }
    return specs.toOwnedSlice(c.gpa);
}

fn parseNam(c: *Ctx, input: []const u8) Error!NamCommand {
    const usage = "usage: nam <cached-name|FILENAME.nam|URL> | nam import <FILENAME.nam|URL> [as name] | nam ls | nam off | nam gain <0..100>";
    const so = splitOnceWs(input) orelse return c.rejectStatic(usage);
    const rest = trim(so.b);
    if (rest.len == 0) return c.rejectStatic(usage);
    var toks = Tokens.init(rest);
    const sub = toks.next() orelse "";
    const ieq = std.ascii.eqlIgnoreCase;

    if (ieq(sub, "login")) return .login;
    if (ieq(sub, "logout")) return .logout;
    if (ieq(sub, "off")) return .off;
    if (ieq(sub, "ls") or ieq(sub, "list")) return .list;
    if (ieq(sub, "search") or ieq(sub, "find")) {
        const m = "usage: nam search <amp, artist, or tone>; describe the capture to find";
        const s2 = splitOnceWs(rest) orelse return c.rejectStatic(m);
        const query = trim(s2.b);
        if (query.len == 0) return c.rejectStatic(m);
        return .{ .search = .{ .query = try c.dupe(query) } };
    }
    if (ieq(sub, "import") or ieq(sub, "pull")) {
        const m = "usage: nam import <FILENAME.nam|URL> [as name]; type a real .nam file name or URL after nam import";
        const s2 = splitOnceWs(rest) orelse return c.rejectStatic(m);
        const import_rest = trim(s2.b);
        if (import_rest.len == 0) return c.rejectStatic(m);
        var path: []const u8 = import_rest;
        var name: ?[]const u8 = null;
        if (std.mem.lastIndexOf(u8, import_rest, " as ")) |pos| {
            const n = trim(import_rest[pos + 4 ..]);
            if (n.len == 0)
                return c.rejectStatic("usage: nam import <FILENAME.nam|URL> as name; type a cache name after as");
            path = trim(import_rest[0..pos]);
            name = n;
        }
        if (path.len == 0) return c.rejectStatic(m);
        const p = try c.dupe(path);
        errdefer c.gpa.free(p);
        return .{ .import = .{ .path = p, .name = if (name) |n| try c.dupe(n) else null } };
    }
    if (ieq(sub, "pin") or ieq(sub, "require")) {
        const m = "usage: nam pin <direct-.nam-URL> as <name>";
        const s2 = splitOnceWs(rest) orelse return c.rejectStatic(m);
        const pin_rest = trim(s2.b);
        if (pin_rest.len == 0) return c.rejectStatic(m);
        const pos = std.mem.lastIndexOf(u8, pin_rest, " as ") orelse return c.rejectStatic(m);
        const url = pin_rest[0..pos];
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://"))
            return c.rejectStatic("nam pin requires a direct http(s) model URL");
        const name = trim(pin_rest[pos + 4 ..]);
        if (name.len == 0) return c.rejectStatic("nam pin needs a stable name after `as`");
        const u = try c.dupe(trim(url));
        errdefer c.gpa.free(u);
        return .{ .pin = .{ .url = u, .name = try c.dupe(name) } };
    }
    if (ieq(sub, "tone3000") or ieq(sub, "t3k")) {
        const m = "usage: nam tone3000 <tone-id> as <name>";
        if (countTokens(rest) != 4 or !ieq(nthToken(rest, 2).?, "as")) return c.rejectStatic(m);
        const tone_id = parseIntRust(u64, nthToken(rest, 1).?) orelse
            return c.rejectStatic("TONE3000 tone ID must be a number");
        return .{ .tone3000 = .{ .tone_id = tone_id, .name = try c.dupe(nthToken(rest, 3).?) } };
    }
    if (ieq(sub, "gain") or ieq(sub, "drive")) {
        const value = toks.next() orelse return c.rejectStatic("usage: nam gain <0..100>; type a number after nam gain");
        const gain = parseFloatRust(f32, value) orelse
            return c.reject("bad NAM gain '{s}'; type a number from 0 to 100", .{value});
        if (!inRange(f32, gain, 0.0, nam_gain_max))
            return c.reject("NAM gain {f} out of range 0..100; use nam gain <0..100>", .{rf(gain)});
        return .{ .gain = gain };
    }
    if (ieq(sub, "input") or ieq(sub, "in")) {
        const v = toks.next() orelse "";
        if (eqlAnyIgnoreCase(v, &.{ "left", "l", "1" })) return .{ .input = .left };
        if (eqlAnyIgnoreCase(v, &.{ "right", "r", "2" })) return .{ .input = .right };
        if (eqlAnyIgnoreCase(v, &.{ "stereo", "both", "lr" })) return .{ .input = .stereo };
        return c.rejectStatic("usage: nam input <left|right|stereo>");
    }
    if (ieq(sub, "latency")) {
        const v = toks.next() orelse "left";
        if (eqlAnyIgnoreCase(v, &.{ "left", "l", "1" })) return .{ .latency = .left };
        if (eqlAnyIgnoreCase(v, &.{ "right", "r", "2" })) return .{ .latency = .right };
        return c.rejectStatic("usage: nam latency <left|right>");
    }
    if (ieq(sub, "load")) {
        const m = "usage: nam load <model.nam|cached-name|URL>; type a .nam path, cached name, or URL after nam load";
        const s2 = splitOnceWs(rest) orelse return c.rejectStatic(m);
        const path = trim(s2.b);
        if (path.len == 0) return c.rejectStatic(m);
        return .{ .load = .{ .path = try c.dupe(path) } };
    }
    return .{ .load = .{ .path = try c.dupe(rest) } };
}

const LlmPrompt = struct { provider: LlmProvider, prompt: []const u8 };

fn parseLlmPrompt(input: []const u8) ?LlmPrompt {
    const colon = std.mem.indexOfScalar(u8, input, ':') orelse return null;
    const head = trim(input[0..colon]);
    const provider: LlmProvider = if (eqlAnyIgnoreCase(head, &.{ "chatgpt", "gpt", "openai" }))
        .chat_gpt
    else if (eqlAnyIgnoreCase(head, &.{ "claude", "anthropic" }))
        .claude
    else
        return null;
    return .{ .provider = provider, .prompt = trim(input[colon + 1 ..]) };
}

fn parseIdRef(c: *Ctx, token: []const u8, usage: []const u8) Error!isize {
    if (std.ascii.eqlIgnoreCase(token, "start")) return START_REF;
    return parseIntRust(isize, token) orelse c.rejectStatic(usage);
}

const Stripped = struct { part: []const u8, repeat: usize };

fn stripRepeat(input: []const u8) Stripped {
    var it = Tokens.init(input);
    var last_opt: ?[]const u8 = null;
    while (it.next()) |t| last_opt = t;
    const last = last_opt orelse return .{ .part = input, .repeat = 1 };
    var alpha_len: usize = 0;
    while (alpha_len < last.len and std.ascii.isAlphabetic(last[alpha_len])) alpha_len += 1;
    const la_d = last[alpha_len..];
    var is_r: bool = undefined;
    if (alpha_len == 1 and std.ascii.toLower(last[0]) == 'r' and la_d.len != 0) {
        is_r = true;
    } else if (alpha_len == 0 and la_d.len != 0) {
        is_r = false;
    } else {
        return .{ .part = input, .repeat = 1 };
    }
    const n = parseIntRust(usize, la_d) orelse return .{ .part = input, .repeat = 1 };
    if (!is_r and n > 20) return .{ .part = input, .repeat = 1 };
    const trimmed = trimEnd(input);
    const pos = std.mem.lastIndexOf(u8, trimmed, last) orelse trimmed.len;
    return .{ .part = trimEnd(trimmed[0..pos]), .repeat = @max(n, 1) };
}

fn parseJinsSpec(c: *Ctx, part: []const u8) Error!JinsSpec {
    var toks = Tokens.init(part);
    const root_tok = toks.next() orelse return c.rejectStatic("missing pitch");
    const root = Pitch.parse(root_tok) orelse return c.reject("unknown pitch '{s}'", .{root_tok});
    const maq_tok = toks.next() orelse return c.rejectStatic("missing maqam");
    const maqam = Maqam.parse(maq_tok) orelse
        return c.reject("unknown maqam '{s}'  (nah bay hij rast kurd saba ajam major minor modes)", .{maq_tok});
    var groups: ?[]u8 = null;
    if (toks.next()) |tok| {
        var n: usize = 0;
        for (tok) |b| {
            if (b >= '1' and b <= '9') n += 1;
        }
        if (n == 0) return c.reject("rhythm '{s}' must be non-zero digits", .{tok});
        const g = try c.gpa.alloc(u8, n);
        var k: usize = 0;
        for (tok) |b| {
            if (b >= '1' and b <= '9') {
                g[k] = b - '0';
                k += 1;
            }
        }
        groups = g;
    }
    errdefer if (groups) |g| c.gpa.free(g);
    return .{ .src = try c.dupe(trim(part)), .root = root, .maqam = maqam, .groups = groups };
}

fn parseRatio(s: []const u8) ?Ratio {
    const slash = std.mem.indexOfScalar(u8, s, '/');
    const p_str = if (slash) |i| s[0..i] else s;
    const p = parseIntRust(u32, p_str) orelse return null;
    const q: u32 = if (slash) |i| parseIntRust(u32, s[i + 1 ..]) orelse 1 else 1;
    if (q == 0) return null;
    return .{ .p = p, .q = q };
}

// ── sym ───────────────────────────────────────────────────────────────────────

fn parseSympatheticChange(c: *Ctx, input: []const u8) Error!SympatheticChange {
    const usage = "usage: sym [all|mic|kanun|bass|drums] [on|off] [decay <0.9..0.99999>] [drive <0..512>] [up|down <interval>] [interval <ratio>] [amount <0..512>] [mic <0..512>] [kanun <0..512>] [bass <0..512>] [drums <0..512>]";
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(c.gpa);
    var it = Tokens.init(input);
    _ = it.next();
    while (it.next()) |t| try list.append(c.gpa, t);
    var rest: []const []const u8 = list.items;
    if (rest.len == 0) return .{ .enabled = true };

    var change: SympatheticChange = .{};
    if (rest.len >= 2 and isSymSettingToken(rest[1])) {
        if (SympatheticTarget.parse(rest[0])) |target| {
            change.target = target;
            rest = rest[1..];
        }
    }
    var i: usize = 0;
    while (i < rest.len) {
        const key = rest[i];
        const next = struct {
            fn f(r: []const []const u8, j: usize) ?[]const u8 {
                return if (j < r.len) r[j] else null;
            }
        }.f;
        if (std.ascii.eqlIgnoreCase(key, "on")) {
            change.enabled = true;
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(key, "off")) {
            change.enabled = false;
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(key, "decay")) {
            i += 1;
            const decay = parseFloatRust(f32, next(rest, i) orelse return c.rejectStatic(usage)) orelse
                return c.rejectStatic(usage);
            if (!inRange(f32, decay, 0.9, 0.999_99)) return c.rejectStatic("sym decay out of range 0.9..0.99999");
            change.decay = decay;
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "gain", "drive" })) {
            i += 1;
            change.gain = try parseSymGain(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "amount", "amt", "level", "send" })) {
            i += 1;
            change.amount = try parseSymGain(c, next(rest, i), usage);
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(key, "up")) {
            i += 1;
            change.interval_ratio = try parseSymIntervalRatio(c, next(rest, i), usage);
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(key, "down")) {
            i += 1;
            change.interval_ratio = 1.0 / try parseSymIntervalRatio(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "interval", "transpose" })) {
            i += 1;
            change.interval_ratio = try parseSymIntervalRatio(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "harmony", "harm", "chord" })) {
            i += 1;
            const hr = try parseSymHarmony(c, rest[i..], usage);
            change.harmony = hr.harmony;
            i += hr.consumed;
        } else if (eqlAnyIgnoreCase(key, &.{ "mic", "input", "live" })) {
            i += 1;
            change.mic = try parseSymGain(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "kanun", "qanun", "melody" })) {
            i += 1;
            change.kanun = try parseSymGain(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "bass", "sub", "subbass" })) {
            i += 1;
            change.bass = try parseSymGain(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "drums", "drum", "kick", "kicks" })) {
            i += 1;
            change.drums = try parseSymGain(c, next(rest, i), usage);
            i += 1;
        } else if (eqlAnyIgnoreCase(key, &.{ "sym", "sympathetics", "tanbura", "tambura" })) {
            i += 1;
        } else {
            return c.rejectStatic(usage);
        }
    }
    return change;
}

fn isSymSettingToken(token: []const u8) bool {
    return eqlAnyIgnoreCase(token, &.{
        "on",   "off", "decay", "gain",     "drive",     "amount",  "amt",  "level",
        "send", "up",  "down",  "interval", "transpose", "harmony", "harm", "chord",
    });
}

const HarmonyParse = struct { harmony: SympatheticHarmony, consumed: usize };

fn parseSymHarmony(c: *Ctx, tokens: []const []const u8, usage: []const u8) Error!HarmonyParse {
    var harmony: SympatheticHarmony = .{};
    var i: usize = 0;
    while (i < tokens.len) {
        if (isSymSettingToken(tokens[i]) and harmony.len > 0) break;
        const ratio = try parseSymIntervalRatio(c, tokens[i], usage);
        i += 1;
        var weight: f32 = 1.0;
        if (i < tokens.len) {
            const nxt = tokens[i];
            if (!isSymSettingToken(nxt)) {
                if (parseFloatRust(f32, nxt)) |parsed| {
                    if (!inRange(f32, parsed, 0.0, 512.0)) return c.rejectStatic("sym harmony weight out of range 0..512");
                    weight = parsed;
                    i += 1;
                }
            }
        }
        if (harmony.push(.{ .ratio = ratio, .weight = weight })) |m| return c.rejectStatic(m);
    }
    if (harmony.len == 0) return c.rejectStatic(usage);
    return .{ .harmony = harmony, .consumed = i };
}

fn parseSymIntervalRatio(c: *Ctx, value: ?[]const u8, usage: []const u8) Error!f64 {
    const token = value orelse return c.rejectStatic(usage);
    if (std.mem.indexOfScalar(u8, token, '/')) |slash| {
        const num = parseFloatRust(f64, token[0..slash]) orelse return c.rejectStatic(usage);
        const den = parseFloatRust(f64, token[slash + 1 ..]) orelse return c.rejectStatic(usage);
        if (den == 0.0) return c.rejectStatic("sym interval ratio cannot divide by zero");
        return validateSymIntervalRatio(c, num / den);
    }
    if (parseFloatRust(f64, token)) |ratio| return validateSymIntervalRatio(c, ratio);
    // normalized: ASCII-lowercased with '-', '_' and ' ' removed
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (token) |b| {
        if (b == '-' or b == '_' or b == ' ') continue;
        if (n == buf.len) return c.rejectStatic(usage); // longer than any interval name
        buf[n] = std.ascii.toLower(b);
        n += 1;
    }
    const norm = buf[0..n];
    const Named = struct { names: []const []const u8, ratio: f64 };
    const table = [_]Named{
        .{ .names = &.{ "unison", "root", "fundamental", "f0" }, .ratio = 1.0 },
        .{ .names = &.{ "minorsecond", "minor2", "m2", "b2", "semitone", "halfstep" }, .ratio = 16.0 / 15.0 },
        .{ .names = &.{ "second", "majorsecond", "major2", "wholestep", "whole" }, .ratio = 9.0 / 8.0 },
        .{ .names = &.{ "third", "minorthird", "minor3", "min3", "m3", "b3" }, .ratio = 6.0 / 5.0 },
        .{ .names = &.{ "majorthird", "major3", "maj3" }, .ratio = 5.0 / 4.0 },
        .{ .names = &.{ "fourth", "perfectfourth", "p4" }, .ratio = 4.0 / 3.0 },
        .{ .names = &.{ "tritone", "flatfifth", "sharpfourth", "b5", "#4" }, .ratio = 45.0 / 32.0 },
        .{ .names = &.{ "fifth", "perfectfifth", "p5" }, .ratio = 3.0 / 2.0 },
        .{ .names = &.{ "sixth", "minorsixth", "minor6", "min6", "m6", "b6" }, .ratio = 8.0 / 5.0 },
        .{ .names = &.{ "majorsixth", "major6", "maj6" }, .ratio = 5.0 / 3.0 },
        .{ .names = &.{ "minorseventh", "m7", "b7" }, .ratio = 9.0 / 5.0 },
        .{ .names = &.{ "seventh", "majorseventh", "major7" }, .ratio = 15.0 / 8.0 },
        .{ .names = &.{ "octave", "oct", "8ve" }, .ratio = 2.0 },
    };
    for (table) |e| {
        for (e.names) |nm| {
            if (std.mem.eql(u8, norm, nm)) return validateSymIntervalRatio(c, e.ratio);
        }
    }
    return c.rejectStatic(usage);
}

fn validateSymIntervalRatio(c: *Ctx, ratio: f64) Error!f64 {
    if (!inRange(f64, ratio, 0.25, 4.0)) return c.rejectStatic("sym interval ratio out of range 1/4..4/1");
    return ratio;
}

fn parseSymGain(c: *Ctx, value: ?[]const u8, usage: []const u8) Error!f32 {
    const gain = parseFloatRust(f32, value orelse return c.rejectStatic(usage)) orelse return c.rejectStatic(usage);
    if (!inRange(f32, gain, 0.0, 512.0)) return c.rejectStatic("sym gain out of range 0..512");
    return gain;
}

// ── vcf ───────────────────────────────────────────────────────────────────────

fn isVcfNamedToken(token: []const u8) bool {
    return std.mem.indexOfScalar(u8, token, '=') != null or eqlAnyIgnoreCase(token, &.{
        "cut", "cutoff", "freq", "frequency", "res", "q", "reso", "resonance", "drive", "drv", "wave", "wav", "shape",
    });
}

fn parseVcfChange(c: *Ctx, input: []const u8) Error!VcfChange {
    const usage = "usage: vcf [all|mic|bass|kanun|drums|kick|sym] <cutoff> [res] [drive] | vcf [target] off | vcf <target> cut=<hz|+n|-n|+nt> res=<0..1|+n|-n|+nt> drive=<n|+n|-n|+nt> wave=<sin|tri|squ|saw|mic> | cut <hz> | res <0..1> | drive <n>";
    var toks = Tokens.init(input);
    const head = toks.next() orelse "";
    var out: VcfChange = .{};

    if (eqlAnyIgnoreCase(head, &.{ "cut", "cutoff", "filt", "filter" })) {
        const tok = toks.next() orelse return c.rejectStatic(usage);
        out.enabled = true;
        out.cutoff_hz = try ValueChange.parseIn(c, tok, usage);
        return out;
    }
    if (eqlAnyIgnoreCase(head, &.{ "res", "q" })) {
        const tok = toks.next() orelse return c.rejectStatic(usage);
        out.enabled = true;
        out.resonance = try ValueChange.parseIn(c, tok, usage);
        return out;
    }
    if (eqlAnyIgnoreCase(head, &.{ "drive", "drv" })) {
        const tok = toks.next() orelse return c.rejectStatic(usage);
        out.enabled = true;
        out.drive = try ValueChange.parseIn(c, tok, usage);
        return out;
    }

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(c.gpa);
    while (toks.next()) |t| try list.append(c.gpa, t);
    var rest: []const []const u8 = list.items;
    if (rest.len == 0) return .{ .enabled = true };
    if (VcfTarget.parse(rest[0])) |target| {
        out.target = target;
        rest = rest[1..];
        if (rest.len == 0) return c.rejectStatic(usage);
    }
    if (rest.len == 1 and std.ascii.eqlIgnoreCase(rest[0], "off")) {
        out.enabled = false;
        if (out.target == null) out.target = .all;
        return out;
    }

    var has_named = false;
    for (rest) |tok| {
        if (isVcfNamedToken(tok)) has_named = true;
    }

    if (!has_named) {
        out.enabled = true;
        out.cutoff_hz = try ValueChange.parseIn(c, rest[0], usage);
        if (rest.len > 1) out.resonance = try ValueChange.parseIn(c, rest[1], usage);
        if (rest.len > 2) out.drive = try ValueChange.parseIn(c, rest[2], usage);
        if (rest.len > 3) return c.rejectStatic(usage);
        return out;
    }

    var positional: [4][]const u8 = undefined;
    var npos: usize = 0;
    while (rest.len > 0) {
        if (isVcfNamedToken(rest[0])) break;
        positional[npos] = rest[0];
        npos += 1;
        rest = rest[1..];
        if (npos > 3) return c.rejectStatic(usage);
    }
    if (npos > 0) {
        out.enabled = true;
        out.cutoff_hz = try ValueChange.parseIn(c, positional[0], usage);
        if (npos > 1) out.resonance = try ValueChange.parseIn(c, positional[1], usage);
        if (npos > 2) out.drive = try ValueChange.parseIn(c, positional[2], usage);
    }

    var i: usize = 0;
    while (i < rest.len) {
        out.enabled = true;
        const tok = rest[i];
        var name: []const u8 = undefined;
        var value: []const u8 = undefined;
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            name = tok[0..eq];
            value = tok[eq + 1 ..];
        } else {
            name = tok;
            i += 1;
            if (i >= rest.len) {
                if (eqlAnyIgnoreCase(name, &.{ "drive", "drv" })) break;
                return c.rejectStatic(usage);
            }
            value = rest[i];
            if (eqlAnyIgnoreCase(name, &.{ "drive", "drv" }) and isVcfNamedToken(value)) continue;
        }
        if (eqlAnyIgnoreCase(name, &.{ "cut", "cutoff", "freq", "frequency" })) {
            out.cutoff_hz = try ValueChange.parseIn(c, value, usage);
        } else if (eqlAnyIgnoreCase(name, &.{ "res", "q", "reso", "resonance" })) {
            out.resonance = try ValueChange.parseIn(c, value, usage);
        } else if (eqlAnyIgnoreCase(name, &.{ "drive", "drv" })) {
            out.drive = try ValueChange.parseIn(c, value, usage);
        } else if (eqlAnyIgnoreCase(name, &.{ "wave", "wav", "shape" })) {
            out.wave = VcoWave.parse(value) orelse return c.rejectStatic(usage);
        } else {
            return c.rejectLower("unknown vcf parameter '{s}'", name);
        }
        i += 1;
    }
    return out;
}

/// Applies a stepped value change: a tick sets the step; +0 stops the tick; anything else changes
/// the value.
fn applyStepped(c: *Ctx, change: ?ValueChange, value: f32, step: *f32) Error!f32 {
    const ch = change orelse return value;
    switch (ch) {
        .tick => |s| {
            step.* = @floatCast(s);
            return value;
        },
        .add => |n| if (n == 0.0) {
            step.* = 0.0;
            return value;
        },
        else => {},
    }
    return switch (ch.apply(value)) {
        .ok => |v| @floatCast(v),
        .err => |m| c.rejectStatic(m),
    };
}

/// The rejection message is owned by the caller.
pub fn applyVcfChange(gpa: Allocator, bank: VcfBank, change: VcfChange) Allocator.Error!Result(VcfSettings) {
    var c: Ctx = .{ .gpa = gpa };
    return c.finish(VcfSettings, applyVcfChangeInner(&c, bank, change));
}

fn applyVcfChangeInner(c: *Ctx, bank: VcfBank, change: VcfChange) Error!VcfSettings {
    const target = change.target orelse bank.focus;
    const current = bank.get(target);
    var cutoff_step_per_tick = current.cutoff_step_per_tick;
    const cutoff_hz = try applyStepped(c, change.cutoff_hz, current.cutoff_hz, &cutoff_step_per_tick);
    if (!inRange(f32, cutoff_hz, 10.0, 22_000.0))
        return c.reject("vcf cutoff {f} Hz out of range 10..22000", .{rf(cutoff_hz)});

    var resonance_step_per_tick = current.resonance_step_per_tick;
    const resonance = try applyStepped(c, change.resonance, current.resonance, &resonance_step_per_tick);
    if (!inRange(f32, resonance, 0.0, 0.98))
        return c.reject("vcf resonance {f} out of range 0..0.98", .{rf(resonance)});

    var drive_step_per_tick = current.drive_step_per_tick;
    const drive = try applyStepped(c, change.drive, current.drive, &drive_step_per_tick);
    if (!inRange(f32, drive, 0.1, 12.0))
        return c.reject("vcf drive {f} out of range 0.1..12", .{rf(drive)});

    return .{
        .enabled = change.enabled orelse current.enabled,
        .target = target,
        .cutoff_hz = cutoff_hz,
        .resonance = resonance,
        .drive = drive,
        .cutoff_step_per_tick = cutoff_step_per_tick,
        .resonance_step_per_tick = resonance_step_per_tick,
        .drive_step_per_tick = drive_step_per_tick,
        .wave = if (target == .all)
            current.wave
        else if (target == .mic)
            .mic
        else
            change.wave orelse current.wave,
    };
}

// ── fx ────────────────────────────────────────────────────────────────────────

fn parseFxChange(c: *Ctx, input: []const u8) Error!FxChange {
    const usage = "usage: flanger ... | chorus ... | reverb ... | delay ... | cab <vintage|modern|open> [mix=<0..1>] | cab off | fx off";
    var toks = Tokens.init(input);
    const head = toks.next() orelse "";
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(c.gpa);
    while (toks.next()) |t| try list.append(c.gpa, t);
    const rest = list.items;
    var out: FxChange = .{};

    if (std.ascii.eqlIgnoreCase(head, "fx")) {
        if (rest.len == 1 and std.ascii.eqlIgnoreCase(rest[0], "off")) {
            out.flanger_enabled = false;
            out.chorus_enabled = false;
            out.reverb_enabled = false;
            out.delay_enabled = false;
            out.cabinet_enabled = false;
            return out;
        }
        return c.rejectStatic(usage);
    }

    const is_flanger = eqlAnyIgnoreCase(head, &.{ "flanger", "flange" });
    const is_chorus = eqlAnyIgnoreCase(head, &.{ "chorus", "choir" });
    const is_reverb = eqlAnyIgnoreCase(head, &.{ "reverb", "rev" });
    const is_delay = eqlAnyIgnoreCase(head, &.{ "delay", "pingpong" });
    const is_cabinet = eqlAnyIgnoreCase(head, &.{ "cab", "cabinet" });
    if (!is_flanger and !is_chorus and !is_reverb and !is_delay and !is_cabinet) return c.rejectStatic(usage);

    const setEnabled = struct {
        fn f(o: *FxChange, fl: bool, ch: bool, rv: bool, dl: bool, on: bool) void {
            if (fl) {
                o.flanger_enabled = on;
            } else if (ch) {
                o.chorus_enabled = on;
            } else if (rv) {
                o.reverb_enabled = on;
            } else if (dl) {
                o.delay_enabled = on;
            } else {
                o.cabinet_enabled = on;
            }
        }
    }.f;
    if (rest.len == 1 and std.ascii.eqlIgnoreCase(rest[0], "off")) {
        setEnabled(&out, is_flanger, is_chorus, is_reverb, is_delay, false);
        return out;
    }
    if (rest.len == 0 or (rest.len == 1 and std.ascii.eqlIgnoreCase(rest[0], "on"))) {
        setEnabled(&out, is_flanger, is_chorus, is_reverb, is_delay, true);
        return out;
    }
    setEnabled(&out, is_flanger, is_chorus, is_reverb, is_delay, true);

    var i: usize = 0;
    // A cabinet's first word may name its model (case-sensitive "mix" is a parameter, as upstream).
    if (is_cabinet and std.mem.indexOfScalar(u8, rest[0], '=') == null and !std.mem.eql(u8, rest[0], "mix")) {
        out.cabinet_model = fx.CabinetModel.parse(rest[0]) orelse
            return c.reject("unknown cabinet '{s}'; use vintage, modern, or open", .{rest[0]});
        i = 1;
    }
    while (i < rest.len) {
        const tok = rest[i];
        var name: []const u8 = undefined;
        var value: []const u8 = undefined;
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            name = tok[0..eq];
            value = tok[eq + 1 ..];
        } else {
            name = tok;
            i += 1;
            if (i >= rest.len) return c.rejectStatic(usage);
            value = rest[i];
        }
        const change = try ValueChange.parseIn(c, value, usage);
        const is = struct {
            fn f(n: []const u8, comptime words: []const []const u8) bool {
                return eqlAnyIgnoreCase(n, words);
            }
        }.f;
        if (is_flanger and is(name, &.{ "rate", "hz", "speed" })) {
            out.flanger_rate_hz = change;
        } else if (is_flanger and is(name, &.{ "depth", "width" })) {
            out.flanger_depth = change;
        } else if (is_flanger and is(name, &.{ "delay", "time", "ms" })) {
            out.flanger_delay_ms = change;
        } else if (is_flanger and is(name, &.{ "feedback", "fb", "regen" })) {
            out.flanger_feedback = change;
        } else if (is_flanger and is(name, &.{"mix"})) {
            out.flanger_mix = change;
        } else if (is_chorus and is(name, &.{ "rate", "hz", "speed" })) {
            out.chorus_rate_hz = change;
        } else if (is_chorus and is(name, &.{ "depth", "width" })) {
            out.chorus_depth = change;
        } else if (is_chorus and is(name, &.{ "delay", "time", "ms" })) {
            out.chorus_delay_ms = change;
        } else if (is_chorus and is(name, &.{"mix"})) {
            out.chorus_mix = change;
        } else if (is_reverb and is(name, &.{"mix"})) {
            out.reverb_mix = change;
        } else if (is_reverb and is(name, &.{ "decay", "room", "feedback" })) {
            out.reverb_decay = change;
        } else if (is_delay and is(name, &.{ "time", "t", "secs", "seconds" })) {
            out.delay_time_secs = change;
        } else if (is_delay and is(name, &.{ "feedback", "fb" })) {
            out.delay_feedback = change;
        } else if (is_delay and is(name, &.{"mix"})) {
            out.delay_mix = change;
        } else if (is_cabinet and is(name, &.{"mix"})) {
            out.cabinet_mix = change;
        } else {
            return c.rejectLower("unknown fx parameter '{s}'", name);
        }
        i += 1;
    }
    return out;
}

/// The rejection message is owned by the caller.
pub fn applyFxChange(gpa: Allocator, current: FxSettings, change: FxChange) Allocator.Error!Result(FxSettings) {
    var c: Ctx = .{ .gpa = gpa };
    return c.finish(FxSettings, applyFxChangeInner(&c, current, change));
}

fn applyFxValue(c: *Ctx, value: *f32, step: *f32, change: ?ValueChange) Error!void {
    value.* = try applyStepped(c, change, value.*, step);
}

fn applyFxChangeInner(c: *Ctx, current: FxSettings, change: FxChange) Error!FxSettings {
    var next = current;
    if (change.flanger_enabled) |e| next.flanger_enabled = e;
    if (change.chorus_enabled) |e| next.chorus_enabled = e;
    if (change.reverb_enabled) |e| next.reverb_enabled = e;
    if (change.delay_enabled) |e| next.delay_enabled = e;
    if (change.cabinet_enabled) |e| next.cabinet_enabled = e;
    if (change.cabinet_model) |m| next.cabinet_model = m;
    try applyFxValue(c, &next.flanger_rate_hz, &next.flanger_rate_step_per_tick, change.flanger_rate_hz);
    try applyFxValue(c, &next.flanger_depth, &next.flanger_depth_step_per_tick, change.flanger_depth);
    try applyFxValue(c, &next.flanger_delay_ms, &next.flanger_delay_step_per_tick, change.flanger_delay_ms);
    try applyFxValue(c, &next.flanger_feedback, &next.flanger_feedback_step_per_tick, change.flanger_feedback);
    try applyFxValue(c, &next.flanger_mix, &next.flanger_mix_step_per_tick, change.flanger_mix);
    try applyFxValue(c, &next.chorus_rate_hz, &next.chorus_rate_step_per_tick, change.chorus_rate_hz);
    try applyFxValue(c, &next.chorus_depth, &next.chorus_depth_step_per_tick, change.chorus_depth);
    try applyFxValue(c, &next.chorus_delay_ms, &next.chorus_delay_step_per_tick, change.chorus_delay_ms);
    try applyFxValue(c, &next.chorus_mix, &next.chorus_mix_step_per_tick, change.chorus_mix);
    try applyFxValue(c, &next.reverb_mix, &next.reverb_mix_step_per_tick, change.reverb_mix);
    try applyFxValue(c, &next.reverb_decay, &next.reverb_decay_step_per_tick, change.reverb_decay);
    try applyFxValue(c, &next.delay_time_secs, &next.delay_time_step_per_tick, change.delay_time_secs);
    try applyFxValue(c, &next.delay_feedback, &next.delay_feedback_step_per_tick, change.delay_feedback);
    try applyFxValue(c, &next.delay_mix, &next.delay_mix_step_per_tick, change.delay_mix);
    // The cabinet mix has no per-tick step; a step is computed and dropped, as upstream.
    var unused_cabinet_step: f32 = 0.0;
    try applyFxValue(c, &next.cabinet_mix, &unused_cabinet_step, change.cabinet_mix);
    return validateFx(c, next);
}

fn validateFx(c: *Ctx, n: FxSettings) Error!FxSettings {
    if (!inRange(f32, n.flanger_rate_hz, 0.01, 8.0))
        return c.reject("flanger rate {f}Hz out of range 0.01..8", .{rf(n.flanger_rate_hz)});
    if (!inRange(f32, n.flanger_depth, 0.0, 1.0))
        return c.reject("flanger depth {f} out of range 0..1", .{rf(n.flanger_depth)});
    if (!inRange(f32, n.flanger_delay_ms, 0.1, 10.0))
        return c.reject("flanger delay {f}ms out of range 0.1..10", .{rf(n.flanger_delay_ms)});
    if (!inRange(f32, n.flanger_feedback, -0.95, 0.95))
        return c.reject("flanger feedback {f} out of range -0.95..0.95", .{rf(n.flanger_feedback)});
    if (!inRange(f32, n.flanger_mix, 0.0, 1.0))
        return c.reject("flanger mix {f} out of range 0..1", .{rf(n.flanger_mix)});
    if (!inRange(f32, n.chorus_rate_hz, 0.01, 8.0))
        return c.reject("chorus rate {f}Hz out of range 0.01..8", .{rf(n.chorus_rate_hz)});
    if (!inRange(f32, n.chorus_depth, 0.0, 1.0))
        return c.reject("chorus depth {f} out of range 0..1", .{rf(n.chorus_depth)});
    if (!inRange(f32, n.chorus_delay_ms, 5.0, 35.0))
        return c.reject("chorus delay {f}ms out of range 5..35", .{rf(n.chorus_delay_ms)});
    if (!inRange(f32, n.chorus_mix, 0.0, 1.0))
        return c.reject("chorus mix {f} out of range 0..1", .{rf(n.chorus_mix)});
    if (!inRange(f32, n.reverb_mix, 0.0, 1.0))
        return c.reject("reverb mix {f} out of range 0..1", .{rf(n.reverb_mix)});
    if (!inRange(f32, n.reverb_decay, 0.0, 0.98))
        return c.reject("reverb decay {f} out of range 0..0.98", .{rf(n.reverb_decay)});
    if (!inRange(f32, n.delay_time_secs, 0.01, 2.0))
        return c.reject("delay time {f}s out of range 0.01..2", .{rf(n.delay_time_secs)});
    if (!inRange(f32, n.delay_feedback, 0.0, 0.95))
        return c.reject("delay feedback {f} out of range 0..0.95", .{rf(n.delay_feedback)});
    if (!inRange(f32, n.delay_mix, 0.0, 1.0))
        return c.reject("delay mix {f} out of range 0..1", .{rf(n.delay_mix)});
    if (!inRange(f32, n.cabinet_mix, 0.0, 1.0))
        return c.reject("cabinet mix {f} out of range 0..1", .{rf(n.cabinet_mix)});
    return n;
}

// ── Tests (command.rs has no #[test]s; these are the port's own) ──────────────

const testing = std.testing;
const ta = testing.allocator;

fn ok(line: []const u8) !ParseResult {
    const r = try parse(ta, line);
    if (r == .err) {
        std.debug.print("unexpected rejection of '{s}': {s}\n", .{ line, r.err });
        r.deinit(ta);
        return error.TestUnexpectedResult;
    }
    return r;
}

fn expectErr(line: []const u8, msg: []const u8) !void {
    const r = try parse(ta, line);
    defer r.deinit(ta);
    switch (r) {
        .ok => |c| {
            std.debug.print("expected rejection of '{s}', got {s}\n", .{ line, @tagName(c) });
            return error.TestUnexpectedResult;
        },
        .err => |m| try testing.expectEqualStrings(msg, m),
    }
}

fn expectTag(line: []const u8, tag: std.meta.Tag(Cmd)) !void {
    const r = try ok(line);
    defer r.deinit(ta);
    try testing.expectEqual(tag, std.meta.activeTag(r.ok));
}

fn expectVc(expected: ValueChange, actual: ?ValueChange) !void {
    try testing.expect(actual != null);
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual.?));
    const a = switch (actual.?) {
        inline else => |v| v,
    };
    const e = switch (expected) {
        inline else => |v| v,
    };
    try testing.expectEqual(e, a);
}

test "rust number grammar" {
    try testing.expectEqual(@as(?f64, 1.5), parseFloatRust(f64, "+1.5"));
    try testing.expectEqual(@as(?f64, 0.5), parseFloatRust(f64, ".5"));
    try testing.expectEqual(@as(?f64, 1.0), parseFloatRust(f64, "1."));
    try testing.expectEqual(@as(?f64, 1000.0), parseFloatRust(f64, "1E3"));
    try testing.expectEqual(@as(?f64, -std.math.inf(f64)), parseFloatRust(f64, "-Infinity"));
    try testing.expect(std.math.isNan(parseFloatRust(f32, "NaN").?));
    for ([_][]const u8{ "", ".", "+", "1e", "0x10", "1_0", "1.2.3", " 1", "e5", "infx" }) |s| {
        try testing.expect(parseFloatRust(f64, s) == null);
    }
    try testing.expectEqual(@as(?isize, -3), parseIntRust(isize, "-3"));
    try testing.expectEqual(@as(?usize, 3), parseIntRust(usize, "+3"));
    try testing.expect(parseIntRust(usize, "-0") == null);
    try testing.expect(parseIntRust(u32, "1_0") == null);
    try testing.expect(parseIntRust(u32, "99999999999") == null);
    try testing.expect(parseIntRust(isize, "+") == null);
}

test "rust float display" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("12", try std.fmt.bufPrint(&buf, "{f}", .{rf(@as(f32, 12.0))}));
    try testing.expectEqualStrings("0.99", try std.fmt.bufPrint(&buf, "{f}", .{rf(@as(f32, 0.99))}));
    try testing.expectEqualStrings("NaN", try std.fmt.bufPrint(&buf, "{f}", .{rf(std.math.nan(f32))}));
    try testing.expectEqualStrings("-inf", try std.fmt.bufPrint(&buf, "{f}", .{rf(-std.math.inf(f32))}));
}

test "unicode whitespace splits like rust" {
    var it = Tokens.init("bpm\u{00A0}120\u{3000} x");
    try testing.expectEqualStrings("bpm", it.next().?);
    try testing.expectEqualStrings("120", it.next().?);
    try testing.expectEqualStrings("x", it.next().?);
    try testing.expect(it.next() == null);
    try testing.expectEqualStrings("a b", trim("\u{2003} a b\u{85}\t"));
    const r = try ok("bpm\u{00A0}120");
    defer r.deinit(ta);
    try expectVc(.{ .set = 120 }, r.ok.set_bpm);
}

test "keywords and transport" {
    try expectTag("q", .quit);
    try expectTag("quit", .quit);
    try expectTag("?", .help);
    try expectTag("help", .help);
    try expectTag("  clear  ", .clear);
    try expectTag("rot", .rotate);
    try expectTag("stop", .stop);
    try expectTag("ls", .list_jins);
    try expectErr("", "empty");
    try expectErr("   ", "empty");
    {
        const r = try ok("tambura off");
        defer r.deinit(ta);
        try testing.expectEqual(false, r.ok.sympathetics);
    }
    {
        const r = try ok("start");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?isize, START_REF), r.ok.toggle_pause.start_id);
    }
    {
        const r = try ok("pause");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?isize, null), r.ok.toggle_pause.start_id);
    }
    const records = [_]struct { []const u8, usize }{
        .{ "m", 1 }, .{ "m3", 3 }, .{ "m 4", 4 }, .{ "M2", 2 }, .{ "m0", 1 }, .{ "mic", 1 }, .{ "m x", 1 },
    };
    for (records) |e| {
        const r = try ok(e[0]);
        defer r.deinit(ta);
        try testing.expectEqual(e[1], r.ok.record);
    }
    // "ma..." is not a record command; it falls through to a phrase.
    try expectErr("major", "unknown pitch 'major'");
    {
        const r = try ok("z");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?isize, null), r.ok.toggle_pause.start_id);
    }
    {
        const r = try ok("z 3");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?isize, 3), r.ok.toggle_pause.start_id);
    }
    {
        const r = try ok("z start");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?isize, START_REF), r.ok.toggle_pause.start_id);
    }
    try expectErr("z x", "usage: z [phrase-id]");
    try expectErr("z5x", "usage: z [phrase-id]");
}

test "llm prompts" {
    const r = try ok("Claude:  how do i set a vcf filter? ");
    defer r.deinit(ta);
    try testing.expectEqual(LlmProvider.claude, r.ok.ask_llm.provider);
    try testing.expectEqualStrings("how do i set a vcf filter?", r.ok.ask_llm.prompt);
    const r2 = try ok("gpt: a:b");
    defer r2.deinit(ta);
    try testing.expectEqual(LlmProvider.chat_gpt, r2.ok.ask_llm.provider);
    try testing.expectEqualStrings("a:b", r2.ok.ask_llm.prompt);
    try expectErr("openai:", "type a question after the colon, like chatgpt: how do i set a vcf filter?");
    try expectErr("foo: bar", "unknown pitch 'foo:'");
}

test "value forms" {
    const cases = [_]struct { []const u8, ValueChange }{
        .{ "bpm 120", .{ .set = 120 } },
        .{ "bpm +5", .{ .add = 5 } },
        .{ "bpm -5", .{ .add = -5 } },
        .{ "bpm *2", .{ .mul = 2 } },
        .{ "bpm /2", .{ .div = 2 } },
        .{ "bpm +2t", .{ .tick = 2 } },
        .{ "bpm -0.5t", .{ .tick = -0.5 } },
        .{ "bpm 3t", .{ .tick = 3 } },
        .{ "bpm +0", .{ .add = 0 } },
        .{ "bpm 5", .{ .set = 5 } },
    };
    for (cases) |e| {
        const r = try ok(e[0]);
        defer r.deinit(ta);
        try expectVc(e[1], r.ok.set_bpm);
    }
    const u = "usage: bpm <tempo|*k|/k|+n|-n>";
    try expectErr("bpm", u);
    try expectErr("bpm x", u);
    try expectErr("bpm t", u);
    try expectErr("bpm 1.", u); // as upstream: "." after the first byte does not parse
    try expectErr("bpm 1_0", u);
    try expectErr("bpm 0x10", u);
    try expectErr("bpm é", u); // the Rust panics here
    try expectErr("bpm +", u);
    const s = try ok("sus *2");
    defer s.deinit(ta);
    try expectVc(.{ .mul = 2 }, s.ok.set_sustain);
    try expectErr("s", "usage: s <secs|*k|/k|+n|-n>");
    try expectErr("s1", "unknown pitch 's1'");
    try testing.expectEqual(@as(f64, 50.0), (ValueChange{ .div = 2 }).apply(100).ok);
    try testing.expectEqualStrings("division by zero", (ValueChange{ .div = 0 }).apply(100).err);
    try testing.expectEqual(@as(f64, 100.0), (ValueChange{ .tick = 9 }).apply(100).ok);
    const pt = try ValueChange.parseToken(ta, "*1.5", "usage");
    try testing.expectEqual(@as(f64, 1.5), pt.ok.mul);
}

test "tuneto" {
    const r = try ok("tuneto b-");
    defer r.deinit(ta);
    try testing.expect(r.ok.tune_to.eql(.{ .letter = 'b', .accidental = -1, .octave = 4 }));
    try expectErr("tuneto", "type a pitch after tuneto, like tuneto c or tuneto b-");
    try expectErr("tuneto x", "unknown pitch 'x'; type a pitch like c, d, a, or b- after tuneto");
}

test "jumps" {
    const Case = struct { []const u8, isize, ?isize, usize };
    const cases = [_]Case{
        .{ "j 3", 3, null, 1 },
        .{ "j3 2", 3, null, 2 },
        .{ "j start always", START_REF, null, 0 },
        .{ "j 2 Forever", 2, null, 0 },
        .{ "j 2 ∞", 2, null, 0 },
        .{ "j 1 else 4 3", 1, 4, 3 },
        .{ "j1 ELSE -2", 1, -2, 1 },
    };
    for (cases) |e| {
        const r = try ok(e[0]);
        defer r.deinit(ta);
        try testing.expectEqual(e[1], r.ok.jump.to);
        try testing.expectEqual(e[2], r.ok.jump.fail_to);
        try testing.expectEqual(e[3], r.ok.jump.times);
    }
    try expectErr("j", "usage: j <pos> [times]");
    try expectErr("j x", "usage: j <pos> [times]");
    try expectErr("j 1 else", "usage: j <success> else <fail> [times]");
    try expectErr("j 1 else start", "bad jump failure address");
    try expectErr("j 1 abc", "jump times must be a number or `always`");
    try expectErr("j 1 -1", "jump times must be a number or `always`");
}

test "edit and insert" {
    {
        const r = try ok("edit 2 d bayati 44");
        defer r.deinit(ta);
        try testing.expectEqual(@as(isize, 2), r.ok.edit.id);
        try testing.expectEqualStrings("d bayati 44", r.ok.edit.source);
        try testing.expectEqualSlices(u8, &.{ 4, 4 }, r.ok.edit.specs[0].groups.?);
    }
    {
        const r = try ok("edit 2 bpm +3");
        defer r.deinit(ta);
        try expectVc(.{ .add = 3 }, r.ok.edit_bpm.change);
    }
    {
        const r = try ok("edit 4 nam import a.nam as amp");
        defer r.deinit(ta);
        try testing.expectEqualStrings("amp", r.ok.edit_nam.command.import.name.?);
    }
    {
        const r = try ok("edit -1 j 3 else 5 2");
        defer r.deinit(ta);
        try testing.expectEqual(@as(isize, -1), r.ok.edit_jump.id);
        try testing.expectEqual(@as(?isize, 5), r.ok.edit_jump.fail_to);
    }
    {
        const r = try ok("i3 d hijaz");
        defer r.deinit(ta);
        try testing.expectEqual(@as(isize, 3), r.ok.insert.before);
        try testing.expectEqualStrings("d hijaz", r.ok.insert.source);
    }
    {
        const r = try ok("i 3 j 1 2");
        defer r.deinit(ta);
        try testing.expectEqual(@as(isize, 3), r.ok.insert_jump.before);
        try testing.expectEqual(@as(usize, 2), r.ok.insert_jump.times);
    }
    {
        const r = try ok("i5 sym decay 0.995");
        defer r.deinit(ta);
        try testing.expectEqual(@as(f32, 0.995), r.ok.insert_sympathetic_decay.decay);
    }
    try expectErr("istart d hijaz", "unknown pitch 'istart'");
    try expectErr("i start bpm 90", "usage: i <pos> <phrase|j target times|bpm n|s n>");
    try expectErr("i3", "usage: i <pos> <phrase|j target times|bpm n|s n>");
    try expectErr("i3x bpm 1", "usage: i<pos> <phrase|j target times|bpm n|s n>");
    try expectErr("i 3 clear", "unsupported command after insert");
    try expectErr("i 3 bpm x", "usage: bpm <tempo|*k|/k|+n|-n>");
    try expectErr("edit 2 rot", "unsupported command after edit");
    try expectErr("edit x d bayati", "usage: edit <id> <phrase|j target [times]|bpm n|s n>");
    try expectErr("edit 2", "usage: edit <id> <phrase|j target [times]|bpm n|s n>");
    try expectErr("edit  2 bpm 3", "usage: edit <id> <phrase|j target [times]|bpm n|s n>"); // splitn on one char
    try expectErr("edit 1 edit 2 bpm 3", "unsupported command after edit");
    try expectErr("i 1 edit 2 bpm 3", "unsupported command after insert");
    // Deep nesting is rejected without unbounded recursion.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(ta);
    for (0..10_000) |_| try deep.appendSlice(ta, "edit 1 ");
    try deep.appendSlice(ta, "bpm 3");
    try expectErr(deep.items, "unsupported command after edit");
}

test "reorder and delete" {
    {
        const r = try ok("up 3");
        defer r.deinit(ta);
        try testing.expectEqual(@as(isize, 3), r.ok.move_up);
    }
    {
        const r = try ok("down -2");
        defer r.deinit(ta);
        try testing.expectEqual(@as(isize, -2), r.ok.move_down);
    }
    try expectErr("up", "usage: up <id>");
    try expectErr("down x", "usage: down <id>");
    {
        const r = try ok("x3 4 5");
        defer r.deinit(ta);
        try testing.expectEqualSlices(isize, &.{ 3, 4, 5 }, r.ok.delete_bars);
    }
    {
        const r = try ok("x 7");
        defer r.deinit(ta);
        try testing.expectEqualSlices(isize, &.{7}, r.ok.delete_bars);
    }
    try expectErr("x", "usage: x<N>");
    try expectErr("x 1 y", "bad id 'y'");
    try expectErr("x start", "bad id 'start'");
    try expectErr("x3y", "usage: x<N> [N …]");
}

test "vol" {
    const cases = [_]struct { []const u8, f32 }{ .{ "vol 1.5", 1.5 }, .{ "vol", 1.0 }, .{ "vol0.5", 0.5 }, .{ "vol 2", 2.0 } };
    for (cases) |e| {
        const r = try ok(e[0]);
        defer r.deinit(ta);
        try testing.expectEqual(e[1], r.ok.set_vol);
    }
    try expectErr("vol 3", "vol 3 out of range 0–2");
    try expectErr("vol -0.25", "vol -0.25 out of range 0–2");
    try expectErr("vol nan", "vol NaN out of range 0–2");
}

test "phrases" {
    {
        const r = try ok("d bayati");
        defer r.deinit(ta);
        const p = r.ok.add_phrase;
        try testing.expectEqual(@as(usize, 1), p.specs.len);
        try testing.expectEqual(@as(usize, 1), p.repeat);
        try testing.expect(p.specs[0].groups == null);
        try testing.expectEqualStrings("Bayati", p.specs[0].maqam.name());
        try testing.expectEqualStrings("d bayati", p.specs[0].src);
    }
    {
        const r = try ok("  b-5 hij 3302x2 R4 ");
        defer r.deinit(ta);
        const p = r.ok.add_phrase;
        try testing.expectEqualStrings("b-5 hij 3302x2 R4", p.source);
        try testing.expectEqual(@as(usize, 4), p.repeat);
        try testing.expect(p.specs[0].root.eql(.{ .letter = 'b', .accidental = -1, .octave = 5 }));
        try testing.expectEqualStrings("Hijaz", p.specs[0].maqam.name());
        try testing.expectEqualSlices(u8, &.{ 3, 3, 2, 2 }, p.specs[0].groups.?);
    }
    {
        const r = try ok("d bayati 4");
        defer r.deinit(ta);
        try testing.expectEqual(@as(usize, 4), r.ok.add_phrase.repeat);
        try testing.expect(r.ok.add_phrase.specs[0].groups == null);
    }
    {
        const r = try ok("d bayati 44");
        defer r.deinit(ta);
        try testing.expectEqual(@as(usize, 1), r.ok.add_phrase.repeat);
        try testing.expectEqualSlices(u8, &.{ 4, 4 }, r.ok.add_phrase.specs[0].groups.?);
    }
    {
        const r = try ok("d bayati 44 r0");
        defer r.deinit(ta);
        try testing.expectEqual(@as(usize, 1), r.ok.add_phrase.repeat);
    }
    {
        const r = try ok("d bayati, g hijaz 332 r16");
        defer r.deinit(ta);
        const p = r.ok.add_phrase;
        try testing.expectEqual(@as(usize, 2), p.specs.len);
        try testing.expectEqual(@as(usize, 16), p.repeat);
        try testing.expectEqualStrings("g hijaz 332", p.specs[1].src);
    }
    try expectErr("d xx", "unknown maqam 'xx'  (nah bay hij rast kurd saba ajam major minor modes)");
    try expectErr("d b", "unknown maqam 'b'  (nah bay hij rast kurd saba ajam major minor modes)");
    try expectErr("d bayati 0x0", "rhythm '0x0' must be non-zero digits");
    {
        // As upstream: a trailing number up to 20 is a repeat count, even "000" (repeat 1).
        const r = try ok("d bayati 000");
        defer r.deinit(ta);
        try testing.expectEqual(@as(usize, 1), r.ok.add_phrase.repeat);
        try testing.expect(r.ok.add_phrase.specs[0].groups == null);
    }
    try expectErr("d", "missing maqam");
    try expectErr("r4", "empty phrase");
    try expectErr("d bayati,", "missing pitch");
    try expectErr("h bayati", "unknown pitch 'h'");
}

test "jins management, audition, save and load" {
    {
        const r = try ok("create Foo 1/1 9/8 3/x 5");
        defer r.deinit(ta);
        try testing.expectEqualStrings("Foo", r.ok.create_jins.name);
        const want = [_]Ratio{ .{ .p = 1, .q = 1 }, .{ .p = 9, .q = 8 }, .{ .p = 3, .q = 1 }, .{ .p = 5, .q = 1 } };
        try testing.expectEqualSlices(Ratio, &want, r.ok.create_jins.ratios);
    }
    try expectErr("create Foo 1/0", "bad ratio '1/0'");
    try expectErr("create Foo -1/2", "bad ratio '-1/2'");
    try expectErr("create Foo", "need at least one ratio");
    try expectErr("create", "usage: create <Name> <ratios…>");
    {
        const r = try ok("delete Foo");
        defer r.deinit(ta);
        try testing.expectEqualStrings("Foo", r.ok.delete_jins.name);
    }
    try expectErr("delete", "usage: delete <Name>");
    {
        const r = try ok("audition bayati");
        defer r.deinit(ta);
        try testing.expectEqualStrings("d Bayati", r.ok.audition_jins.specs[0].src);
        try testing.expect(r.ok.audition_jins.specs[0].root.eql(.{ .letter = 'd', .accidental = 0, .octave = 4 }));
    }
    {
        const r = try ok("audition d hijaz, g rast");
        defer r.deinit(ta);
        try testing.expectEqual(@as(usize, 2), r.ok.audition_jins.specs.len);
    }
    try expectErr("audition zz", "unknown maqam 'zz'");
    try expectErr("audition", "usage: audition <Name> | audition <root> <Name> [, <root> <Name> ...]");
    try expectErr("audition d zz", "unknown maqam 'zz'  (nah bay hij rast kurd saba ajam major minor modes)");
    {
        const r = try ok("save");
        defer r.deinit(ta);
        try testing.expect(r.ok.save.path == null);
    }
    {
        const r = try ok("save  my song.mq ");
        defer r.deinit(ta);
        try testing.expectEqualStrings("my song.mq", r.ok.save.path.?);
    }
    {
        const r = try ok("load x.mq");
        defer r.deinit(ta);
        try testing.expectEqualStrings("x.mq", r.ok.load.path);
    }
    try expectErr("load", "usage: load <path>");
}

test "vcf parsing" {
    {
        const r = try ok("vcf");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?bool, true), r.ok.set_vcf.enabled);
        try testing.expect(r.ok.set_vcf.target == null);
    }
    {
        const r = try ok("vcf off");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?bool, false), r.ok.set_vcf.enabled);
        try testing.expectEqual(@as(?VcfTarget, .all), r.ok.set_vcf.target);
    }
    {
        const r = try ok("vcf mic OFF");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?bool, false), r.ok.set_vcf.enabled);
        try testing.expectEqual(@as(?VcfTarget, .mic), r.ok.set_vcf.target);
    }
    {
        const r = try ok("vcf 800 0.5 2");
        defer r.deinit(ta);
        const v = r.ok.set_vcf;
        try expectVc(.{ .set = 800 }, v.cutoff_hz);
        try expectVc(.{ .set = 0.5 }, v.resonance);
        try expectVc(.{ .set = 2 }, v.drive);
    }
    {
        const r = try ok("vcf all cut=+100 res=-0.1 drive=*1.5 wave=saw");
        defer r.deinit(ta);
        const v = r.ok.set_vcf;
        try expectVc(.{ .add = 100 }, v.cutoff_hz);
        try expectVc(.{ .add = -0.1 }, v.resonance);
        try expectVc(.{ .mul = 1.5 }, v.drive);
        try testing.expectEqual(@as(?VcoWave, .saw), v.wave);
    }
    {
        const r = try ok("vcf kanun 500 cut 900 drive");
        defer r.deinit(ta);
        try expectVc(.{ .set = 900 }, r.ok.set_vcf.cutoff_hz);
        try testing.expect(r.ok.set_vcf.drive == null);
    }
    {
        const r = try ok("vcf bass drive cut 900");
        defer r.deinit(ta);
        try expectVc(.{ .set = 900 }, r.ok.set_vcf.cutoff_hz);
        try testing.expect(r.ok.set_vcf.drive == null);
    }
    {
        const r = try ok("drv +2t");
        defer r.deinit(ta);
        try expectVc(.{ .tick = 2 }, r.ok.set_vcf.drive);
        try testing.expectEqual(@as(?bool, true), r.ok.set_vcf.enabled);
    }
    {
        const r = try ok("q 0.5");
        defer r.deinit(ta);
        try expectVc(.{ .set = 0.5 }, r.ok.set_vcf.resonance);
    }
    const u = "usage: vcf [all|mic|bass|kanun|drums|kick|sym] <cutoff> [res] [drive] | vcf [target] off | vcf <target> cut=<hz|+n|-n|+nt> res=<0..1|+n|-n|+nt> drive=<n|+n|-n|+nt> wave=<sin|tri|squ|saw|mic> | cut <hz> | res <0..1> | drive <n>";
    try expectErr("vcf 1 2 3 4", u);
    try expectErr("vcf 1 2 3 4 cut 5", u);
    try expectErr("vcf all", u);
    try expectErr("filter all", u);
    try expectErr("cut", u);
    try expectErr("vcf all cut", u);
    try expectErr("vcf all wave=xyz", u);
    try expectErr("vcf all FOO=3", "unknown vcf parameter 'foo'");
    try expectErr("vcf all cut 800 900", u);
}

test "vcf application" {
    const bank: VcfBank = .{};
    const parsed = try ok("vcf kanun cut=+100 res=+0.1t wave=tri");
    defer parsed.deinit(ta);
    const s = (try applyVcfChange(ta, bank, parsed.ok.set_vcf)).ok;
    try testing.expectEqual(@as(f32, 1300), s.cutoff_hz);
    try testing.expectEqual(@as(f32, 0.35), s.resonance);
    try testing.expectEqual(@as(f32, 0.1), s.resonance_step_per_tick);
    try testing.expectEqual(VcoWave.tri, s.wave);
    try testing.expectEqual(VcfTarget.kanun, s.target);
    try testing.expect(s.enabled);

    var b2 = bank;
    b2.apply(s);
    const stop = (try applyVcfChange(ta, b2, .{ .resonance = .{ .add = -0.0 } })).ok; // +0 stops a tick
    try testing.expectEqual(@as(f32, 0.0), stop.resonance_step_per_tick);
    try testing.expectEqual(VcfTarget.kanun, stop.target); // focus

    const mic = (try applyVcfChange(ta, bank, .{ .target = .mic, .wave = .saw })).ok;
    try testing.expectEqual(VcoWave.mic, mic.wave);
    const all = (try applyVcfChange(ta, bank, .{ .target = .all, .wave = .saw })).ok;
    try testing.expectEqual(VcoWave.sin, all.wave);

    const cases = [_]struct { VcfChange, []const u8 }{
        .{ .{ .cutoff_hz = .{ .set = 30000 } }, "vcf cutoff 30000 Hz out of range 10..22000" },
        .{ .{ .cutoff_hz = .{ .div = 0 } }, "division by zero" },
        .{ .{ .resonance = .{ .set = 0.99 } }, "vcf resonance 0.99 out of range 0..0.98" },
        .{ .{ .drive = .{ .mul = 10 } }, "vcf drive 15 out of range 0.1..12" },
        .{ .{ .cutoff_hz = .{ .set = std.math.nan(f64) } }, "vcf cutoff NaN Hz out of range 10..22000" },
    };
    for (cases) |e| {
        const res = try applyVcfChange(ta, bank, e[0]);
        defer ta.free(res.err);
        try testing.expectEqualStrings(e[1], res.err);
    }
}

test "fx parsing and application" {
    {
        const r = try ok("flanger");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?bool, true), r.ok.set_fx.flanger_enabled);
    }
    {
        const r = try ok("rev off");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?bool, false), r.ok.set_fx.reverb_enabled);
    }
    {
        const r = try ok("fx off");
        defer r.deinit(ta);
        const f = r.ok.set_fx;
        try testing.expect(f.flanger_enabled.? == false and f.chorus_enabled.? == false and
            f.reverb_enabled.? == false and f.delay_enabled.? == false);
    }
    {
        const r = try ok("reverb mix=0.5 decay 0.7");
        defer r.deinit(ta);
        try expectVc(.{ .set = 0.5 }, r.ok.set_fx.reverb_mix);
        try expectVc(.{ .set = 0.7 }, r.ok.set_fx.reverb_decay);
        try testing.expectEqual(@as(?bool, true), r.ok.set_fx.reverb_enabled);
    }
    {
        const r = try ok("pingpong time 0.5 FB=0.3 mix +0.1t");
        defer r.deinit(ta);
        try expectVc(.{ .set = 0.5 }, r.ok.set_fx.delay_time_secs);
        try expectVc(.{ .set = 0.3 }, r.ok.set_fx.delay_feedback);
        try expectVc(.{ .tick = 0.1 }, r.ok.set_fx.delay_mix);
    }
    const u = "usage: flanger ... | chorus ... | reverb ... | delay ... | cab <vintage|modern|open> [mix=<0..1>] | cab off | fx off";
    try expectErr("fx", u);
    try expectErr("fx on", u);
    try expectErr("chorus rate", u);
    try expectErr("chorus rate=abc", u);
    try expectErr("delay Delay 3", "unknown fx parameter 'delay'");
    try expectErr("chorus feedback 0.2", "unknown fx parameter 'feedback'");

    const base: FxSettings = .{};
    const p = try ok("flanger rate +2t depth=*0.5");
    defer p.deinit(ta);
    const next = (try applyFxChange(ta, base, p.ok.set_fx)).ok;
    try testing.expect(next.flanger_enabled);
    try testing.expectEqual(@as(f32, 2.0), next.flanger_rate_step_per_tick);
    try testing.expectEqual(@as(f32, 0.375), next.flanger_depth);
    const stopped = (try applyFxChange(ta, next, .{ .flanger_rate_hz = .{ .add = 0 } })).ok;
    try testing.expectEqual(@as(f32, 0.0), stopped.flanger_rate_step_per_tick);

    const cases = [_]struct { FxChange, []const u8 }{
        .{ .{ .reverb_decay = .{ .set = 0.99 } }, "reverb decay 0.99 out of range 0..0.98" },
        .{ .{ .flanger_rate_hz = .{ .set = 9 } }, "flanger rate 9Hz out of range 0.01..8" },
        .{ .{ .flanger_delay_ms = .{ .set = 11 } }, "flanger delay 11ms out of range 0.1..10" },
        .{ .{ .flanger_feedback = .{ .set = -1 } }, "flanger feedback -1 out of range -0.95..0.95" },
        .{ .{ .chorus_delay_ms = .{ .set = 4 } }, "chorus delay 4ms out of range 5..35" },
        .{ .{ .delay_time_secs = .{ .set = 3 } }, "delay time 3s out of range 0.01..2" },
        .{ .{ .delay_feedback = .{ .set = 0.96 } }, "delay feedback 0.96 out of range 0..0.95" },
        .{ .{ .delay_mix = .{ .div = 0 } }, "division by zero" },
    };
    for (cases) |e| {
        const res = try applyFxChange(ta, base, e[0]);
        defer ta.free(res.err);
        try testing.expectEqualStrings(e[1], res.err);
    }
}

test "sym parsing" {
    {
        const r = try ok("sym decay 0.995");
        defer r.deinit(ta);
        try testing.expectEqual(@as(f32, 0.995), r.ok.sympathetic_decay);
    }
    {
        const r = try ok("tanbura gain 4");
        defer r.deinit(ta);
        try testing.expectEqual(@as(f32, 4), r.ok.sympathetic_gain);
    }
    {
        const r = try ok("sym  off");
        defer r.deinit(ta);
        try testing.expectEqual(false, r.ok.sympathetics);
    }
    {
        const r = try ok("sym on harmony root");
        defer r.deinit(ta);
        try testing.expectEqual(true, r.ok.sympathetics);
    }
    {
        const r = try ok("sym mic decay 0.995 drive 3 amount 1");
        defer r.deinit(ta);
        const s = r.ok.sympathetic;
        try testing.expectEqual(@as(?SympatheticTarget, .mic), s.target);
        try testing.expectEqual(@as(?f32, 0.995), s.decay);
        try testing.expectEqual(@as(?f32, 3), s.gain);
        try testing.expectEqual(@as(?f32, 1), s.amount);
    }
    {
        const r = try ok("sym kanun 0.5 bass 0.5");
        defer r.deinit(ta);
        const s = r.ok.sympathetic;
        try testing.expect(s.target == null);
        try testing.expectEqual(@as(?f32, 0.5), s.kanun);
        try testing.expectEqual(@as(?f32, 0.5), s.bass);
    }
    {
        const r = try ok("sym up fifth");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?f64, 1.5), r.ok.sympathetic.interval_ratio);
    }
    {
        const r = try ok("sym down Octave");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?f64, 0.5), r.ok.sympathetic.interval_ratio);
    }
    {
        const r = try ok("sym interval 3/2");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?f64, 1.5), r.ok.sympathetic.interval_ratio);
    }
    {
        const r = try ok("sym transpose major-third");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?f64, 1.25), r.ok.sympathetic.interval_ratio);
    }
    {
        const r = try ok("sym mic harmony root 0.5 third 0.25 fifth 0.25 amount 2");
        defer r.deinit(ta);
        try testing.expectEqual(@as(?SympatheticTarget, .mic), r.ok.sympathetic.target);
        const h = r.ok.sympathetic.harmony.?;
        try testing.expectEqual(@as(usize, 3), h.len);
        try testing.expectEqual(@as(f64, 1.2), h.items()[1].ratio);
        try testing.expectEqual(@as(f32, 0.25), h.items()[2].weight);
        try testing.expectEqual(@as(?f32, 2), r.ok.sympathetic.amount);
    }
    {
        // A source name is not a harmony interval (as upstream).
        try expectErr("sym harmony root drums 2", "usage: sym [all|mic|kanun|bass|drums] [on|off] [decay <0.9..0.99999>] [drive <0..512>] [up|down <interval>] [interval <ratio>] [amount <0..512>] [mic <0..512>] [kanun <0..512>] [bass <0..512>] [drums <0..512>]");
    }
    {
        // As upstream: a lone decay wins even with a harmony on the line.
        const r = try ok("sym harmony root third decay 0.999");
        defer r.deinit(ta);
        try testing.expectEqual(@as(f32, 0.999), r.ok.sympathetic_decay);
    }
    const u = "usage: sym [all|mic|kanun|bass|drums] [on|off] [decay <0.9..0.99999>] [drive <0..512>] [up|down <interval>] [interval <ratio>] [amount <0..512>] [mic <0..512>] [kanun <0..512>] [bass <0..512>] [drums <0..512>]";
    try expectErr("sym gain 600", "sym gain out of range 0..512");
    try expectErr("sym decay 0.5", "sym decay out of range 0.9..0.99999");
    try expectErr("sym decay", u);
    try expectErr("sym decay x", u);
    try expectErr("sym bogus", u);
    try expectErr("sym interval 3/0", "sym interval ratio cannot divide by zero");
    try expectErr("sym interval 5", "sym interval ratio out of range 1/4..4/1");
    try expectErr("sym up ninth", u);
    try expectErr("sym harmony", u);
    try expectErr("sym harmony root 600", "sym harmony weight out of range 0..512");
    try expectErr("sym harmony root third fourth fifth sixth seventh octave second minor-third", "sym harmony can contain at most 8 intervals");
}

test "nam parsing" {
    const u = "usage: nam <cached-name|FILENAME.nam|URL> | nam import <FILENAME.nam|URL> [as name] | nam ls | nam off | nam gain <0..100>";
    try expectErr("nam", u);
    try expectErr("nam   ", u);
    const simple = [_]struct { []const u8, NamCommand }{
        .{ "nam login", .login },
        .{ "nam LOGOUT", .logout },
        .{ "nam off", .off },
        .{ "nam list", .list },
        .{ "nam gain 3", .{ .gain = 3 } },
        .{ "nam drive 11", .{ .gain = 11 } },
        .{ "nam input l", .{ .input = .left } },
        .{ "nam in Both", .{ .input = .stereo } },
        .{ "nam latency", .{ .latency = .left } },
        .{ "nam latency 2", .{ .latency = .right } },
        .{ "nam metallica", .{ .load = .{ .path = "metallica" } } },
        .{ "nam my amp.nam", .{ .load = .{ .path = "my amp.nam" } } },
        .{ "nam load  x.nam ", .{ .load = .{ .path = "x.nam" } } },
        .{ "nam import a.nam as amp", .{ .import = .{ .path = "a.nam", .name = "amp" } } },
        .{ "nam pull https://e.com/a.nam", .{ .import = .{ .path = "https://e.com/a.nam", .name = null } } },
        .{ "nam pin http://x/y.nam as y z", .{ .pin = .{ .url = "http://x/y.nam", .name = "y z" } } },
        .{ "nam tone3000 123 AS amp", .{ .tone3000 = .{ .tone_id = 123, .name = "amp" } } },
        .{ "nam search Fender clean  A2", .{ .search = .{ .query = "Fender clean  A2" } } },
    };
    for (simple) |e| {
        const r = try ok(e[0]);
        defer r.deinit(ta);
        try testing.expect(r.ok.set_nam.eql(e[1]));
    }
    try expectErr("nam load", "usage: nam load <model.nam|cached-name|URL>; type a .nam path, cached name, or URL after nam load");
    try expectErr("nam import", "usage: nam import <FILENAME.nam|URL> [as name]; type a real .nam file name or URL after nam import");
    {
        const r = try ok("nam import x as  y as");
        defer r.deinit(ta);
        try testing.expectEqualStrings("y as", r.ok.set_nam.import.name.?);
    }
    try expectErr("nam pin ftp://x as y", "nam pin requires a direct http(s) model URL");
    try expectErr("nam pin http://x", "usage: nam pin <direct-.nam-URL> as <name>");
    try expectErr("nam pin", "usage: nam pin <direct-.nam-URL> as <name>");
    try expectErr("nam t3k abc as amp", "TONE3000 tone ID must be a number");
    try expectErr("nam tone3000 1 2", "usage: nam tone3000 <tone-id> as <name>");
    try expectErr("nam gain 101", "NAM gain 101 out of range 0..100; use nam gain <0..100>");
    try expectErr("nam gain -1", "NAM gain -1 out of range 0..100; use nam gain <0..100>");
    try expectErr("nam gain x", "bad NAM gain 'x'; type a number from 0 to 100");
    try expectErr("nam gain", "usage: nam gain <0..100>; type a number after nam gain");
    try expectErr("nam input x", "usage: nam input <left|right|stereo>");
    try expectErr("nam latency stereo", "usage: nam latency <left|right>");
    try expectErr("nam search", "usage: nam search <amp, artist, or tone>; describe the capture to find");
}

test "language reference and metadata" {
    const text = try languageReference(ta);
    defer ta.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "maqam-live command language reference\n\nCore rule: use only this command language; do not invent English aliases.\n\nPatterns:\n- `<root> <jins> [rhythm]`: add a phrase using one jins or Western mode; roots are c d e f g a b with optional + or -, e.g. b-; "));
    try testing.expect(std.mem.indexOf(u8, text, "  - `cut` (aliases: cutoff, freq, frequency): filter cutoff frequency; range 10..22000 Hz; typical 700..4000 for audible sweeps\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  - `decay`: sympathetic string decay time; range 0.9..0.99999; typical 0.999; higher values ring longer\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  - `wave` (aliases: wav, shape): VCO/source waveform used by instrument VCFs; values sin|tri|squ|saw|mic; typical target instrument defaults to its own source; vcf all ignores wave because it filters the final outgoing mix\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  targets: all (aliases: mix, master), mic (aliases: input, live), bass (aliases: sub, subbass), kanun (aliases: qanun, melody), drums (aliases: drum, kick, kicks), sym (aliases: tanbura, tambura, sympathetics)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  - `up` (aliases: interval, transpose): multiply sympathetic resonator target strings upward by an ideal interval ratio; values unison|second|third|fourth|fifth|sixth|seventh|octave; range 0.25..4 ratio;") != null);
    try testing.expect(std.mem.endsWith(u8, text, "  note: NAM models have an expected sample rate; set the audio device to that rate if the model sounds wrong\n"));

    try testing.expect(std.mem.indexOf(u8, text, "  - `gain` (aliases: drive): input gain before the NAM model; range 0..100; typical 0.5..2;") != null);
    try testing.expectEqualStrings("vcf", commandMetadata("FILTER").?.name);
    try testing.expectEqualStrings("nam", commandMetadata("nam").?.name);
    try testing.expect(commandMetadata("bogus") == null);
    try testing.expectEqualStrings("sym", commandTokenName(&VCF_TARGETS, "Tambura").?);
    try testing.expectEqualStrings("drive", commandParameter(&SYM_METADATA, "GAIN").?.name);
    try testing.expect(commandParameter(&NAM_METADATA, "x") == null);
}

test "sympathetic harmony holds at most 8" {
    var h: SympatheticHarmony = .{};
    for (0..8) |_| try testing.expect(h.push(.{ .ratio = 1, .weight = 1 }) == null);
    try testing.expectEqualStrings("sym harmony can contain at most 8 intervals", h.push(.{ .ratio = 1, .weight = 1 }).?);
    try testing.expectEqual(@as(usize, 8), h.items().len);
    try testing.expectEqual(SympatheticTarget.drums, SympatheticTarget.parse("Kicks").?);
}

fn parseAndFree(gpa: Allocator, line: []const u8) !void {
    const r = try parse(gpa, line);
    r.deinit(gpa);
}

test "no leaks when allocation fails" {
    const lines = [_][]const u8{
        "d bayati 332, g hijaz 44 r3",
        "edit 3 nam import https://e.com/a.nam as amp",
        "i2 nam pin http://x/y.nam as y",
        "x1 2 3 4 5",
        "create Foo 1/1 9/8 5/4",
        "audition bayati",
        "audition d hijaz, g rast",
        "vcf all FOO=3",
        "sym harmony root 0.5 third 0.25 fifth 0.25",
        "delay Delay 3",
        "claude: hello",
        "save a.mq",
        "d bayati, zz",
    };
    for (lines) |l| try testing.checkAllAllocationFailures(ta, parseAndFree, .{l});
}

test "random lines never crash or leak" {
    const vocab = [_][]const u8{
        "edit",     "i",       "i3",      "j",      "else",   "x",        "up",                   "down",
        "bpm",      "s",       "sus",     "vcf",    "cut",    "res",      "drive",                "wave",
        "off",      "on",      "all",     "mic",    "sym",    "decay",    "gain",                 "harmony",
        "third",    "fifth",   "3/2",     "0/0",    "nam",    "pin",      "import",               "as",
        "tone3000", "flanger", "reverb",  "delay",  "fx",     "mix=",     "=",                    "+",
        "-",        "*",       "/",       "t",      "+2t",    "/0",       "1e400",                "nan",
        "inf",      "d",       "bayati",  "hij",    "r4",     "44",       "0",                    ",",
        "start",
        "é",
        "∞",
        "\u{00A0}", "\xff",    "\xc3",    "create", "delete", "audition", "tuneto",               "vol",
        "m",        "z",       "claude:", "load",   "save",   "ls",       "-9223372036854775808", "99999999999999999999",
    };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ta);
    for (0..20_000) |_| {
        line.clearRetainingCapacity();
        const n = rand.intRangeAtMost(usize, 1, 9);
        for (0..n) |k| {
            if (k > 0) try line.append(ta, if (rand.boolean()) ' ' else '\t');
            if (rand.intRangeLessThan(u8, 0, 10) == 0) {
                for (0..rand.intRangeAtMost(usize, 1, 4)) |_| try line.append(ta, rand.int(u8));
            } else {
                try line.appendSlice(ta, vocab[rand.uintLessThan(usize, vocab.len)]);
            }
        }
        const r = try parse(ta, line.items);
        switch (r) {
            .ok => |c| switch (c) {
                .set_vcf => |v| {
                    const a = try applyVcfChange(ta, .{}, v);
                    if (a == .err) ta.free(a.err);
                },
                .set_fx => |v| {
                    const a = try applyFxChange(ta, .{}, v);
                    if (a == .err) ta.free(a.err);
                },
                else => {},
            },
            .err => {},
        }
        r.deinit(ta);
    }
}

test "vol per bus, dry and their timeline forms" {
    const gpa = testing.allocator;
    {
        const r = try parse(gpa, "vol mic 0.25");
        defer r.deinit(gpa);
        try testing.expectEqual(VcfTarget.mic, r.ok.set_bus_vol.target);
        try testing.expectEqual(@as(f32, 0.25), r.ok.set_bus_vol.value);
    }
    {
        const r = try parse(gpa, "vol drums 2");
        defer r.deinit(gpa);
        try testing.expectEqual(VcfTarget.kick, r.ok.set_bus_vol.target);
    }
    try expectErr("vol abc", "bad volume 'abc'");
    try expectErr("vol mic x", "bad volume 'x'");
    try expectErr("vol guitar 1", "unknown volume target 'guitar'; use all, mic, bass, kanun, drums, or sym");
    try expectErr("vol mic 3", "vol mic 3 out of range 0–2");
    try expectErr("vol a b c", "usage: vol <0..2> | vol <all|mic|bass|kanun|drums|sym> <0..2>");
    {
        const r = try parse(gpa, "dry 25%");
        defer r.deinit(gpa);
        try testing.expectEqual(@as(f32, 25), r.ok.set_dry);
    }
    try expectErr("dry", "usage: dry <0..100>");
    try expectErr("dry lots", "bad dry percentage 'lots'");
    try expectErr("dry 101", "dry 101 out of range 0–100");
    {
        const r = try parse(gpa, "i 0 vol mic 0.25");
        defer r.deinit(gpa);
        try testing.expectEqual(VcfTarget.mic, r.ok.insert_bus_vol.target);
        try testing.expectEqual(@as(isize, 0), r.ok.insert_bus_vol.before);
    }
    {
        const r = try parse(gpa, "edit 3 dry 75");
        defer r.deinit(gpa);
        try testing.expectEqual(@as(f32, 75), r.ok.edit_dry.percent);
    }
    {
        const r = try parse(gpa, "i 2 vol 1.5");
        defer r.deinit(gpa);
        try testing.expectEqual(@as(f32, 1.5), r.ok.insert_vol.value);
    }
}

test "cabinet_commands_select_portable_impulse_responses" {
    const gpa = testing.allocator;
    const r = try parse(gpa, "cab modern mix=0.85");
    defer r.deinit(gpa);
    const change = r.ok.set_fx;
    const applied = try applyFxChange(gpa, FxSettings.default(), change);
    try testing.expect(applied.ok.cabinet_enabled);
    try testing.expectEqual(fx.CabinetModel.modern, applied.ok.cabinet_model);
    try testing.expectEqual(@as(f32, 0.85), applied.ok.cabinet_mix);
    {
        const off = try parse(gpa, "fx off");
        defer off.deinit(gpa);
        try testing.expectEqual(@as(?bool, false), off.ok.set_fx.cabinet_enabled);
    }
    {
        const on = try parse(gpa, "cabinet");
        defer on.deinit(gpa);
        try testing.expectEqual(@as(?bool, true), on.ok.set_fx.cabinet_enabled);
        try testing.expectEqual(@as(?fx.CabinetModel, null), on.ok.set_fx.cabinet_model);
    }
    try expectErr("cab 8x10", "unknown cabinet '8x10'; use vintage, modern, or open");
    const too_much = try parse(gpa, "cab open mix 2");
    defer too_much.deinit(gpa);
    const bad = try applyFxChange(gpa, FxSettings.default(), too_much.ok.set_fx);
    defer gpa.free(bad.err);
    try testing.expectEqualStrings("cabinet mix 2 out of range 0..1", bad.err);
}
