//! Port of maqam-live `src/session_v3.rs` (the MAQAM_SESSION_V3 record format: `HEADER`,
//! `serializeSessionV3`, escaping and `splitEscapedFields`) together with the session loaders of
//! `src/app.rs` (`load_session`, `load_session_v3`, `load_session_v1`, `load_session_v2`) and the
//! app.rs helpers they need, which app.zig reuses: `valueChangeSrc`, `vcfChangeSrc`,
//! `fxChangeSrc`, `symChangeSrc`, `symIntervalName`, `namCommandSrc`, `namInputName`,
//! `namTimelineControl`, `replaceLiveNamCommand`, `applyBpmChange`, `applySustainChange`,
//! `isPlainControlLine` (and its vcf / fx variants) and `sequenceStartSettings`.
//!
//! The loaders are pure functions of the file text: they return the timeline entries, the custom
//! jins, the settings and what NAM rows asked for (`Loaded`), or the first error with its line
//! number in exactly the Rust's text. They never touch an App, the audio thread, a NAM file, the
//! network or a browser. Like the Rust, they do reset the process-wide jins registry
//! (tuning.Maqam) and register the session's `create` lines as they go, because later phrase lines
//! name those jins; on an error the registry holds what was registered before the failing line.
//!
//! What the App does with a `Loaded` (as the Rust load_session_* did after reading): replace its
//! timeline with `phrases`, set `next_phrase_id`, `last_rhythm`, bpm / sustain / vcf / fx from
//! `settings`, keep vol and tuneto (they are never in a session), take `live_nam_commands`, then
//! send Clear, ResetSessionState, the `start` settings, SetVol, SetPaused(false), the NAM commands
//! of `nam_rows` (in order; see `NamRow`), every phrase and SetCurPhrase(0).
//!
//! Ownership: `Loaded.deinit(gpa)` frees everything in it; `LoadResult.err` and every returned
//! string are owned by the caller.
//!
//! Deliberate differences from the Rust:
//! * NAM rows are recorded, not acted on: the Rust loader tried to load each `nam <file>`,
//!   `nam pin` and `nam tone3000` model while reading (and could start a download or a TONE3000
//!   login, opening a browser); here each such row becomes a `NamRow` with its line number for the
//!   App, which resolves it after the load (and only outside tests).
//! * Phrase and jump rows go through sequencer.buildPhrase / buildJumpEntry, which reject a scale
//!   of fewer than 3 notes, more than 20 repeats and more than 10000 jump passes ("line N: ..."),
//!   where the Rust panics or accepts them.
//! * `load` takes the App's current settings (`Settings`) because a V1 file starts from them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const fx = @import("fx.zig");
const sequencer = @import("sequencer.zig");
const tuning = @import("tuning.zig");
const vcf = @import("vcf.zig");

const Cmd = command.Cmd;
const NamCommand = command.NamCommand;
const NamInput = command.NamInput;
const ValueChange = command.ValueChange;
const ControlSpec = sequencer.ControlSpec;
const Phrase = sequencer.Phrase;
const FxSettings = fx.FxSettings;
const Maqam = tuning.Maqam;
const VcfBank = vcf.VcfBank;
const VcfTarget = vcf.VcfTarget;
const VcoWave = vcf.VcoWave;
const rs = sequencer.rust_str;

pub const HEADER = "MAQAM_SESSION_V3";

// ── Rust number formatting and parsing ────────────────────────────────────────

/// Rust `{}` of a float (shortest round-trip decimal, `NaN`, `inf`).
fn printFloat(out: *std.ArrayList(u8), gpa: Allocator, x: anytype) Allocator.Error!void {
    if (std.math.isNan(x)) return out.appendSlice(gpa, "NaN");
    if (std.math.isInf(x)) return out.appendSlice(gpa, if (x < 0) "-inf" else "inf");
    try out.print(gpa, "{d}", .{x});
}

/// Rust `{:.N}` of a float.
fn printFixed(out: *std.ArrayList(u8), gpa: Allocator, x: anytype, comptime prec: usize) Allocator.Error!void {
    if (std.math.isNan(x)) return out.appendSlice(gpa, "NaN");
    if (std.math.isInf(x)) return out.appendSlice(gpa, if (x < 0) "-inf" else "inf");
    try out.print(gpa, "{d:." ++ std.fmt.comptimePrint("{d}", .{prec}) ++ "}", .{x});
}

fn floatAlloc(gpa: Allocator, comptime prefix: []const u8, x: anytype) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    try printFloat(&out, gpa, x);
    return out.toOwnedSlice(gpa);
}

/// Rust `str::parse::<usize>` (an optional `+`, then decimal digits; no overflow).
fn parseUsize(s: []const u8) ?usize {
    var t = s;
    if (t.len > 0 and t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, t, 10) catch null;
}

/// Rust `str::parse::<f64>` / `<f32>`: optional sign, then `inf`, `infinity`, `nan` (any case) or
/// decimal digits with an optional fraction and exponent.
fn parseFloat(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') i = 1;
    const body = s[i..];
    if (std.ascii.eqlIgnoreCase(body, "inf") or std.ascii.eqlIgnoreCase(body, "infinity")) {
        return if (s[0] == '-') -std.math.inf(T) else std.math.inf(T);
    }
    if (std.ascii.eqlIgnoreCase(body, "nan")) return std.math.nan(T);
    var digits: usize = 0;
    var j: usize = 0;
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
    return std.fmt.parseFloat(T, s) catch null;
}

// ── Serialization (session_v3.rs) ─────────────────────────────────────────────

fn appendEscaped(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '|' => try out.appendSlice(gpa, "\\|"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        else => try out.append(gpa, c),
    };
}

/// The V3 text of a timeline: the header, a `create` line per custom jins in the live registry
/// (sorted by name), then one record per entry. vol and tuneto are never written. Caller owns it.
pub fn serializeSessionV3(gpa: Allocator, phrases: []const Phrase) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, HEADER);
    try out.append(gpa, '\n');

    const custom = try Maqam.listCustom(gpa);
    defer tuning.freeList(gpa, custom);
    for (custom) |e| {
        try out.print(gpa, "create {s}", .{e.name});
        for (e.ratios, 0..) |r, i| {
            try out.print(gpa, "{s}{d}/{d}", .{ if (i == 0) " " else " ", r.p, r.q });
        }
        try out.append(gpa, '\n');
    }

    for (phrases) |*p| {
        if (p.jump) |j| {
            if (j.fail_target_id) |fail| {
                try out.print(gpa, "J|{d}|{d}|{d}|{d}\n", .{ p.id, j.target_id, fail, j.times });
            } else {
                try out.print(gpa, "J|{d}|{d}|{d}\n", .{ p.id, j.target_id, j.times });
            }
        } else if (p.control) |ctrl| {
            switch (ctrl) {
                .stop => try out.print(gpa, "T|{d}|stop\n", .{p.id}),
                .set_bpm => |v| {
                    try out.print(gpa, "B|{d}|", .{p.id});
                    try printFloat(&out, gpa, v);
                    try out.append(gpa, '\n');
                },
                .set_sustain => |v| {
                    try out.print(gpa, "S|{d}|", .{p.id});
                    try printFloat(&out, gpa, v);
                    try out.append(gpa, '\n');
                },
                .set_vcf, .set_fx, .set_vol, .set_bus_vol, .set_dry, .set_nam_enabled, .set_nam_gain, .set_nam_input, .set_sympathetics, .set_sympathetic_decay, .set_sympathetic_gain, .set_sympathetic => {
                    const tag: u8 = switch (ctrl) {
                        .set_vcf => 'V',
                        .set_fx => 'F',
                        .set_vol, .set_bus_vol => 'L',
                        .set_dry => 'D',
                        .set_nam_enabled, .set_nam_gain, .set_nam_input => 'N',
                        else => 'Y',
                    };
                    try out.print(gpa, "{c}|{d}|", .{ tag, p.id });
                    try appendEscaped(&out, gpa, p.src);
                    try out.append(gpa, '\n');
                },
            }
        } else {
            try out.print(gpa, "P|{d}|{d}|", .{ p.id, @max(p.repeat, 1) });
            try appendEscaped(&out, gpa, p.src);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Name used by the porting brief.
pub const serialize = serializeSessionV3;

pub fn freeFields(gpa: Allocator, fields: []const []const u8) void {
    for (fields) |f| gpa.free(f);
    gpa.free(fields);
}

/// Split a record on unescaped `|`, undoing `\\`, `\|` and `\n` (any other escape is kept as
/// written). Free with `freeFields`.
pub fn splitEscapedFields(gpa: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |f| gpa.free(f);
        fields.deinit(gpa);
    }
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    var esc = false;
    for (line) |c| {
        if (esc) {
            switch (c) {
                'n' => try cur.append(gpa, '\n'),
                '|' => try cur.append(gpa, '|'),
                '\\' => try cur.append(gpa, '\\'),
                else => try cur.appendSlice(gpa, &.{ '\\', c }),
            }
            esc = false;
        } else if (c == '\\') {
            esc = true;
        } else if (c == '|') {
            try fields.ensureUnusedCapacity(gpa, 1);
            fields.appendAssumeCapacity(try cur.toOwnedSlice(gpa));
        } else {
            try cur.append(gpa, c);
        }
    }
    if (esc) try cur.append(gpa, '\\');
    try fields.ensureUnusedCapacity(gpa, 1);
    fields.appendAssumeCapacity(try cur.toOwnedSlice(gpa));
    return fields.toOwnedSlice(gpa);
}

// ── Source text of changes (app.rs) ───────────────────────────────────────────

fn printValueChange(out: *std.ArrayList(u8), gpa: Allocator, change: ValueChange) Allocator.Error!void {
    switch (change) {
        .set => |n| try printFloat(out, gpa, n),
        .add => |n| {
            if (!(n < 0.0)) try out.append(gpa, '+');
            try printFloat(out, gpa, n);
        },
        .mul => |n| {
            try out.append(gpa, '*');
            try printFloat(out, gpa, n);
        },
        .div => |n| {
            try out.append(gpa, '/');
            try printFloat(out, gpa, n);
        },
        .tick => |n| {
            if (!(n < 0.0)) try out.append(gpa, '+');
            try printFloat(out, gpa, n);
            try out.append(gpa, 't');
        },
    }
}

pub fn valueChangeSrc(gpa: Allocator, change: ValueChange) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printValueChange(&out, gpa, change);
    return out.toOwnedSlice(gpa);
}

