//! Port of maqam-live `src/ui.rs`: the terminal UI, one row per timeline entry. Layout, colors,
//! glyphs, keys and panel texts are the Rust's; ratatui/crossterm are replaced by term.zig (a cell
//! grid flushed as one write per frame, raw keys read with a 40 ms timeout).
//!
//! Layout (top to bottom): the timeline box (at least 3 rows) titled with the session and globals
//! file names and the latency / level meter; the " cmd " input box (3 rows) with an inverse block
//! cursor; the response box (4 rows; red when the message starts with ✗) or the status line; and
//! one recording / NAM download line. `?` opens the README overlay, `ls` the jins registry.
//!
//! Deliberate differences from the Rust:
//! * The help overlay shows the command language reference only: the Rust embedded README.md with
//!   include_str!, and a Zig module rooted in src/ cannot @embedFile a file outside src/.
//! * term.Style has no underline, so the current rhythm subdivision is drawn bold only, and the
//!   overlay headings are bold only.
//! * Ctrl-q is read here from the raw byte (term.decode drops control bytes); Ctrl-c as upstream.
//! * The terminal is entered and left here (the same modes and escapes as term.Terminal.enter /
//!   leave) and frames are written through std.Io: term.Terminal.writeRaw uses std.posix.write,
//!   which Zig 0.17.1 does not have.
//! * The terminal is restored on every exit path, errors included (a `defer` around the loop);
//!   NO_COLOR is not consulted (always truecolor), like the Rust's force_color_output(true).
const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const command = @import("command.zig");
const sequencer = @import("sequencer.zig");
const shared_mod = @import("shared.zig");
const term = @import("term.zig");
const tuning = @import("tuning.zig");
const vcf = @import("vcf.zig");
const fx = @import("fx.zig");

const App = app_mod.App;
const rfix = app_mod.rfix;
const Shared = shared_mod.Shared;
const Color = term.Color;
const Style = term.Style;
const Screen = term.Screen;
const Key = term.Key;

const BG: Color = .{ .r = 0, .g = 0, .b = 0 };
const BORDER: Color = .{ .r = 0, .g = 255, .b = 0 };
const ACCENT: Color = .{ .r = 0, .g = 255, .b = 0 };
const DIM: Color = .{ .r = 0, .g = 180, .b = 0 };
const CMD: Color = .{ .r = 0, .g = 255, .b = 0 };
const ERR: Color = .{ .r = 255, .g = 80, .b = 80 };
const CURRENT_GREEN: Color = .{ .r = 80, .g = 255, .b = 120 };
const NEXT_DIFFERENT_BLUE: Color = .{ .r = 95, .g = 125, .b = 230 };
const NEXT_BLUE: Color = .{ .r = 70, .g = 150, .b = 255 };
const INACTIVE_GRAY: Color = .{ .r = 128, .g = 128, .b = 128 };
const ROW_GUARD: Color = .{ .r = 0, .g = 0, .b = 0 };

fn st(fg: Color) Style {
    return .{ .fg = fg, .bg = BG };
}

fn bold(fg: Color) Style {
    return .{ .fg = fg, .bg = BG, .bold = true };
}

/// The TUI loop until the App quits; the terminal is restored however it ends.
pub fn run(app: *App, io: std.Io) !void {
    const gpa = app.gpa;
    var terminal = try enterTerminal(io);
    defer leaveTerminal(io, &terminal);
    var screen = try Screen.init(gpa, terminal.width, terminal.height);
    defer screen.deinit(gpa);
    while (true) {
        try app.tick();
        terminal.refreshSize();
        if (terminal.width != screen.width or terminal.height != screen.height) {
            const next = try Screen.init(gpa, terminal.width, terminal.height);
            screen.deinit(gpa);
            screen = next;
        }
        const cursor = try draw(gpa, app, &screen);
        const bytes = try screen.render(gpa, cursor);
        defer gpa.free(bytes);
        writeOut(io, bytes);
        if (readKey(&terminal, 40)) |key| {
            try handleKey(app, key);
            // The rest of a paste is handled before the next redraw.
            while (!app.should_quit and pending_len > 0) {
                const next = takeKey() orelse break;
                try handleKey(app, next);
            }
        }
        if (app.should_quit) break;
    }
}

/// term.Terminal.enter, writing through std.Io (term.Terminal.writeRaw calls std.posix.write,
/// which Zig 0.17 no longer has).
fn enterTerminal(io: std.Io) !term.Terminal {
    const posix = std.posix;
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
    var t: term.Terminal = .{ .fd = fd, .saved = saved };
    writeOut(io, "\x1b[?1049h\x1b[?25l\x1b[2J");
    t.refreshSize();
    return t;
}

fn leaveTerminal(io: std.Io, t: *term.Terminal) void {
    writeOut(io, "\x1b[0m\x1b[?25h\x1b[?1049l");
    std.posix.tcsetattr(t.fd, .FLUSH, t.saved) catch {};
}

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

/// Bytes read from the terminal and not yet decoded: a paste or a fast typist delivers several
/// keys in one read, and every one of them must reach the App (upstream crossterm queues them).
var pending: [256]u8 = undefined;
var pending_len: usize = 0;

