//! The event log every implementation provides (spec/Requirements.lean, markdown "comparison";
//! property "Every implementation logs the same protocol"; proof "The event log carries only
//! declared fields"). With MAQAM_EVENT_LOG=<path> each message of protocol MaqamLive
//! (spec/Maqam.leanfm) the app takes part in is appended as one JSON object per line:
//! {ts, session, from, to, label, cause, fields}. ts is nanoseconds of one monotonic clock; cause
//! is the ts of the event the protocol names as its cause (null when it names none); fields are
//! only those the protocol's structure of that name declares, integers as decimal strings.
//! A message inside a protocol `sessions { ... }` block is logged under its own session id
//! ("<interaction>.<k>"), which is how session_conform reads derived sessions.
//! Unset, nothing is opened or written. Never written from the audio output path.
const std = @import("std");
const util = @import("util.zig");

/// The fields each MaqamLive structure declares, by message label. A label not listed declares none.
const declared = [_]struct { label: []const u8, fields: []const []const u8 }{
    .{ .label = "Command", .fields = &.{"line"} },
    .{ .label = "Phrase", .fields = &.{ "id", "source" } },
    .{ .label = "Audio", .fields = &.{"kind"} },
    .{ .label = "Saved", .fields = &.{"path"} },
    .{ .label = "Prompt", .fields = &.{ "provider", "text" } },
    .{ .label = "Commands", .fields = &.{"count"} },
    .{ .label = "Fetch", .fields = &.{ "url", "name" } },
};

pub fn declaredFields(label: []const u8) []const []const u8 {
    for (declared) |d| if (std.mem.eql(u8, d.label, label)) return d.fields;
    return &.{};
}

pub const Field = struct { name: []const u8, value: []const u8 };

pub const EventLog = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    lock: util.SpinLock = .{},
    next_interaction: std.atomic.Value(u64) = .init(1),
    /// For tests and the offline render: a deterministic clock (each event one microsecond later).
    fake_clock: ?u64 = null,
    offset: u64 = 0,

    /// Opens the log named by MAQAM_EVENT_LOG for appending; unset or empty means no log.
    pub fn fromEnv(io: std.Io, env: *const std.process.Environ.Map) EventLog {
        const path = env.get("MAQAM_EVENT_LOG") orelse return .{ .io = io };
        if (path.len == 0) return .{ .io = io };
        return open(io, path) catch .{ .io = io };
    }

    pub fn open(io: std.Io, path: []const u8) !EventLog {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(io, path, .{ .truncate = false });
        const len = try file.length(io);
        var log: EventLog = .{ .io = io, .file = file };
        log.offset = len;
        return log;
    }

    pub fn enabled(self: *const EventLog) bool {
        return self.file != null;
    }

    pub fn close(self: *EventLog) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    /// A new interaction (one choice of the protocol's Live loop): its session id.
    pub fn interaction(self: *EventLog) u64 {
        return self.next_interaction.fetchAdd(1, .monotonic);
    }

    pub fn now(self: *EventLog) u64 {
        if (self.fake_clock) |*t| {
            t.* += 1000;
            return t.*;
        }
        const ts = std.Io.Clock.awake.now(self.io);
        return @intCast(@max(ts.nanoseconds, 0));
    }

    /// Appends one event and returns its ts (0 when the log is off), the value later events
    /// pass as their cause. `sub` is 0 for the interaction itself, k for its k-th derived session.
    pub fn emit(self: *EventLog, session: u64, sub: u32, from: []const u8, to: []const u8, label: []const u8, cause: ?u64, fields: []const Field) u64 {
        if (self.file == null) return 0;
        self.lock.lock();
        defer self.lock.unlock();
        const ts = self.now();
        var buf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        writeEvent(&w, ts, session, sub, from, to, label, cause, fields) catch return ts;
        const line = w.buffered();
        const file = self.file.?;
        file.writePositionalAll(self.io, line, self.offset) catch return ts;
        self.offset += line.len;
        return ts;
    }
};