pub fn vcfChangeSrc(gpa: Allocator, change: command.VcfChange) Allocator.Error![]u8 {
    if (change.enabled == false) {
        if (change.target == null or change.target.? == .all) return gpa.dupe(u8, "vcf off");
        return std.fmt.allocPrint(gpa, "vcf {s} off", .{change.target.?.asStr()});
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "vcf");
    if (change.target) |t| try out.print(gpa, " {s}", .{t.asStr()});
    if (change.cutoff_hz) |v| {
        try out.appendSlice(gpa, " cut ");
        try printValueChange(&out, gpa, v);
    }
    if (change.resonance) |v| {
        try out.appendSlice(gpa, " res ");
        try printValueChange(&out, gpa, v);
    }
    if (change.drive) |v| {
        try out.appendSlice(gpa, " drive ");
        try printValueChange(&out, gpa, v);
    }
    if (change.wave) |w| {
        const hidden = if (change.target) |t| (t == .all or t == .mic) else false;
        if (!hidden) try out.print(gpa, " wave {s}", .{w.asStr()});
    }
    return out.toOwnedSlice(gpa);
}

const known_intervals = [_]struct { f64, []const u8 }{
    .{ 1.0, "unison" },
    .{ 16.0 / 15.0, "minor-second" },
    .{ 9.0 / 8.0, "second" },
    .{ 6.0 / 5.0, "third" },
    .{ 5.0 / 4.0, "major-third" },
    .{ 4.0 / 3.0, "fourth" },
    .{ 45.0 / 32.0, "tritone" },
    .{ 3.0 / 2.0, "fifth" },
    .{ 8.0 / 5.0, "sixth" },
    .{ 5.0 / 3.0, "major-sixth" },
    .{ 9.0 / 5.0, "minor-seventh" },
    .{ 15.0 / 8.0, "seventh" },
    .{ 2.0, "octave" },
};

fn printSymInterval(out: *std.ArrayList(u8), gpa: Allocator, ratio: f64) Allocator.Error!void {
    for (known_intervals) |k| {
        if (@abs(ratio - k[0]) < 0.000_001) return out.appendSlice(gpa, k[1]);
    }
    try printFixed(out, gpa, ratio, 5);
}

pub fn symIntervalName(gpa: Allocator, ratio: f64) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printSymInterval(&out, gpa, ratio);
    return out.toOwnedSlice(gpa);
}

fn printSymHarmonyInterval(out: *std.ArrayList(u8), gpa: Allocator, ratio: f64) Allocator.Error!void {
    if (@abs(ratio - 1.0) < 0.000_001) return out.appendSlice(gpa, "root");
    try printSymInterval(out, gpa, ratio);
}

pub fn symChangeSrc(gpa: Allocator, change: command.SympatheticChange) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "sym");
    if (change.target) |t| try out.print(gpa, " {s}", .{t.asStr()});
    if (change.enabled) |e| try out.appendSlice(gpa, if (e) " on" else " off");
    if (change.decay) |d| {
        try out.appendSlice(gpa, " decay ");
        try printFloat(&out, gpa, d);
    }
    if (change.gain) |g| {
        try out.appendSlice(gpa, " drive ");
        try printFloat(&out, gpa, g);
    }
    if (change.interval_ratio) |ratio| {
        if (ratio < 1.0) {
            try out.appendSlice(gpa, " down ");
            try printSymInterval(&out, gpa, 1.0 / ratio);
        } else {
            try out.appendSlice(gpa, " up ");
            try printSymInterval(&out, gpa, ratio);
        }
    }
    if (change.harmony) |h| {
        try out.appendSlice(gpa, " harmony");
        for (h.items()) |c| {
            try out.append(gpa, ' ');
            try printSymHarmonyInterval(&out, gpa, c.ratio);
            try out.append(gpa, ' ');
            try printFixed(&out, gpa, c.weight, 2);
        }
    }
    const tail = [_]struct { []const u8, ?f32 }{
        .{ " amount ", change.amount },
        .{ " mic ", change.mic },
        .{ " kanun ", change.kanun },
        .{ " bass ", change.bass },
        .{ " drums ", change.drums },
    };
    for (tail) |t| if (t[1]) |v| {
        try out.appendSlice(gpa, t[0]);
        try printFloat(&out, gpa, v);
    };
    return out.toOwnedSlice(gpa);
}

fn printParams(out: *std.ArrayList(u8), gpa: Allocator, params: []const struct { []const u8, ?ValueChange }) Allocator.Error!void {
    for (params) |p| if (p[1]) |v| {
        try out.print(gpa, " {s} ", .{p[0]});
        try printValueChange(out, gpa, v);
    };
}

pub fn fxChangeSrc(gpa: Allocator, change: command.FxChange) Allocator.Error![]u8 {
    if (change.flanger_enabled == false and change.chorus_enabled == false and
        change.reverb_enabled == false and change.delay_enabled == false and change.cabinet_enabled == false)
        return gpa.dupe(u8, "fx off");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const c = change;
    if (c.flanger_enabled != null or c.flanger_rate_hz != null or c.flanger_depth != null or
        c.flanger_delay_ms != null or c.flanger_feedback != null or c.flanger_mix != null)
    {
        try out.appendSlice(gpa, "flanger");
        if (c.flanger_enabled == false) {
            try out.appendSlice(gpa, " off");
            return out.toOwnedSlice(gpa);
        }
        try printParams(&out, gpa, &.{
            .{ "rate", c.flanger_rate_hz },      .{ "depth", c.flanger_depth }, .{ "delay", c.flanger_delay_ms },
            .{ "feedback", c.flanger_feedback }, .{ "mix", c.flanger_mix },
        });
    } else if (c.chorus_enabled != null or c.chorus_rate_hz != null or c.chorus_depth != null or
        c.chorus_delay_ms != null or c.chorus_mix != null)
    {
        try out.appendSlice(gpa, "chorus");
        if (c.chorus_enabled == false) {
            try out.appendSlice(gpa, " off");
            return out.toOwnedSlice(gpa);
        }
        try printParams(&out, gpa, &.{
            .{ "rate", c.chorus_rate_hz }, .{ "depth", c.chorus_depth }, .{ "delay", c.chorus_delay_ms }, .{ "mix", c.chorus_mix },
        });
    } else if (c.reverb_enabled != null or c.reverb_mix != null or c.reverb_decay != null) {
        try out.appendSlice(gpa, "reverb");
        if (c.reverb_enabled == false) {
            try out.appendSlice(gpa, " off");
            return out.toOwnedSlice(gpa);
        }
        try printParams(&out, gpa, &.{ .{ "mix", c.reverb_mix }, .{ "decay", c.reverb_decay } });
    } else if (c.delay_enabled != null or c.delay_time_secs != null or c.delay_feedback != null or c.delay_mix != null) {
        try out.appendSlice(gpa, "delay");
        if (c.delay_enabled == false) {
            try out.appendSlice(gpa, " off");
            return out.toOwnedSlice(gpa);
        }
        try printParams(&out, gpa, &.{
            .{ "time", c.delay_time_secs }, .{ "feedback", c.delay_feedback }, .{ "mix", c.delay_mix },
        });
    } else {
        try out.appendSlice(gpa, "cab");
        if (c.cabinet_enabled == false) {
            try out.appendSlice(gpa, " off");
            return out.toOwnedSlice(gpa);
        }
        if (c.cabinet_model) |m| {
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, m.name());
        }
        try printParams(&out, gpa, &.{.{ "mix", c.cabinet_mix }});
    }
    return out.toOwnedSlice(gpa);
}

// ── NAM helpers (app.rs) ──────────────────────────────────────────────────────

/// The rejection of a NAM command a session cannot run (the Rust `nam_session_audio_cmd`).
pub const nam_session_only_message = "NAM lines in .mq files can load, bypass, or set gain only; run import/search/list interactively";

pub fn namInputName(route: NamInput) []const u8 {
    return switch (route) {
        .left => "left",
        .right => "right",
        .stereo => "stereo",
    };
}

/// The canonical source of a NAM command that is live state, or null. Caller owns it.
pub fn namCommandSrc(gpa: Allocator, cmd: NamCommand) Allocator.Error!?[]u8 {
    return switch (cmd) {
        .load => |v| try std.fmt.allocPrint(gpa, "nam {s}", .{v.path}),
        .off => try gpa.dupe(u8, "nam off"),
        .gain => |g| try floatAlloc(gpa, "nam gain ", g),
        .input => |r| try std.fmt.allocPrint(gpa, "nam input {s}", .{namInputName(r)}),
        .pin => |v| try std.fmt.allocPrint(gpa, "nam pin {s} as {s}", .{ v.url, v.name }),
        .tone3000 => |v| try std.fmt.allocPrint(gpa, "nam tone3000 {d} as {s}", .{ v.tone_id, v.name }),
        .login, .logout, .latency, .import, .search, .list => null,
    };
}

pub fn namTimelineControl(cmd: NamCommand) ?ControlSpec {
    return switch (cmd) {
        .off => .{ .set_nam_enabled = false },
        .gain => |g| .{ .set_nam_gain = g },
        .input => |r| .{ .set_nam_input = r },
        .load, .pin, .tone3000 => .{ .set_nam_enabled = true },
        .login, .logout, .latency, .import, .search, .list => null,
    };
}