/// term.Terminal.readKey, one key at a time from `pending`, plus Ctrl-q (byte 17), which
/// term.decode drops.
fn readKey(t: *term.Terminal, timeout_ms: i32) ?Key {
    const posix = std.posix;
    if (pending_len == 0) {
        var fds = [_]posix.pollfd{.{ .fd = t.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return null;
        if (ready == 0) return null;
        const n = posix.read(t.fd, &pending) catch return null;
        if (n == 0) return null;
        pending_len = n;
    }
    return takeKey();
}

/// Decodes and removes the first key in `pending`; bytes that form no key are skipped.
fn takeKey() ?Key {
    while (pending_len > 0) {
        const len = keyLength(pending[0..pending_len]);
        const bytes = pending[0..len];
        const key: ?Key = if (bytes[0] == 17) .ctrl_c else term.decode(bytes);
        std.mem.copyForwards(u8, pending[0 .. pending_len - len], pending[len..pending_len]);
        pending_len -= len;
        if (key) |k| return k;
    }
    return null;
}

/// How many bytes the first key of `b` takes: an escape sequence (ESC [ or ESC O, then
/// parameters up to the final byte), one UTF-8 character, or one byte.
fn keyLength(b: []const u8) usize {
    if (b[0] == 27) {
        if (b.len >= 2 and (b[1] == '[' or b[1] == 'O')) {
            var i: usize = 2;
            while (i < b.len) : (i += 1) {
                if (b[i] >= 0x40 and b[i] <= 0x7e) return i + 1;
            }
            return b.len;
        }
        return 1;
    }
    const n = std.unicode.utf8ByteSequenceLength(b[0]) catch return 1;
    return @min(n, b.len);
}

test "a pasted line reaches the App key by key" {
    const line = "bpm 100\r\x1b[A\xc3\xa9\x11";
    @memcpy(pending[0..line.len], line);
    pending_len = line.len;
    var got: [16]Key = undefined;
    var n: usize = 0;
    while (takeKey()) |k| : (n += 1) got[n] = k;
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqual(@as(u21, 'b'), got[0].char);
    try std.testing.expectEqual(@as(u21, '0'), got[6].char);
    try std.testing.expectEqual(Key.enter, got[7]);
    try std.testing.expectEqual(Key.up, got[8]);
    try std.testing.expectEqual(@as(u21, 0x00e9), got[9].char);
    try std.testing.expectEqual(Key.ctrl_c, got[10]);
}

/// One key (the Rust event match).
pub fn handleKey(app: *App, key: Key) Allocator.Error!void {
    if (app.show_help) {
        switch (key) {
            .up => app.overlayScrollUp(),
            .down => app.overlayScrollDown(),
            .home => app.overlayScrollHome(),
            else => {
                app.show_help = false;
                app.help_scroll = 0;
            },
        }
        return;
    }
    if (app.show_jins) {
        switch (key) {
            .up => app.overlayScrollUp(),
            .down => app.overlayScrollDown(),
            .home => app.overlayScrollHome(),
            else => {
                app.show_jins = false;
                app.jins_scroll = 0;
            },
        }
        return;
    }
    switch (key) {
        .ctrl_c => app.should_quit = true,
        .enter => {
            const trimmed_empty = std.mem.trim(u8, app.input.items, " \t\r\n").len == 0 and isUnicodeBlank(app.input.items);
            const src: []const u8 = if (trimmed_empty) (app.lastHistory() orelse "") else app.input.items;
            const line = try app.gpa.dupe(u8, src);
            defer app.gpa.free(line);
            try app.historyPush(line);
            app.input.clearRetainingCapacity();
            app.cursor_pos = 0;
            app.messageScrollHome();
            try app.handleCommand(line);
        },
        .up => try app.historyUp(),
        .down => try app.historyDown(),
        .left => app.cursorLeft(),
        .right => app.cursorRight(),
        .home => app.cursorHome(),
        .end => app.cursorEnd(),
        .page_up => app.messageScrollUp(),
        .page_down => app.messageScrollDown(),
        .tab => try app.completeInput(),
        .delete => {
            app.history_pos = null;
            app.deleteChar();
        },
        .backspace => {
            app.history_pos = null;
            app.backspace();
        },
        .char => |c| {
            app.history_pos = null;
            try app.insertChar(c);
        },
        .esc => {
            app.input.clearRetainingCapacity();
            app.cursor_pos = 0;
            if (app.message) |m| app.gpa.free(m);
            app.message = null;
            app.history_pos = null;
        },
    }
}

/// True when `s` is all (Unicode) whitespace, Rust `str::trim().is_empty()`.
fn isUnicodeBlank(s: []const u8) bool {
    return sequencer.rust_str.trim(s).len == 0;
}

/// Draws the whole frame; returns where the terminal cursor goes.
pub fn draw(gpa: Allocator, app: *const App, screen: *Screen) Allocator.Error!?[2]u16 {
    screen.clear(st(INACTIVE_GRAY));
    const w = screen.width;
    const h = screen.height;
    if (app.show_help) {
        try drawHelp(gpa, app, screen);
        return null;
    }
    if (app.show_jins) {
        try drawJinsList(gpa, app, screen);
        return null;
    }
    // Constraint::Min(3), Length(3), Length(4), Length(1)
    const fixed: u16 = 3 + 4 + 1;
    const phrases_h: u16 = if (h > fixed) h - fixed else 0;
    try drawPhrases(gpa, app, screen, .{ .x = 0, .y = 0, .w = w, .h = phrases_h });
    const cursor = drawInput(app, screen, .{ .x = 0, .y = phrases_h, .w = w, .h = 3 });
    try drawStatus(gpa, app, screen, .{ .x = 0, .y = phrases_h + 3, .w = w, .h = 4 });
    try drawRecording(gpa, app, screen, .{ .x = 0, .y = phrases_h + 7, .w = w, .h = 1 });
    return cursor;
}

const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// A line being written left to right, clipped at `max` columns.
const Line = struct {
    screen: *Screen,
    x: u16,
    y: u16,
    max: u16,
    col: u16 = 0,

    fn put(self: *Line, text: []const u8, style: Style) void {
        if (self.col >= self.max) return;
        self.col += self.screen.put(self.x + self.col, self.y, self.max - self.col, text, style);
    }

    fn print(self: *Line, buf: []u8, comptime f: []const u8, args: anytype, style: Style) void {
        const s = std.fmt.bufPrint(buf, f, args) catch return;
        self.put(s, style);
    }

    /// `text` padded with spaces to `width` characters (Rust `{:<width$}`).
    fn padded(self: *Line, text: []const u8, width: usize, style: Style) void {
        self.put(text, style);
        var n = charCount(text);
        while (n < width) : (n += 1) self.put(" ", style);
    }
};

fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

const JumpBack = struct { target: usize, source: usize, jump_id: usize, times: usize, failure: bool };

fn positionOfId(phrases: []const sequencer.Phrase, id: usize) ?usize {
    for (phrases, 0..) |p, i| if (p.id == id) return i;
    return null;
}

fn drawPhrases(gpa: Allocator, app: *const App, screen: *Screen, area: Rect) Allocator.Error!void {
    if (area.h == 0) return;
    const sh = app.shared;
    const cur = sh.cur_phrase.load(.monotonic);
    const cur_sub = sh.cur_subdiv.load(.monotonic);
    const cur_plays = sh.cur_plays.load(.monotonic);
    const next = sh.next_phrase.load(.monotonic);
    const exit = sh.exit_phrase.load(.monotonic);
    const phrases = app.phrases.items;
    const n = @max(phrases.len, 1);
    const current_is_last_repeat = if (cur % n < phrases.len) cur_plays + 1 >= @max(phrases[cur % n].repeat, 1) else true;

    var upcoming_jump_source: ?usize = null;
    if (phrases.len > 0) {
        var position = (cur +% 1) % phrases.len;
        for (0..phrases.len) |_| {
            const p = &phrases[position];
            if (p.jump != null) {
                upcoming_jump_source = position;
                break;
            }
            if (p.control == null) break;
            position = (position + 1) % phrases.len;
        }
    }

    var jumpbacks: std.ArrayList(JumpBack) = .empty;
    defer jumpbacks.deinit(gpa);
    for (phrases, 0..) |p, source| {
        const jump = p.jump orelse continue;
        if (positionOfId(phrases, jump.target_id)) |target| if (target != source)
            try jumpbacks.append(gpa, .{ .target = target, .source = source, .jump_id = p.id, .times = jump.times, .failure = false });
        if (jump.fail_target_id) |fid| if (positionOfId(phrases, fid)) |target| if (target != source)
            try jumpbacks.append(gpa, .{ .target = target, .source = source, .jump_id = p.id, .times = jump.times, .failure = true });
    }

    var status_width: usize = "[settings]".len;
    for (phrases) |p| {
        var buf: [64]u8 = undefined;
        const s = if (p.jump) |j|
            (if (j.times == 0) "[always]" else std.fmt.bufPrint(&buf, "[{d}/{d}]", .{ j.times, j.times }) catch "")
        else
            std.fmt.bufPrint(&buf, "[{d}/{d}]", .{ @max(p.repeat, 1), @max(p.repeat, 1) }) catch "";
        status_width = @max(status_width, s.len);
    }

    // The block with its banner.
    screen.box(area.x, area.y, area.w, area.h, "", st(BORDER));
    {
        const fname = app.sessionFilename();
        const globals = try app.globalsFilename(gpa);
        defer gpa.free(globals);
        const title = if (fname) |f|
            try std.fmt.allocPrint(gpa, " maqam-live {s} {s} ", .{ f, globals })
        else
            try std.fmt.allocPrint(gpa, " maqam-live {s} ", .{globals});
        defer gpa.free(title);
        const meter_inner = try latencyStatus(gpa, sh);
        defer gpa.free(meter_inner);
        const meter = try std.fmt.allocPrint(gpa, " {s} ", .{meter_inner});
        defer gpa.free(meter);
        // Buffer skips are shown, in red, from the first one on (proof "A buffer skip is never silent").
        const skips = sh.underruns.load(.monotonic);
        const xrun = if (skips > 0) try std.fmt.allocPrint(gpa, " xrun {d} ", .{skips}) else try gpa.dupe(u8, "");
        defer gpa.free(xrun);
        const title_width: usize = area.w -| 2;
        const padding = title_width -| (charCount(title) + charCount(xrun) + charCount(meter));
        var line: Line = .{ .screen = screen, .x = area.x + 1, .y = area.y, .max = @intCast(title_width) };
        line.put(title, bold(ACCENT));
        for (0..padding) |_| line.put(" ", .{ .bg = BG });
        line.put(xrun, bold(ERR));
        line.put(meter, st(DIM));
    }

    const inner_w: u16 = area.w -| 2;
    const rows: usize = area.h -| 2;
    for (phrases, 0..) |*phrase, idx| {
        if (idx >= rows) break;
        var line: Line = .{ .screen = screen, .x = area.x + 1, .y = area.y + 1 + @as(u16, @intCast(idx)), .max = inner_w };
        const playing = idx == cur % n;
        const is_up_next = !playing and idx == next;
        const is_next_different = !playing and idx == exit;
        const state_color = if (playing) CURRENT_GREEN else if (is_up_next) NEXT_BLUE else if (is_next_different) NEXT_DIFFERENT_BLUE else INACTIVE_GRAY;
        var buf: [96]u8 = undefined;

        line.put("•", st(ROW_GUARD));
        line.print(&buf, "{d:>3}: ", .{phrase.id}, st(state_color));
        const marker = if (playing) "▶ " else if (is_up_next) "▸ " else if (is_next_different) (if (current_is_last_repeat) "▷ " else "◇ ") else "· ";
        line.put(marker, bold(state_color));
        // Jump arrows
        for (jumpbacks.items) |jb| {
            const on_path = @min(jb.target, jb.source) <= idx and idx <= @max(jb.target, jb.source);
            if (!on_path) {
                line.put("    ", st(INACTIVE_GRAY));
                continue;
            }
            const value = sh.jumpCounter(jb.jump_id);
            const success = jb.times == 0 or value +| 1 < @max(jb.times, 1);
            const will_jump = upcoming_jump_source == jb.source and (if (jb.failure) !success else success);
            if (idx == jb.target) {
                line.put(if (jb.target < jb.source) "┌──>" else "└──>", st(if (will_jump) NEXT_DIFFERENT_BLUE else INACTIVE_GRAY));
            } else if (idx == jb.source and will_jump and current_is_last_repeat) {
                line.put("●   ", st(NEXT_BLUE));
            } else {
                line.put("│   ", st(INACTIVE_GRAY));
            }
        }
        const display = try phrase.displaySrc(gpa);
        defer gpa.free(display);

        if (phrase.jump) |js| {
            const valid_target = positionOfId(phrases, js.target_id) != null and
                (if (js.fail_target_id) |fid| positionOfId(phrases, fid) != null else true);
            const pass = sh.jumpCounter(phrase.id);
            const counter_text = if (js.times == 0)
                "[always]"
            else
                std.fmt.bufPrint(&buf, "[{d}/{d}]", .{ @min(pass +| 1, js.times), js.times }) catch "";
            const col_src: Color = if (!valid_target) .{ .r = 255, .g = 80, .b = 80 } else state_color;
            const col_ctr: Color = if (!valid_target) .{ .r = 255, .g = 120, .b = 120 } else state_color;
            line.padded(counter_text, status_width, bold(col_ctr));
            line.put(" ", bold(col_ctr));
            line.put(display, bold(col_src));
            if (!valid_target) line.put("  [missing target]", bold(.{ .r = 255, .g = 100, .b = 100 }));
            continue;
        }
        if (phrase.control) |control| {
            const status = if (control == .stop) "[stop]" else "[settings]";
            line.padded(status, status_width, st(state_color));
            line.put(" ", st(state_color));
            line.put(display, bold(state_color));
            continue;
        }
        const total_plays = @max(phrase.repeat, 1);
        const displayed_play = if (playing) @min(cur_plays +| 1, total_plays) else 1;
        const plays = std.fmt.bufPrint(&buf, "[{d}/{d}]", .{ displayed_play, total_plays }) catch "";
        const play_style: Style = .{ .fg = state_color, .bg = BG, .bold = playing };
        line.padded(plays, status_width, play_style);
        line.put(" ", play_style);
        line.padded(display, 28, st(state_color));
        line.put(" ", .{});
        const rhythm = try phrase.rhythmDisplay(gpa);
        defer gpa.free(rhythm);
        var it = std.unicode.Utf8View.initUnchecked(rhythm).iterator();
        var si: usize = 0;
        while (it.nextCodepointSlice()) |ch| : (si += 1) {
            // `z` silences score voices but leaves the sequencer running so the sympathetic
            // strings keep following the current scale: show that silent traversal like playback.
            const is_now = playing and si == cur_sub;
            line.put(ch, .{ .fg = state_color, .bg = BG, .bold = is_now });
        }
        const ratios = try phrase.pitchRatiosDisplay(gpa);
        defer gpa.free(ratios);
        if (ratios.len > 0) {
            line.put("  ", .{});
            line.put(ratios, st(DIM));
        }
    }
}

fn drawInput(app: *const App, screen: *Screen, area: Rect) ?[2]u16 {
    screen.box(area.x, area.y, area.w, area.h, "", st(BORDER));
    _ = screen.put(area.x + 1, area.y, area.w -| 2, " cmd ", st(DIM));
    var line: Line = .{ .screen = screen, .x = area.x + 1, .y = area.y + 1, .max = area.w -| 2 };
    line.put("> ", st(DIM));
    const text = app.input.items;
    const count = charCount(text);
    const cursor = @min(app.cursor_pos, count);
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var idx: usize = 0;
    const cursor_style: Style = .{ .fg = BG, .bg = CMD, .bold = true };
    while (it.nextCodepointSlice()) |ch| : (idx += 1) {
        line.put(ch, if (idx == cursor) cursor_style else st(CMD));
    }
    if (cursor >= count) line.put(" ", cursor_style);
    // Keep the real terminal cursor aligned with the painted inverse cursor cell.
    const cx = @as(usize, area.x) + 1 + 2 + cursor;
    return .{ @intCast(@min(cx, std.math.maxInt(u16))), area.y + 1 };
}

fn drawStatus(gpa: Allocator, app: *const App, screen: *Screen, area: Rect) Allocator.Error!void {
    if (app.message) |msg| {
        const col = if (std.mem.startsWith(u8, msg, "✗")) ERR else DIM;
        screen.box(area.x, area.y, area.w, area.h, "", st(BORDER));
        _ = screen.put(area.x + 1, area.y, area.w -| 2, " response PgUp/PgDn ", st(DIM));
        const inner_w: usize = area.w -| 2;
        const lines = try wrapText(gpa, msg, inner_w);
        defer gpa.free(lines);
        const rows: usize = area.h -| 2;
        var row: usize = 0;
        var i: usize = app.message_scroll;
        while (row < rows and i < lines.len) : ({
            row += 1;
            i += 1;
        }) {
            _ = screen.put(area.x + 1, area.y + 1 + @as(u16, @intCast(row)), @intCast(inner_w), lines[i], st(col));
        }
        return;
    }
    const vcf_status = try vcfStatus(gpa, app.vcf);
    defer gpa.free(vcf_status);
    const fx_status = try formatFxStatus(gpa, app.fx);
    defer gpa.free(fx_status);
    const text = try std.fmt.allocPrint(gpa, "  {s}BPM:{d} sus:{f}s vcf:{s} fx:{s} vol:{f} phrases:{d}  [?] help  [z] sound  [z id] jump", .{
        if (app.paused) "⏸ PAUSED  " else "",
        app.bpm,
        rfix(app.sustain, 1),
        vcf_status,
        fx_status,
        rfix(app.vol, 2),
        app.phrases.items.len,
    });
    defer gpa.free(text);
    _ = screen.put(area.x, area.y, area.w, text, st(DIM));
}

/// Paragraph wrapping (ratatui Wrap { trim: false }): each line broken at word boundaries, a
/// word longer than the width broken by characters. The slices borrow `text`.
fn wrapText(gpa: Allocator, text: []const u8, width: usize) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    const w = @max(width, 1);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var start: usize = 0;
        if (line.len == 0) {
            try out.append(gpa, line);
            continue;
        }
        while (start < line.len) {
            // Find the longest prefix of at most w characters, preferring to end after a space.
            var i = start;
            var chars: usize = 0;
            var last_space: ?usize = null;
            while (i < line.len and chars < w) {
                const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
                if (line[i] == ' ') last_space = i + 1;
                i = @min(i + n, line.len);
                chars += 1;
            }
            var end = i;
            if (i < line.len and line[i] != ' ') {
                if (last_space) |s| if (s > start) {
                    end = s;
                };
            }
            try out.append(gpa, line[start..end]);
            start = end;
            if (start < line.len and line[start] == ' ' and end == i) start += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn latencyStatus(gpa: Allocator, sh: *const Shared) Allocator.Error![]u8 {
    var b: [5][32]u8 = undefined;
    const left = latencyValue(&b[0], sh.latency_left_us.load(.monotonic));
    const right = latencyValue(&b[1], sh.latency_right_us.load(.monotonic));
    const in_l = levelValue(&b[2], Shared.loadLevel(&sh.input_left_level));
    const in_r = levelValue(&b[3], Shared.loadLevel(&sh.input_right_level));
    const post = levelValue(&b[4], Shared.loadLevel(&sh.nam_output_level));
    const nam = switch (sh.nam_status.load(.monotonic)) {
        1 => "on",
        2 => "login",
        3 => "downloading",
        4 => "error",
        5 => "bypass",
        else => "none",
    };
    return std.fmt.allocPrint(gpa, "lat L:{s} R:{s}  in L:{s} R:{s}dB post:{s}dB NAM:{s}", .{ left, right, in_l, in_r, post, nam });
}

fn latencyValue(buf: []u8, us: u64) []const u8 {
    if (us == 0) return "--";
    return std.fmt.bufPrint(buf, "{f}ms", .{rfix(@as(f64, @floatFromInt(us)) / 1000.0, 1)}) catch "--";
}

/// A linear level in dBFS ("-∞" at silence). The Rust kept the level as millionths in a u32;
/// shared.zig keeps the f32 itself.
fn levelValue(buf: []u8, level: f32) []const u8 {
    if (!(level > 0)) return "-∞";
    return std.fmt.bufPrint(buf, "{f}", .{rfix(20.0 * std.math.log10(@as(f64, level)), 0)}) catch "-∞";
}

fn vcfStatus(gpa: Allocator, bank: vcf.VcfBank) Allocator.Error![]u8 {
    if (bank.all.enabled) return formatVcfStatus(gpa, bank.all);
    var parts: std.ArrayList(u8) = .empty;
    errdefer parts.deinit(gpa);
    for ([_]vcf.VcfSettings{ bank.mic, bank.bass, bank.kanun, bank.kick, bank.tanbura }) |s| {
        if (!s.enabled) continue;
        const part = try formatVcfStatus(gpa, s);
        defer gpa.free(part);
        if (parts.items.len > 0) try parts.append(gpa, ' ');
        try parts.appendSlice(gpa, part);
    }
    if (parts.items.len == 0) try parts.appendSlice(gpa, "off");
    return parts.toOwnedSlice(gpa);
}

fn formatVcfStatus(gpa: Allocator, v: vcf.VcfSettings) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}:{f}/{f}/{f}/{s}", .{ v.target.asStr(), rfix(v.cutoff_hz, 0), rfix(v.resonance, 2), rfix(v.drive, 1), v.wave.asStr() });
}

fn formatFxStatus(gpa: Allocator, f: fx.FxSettings) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (f.flanger_enabled) try out.print(gpa, "flg:{f}/{f}/{f}", .{ rfix(f.flanger_rate_hz, 2), rfix(f.flanger_feedback, 2), rfix(f.flanger_mix, 2) });
    if (f.chorus_enabled) {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.print(gpa, "chr:{f}/{f}/{f}", .{ rfix(f.chorus_rate_hz, 2), rfix(f.chorus_depth, 2), rfix(f.chorus_mix, 2) });
    }
    if (f.reverb_enabled) {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.print(gpa, "rev:{f}/{f}", .{ rfix(f.reverb_mix, 2), rfix(f.reverb_decay, 2) });
    }
    if (f.delay_enabled) {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.print(gpa, "delay:{f}/{f}/{f}", .{ rfix(f.delay_time_secs, 2), rfix(f.delay_feedback, 2), rfix(f.delay_mix, 2) });
    }
    if (f.cabinet_enabled) {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.print(gpa, "cab:{s}/{f}", .{ f.cabinet_model.name(), rfix(f.cabinet_mix, 2) });
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "off");
    return out.toOwnedSlice(gpa);
}

