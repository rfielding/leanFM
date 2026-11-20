//! Port of maqam-live `src/carpet.rs`: the static picture layers of an MP4 recording (the carpet
//! background, the center Gosper overlay, the jump arrows overlay), and the score geometry the
//! recorder animates over them (`WeaveScore`, `scoreBorderLayout`, `jumpLinkCells`,
//! `jumpCounterLayout`). Every layer is 1280x720 RGB with the Rust's pixel math (f32 throughout,
//! Rust `as` casts reproduced as saturating casts with NaN -> 0).
//!
//! Deliberate differences from the Rust:
//! * The layers are written as PNG (png.zig) instead of binary PPM; the pixels are the same.
//! * The `render*` functions (new) return the RGB buffer, so tests can check a layer without a
//!   file; `write*` take an `Io` and a directory, and the returned `CarpetRenderInfo.path`
//!   borrows the caller's path instead of owning a copy.
//! * Text is decoded as UTF-8 leniently: an invalid byte counts as one (blank) character, where a
//!   Rust `String` cannot hold invalid UTF-8.
//! * Phrase lookups by id use the first phrase with that id (as the Rust `find`), and score bounds
//!   for a duplicated id span all of its ticks (as the Rust's per-id filter).
const std = @import("std");
const sequencer = @import("sequencer.zig");
const png = @import("png.zig");

const Phrase = sequencer.Phrase;
const rust_str = sequencer.rust_str;
const Allocator = std.mem.Allocator;
const TAU: f32 = std.math.tau;

pub const CARPET_H: usize = 720;
pub const CARPET_START_X: usize = 1180;
pub const CARPET_STEP_X: usize = 30;
pub const W: usize = 1280;
const CX: f32 = 640.0;
const CY: f32 = 360.0;
const INNER_R: f32 = 175.0;
const BEAT_R: f32 = 214.0;
const LABEL_R: f32 = 328.0;
const CARPET_X0: f32 = 64.0;
const CARPET_Y0: f32 = 50.0;
const CARPET_X1_PAD: f32 = 64.0;
const CARPET_Y1: f32 = 670.0;

/// Bytes of one RGB layer.
pub const layer_bytes: usize = W * CARPET_H * 3;

pub const CarpetEntry = struct {
    phrase_idx: usize,
    bpm: f64,
    sustain: f64,
};

pub const CarpetRenderInfo = struct {
    /// Borrowed from the caller's path argument.
    path: []const u8,
    width: usize,
    content_end_x: usize,
};

pub const WeaveTick = struct {
    phrase_id: usize,
    group_index: usize,
    tick_in_group: usize,
    group_len: usize,
};

pub const WeavePhrase = struct {
    phrase_id: usize,
    /// Borrowed from the phrase's bar.
    groups: []const u8,
    first_tick: usize,
    tick_count: usize,
};