/// Keep one gain command and one state command (load / off / pin / tone3000 / input) in the live
/// NAM command list: `src` replaces the first of its kind or is appended. Takes ownership of `src`.
pub fn replaceLiveNamCommand(gpa: Allocator, commands: *std.ArrayList([]u8), src_opt: ?[]u8) Allocator.Error!void {
    const src = src_opt orelse return;
    const is_gain = std.mem.startsWith(u8, src, "nam gain ");
    const is_state = std.mem.eql(u8, src, "nam off") or (!is_gain and std.mem.startsWith(u8, src, "nam "));
    for (commands.items) |*existing| {
        const hit = if (is_gain)
            std.mem.startsWith(u8, existing.*, "nam gain ")
        else if (is_state)
            std.mem.eql(u8, existing.*, "nam off") or
                (!std.mem.startsWith(u8, existing.*, "nam gain ") and std.mem.startsWith(u8, existing.*, "nam "))
        else
            false;
        if (hit) {
            gpa.free(existing.*);
            existing.* = src;
            return;
        }
    }
    commands.append(gpa, src) catch |e| {
        gpa.free(src);
        return e;
    };
}

// ── Control helpers (app.rs) ──────────────────────────────────────────────────

pub const ChangeResult = union(enum) { ok: f64, err: []u8 };

/// Apply a bpm change and check 20..=400; the message is owned.
pub fn applyBpmChange(gpa: Allocator, current: f64, change: ValueChange) Allocator.Error!ChangeResult {
    const next = switch (change.apply(current)) {
        .ok => |v| v,
        .err => |m| return .{ .err = try gpa.dupe(u8, m) },
    };
    if (!(next >= 20.0 and next <= 400.0)) return .{ .err = try floatMsg(gpa, "bpm ", next, " out of range") };
    return .{ .ok = next };
}

/// Apply a sustain change and check 0.05..=10; the message is owned.
pub fn applySustainChange(gpa: Allocator, current: f64, change: ValueChange) Allocator.Error!ChangeResult {
    const next = switch (change.apply(current)) {
        .ok => |v| v,
        .err => |m| return .{ .err = try gpa.dupe(u8, m) },
    };
    if (!(next >= 0.05 and next <= 10.0)) return .{ .err = try floatMsg(gpa, "sustain ", next, "s out of range") };
    return .{ .ok = next };
}

fn floatMsg(gpa: Allocator, comptime pre: []const u8, x: f64, comptime post: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, pre);
    try printFloat(&out, gpa, x);
    try out.appendSlice(gpa, post);
    return out.toOwnedSlice(gpa);
}

fn firstWordIs(line: []const u8, names: []const []const u8) bool {
    const first = rs.firstWord(line) orelse "";
    for (names) |n| if (std.ascii.eqlIgnoreCase(first, n)) return true;
    return false;
}

pub fn isPlainVcfControlLine(line: []const u8) bool {
    return firstWordIs(line, &.{ "vcf", "filter", "filt", "cut", "cutoff", "res", "q", "drive", "drv" });
}

pub fn isPlainFxControlLine(line: []const u8) bool {
    return firstWordIs(line, &.{ "fx", "flanger", "flange", "chorus", "choir", "reverb", "rev", "delay", "pingpong", "cab", "cabinet" });
}

pub fn isPlainControlLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "bpm ") or std.mem.startsWith(u8, line, "s ") or
        std.mem.startsWith(u8, line, "sus ") or isPlainVcfControlLine(line) or
        isPlainFxControlLine(line) or firstWordIs(line, &.{"sym"});
}

/// Tempo, sustain, filter bank and effects.
pub const Settings = struct {
    bpm: f64 = 120.0,
    sustain: f64 = 1.25,
    vcf: VcfBank = .{},
    fx: FxSettings = .{},
};

/// The settings in force when playback starts: the control entries before the first audio phrase
/// applied to the defaults (the Rust `sequence_start_settings`).
pub fn sequenceStartSettings(gpa: Allocator, phrases: []const Phrase) Allocator.Error!Settings {
    var s: Settings = .{};
    for (phrases) |*phrase| {
        if (phrase.control) |ctrl| {
            switch (ctrl) {
                .set_bpm => |v| s.bpm = v,
                .set_sustain => |v| s.sustain = v,
                .set_vcf => |v| switch (try command.applyVcfChange(gpa, s.vcf, v)) {
                    .ok => |setting| s.vcf.apply(setting),
                    .err => |m| gpa.free(m),
                },
                .set_fx => |v| switch (try command.applyFxChange(gpa, s.fx, v)) {
                    .ok => |setting| s.fx = setting,
                    .err => |m| gpa.free(m),
                },
                else => {},
            }
            continue;
        }
        if (phrase.jump == null) break;
    }
    return s;
}

// ── Loading ───────────────────────────────────────────────────────────────────

/// A NAM row the App resolves after the load, in file order. For `load`, `pin` and `tone3000`
/// the App tries the cached model (`nam_session_audio_cmd`); when that fails a `tone3000` row
/// becomes the pending TONE3000 download, a `pin` row the pending pinned download, and a `load`
/// row the pending slot (with the warning "This score needs a NAM model for “<slot>”. What amp or
/// tone should it use?" only when `record` is false). `off`, `gain` and `input` become their audio
/// commands. Any other command (only possible on a plain `nam` line) gives the warning
/// "line <line_no>: " ++ `nam_session_only_message`. The first warning becomes the App's message.
pub const NamRow = struct {
    line_no: usize,
    /// Owned.
    command: NamCommand,
    /// True for an `N|id|...` record, false for a plain `nam ...` line.
    record: bool,
};

pub const Version = enum { v1, v2, v3 };

/// What a session file holds.
pub const Loaded = struct {
    version: Version,
    /// The timeline entries in file order, with their ids.
    phrases: []Phrase,
    /// One more than the largest id (0 for an empty V3 timeline).
    next_phrase_id: usize,
    /// The rhythm a later phrase without one inherits.
    last_rhythm: []u8,
    /// Tempo, sustain, filters and effects after reading the whole file (the App's live state).
    settings: Settings,
    /// The settings playback starts with (`sequenceStartSettings(phrases)`).
    start: Settings,
    /// The custom jins in the registry after the load (what a save writes as `create` lines).
    custom_jins: []tuning.JinsEntry,
    /// The live NAM commands from plain `nam` lines (V3 only).
    live_nam_commands: [][]u8,
    /// NAM rows for the App to resolve (V3 only).
    nam_rows: []NamRow,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        for (self.phrases) |*p| p.deinit(gpa);
        gpa.free(self.phrases);
        gpa.free(self.last_rhythm);
        tuning.freeList(gpa, self.custom_jins);
        for (self.live_nam_commands) |c| gpa.free(c);
        gpa.free(self.live_nam_commands);
        for (self.nam_rows) |r| r.command.deinit(gpa);
        gpa.free(self.nam_rows);
        self.* = undefined;
    }
};

/// A loaded session, or the first error ("line N: ..." etc., the Rust text; owned).
pub const LoadResult = union(enum) {
    ok: Loaded,
    err: []u8,

    pub fn deinit(self: *LoadResult, gpa: Allocator) void {
        switch (self.*) {
            .ok => |*l| l.deinit(gpa),
            .err => |m| gpa.free(m),
        }
    }
};

const Error = error{ Rejected, OutOfMemory };

