//! Port of maqam-live `src/analog.rs`: the console-style soft clipper on the output bus.
//! No deliberate behavioral differences from the Rust.
const std = @import("std");

pub fn softClip(sample: f32) f32 {
    // A gentle console-style curve: unity-ish around quiet signals, then
    // progressively bends peaks instead of flattening them at +/-1.
    const driven = sample * 0.85;
    return std.math.tanh(driven + 0.2 * (driven * driven * driven));
}

pub const Stereo = struct { left: f32, right: f32 };

pub fn softClipStereo(left: f32, right: f32) Stereo {
    return .{ .left = softClip(left), .right = softClip(right) };
}

test "soft_clip_preserves_quiet_signal_and_bounds_hot_signal" {
    try std.testing.expect(@abs(softClip(0.1) - 0.085) < 0.002);
    try std.testing.expect(softClip(2.0) > 0.9);
    try std.testing.expect(softClip(2.0) < 1.0);
    try std.testing.expect(softClip(-2.0) < -0.9);
    try std.testing.expect(softClip(-2.0) > -1.0);
}
