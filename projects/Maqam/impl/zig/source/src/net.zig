//! HTTP(S) for the workers: LLM requests (Actor Llm) and NAM capture downloads and searches (Actor
//! Web). Always called on a worker thread, never from the audio output path or the UI loop.
//! Bounded where the upstream is not (specification markdown "bounds"): a response body is read
//! into memory up to `max_body`, and a download stops with an error past `max_download`.
const std = @import("std");

pub const max_body: usize = 4 * 1024 * 1024;
pub const max_download: u64 = 256 * 1024 * 1024;

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

pub const Header = std.http.Header;

/// One request with an optional JSON or form payload; the body comes back whatever the status.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io, method: std.http.Method, url: []const u8, headers: []const Header, payload: ?[]const u8) !Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var lbuf: [4096]u8 = undefined;
    var limited: LimitedWriter = .init(&body.writer, max_body, &lbuf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers,
        .response_writer = &limited.writer,
        .keep_alive = false,
    });
    limited.writer.flush() catch {};
    if (limited.over) return error.ResponseTooLarge;
    return .{ .status = @backingInt(res.status), .body = try body.toOwnedSlice() };
}

/// Streams a GET into `file` (already created by the caller), reporting progress through
/// `progress` (bytes so far); stops with error.DownloadTooLarge past max_download.
pub fn download(gpa: std.mem.Allocator, io: std.Io, url: []const u8, headers: []const Header, file: std.Io.File, progress: *std.atomic.Value(u64)) !u16 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var buf: [64 * 1024]u8 = undefined;
    var sink: FileSink = .{ .io = io, .file = file, .progress = progress, .writer = .{ .vtable = &FileSink.vtable, .buffer = &buf } };
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = headers,
        .response_writer = &sink.writer,
        .keep_alive = false,
    });
    sink.writer.flush() catch {};
    if (sink.failed) |e| return e;
    return @backingInt(res.status);
}

const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    progress: *std.atomic.Value(u64),
    failed: ?anyerror = null,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FileSink = @fieldParentPtr("writer", w);
        try self.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.put(last);
            n += last.len;
        }
        return n;
    }

    fn put(self: *FileSink, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (self.offset + bytes.len > max_download) {
            self.failed = error.DownloadTooLarge;
            return error.WriteFailed;
        }
        self.file.writePositionalAll(self.io, bytes, self.offset) catch |e| {
            self.failed = e;
            return error.WriteFailed;
        };
        self.offset += bytes.len;
        self.progress.store(self.offset, .monotonic);
    }
};

/// A writer that forwards at most `left` bytes and remembers that more were offered.
const LimitedWriter = struct {
    inner: *std.Io.Writer,
    left: usize,
    over: bool = false,
    writer: std.Io.Writer,

    fn init(inner: *std.Io.Writer, left: usize, buf: []u8) LimitedWriter {
        return .{ .inner = inner, .left = left, .writer = .{ .vtable = &vtable, .buffer = buf } };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drainFn };

    fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedWriter = @fieldParentPtr("writer", w);
        try self.forward(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.forward(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.forward(last);
            n += last.len;
        }
        return n;
    }

    fn forward(self: *LimitedWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > self.left) {
            self.over = true;
            return error.WriteFailed;
        }
        self.left -= bytes.len;
        try self.inner.writeAll(bytes);
    }
};

/// Percent-encodes a query value (RFC 3986 unreserved characters pass).
pub fn queryEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(gpa, ch);
        } else if (ch == ' ') {
            try out.append(gpa, '+');
        } else {
            var b: [3]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&b, "%{X:0>2}", .{ch}));
        }
    }
    return out.toOwnedSlice(gpa);
}

test "query encoding" {
    const gpa = std.testing.allocator;
    const s = try queryEncode(gpa, "nam a/b c");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("nam+a%2Fb+c", s);
}

test "limited writer refuses past its bound" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var buf: [2]u8 = undefined;
    var lw: LimitedWriter = .init(&sink.writer, 5, &buf);
    const w = &lw.writer;
    try w.writeAll("abc");
    try w.flush();
    try std.testing.expectError(error.WriteFailed, blk: {
        w.writeAll("defghi") catch |e| break :blk e;
        w.flush() catch |e| break :blk e;
        break :blk {};
    });
    try std.testing.expect(lw.over);
}

test "every declaration compiles" {
    std.testing.refAllDecls(@This());
}
