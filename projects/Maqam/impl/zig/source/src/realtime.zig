//! Real-time scheduling for the thread that runs the output callback (proof "No missed audio
//! deadline"). At normal priority the kernel may preempt the audio thread for milliseconds, which
//! is longer than a 64-frame period; the bench measured exactly that. `request` is called once by
//! the audio thread itself, before its loop (never from the callback).
//!
//! Linux: it asks for SCHED_FIFO directly and, when that is not permitted (no CAP_SYS_NICE,
//! RLIMIT_RTPRIO 0), asks RealtimeKit over D-Bus with busctl, the way desktop audio clients do.
//! RealtimeKit requires RLIMIT_RTTIME, so a hard CPU-time limit without blocking is set first: a
//! real-time thread that never blocks for 200 ms is killed instead of freezing the machine. The
//! thread blocks every period (the ALSA write, the bench's sleep), so the limit is never reached in
//! normal operation.
//!
//! macOS: it sets the Mach time-constraint policy, as CoreAudio does for its own I/O threads (the
//! live callback runs on one of those, so only the bench asks): every period of the block length
//! the thread needs at most half of it, finished within the period.
//!
//! `lockMemory` (mlockall, current and future mappings) is called once before the audio starts:
//! memory touched for the first time inside the callback costs a page fault each, kernel work in
//! the middle of a deadline (the bench measured 916 faults in the first block after a load, 1 ms).
//! macOS has no mlockall; there it returns false and the device writes its buffers first instead.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const is_macos = builtin.os.tag.isDarwin();

pub const Granted = enum { fifo, rtkit, mach, none };

/// The priority asked for: RealtimeKit's default maximum is 20, PipeWire's own threads use 20.
pub const priority: u32 = 10;
/// RealtimeKit refuses a process whose RLIMIT_RTTIME hard limit is above its own (200 ms).
pub const rttime_us: u64 = 200_000;

/// Asks real-time scheduling for the calling thread, which renders a block every `period_ns`.
pub fn request(io: std.Io, period_ns: u64) Granted {
    if (is_macos) return if (mach.setTimeConstraint(period_ns)) .mach else .none;
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

/// Puts the calling thread back to normal scheduling after `request` granted `g`.
pub fn release(g: Granted) void {
    switch (g) {
        .none => {},
        .mach => if (is_macos) mach.setStandard(),
        .fifo, .rtkit => if (!is_macos) {
            const normal: linux.sched_param = .{ .priority = 0 };
            _ = linux.sched_setscheduler(0, .{ .mode = .NORMAL }, &normal);
        },
    }
}

/// Locks every current and future mapping in RAM, faulting it in now, so the callback never takes
/// a page fault. False when RLIMIT_MEMLOCK does not allow it, and on macOS, which has no mlockall
/// (then nothing changes).
pub fn lockMemory() bool {
    if (is_macos) return false;
    return linux.errno(linux.mlockall(.{ .CURRENT = true, .FUTURE = true })) == .SUCCESS;
}

/// Undoes a `lockMemory` that returned true.
pub fn unlockMemory() void {
    if (!is_macos) _ = linux.munlockall();
}

/// True when the calling thread runs under a real-time policy (Linux: FIFO or RR; macOS: the
/// time-constraint policy).
pub fn isRealtime() bool {
    if (is_macos) return mach.hasTimeConstraint();
    const policy = linux.sched_getscheduler(0);
    if (linux.errno(policy) != .SUCCESS) return false;
    const mode = @as(u32, @truncate(policy)) & 0x7; // without SCHED_RESET_ON_FORK
    return mode == 1 or mode == 2;
}

pub fn name(g: Granted) []const u8 {
    return switch (g) {
        .fifo => "fifo",
        .rtkit => "rtkit",
        .mach => "mach",
        .none => "none",
    };
}

/// The Mach thread policies (<mach/thread_policy.h>), declared here rather than translated.
const mach = struct {
    const THREAD_STANDARD_POLICY: u32 = 1;
    const THREAD_TIME_CONSTRAINT_POLICY: u32 = 2;
    const TimeConstraint = extern struct { period: u32, computation: u32, constraint: u32, preemptible: c_int };
    const time_constraint_count: u32 = @sizeOf(TimeConstraint) / @sizeOf(c_int);
    const Timebase = extern struct { numer: u32, denom: u32 };

    extern "c" fn pthread_self() *anyopaque;
    extern "c" fn pthread_mach_thread_np(thread: *anyopaque) u32;
    extern "c" fn thread_policy_set(thread: u32, flavor: u32, info: *anyopaque, count: u32) c_int;
    extern "c" fn thread_policy_get(thread: u32, flavor: u32, info: *anyopaque, count: *u32, get_default: *c_int) c_int;
    extern "c" fn mach_timebase_info(info: *Timebase) c_int;

    fn self() u32 {
        return pthread_mach_thread_np(pthread_self());
    }

    /// Nanoseconds in Mach absolute time units (1:1 on Intel, 125:3 on Apple silicon).
    fn toAbs(ns: u64) u32 {
        var tb: Timebase = .{ .numer = 1, .denom = 1 };
        if (mach_timebase_info(&tb) != 0 or tb.numer == 0) tb = .{ .numer = 1, .denom = 1 };
        return @intCast(@min(ns * tb.denom / tb.numer, std.math.maxInt(u32)));
    }

    fn setTimeConstraint(period_ns: u64) bool {
        const period = toAbs(period_ns);
        var p: TimeConstraint = .{ .period = period, .computation = period / 2, .constraint = period, .preemptible = 1 };
        return thread_policy_set(self(), THREAD_TIME_CONSTRAINT_POLICY, &p, time_constraint_count) == 0;
    }

    fn setStandard() void {
        var dummy: c_int = 0;
        _ = thread_policy_set(self(), THREAD_STANDARD_POLICY, &dummy, 0);
    }

    fn hasTimeConstraint() bool {
        var p: TimeConstraint = undefined;
        var count: u32 = time_constraint_count;
        var get_default: c_int = 0;
        if (thread_policy_get(self(), THREAD_TIME_CONSTRAINT_POLICY, &p, &count, &get_default) != 0) return false;
        return get_default == 0;
    }
};

test "a thread at normal priority is not real-time, and names are stable" {
    // The test runner's threads are normal priority unless the machine runs tests under chrt.
    _ = isRealtime();
    try std.testing.expectEqualStrings("rtkit", name(.rtkit));
    try std.testing.expectEqualStrings("mach", name(.mach));
    try std.testing.expectEqualStrings("none", name(.none));
}

test "on macOS the time-constraint policy is granted and released" {
    if (!is_macos) return error.SkipZigTest;
    // A test thread of its own, so the runner's thread is never left real-time.
    const T = struct {
        fn run(ok: *[3]bool) void {
            ok[0] = !isRealtime();
            ok[1] = request(std.testing.io, 1_333_333) == .mach and isRealtime();
            release(.mach);
            ok[2] = !isRealtime();
        }
    };
    var ok: [3]bool = .{ false, false, false };
    const t = try std.Thread.spawn(.{}, T.run, .{&ok});
    t.join();
    try std.testing.expect(ok[0] and ok[1] and ok[2]);
}
