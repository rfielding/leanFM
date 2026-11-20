//! The terminal: raw mode on the alternate screen, keys read with a timeout, the window size, and a
//! cell grid redrawn as one write per frame. It stands in for crossterm/ratatui in the Rust.
const std = @import("std");
const posix = std.posix;

pub const Key = union(enum) {
    char: u21,
    enter,
    esc,
    backspace,
    delete,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    ctrl_c,
};

pub const Color = struct { r: u8, g: u8, b: u8 };

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    eql: void = {},
};

pub const Cell = struct { ch: u21 = ' ', style: Style = .{} };

pub const Terminal = struct {
    fd: posix.fd_t,
    saved: posix.termios,
    width: u16 = 80,
    height: u16 = 24,

    pub fn enter() !Terminal {
        const fd = posix.STDIN_FILENO;
        const saved = try posix.tcgetattr(fd);
        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cc[@backingInt(posix.V.MIN)] = 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        var t: Terminal = .{ .fd = fd, .saved = saved };
        t.writeRaw("\x1b[?1049h\x1b[?25l\x1b[2J");
        t.refreshSize();
        return t;
    }

    pub fn leave(self: *Terminal) void {
        self.writeRaw("\x1b[0m\x1b[?25h\x1b[?1049l");
        posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }

    pub fn refreshSize(self: *Terminal) void {
        var ws: posix.winsize = undefined;
        if (std.os.linux.ioctl(posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.col > 0 and ws.row > 0) {
            self.width = ws.col;
            self.height = ws.row;
        }
    }

    pub fn writeRaw(self: *Terminal, bytes: []const u8) void {
        _ = self;
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.os.linux.write(posix.STDOUT_FILENO, bytes[off..].ptr, bytes.len - off);
            if (std.os.linux.errno(rc) == .INTR) continue;
            if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) return;
            off += rc;
        }
    }

    /// The next key, waiting at most `timeout_ms` (0 polls); null when none arrived.
    pub fn readKey(self: *Terminal, timeout_ms: i32) ?Key {
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return null;
        if (ready == 0) return null;
        var buf: [16]u8 = undefined;
        const n = posix.read(self.fd, &buf) catch return null;
        if (n == 0) return null;
        return decode(buf[0..n]);
    }
};

/// Decodes the bytes one keypress sent (a character, a control byte or an escape sequence).
pub fn decode(b: []const u8) ?Key {
    if (b.len == 0) return null;
    switch (b[0]) {
        3 => return .ctrl_c,
        '\r', '\n' => return .enter,
        '\t' => return .tab,
        127, 8 => return .backspace,
        27 => {
            if (b.len == 1) return .esc;
            if (b.len >= 3 and (b[1] == '[' or b[1] == 'O')) {
                return switch (b[2]) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    '1', '7' => if (b.len >= 4 and b[3] == '~') .home else null,
                    '4', '8' => if (b.len >= 4 and b[3] == '~') .end else null,
                    '3' => if (b.len >= 4 and b[3] == '~') .delete else null,
                    '5' => if (b.len >= 4 and b[3] == '~') .page_up else null,
                    '6' => if (b.len >= 4 and b[3] == '~') .page_down else null,
                    else => null,
                };
            }
            return .esc;
        },
        else => {},
    }
    const len = std.unicode.utf8ByteSequenceLength(b[0]) catch return null;
    if (len > b.len) return null;
    const cp = std.unicode.utf8Decode(b[0..len]) catch return null;
    if (cp < 32) return null;
    return .{ .char = cp };
}

