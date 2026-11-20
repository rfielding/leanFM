//! WAV files: 32-bit float mono for the offline render hook (spec markdown "comparison"), and
//! 16-bit PCM for the recorder's input to ffmpeg.
const std = @import("std");

/// The bytes of a WAV file holding `samples` (mono) as IEEE float 32 (format 3) or PCM 16 (format 1).
pub fn encode(gpa: std.mem.Allocator, samples: []const f32, rate: u32, float32: bool) ![]u8 {
    const bytes_per = @as(u32, if (float32) 4 else 2);
    const data_len: u32 = @intCast(samples.len * bytes_per);
    const header_len: u32 = if (float32) 58 else 44;
    const out = try gpa.alloc(u8, header_len + data_len);
    var w: std.Io.Writer = .fixed(out);
    try w.writeAll("RIFF");
    try w.writeInt(u32, header_len - 8 + data_len, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, if (float32) 18 else 16, .little);
    try w.writeInt(u16, if (float32) 3 else 1, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, rate, .little);
    try w.writeInt(u32, rate * bytes_per, .little);
    try w.writeInt(u16, @intCast(bytes_per), .little);
    try w.writeInt(u16, @intCast(bytes_per * 8), .little);
    if (float32) {
        try w.writeInt(u16, 0, .little); // cbSize
        try w.writeAll("fact");
        try w.writeInt(u32, 4, .little);
        try w.writeInt(u32, @intCast(samples.len), .little);
    }
    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
    for (samples) |s| {
        if (float32) {
            try w.writeInt(u32, @bitCast(s), .little);
        } else {
            const c = std.math.clamp(s, -1.0, 1.0);
            try w.writeInt(i16, @intFromFloat(@round(c * 32767.0)), .little);
        }
    }
    return out;
}

test "float wav header and samples" {
    const gpa = std.testing.allocator;
    const bytes = try encode(gpa, &.{ 0.5, -1.0 }, 48000, true);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("RIFF", bytes[0..4]);
    try std.testing.expectEqual(@as(usize, 58 + 8), bytes.len);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, bytes[20..22], .little));
    try std.testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, bytes[24..28], .little));
    try std.testing.expectEqual(@as(f32, 0.5), @as(f32, @bitCast(std.mem.readInt(u32, bytes[58..62], .little))));
}

test "pcm wav clamps" {
    const gpa = std.testing.allocator;
    const bytes = try encode(gpa, &.{ 2.0, -2.0 }, 44100, false);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, bytes[44..46], .little));
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, bytes[46..48], .little));
}

test "every declaration compiles" {
    std.testing.refAllDecls(@This());
}