/// Loader state: everything it builds, freed on error.
const Loader = struct {
    gpa: Allocator,
    msg: ?[]u8 = null,
    phrases: std.ArrayList(Phrase) = .empty,
    last_rhythm: std.ArrayList(u8) = .empty,
    live_nam: std.ArrayList([]u8) = .empty,
    nam_rows: std.ArrayList(NamRow) = .empty,
    settings: Settings = .{},

    fn init(gpa: Allocator) Allocator.Error!Loader {
        var l: Loader = .{ .gpa = gpa };
        try l.last_rhythm.appendSlice(gpa, &.{ 3, 3, 2 });
        return l;
    }

    fn deinit(l: *Loader) void {
        const gpa = l.gpa;
        if (l.msg) |m| gpa.free(m);
        for (l.phrases.items) |*p| p.deinit(gpa);
        l.phrases.deinit(gpa);
        l.last_rhythm.deinit(gpa);
        for (l.live_nam.items) |c| gpa.free(c);
        l.live_nam.deinit(gpa);
        for (l.nam_rows.items) |r| r.command.deinit(gpa);
        l.nam_rows.deinit(gpa);
    }

    fn fail(l: *Loader, comptime f: []const u8, args: anytype) Error {
        const m = try std.fmt.allocPrint(l.gpa, f, args);
        if (l.msg) |old| l.gpa.free(old);
        l.msg = m;
        return error.Rejected;
    }

    /// "line N: <owned message>", freeing the message.
    fn failOwned(l: *Loader, line_no: usize, m: []u8) Error {
        defer l.gpa.free(m);
        return l.fail("line {d}: {s}", .{ line_no, m });
    }

    fn push(l: *Loader, p: Phrase) Allocator.Error!void {
        var entry = p;
        l.phrases.append(l.gpa, entry) catch |e| {
            entry.deinit(l.gpa);
            return e;
        };
    }

    fn pushControl(l: *Loader, id: usize, src: []const u8, control: ControlSpec) Allocator.Error!void {
        try l.push(try sequencer.buildControlEntry(l.gpa, id, src, control));
    }

    fn pushControlOwnedSrc(l: *Loader, id: usize, src: []u8, control: ControlSpec) Allocator.Error!void {
        defer l.gpa.free(src);
        try l.pushControl(id, src, control);
    }

    fn pushBuilt(l: *Loader, line_no: usize, r: sequencer.BuildResult) Error!void {
        switch (r) {
            .ok => |p| try l.push(p),
            .err => |m| return l.failOwned(line_no, m),
        }
    }

    /// Parse a command line; a rejection becomes "line N: <message>". Caller deinits the Cmd.
    fn parse(l: *Loader, line_no: usize, text: []const u8) Error!Cmd {
        return switch (try command.parse(l.gpa, text)) {
            .ok => |c| c,
            .err => |m| l.failOwned(line_no, m),
        };
    }

    fn createJins(l: *Loader, line_no: usize, line: []const u8) Error!void {
        const parsed = try l.parse(line_no, line);
        defer parsed.deinit(l.gpa);
        switch (parsed) {
            .create_jins => |v| switch (try Maqam.create(v.name, v.ratios)) {
                .ok => {},
                .err => |m| return l.fail("line {d}: {s}", .{ line_no, m }),
            },
            else => return l.fail("line {d}: expected create line", .{line_no}),
        }
    }

    fn bpm(l: *Loader, line_no: usize, id: usize, change: ValueChange) Error!void {
        switch (try applyBpmChange(l.gpa, l.settings.bpm, change)) {
            .ok => |v| l.settings.bpm = v,
            .err => |m| return l.failOwned(line_no, m),
        }
        try l.pushControlOwnedSrc(id, try floatAlloc(l.gpa, "bpm ", l.settings.bpm), .{ .set_bpm = l.settings.bpm });
    }

    fn sustain(l: *Loader, line_no: usize, id: usize, change: ValueChange) Error!void {
        switch (try applySustainChange(l.gpa, l.settings.sustain, change)) {
            .ok => |v| l.settings.sustain = v,
            .err => |m| return l.failOwned(line_no, m),
        }
        try l.pushControlOwnedSrc(id, try floatAlloc(l.gpa, "s ", l.settings.sustain), .{ .set_sustain = l.settings.sustain });
    }

    fn vcfChange(l: *Loader, line_no: usize, id: usize, change: command.VcfChange) Error!void {
        switch (try command.applyVcfChange(l.gpa, l.settings.vcf, change)) {
            .ok => |setting| l.settings.vcf.apply(setting),
            .err => |m| return l.failOwned(line_no, m),
        }
        try l.pushControlOwnedSrc(id, try vcfChangeSrc(l.gpa, change), .{ .set_vcf = change });
    }

    fn fxChange(l: *Loader, line_no: usize, id: usize, change: command.FxChange) Error!void {
        switch (try command.applyFxChange(l.gpa, l.settings.fx, change)) {
            .ok => |setting| l.settings.fx = setting,
            .err => |m| return l.failOwned(line_no, m),
        }
        try l.pushControlOwnedSrc(id, try fxChangeSrc(l.gpa, change), .{ .set_fx = change });
    }

    /// The sym commands as a control entry with their canonical source, or null for another command.
    fn symControl(l: *Loader, id: usize, parsed: Cmd) Allocator.Error!bool {
        switch (parsed) {
            .sympathetics => |e| try l.pushControl(id, if (e) "sym on" else "sym off", .{ .set_sympathetics = e }),
            .sympathetic_decay => |d| try l.pushControlOwnedSrc(id, try floatAlloc(l.gpa, "sym decay ", d), .{ .set_sympathetic_decay = d }),
            .sympathetic_gain => |g| try l.pushControlOwnedSrc(id, try floatAlloc(l.gpa, "sym gain ", g), .{ .set_sympathetic_gain = g }),
            .sympathetic => |c| try l.pushControlOwnedSrc(id, try symChangeSrc(l.gpa, c), .{ .set_sympathetic = c }),
            else => return false,
        }
        return true;
    }

    fn addNamRow(l: *Loader, line_no: usize, cmd: NamCommand, record: bool) Allocator.Error!void {
        const copy = try dupeNamCommand(l.gpa, cmd);
        l.nam_rows.append(l.gpa, .{ .line_no = line_no, .command = copy, .record = record }) catch |e| {
            copy.deinit(l.gpa);
            return e;
        };
    }

    /// Build a phrase from parsed specs with the loader's rhythm inheritance.
    fn phrase(l: *Loader, line_no: usize, id: usize, src: []const u8, specs: []const command.JinsSpec, repeat: usize) Error!void {
        const resolved = try sequencer.resolveRhythms(l.gpa, specs, l.last_rhythm.items);
        defer l.gpa.free(resolved);
        if (resolved.len > 0) {
            const groups = try l.gpa.dupe(u8, resolved[resolved.len - 1].groups);
            defer l.gpa.free(groups);
            // Build first: `resolved` may borrow the current last_rhythm.
            const built = try sequencer.buildPhrase(l.gpa, id, src, resolved, 4, repeat);
            l.last_rhythm.clearRetainingCapacity();
            l.last_rhythm.appendSlice(l.gpa, groups) catch |e| {
                var b = built;
                b.deinit(l.gpa);
                return e;
            };
            return l.pushBuilt(line_no, built);
        }
        return l.pushBuilt(line_no, try sequencer.buildPhrase(l.gpa, id, src, resolved, 4, repeat));
    }

    fn finish(l: *Loader, version: Version, next_phrase_id: usize) Allocator.Error!Loaded {
        const gpa = l.gpa;
        const start = try sequenceStartSettings(gpa, l.phrases.items);
        const custom = try Maqam.listCustom(gpa);
        errdefer tuning.freeList(gpa, custom);
        const phrases = try l.phrases.toOwnedSlice(gpa);
        errdefer {
            for (phrases) |*p| p.deinit(gpa);
            gpa.free(phrases);
        }
        const last_rhythm = try l.last_rhythm.toOwnedSlice(gpa);
        errdefer gpa.free(last_rhythm);
        const live = try l.live_nam.toOwnedSlice(gpa);
        errdefer {
            for (live) |c| gpa.free(c);
            gpa.free(live);
        }
        const rows = try l.nam_rows.toOwnedSlice(gpa);
        return .{
            .version = version,
            .phrases = phrases,
            .next_phrase_id = next_phrase_id,
            .last_rhythm = last_rhythm,
            .settings = l.settings,
            .start = start,
            .custom_jins = custom,
            .live_nam_commands = live,
            .nam_rows = rows,
        };
    }
};

fn dupeNamCommand(gpa: Allocator, cmd: NamCommand) Allocator.Error!NamCommand {
    return switch (cmd) {
        .load => |v| .{ .load = .{ .path = try gpa.dupe(u8, v.path) } },
        .import => |v| blk: {
            const path = try gpa.dupe(u8, v.path);
            errdefer gpa.free(path);
            break :blk .{ .import = .{ .path = path, .name = if (v.name) |n| try gpa.dupe(u8, n) else null } };
        },
        .pin => |v| blk: {
            const url = try gpa.dupe(u8, v.url);
            errdefer gpa.free(url);
            break :blk .{ .pin = .{ .url = url, .name = try gpa.dupe(u8, v.name) } };
        },
        .tone3000 => |v| .{ .tone3000 = .{ .tone_id = v.tone_id, .name = try gpa.dupe(u8, v.name) } },
        .search => |v| .{ .search = .{ .query = try gpa.dupe(u8, v.query) } },
        else => cmd,
    };
}

fn runLoader(gpa: Allocator, comptime body: anytype, args: anytype) Allocator.Error!LoadResult {
    var l = try Loader.init(gpa);
    defer l.deinit();
    const loaded = @call(.auto, body, .{&l} ++ args) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => {
            const m = l.msg.?;
            l.msg = null;
            return .{ .err = m };
        },
    };
    return .{ .ok = loaded };
}

/// The V3 loader (app.rs `load_session_v3`): `lines` are the lines after the header (the first is
/// line 2). Also accepts plain `create`, `vol` (skipped), `nam`, `bpm`, `s`/`sus`, vcf, fx and sym
/// lines, which take the lowest ids no record uses.
pub fn loadSessionV3(gpa: Allocator, lines: []const []const u8) Allocator.Error!LoadResult {
    return runLoader(gpa, v3Body, .{lines});
}

