//! State the audio output path publishes and the App and UI read, without locks: the Zig form of
//! the statics in upstream main.rs (CUR_PHRASE, NEXT_PHRASE, EXIT_PHRASE, CUR_SUBDIV, CUR_PLAYS,
//! CUR_JUMP_VALUE, AUDIO_LATENCY_*_US, INPUT_*_LEVEL, NAM_OUTPUT_LEVEL, NAM_MODEL_ACTIVE,
//! NAM_STATUS, REC_*) and of JUMP_COUNTERS, which upstream guards with a Mutex<HashMap>; here it
//! is a fixed table of atomics (entry id -> completed jump-backs), so the audio path never locks.
//! Message Position of the specification is this state. Levels are f32 bit patterns.
const std = @import("std");

pub const none: usize = std.math.maxInt(usize);
/// Entry ids at or above this are not shown with jump counters (the timeline itself is bounded
/// by the App at the same number of entries; specification markdown "bounds").
pub const max_entries: usize = 4096;

pub const Shared = struct {
    cur_phrase: std.atomic.Value(usize) = .init(0),
    next_phrase: std.atomic.Value(usize) = .init(none),
    exit_phrase: std.atomic.Value(usize) = .init(none),
    cur_subdiv: std.atomic.Value(usize) = .init(0),
    cur_plays: std.atomic.Value(usize) = .init(0),
    cur_jump_value: std.atomic.Value(usize) = .init(0),
    /// Times the sequencer wrapped from the last row to the first (the offline render counts cycles by it).
    cycles: std.atomic.Value(u64) = .init(0),
    /// Phrase starts so far (PhraseStart), for the event log's Position events.
    phrase_starts: std.atomic.Value(u64) = .init(0),
    latency_left_us: std.atomic.Value(u64) = .init(0),
    latency_right_us: std.atomic.Value(u64) = .init(0),
    input_left_level: std.atomic.Value(u32) = .init(0),
    input_right_level: std.atomic.Value(u32) = .init(0),
    nam_output_level: std.atomic.Value(u32) = .init(0),
    nam_model_active: std.atomic.Value(bool) = .init(false),
    /// 0 none, 1 active, 2 login required/in progress, 3 downloading, 4 error, 5 bypassed.
    nam_status: std.atomic.Value(usize) = .init(0),
    rec_samples_done: std.atomic.Value(usize) = .init(0),
    rec_samples_total: std.atomic.Value(usize) = .init(0),
    rec_active: std.atomic.Value(bool) = .init(false),
    /// Playback underruns (buffer skips) the output device reported; the header shows them.
    underruns: std.atomic.Value(u64) = .init(0),
    jump_counters: [max_entries]std.atomic.Value(u32) = @splat(.init(0)),

    pub fn setJumpCounter(self: *Shared, id: usize, v: usize) void {
        if (id < max_entries) self.jump_counters[id].store(@intCast(@min(v, std.math.maxInt(u32))), .monotonic);
    }

    pub fn jumpCounter(self: *const Shared, id: usize) usize {
        return if (id < max_entries) self.jump_counters[id].load(.monotonic) else 0;
    }

    pub fn clearJumpCounters(self: *Shared) void {
        for (&self.jump_counters) |*c| c.store(0, .monotonic);
    }

    pub fn storeLevel(slot: *std.atomic.Value(u32), v: f32) void {
        slot.store(@bitCast(v), .monotonic);
    }

    pub fn loadLevel(slot: *const std.atomic.Value(u32)) f32 {
        return @bitCast(slot.load(.monotonic));
    }
};

test "jump counters are bounded and lock-free" {
    var s: Shared = .{};
    s.setJumpCounter(3, 2);
    s.setJumpCounter(max_entries + 1, 9);
    try std.testing.expectEqual(@as(usize, 2), s.jumpCounter(3));
    try std.testing.expectEqual(@as(usize, 0), s.jumpCounter(max_entries + 1));
    Shared.storeLevel(&s.input_left_level, 0.5);
    try std.testing.expectEqual(@as(f32, 0.5), Shared.loadLevel(&s.input_left_level));
}
