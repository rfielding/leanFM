//! The macOS audio device: CoreAudio's default output unit, and the default input device through
//! an input-only AUHAL unit for the live input. It is device.Output on macOS (device.Alsa is it on
//! Linux) and offers the same open/start/stop/close, rate, period and latency_us.
//!
//! CoreAudio pulls: it calls `render` on its own real-time I/O thread whenever it needs a block, and
//! that callback calls the engine's process function (the specification's output callback) once.
//! The input unit's callback runs on the input device's I/O thread and hands captured frames to the
//! output callback through `FrameRing`, a single-producer single-consumer ring; neither callback
//! locks, allocates or does I/O (proof "The audio callback never blocks").
//!
//! A skip is counted, never hidden (proof "A buffer skip is never silent"): CoreAudio reports no
//! write error, so the output callback compares the sample time of each block with the end of the
//! block before it; a jump forward means the device played frames the app never handed over.
//!
//! macOS has no mlockall, so `open` writes every buffer the callbacks use and `start` renders one
//! silent block through the engine before the device starts (proof "The audio thread never waits
//! on the kernel"); CoreAudio's I/O threads already run under the Mach time-constraint policy.
//!
//! The few CoreAudio and AudioToolbox declarations needed are written here rather than translated
//! from the SDK headers; the build links the AudioToolbox and CoreAudio frameworks.
const std = @import("std");
const realtime = @import("realtime.zig");
const device = @import("device.zig");

const Frame = device.Frame;
const Process = device.Process;

// ── CoreAudio / AudioToolbox ─────────────────────────────────────────────────

const OSStatus = i32;
const AudioObjectID = u32;
const AudioComponent = *opaque {};
const AudioUnit = *opaque {};

const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
};

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const SMPTETime = extern struct {
    mSubframes: i16,
    mSubframeDivisor: i16,
    mCounter: u32,
    mType: u32,
    mFlags: u32,
    mHours: i16,
    mMinutes: i16,
    mSeconds: i16,
    mFrames: i16,
};