fn v3Body(l: *Loader, lines: []const []const u8) Error!Loaded {
    const gpa = l.gpa;
    var reserved: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer reserved.deinit(gpa);
    for (lines) |line| {
        const fields = try splitEscapedFields(gpa, line);
        defer freeFields(gpa, fields);
        if (fields.len > 1) {
            if (parseUsize(fields[1])) |id| try reserved.put(gpa, id, {});
        }
    }
    Maqam.resetToDefaults();
    var ids: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer ids.deinit(gpa);
    var max_id: ?usize = null;
    var next_legacy_id: usize = 0;

    const legacy = struct {
        fn next(ids_: *std.AutoHashMapUnmanaged(usize, void), reserved_: *const std.AutoHashMapUnmanaged(usize, void), counter: *usize, max: *?usize, a: Allocator) Allocator.Error!usize {
            while (ids_.contains(counter.*) or reserved_.contains(counter.*)) counter.* += 1;
            const id = counter.*;
            counter.* += 1;
            try ids_.put(a, id, {});
            max.* = if (max.*) |m| @max(m, id) else id;
            return id;
        }
    };

    for (lines, 0..) |raw_line, line_idx| {
        const line_no = line_idx + 2;
        const line = rs.trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "create ")) {
            try l.createJins(line_no, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, "vol ")) continue;
        if (firstWordIs(line, &.{"nam"})) {
            const parsed = try l.parse(line_no, line);
            defer parsed.deinit(gpa);
            const cmd = switch (parsed) {
                .set_nam => |c| c,
                else => return l.fail("line {d}: expected nam line", .{line_no}),
            };
            try l.addNamRow(line_no, cmd, false);
            try replaceLiveNamCommand(gpa, &l.live_nam, try namCommandSrc(gpa, cmd));
            if (namTimelineControl(cmd)) |control| {
                const id = try legacy.next(&ids, &reserved, &next_legacy_id, &max_id, gpa);
                try l.pushControl(id, line, control);
            }
            continue;
        }
        if (isPlainControlLine(line)) {
            const id = try legacy.next(&ids, &reserved, &next_legacy_id, &max_id, gpa);
            const parsed = try l.parse(line_no, line);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_bpm => |c| try l.bpm(line_no, id, c),
                .set_sustain => |c| try l.sustain(line_no, id, c),
                .set_vcf => |c| try l.vcfChange(line_no, id, c),
                .set_fx => |c| try l.fxChange(line_no, id, c),
                else => if (!try l.symControl(id, parsed)) return l.fail("line {d}: expected control line", .{line_no}),
            }
            continue;
        }

        const fields = try splitEscapedFields(gpa, line);
        defer freeFields(gpa, fields);
        if (fields.len < 2) return l.fail("line {d}: missing id", .{line_no});
        const id = parseUsize(rs.trim(fields[1])) orelse return l.fail("line {d}: bad id", .{line_no});
        const gop = try ids.getOrPut(gpa, id);
        if (gop.found_existing) return l.fail("line {d}: duplicate id {d}", .{ line_no, id });
        max_id = if (max_id) |m| @max(m, id) else id;

        const kind = fields[0];
        const n = fields.len;
        if (std.mem.eql(u8, kind, "T") and n == 3 and std.mem.eql(u8, rs.trim(fields[2]), "stop")) {
            try l.pushControl(id, "stop", .stop);
        } else if (std.mem.eql(u8, kind, "B") and n == 3) {
            const v = parseFloat(f64, rs.trim(fields[2])) orelse return l.fail("line {d}: bad bpm", .{line_no});
            l.settings.bpm = v;
            if (!(v >= 20.0 and v <= 400.0)) return l.fail("line {d}: bpm out of range", .{line_no});
            try l.pushControlOwnedSrc(id, try floatAlloc(gpa, "bpm ", v), .{ .set_bpm = v });
        } else if (std.mem.eql(u8, kind, "S") and n == 3) {
            const v = parseFloat(f64, rs.trim(fields[2])) orelse return l.fail("line {d}: bad sustain", .{line_no});
            l.settings.sustain = v;
            if (!(v >= 0.05 and v <= 10.0)) return l.fail("line {d}: sustain out of range", .{line_no});
            try l.pushControlOwnedSrc(id, try floatAlloc(gpa, "s ", v), .{ .set_sustain = v });
        } else if (std.mem.eql(u8, kind, "V") and n == 3) {
            const parsed = try l.parse(line_no, fields[2]);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_vcf => |c| try l.vcfChange(line_no, id, c),
                else => return l.fail("line {d}: expected vcf line", .{line_no}),
            }
        } else if (std.mem.eql(u8, kind, "F") and n == 3) {
            const parsed = try l.parse(line_no, fields[2]);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_fx => |c| try l.fxChange(line_no, id, c),
                else => return l.fail("line {d}: expected fx line", .{line_no}),
            }
        } else if (std.mem.eql(u8, kind, "L") and n == 3) {
            const parsed = try l.parse(line_no, fields[2]);
            defer parsed.deinit(gpa);
            const control: ControlSpec = switch (parsed) {
                .set_vol => |v| .{ .set_vol = v },
                .set_bus_vol => |v| .{ .set_bus_vol = .{ .target = v.target, .value = v.value } },
                else => return l.fail("line {d}: expected vol line", .{line_no}),
            };
            try l.pushControl(id, fields[2], control);
        } else if (std.mem.eql(u8, kind, "D") and n == 3) {
            const parsed = switch (try command.parse(gpa, fields[2])) {
                .ok => |c| c,
                .err => |m| {
                    defer gpa.free(m);
                    return l.fail("line {d}: invalid dry control: {s}", .{ line_no, m });
                },
            };
            defer parsed.deinit(gpa);
            const control: ControlSpec = switch (parsed) {
                .set_dry => |v| .{ .set_dry = v },
                else => return l.fail("line {d}: expected dry line", .{line_no}),
            };
            try l.pushControl(id, fields[2], control);
        } else if (std.mem.eql(u8, kind, "N") and n == 3) {
            const parsed = try l.parse(line_no, fields[2]);
            defer parsed.deinit(gpa);
            const cmd = switch (parsed) {
                .set_nam => |c| c,
                else => return l.fail("line {d}: expected nam line", .{line_no}),
            };
            const control = namTimelineControl(cmd) orelse return l.fail("line {d}: NAM command cannot be scheduled", .{line_no});
            try l.addNamRow(line_no, cmd, true);
            try l.pushControl(id, fields[2], control);
        } else if (std.mem.eql(u8, kind, "Y") and n == 3) {
            const parsed = try l.parse(line_no, fields[2]);
            defer parsed.deinit(gpa);
            if (!try l.symControl(id, parsed)) return l.fail("line {d}: expected sym line", .{line_no});
        } else if (std.mem.eql(u8, kind, "V") and n >= 5 and n <= 8) {
            var target: VcfTarget = l.settings.vcf.focus;
            var offset: usize = 2;
            if (n >= 6) {
                target = VcfTarget.parse(fields[2]) orelse return l.fail("line {d}: bad vcf target", .{line_no});
                offset = 3;
            }
            const cutoff = parseFloat(f32, rs.trim(fields[offset])) orelse return l.fail("line {d}: bad vcf cutoff", .{line_no});
            const resonance = parseFloat(f32, rs.trim(fields[offset + 1])) orelse return l.fail("line {d}: bad vcf resonance", .{line_no});
            const drive = parseFloat(f32, rs.trim(fields[offset + 2])) orelse return l.fail("line {d}: bad vcf drive", .{line_no});
            var enabled = true;
            if (n >= 7) {
                const flag = rs.trim(fields[6]);
                if (eqlAny(flag, &.{ "on", "true", "1" })) {
                    enabled = true;
                } else if (eqlAny(flag, &.{ "off", "false", "0" })) {
                    enabled = false;
                } else return l.fail("line {d}: bad vcf enabled flag", .{line_no});
            }
            const wave: VcoWave = if (n == 8)
                VcoWave.parse(fields[7]) orelse return l.fail("line {d}: bad vcf wave", .{line_no})
            else
                l.settings.vcf.get(target).wave;
            try l.vcfChange(line_no, id, .{
                .enabled = enabled,
                .target = target,
                .cutoff_hz = .{ .set = cutoff },
                .resonance = .{ .set = resonance },
                .drive = .{ .set = drive },
                .wave = wave,
            });
        } else if (std.mem.eql(u8, kind, "J") and (n == 4 or n == 5)) {
            const target = parseUsize(rs.trim(fields[2])) orelse return l.fail("line {d}: bad jump target", .{line_no});
            var fail_target: ?usize = null;
            var times_field: usize = 3;
            if (n == 5) {
                fail_target = parseUsize(rs.trim(fields[3])) orelse return l.fail("line {d}: bad jump failure target", .{line_no});
                times_field = 4;
            }
            const times = parseUsize(rs.trim(fields[times_field])) orelse return l.fail("line {d}: bad jump times", .{line_no});
            try l.pushBuilt(line_no, try sequencer.buildJumpEntry(gpa, id, target, fail_target, times));
        } else if (std.mem.eql(u8, kind, "P") and n == 4) {
            const repeat = @max(parseUsize(rs.trim(fields[2])) orelse return l.fail("line {d}: bad repeat", .{line_no}), 1);
            const src = fields[3];
            const parsed = try l.parse(line_no, src);
            defer parsed.deinit(gpa);
            const specs = switch (parsed) {
                .add_phrase => |v| v.specs,
                else => return l.fail("line {d}: expected phrase command", .{line_no}),
            };
            try l.phrase(line_no, id, src, specs, repeat);
        } else {
            return l.fail("line {d}: malformed V3 record", .{line_no});
        }
    }
    return l.finish(.v3, if (max_id) |m| m +| 1 else 0);
}

/// ASCII case-insensitive membership (the Rust `to_ascii_lowercase()` match).
fn eqlAny(s: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n)) return true;
    return false;
}

/// The V1 loader (app.rs `load_session_v1`): starts from the App's `current` tempo, sustain,
/// filters and effects. Control lines take the running counter as their id.
pub fn loadSessionV1(gpa: Allocator, lines: []const []const u8, current: Settings) Allocator.Error!LoadResult {
    return runLoader(gpa, v1Body, .{ lines, current });
}

fn v1Body(l: *Loader, lines: []const []const u8, current: Settings) Error!Loaded {
    const gpa = l.gpa;
    Maqam.resetToDefaults();
    l.settings = current;
    var max_id: usize = 0;

    for (lines, 0..) |raw_line, line_idx| {
        const line_no = line_idx + 2;
        const line = rs.trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "create ")) {
            try l.createJins(line_no, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, "bpm ")) {
            const parsed = try l.parse(line_no, line);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_bpm => |c| try l.bpm(line_no, max_id, c),
                else => return l.fail("line {d}: expected bpm line", .{line_no}),
            }
            max_id += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "s ") or std.mem.startsWith(u8, line, "sus ")) {
            const parsed = try l.parse(line_no, line);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_sustain => |c| try l.sustain(line_no, max_id, c),
                else => return l.fail("line {d}: expected sustain line", .{line_no}),
            }
            max_id += 1;
            continue;
        }
        if (isPlainVcfControlLine(line)) {
            const parsed = try l.parse(line_no, line);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_vcf => |c| try l.vcfChange(line_no, max_id, c),
                else => return l.fail("line {d}: expected vcf line", .{line_no}),
            }
            max_id += 1;
            continue;
        }
        if (isPlainFxControlLine(line)) {
            const parsed = try l.parse(line_no, line);
            defer parsed.deinit(gpa);
            switch (parsed) {
                .set_fx => |c| try l.fxChange(line_no, max_id, c),
                else => return l.fail("line {d}: expected fx line", .{line_no}),
            }
            max_id += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "vol ")) continue;

        if (std.mem.startsWith(u8, line, "J|")) {
            var parts = std.mem.splitScalar(u8, line[2..], '|');
            const id_s = parts.next() orelse return l.fail("line {d}: missing jump id", .{line_no});
            const id = parseUsize(id_s) orelse return l.fail("line {d}: bad jump id", .{line_no});
            const target_s = parts.next() orelse return l.fail("line {d}: missing jump target", .{line_no});
            const target = parseUsize(target_s) orelse return l.fail("line {d}: bad jump target", .{line_no});
            if (parts.index == null) return l.fail("line {d}: missing jump times", .{line_no});
            const times = parseUsize(parts.rest()) orelse return l.fail("line {d}: bad jump times", .{line_no});
            max_id = @max(max_id, id);
            try l.pushBuilt(line_no, try sequencer.buildJumpEntry(gpa, id, target, null, @max(times, 1)));
            continue;
        }

        if (std.mem.startsWith(u8, line, "P|")) {
            var parts = std.mem.splitScalar(u8, line[2..], '|');
            const id_s = parts.next() orelse return l.fail("line {d}: missing phrase id", .{line_no});
            const id = parseUsize(id_s) orelse return l.fail("line {d}: bad phrase id", .{line_no});
            const rep_s = parts.next() orelse return l.fail("line {d}: missing repeat", .{line_no});
            const repeat = parseUsize(rep_s) orelse return l.fail("line {d}: bad repeat", .{line_no});
            if (parts.index == null) return l.fail("line {d}: missing phrase source", .{line_no});
            const src = parts.rest();
            const cmd_src = if (repeat > 1)
                try std.fmt.allocPrint(gpa, "{s} r{d}", .{ src, repeat })
            else
                try gpa.dupe(u8, src);
            defer gpa.free(cmd_src);
            const parsed = try l.parse(line_no, cmd_src);
            defer parsed.deinit(gpa);
            const ap = switch (parsed) {
                .add_phrase => |v| v,
                else => return l.fail("line {d}: expected phrase command", .{line_no}),
            };
            try l.phrase(line_no, id, src, ap.specs, @max(ap.repeat, 1));
            max_id = @max(max_id, id);
            continue;
        }

        return l.fail("line {d}: unrecognized line", .{line_no});
    }
    return l.finish(.v1, max_id +| 1);
}

