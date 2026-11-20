//! Real-time scheduling for the thread that runs the output callback (proof "No missed audio
//! deadline"). At normal priority the kernel may preempt the audio thread for milliseconds, which
//! is longer than a 64-frame period; the bench measured exactly that. `request` is called once by
//! the audio thread itself, before its loop (never from the callback): it asks for SCHED_FIFO
//! directly and, when that is not permitted (no CAP_SYS_NICE, RLIMIT_RTPRIO 0), asks RealtimeKit
//! over D-Bus with busctl, the way desktop audio clients do. RealtimeKit requires RLIMIT_RTTIME,
//! so a hard CPU-time limit without blocking is set first: a real-time thread that never blocks
//! for 200 ms is killed instead of freezing the machine. The thread blocks every period (the ALSA
//! write, the bench's sleep), so the limit is never reached in normal operation.
//!
//! `lockMemory` (mlockall, current and future mappings) is called once before the audio starts:
//! memory touched for the first time inside the callback costs a page fault each, kernel work in
//! the middle of a deadline (the bench measured 916 faults in the first block after a load, 1 ms).
const std = @import("std");
const linux = std.os.linux;

pub const Granted = enum { fifo, rtkit, none };

/// The priority asked for: RealtimeKit's default maximum is 20, PipeWire's own threads use 20.
pub const priority: u32 = 10;
/// RealtimeKit refuses a process whose RLIMIT_RTTIME hard limit is above its own (200 ms).
pub const rttime_us: u64 = 200_000;

pub fn request(io: std.Io) Granted {
    const param: linux.sched_param = .{ .priority = @intCast(priority) };
    if (linux.errno(linux.sched_setscheduler(0, .{ .mode = .FIFO }, &param)) == .SUCCESS) return .fifo;
    const lim: linux.rlimit = .{ .cur = rttime_us, .max = rttime_us };
    if (linux.errno(linux.setrlimit(.RTTIME, &lim)) != .SUCCESS) return .none;
    var pid_buf: [24]u8 = undefined;
    var tid_buf: [24]u8 = undefined;
    var prio_buf: [8]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{linux.getpid()}) catch return .none;
    const tid = std.fmt.bufPrint(&tid_buf, "{d}", .{linux.gettid()}) catch return .none;
    const prio = std.fmt.bufPrint(&prio_buf, "{d}", .{priority}) catch return .none;
    var child = std.process.spawn(io, .{
        .argv = &.{ "busctl", "call", "--system", "org.freedesktop.RealtimeKit1", "/org/freedesktop/RealtimeKit1", "org.freedesktop.RealtimeKit1", "MakeThreadRealtimeWithPID", "ttu", pid, tid, prio },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .none;
    const term = child.wait(io) catch {
        child.kill(io);
        return .none;
    };
    return if (term.success() and isRealtime()) .rtkit else .none;
}

/// Locks every current and future mapping in RAM, faulting it in now, so the callback never takes
/// a page fault. False when RLIMIT_MEMLOCK does not allow it (then nothing changes).
pub fn lockMemory() bool {
    return linux.errno(linux.mlockall(.{ .CURRENT = true, .FUTURE = true })) == .SUCCESS;
}

/// True when the calling thread runs under a real-time policy (FIFO or RR).
pub fn isRealtime() bool {
    const policy = linux.sched_getscheduler(0);
    if (linux.errno(policy) != .SUCCESS) return false;
    const mode = @as(u32, @truncate(policy)) & 0x7; // without SCHED_RESET_ON_FORK
    return mode == 1 or mode == 2;
}

pub fn name(g: Granted) []const u8 {
    return switch (g) {
        .fifo => "fifo",
        .rtkit => "rtkit",
        .none => "none",
    };
}

test "a thread at normal priority is not real-time, and names are stable" {
    // The test runner's threads are normal priority unless the machine runs tests under chrt.
    _ = isRealtime();
    try std.testing.expectEqualStrings("rtkit", name(.rtkit));
    try std.testing.expectEqualStrings("none", name(.none));
}