/// A progress bar: '=' for the filled part, '>' at its head, spaces after.
fn progressBar(gpa: Allocator, bar_w: usize, filled: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, '=', @min(filled, bar_w));
    if (filled < bar_w) try out.append(gpa, '>');
    try out.appendNTimes(gpa, ' ', bar_w -| (filled + 1));
    return out.toOwnedSlice(gpa);
}

fn drawRecording(gpa: Allocator, app: *const App, screen: *Screen, area: Rect) Allocator.Error!void {
    const sh = app.shared;
    var line: Line = .{ .screen = screen, .x = area.x, .y = area.y, .max = area.w };
    const grey: Color = .{ .r = 160, .g = 160, .b = 180 };
    const green: Color = .{ .r = 0, .g = 200, .b = 100 };
    const red: Color = .{ .r = 200, .g = 80, .b = 80 };
    if (sh.rec_active.load(.monotonic)) {
        const done = sh.rec_samples_done.load(.monotonic);
        const total = @max(sh.rec_samples_total.load(.monotonic), 1);
        const pct = @min(done *| 100 / total, 100);
        const bar_w = @max(@as(usize, area.w) -| 22, 4);
        const bar = try progressBar(gpa, bar_w, bar_w * pct / 100);
        defer gpa.free(bar);
        var buf: [32]u8 = undefined;
        line.put("  ◉ rendering [", st(red));
        line.put(bar, st(green));
        line.print(&buf, "] {d:>3}%", .{pct}, st(grey));
    } else if (app.nam_download_progress) |p| {
        const pct: ?u64 = if (p.total) |t| (if (t > 0) @min(p.downloaded *| 100 / t, 100) else null) else null;
        const bar_w = @max(@as(usize, area.w) -| 36, 4);
        const filled: usize = if (pct) |x| bar_w * @as(usize, @intCast(x)) / 100 else 0;
        const bar = try progressBar(gpa, bar_w, filled);
        defer gpa.free(bar);
        const action = if (p.load_after) "load" else "cache";
        const suffix = if (pct) |x|
            try std.fmt.allocPrint(gpa, "] {d:>3}% {s} {s}", .{ x, action, p.name })
        else blk: {
            var sb: [32]u8 = undefined;
            break :blk try std.fmt.allocPrint(gpa, "] {s} {s} {s}", .{ formatDownloadSize(&sb, p.downloaded), action, p.name });
        };
        defer gpa.free(suffix);
        line.put("  ↓ NAM [", st(.{ .r = 120, .g = 170, .b = 255 }));
        line.put(bar, st(green));
        line.put(suffix, st(grey));
    } else if (app.last_recording) |path| {
        line.put("  ◉ ", st(red));
        line.put(path, st(grey));
    } else {
        line.put("  m → record cycle to ./maqam-<ts>.mp4", st(.{ .r = 55, .g = 55, .b = 70 }));
    }
}