/// The V2 loader (app.rs `load_session_v2`): every line is a command; entries get sequential ids.
pub fn loadSessionV2(gpa: Allocator, lines: []const []const u8) Allocator.Error!LoadResult {
    return runLoader(gpa, v2Body, .{lines});
}

fn v2Body(l: *Loader, lines: []const []const u8) Error!Loaded {
    const gpa = l.gpa;
    Maqam.resetToDefaults();
    var next_id: usize = 0;

    for (lines, 0..) |raw_line, line_idx| {
        const line_no = line_idx + 2;
        const line = rs.trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        const parsed = try l.parse(line_no, line);
        defer parsed.deinit(gpa);
        switch (parsed) {
            .set_bpm => |c| {
                try l.bpm(line_no, next_id, c);
                next_id += 1;
            },
            .set_sustain => |c| {
                try l.sustain(line_no, next_id, c);
                next_id += 1;
            },
            .set_vcf => |c| {
                try l.vcfChange(line_no, next_id, c);
                next_id += 1;
            },
            .set_fx => |c| {
                try l.fxChange(line_no, next_id, c);
                next_id += 1;
            },
            .set_vol => {},
            .add_phrase => |v| {
                try l.phrase(line_no, next_id, v.source, v.specs, @max(v.repeat, 1));
                next_id += 1;
            },
            .jump => |j| {
                if (j.to < 0) return l.fail("line {d}: negative ids are only supported in interactive commands", .{line_no});
                var fail_target: ?usize = null;
                if (j.fail_to) |f| {
                    if (f < 0) return l.fail("line {d}: negative failure ids are only supported in interactive commands", .{line_no});
                    fail_target = @intCast(f);
                }
                try l.pushBuilt(line_no, try sequencer.buildJumpEntry(gpa, next_id, @intCast(j.to), fail_target, @max(j.times, 1)));
                next_id += 1;
            },
            .clear => {
                for (l.phrases.items) |*p| p.deinit(gpa);
                l.phrases.clearRetainingCapacity();
                next_id = 0;
                l.last_rhythm.clearRetainingCapacity();
                try l.last_rhythm.appendSlice(gpa, &.{ 3, 3, 2 });
            },
            .create_jins => |v| switch (try Maqam.create(v.name, v.ratios)) {
                .ok => {},
                .err => |m| return l.fail("line {d}: {s}", .{ line_no, m }),
            },
            .delete_jins => |v| {
                _ = Maqam.delete(v.name);
            },
            else => return l.fail("line {d}: unsupported command in session", .{line_no}),
        }
    }
    return l.finish(.v2, next_id);
}

/// Split text into lines like Rust `str::lines` (on `\n`, dropping one trailing `\r`; no final
/// empty line after a trailing newline). Free the slice with `gpa.free`.
pub fn splitLines(gpa: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        var line = text[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try out.append(gpa, line);
        start = end + 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Load a session file's text (app.rs `load_session` without the file read and the App update):
/// the header picks the V3, V2 or V1 loader. `current` is the App's live settings (a V1 file
/// starts from them).
pub fn load(gpa: Allocator, text: []const u8, current: Settings) Allocator.Error!LoadResult {
    const lines = try splitLines(gpa, text);
    defer gpa.free(lines);
    if (lines.len == 0) return .{ .err = try gpa.dupe(u8, "empty file") };
    const header = rs.trim(lines[0]);
    const body = lines[1..];
    if (std.mem.eql(u8, header, HEADER)) return loadSessionV3(gpa, body);
    if (std.mem.eql(u8, header, "MAQAM_SESSION_V2")) return loadSessionV2(gpa, body);
    if (std.mem.eql(u8, header, "MAQAM_SESSION_V1")) return loadSessionV1(gpa, body, current);
    return .{ .err = try gpa.dupe(u8, "bad header (expected MAQAM_SESSION_V3, MAQAM_SESSION_V2, or MAQAM_SESSION_V1)") };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectLoaded(r: LoadResult) !Loaded {
    return switch (r) {
        .ok => |l| l,
        .err => |m| {
            std.debug.print("load failed: {s}\n", .{m});
            testing.allocator.free(m);
            return error.TestUnexpectedResult;
        },
    };
}

fn idsOf(gpa: Allocator, phrases: []const Phrase) ![]usize {
    const out = try gpa.alloc(usize, phrases.len);
    for (phrases, 0..) |p, i| out[i] = p.id;
    return out;
}

fn expectErr(expected: []const u8, r: LoadResult) !void {
    var res = r;
    defer res.deinit(testing.allocator);
    switch (res) {
        .ok => return error.TestUnexpectedResult,
        .err => |m| try testing.expectEqualStrings(expected, m),
    }
}

test "loads and saves v3 without rewriting input" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    const source =
        "MAQAM_SESSION_V3\n" ++
        "create testv3 1/1 9/8 5/4\n" ++
        "vol 0.75\n" ++
        "B|4|180\n" ++
        "S|7|1.2\n" ++
        "Y|8|sym on\n" ++
        "Y|9|sym gain 64\n" ++
        "Y|10|sym decay 0.99\n" ++
        "P|11|2|g testv3 332\n" ++
        "J|15|11|3\n";
    var loaded = try expectLoaded(try load(gpa, source, .{}));
    defer loaded.deinit(gpa);
    const got = try idsOf(gpa, loaded.phrases);
    defer gpa.free(got);
    try testing.expectEqualSlices(usize, &.{ 4, 7, 8, 9, 10, 11, 15 }, got);
    try testing.expectEqual(ControlSpec{ .set_sympathetics = true }, loaded.phrases[2].control.?);
    try testing.expectEqual(ControlSpec{ .set_sympathetic_gain = 64.0 }, loaded.phrases[3].control.?);
    try testing.expectEqual(ControlSpec{ .set_sympathetic_decay = 0.99 }, loaded.phrases[4].control.?);
    try testing.expectEqual(@as(usize, 2), loaded.phrases[5].repeat);
    try testing.expectEqual(@as(usize, 11), loaded.phrases[6].jump.?.target_id);
    try testing.expectEqual(@as(usize, 16), loaded.next_phrase_id);
    try testing.expectEqual(@as(f64, 180), loaded.settings.bpm);
    try testing.expectEqual(@as(f64, 1.2), loaded.settings.sustain);

    const saved = try serializeSessionV3(gpa, loaded.phrases);
    defer gpa.free(saved);
    try testing.expect(std.mem.startsWith(u8, saved, "MAQAM_SESSION_V3\n"));
    try testing.expect(std.mem.indexOf(u8, saved, "\nvol ") == null);
    try testing.expect(std.mem.indexOf(u8, saved, "tuneto") == null);
    for ([_][]const u8{ "create testv3 1/1 9/8 5/4\n", "B|4|180\n", "Y|8|sym on\n", "Y|9|sym gain 64\n", "Y|10|sym decay 0.99\n", "P|11|2|g testv3 332\n", "J|15|11|3\n" }) |want| {
        if (std.mem.indexOf(u8, saved, want) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ want, saved });
            return error.TestUnexpectedResult;
        }
    }
}

test "tuneto is live state and not saved in sessions" {
    const gpa = testing.allocator;
    defer tuning.resetTuningBase();
    defer Maqam.resetToDefaults();
    tuning.tuneToStandardPitch(tuning.Pitch.parse("a").?);
    var loaded = try expectLoaded(try loadSessionV3(gpa, &.{"P|0|1|a major 44"}));
    defer loaded.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 440.0), loaded.phrases[0].bar.root_hz, 0.0001);
    const saved = try serializeSessionV3(gpa, loaded.phrases);
    defer gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "tuneto") == null);
    try testing.expect(std.mem.indexOf(u8, saved, "P|0|1|a major 44\n") != null);
}

test "loads legacy control lines under v3 header" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    var loaded = try expectLoaded(try loadSessionV3(gpa, &.{ "bpm 180", "s 1.2", "P|2|1|g hijaz 4444" }));
    defer loaded.deinit(gpa);
    const got = try idsOf(gpa, loaded.phrases);
    defer gpa.free(got);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, got);
    try testing.expectEqual(@as(f64, 180.0), loaded.settings.bpm);
    try testing.expectEqual(@as(f64, 1.2), loaded.settings.sustain);
    try testing.expectEqual(@as(f64, 180.0), loaded.start.bpm);
}

