//! Small shared helpers for the Zig port of maqam-live.
const std = @import("std");

/// A spin lock for short critical sections on shared module state (the tuning base, the custom
/// jins registry). It never sleeps, so it is safe where a std.Io.Mutex (which needs an Io) is not
/// available; never hold it across allocation-heavy or blocking work, and never take it in the
/// audio output path except with tryLock.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    pub fn tryLock(self: *SpinLock) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }
    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

test "spin lock" {
    var l: SpinLock = .{};
    l.lock();
    try std.testing.expect(!l.tryLock());
    l.unlock();
    try std.testing.expect(l.tryLock());
    l.unlock();
}