fn formatDownloadSize(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes >= 1_048_576) return std.fmt.bufPrint(buf, "{f} MiB", .{rfix(b / 1_048_576.0, 1)}) catch "";
    if (bytes >= 1024) return std.fmt.bufPrint(buf, "{f} KiB", .{rfix(b / 1024.0, 0)}) catch "";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
}

/// Draws `lines` (text and style) inside a bordered box, scrolled by `scroll` rows.
fn drawScrolled(screen: *Screen, lines: []const StyledLine, scroll: u16) void {
    const w = screen.width;
    const h = screen.height;
    screen.box(0, 0, w, h, "", st(ACCENT));
    const rows: usize = h -| 2;
    var row: usize = 0;
    var i: usize = scroll;
    while (row < rows and i < lines.len) : ({
        row += 1;
        i += 1;
    }) {
        var line: Line = .{ .screen = screen, .x = 1, .y = 1 + @as(u16, @intCast(row)), .max = w -| 2 };
        for (lines[i].spans) |span| line.put(span.text, span.style);
    }
}

const Span = struct { text: []const u8, style: Style };
const StyledLine = struct { spans: []const Span };

fn drawHelp(gpa: Allocator, app: *const App, screen: *Screen) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const heading = bold(.{ .r = 0, .g = 255, .b = 0 });
    const dim = st(DIM);
    const plain = st(ACCENT);
    var lines: std.ArrayList(StyledLine) = .empty;
    try lines.append(arena, try one(arena, "  maqam-live — README", heading));
    try lines.append(arena, try one(arena, "  Esc closes, Up/Down scroll", dim));
    try lines.append(arena, try one(arena, "", plain));
    try lines.append(arena, try one(arena, "", plain));
    const reference = try command.languageReference(arena);
    // str::lines(): no empty line after the final newline
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, reference, "\n"), '\n');
    while (it.next()) |raw| {
        const text = try std.fmt.allocPrint(arena, "  {s}", .{raw});
        const style = if (std.mem.endsWith(u8, raw, ":"))
            heading
        else if (std.mem.startsWith(u8, raw, "- ") or std.mem.startsWith(u8, raw, "  - ") or std.mem.startsWith(u8, raw, "  note:"))
            dim
        else
            plain;
        try lines.append(arena, try one(arena, text, style));
    }
    drawScrolled(screen, lines.items, app.help_scroll);
}