test "loads vcf control lines under v3 header" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    var loaded = try expectLoaded(try loadSessionV3(gpa, &.{
        "vcf bass cut=900 res=0.65 drive=3.5",
        "cut +100",
        "V|5|kanun|1200|0.4|2.25",
        "P|6|1|g hijaz 4444",
    }));
    defer loaded.deinit(gpa);
    const got = try idsOf(gpa, loaded.phrases);
    defer gpa.free(got);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 5, 6 }, got);
    try testing.expectEqual(@as(f32, 1200.0), loaded.settings.vcf.kanun.cutoff_hz);
    try testing.expectEqual(@as(f32, 0.4), loaded.settings.vcf.kanun.resonance);
    try testing.expectEqual(@as(f32, 2.25), loaded.settings.vcf.kanun.drive);
    try testing.expectEqual(VcfTarget.kanun, loaded.settings.vcf.kanun.target);
}

test "missing nam live state does not block session load" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    var loaded = try expectLoaded(try loadSessionV3(gpa, &.{ "nam practice", "P|0|1|d bayati 4444" }));
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loaded.live_nam_commands.len);
    try testing.expectEqualStrings("nam practice", loaded.live_nam_commands[0]);
    try testing.expectEqual(@as(usize, 2), loaded.phrases.len);
    try testing.expectEqualStrings("nam practice", loaded.phrases[0].src);
    try testing.expectEqual(ControlSpec{ .set_nam_enabled = true }, loaded.phrases[0].control.?);
    try testing.expectEqualStrings("d bayati 4444", loaded.phrases[1].src);
    // The App resolves the row (here: no cached "practice", so it becomes the pending slot).
    try testing.expectEqual(@as(usize, 1), loaded.nam_rows.len);
    try testing.expectEqual(@as(usize, 2), loaded.nam_rows[0].line_no);
    try testing.expectEqualStrings("practice", loaded.nam_rows[0].command.load.path);
    try testing.expect(!loaded.nam_rows[0].record);
}

test "loads rewritten v1 session with custom jins" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    var loaded = try expectLoaded(try loadSessionV1(gpa, &.{
        "create saba2 1/1 13/12 6/5 5/4",
        "vol 1",
        "bpm 180",
        "s 2",
        "P|2|1|d bayati, f hijaz 4444",
        "J|3|0|3",
        "P|4|1|a saba, c hijaz",
        "P|5|1|a saba2, c hijaz",
        "J|6|4|4",
        "P|7|1|g rast 664664",
        "J|8|7|4",
    }, .{}));
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 9), loaded.phrases.len);
    try testing.expectEqual(@as(usize, 9), loaded.next_phrase_id);
    try testing.expectEqual(@as(usize, 1), loaded.custom_jins.len);
    try testing.expectEqualStrings("saba2", loaded.custom_jins[0].name);
    // P rows without a rhythm inherit the previous one.
    try testing.expectEqualSlices(u8, &.{ 4, 4, 4, 4 }, loaded.phrases[4].bar.groups);
    try testing.expectEqualSlices(u8, &.{ 6, 6, 4, 6, 6, 4 }, loaded.last_rhythm);
}

test "v1 repeats, V2 sequential ids and clear" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    var v1 = try expectLoaded(try load(gpa, "MAQAM_SESSION_V1\r\nP|3|4|d bayati 332\r\n", .{ .bpm = 99 }));
    defer v1.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), v1.phrases[0].repeat);
    try testing.expectEqualStrings("d bayati 332", v1.phrases[0].src);
    try testing.expectEqual(@as(f64, 99), v1.settings.bpm); // V1 starts from the App's settings
    try testing.expectEqual(@as(f64, 120), v1.start.bpm);
    try testing.expectEqual(@as(usize, 4), v1.next_phrase_id);

    var v2 = try expectLoaded(try load(gpa, "MAQAM_SESSION_V2\nd rast 44\nclear\nbpm 90\ncreate Qq 1/1 9/8 5/4 4/3\nd qq 332 r2\nvol 0.3\nj 1 2\ndelete Qq\n", .{}));
    defer v2.deinit(gpa);
    const got = try idsOf(gpa, v2.phrases);
    defer gpa.free(got);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, got);
    try testing.expectEqual(@as(usize, 3), v2.next_phrase_id);
    try testing.expectEqual(@as(usize, 2), v2.phrases[1].repeat);
    try testing.expectEqualStrings("j 1 2", v2.phrases[2].src);
    try testing.expectEqual(@as(usize, 0), v2.custom_jins.len); // deleted again
    try testing.expectEqual(@as(f64, 90), v2.start.bpm);
}

test "errors carry the line number and the Rust text" {
    const gpa = testing.allocator;
    defer Maqam.resetToDefaults();
    try expectErr("empty file", try load(gpa, "", .{}));
    try expectErr("bad header (expected MAQAM_SESSION_V3, MAQAM_SESSION_V2, or MAQAM_SESSION_V1)", try load(gpa, "\n", .{}));
    try expectErr("line 2: bpm out of range", try loadSessionV3(gpa, &.{"B|0|500"}));
    try expectErr("line 3: duplicate id 1", try loadSessionV3(gpa, &.{ "B|1|90", "S|1|1" }));
    try expectErr("line 2: bad id", try loadSessionV3(gpa, &.{"P|x|1|d rast 4"}));
    try expectErr("line 2: missing id", try loadSessionV3(gpa, &.{"tuneto a"}));
    try expectErr("line 2: malformed V3 record", try loadSessionV3(gpa, &.{"Q|1|x"}));
    try expectErr("line 2: bad jump times", try loadSessionV3(gpa, &.{"J|1|0|x"}));
    try expectErr("line 2: bad bpm", try loadSessionV3(gpa, &.{"B|1|fast"}));
    try expectErr("line 2: sustain out of range", try loadSessionV3(gpa, &.{"S|1|NaN"}));
    try expectErr("line 2: NAM command cannot be scheduled", try loadSessionV3(gpa, &.{"N|1|nam list"}));
    try expectErr("line 2: expected sym line", try loadSessionV3(gpa, &.{"Y|1|bpm 90"}));
    try expectErr("line 2: bad vcf enabled flag", try loadSessionV3(gpa, &.{"V|1|kanun|900|0.5|2|maybe"}));
    try expectErr("line 3: unrecognized line", try loadSessionV1(gpa, &.{ "", "zzz" }, .{}));
    try expectErr("line 2: unsupported command in session", try loadSessionV2(gpa, &.{"rot"}));
    try expectErr("line 2: negative ids are only supported in interactive commands", try loadSessionV2(gpa, &.{"j -1"}));
    try expectErr("line 2: bpm 500 out of range", try loadSessionV2(gpa, &.{"bpm 500"}));
    try expectErr("line 2: sustain 20s out of range", try loadSessionV3(gpa, &.{"s 20"}));
    // The bounds and the upstream panic are rejections here.
    try expectErr("line 2: repeat 21 is too many; a phrase repeats at most r20 (use a jump for longer loops)", try loadSessionV3(gpa, &.{"P|1|21|d rast 4"}));
    try expectErr("line 2: jump times 10001 is too many; use 1..10000, or always", try loadSessionV3(gpa, &.{"J|1|0|10001"}));
    try expectErr(
        "line 3: a phrase needs at least 3 notes in its scale, but this one has 1; give the jins more ratios (create Zz 1/1 9/8 5/4) or stack another jins after a comma",
        try loadSessionV3(gpa, &.{ "create Zz 1/1", "P|0|1|d zz 4" }),
    );
    // A command parse error is passed through with its line.
    var r = try loadSessionV3(gpa, &.{ "# comment", "P|0|1|nonsense" });
    defer r.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, r.err, "line 3: "));
}

test "escaping round trips" {
    const gpa = testing.allocator;
    const f = try splitEscapedFields(gpa, "P|1|2|a\\|b\\\\c\\nd\\x\\");
    defer freeFields(gpa, f);
    try testing.expectEqual(@as(usize, 4), f.len);
    try testing.expectEqualStrings("a|b\\c\nd\\x\\", f[3]);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendEscaped(&out, gpa, "a|b\\c\nd");
    const back = try splitEscapedFields(gpa, out.items);
    defer freeFields(gpa, back);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings("a|b\\c\nd", back[0]);
}

test "change sources" {
    const gpa = testing.allocator;
    const cases = [_]struct { ValueChange, []const u8 }{
        .{ .{ .set = 120 }, "120" },     .{ .{ .add = -5 }, "-5" }, .{ .{ .add = 2.5 }, "+2.5" },
        .{ .{ .mul = 2 }, "*2" },        .{ .{ .div = 3 }, "/3" },  .{ .{ .tick = 10 }, "+10t" },
        .{ .{ .tick = -0.5 }, "-0.5t" },
    };
    for (cases) |c| {
        const s = try valueChangeSrc(gpa, c[0]);
        defer gpa.free(s);
        try testing.expectEqualStrings(c[1], s);
    }
    const v = try vcfChangeSrc(gpa, .{ .target = .kanun, .cutoff_hz = .{ .set = 900 }, .wave = .squ });
    defer gpa.free(v);
    try testing.expectEqualStrings("vcf kanun cut 900 wave squ", v);
    const v2 = try vcfChangeSrc(gpa, .{ .target = .all, .enabled = false });
    defer gpa.free(v2);
    try testing.expectEqualStrings("vcf off", v2);
    const f1 = try fxChangeSrc(gpa, .{ .reverb_mix = .{ .set = 0.3 } });
    defer gpa.free(f1);
    try testing.expectEqualStrings("reverb mix 0.3", f1);
    const f2 = try fxChangeSrc(gpa, .{ .flanger_enabled = false, .chorus_enabled = false, .reverb_enabled = false, .delay_enabled = false, .cabinet_enabled = false });
    defer gpa.free(f2);
    try testing.expectEqualStrings("fx off", f2);
    const int1 = try symIntervalName(gpa, 3.0 / 2.0);
    defer gpa.free(int1);
    try testing.expectEqualStrings("fifth", int1);
    const int2 = try symIntervalName(gpa, 1.3);
    defer gpa.free(int2);
    try testing.expectEqualStrings("1.30000", int2);
    var h: command.SympatheticHarmony = .{};
    _ = h.push(.{ .ratio = 1.0, .weight = 1.0 });
    _ = h.push(.{ .ratio = 1.5, .weight = 0.5 });
    const s1 = try symChangeSrc(gpa, .{ .enabled = true, .decay = 0.995, .gain = 2, .interval_ratio = 0.5, .harmony = h, .amount = 0.25 });
    defer gpa.free(s1);
    try testing.expectEqualStrings("sym on decay 0.995 drive 2 down octave harmony root 1.00 fifth 0.50 amount 0.25", s1);
}

