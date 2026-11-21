//! maqam-live in Zig: `zig build --release` (what `make` runs; ReleaseFast, the real-time build) builds zig-out/bin/maqam-live, `zig build test` runs every
//! module's tests. Needs only Zig 0.17 and, on Linux, the ALSA development headers (libasound2-dev),
//! or, on macOS, the system's CoreAudio and AudioToolbox frameworks (the Command Line Tools' SDK);
//! nothing outside this directory is read, built or linked (specification proof "Implementations stand alone").
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    linkAudio(b, exe_mod, target, optimize);
    const exe = b.addExecutable(.{ .name = "maqam-live", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run maqam-live").dependOn(&run.step);

    const test_mod = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    linkAudio(b, test_mod, target, optimize);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run every module's tests").dependOn(&run_tests.step);
}

/// The audio device's system libraries: CoreAudio on macOS (declared in src/coreaudio.zig, so no
/// header is translated), ALSA everywhere else (c/alsa.h translated and imported as "alsa").
fn linkAudio(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (target.result.os.tag.isDarwin()) {
        mod.linkFramework("AudioToolbox", .{});
        mod.linkFramework("CoreAudio", .{});
        return;
    }
    const alsa = b.addTranslateC(.{ .root_source_file = b.path("c/alsa.h"), .target = target, .optimize = optimize });
    mod.addImport("alsa", alsa.createModule());
    mod.linkSystemLibrary("asound", .{});
}