fn one(arena: Allocator, text: []const u8, style: Style) Allocator.Error!StyledLine {
    const spans = try arena.alloc(Span, 1);
    spans[0] = .{ .text = text, .style = style };
    return .{ .spans = spans };
}

fn drawJinsList(gpa: Allocator, app: *const App, screen: *Screen) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const heading = bold(.{ .r = 0, .g = 255, .b = 0 });
    const dim = st(DIM);
    var lines: std.ArrayList(StyledLine) = .empty;
    try lines.append(arena, try one(arena, "  maqam-live — jins registry", heading));
    try lines.append(arena, try one(arena, "  Esc closes, Up/Down scroll", dim));
    try lines.append(arena, try one(arena, "", st(ACCENT)));
    try lines.append(arena, try one(arena, "  audition <Name>|<root> <Name>[, ...]   create <Name> <p/q> …   delete <Name>   ls", st(.{ .r = 0, .g = 160, .b = 0 })));
    try lines.append(arena, try one(arena, "", st(ACCENT)));
    const all = try tuning.Maqam.listAll(gpa);
    defer tuning.freeList(gpa, all);
    for (all) |entry| {
        const c = tuning.Maqam.colorForRatios(entry.ratios);
        const color: Color = .{ .r = c[0], .g = c[1], .b = c[2] };
        var rat: std.ArrayList(u8) = .empty;
        for (entry.ratios, 0..) |r, i| {
            if (i > 0) try rat.appendSlice(arena, "  ");
            try rat.print(arena, "{d}/{d}", .{ r.p, r.q });
        }
        const name = try padRight(arena, entry.name, 14);
        const spans = try arena.alloc(Span, 2);
        spans[0] = .{ .text = try std.fmt.allocPrint(arena, "  {s}", .{name}), .style = bold(color) };
        spans[1] = .{ .text = rat.items, .style = st(color) };
        try lines.append(arena, .{ .spans = spans });
    }
    drawScrolled(screen, lines.items, app.jins_scroll);
}