const AudioTimeStamp = extern struct {
    mSampleTime: f64,
    mHostTime: u64,
    mRateScalar: f64,
    mWordClockTime: u64,
    mSMPTETime: SMPTETime,
    mFlags: u32,
    mReserved: u32,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

const AURenderCallback = *const fn (ref: ?*anyopaque, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus;

const AURenderCallbackStruct = extern struct {
    inputProc: AURenderCallback,
    inputProcRefCon: ?*anyopaque,
};

const AudioObjectPropertyAddress = extern struct {
    mSelector: u32,
    mScope: u32,
    mElement: u32 = 0, // kAudioObjectPropertyElementMain
};

extern "c" fn AudioComponentFindNext(after: ?AudioComponent, desc: *const AudioComponentDescription) ?AudioComponent;
extern "c" fn AudioComponentInstanceNew(comp: AudioComponent, out: *?AudioUnit) OSStatus;
extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *const anyopaque, size: u32) OSStatus;
extern "c" fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *anyopaque, size: *u32) OSStatus;
extern "c" fn AudioUnitRender(unit: AudioUnit, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: *AudioBufferList) OSStatus;
extern "c" fn AudioOutputUnitStart(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStop(unit: AudioUnit) OSStatus;
extern "c" fn AudioObjectGetPropertyData(obj: AudioObjectID, addr: *const AudioObjectPropertyAddress, qsize: u32, qdata: ?*const anyopaque, size: *u32, data: *anyopaque) OSStatus;
extern "c" fn AudioObjectSetPropertyData(obj: AudioObjectID, addr: *const AudioObjectPropertyAddress, qsize: u32, qdata: ?*const anyopaque, size: u32, data: *const anyopaque) OSStatus;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const kAudioUnitType_Output = fourcc("auou");
const kAudioUnitSubType_DefaultOutput = fourcc("def ");
const kAudioUnitSubType_HALOutput = fourcc("ahal");
const kAudioUnitManufacturer_Apple = fourcc("appl");
const kAudioFormatLinearPCM = fourcc("lpcm");
const kAudioFormatFlagIsFloat: u32 = 1 << 0;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;

const kAudioUnitScope_Global: u32 = 0;
const kAudioUnitScope_Input: u32 = 1;
const kAudioUnitScope_Output: u32 = 2;
const kAudioUnitProperty_StreamFormat: u32 = 8;
const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
const kAudioUnitProperty_SetRenderCallback: u32 = 23;
const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;
const kAudioOutputUnitProperty_EnableIO: u32 = 2003;
const kAudioOutputUnitProperty_SetInputCallback: u32 = 2005;

const kAudioObjectSystemObject: AudioObjectID = 1;
const kAudioObjectPropertyScopeGlobal = fourcc("glob");
const kAudioObjectPropertyScopeInput = fourcc("inpt");
const kAudioObjectPropertyScopeOutput = fourcc("outp");
const kAudioHardwarePropertyDefaultInputDevice = fourcc("dIn ");
const kAudioHardwarePropertyDefaultOutputDevice = fourcc("dOut");
const kAudioDevicePropertyBufferFrameSize = fourcc("fsiz");
const kAudioDevicePropertyNominalSampleRate = fourcc("nsrt");
const kAudioDevicePropertyLatency = fourcc("ltnc");
const kAudioDevicePropertySafetyOffset = fourcc("saft");
const kAudioTimeStampSampleTimeValid: u32 = 1 << 0;

/// The input element of an AUHAL unit (the input device) and its output element (the output device).
const bus_in: u32 = 1;
const bus_out: u32 = 0;

/// The largest block CoreAudio is allowed to ask for; the engine renders longer blocks in chunks.
pub const max_frames: u32 = 4096;
/// Captured frames waiting for the output callback: about 0.34 s at 48 kHz, as upstream's queue.
pub const ring_frames: usize = 16384;

fn check(status: OSStatus) !void {
    if (status != 0) return error.CoreAudio;
}

fn stereoFloat(rate: f64, channels: u32) AudioStreamBasicDescription {
    return .{
        .mSampleRate = rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 32,
    };
}

fn newUnit(sub_type: u32) !AudioUnit {
    const desc: AudioComponentDescription = .{ .componentType = kAudioUnitType_Output, .componentSubType = sub_type, .componentManufacturer = kAudioUnitManufacturer_Apple };
    const comp = AudioComponentFindNext(null, &desc) orelse return error.NoAudioOutput;
    var unit: ?AudioUnit = null;
    try check(AudioComponentInstanceNew(comp, &unit));
    return unit orelse error.NoAudioOutput;
}

fn setProp(unit: AudioUnit, id: u32, scope: u32, element: u32, value: anytype) !void {
    try check(AudioUnitSetProperty(unit, id, scope, element, value, @sizeOf(@TypeOf(value.*))));
}

fn getObject(comptime T: type, obj: AudioObjectID, selector: u32, scope: u32) ?T {
    var v: T = undefined;
    var size: u32 = @sizeOf(T);
    const addr: AudioObjectPropertyAddress = .{ .mSelector = selector, .mScope = scope };
    if (AudioObjectGetPropertyData(obj, &addr, 0, null, &size, &v) != 0 or size != @sizeOf(T)) return null;
    return v;
}

fn defaultDevice(selector: u32) ?AudioObjectID {
    const id = getObject(AudioObjectID, kAudioObjectSystemObject, selector, kAudioObjectPropertyScopeGlobal) orelse return null;
    return if (id == 0) null else id;
}

// ── the frame ring ───────────────────────────────────────────────────────────

/// Single producer (the input callback), single consumer (the output callback), no locks. A frame
/// that does not fit is dropped (the input runs ahead of an output that stalled); the consumer
/// takes at most what it asks for.
pub const FrameRing = struct {
    buf: []Frame,
    head: std.atomic.Value(usize) = .init(0), // written by the producer
    tail: std.atomic.Value(usize) = .init(0), // written by the consumer

    pub fn push(self: *FrameRing, frames: []const Frame) void {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        const free = self.buf.len - (h - t);
        const n = @min(frames.len, free);
        for (frames[0..n], 0..) |f, i| self.buf[(h + i) % self.buf.len] = f;
        self.head.store(h + n, .release);
    }

    /// Frames waiting.
    pub fn len(self: *FrameRing) usize {
        return self.head.load(.acquire) - self.tail.load(.monotonic);
    }

    /// Drops the oldest frames until at most `limit` wait (consumer side only).
    pub fn dropOldest(self: *FrameRing, limit: usize) void {
        const t = self.tail.load(.monotonic);
        const h = self.head.load(.acquire);
        if (h - t > limit) self.tail.store(h - limit, .release);
    }

    pub fn pop(self: *FrameRing, out: []Frame) usize {
        const t = self.tail.load(.monotonic);
        const h = self.head.load(.acquire);
        const n = @min(out.len, h - t);
        for (out[0..n], 0..) |*f, i| f.* = self.buf[(t + i) % self.buf.len];
        self.tail.store(t + n, .release);
        return n;
    }
};

/// The most captured frames allowed to wait at the start of an output block of `out_frames`, when
/// the input arrives in chunks of `in_frames` (upstream's bound: three output blocks, or one input
/// chunk plus one output block when the input runs in larger chunks), so the input never lags.
pub fn backlogLimit(out_frames: usize, in_frames: usize) usize {
    return @max(out_frames * 3, in_frames + out_frames);
}

/// True when a block whose first frame is at `sample_time` leaves a gap after the block before it,
/// which ended at `expected` (its sample time plus its frames): the device played frames that were
/// never handed over. Half a frame of tolerance absorbs the floating-point sample times.
pub fn isSkip(expected: f64, sample_time: f64) bool {
    return sample_time > expected + 0.5;
}

// ── the device ───────────────────────────────────────────────────────────────

pub const CoreAudio = struct {
    output: ?AudioUnit = null,
    input: ?AudioUnit = null,
    rate: u32 = 48000,
    period: u32 = 256,
    running: bool = false,
    process: Process = undefined,
    ctx: *anyopaque = undefined,
    /// Frames from the ring for the current block (output callback only).
    in_buf: []Frame = &.{},
    /// Interleaved samples the input unit renders into (input callback only).
    in_raw: []f32 = &.{},
    in_channels: u32 = 2,
    /// Frames in the last input callback (input thread writes, output thread reads).
    in_chunk: std.atomic.Value(usize) = .init(0),
    ring: FrameRing = .{ .buf = &.{} },
    /// The silent block `start` renders before the device starts.
    warm: []f32 = &.{},
    /// Where the next block should start on the device's sample clock; NaN before the first.
    expected: f64 = std.math.nan(f64),
    /// Microseconds from a block's hand-over to it being heard: buffer, device latency, safety offset.
    latency_us: std.atomic.Value(u64) = .init(0),
    underruns: ?*std.atomic.Value(u64) = null,
    /// CoreAudio's I/O thread runs under the Mach time-constraint policy (realtime.Granted.mach).
    realtime: realtime.Granted = .mach,
    memory_locked: bool = false,

    /// Opens the default output device (and, when asked, the default input device; a missing input
    /// device, one at another sample rate, or a refused microphone permission only means no live
    /// input). The returned device is not running yet.
    pub fn open(gpa: std.mem.Allocator, cfg: device.Config) !*CoreAudio {
        const self = try gpa.create(CoreAudio);
        errdefer gpa.destroy(self);
        self.* = .{ .rate = cfg.rate, .period = cfg.period_frames, .underruns = cfg.underruns };

        const out = try newUnit(kAudioUnitSubType_DefaultOutput);
        errdefer _ = AudioComponentInstanceDispose(out);
        // Ask the output device for the period; it may choose another size, which the engine
        // handles (it renders any block in chunks of its own maximum).
        const out_dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
        if (out_dev) |dev| {
            const want: u32 = cfg.period_frames;
            const addr: AudioObjectPropertyAddress = .{ .mSelector = kAudioDevicePropertyBufferFrameSize, .mScope = kAudioObjectPropertyScopeGlobal };
            _ = AudioObjectSetPropertyData(dev, &addr, 0, null, @sizeOf(u32), &want);
            if (getObject(u32, dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)) |got| {
                if (got > 0 and got <= max_frames) self.period = got;
            }
        }
        // The engine's format; the output unit converts to the device's rate and channels.
        const fmt = stereoFloat(@floatFromInt(cfg.rate), 2);
        try setProp(out, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus_out, &fmt);
        const mf: u32 = max_frames;
        try setProp(out, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mf);
        const cb: AURenderCallbackStruct = .{ .inputProc = render, .inputProcRefCon = self };
        try setProp(out, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, bus_out, &cb);
        try check(AudioUnitInitialize(out));
        self.output = out;
        if (out_dev) |dev| {
            const lat = getObject(u32, dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) orelse 0;
            const safety = getObject(u32, dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) orelse 0;
            const dev_rate = getObject(f64, dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) orelse @as(f64, @floatFromInt(cfg.rate));
            const frames: f64 = @floatFromInt(@as(u64, self.period) + lat + safety);
            if (dev_rate > 0) self.latency_us.store(@intFromFloat(frames * 1e6 / dev_rate), .monotonic);
        }

        // Every buffer the callbacks touch is allocated and written now, never first touched there.
        self.in_buf = try gpa.alloc(Frame, max_frames);
        @memset(self.in_buf, .{ 0, 0 });
        self.in_raw = try gpa.alloc(f32, max_frames * 2);
        @memset(self.in_raw, 0);
        self.ring.buf = try gpa.alloc(Frame, ring_frames);
        @memset(self.ring.buf, .{ 0, 0 });
        self.warm = try gpa.alloc(f32, self.period * 2);
        @memset(self.warm, 0);

        if (cfg.capture) self.input = openInput(self, cfg.rate) catch null;
        return self;
    }

    /// The input-only AUHAL unit on the default input device, at the engine's rate (AUHAL converts
    /// channels and sample format but not rate, so a device at another rate gives no live input,
    /// as an ALSA capture device at another rate does on Linux).
    fn openInput(self: *CoreAudio, rate: u32) !AudioUnit {
        const dev = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) orelse return error.NoInput;
        const dev_rate = getObject(f64, dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) orelse return error.NoInput;
        if (@abs(dev_rate - @as(f64, @floatFromInt(rate))) > 0.5) return error.InputRate;
        const unit = try newUnit(kAudioUnitSubType_HALOutput);
        errdefer _ = AudioComponentInstanceDispose(unit);
        const on: u32 = 1;
        const off: u32 = 0;
        try setProp(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, bus_in, &on);
        try setProp(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, bus_out, &off);
        try setProp(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev);
        // The device side of the input element says how many channels it delivers; a mono
        // microphone is copied to both sides of the frame.
        var dev_fmt: AudioStreamBasicDescription = undefined;
        var size: u32 = @sizeOf(AudioStreamBasicDescription);
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus_in, &dev_fmt, &size));
        self.in_channels = if (dev_fmt.mChannelsPerFrame >= 2) 2 else 1;
        const fmt = stereoFloat(@floatFromInt(rate), self.in_channels);
        try setProp(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, bus_in, &fmt);
        const mf: u32 = max_frames;
        try setProp(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mf);
        const cb: AURenderCallbackStruct = .{ .inputProc = captured, .inputProcRefCon = self };
        try setProp(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb);
        try check(AudioUnitInitialize(unit));
        return unit;
    }

    /// Renders one silent block through `process` (its first touch of the engine's buffers happens
    /// here, not on the I/O thread), then starts the input and the output.
    pub fn start(self: *CoreAudio, io: std.Io, process: Process, ctx: *anyopaque) !void {
        _ = io;
        self.process = process;
        self.ctx = ctx;
        process(ctx, self.warm, &.{});
        if (self.input) |unit| {
            if (AudioOutputUnitStart(unit) != 0) {
                _ = AudioUnitUninitialize(unit);
                _ = AudioComponentInstanceDispose(unit);
                self.input = null;
            }
        }
        try check(AudioOutputUnitStart(self.output.?));
        self.running = true;
    }

    /// The input callback: render the captured frames into `in_raw` and queue them.
    fn captured(ref: ?*anyopaque, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, _: ?*AudioBufferList) callconv(.c) OSStatus {
        const self: *CoreAudio = @ptrCast(@alignCast(ref.?));
        const unit = self.input orelse return 0;
        const n: u32 = @min(frames, max_frames);
        self.in_chunk.store(n, .monotonic);
        const ch = self.in_channels;
        var abl: AudioBufferList = .{ .mNumberBuffers = 1, .mBuffers = .{.{ .mNumberChannels = ch, .mDataByteSize = n * 4 * ch, .mData = self.in_raw.ptr }} };
        const status = AudioUnitRender(unit, flags, ts, bus, n, &abl);
        if (status != 0) return status;
        // Converted in place to frames: walk backwards for mono so no sample is overwritten first.
        const out: []Frame = @as([*]Frame, @ptrCast(self.in_raw.ptr))[0..n];
        if (ch == 1) {
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                const s = self.in_raw[i];
                out[i] = .{ s, s };
            }
        }
        self.ring.push(out);
        return 0;
    }

    /// The output callback: count a skip, take the captured frames, render the block.
    fn render(ref: ?*anyopaque, _: *u32, ts: *const AudioTimeStamp, _: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
        const self: *CoreAudio = @ptrCast(@alignCast(ref.?));
        const abl = data orelse return 0;
        const buf = abl.mBuffers[0];
        const ptr: [*]f32 = @ptrCast(@alignCast(buf.mData orelse return 0));
        const n: usize = @min(frames, buf.mDataByteSize / 8);
        if (ts.mFlags & kAudioTimeStampSampleTimeValid != 0) {
            // A skip is counted before playing on, never hidden.
            if (!std.math.isNan(self.expected) and isSkip(self.expected, ts.mSampleTime)) {
                if (self.underruns) |u| _ = u.fetchAdd(1, .monotonic);
            }
            self.expected = ts.mSampleTime + @as(f64, @floatFromInt(n));
        }
        var got: usize = 0;
        if (self.input != null) {
            // Keep the live input latency bounded: older frames than the bound are dropped.
            self.ring.dropOldest(backlogLimit(n, self.in_chunk.load(.monotonic)));
            got = self.ring.pop(self.in_buf[0..@min(n, self.in_buf.len)]);
        }
        self.process(self.ctx, ptr[0 .. n * 2], self.in_buf[0..got]);
        return 0;
    }

    /// Whether the default input device feeds the live input.
    pub fn hasInput(self: *const CoreAudio) bool {
        return self.input != null;
    }

    pub fn stop(self: *CoreAudio) void {
        if (!self.running) return;
        if (self.output) |u| _ = AudioOutputUnitStop(u);
        if (self.input) |u| _ = AudioOutputUnitStop(u);
        self.running = false;
    }

    pub fn close(self: *CoreAudio, gpa: std.mem.Allocator) void {
        self.stop();
        inline for (.{ self.input, self.output }) |unit| if (unit) |u| {
            _ = AudioUnitUninitialize(u);
            _ = AudioComponentInstanceDispose(u);
        };
        gpa.free(self.in_buf);
        gpa.free(self.in_raw);
        gpa.free(self.ring.buf);
        gpa.free(self.warm);
        gpa.destroy(self);
    }
};

