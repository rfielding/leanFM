//! maqam-live in Zig: `zig build --release` (what `make` runs; ReleaseFast, the real-time build) builds zig-out/bin/maqam-live, `zig build test` runs every
//! module's tests. Needs only Zig 0.17 and the ALSA development headers (libasound2-dev); nothing
//! outside this directory is read, built or linked (specification proof "Implementations stand alone").
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const alsa = b.addTranslateC(.{ .root_source_file = b.path("c/alsa.h"), .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    exe_mod.addImport("alsa", alsa.createModule());
    exe_mod.linkSystemLibrary("asound", .{});
    const exe = b.addExecutable(.{ .name = "maqam-live", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run maqam-live").dependOn(&run.step);

    const test_mod = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    test_mod.addImport("alsa", alsa.createModule());
    test_mod.linkSystemLibrary("asound", .{});
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run every module's tests").dependOn(&run_tests.step);
}