/// A grid of cells the UI draws into, flushed to the terminal as one write.
pub const Screen = struct {
    width: u16,
    height: u16,
    cells: []Cell,

    pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) !Screen {
        const cells = try gpa.alloc(Cell, @as(usize, width) * height);
        @memset(cells, .{});
        return .{ .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
    }

    pub fn clear(self: *Screen, style: Style) void {
        @memset(self.cells, .{ .style = style });
    }

    /// Writes `text` at (x, y) clipped to `max` columns; returns the columns written.
    pub fn put(self: *Screen, x: u16, y: u16, max: u16, text: []const u8, style: Style) u16 {
        if (y >= self.height or x >= self.width) return 0;
        var col: u16 = 0;
        const limit = @min(max, self.width - x);
        var it = (std.unicode.Utf8View.init(text) catch return self.putAscii(x, y, limit, text, style)).iterator();
        while (it.nextCodepoint()) |cp| {
            if (col >= limit) break;
            self.cells[@as(usize, y) * self.width + x + col] = .{ .ch = if (cp < 32) ' ' else cp, .style = style };
            col += 1;
        }
        return col;
    }

    fn putAscii(self: *Screen, x: u16, y: u16, limit: u16, text: []const u8, style: Style) u16 {
        var col: u16 = 0;
        for (text) |ch| {
            if (col >= limit) break;
            self.cells[@as(usize, y) * self.width + x + col] = .{ .ch = if (ch < 32 or ch > 126) '?' else ch, .style = style };
            col += 1;
        }
        return col;
    }

    pub fn fill(self: *Screen, x: u16, y: u16, w: u16, h: u16, style: Style) void {
        var yy = y;
        while (yy < @min(self.height, y + h)) : (yy += 1) {
            var xx = x;
            while (xx < @min(self.width, x + w)) : (xx += 1) self.cells[@as(usize, yy) * self.width + xx] = .{ .style = style };
        }
    }

    /// A box border with a title, like a ratatui Block.
    pub fn box(self: *Screen, x: u16, y: u16, w: u16, h: u16, title: []const u8, style: Style) void {
        if (w < 2 or h < 2) return;
        var i: u16 = 1;
        while (i + 1 < w) : (i += 1) {
            self.set(x + i, y, 0x2500, style);
            self.set(x + i, y + h - 1, 0x2500, style);
        }
        i = 1;
        while (i + 1 < h) : (i += 1) {
            self.set(x, y + i, 0x2502, style);
            self.set(x + w - 1, y + i, 0x2502, style);
        }
        self.set(x, y, 0x250c, style);
        self.set(x + w - 1, y, 0x2510, style);
        self.set(x, y + h - 1, 0x2514, style);
        self.set(x + w - 1, y + h - 1, 0x2518, style);
        if (title.len > 0 and w > 4) _ = self.put(x + 2, y, w - 4, title, style);
    }

    pub fn set(self: *Screen, x: u16, y: u16, ch: u21, style: Style) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[@as(usize, y) * self.width + x] = .{ .ch = ch, .style = style };
    }

    /// The escape sequences that draw the whole grid, with the cursor left at (cx, cy) when given.
    pub fn render(self: *const Screen, gpa: std.mem.Allocator, cursor: ?[2]u16) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "\x1b[?25l\x1b[H");
        var last: ?Style = null;
        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            var line: [32]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "\x1b[{d};1H", .{y + 1}));
            var x: u16 = 0;
            while (x < self.width) : (x += 1) {
                const cell = self.cells[@as(usize, y) * self.width + x];
                if (last == null or !sameStyle(last.?, cell.style)) {
                    try appendStyle(gpa, &out, cell.style);
                    last = cell.style;
                }
                var utf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.ch, &utf) catch 1;
                try out.appendSlice(gpa, utf[0..n]);
            }
        }
        try out.appendSlice(gpa, "\x1b[0m");
        if (cursor) |cxy| {
            var line: [32]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "\x1b[{d};{d}H\x1b[?25h", .{ cxy[1] + 1, cxy[0] + 1 }));
        }
        return out.toOwnedSlice(gpa);
    }
};

fn sameStyle(a: Style, b: Style) bool {
    return a.bold == b.bold and eqlColor(a.fg, b.fg) and eqlColor(a.bg, b.bg);
}

fn eqlColor(a: ?Color, b: ?Color) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
}

fn appendStyle(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: Style) !void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(gpa, "\x1b[0m");
    if (s.bold) try out.appendSlice(gpa, "\x1b[1m");
    if (s.fg) |f| try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ f.r, f.g, f.b }));
    if (s.bg) |g| try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};{d}m", .{ g.r, g.g, g.b }));
}

test "decode keys" {
    try std.testing.expectEqual(Key.enter, decode("\r").?);
    try std.testing.expectEqual(Key.up, decode("\x1b[A").?);
    try std.testing.expectEqual(Key.page_down, decode("\x1b[6~").?);
    try std.testing.expectEqual(Key.delete, decode("\x1b[3~").?);
    try std.testing.expectEqual(@as(u21, 'x'), decode("x").?.char);
    try std.testing.expectEqual(@as(u21, 0x00e9), decode("\xc3\xa9").?.char);
    try std.testing.expectEqual(Key.ctrl_c, decode("\x03").?);
}

test "screen put clips and renders" {
    const gpa = std.testing.allocator;
    var s = try Screen.init(gpa, 6, 2);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 4), s.put(2, 0, 10, "hello", .{}));
    const bytes = try s.render(gpa, .{ 1, 1 });
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "  hell") != null);
}

test "every declaration compiles" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Terminal);
    std.testing.refAllDecls(Screen);
}
