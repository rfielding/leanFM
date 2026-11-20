//! Bounded single-producer single-consumer channels, lock-free. The App sends AudioCmd values to
//! the audio output path on one (512 slots, the specification's bound), and the audio path hands
//! back everything it no longer uses (replaced phrases, models) on another, so it never frees or
//! allocates memory itself (proof "The audio callback never blocks"). Workers answer the App on
//! one-slot channels the App polls every tick.
const std = @import("std");

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        buf: [capacity]T = undefined,
        head: std.atomic.Value(usize) = .init(0), // next slot the consumer reads
        tail: std.atomic.Value(usize) = .init(0), // next slot the producer writes
        closed: std.atomic.Value(bool) = .init(false),

        /// Producer: false when full or closed (nothing changes).
        pub fn trySend(self: *Self, v: T) bool {
            if (self.closed.load(.acquire)) return false;
            const t = self.tail.load(.monotonic);
            if (t - self.head.load(.acquire) == capacity) return false;
            self.buf[t % capacity] = v;
            self.tail.store(t + 1, .release);
            return true;
        }

        /// Producer: waits (yielding the thread) while full, so a burst of edits never drops a
        /// command; false only when the channel was closed. Never called on the audio path.
        pub fn send(self: *Self, v: T) bool {
            while (!self.trySend(v)) {
                if (self.closed.load(.acquire)) return false;
                std.Thread.yield() catch {};
            }
            return true;
        }

        /// Consumer: the next value, or null when empty. Never waits.
        pub fn tryRecv(self: *Self) ?T {
            const h = self.head.load(.monotonic);
            if (h == self.tail.load(.acquire)) return null;
            const v = self.buf[h % capacity];
            self.head.store(h + 1, .release);
            return v;
        }

        /// Consumer, off the audio path only: waits (yielding) for a value; null once the channel
        /// is closed and drained.
        pub fn recv(self: *Self) ?T {
            while (true) {
                if (self.tryRecv()) |v| return v;
                if (self.closed.load(.acquire)) return self.tryRecv();
                std.Thread.yield() catch {};
            }
        }

        pub fn len(self: *Self) usize {
            return self.tail.load(.acquire) - self.head.load(.acquire);
        }

        /// Idempotent; waiters poll the flag, so they wake on their next turn.
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }
    };
}

/// A one-slot mailbox a worker thread fills once and the App polls (crossbeam bounded(1) upstream).
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T = undefined,
        full: std.atomic.Value(bool) = .init(false),

        pub fn put(self: *Self, v: T) bool {
            if (self.full.load(.acquire)) return false;
            self.value = v;
            self.full.store(true, .release);
            return true;
        }

        pub fn take(self: *Self) ?T {
            if (!self.full.load(.acquire)) return null;
            const v = self.value;
            self.full.store(false, .release);
            return v;
        }
    };
}

test "ring keeps order and its bound" {
    var r: Ring(u32, 4) = .{};
    for (0..4) |i| try std.testing.expect(r.trySend(@intCast(i)));
    try std.testing.expect(!r.trySend(9));
    for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), r.tryRecv().?);
    try std.testing.expectEqual(@as(?u32, null), r.tryRecv());
}

test "ring across threads" {
    const R = Ring(u64, 512);
    var r: R = .{};
    const n: u64 = 100_000;
    const t = try std.Thread.spawn(.{}, struct {
        fn run(rr: *R) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) _ = rr.send(i);
        }
    }.run, .{&r});
    var expect: u64 = 0;
    while (expect < n) {
        if (r.tryRecv()) |v| {
            try std.testing.expectEqual(expect, v);
            expect += 1;
        }
    }
    t.join();
}

test "closed ring rejects sends and drains before reporting closed" {
    var r: Ring(u8, 4) = .{};
    try std.testing.expect(r.trySend(1));
    r.close();
    r.close();
    try std.testing.expect(!r.trySend(2));
    try std.testing.expect(!r.send(3));
    try std.testing.expectEqual(@as(?u8, 1), r.recv());
    try std.testing.expectEqual(@as(?u8, null), r.recv());
}

test "mailbox" {
    var m: Mailbox(u8) = .{};
    try std.testing.expect(m.put(1));
    try std.testing.expect(!m.put(2));
    try std.testing.expectEqual(@as(?u8, 1), m.take());
    try std.testing.expectEqual(@as(?u8, null), m.take());
}
