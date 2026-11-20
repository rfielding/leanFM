//! A minimal PNG encoder for the recorder's video layers (carpet background, center Gosper
//! overlay, jump arrows): 8-bit RGB or RGBA, one IDAT chunk, every scanline with filter type 0,
//! zlib-compressed with `std.compress.flate.Compress` (fastest level), CRC-32 from `std.hash`.
//!
//! New in the Zig port: upstream `carpet.rs` writes binary PPM (P6) files instead. ffmpeg reads
//! either; PNG is several times smaller for these mostly black layers and keeps RGBA available.
const std = @import("std");
const flate = std.compress.flate;

pub const ColorType = enum(u8) {
    rgb8 = 2,
    rgba8 = 6,

    pub fn channels(self: ColorType) usize {
        return switch (self) {
            .rgb8 => 3,
            .rgba8 => 4,
        };
    }
};

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// Largest width or height PNG allows (2^31 - 1).
pub const max_dimension: u32 = 0x7fff_ffff;

pub const Error = error{ InvalidImage, OutOfMemory };

/// The bytes of a PNG holding `pixels` (row-major, `width * height * channels` bytes, no padding).
/// Caller owns the result.
pub fn encode(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, color: ColorType) Error![]u8 {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidImage;
    const row_len = std.math.mul(usize, width, color.channels()) catch return error.InvalidImage;
    const total = std.math.mul(usize, row_len, height) catch return error.InvalidImage;
    if (pixels.len != total) return error.InvalidImage;

    // zlib stream of the filtered scanlines.
    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer z.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = flate.Compress.init(&z.writer, window, .zlib, .fastest) catch return error.OutOfMemory;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        c.writer.writeByte(0) catch return error.OutOfMemory;
        c.writer.writeAll(pixels[y * row_len ..][0..row_len]) catch return error.OutOfMemory;
    }
    c.finish() catch return error.OutOfMemory;
    const idat = z.written();
    if (idat.len > max_dimension) return error.InvalidImage;

    const out_len = signature.len + (12 + 13) + (12 + idat.len) + 12;
    const out = try gpa.alloc(u8, out_len);
    errdefer gpa.free(out);
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(&signature) catch unreachable;
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = @backingInt(color);
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering (all rows use type 0)
    ihdr[12] = 0; // no interlace
    writeChunk(&w, "IHDR", &ihdr);
    writeChunk(&w, "IDAT", idat);
    writeChunk(&w, "IEND", "");
    std.debug.assert(w.end == out.len);
    return out;
}

/// Writes one chunk into a writer sized for it (the caller computed the exact length).
fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) void {
    w.writeInt(u32, @intCast(data.len), .big) catch unreachable;
    w.writeAll(kind) catch unreachable;
    w.writeAll(data) catch unreachable;
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    w.writeInt(u32, crc.final(), .big) catch unreachable;
}

/// Encode and write to `sub_path` (relative to `dir`, or absolute).
pub fn writeFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, pixels: []const u8, width: u32, height: u32, color: ColorType) !void {
    const bytes = try encode(gpa, pixels, width, height, color);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The chunks of a PNG, checking the signature, every length and every CRC.
const Chunk = struct { kind: [4]u8, data: []const u8 };
fn parseChunks(bytes: []const u8, out: []Chunk) !usize {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.BadSignature;
    var pos: usize = 8;
    var n: usize = 0;
    while (pos < bytes.len) {
        if (bytes.len - pos < 12) return error.Truncated;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (bytes.len - pos - 12 < len) return error.Truncated;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        var h = std.hash.Crc32.init();
        h.update(kind);
        h.update(data);
        if (h.final() != crc) return error.BadCrc;
        if (n == out.len) return error.TooManyChunks;
        out[n] = .{ .kind = kind.*, .data = data };
        n += 1;
        pos += 12 + len;
    }
    return n;
}

/// Width and height from a PNG's IHDR (after checking signature and CRCs).
pub fn testDimensions(bytes: []const u8) !struct { width: u32, height: u32, color: u8 } {
    var chunks: [8]Chunk = undefined;
    const n = try parseChunks(bytes, &chunks);
    if (n < 3 or !std.mem.eql(u8, &chunks[0].kind, "IHDR") or chunks[0].data.len != 13) return error.BadHeader;
    return .{
        .width = std.mem.readInt(u32, chunks[0].data[0..4], .big),
        .height = std.mem.readInt(u32, chunks[0].data[4..8], .big),
        .color = chunks[0].data[9],
    };
}

test "png: signature, IHDR, chunk order and CRCs" {
    const gpa = testing.allocator;
    var px: [3 * 4 * 2]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i * 7 % 256);
    const bytes = try encode(gpa, &px, 4, 2, .rgb8);
    defer gpa.free(bytes);
    var chunks: [8]Chunk = undefined;
    const n = try parseChunks(bytes, &chunks);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("IHDR", &chunks[0].kind);
    try testing.expectEqualStrings("IDAT", &chunks[1].kind);
    try testing.expectEqualStrings("IEND", &chunks[2].kind);
    try testing.expectEqual(@as(usize, 0), chunks[2].data.len);
    const d = try testDimensions(bytes);
    try testing.expectEqual(@as(u32, 4), d.width);
    try testing.expectEqual(@as(u32, 2), d.height);
    try testing.expectEqual(@as(u8, 2), d.color);
    try testing.expectEqual(@as(u8, 8), chunks[0].data[8]);
    // The IEND CRC is the well-known constant.
    try testing.expectEqualSlices(u8, &.{ 0xAE, 0x42, 0x60, 0x82 }, bytes[bytes.len - 4 ..]);
}

test "png: the zlib stream inflates to the filtered scanlines" {
    const gpa = testing.allocator;
    const w = 37;
    const h = 11;
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);
    for (px, 0..) |*p, i| p.* = @truncate(i *% 2654435761 >> 7);
    const bytes = try encode(gpa, px, w, h, .rgba8);
    defer gpa.free(bytes);
    var chunks: [8]Chunk = undefined;
    _ = try parseChunks(bytes, &chunks);
    try testing.expectEqual(@as(u8, 6), chunks[0].data[9]);
    var in: std.Io.Reader = .fixed(chunks[1].data);
    var d: flate.Decompress = .init(&in, .zlib, &.{});
    const raw = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    try testing.expectEqual(@as(usize, h * (1 + w * 4)), raw.len);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        try testing.expectEqual(@as(u8, 0), raw[y * (1 + w * 4)]);
        try testing.expectEqualSlices(u8, px[y * w * 4 ..][0 .. w * 4], raw[y * (1 + w * 4) + 1 ..][0 .. w * 4]);
    }
}

test "png: rejects a pixel buffer of the wrong size or an empty image" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidImage, encode(gpa, &.{ 1, 2, 3 }, 2, 1, .rgb8));
    try testing.expectError(error.InvalidImage, encode(gpa, &.{}, 0, 1, .rgb8));
}

test "png: ffmpeg reads it when ffmpeg is installed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var px: [16 * 8 * 3]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i % 251);
    try writeFile(gpa, io, tmp.dir, "t.png", &px, 16, 8, .rgb8);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/t.png", .{tmp.sub_path});
    defer gpa.free(path);
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "ffmpeg", "-v", "error", "-i", path, "-f", "null", "-" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return, // ffmpeg not installed: the encode-free checks above suffice
        else => return err,
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try testing.expect(r.term.success());
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
}