fn padRight(gpa: Allocator, s: []const u8, width: usize) Allocator.Error![]u8 {
    const n = charCount(s);
    const out = try gpa.alloc(u8, s.len + (width -| n));
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const channel = @import("channel.zig");
const eventlog = @import("eventlog.zig");

const TestApp = struct {
    cmds: *app_mod.CmdRing,
    garbage: *app_mod.GarbageRing,
    shared: *Shared,
    log: *eventlog.EventLog,
    env: *std.process.Environ.Map,
    tmp: testing.TmpDir,
    app: *App,

    fn init() !TestApp {
        const gpa = testing.allocator;
        var t: TestApp = undefined;
        t.tmp = testing.tmpDir(.{});
        t.cmds = try gpa.create(app_mod.CmdRing);
        t.cmds.* = .{};
        t.garbage = try gpa.create(app_mod.GarbageRing);
        t.garbage.* = .{};
        t.shared = try gpa.create(Shared);
        t.shared.* = .{};
        t.log = try gpa.create(eventlog.EventLog);
        t.log.* = .{ .io = testing.io };
        t.env = try gpa.create(std.process.Environ.Map);
        t.env.* = .init(gpa);
        t.app = try App.init(gpa, testing.io, .{
            .cmds = t.cmds,
            .garbage = t.garbage,
            .shared = t.shared,
            .log = t.log,
            .env = t.env,
            .record_fn = noRecord,
            .http = app_mod.Http.offline,
            .cwd = t.tmp.dir,
        });
        return t;
    }

    /// Frees what was sent to the (absent) audio side; tests send far fewer than 512 commands.
    fn drain(t: *TestApp) void {
        while (t.cmds.tryRecv()) |c| c.deinit(testing.allocator);
    }

    fn deinit(t: *TestApp) void {
        const gpa = testing.allocator;
        t.app.deinit();
        t.drain();
        t.env.deinit();
        gpa.destroy(t.env);
        gpa.destroy(t.log);
        gpa.destroy(t.shared);
        gpa.destroy(t.garbage);
        gpa.destroy(t.cmds);
        t.tmp.cleanup();
    }

    fn cmd(t: *TestApp, line: []const u8) !void {
        try t.app.handleCommand(line);
        t.drain();
    }
};

fn noRecord(gpa: Allocator, _: std.Io, _: *Shared, _: []const sequencer.Phrase, _: f64, _: f64, _: vcf.VcfBank, _: fx.FxSettings, _: usize) app_mod.RecordResult {
    return .{ .err = gpa.dupe(u8, "no recorder in tests") catch @panic("oom") };
}

/// The text of screen row `y` (trailing spaces removed). Caller owns it.
fn rowText(gpa: Allocator, screen: *const Screen, y: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (screen.cells[@as(usize, y) * screen.width ..][0..screen.width]) |c| {
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c.ch, &b) catch 1;
        try out.appendSlice(gpa, b[0..n]);
    }
    const trimmed = std.mem.trimEnd(u8, out.items, " ");
    out.shrinkRetainingCapacity(trimmed.len);
    return out.toOwnedSlice(gpa);
}