test "live nam commands keep one gain and one state" {
    const gpa = testing.allocator;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |c| gpa.free(c);
        list.deinit(gpa);
    }
    try replaceLiveNamCommand(gpa, &list, try gpa.dupe(u8, "nam amp"));
    try replaceLiveNamCommand(gpa, &list, try gpa.dupe(u8, "nam gain 2"));
    try replaceLiveNamCommand(gpa, &list, try gpa.dupe(u8, "nam off"));
    try replaceLiveNamCommand(gpa, &list, try gpa.dupe(u8, "nam gain 3"));
    try replaceLiveNamCommand(gpa, &list, null);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("nam off", list.items[0]);
    try testing.expectEqualStrings("nam gain 3", list.items[1]);
    const g = (try namCommandSrc(gpa, .{ .gain = 1.5 })).?;
    defer gpa.free(g);
    try testing.expectEqualStrings("nam gain 1.5", g);
    try testing.expectEqual(@as(?[]u8, null), try namCommandSrc(gpa, .login));
}

/// Property "Session round trip": load(save(timeline)) has the same entries, ids, sources and
/// custom jins, and the saved text never holds vol or tuneto. Saving again gives the same text.
fn expectRoundTrip(gpa: Allocator, text: []const u8, name: []const u8) !void {
    defer Maqam.resetToDefaults();
    var first = switch (try load(gpa, text, .{})) {
        .ok => |l| l,
        .err => |m| {
            defer gpa.free(m);
            std.debug.print("{s} failed to load: {s}\n", .{ name, m });
            return error.TestUnexpectedResult;
        },
    };
    defer first.deinit(gpa);
    try testing.expect(first.phrases.len > 0);
    for (first.phrases) |p| try testing.expect(p.id < first.next_phrase_id);

    const saved = try serializeSessionV3(gpa, first.phrases);
    defer gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\nvol ") == null);
    try testing.expect(std.mem.indexOf(u8, saved, "tuneto") == null);

    var second = switch (try load(gpa, saved, .{})) {
        .ok => |l| l,
        .err => |m| {
            defer gpa.free(m);
            std.debug.print("{s}: saved text failed to load: {s}\n{s}\n", .{ name, m, saved });
            return error.TestUnexpectedResult;
        },
    };
    defer second.deinit(gpa);
    try testing.expectEqual(first.phrases.len, second.phrases.len);
    var any_legacy_off = false;
    for (first.phrases, second.phrases) |a, b| {
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqualStrings(a.src, b.src);
        try testing.expectEqual(a.repeat, b.repeat);
        try testing.expect(std.meta.eql(a.jump, b.jump));
        // A legacy positional V record that turns a filter off keeps its other values in the
        // change, but its source (all a session stores) says only "vcf <target> off": compare
        // what the source determines.
        const legacy_off = a.control != null and a.control.? == .set_vcf and a.control.?.set_vcf.enabled == false;
        if (legacy_off) {
            any_legacy_off = true;
            try testing.expect(b.control != null and b.control.? == .set_vcf);
            const sa = try vcfChangeSrc(gpa, a.control.?.set_vcf);
            defer gpa.free(sa);
            const sb = try vcfChangeSrc(gpa, b.control.?.set_vcf);
            defer gpa.free(sb);
            try testing.expectEqualStrings(sa, sb);
        } else if (!std.meta.eql(a.control, b.control)) {
            std.debug.print("{s}: id {d} '{s}': {any} vs {any}\n", .{ name, a.id, a.src, a.control, b.control });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualSlices(f64, a.bar.frequencies, b.bar.frequencies);
        try testing.expectEqualSlices(u8, a.bar.groups, b.bar.groups);
    }
    try testing.expectEqual(first.next_phrase_id, second.next_phrase_id);
    try testing.expectEqual(first.custom_jins.len, second.custom_jins.len);
    for (first.custom_jins, second.custom_jins) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqual(a.ratios.len, b.ratios.len);
        for (a.ratios, b.ratios) |x, y| try testing.expect(x.eql(y));
    }
    // (The values a legacy "off" record drops also drop out of the disabled filter's settings.)
    if (!any_legacy_off) try testing.expect(std.meta.eql(first.start, second.start));
    try testing.expectEqual(first.start.bpm, second.start.bpm);
    try testing.expectEqual(first.start.sustain, second.start.sustain);
    try testing.expect(std.meta.eql(first.start.fx, second.start.fx));
    const again = try serializeSessionV3(gpa, second.phrases);
    defer gpa.free(again);
    try testing.expectEqualStrings(saved, again);
}

test "session round trip: constructed sessions" {
    const gpa = testing.allocator;
    const sessions = [_][]const u8{
        "MAQAM_SESSION_V3\ncreate testv3 1/1 9/8 5/4\nvol 0.75\nB|4|180\nS|7|1.2\nY|8|sym on\nY|9|sym gain 64\nY|10|sym decay 0.99\nP|11|2|g testv3 332\nJ|15|11|3\n",
        "MAQAM_SESSION_V3\nbpm 180\ns 1.2\nvcf bass cut=900 res=0.65 drive=3.5\ncut +100\nV|5|kanun|1200|0.4|2.25\nV|7|drums|300|0.2|1|off\nV|8|bass|700|0.5|1.5|on|saw\nP|6|1|g hijaz 4444\n",
        "MAQAM_SESSION_V3\nnam practice\nnam gain 2\nN|9|nam tone3000 45896 as mesaboogie\nN|10|nam input left\nN|11|nam off\nN|13|nam C:\\\\amps\\\\x\\|y.nam\nP|0|3|d bayati, a nahawand 332\nJ|1|0|0\nT|12|stop\n",
        "MAQAM_SESSION_V3\nP|0|1|d rast 44\nF|1|reverb mix 0.3 decay 0.8\nF|2|delay time 0.25 feedback 0.4 mix 0.2\nF|3|fx off\nY|4|sym kanun on decay 0.995 drive 2 amount 0.5\nJ|5|0|1|2\n",
        "MAQAM_SESSION_V1\ncreate saba2 1/1 13/12 6/5 5/4\nvol 1\nbpm 180\ns 2\nP|2|1|d bayati, f hijaz 4444\nJ|3|0|3\nP|4|1|a saba, c hijaz\nP|5|1|a saba2, c hijaz\nJ|6|4|4\nP|7|2|g rast 664664\nJ|8|7|4\n",
        "MAQAM_SESSION_V2\ncreate Qq 1/1 9/8 5/4 4/3\nbpm 100\ns 0.5\nd qq 332 r2\nj 0 3\nreverb mix 0.2\nvcf kanun cut 800\n",
    };
    for (sessions, 0..) |s, i| {
        var nb: [32]u8 = undefined;
        expectRoundTrip(gpa, s, try std.fmt.bufPrint(&nb, "session {d}", .{i})) catch |e| {
            std.debug.print("round trip failed for session {d}\n", .{i});
            return e;
        };
    }
}

test "session round trip: every bundled .mq file" {
    // The bundled sessions name NAM captures and TONE3000 tones: loading only records those rows,
    // so this touches neither the network nor a browser.
    const gpa = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".mq")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    // The ones the Rust test names, and the bundle as it stands, are all there.
    const expected = [_][]const u8{ "default.mq", "magiccarpet.mq", "growl.mq", "nama2.mq", "practice.mq", "vocals.mq" };
    for (expected) |want| {
        var found = false;
        for (names.items) |n| if (std.mem.eql(u8, n, want)) {
            found = true;
        };
        if (!found) {
            std.debug.print("bundled session {s} not found (run the tests from impl/zig/source)\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
        defer gpa.free(text);
        try testing.expect(std.mem.startsWith(u8, text, "MAQAM_SESSION_V3\n"));
        expectRoundTrip(gpa, text, name) catch |e| {
            std.debug.print("round trip failed for {s}\n", .{name});
            return e;
        };
    }
}

test "loading never leaks when allocation fails" {
    const text = "MAQAM_SESSION_V3\ncreate testv3 1/1 9/8 5/4\nnam practice\nbpm 100\nB|4|180\nY|8|sym on\nV|5|kanun|1200|0.4|2.25\nN|9|nam tone3000 1 as x\nP|11|2|g testv3 332\nJ|15|11|3\n";
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: Allocator) !void {
            defer Maqam.resetToDefaults();
            var r = try load(a, text, .{});
            defer r.deinit(a);
            if (r == .ok) {
                const s = try serializeSessionV3(a, r.ok.phrases);
                a.free(s);
            }
        }
    }.run, .{});
}

test "number parsing follows Rust" {
    try testing.expectEqual(@as(?usize, 12), parseUsize("+12"));
    try testing.expectEqual(@as(?usize, null), parseUsize("-1"));
    try testing.expectEqual(@as(?usize, null), parseUsize("1_0"));
    try testing.expectEqual(@as(?usize, null), parseUsize("99999999999999999999999"));
    try testing.expectEqual(@as(?f64, 0.5), parseFloat(f64, ".5"));
    try testing.expectEqual(@as(?f64, 5.0), parseFloat(f64, "5."));
    try testing.expectEqual(@as(?f64, 1e3), parseFloat(f64, "1E3"));
    try testing.expect(std.math.isInf(parseFloat(f64, "-Infinity").?));
    try testing.expect(std.math.isNan(parseFloat(f64, "nan").?));
    try testing.expectEqual(@as(?f64, null), parseFloat(f64, "0x10"));
    try testing.expectEqual(@as(?f64, null), parseFloat(f64, "1_000"));
    try testing.expectEqual(@as(?f64, null), parseFloat(f64, "e5"));
    try testing.expectEqual(@as(?f64, null), parseFloat(f64, "."));
}