fn writeEvent(w: *std.Io.Writer, ts: u64, session: u64, sub: u32, from: []const u8, to: []const u8, label: []const u8, cause: ?u64, fields: []const Field) !void {
    try w.print("{{\"ts\":\"{d}\",\"session\":", .{ts});
    if (sub == 0) try w.print("\"{d}\"", .{session}) else try w.print("\"{d}.{d}\"", .{ session, sub });
    try w.writeAll(",\"from\":");
    try jsonString(w, from);
    try w.writeAll(",\"to\":");
    try jsonString(w, to);
    try w.writeAll(",\"label\":");
    try jsonString(w, label);
    if (cause) |c| try w.print(",\"cause\":\"{d}\"", .{c}) else try w.writeAll(",\"cause\":null");
    try w.writeAll(",\"fields\":{");
    const allowed = declaredFields(label);
    var first = true;
    for (fields) |f| {
        var ok = false;
        for (allowed) |a| if (std.mem.eql(u8, a, f.name)) {
            ok = true;
        };
        if (!ok) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try jsonString(w, f.name);
        try w.writeAll(":");
        try jsonRedacted(w, f.value);
    }
    try w.writeAll("}}\n");
}

pub fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// A value with anything that looks like an API key or bearer token replaced, so a pasted secret
/// never reaches the log (proof "Secrets stay out of files, scores and prompts").
fn jsonRedacted(w: *std.Io.Writer, s: []const u8) !void {
    var tmp: [4096]u8 = undefined;
    const n = redact(s, &tmp);
    try jsonString(w, tmp[0..n]);
}

pub fn redact(s: []const u8, out: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < s.len and o < out.len) {
        const rest = s[i..];
        const secret = std.mem.startsWith(u8, rest, "sk-") or std.ascii.startsWithIgnoreCase(rest, "bearer ") or std.mem.startsWith(u8, rest, "token=");
        if (secret and (i == 0 or !std.ascii.isAlphanumeric(s[i - 1]))) {
            const marker = "[redacted]";
            for (marker) |ch| {
                if (o < out.len) out[o] = ch;
                o += 1;
            }
            // skip the prefix, then the token itself
            i += if (std.ascii.startsWithIgnoreCase(rest, "bearer ")) 7 else if (std.mem.startsWith(u8, rest, "token=")) 6 else 3;
            while (i < s.len and !std.ascii.isWhitespace(s[i]) and s[i] != '"' and s[i] != ',') i += 1;
            continue;
        }
        out[o] = s[i];
        o += 1;
        i += 1;
    }
    return @min(o, out.len);
}

test "only declared fields, escaped, and secrets redacted" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEvent(&w, 5, 3, 0, "Performer", "App", "Command", null, &.{
        .{ .name = "line", .value = "chatgpt: \"hi\" sk-abc123 x" },
        .{ .name = "secret", .value = "nope" },
    });
    try std.testing.expectEqualStrings(
        "{\"ts\":\"5\",\"session\":\"3\",\"from\":\"Performer\",\"to\":\"App\",\"label\":\"Command\",\"cause\":null,\"fields\":{\"line\":\"chatgpt: \\\"hi\\\" [redacted] x\"}}\n",
        w.buffered(),
    );
}

test "derived sessions and causes" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEvent(&w, 9, 3, 2, "App", "Audio", "Phrase", 7, &.{ .{ .name = "id", .value = "4" }, .{ .name = "source", .value = "d bay" } });
    try std.testing.expectEqualStrings(
        "{\"ts\":\"9\",\"session\":\"3.2\",\"from\":\"App\",\"to\":\"Audio\",\"label\":\"Phrase\",\"cause\":\"7\",\"fields\":{\"id\":\"4\",\"source\":\"d bay\"}}\n",
        w.buffered(),
    );
}

test "a label the protocol gives no structure carries no fields" {
    try std.testing.expectEqual(@as(usize, 0), declaredFields("Shown").len);
}

test "every declaration compiles" {
    std.testing.refAllDecls(@This());
}