fn screenHas(screen: *const Screen, needle: []const u8) !bool {
    var y: u16 = 0;
    while (y < screen.height) : (y += 1) {
        const row = try rowText(testing.allocator, screen, y);
        defer testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, needle) != null) return true;
    }
    return false;
}

test "the main view lays out the timeline, input, response and recording line" {
    var t = try TestApp.init();
    defer t.deinit();
    try t.cmd("d bayati 4444");
    try t.cmd("bpm 140");
    try t.cmd("j 0 3");
    try t.cmd("stop");
    var screen = try Screen.init(testing.allocator, 120, 20);
    defer screen.deinit(testing.allocator);
    const cursor = try draw(testing.allocator, t.app, &screen);

    const top = try rowText(testing.allocator, &screen, 0);
    defer testing.allocator.free(top);
    try testing.expect(std.mem.startsWith(u8, top, "┌ maqam-live .globals.ml "));
    try testing.expect(std.mem.indexOf(u8, top, " lat L:-- R:--  in L:-∞ R:-∞dB post:-∞dB NAM:none ┐") != null);
    try testing.expect(std.mem.indexOf(u8, top, "xrun") == null);

    const row0 = try rowText(testing.allocator, &screen, 1);
    defer testing.allocator.free(row0);
    try testing.expect(std.mem.startsWith(u8, row0, "│•  0: ▶ ┌──>[1/1]      d bayati 4444"));
    try testing.expect(std.mem.indexOf(u8, row0, "1/1 ") != null);
    const row1 = try rowText(testing.allocator, &screen, 2);
    defer testing.allocator.free(row1);
    try testing.expect(std.mem.startsWith(u8, row1, "│•  1: · │   [settings] bpm 140"));
    const row2 = try rowText(testing.allocator, &screen, 3);
    defer testing.allocator.free(row2);
    // the jump is the next sounding transition (row 1 is a control row), so its source shows ●
    try testing.expect(std.mem.startsWith(u8, row2, "│•  2: · ●   [1/3]      j 0 3"));
    const row3 = try rowText(testing.allocator, &screen, 4);
    defer testing.allocator.free(row3);
    try testing.expect(std.mem.startsWith(u8, row3, "│•  3: ·     [stop]     stop"));

    // input box at rows 12..14, response 15..18, recording 19
    const input_title = try rowText(testing.allocator, &screen, 12);
    defer testing.allocator.free(input_title);
    try testing.expect(std.mem.startsWith(u8, input_title, "┌ cmd ─"));
    try testing.expectEqual(@as(?[2]u16, .{ 3, 13 }), cursor);
    try testing.expect(try screenHas(&screen, "┌ response PgUp/PgDn ─"));
    try testing.expect(try screenHas(&screen, "stop line added"));
    const rec = try rowText(testing.allocator, &screen, 19);
    defer testing.allocator.free(rec);
    try testing.expectEqualStrings("  m → record cycle to ./maqam-<ts>.mp4", rec);
}

test "the status line replaces the response box when there is no message" {
    var t = try TestApp.init();
    defer t.deinit();
    try handleKey(t.app, .esc);
    try testing.expect(t.app.message == null);
    var screen = try Screen.init(testing.allocator, 140, 12);
    defer screen.deinit(testing.allocator);
    _ = try draw(testing.allocator, t.app, &screen);
    const status = try rowText(testing.allocator, &screen, 7);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("  BPM:120 sus:1.2s vcf:off fx:off vol:1.00 phrases:0  [?] help  [z] sound  [z id] jump", status);
}