test "a skip is a forward jump of the sample clock past the last block's end" {
    try std.testing.expect(!isSkip(512, 512));
    try std.testing.expect(!isSkip(512, 512.4));
    try std.testing.expect(isSkip(512, 768));
    // a clock that runs back (a device restart) is not a skip of frames handed over
    try std.testing.expect(!isSkip(512, 0));
}

test "the frame ring keeps order, drops what does not fit and hands over at most what is asked" {
    var storage: [4]Frame = undefined;
    var r: FrameRing = .{ .buf = &storage };
    r.push(&.{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } });
    var out: [2]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 2), r.pop(&out));
    try std.testing.expectEqual(@as(f32, 1), out[0][0]);
    try std.testing.expectEqual(@as(f32, 2), out[1][0]);
    r.push(&.{ .{ 4, 4 }, .{ 5, 5 }, .{ 6, 6 }, .{ 7, 7 } }); // one is left, room for three
    var all: [8]Frame = undefined;
    const n = r.pop(&all);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(f32, 3), all[0][0]);
    try std.testing.expectEqual(@as(f32, 6), all[3][0]);
    try std.testing.expectEqual(@as(usize, 0), r.pop(&all));
}

test "the live input backlog is bounded and the newest frames are kept" {
    try std.testing.expectEqual(@as(usize, 768), backlogLimit(256, 256));
    try std.testing.expectEqual(@as(usize, 1088), backlogLimit(64, 1024));
    var storage: [16]Frame = undefined;
    var r: FrameRing = .{ .buf = &storage };
    var frames: [10]Frame = undefined;
    for (&frames, 0..) |*f, i| f.* = .{ @floatFromInt(i), 0 };
    r.push(&frames);
    r.dropOldest(4);
    try std.testing.expectEqual(@as(usize, 4), r.len());
    var out: [4]Frame = undefined;
    _ = r.pop(&out);
    try std.testing.expectEqual(@as(f32, 6), out[0][0]);
    r.dropOldest(4); // nothing to drop
    try std.testing.expectEqual(@as(usize, 0), r.len());
}

test "four-character codes match the SDK's values" {
    try std.testing.expectEqual(@as(u32, 0x61756f75), kAudioUnitType_Output);
    try std.testing.expectEqual(@as(u32, 0x6c70636d), kAudioFormatLinearPCM);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(AudioStreamBasicDescription));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(AudioTimeStamp));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(AudioBufferList));
}