pub const WeaveScore = struct {
    phrases: []WeavePhrase = &.{},
    ticks: []WeaveTick = &.{},

    /// The Rust `WeaveScore::from_phrases`. Free with `deinit`.
    pub fn fromPhrases(gpa: Allocator, phrases: []const Phrase) Allocator.Error!WeaveScore {
        var ps: std.ArrayList(WeavePhrase) = .empty;
        errdefer ps.deinit(gpa);
        var ts: std.ArrayList(WeaveTick) = .empty;
        errdefer ts.deinit(gpa);
        for (phrases) |*phrase| {
            if (phrase.jump != null or phrase.control != null) continue;
            // The design ring represents exactly what was entered for each phrase. Phrase
            // repeats and jumps do not duplicate ring beats, but repeated rhythm groups inside
            // the phrase are real beats.
            const groups = phrase.bar.groups;
            const first_tick = ts.items.len;
            for (groups, 0..) |group_len, group_index| {
                var tick_in_group: usize = 0;
                while (tick_in_group < group_len) : (tick_in_group += 1) {
                    try ts.append(gpa, .{
                        .phrase_id = phrase.id,
                        .group_index = group_index,
                        .tick_in_group = tick_in_group,
                        .group_len = group_len,
                    });
                }
            }
            try ps.append(gpa, .{
                .phrase_id = phrase.id,
                .groups = groups,
                .first_tick = first_tick,
                .tick_count = ts.items.len - first_tick,
            });
        }
        const p = try ps.toOwnedSlice(gpa);
        errdefer gpa.free(p);
        return .{ .phrases = p, .ticks = try ts.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *WeaveScore, gpa: Allocator) void {
        gpa.free(self.phrases);
        gpa.free(self.ticks);
        self.* = .{};
    }
};

pub const BorderTickLayout = struct {
    phrase_id: usize,
    score_tick: usize,
    x: f32,
    y: f32,
    is_kick: bool,
    start_t: f32,
    end_t: f32,
};

pub const JumpLinkCell = struct {
    jump_id: usize,
    x: f32,
    y: f32,
    size: i32,
};

pub const JumpCounterLayout = struct {
    jump_id: usize,
    x: f32,
    y: f32,
};

const JumpRoute = struct {
    jump_id: usize,
    source_phrase_id: usize,
    target_phrase_id: usize,
    source_t: f32,
    target_t: f32,
};

const Pt = struct {
    x: f32,
    y: f32,
    fn new(x: f32, y: f32) Pt {
        return .{ .x = x, .y = y };
    }
    fn add(self: Pt, o: Pt) Pt {
        return new(self.x + o.x, self.y + o.y);
    }
    fn mul(self: Pt, k: f32) Pt {
        return new(self.x * k, self.y * k);
    }
};

const Rgb = [3]u8;

// ── Rust `as` casts (saturating, NaN -> 0) ───────────────────────────────────

pub fn asI32(x: f32) i32 {
    if (std.math.isNan(x)) return 0;
    if (x >= 2147483647.0) return std.math.maxInt(i32);
    if (x <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(x);
}

fn asU8(x: f32) u8 {
    if (std.math.isNan(x) or x <= 0.0) return 0;
    if (x >= 255.0) return 255;
    return @intFromFloat(x);
}

fn asUsize(x: f32) usize {
    if (std.math.isNan(x) or x <= 0.0) return 0;
    if (x >= 1.8446744e19) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

fn roundI32(x: f32) i32 {
    return asI32(@round(x));
}

fn fclamp(x: f32, lo: f32, hi: f32) f32 {
    var v = x;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

/// Rust `f32::rem_euclid`.
fn remEuclid(x: f32, m: f32) f32 {
    const r = @rem(x, m);
    return if (r < 0.0) r + @abs(m) else r;
}

// ── Drawing primitives ───────────────────────────────────────────────────────

fn clamp01(x: f32) f32 {
    return fclamp(x, 0.0, 1.0);
}

fn blendPx(buf: []u8, w: usize, x: i32, y: i32, rgb: Rgb, a_in: f32) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(w)) or y >= @as(i32, @intCast(CARPET_H))) return;
    const a = clamp01(a_in);
    const i = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 3;
    for (0..3) |c| {
        const b: f32 = @floatFromInt(buf[i + c]);
        const o: f32 = @floatFromInt(rgb[c]);
        buf[i + c] = asU8(fclamp(@round(b * (1.0 - a) + o * a), 0.0, 255.0));
    }
}

fn putPx(buf: []u8, w: usize, x: usize, y: usize, rgb: Rgb) void {
    if (x < w and y < CARPET_H) {
        const i = (y * w + x) * 3;
        @memcpy(buf[i..][0..3], &rgb);
    }
}

fn line(buf: []u8, w: usize, x0_in: i32, y0_in: i32, x1: i32, y1: i32, rgb: Rgb, a: f32) void {
    // i64 so that no coordinate the score can produce overflows (the Rust's i32 math would).
    var x0: i64 = x0_in;
    var y0: i64 = y0_in;
    const dx: i64 = @intCast(@abs(@as(i64, x1) - x0));
    const sx: i64 = if (x0 < x1) 1 else -1;
    const dy: i64 = -@as(i64, @intCast(@abs(@as(i64, y1) - y0)));
    const sy: i64 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    // A segment wholly off the picture draws nothing; skip walking it.
    const wi: i64 = @intCast(w);
    const hi: i64 = @intCast(CARPET_H);
    if ((x0 < 0 and x1 < 0) or (y0 < 0 and y1 < 0) or (x0 >= wi and x1 >= wi) or (y0 >= hi and y1 >= hi)) return;
    while (true) {
        if (x0 >= std.math.minInt(i32) and x0 <= std.math.maxInt(i32) and y0 >= std.math.minInt(i32) and y0 <= std.math.maxInt(i32))
            blendPx(buf, w, @intCast(x0), @intCast(y0), rgb, a);
        if (x0 == x1 and y0 == y1) break;
        const e2 = err * 2;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn thickLine(buf: []u8, w: usize, x0: i32, y0: i32, x1: i32, y1: i32, rgb: Rgb, a: f32, t: i32) void {
    const half: i32 = @divTrunc(@max(t, 1), 2);
    var off: i32 = -half;
    while (off <= half) : (off += 1) {
        line(buf, w, x0 +| off, y0, x1 +| off, y1, rgb, a);
        line(buf, w, x0, y0 +| off, x1, y1 +| off, rgb, a);
    }
}

fn dot(buf: []u8, w: usize, cx: i32, cy: i32, r_in: i32, rgb: Rgb, a: f32) void {
    const r: i32 = @max(r_in, 1);
    const rr: f32 = @floatFromInt(r * r);
    var y: i32 = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x: i32 = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx: f32 = @floatFromInt(x - cx);
            const dy: f32 = @floatFromInt(y - cy);
            const d2 = dx * dx + dy * dy;
            if (d2 <= rr) {
                const falloff = 0.35 + 0.65 * (1.0 - @sqrt(d2 / rr));
                blendPx(buf, w, x, y, rgb, a * falloff);
            }
        }
    }
}

fn hash(x_in: u32) u32 {
    var x = x_in;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    return x ^ (x >> 16);
}

fn hash01(x: u32) f32 {
    return @as(f32, @floatFromInt(hash(x))) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

fn phraseColor(phrase_id: usize) Rgb {
    const colors = [8]Rgb{
        .{ 88, 44, 122 },
        .{ 32, 110, 78 },
        .{ 30, 104, 132 },
        .{ 148, 74, 46 },
        .{ 132, 105, 42 },
        .{ 78, 92, 126 },
        .{ 118, 70, 112 },
        .{ 108, 78, 48 },
    };
    return colors[phrase_id % colors.len];
}

fn dark(c: Rgb, k: f32) Rgb {
    var out: Rgb = undefined;
    for (0..3) |i| out[i] = asU8(@round(@as(f32, @floatFromInt(c[i])) * (1.0 - k)));
    return out;
}

fn light(c: Rgb, k: f32) Rgb {
    var out: Rgb = undefined;
    for (0..3) |i| out[i] = asU8(@min(@round(@as(f32, @floatFromInt(c[i])) * (1.0 - k) + 255.0 * k), 255.0));
    return out;
}

// ── Text ─────────────────────────────────────────────────────────────────────

/// Lenient UTF-8 iteration: each scalar value, or each invalid byte, is one character.
const Chars = struct {
    s: []const u8,
    i: usize = 0,
    fn next(self: *Chars) ?u21 {
        if (self.i >= self.s.len) return null;
        const b = self.s[self.i];
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + n > self.s.len) {
            self.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.s[self.i..][0..n]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        self.i += n;
        return cp;
    }
};

fn charCount(s: []const u8) usize {
    var it: Chars = .{ .s = s };
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

fn glyph(c: u21) [7]u8 {
    const u: u8 = if (c < 128) std.ascii.toUpper(@intCast(c)) else 0;
    return switch (u) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 14 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
        'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        '/' => .{ 1, 1, 2, 4, 8, 16, 16 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

fn textWidth(s: []const u8, scale: i32) i32 {
    const n: i64 = @intCast(@min(charCount(s), std.math.maxInt(i32)));
    return @intCast(std.math.clamp(n * 6 * scale, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn drawText(buf: []u8, w: usize, text: []const u8, x: i32, y: i32, scale: i32, rgb: Rgb, a: f32) void {
    var xx: i32 = x;
    var it: Chars = .{ .s = text };
    while (it.next()) |ch| {
        // Characters entirely right of the picture draw nothing (and keep xx from overflowing).
        if (xx >= @as(i32, @intCast(w))) break;
        const rows = glyph(ch);
        for (rows, 0..) |row, yy| {
            var bit: i32 = 0;
            while (bit < 5) : (bit += 1) {
                if ((row >> @intCast(4 - bit)) & 1 == 1) {
                    var dy: i32 = 0;
                    while (dy < scale) : (dy += 1) {
                        var dx: i32 = 0;
                        while (dx < scale) : (dx += 1) {
                            blendPx(buf, w, xx + bit * scale + dx, y + @as(i32, @intCast(yy)) * scale + dy, rgb, a);
                        }
                    }
                }
            }
        }
        xx += 6 * scale;
    }
}

fn drawLabelBox(buf: []u8, w: usize, x: i32, y: i32, title: []const u8, ratios: []const u8) void {
    const ts: i32 = 2;
    const rs: i32 = 1;
    const tw: i32 = @max(@max(textWidth(title, ts), textWidth(ratios, rs)), 48);
    const bw: i32 = tw +| 16;
    const bh: i32 = 8 + 7 * ts + 5 + 7 * rs + 8;
    var x0: i32 = x -| @divTrunc(bw, 2);
    var y0: i32 = y -| @divTrunc(bh, 2);
    // Rust `i32::clamp(74, w - bw - 74)`, which panics when the box is wider than the picture;
    // max(lo, min(x, hi)) keeps the same result whenever the Rust does not panic.
    x0 = @max(74, @min(x0, @as(i32, @intCast(w)) -| bw -| 74));
    y0 = @max(58, @min(y0, @as(i32, @intCast(CARPET_H)) - bh - 58));
    var yy = y0;
    while (yy < y0 + bh) : (yy += 1) {
        var xx = x0;
        const x_end: i32 = @min(x0 +| bw, @as(i32, @intCast(w)));
        while (xx < x_end) : (xx += 1) blendPx(buf, w, xx, yy, .{ 0, 0, 0 }, 0.96);
    }
    const edge: Rgb = .{ 48, 36, 18 };
    thickLine(buf, w, x0, y0, x0 +| bw, y0, edge, 0.82, 2);
    thickLine(buf, w, x0, y0 + bh, x0 +| bw, y0 + bh, edge, 0.82, 2);
    thickLine(buf, w, x0, y0, x0, y0 + bh, edge, 0.82, 2);
    thickLine(buf, w, x0 +| bw, y0, x0 +| bw, y0 + bh, edge, 0.82, 2);
    drawText(buf, w, title, x0 + 8, y0 + 7, ts, .{ 150, 112, 54 }, 0.78);
    drawText(buf, w, ratios, x0 + 8, y0 + 7 + 7 * ts + 5, rs, .{ 118, 88, 42 }, 0.72);
}

// ── Curves ───────────────────────────────────────────────────────────────────

fn hilbertRot(n: i32, x: *i32, y: *i32, rx: i32, ry: i32) void {
    if (ry == 0) {
        if (rx == 1) {
            x.* = n - 1 - x.*;
            y.* = n - 1 - y.*;
        }
        std.mem.swap(i32, x, y);
    }
}

fn hilbertD2xy(order: u5, d_in: i32) Pt {
    const n: i32 = @as(i32, 1) << order;
    var d = d_in;
    var x: i32 = 0;
    var y: i32 = 0;
    var s: i32 = 1;
    while (s < n) {
        const rx = 1 & @divTrunc(d, 2);
        const ry = 1 & (d ^ rx);
        hilbertRot(s, &x, &y, rx, ry);
        x += s * rx;
        y += s * ry;
        d = @divTrunc(d, 4);
        s *= 2;
    }
    return Pt.new(@floatFromInt(x), @floatFromInt(y));
}

fn hilbertPoints(gpa: Allocator, comptime order: u5) Allocator.Error![]Pt {
    const n: i32 = @as(i32, 1) << order;
    const pts = try gpa.alloc(Pt, @intCast(n * n));
    for (pts, 0..) |*p, d| p.* = hilbertD2xy(order, @intCast(d));
    return pts;
}

const Extent = struct { minx: f32, maxx: f32, miny: f32, maxy: f32 };
fn extent(pts: []const Pt) Extent {
    var e: Extent = .{ .minx = std.math.inf(f32), .maxx = -std.math.inf(f32), .miny = std.math.inf(f32), .maxy = -std.math.inf(f32) };
    for (pts) |p| {
        e.minx = @min(e.minx, p.x);
        e.maxx = @max(e.maxx, p.x);
        e.miny = @min(e.miny, p.y);
        e.maxy = @max(e.maxy, p.y);
    }
    return e;
}

/// In place (the Rust returns a new Vec).
fn fitPoints(pts: []Pt, x0: f32, y0: f32, x1: f32, y1: f32, margin: f32) void {
    const e = extent(pts);
    const sx = (x1 - x0 - 2.0 * margin) / @max(e.maxx - e.minx, 0.001);
    const sy = (y1 - y0 - 2.0 * margin) / @max(e.maxy - e.miny, 0.001);
    const sc = @min(sx, sy);
    const ox = x0 + (x1 - x0 - (e.maxx - e.minx) * sc) / 2.0 - e.minx * sc;
    const oy = y0 + (y1 - y0 - (e.maxy - e.miny) * sc) / 2.0 - e.miny * sc;
    for (pts) |*p| p.* = Pt.new(ox + p.x * sc, oy + p.y * sc);
}

fn normT(t: f32) f32 {
    return remEuclid(t, 1.0);
}

fn angleT(x: f32, y: f32) f32 {
    return remEuclid(std.math.atan2(y - CY, x - CX) / TAU + 1.25, 1.0);
}

fn pointOnCircle(r: f32, t: f32) Pt {
    const a = (t - 0.25) * TAU;
    return Pt.new(CX + r * @cos(a), CY + r * @sin(a));
}

fn gosperExpand(gpa: Allocator, symbols: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, symbols.len * 8);
    errdefer out.deinit(gpa);
    for (symbols) |ch| switch (ch) {
        'A' => try out.appendSlice(gpa, "A-B--B+A++AA+B-"),
        'B' => try out.appendSlice(gpa, "+A-BB--B-A++A+B"),
        '+', '-' => try out.append(gpa, ch),
        else => {},
    };
    return out.toOwnedSlice(gpa);
}

fn gosperPoints(gpa: Allocator, levels: usize, step: f32) Allocator.Error![]Pt {
    var prog = try gpa.dupe(u8, "A");
    defer gpa.free(prog);
    for (0..levels) |_| {
        const next = try gosperExpand(gpa, prog);
        gpa.free(prog);
        prog = next;
    }
    var pts: std.ArrayList(Pt) = .empty;
    errdefer pts.deinit(gpa);
    var p = Pt.new(0.0, 0.0);
    var ang: f32 = 0.0;
    const turn: f32 = std.math.pi / 3.0;
    try pts.append(gpa, p);
    for (prog) |ch| switch (ch) {
        'A', 'B' => {
            p = Pt.new(p.x + step * @cos(ang), p.y + step * @sin(ang));
            try pts.append(gpa, p);
        },
        '+' => ang += turn,
        '-' => ang -= turn,
        else => {},
    };
    return pts.toOwnedSlice(gpa);
}

/// In place (the Rust returns a new Vec).
fn fitPointsToCircle(pts: []Pt, cx: f32, cy: f32, r: f32, margin: f32) void {
    const e = extent(pts);
    const scale = @max((2.0 * (r - margin)) / @max(@max(e.maxx - e.minx, e.maxy - e.miny), 0.001), 0.001);
    const ox = cx - ((e.minx + e.maxx) * 0.5) * scale;
    const oy = cy - ((e.miny + e.maxy) * 0.5) * scale;
    for (pts) |*p| p.* = Pt.new(ox + p.x * scale, oy + p.y * scale);
}

fn drawCenterGosperBackground(gpa: Allocator, buf: []u8, w: usize, score: *const WeaveScore) Allocator.Error!void {
    const thread: Rgb = if (score.phrases.len > 0)
        light(dark(phraseColor(score.phrases[0].phrase_id), 0.36), 0.18)
    else
        .{ 122, 84, 42 };
    const pts = try gosperPoints(gpa, 4, 1.0);
    defer gpa.free(pts);
    fitPointsToCircle(pts, CX, CY, INNER_R - 30.0, 8.0);
    const clip = INNER_R - 22.0;
    const clip2 = clip * clip;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[i + 1];
        const mx = (a.x + b.x) * 0.5;
        const my = (a.y + b.y) * 0.5;
        const dx = mx - CX;
        const dy = my - CY;
        if (dx * dx + dy * dy > clip2) continue;
        thickLine(buf, w, roundI32(a.x), roundI32(a.y), roundI32(b.x), roundI32(b.y), .{ 0, 0, 0 }, 0.74, 9);
        thickLine(buf, w, roundI32(a.x), roundI32(a.y), roundI32(b.x), roundI32(b.y), thread, 0.82, 5);
    }
}

fn drawChevron(buf: []u8, w: usize, r: f32, t: f32, rgb: Rgb, a: f32, scale: f32, ccw: bool) void {
    const ang = (t - 0.25) * TAU;
    const p = pointOnCircle(r, normT(t));
    const dx: f32, const dy: f32 = if (ccw) .{ @sin(ang), -@cos(ang) } else .{ -@sin(ang), @cos(ang) };
    const nx = -dy;
    const ny = dx;
    const ax = p.x + dx * scale;
    const ay = p.y + dy * scale;
    const bx = p.x - dx * scale * 0.8;
    const by = p.y - dy * scale * 0.8;
    const l = Pt.new(bx + nx * scale * 0.65, by + ny * scale * 0.65);
    const rr = Pt.new(bx - nx * scale * 0.65, by - ny * scale * 0.65);
    thickLine(buf, w, roundI32(l.x), roundI32(l.y), roundI32(ax), roundI32(ay), rgb, a, 2);
    thickLine(buf, w, roundI32(rr.x), roundI32(rr.y), roundI32(ax), roundI32(ay), rgb, a, 2);
}

/// Bounded so a pathological t cannot loop for long: t values come from [0, 1] score fractions.
fn steps70(span: f32) usize {
    return @min(asUsize(@max(@ceil(span * 70.0), 3.0)), 100_000);
}

fn drawChevrons(buf: []u8, w: usize, r: f32, t0: f32, t1: f32, rgb: Rgb, a: f32, scale: f32, ccw: bool) void {
    if (ccw) {
        var end = t1;
        while (end >= t0) end -= 1.0;
        const span = @abs(t0 - end);
        const steps = steps70(span);
        var i: usize = 1;
        while (i < steps) : (i += 1) {
            const t = t0 - span * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            drawChevron(buf, w, r, t, rgb, a, scale, true);
        }
    } else {
        var end = t1;
        if (end < t0) end += 1.0;
        const span = @abs(end - t0);
        const steps = steps70(span);
        var i: usize = 1;
        while (i < steps) : (i += 1) {
            const t = t0 + span * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            drawChevron(buf, w, r, t, rgb, a, scale, false);
        }
    }
}

/// The Rust `score_border_layout`. Caller owns the result.
pub fn scoreBorderLayout(gpa: Allocator, score: *const WeaveScore) Allocator.Error![]BorderTickLayout {
    // Use one global angular grid. Giving each phrase an equal arc makes beats uneven whenever
    // phrases contain different numbers of ticks.
    const tick_count: f32 = @floatFromInt(@max(score.ticks.len, 1));
    var layout: std.ArrayList(BorderTickLayout) = try .initCapacity(gpa, score.ticks.len);
    errdefer layout.deinit(gpa);
    for (score.phrases) |phrase| {
        for (0..phrase.tick_count) |score_tick| {
            const global_tick = phrase.first_tick + score_tick;
            const start_t = @as(f32, @floatFromInt(global_tick)) / tick_count;
            const end_t = @as(f32, @floatFromInt(global_tick + 1)) / tick_count;
            const tick = score.ticks[global_tick];
            const p = pointOnCircle(BEAT_R, (start_t + end_t) * 0.5);
            try layout.append(gpa, .{
                .phrase_id = phrase.phrase_id,
                .score_tick = score_tick,
                .x = p.x,
                .y = p.y,
                .is_kick = tick.tick_in_group == 0,
                .start_t = start_t,
                .end_t = end_t,
            });
        }
    }
    return layout.toOwnedSlice(gpa);
}

/// (first tick's start_t, last tick's end_t) of a phrase id in the layout, if it has ticks.
fn phraseBounds(layout: []const BorderTickLayout, phrase_id: usize) ?struct { f32, f32 } {
    var first: ?BorderTickLayout = null;
    var last: BorderTickLayout = undefined;
    for (layout) |t| {
        if (t.phrase_id != phrase_id) continue;
        if (first == null) first = t;
        last = t;
    }
    const f = first orelse return null;
    return .{ f.start_t, last.end_t };
}

fn jumpRoutes(gpa: Allocator, phrases: []const Phrase, score: *const WeaveScore) Allocator.Error![]JumpRoute {
    const layout = try scoreBorderLayout(gpa, score);
    defer gpa.free(layout);
    var routes: std.ArrayList(JumpRoute) = .empty;
    errdefer routes.deinit(gpa);
    var previous_phrase_id: ?usize = null;
    for (phrases) |*phrase| {
        if (phrase.jump) |jump| {
            const source_phrase_id = previous_phrase_id orelse continue;
            const target_phrase_id = resolveTarget(phrases, layout, jump.target_id) orelse continue;
            const sb = phraseBounds(layout, source_phrase_id) orelse continue;
            const tb = phraseBounds(layout, target_phrase_id) orelse continue;
            try routes.append(gpa, .{
                .jump_id = phrase.id,
                .source_phrase_id = source_phrase_id,
                .target_phrase_id = target_phrase_id,
                .source_t = sb[1],
                .target_t = tb[0],
            });
        } else if (phrase.control == null) {
            previous_phrase_id = phrase.id;
        }
    }
    return routes.toOwnedSlice(gpa);
}

fn resolveTarget(phrases: []const Phrase, layout: []const BorderTickLayout, target_id: usize) ?usize {
    if (phraseBounds(layout, target_id) != null) return target_id;
    var first_musical: ?usize = null;
    for (phrases) |*p| {
        if (p.jump != null or p.control != null) continue;
        if (first_musical == null) first_musical = p.id;
        if (p.id >= target_id) return p.id;
    }
    return first_musical;
}

/// The Rust `jump_link_cells`. Caller owns the result.
pub fn jumpLinkCells(gpa: Allocator, phrases: []const Phrase) Allocator.Error![]JumpLinkCell {
    var score = try WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const routes = try jumpRoutes(gpa, phrases, &score);
    defer gpa.free(routes);
    var cells: std.ArrayList(JumpLinkCell) = .empty;
    errdefer cells.deinit(gpa);
    for (routes, 0..) |route, order| {
        const r: f32 = @max(INNER_R - 22.0 - @as(f32, @floatFromInt(order)) * 18.0, 58.0);
        var target_t = route.target_t;
        while (target_t >= route.source_t) target_t -= 1.0;
        const steps: usize = @max(asUsize(@ceil(@abs(route.source_t - target_t) * 130.0)), 12);
        for (0..steps + 1) |step| {
            const t = route.source_t + (target_t - route.source_t) * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const p = pointOnCircle(r, t);
            try cells.append(gpa, .{
                .jump_id = route.jump_id,
                .x = p.x,
                .y = p.y,
                .size = if (step == steps) 7 else 5,
            });
        }
    }
    return cells.toOwnedSlice(gpa);
}

/// The Rust `jump_counter_layout`. Caller owns the result.
pub fn jumpCounterLayout(gpa: Allocator, phrases: []const Phrase) Allocator.Error![]JumpCounterLayout {
    var score = try WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const routes = try jumpRoutes(gpa, phrases, &score);
    defer gpa.free(routes);
    const out = try gpa.alloc(JumpCounterLayout, routes.len);
    for (routes, 0..) |route, order| {
        const r: f32 = @max(INNER_R - 48.0 - @as(f32, @floatFromInt(order)) * 20.0, 46.0);
        const p = pointOnCircle(r, route.source_t);
        out[order] = .{ .jump_id = route.jump_id, .x = p.x, .y = p.y };
    }
    return out;
}

fn steps180(span: f32) usize {
    return @min(asUsize(@max(@ceil(span * 180.0), 8.0)), 100_000);
}

fn drawArc(buf: []u8, w: usize, r: f32, t0: f32, t1: f32, rgb: Rgb, a: f32, thick: i32) void {
    var end = t1;
    if (end < t0) end += 1.0;
    const steps = steps180(@abs(end - t0));
    var prev = pointOnCircle(r, t0);
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = t0 + (end - t0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const p = pointOnCircle(r, normT(t));
        thickLine(buf, w, roundI32(prev.x), roundI32(prev.y), roundI32(p.x), roundI32(p.y), rgb, a, thick);
        prev = p;
    }
}

fn drawArcCcw(buf: []u8, w: usize, r: f32, t0: f32, t1: f32, rgb: Rgb, a: f32, thick: i32) void {
    var end = t1;
    while (end >= t0) end -= 1.0;
    const span = @abs(t0 - end);
    const steps = steps180(span);
    var prev = pointOnCircle(r, t0);
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = t0 - span * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const p = pointOnCircle(r, normT(t));
        thickLine(buf, w, roundI32(prev.x), roundI32(prev.y), roundI32(p.x), roundI32(p.y), rgb, a, thick);
        prev = p;
    }
}

fn drawBaseWeave(buf: []u8, w: usize) void {
    for (0..CARPET_H) |y| {
        for (0..w) |x| {
            const xu: u32 = @truncate(x);
            const yu: u32 = @truncate(y);
            const n = hash01((xu *% 73856093) ^ (yu *% 19349663));
            const warp: f32 = if (x % 4 < 2) 1.08 else 0.92;
            const weft: f32 = if (y % 4 < 2) 1.04 else 0.96;
            const base = [3]f32{ 6.0, 5.0, 4.0 };
            putPx(buf, w, x, y, .{
                asU8(base[0] * warp * weft + n * 3.0),
                asU8(base[1] * warp * weft + n * 2.5),
                asU8(base[2] * warp * weft + n * 2.0),
            });
        }
    }
}

fn drawOuterHilbert(gpa: Allocator, buf: []u8, w: usize, score: *const WeaveScore) Allocator.Error!void {
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(CARPET_H);
    const pts = try hilbertPoints(gpa, 6);
    defer gpa.free(pts);
    fitPoints(pts, -wf * 0.5, -hf * 0.5, wf * 1.5, hf * 1.5, 0.0);
    const clear_r2 = (BEAT_R + 34.0) * (BEAT_R + 34.0);
    const x1 = wf - CARPET_X1_PAD;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[i + 1];
        const m = a.add(b).mul(0.5);
        if (m.x < CARPET_X0 or m.x > x1 or m.y < CARPET_Y0 or m.y > CARPET_Y1) continue;
        const dx = m.x - CX;
        const dy = m.y - CY;
        if (dx * dx + dy * dy <= clear_r2) continue;
        const t = angleT(m.x, m.y);
        const n_phrases = score.phrases.len;
        const phrase_idx = @min(asUsize(@floor(t * @as(f32, @floatFromInt(@max(n_phrases, 1))))), n_phrases -| 1);
        const phrase_id = if (phrase_idx < n_phrases) score.phrases[phrase_idx].phrase_id else 0;
        const c = dark(phraseColor(phrase_id), 0.55);
        thickLine(buf, w, roundI32(a.x), roundI32(a.y), roundI32(b.x), roundI32(b.y), dark(c, 0.75), 0.24, 5);
        thickLine(buf, w, roundI32(a.x), roundI32(a.y), roundI32(b.x), roundI32(b.y), c, 0.42, 3);
    }
}

fn drawRingScore(gpa: Allocator, buf: []u8, w: usize, score: *const WeaveScore) Allocator.Error!void {
    dot(buf, w, roundI32(CX), roundI32(CY), roundI32(INNER_R) + 14, .{ 0, 0, 0 }, 0.78);
    dot(buf, w, roundI32(CX), roundI32(CY), roundI32(INNER_R) - 4, .{ 6, 5, 4 }, 0.64);
    const layout = try scoreBorderLayout(gpa, score);
    defer gpa.free(layout);
    for (score.phrases) |phrase| {
        if (phraseBounds(layout, phrase.phrase_id)) |b| {
            const color = phraseColor(phrase.phrase_id);
            const lane = dark(color, 0.34);
            drawArc(buf, w, INNER_R, b[0], b[1], lane, 0.84, 13);
            drawArc(buf, w, INNER_R - 16.0, b[0], b[1], .{ 22, 17, 12 }, 0.68, 4);
            drawChevrons(buf, w, INNER_R, b[0], b[1], light(lane, 0.18), 0.54, 6.0, false);
        }
    }
    for (layout) |tick| {
        const c: Rgb = if (tick.is_kick) .{ 194, 142, 80 } else light(dark(phraseColor(tick.phrase_id), 0.20), 0.08);
        dot(buf, w, roundI32(tick.x), roundI32(tick.y), if (tick.is_kick) 4 else 3, .{ 6, 4, 3 }, 0.96);
        dot(buf, w, roundI32(tick.x), roundI32(tick.y), if (tick.is_kick) 3 else 2, c, 0.90);
    }
}

fn drawJumpArrows(gpa: Allocator, buf: []u8, w: usize, phrases: []const Phrase, score: *const WeaveScore) Allocator.Error!void {
    const routes = try jumpRoutes(gpa, phrases, score);
    defer gpa.free(routes);
    for (routes, 0..) |route, order| {
        const r: f32 = @max(INNER_R - 22.0 - @as(f32, @floatFromInt(order)) * 18.0, 58.0);
        var target_t = route.target_t;
        while (target_t >= route.source_t) target_t -= 1.0;
        const color: Rgb = if (order % 2 == 0) .{ 170, 126, 72 } else .{ 150, 104, 60 };
        drawArcCcw(buf, w, r, route.source_t, target_t, .{ 5, 4, 3 }, 0.76, 8);
        drawArcCcw(buf, w, r, route.source_t, target_t, color, 0.66, 4);
        drawChevrons(buf, w, r, route.source_t, target_t, light(color, 0.24), 0.58, 7.5, true);
        const tip = pointOnCircle(BEAT_R, normT(target_t));
        dot(buf, w, roundI32(tip.x), roundI32(tip.y), 5, color, 0.88);
    }
}

fn allAsciiDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn appendUpper(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| try out.append(gpa, std.ascii.toUpper(c));
}

/// The Rust `phrase_label`: (title, ratios), both owned by the caller.
pub fn phraseLabel(gpa: Allocator, phrase: *const Phrase) Allocator.Error!struct { []u8, []u8 } {
    var title: std.ArrayList(u8) = .empty;
    errdefer title.deinit(gpa);
    var parts = std.mem.splitScalar(u8, phrase.src, ',');
    var any = false;
    while (parts.next()) |part| {
        var toks: [2][]const u8 = undefined;
        var n: usize = 0;
        var words = rust_str.words(part);
        while (words.next()) |s| {
            if (allAsciiDigits(s) or s[0] == 'r') continue;
            if (n < 2) toks[n] = s;
            n += 1;
        }
        if (n == 0) continue;
        if (any) try title.append(gpa, '+');
        any = true;
        if (n >= 2) {
            try appendUpper(gpa, &title, toks[0]);
            try title.append(gpa, ' ');
            try appendUpper(gpa, &title, toks[1]);
        } else {
            try appendUpper(gpa, &title, toks[0]);
        }
    }
    if (title.items.len == 0) {
        if (phrase.bar.maqam_names.len > 0) {
            for (phrase.bar.maqam_names, 0..) |name, i| {
                if (i > 0) try title.append(gpa, '+');
                try appendUpper(gpa, &title, name);
            }
        } else {
            var words = rust_str.words(phrase.src);
            var taken: usize = 0;
            while (words.next()) |s| {
                if (allAsciiDigits(s)) continue;
                if (taken == 3) break;
                if (taken > 0) try title.append(gpa, ' ');
                try appendUpper(gpa, &title, s);
                taken += 1;
            }
        }
    }
    var ratios: std.ArrayList(u8) = .empty;
    errdefer ratios.deinit(gpa);
    for (phrase.bar.ratio_strs) |rs| {
        var words = rust_str.words(rs);
        while (words.next()) |r| {
            if (std.mem.eql(u8, r, "1/1")) continue;
            if (ratios.items.len > 0) try ratios.append(gpa, ' ');
            try ratios.appendSlice(gpa, r);
        }
    }
    const t = try title.toOwnedSlice(gpa);
    errdefer gpa.free(t);
    return .{ t, try ratios.toOwnedSlice(gpa) };
}

fn firstPhraseWithId(phrases: []const Phrase, id: usize) ?*const Phrase {
    for (phrases) |*p| if (p.id == id) return p;
    return null;
}

fn drawPhraseLabels(gpa: Allocator, buf: []u8, w: usize, phrases: []const Phrase, score: *const WeaveScore) Allocator.Error!void {
    const layout = try scoreBorderLayout(gpa, score);
    defer gpa.free(layout);
    for (score.phrases) |phrase| {
        const src = firstPhraseWithId(phrases, phrase.phrase_id) orelse continue;
        if (phraseBounds(layout, phrase.phrase_id)) |b| {
            const mid = normT((b[0] + b[1]) * 0.5);
            const p = pointOnCircle(LABEL_R, mid);
            const title, const ratios = try phraseLabel(gpa, src);
            defer gpa.free(title);
            defer gpa.free(ratios);
            drawLabelBox(buf, w, roundI32(p.x), roundI32(p.y), title, ratios);
        }
    }
}

fn drawFrame(buf: []u8, w: usize) void {
    const wi: i32 = @intCast(w);
    const frame: Rgb = .{ 84, 70, 52 };
    var x: usize = 24;
    while (x < w - 24) : (x += 8) {
        const xu: u32 = @intCast(x);
        const xi: i32 = @intCast(x);
        const len = 15 + asI32(hash01(xu) * 18.0);
        line(buf, w, xi, 28, xi + asI32(hash01(xu + 7) * 12.0 - 6.0), 28 - len, frame, 0.58);
        line(buf, w, xi, 692, xi + asI32(hash01(xu + 13) * 12.0 - 6.0), 692 + len, frame, 0.58);
    }
    var y: usize = 36;
    while (y < CARPET_H - 36) : (y += 8) {
        const yu: u32 = @intCast(y);
        const yi: i32 = @intCast(y);
        const len = 12 + asI32(hash01(yu + 99) * 16.0);
        line(buf, w, 38, yi, 38 - len, yi + asI32(hash01(yu + 3) * 12.0 - 6.0), frame, 0.50);
        line(buf, w, wi - 38, yi, wi - 38 + len, yi + asI32(hash01(yu + 5) * 12.0 - 6.0), frame, 0.50);
    }
    const edge: Rgb = .{ 50, 34, 22 };
    thickLine(buf, w, 52, 40, wi - 52, 40, edge, 0.62, 8);
    thickLine(buf, w, 52, 680, wi - 52, 680, edge, 0.62, 8);
    thickLine(buf, w, 52, 40, 52, 680, edge, 0.62, 8);
    thickLine(buf, w, wi - 52, 40, wi - 52, 680, edge, 0.62, 8);
}

// ── Layers ───────────────────────────────────────────────────────────────────

/// The center Gosper overlay's RGB pixels (W x CARPET_H). Caller owns the result.
pub fn renderCenterGosperOverlay(gpa: Allocator, phrases: []const Phrase) Allocator.Error![]u8 {
    var score = try WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const buf = try gpa.alloc(u8, layer_bytes);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    try drawCenterGosperBackground(gpa, buf, W, &score);
    return buf;
}

/// The jump arrows overlay's RGB pixels. Caller owns the result.
pub fn renderJumpArrowsOverlay(gpa: Allocator, phrases: []const Phrase) Allocator.Error![]u8 {
    var score = try WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const buf = try gpa.alloc(u8, layer_bytes);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    try drawJumpArrows(gpa, buf, W, phrases, &score);
    return buf;
}

/// The carpet background's RGB pixels. Caller owns the result.
pub fn renderCarpetBackground(gpa: Allocator, entries: []const CarpetEntry, phrases: []const Phrase) Allocator.Error![]u8 {
    _ = entries;
    var score = try WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    const buf = try gpa.alloc(u8, layer_bytes);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    drawBaseWeave(buf, W);
    try drawOuterHilbert(gpa, buf, W, &score);
    try drawRingScore(gpa, buf, W, &score);
    try drawPhraseLabels(gpa, buf, W, phrases, &score);
    drawFrame(buf, W);
    return buf;
}

fn writeLayer(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, buf: []const u8) !CarpetRenderInfo {
    try png.writeFile(gpa, io, dir, path, buf, W, CARPET_H, .rgb8);
    return .{ .path = path, .width = W, .content_end_x = W };
}

pub fn writeCenterGosperOverlay(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, phrases: []const Phrase) !CarpetRenderInfo {
    const buf = try renderCenterGosperOverlay(gpa, phrases);
    defer gpa.free(buf);
    return writeLayer(gpa, io, dir, path, buf);
}

pub fn writeJumpArrowsOverlay(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, phrases: []const Phrase) !CarpetRenderInfo {
    const buf = try renderJumpArrowsOverlay(gpa, phrases);
    defer gpa.free(buf);
    return writeLayer(gpa, io, dir, path, buf);
}

pub fn writeCarpetBackground(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, entries: []const CarpetEntry, phrases: []const Phrase) !CarpetRenderInfo {
    const buf = try renderCarpetBackground(gpa, entries, phrases);
    defer gpa.free(buf);
    return writeLayer(gpa, io, dir, path, buf);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const command = @import("command.zig");

test "circular_layout_has_points" {
    const gpa = testing.allocator;
    var phrases = [_]WeavePhrase{.{ .phrase_id = 0, .groups = &.{4}, .first_tick = 0, .tick_count = 4 }};
    var ticks: [4]WeaveTick = undefined;
    for (&ticks, 0..) |*t, i| t.* = .{ .phrase_id = 0, .group_index = 0, .tick_in_group = i, .group_len = 4 };
    const score: WeaveScore = .{ .phrases = &phrases, .ticks = &ticks };
    const layout = try scoreBorderLayout(gpa, &score);
    defer gpa.free(layout);
    try testing.expectEqual(@as(usize, 4), layout.len);
    for (layout) |tick| {
        try testing.expect(@abs(tick.x - CX) <= BEAT_R + 2.0);
        try testing.expect(@abs(tick.y - CY) <= BEAT_R + 2.0);
    }
}

test "circular_layout_spaces_all_beats_evenly_across_phrases" {
    const gpa = testing.allocator;
    var phrases = [_]WeavePhrase{
        .{ .phrase_id = 10, .groups = &.{2}, .first_tick = 0, .tick_count = 2 },
        .{ .phrase_id = 20, .groups = &.{4}, .first_tick = 2, .tick_count = 4 },
    };
    var ticks: [6]WeaveTick = undefined;
    for (&ticks, 0..) |*t, i| t.* = .{
        .phrase_id = if (i < 2) 10 else 20,
        .group_index = 0,
        .tick_in_group = if (i < 2) i else i - 2,
        .group_len = if (i < 2) 2 else 4,
    };
    const score: WeaveScore = .{ .phrases = &phrases, .ticks = &ticks };
    const layout = try scoreBorderLayout(gpa, &score);
    defer gpa.free(layout);
    try testing.expectEqual(@as(usize, 6), layout.len);
    for (layout, 0..) |tick, i| {
        try testing.expect(@abs(tick.start_t - @as(f32, @floatFromInt(i)) / 6.0) < 1e-6);
        try testing.expect(@abs(tick.end_t - @as(f32, @floatFromInt(i + 1)) / 6.0) < 1e-6);
    }
}

/// Parse and build a phrase the way the app does (rhythm default 3 3 2).
pub fn testPhrase(gpa: Allocator, id: usize, src: []const u8) !Phrase {
    var parsed = try command.parse(gpa, src);
    defer parsed.deinit(gpa);
    const ap = switch (parsed) {
        .ok => |c| switch (c) {
            .add_phrase => |v| v,
            else => return error.TestUnexpectedResult,
        },
        .err => return error.TestUnexpectedResult,
    };
    const specs = try sequencer.resolveRhythms(gpa, ap.specs, &.{ 3, 3, 2 });
    defer gpa.free(specs);
    var r = try sequencer.buildPhrase(gpa, id, ap.source, specs, 4, @max(ap.repeat, 1));
    switch (r) {
        .ok => |p| return p,
        .err => {
            r.deinit(gpa);
            return error.TestUnexpectedResult;
        },
    }
}

/// A two-phrase timeline with a jump back (j 0 2) and a stop, as the recorder sees one.
pub fn testTimeline(gpa: Allocator) ![]Phrase {
    const out = try gpa.alloc(Phrase, 3);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |*p| p.deinit(gpa);
        gpa.free(out);
    }
    out[0] = try testPhrase(gpa, 0, "d bayati 332");
    n = 1;
    out[1] = try testPhrase(gpa, 1, "g hijaz, d rast 3322");
    n = 2;
    var j = try sequencer.buildJumpEntry(gpa, 2, 0, null, 2);
    switch (j) {
        .ok => |p| out[2] = p,
        .err => {
            j.deinit(gpa);
            return error.TestUnexpectedResult;
        },
    }
    return out;
}

pub fn freeTimeline(gpa: Allocator, phrases: []Phrase) void {
    for (phrases) |*p| p.deinit(gpa);
    gpa.free(phrases);
}

test "the layers have the Rust sizes and are deterministic" {
    const gpa = testing.allocator;
    const phrases = try testTimeline(gpa);
    defer freeTimeline(gpa, phrases);
    const bg = try renderCarpetBackground(gpa, &.{}, phrases);
    defer gpa.free(bg);
    const go = try renderCenterGosperOverlay(gpa, phrases);
    defer gpa.free(go);
    const ja = try renderJumpArrowsOverlay(gpa, phrases);
    defer gpa.free(ja);
    for ([_][]const u8{ bg, go, ja }) |b| try testing.expectEqual(@as(usize, 1280 * 720 * 3), b.len);
    // Something is drawn on every layer, and the overlays keep a black (keyed-out) surround.
    for ([_][]const u8{ bg, go, ja }) |b| {
        var lit: usize = 0;
        for (b) |v| lit += @intFromBool(v != 0);
        try testing.expect(lit > 1000);
    }
    try testing.expectEqual(@as(u8, 0), go[0]);
    try testing.expectEqual(@as(u8, 0), ja[0]);
    // The center of the Gosper overlay sits inside the drawn curve region.
    const bg2 = try renderCarpetBackground(gpa, &.{}, phrases);
    defer gpa.free(bg2);
    try testing.expectEqualSlices(u8, bg, bg2);
    // The PNG header says 1280x720 RGB.
    const bytes = try png.encode(gpa, bg, W, CARPET_H, .rgb8);
    defer gpa.free(bytes);
    const d = try png.testDimensions(bytes);
    try testing.expectEqual(@as(u32, 1280), d.width);
    try testing.expectEqual(@as(u32, 720), d.height);
    try testing.expectEqual(@as(u8, 2), d.color);
}

test "jump geometry: one route from phrase 1 back to phrase 0" {
    const gpa = testing.allocator;
    const phrases = try testTimeline(gpa);
    defer freeTimeline(gpa, phrases);
    const counters = try jumpCounterLayout(gpa, phrases);
    defer gpa.free(counters);
    try testing.expectEqual(@as(usize, 1), counters.len);
    try testing.expectEqual(@as(usize, 2), counters[0].jump_id);
    const cells = try jumpLinkCells(gpa, phrases);
    defer gpa.free(cells);
    try testing.expect(cells.len >= 13);
    try testing.expectEqual(@as(i32, 7), cells[cells.len - 1].size);
    try testing.expectEqual(@as(i32, 5), cells[0].size);
    var score = try WeaveScore.fromPhrases(gpa, phrases);
    defer score.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), score.phrases.len);
    try testing.expectEqual(@as(usize, 8 + 10), score.ticks.len);
}

test "phrase labels follow the Rust rules" {
    const gpa = testing.allocator;
    var p = try testPhrase(gpa, 0, "g hijaz, d rast 3322 r2");
    defer p.deinit(gpa);
    const title, const ratios = try phraseLabel(gpa, &p);
    defer gpa.free(title);
    defer gpa.free(ratios);
    // Rust drops every token starting with 'r' (meant for rN), so "rast" is dropped too.
    try testing.expectEqualStrings("G HIJAZ+D", title);
    try testing.expect(std.mem.indexOf(u8, ratios, "1/1") == null);
    try testing.expect(ratios.len > 0);
}

test "drawing never leaves the buffer for any geometry" {
    const buf = try testing.allocator.alloc(u8, layer_bytes);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    line(buf, W, -50_000, 3, 50_000, 5, .{ 1, 2, 3 }, 1.0);
    line(buf, W, -5, -5, -2_000_000_000, -7, .{ 1, 2, 3 }, 1.0); // wholly off the picture: skipped
    thickLine(buf, W, std.math.maxInt(i32), 0, std.math.maxInt(i32) - 3, 10, .{ 1, 2, 3 }, 1.0, 9);
    drawLabelBox(buf, W, 10, 10, "A VERY LONG TITLE THAT IS WIDER THAN THE WHOLE PICTURE CAN HOLD AT SCALE TWO, REALLY REALLY REALLY REALLY", "\xff\xfe 9/8");
    drawText(buf, W, "XXXX", std.math.maxInt(i32) - 20, 5, 2, .{ 9, 9, 9 }, 1.0);
    dot(buf, W, -3, -3, 5, .{ 9, 9, 9 }, 1.0);
}