test "an error message is drawn in red and wrapped" {
    var t = try TestApp.init();
    defer t.deinit();
    try t.cmd("j 0 1");
    var screen = try Screen.init(testing.allocator, 30, 14);
    defer screen.deinit(testing.allocator);
    _ = try draw(testing.allocator, t.app, &screen);
    // response box rows 9..12
    const cell = screen.cells[10 * 30 + 1];
    try testing.expectEqual(ERR, cell.style.fg.?);
    const first = try rowText(testing.allocator, &screen, 10);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.startsWith(u8, first, "│✗ jump ×1 is a no-op; use j"));
}

test "keys edit the input, run commands and recall history" {
    var t = try TestApp.init();
    defer t.deinit();
    for ("d bayati 4444") |c| try handleKey(t.app, .{ .char = c });
    try testing.expectEqualStrings("d bayati 4444", t.app.input.items);
    try handleKey(t.app, .enter);
    t.drain();
    try testing.expectEqual(@as(usize, 1), t.app.phrases.items.len);
    try testing.expectEqual(@as(usize, 0), t.app.input.items.len);
    // Enter on an empty line repeats the last command
    try handleKey(t.app, .enter);
    t.drain();
    try testing.expectEqual(@as(usize, 2), t.app.phrases.items.len);
    try handleKey(t.app, .up);
    try testing.expectEqualStrings("d bayati 4444", t.app.input.items);
    try handleKey(t.app, .backspace);
    try testing.expectEqual(@as(?usize, null), t.app.history_pos);
    try testing.expectEqualStrings("d bayati 444", t.app.input.items);
    try handleKey(t.app, .home);
    try handleKey(t.app, .delete);
    try testing.expectEqualStrings(" bayati 444", t.app.input.items);
    try handleKey(t.app, .esc);
    try testing.expectEqual(@as(usize, 0), t.app.input.items.len);
    try testing.expect(t.app.message == null);
    try handleKey(t.app, .ctrl_c);
    try testing.expect(t.app.should_quit);
}

test "help and jins overlays scroll and close on any other key" {
    var t = try TestApp.init();
    defer t.deinit();
    try t.cmd("?");
    try testing.expect(t.app.show_help);
    var screen = try Screen.init(testing.allocator, 100, 30);
    defer screen.deinit(testing.allocator);
    _ = try draw(testing.allocator, t.app, &screen);
    try testing.expect(try screenHas(&screen, "maqam-live — README"));
    try handleKey(t.app, .down);
    try testing.expectEqual(@as(u16, 1), t.app.help_scroll);
    try handleKey(t.app, .{ .char = 'x' });
    try testing.expect(!t.app.show_help);
    try testing.expectEqual(@as(u16, 0), t.app.help_scroll);

    try t.cmd("ls");
    try testing.expect(t.app.show_jins);
    _ = try draw(testing.allocator, t.app, &screen);
    try testing.expect(try screenHas(&screen, "maqam-live — jins registry"));
    try testing.expect(try screenHas(&screen, "  Bayati"));
    try handleKey(t.app, .esc);
    try testing.expect(!t.app.show_jins);
}

test "recording and download progress bars" {
    var t = try TestApp.init();
    defer t.deinit();
    t.shared.rec_active.store(true, .monotonic);
    t.shared.rec_samples_done.store(50, .monotonic);
    t.shared.rec_samples_total.store(100, .monotonic);
    var screen = try Screen.init(testing.allocator, 42, 12);
    defer screen.deinit(testing.allocator);
    _ = try draw(testing.allocator, t.app, &screen);
    const rec = try rowText(testing.allocator, &screen, 11);
    defer testing.allocator.free(rec);
    try testing.expectEqualStrings("  ◉ rendering [==========>         ]  50%", rec);
    t.shared.rec_active.store(false, .monotonic);
    t.app.nam_download_progress = .{ .name = try testing.allocator.dupe(u8, "clean"), .downloaded = 2048, .total = null, .load_after = true };
    _ = try draw(testing.allocator, t.app, &screen);
    const dl = try rowText(testing.allocator, &screen, 11);
    defer testing.allocator.free(dl);
    try testing.expectEqualStrings("  ↓ NAM [>     ] 2 KiB load clean", dl);
}

test "formatting helpers follow the Rust" {
    const gpa = testing.allocator;
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("1.5ms", latencyValue(&b, 1500));
    try testing.expectEqualStrings("-6", levelValue(&b, 0.5));
    try testing.expectEqualStrings("3.0 MiB", formatDownloadSize(&b, 3 * 1_048_576));
    try testing.expectEqualStrings("12 B", formatDownloadSize(&b, 12));
    const lines = try wrapText(gpa, "aaa bbb ccc\n\nlongword", 7);
    defer gpa.free(lines);
    try testing.expectEqual(@as(usize, 5), lines.len);
    try testing.expectEqualStrings("aaa bbb", lines[0]);
    try testing.expectEqualStrings("ccc", lines[1]);
    try testing.expectEqualStrings("", lines[2]);
    try testing.expectEqualStrings("longwor", lines[3]);
    try testing.expectEqualStrings("d", lines[4]);
    const fxs = try formatFxStatus(gpa, .{ .reverb_enabled = true, .reverb_mix = 0.25, .reverb_decay = 0.5 });
    defer gpa.free(fxs);
    try testing.expectEqualStrings("rev:0.25/0.50", fxs);
}

test "every declaration compiles" {
    testing.refAllDecls(@This());
}

test "buffer skips appear in the header, in red, from the first one" {
    var t = try TestApp.init();
    defer t.deinit();
    t.app.shared.underruns.store(3, .monotonic);
    var screen = try Screen.init(testing.allocator, 120, 20);
    defer screen.deinit(testing.allocator);
    _ = try draw(testing.allocator, t.app, &screen);
    const top = try rowText(testing.allocator, &screen, 0);
    defer testing.allocator.free(top);
    try testing.expect(std.mem.indexOf(u8, top, " xrun 3  lat L:--") != null);
}
