//! Neural Amp Modeler (NAM) inference: a port of the Rust crate `nam-rs` 0.4.0
//! (OpenSauce/nam-rs, MIT; itself a port of NeuralAmpModelerCore / NeuralAudio).
//!
//! It parses the `.nam` JSON format (version, architecture, config, flat weights,
//! sample_rate, metadata) and runs the forward pass of the three architectures nam-rs
//! supports: WaveNet (A1 and the A2 feature set: gating/blending, bottleneck, grouped
//! convolutions, head1x1, the eight FiLM sites, multi-tap layer heads, the post-stack
//! head and a nested `condition_dsp`), LSTM, and SlimmableContainer.
//!
//! Real-time contract: everything is allocated when a model is built (`Model.fromNam`,
//! `Model.loadBytes`, `Model.loadFile`). `Model.processBuffer`, `Model.processSample`
//! and `Model.reset` never allocate, lock, block or make a system call. Blocks longer
//! than `MAX_BLOCK` (the nam-rs bound, 1024 frames) are processed in chunks.
//!
//! Differences from nam-rs, all on the rejection side: inputs that would make nam-rs
//! panic (an LSTM with `input_size != 1`, a layer-array reading more input rows or
//! conditioning rows than exist, a post-stack head kernel of 0) are rejected with an
//! error, and absurd sizes (JSON larger than `max_json_bytes`, dimensions above the
//! `max_*` bounds, a runtime footprint above `max_runtime_floats`) are rejected with
//! `error.ConfigTooLarge` before anything is allocated for them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Largest block the planar kernel processes in one call (nam-rs `MAX_BLOCK`).
/// Longer buffers are processed in chunks of this size.
pub const MAX_BLOCK: usize = 1024;

/// Sample rate assumed when a `.nam` file omits `sample_rate` (NAM's documented default).
pub const DEFAULT_SAMPLE_RATE: f64 = 48_000.0;

/// Largest `.nam` file accepted, in bytes.
pub const max_json_bytes: usize = 64 << 20;
/// Largest flat weight blob accepted, in floats.
pub const max_weights: usize = 8 << 20;
/// Largest channel-like dimension (channels, bottleneck, head sizes, hidden size, ...).
pub const max_dim: usize = 4096;
/// Largest convolution kernel.
pub const max_kernel: usize = 4096;
/// Largest dilation.
pub const max_dilation: usize = 1 << 16;
/// Largest number of layers in one layer-array, of layer-arrays, of LSTM layers,
/// of post-stack head convolutions, and of slimmable submodels.
pub const max_layers: usize = 1024;
/// Deepest nesting of `condition_dsp` / slimmable submodels.
pub const max_nesting: usize = 4;
/// Largest runtime footprint (weights + state + scratch) of a built model, in floats.
pub const max_runtime_floats: usize = 64 << 20;

/// Errors produced when loading or building a NAM model (nam-rs `Error`), plus
/// allocation and file errors. `Diagnostic` carries the human-readable message.
pub const Error = error{
    /// The `.nam` JSON could not be parsed or is not a valid `.nam` shape.
    Json,
    /// The file could not be read.
    Io,
    /// The `architecture` field names an architecture this port cannot run.
    UnsupportedArchitecture,
    /// A layer's activation names a function this port does not implement.
    UnsupportedActivation,
    /// The config uses a feature that is not implemented (or would crash nam-rs).
    UnsupportedFeature,
    /// The flat `weights` array disagrees with the count the config implies.
    WeightCountMismatch,
    /// The config's dimensions are absurd (overflow, or above the `max_*` bounds).
    ConfigTooLarge,
    OutOfMemory,
};

/// The human-readable reason for the last load error, formatted like the nam-rs
/// `Display` text (`"weight count mismatch: config implies 8 weights, file has 7"`).
/// Pass `null` where the message is not needed.
pub const Diagnostic = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(diag: ?*Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const d = diag orelse return;
        if (std.fmt.bufPrint(&d.buf, fmt, args)) |s| {
            d.len = s.len;
        } else |_| {
            d.len = d.buf.len;
        }
    }
};

fn fail(diag: ?*Diagnostic, err: Error, comptime fmt: []const u8, args: anytype) Error {
    switch (err) {
        error.Json => Diagnostic.set(diag, "failed to parse .nam JSON: " ++ fmt, args),
        error.Io => Diagnostic.set(diag, "failed to read .nam file: " ++ fmt, args),
        error.UnsupportedArchitecture => Diagnostic.set(diag, "unsupported model architecture: " ++ fmt, args),
        error.UnsupportedActivation => Diagnostic.set(diag, "unsupported activation function: " ++ fmt, args),
        error.UnsupportedFeature => Diagnostic.set(diag, "unsupported model feature: " ++ fmt, args),
        error.WeightCountMismatch => Diagnostic.set(diag, "weight count mismatch: " ++ fmt, args),
        error.ConfigTooLarge => Diagnostic.set(diag, "model config dimensions are too large to be valid" ++ fmt, args),
        error.OutOfMemory => Diagnostic.set(diag, "out of memory" ++ fmt, args),
    }
    return err;
}

fn tooLarge(diag: ?*Diagnostic) Error {
    return fail(diag, error.ConfigTooLarge, "", .{});
}

// ─────────────────────────────── file representation ───────────────────────────────

/// How a layer-array's `activation` was written: a name with an optional LeakyReLU
/// slope, or a shape this port does not model (rejected when the model is built).
pub const ActivationSpec = union(enum) {
    named: struct { name: []const u8, negative_slope: ?f32 },
    unsupported,

    fn fromValue(v: Value) ActivationSpec {
        switch (v) {
            .string => |s| return .{ .named = .{ .name = s, .negative_slope = null } },
            .object => |o| {
                const t = o.get("type") orelse return .unsupported;
                if (t != .string) return .unsupported;
                const slope = o.get("negative_slope") orelse
                    return .{ .named = .{ .name = t.string, .negative_slope = null } };
                return switch (slope) {
                    .null => .{ .named = .{ .name = t.string, .negative_slope = null } },
                    .integer, .float => .{ .named = .{ .name = t.string, .negative_slope = @floatCast(numberF64(slope).?) } },
                    else => .unsupported,
                };
            },
            else => return .unsupported,
        }
    }

    const sigmoid: ActivationSpec = .{ .named = .{ .name = "Sigmoid", .negative_slope = null } };
};

/// Activation gating mode for a WaveNet layer (NAMCore `GatingMode`).
pub const GatingMode = enum {
    none,
    gated,
    blended,

    pub fn fromName(s: []const u8) ?GatingMode {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "gated")) return .gated;
        if (std.mem.eql(u8, s, "blended")) return .blended;
        return null;
    }
};

/// A layer's residual 1×1. Active by default (the A1 `_1x1`).
pub const Layer1x1Config = struct {
    active: bool = true,
    groups: usize = 1,

    fn fromValue(v: ?Value) Layer1x1Config {
        const o = v orelse return .{};
        return .{
            .active = lenientBool(o, "active") orelse true,
            .groups = lenientUsize(o, "groups") orelse 1,
        };
    }
};

/// A layer's head 1×1. Inactive by default.
pub const Head1x1Config = struct {
    active: bool = false,
    out_channels: ?usize = null,
    groups: usize = 1,

    fn fromValue(v: ?Value) Head1x1Config {
        const o = v orelse return .{};
        return .{
            .active = lenientBool(o, "active") orelse false,
            .out_channels = lenientUsize(o, "out_channels"),
            .groups = lenientUsize(o, "groups") orelse 1,
        };
    }
};

/// One FiLM site. Absent, `null` or `false` means inactive.
pub const FilmConfig = struct {
    active: bool,
    shift: bool,
    groups: usize,

    pub const INACTIVE: FilmConfig = .{ .active = false, .shift = false, .groups = 1 };

    fn fromValue(v: ?Value) FilmConfig {
        const o = v orelse return INACTIVE;
        if (o == .bool and !o.bool) return INACTIVE;
        return .{
            .active = lenientBool(o, "active") orelse true,
            .shift = lenientBool(o, "shift") orelse true,
            .groups = lenientUsize(o, "groups") orelse 1,
        };
    }
};

/// Post-stack head (`config.head`): a chain of `activation → Conv1d`.
pub const PostStackHeadConfig = struct {
    channels: usize,
    out_channels: usize,
    kernel_sizes: []const usize,
    activation: ActivationSpec,
};

/// One WaveNet layer-array, normalized so every per-layer field has one entry per layer.
pub const LayerArrayConfig = struct {
    input_size: usize,
    condition_size: usize,
    channels: usize,
    bottleneck: usize,
    dilations: []const usize,
    kernel_sizes: []const usize,
    activations: []const ActivationSpec,
    gating_modes: []const GatingMode,
    secondary_activations: []const ActivationSpec,
    groups_input: usize,
    groups_input_mixin: usize,
    head_size: usize,
    head_kernel_size: usize,
    head_bias: bool,
    layer1x1: Layer1x1Config,
    head1x1: Head1x1Config,
    /// The eight FiLM sites in NAMCore order: conv_pre, conv_post, input_mixin_pre,
    /// input_mixin_post, activation_pre, activation_post, layer1x1_post, head1x1_post.
    films: [8]FilmConfig,

    /// The array's uniform gating mode (`none` for an empty list).
    pub fn gatingMode(self: *const LayerArrayConfig) GatingMode {
        return if (self.gating_modes.len > 0) self.gating_modes[0] else .none;
    }
};

/// WaveNet configuration.
pub const WaveNetConfig = struct {
    layers: []const LayerArrayConfig,
    post_stack_head: ?PostStackHeadConfig,
    head_scale: f32,
    in_channels: usize,
    condition_dsp: ?*const NamModel,
};

/// LSTM configuration.
pub const LstmConfig = struct {
    input_size: usize,
    hidden_size: usize,
    num_layers: usize,
};

/// One SlimmableContainer entry: a standalone submodel and its width-dial threshold.
pub const SlimmableSubmodel = struct {
    max_value: f32,
    model: NamModel,
};

/// SlimmableContainer configuration.
pub const SlimmableConfig = struct {
    submodels: []const SlimmableSubmodel,
};

/// Architecture-specific configuration, tagged by `NamModel.architecture`.
pub const ModelConfig = union(enum) {
    wave_net: WaveNetConfig,
    lstm: LstmConfig,
    slimmable: SlimmableConfig,
};

/// Calendar timestamp from `metadata.date`.
pub const Date = struct {
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
};

/// The descriptive `metadata` block, parsed leniently: a malformed field is `null`
/// and costs only itself. None of it reaches the forward pass.
pub const Metadata = struct {
    loudness: ?f32 = null,
    input_level_dbu: ?f32 = null,
    output_level_dbu: ?f32 = null,
    gain: ?f32 = null,
    name: ?[]const u8 = null,
    modeled_by: ?[]const u8 = null,
    gear_make: ?[]const u8 = null,
    gear_model: ?[]const u8 = null,
    gear_type: ?[]const u8 = null,
    tone_type: ?[]const u8 = null,
    trainer: ?[]const u8 = null,
    date: ?Date = null,
    training: ?Value = null,

    fn fromValue(v: Value) Metadata {
        if (v != .object) return .{};
        const o = v.object;
        var m: Metadata = .{};
        m.loudness = lenientF32(o.get("loudness"));
        m.input_level_dbu = lenientF32(o.get("input_level_dbu"));
        m.output_level_dbu = lenientF32(o.get("output_level_dbu"));
        m.gain = lenientF32(o.get("gain"));
        m.name = lenientString(o.get("name"));
        m.modeled_by = lenientString(o.get("modeled_by"));
        m.gear_make = lenientString(o.get("gear_make"));
        m.gear_model = lenientString(o.get("gear_model"));
        m.gear_type = lenientString(o.get("gear_type"));
        m.tone_type = lenientString(o.get("tone_type"));
        m.trainer = lenientString(o.get("trainer"));
        m.date = lenientDate(o.get("date"));
        if (o.get("training")) |t| {
            if (t != .null) m.training = t;
        }
        return m;
    }

    /// Whether the capture includes a speaker cabinet, as far as `gear_type` says
    /// (nam-rs `Metadata::includes_cab`): `false` for amp/preamp/pedal/pedal_amp/
    /// outboard/space, `true` for full_rig/ir or any `_`-separated `cab` token, `null`
    /// otherwise. Ignores case, surrounding whitespace, and `-` vs `_`.
    pub fn includesCab(self: *const Metadata) ?bool {
        const raw = self.gear_type orelse return null;
        const s = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const no_cab = [_][]const u8{ "amp", "preamp", "pedal", "pedal_amp", "outboard", "space" };
        for (no_cab) |c| if (eqlNormalized(s, c)) return false;
        if (eqlNormalized(s, "full_rig") or eqlNormalized(s, "ir")) return true;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (i == s.len or s[i] == '_' or s[i] == '-') {
                if (eqlNormalized(s[start..i], "cab")) return true;
                start = i + 1;
            }
        }
        return null;
    }
};

fn eqlNormalized(s: []const u8, lower: []const u8) bool {
    if (s.len != lower.len) return false;
    for (s, lower) |a, b| {
        const c = if (a == '-') '_' else std.ascii.toLower(a);
        if (c != b) return false;
    }
    return true;
}

/// A parsed `.nam` file: the raw config and flat weight blob (nam-rs `NamModel`).
/// Slices point into the allocator the model was parsed with (see `Parsed`).
pub const NamModel = struct {
    version: []const u8,
    architecture: []const u8,
    config: ModelConfig,
    /// Flat weight blob in NAM `export_weights` order; for WaveNet the last is `head_scale`.
    weights: []const f32,
    sample_rate: ?f64,
    /// The raw `metadata` block, if present (see `metadataTyped`).
    metadata: ?Value,

    /// A parsed model together with the arena that owns it.
    pub const Parsed = struct {
        arena: *std.heap.ArenaAllocator,
        value: NamModel,

        pub fn deinit(self: Parsed) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };

    /// Parse a `.nam` JSON document (nam-rs `NamModel::from_json_str`).
    pub fn fromJsonStr(gpa: Allocator, json: []const u8, diag: ?*Diagnostic) Error!Parsed {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        const value = try parseLeaky(arena.allocator(), json, diag);
        return .{ .arena = arena, .value = value };
    }

    /// Read and parse a `.nam` file (nam-rs `NamModel::from_file`).
    pub fn fromFile(gpa: Allocator, io: std.Io, path: []const u8, diag: ?*Diagnostic) Error!Parsed {
        const bytes = try readFile(gpa, io, path, diag);
        defer gpa.free(bytes);
        return fromJsonStr(gpa, bytes, diag);
    }

    /// Parse into `arena`, which must outlive the result and is expected to be an arena
    /// (nothing is freed individually).
    pub fn parseLeaky(arena: Allocator, json: []const u8, diag: ?*Diagnostic) Error!NamModel {
        if (json.len > max_json_bytes) return tooLarge(diag);
        const root = std.json.parseFromSliceLeaky(Value, arena, json, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(diag, error.Json, "{s}", .{@errorName(e)}),
        };
        var p: Parser = .{ .a = arena, .diag = diag };
        return p.model(root, 0);
    }

    /// The sample rate, in Hz, the model expects; `DEFAULT_SAMPLE_RATE` when absent.
    /// The model does not resample: feed it audio at this rate.
    pub fn expectedSampleRate(self: *const NamModel) f64 {
        return self.sample_rate orelse DEFAULT_SAMPLE_RATE;
    }

    /// The typed `metadata` block (all fields `null` when there is none).
    pub fn metadataTyped(self: *const NamModel) Metadata {
        const m = self.metadata orelse return .{};
        return Metadata.fromValue(m);
    }

    pub fn loudness(self: *const NamModel) ?f32 {
        return self.metadataTyped().loudness;
    }

    pub fn inputLevelDbu(self: *const NamModel) ?f32 {
        return self.metadataTyped().input_level_dbu;
    }

    pub fn outputLevelDbu(self: *const NamModel) ?f32 {
        return self.metadataTyped().output_level_dbu;
    }

    pub fn includesCab(self: *const NamModel) ?bool {
        return self.metadataTyped().includesCab();
    }
};

fn readFile(gpa: Allocator, io: std.Io, path: []const u8, diag: ?*Diagnostic) Error![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_json_bytes + 1)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => tooLarge(diag),
        else => fail(diag, error.Io, "{s}: {s}", .{ path, @errorName(e) }),
    };
}

// ─────────────────────────────── JSON helpers ───────────────────────────────

fn numberF64(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn lenientBool(o: Value, key: []const u8) ?bool {
    if (o != .object) return null;
    const v = o.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn lenientUsize(o: Value, key: []const u8) ?usize {
    if (o != .object) return null;
    const v = o.object.get(key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}

fn lenientF32(v: ?Value) ?f32 {
    const x = numberF64(v orelse return null) orelse return null;
    return @floatCast(x);
}

fn lenientString(v: ?Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

fn lenientDate(v: ?Value) ?Date {
    const d = v orelse return null;
    if (d != .object) return null;
    const o = d.object;
    const fields = [_][]const u8{ "year", "month", "day", "hour", "minute", "second" };
    var vals: [6]i64 = undefined;
    for (fields, 0..) |f, i| {
        const x = o.get(f) orelse return null;
        if (x != .integer) return null;
        vals[i] = x.integer;
    }
    const year = std.math.cast(i32, vals[0]) orelse return null;
    var rest: [5]u32 = undefined;
    for (vals[1..], 0..) |x, i| rest[i] = std.math.cast(u32, x) orelse return null;
    return .{ .year = year, .month = rest[0], .day = rest[1], .hour = rest[2], .minute = rest[3], .second = rest[4] };
}

const Parser = struct {
    a: Allocator,
    diag: ?*Diagnostic,

    fn err(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        return fail(p.diag, error.Json, fmt, args);
    }

    fn field(o: Value, key: []const u8) ?Value {
        return if (o == .object) o.object.get(key) else null;
    }

    /// Present and non-null (serde `Option<T>` treats `null` as absent).
    fn optField(o: Value, key: []const u8) ?Value {
        const v = field(o, key) orelse return null;
        return if (v == .null) null else v;
    }

    fn usizeOf(p: *Parser, v: Value, key: []const u8) Error!usize {
        return switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else p.err("invalid value: integer `{d}`, expected usize for `{s}`", .{ i, key }),
            .number_string => tooLarge(p.diag),
            else => p.err("invalid type for `{s}`, expected usize", .{key}),
        };
    }

    fn reqUsize(p: *Parser, o: Value, key: []const u8) Error!usize {
        const v = field(o, key) orelse return p.err("missing field `{s}`", .{key});
        return p.usizeOf(v, key);
    }

    fn optUsize(p: *Parser, o: Value, key: []const u8) Error!?usize {
        const v = optField(o, key) orelse return null;
        return try p.usizeOf(v, key);
    }

    fn optBool(p: *Parser, o: Value, key: []const u8) Error!?bool {
        const v = optField(o, key) orelse return null;
        if (v != .bool) return p.err("invalid type for `{s}`, expected a boolean", .{key});
        return v.bool;
    }

    fn f32Of(p: *Parser, v: Value, key: []const u8) Error!f32 {
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            .number_string => p.err("number out of range in `{s}`", .{key}),
            else => p.err("invalid type for `{s}`, expected f32", .{key}),
        };
    }

    fn reqString(p: *Parser, o: Value, key: []const u8) Error![]const u8 {
        const v = field(o, key) orelse return p.err("missing field `{s}`", .{key});
        if (v != .string) return p.err("invalid type for `{s}`, expected a string", .{key});
        return v.string;
    }

    fn usizeList(p: *Parser, v: Value, key: []const u8) Error![]usize {
        if (v != .array) return p.err("invalid type for `{s}`, expected a sequence", .{key});
        const items = v.array.items;
        if (items.len > max_layers) return tooLarge(p.diag);
        const out = try p.a.alloc(usize, items.len);
        for (items, out) |x, *o| o.* = try p.usizeOf(x, key);
        return out;
    }

    fn model(p: *Parser, root: Value, depth: usize) Error!NamModel {
        if (depth > max_nesting) return fail(p.diag, error.UnsupportedFeature, "model nesting deeper than {d}", .{max_nesting});
        if (root != .object) return p.err("invalid type: expected struct NamModel", .{});
        const version = try p.reqString(root, "version");
        const architecture = try p.reqString(root, "architecture");
        const config_v = field(root, "config") orelse return p.err("missing field `config`", .{});
        const weights_v = field(root, "weights") orelse return p.err("missing field `weights`", .{});
        if (weights_v != .array) return p.err("invalid type for `weights`, expected a sequence", .{});
        if (weights_v.array.items.len > max_weights) return tooLarge(p.diag);
        const weights = try p.a.alloc(f32, weights_v.array.items.len);
        for (weights_v.array.items, weights) |x, *w| w.* = try p.f32Of(x, "weights");
        const sample_rate: ?f64 = if (optField(root, "sample_rate")) |sr|
            (numberF64(sr) orelse return p.err("invalid type for `sample_rate`, expected f64", .{}))
        else
            null;
        const metadata = optField(root, "metadata");

        const config: ModelConfig = if (std.mem.eql(u8, architecture, "WaveNet"))
            .{ .wave_net = try p.waveNet(config_v, depth) }
        else if (std.mem.eql(u8, architecture, "LSTM"))
            .{ .lstm = .{
                .input_size = try p.reqUsize(config_v, "input_size"),
                .hidden_size = try p.reqUsize(config_v, "hidden_size"),
                .num_layers = try p.reqUsize(config_v, "num_layers"),
            } }
        else if (std.mem.eql(u8, architecture, "SlimmableContainer"))
            .{ .slimmable = try p.slimmable(config_v, depth) }
        else
            return p.err("unsupported model architecture: \"{s}\"", .{architecture});

        return .{
            .version = version,
            .architecture = architecture,
            .config = config,
            .weights = weights,
            .sample_rate = sample_rate,
            .metadata = metadata,
        };
    }

    fn slimmable(p: *Parser, cfg: Value, depth: usize) Error!SlimmableConfig {
        const subs = field(cfg, "submodels") orelse return p.err("missing field `submodels`", .{});
        if (subs != .array) return p.err("invalid type for `submodels`, expected a sequence", .{});
        if (subs.array.items.len > max_layers) return tooLarge(p.diag);
        const out = try p.a.alloc(SlimmableSubmodel, subs.array.items.len);
        for (subs.array.items, out) |s, *o| {
            const mv = field(s, "max_value") orelse return p.err("missing field `max_value`", .{});
            const m = field(s, "model") orelse return p.err("missing field `model`", .{});
            o.* = .{ .max_value = try p.f32Of(mv, "max_value"), .model = try p.model(m, depth + 1) };
        }
        return .{ .submodels = out };
    }

    fn waveNet(p: *Parser, cfg: Value, depth: usize) Error!WaveNetConfig {
        if (cfg != .object) return p.err("invalid type: expected struct RawWaveNetConfig", .{});
        const layers_v = field(cfg, "layers") orelse return p.err("missing field `layers`", .{});
        if (layers_v != .array) return p.err("invalid type for `layers`, expected a sequence", .{});
        if (layers_v.array.items.len > max_layers) return tooLarge(p.diag);
        const layers = try p.a.alloc(LayerArrayConfig, layers_v.array.items.len);
        for (layers_v.array.items, layers) |l, *o| o.* = try p.layerArray(l);
        const hs = field(cfg, "head_scale") orelse return p.err("missing field `head_scale`", .{});
        const head_scale = try p.f32Of(hs, "head_scale");
        const in_channels = (try p.optUsize(cfg, "in_channels")) orelse 1;

        var post_stack_head: ?PostStackHeadConfig = null;
        if (optField(cfg, "head")) |h| {
            const channels = lenientUsize(h, "channels") orelse return p.err("post-stack head missing channels", .{});
            const out_channels = lenientUsize(h, "out_channels") orelse return p.err("post-stack head missing out_channels", .{});
            const ks = field(h, "kernel_sizes") orelse return p.err("post-stack head missing kernel_sizes", .{});
            if (ks != .array) return p.err("post-stack head missing kernel_sizes", .{});
            if (ks.array.items.len > max_layers) return tooLarge(p.diag);
            const kernel_sizes = try p.a.alloc(usize, ks.array.items.len);
            for (ks.array.items, kernel_sizes) |k, *o| {
                if (k != .integer or k.integer < 0) return p.err("kernel_sizes entry not an int", .{});
                o.* = @intCast(k.integer);
            }
            post_stack_head = .{
                .channels = channels,
                .out_channels = out_channels,
                .kernel_sizes = kernel_sizes,
                .activation = ActivationSpec.fromValue(field(h, "activation") orelse .null),
            };
        }

        var condition_dsp: ?*const NamModel = null;
        if (optField(cfg, "condition_dsp")) |c| {
            const m = try p.a.create(NamModel);
            m.* = try p.model(c, depth + 1);
            condition_dsp = m;
        }

        return .{
            .layers = layers,
            .post_stack_head = post_stack_head,
            .head_scale = head_scale,
            .in_channels = in_channels,
            .condition_dsp = condition_dsp,
        };
    }

    /// nam-rs `RawLayerArrayConfig::normalize`.
    fn layerArray(p: *Parser, l: Value) Error!LayerArrayConfig {
        if (l != .object) return p.err("invalid type: expected struct RawLayerArrayConfig", .{});
        const input_size = try p.reqUsize(l, "input_size");
        const condition_size = try p.reqUsize(l, "condition_size");
        const channels = try p.reqUsize(l, "channels");
        const bottleneck_opt = try p.optUsize(l, "bottleneck");
        const dil_v = field(l, "dilations") orelse return p.err("missing field `dilations`", .{});
        const dilations = try p.usizeList(dil_v, "dilations");
        const kernel_size = try p.optUsize(l, "kernel_size");
        const kernel_sizes_opt: ?[]usize = if (optField(l, "kernel_sizes")) |v| try p.usizeList(v, "kernel_sizes") else null;
        const activation_v = field(l, "activation") orelse return p.err("missing field `activation`", .{});
        const gating_v = optField(l, "gating_mode");
        const gated = try p.optBool(l, "gated");
        const secondary_v = optField(l, "secondary_activation");
        const groups_input = (try p.optUsize(l, "groups_input")) orelse 1;
        const groups_input_mixin = (try p.optUsize(l, "groups_input_mixin")) orelse 1;
        const head_v = optField(l, "head");
        const head_size_opt = try p.optUsize(l, "head_size");
        const head_bias_opt = try p.optBool(l, "head_bias");

        const n = dilations.len;
        if (n == 0) return p.err("layer-array has no dilations", .{});

        var kernel_sizes: []usize = undefined;
        if (kernel_size != null and kernel_sizes_opt != null) {
            return p.err("layer-array specifies both kernel_size and kernel_sizes", .{});
        } else if (kernel_size) |k| {
            kernel_sizes = try p.a.alloc(usize, n);
            @memset(kernel_sizes, k);
        } else if (kernel_sizes_opt) |ks| {
            if (ks.len != n) return p.err("kernel_sizes length {d} != number of layers {d}", .{ ks.len, n });
            kernel_sizes = ks;
        } else {
            return p.err("layer-array specifies neither kernel_size nor kernel_sizes", .{});
        }

        const activations = try p.a.alloc(ActivationSpec, n);
        if (activation_v == .array) {
            const items = activation_v.array.items;
            if (items.len != n) return p.err("activation list length {d} != number of layers {d}", .{ items.len, n });
            for (items, activations) |x, *o| o.* = ActivationSpec.fromValue(x);
        } else @memset(activations, ActivationSpec.fromValue(activation_v));

        const gating_modes = try p.a.alloc(GatingMode, n);
        if (gating_v) |g| {
            if (g == .array) {
                if (g.array.items.len != n) return p.err("gating_mode list length {d} != number of layers {d}", .{ g.array.items.len, n });
                for (g.array.items, gating_modes) |x, *o| o.* = try p.gating(x);
            } else @memset(gating_modes, try p.gating(g));
        } else @memset(gating_modes, if (gated orelse false) .gated else .none);

        const secondary_activations = try p.a.alloc(ActivationSpec, n);
        if (secondary_v) |s| {
            if (s == .array) {
                if (s.array.items.len != n) return p.err("secondary_activation list length {d} != number of layers {d}", .{ s.array.items.len, n });
                for (s.array.items, secondary_activations) |x, *o|
                    o.* = if (x == .null) ActivationSpec.sigmoid else ActivationSpec.fromValue(x);
            } else @memset(secondary_activations, ActivationSpec.fromValue(s));
        } else @memset(secondary_activations, ActivationSpec.sigmoid);

        var head_size: usize = undefined;
        var head_kernel_size: usize = undefined;
        var head_bias: bool = undefined;
        if (head_v) |h| {
            head_size = lenientUsize(h, "out_channels") orelse return p.err("layer head missing out_channels", .{});
            head_kernel_size = lenientUsize(h, "kernel_size") orelse return p.err("layer head missing kernel_size", .{});
            head_bias = lenientBool(h, "bias") orelse true;
        } else {
            head_size = head_size_opt orelse return p.err("layer-array missing head_size (and no head object)", .{});
            head_kernel_size = 1;
            head_bias = head_bias_opt orelse false;
        }

        if (head_kernel_size == 0) return p.err("layer-array head_kernel_size must be >= 1", .{});
        if (channels == 0) return p.err("layer-array channels must be >= 1", .{});
        if (head_size == 0) return p.err("layer-array head_size must be >= 1", .{});
        if (std.mem.indexOfScalar(usize, kernel_sizes, 0) != null) return p.err("layer-array kernel_sizes entries must be >= 1", .{});
        if (std.mem.indexOfScalar(usize, dilations, 0) != null) return p.err("layer-array dilations entries must be >= 1", .{});
        const bottleneck = bottleneck_opt orelse channels;
        if (bottleneck == 0) return p.err("layer-array bottleneck must be >= 1", .{});

        const layer1x1 = Layer1x1Config.fromValue(optField(l, "layer1x1"));
        const head1x1 = Head1x1Config.fromValue(optField(l, "head1x1"));
        const film_names = [8][]const u8{
            "conv_pre_film",       "conv_post_film",       "input_mixin_pre_film", "input_mixin_post_film",
            "activation_pre_film", "activation_post_film", "layer1x1_post_film",   "head1x1_post_film",
        };
        var films: [8]FilmConfig = undefined;
        var min_film_groups: usize = std.math.maxInt(usize);
        for (film_names, &films) |name, *f| {
            f.* = FilmConfig.fromValue(optField(l, name));
            min_film_groups = @min(min_film_groups, f.groups);
        }
        const group_counts = [_]struct { []const u8, usize }{
            .{ "groups_input", groups_input },
            .{ "groups_input_mixin", groups_input_mixin },
            .{ "layer1x1.groups", layer1x1.groups },
            .{ "head1x1.groups", head1x1.groups },
            .{ "film.groups", min_film_groups },
        };
        for (group_counts) |gc| {
            if (gc[1] == 0) return p.err("layer-array {s} must be >= 1", .{gc[0]});
        }

        return .{
            .input_size = input_size,
            .condition_size = condition_size,
            .channels = channels,
            .bottleneck = bottleneck,
            .dilations = dilations,
            .kernel_sizes = kernel_sizes,
            .activations = activations,
            .gating_modes = gating_modes,
            .secondary_activations = secondary_activations,
            .groups_input = groups_input,
            .groups_input_mixin = groups_input_mixin,
            .head_size = head_size,
            .head_kernel_size = head_kernel_size,
            .head_bias = head_bias,
            .layer1x1 = layer1x1,
            .head1x1 = head1x1,
            .films = films,
        };
    }

    fn gating(p: *Parser, v: Value) Error!GatingMode {
        if (v != .string) return p.err("gating_mode entry is not a string", .{});
        return GatingMode.fromName(v.string) orelse p.err("unknown gating_mode: \"{s}\"", .{v.string});
    }
};

// ─────────────────────────────── runtime primitives ───────────────────────────────

/// Allocation context for building a runtime: an arena, the diagnostic, and the
/// remaining float budget (`max_runtime_floats`).
const Builder = struct {
    a: Allocator,
    diag: ?*Diagnostic,
    floats_left: usize = max_runtime_floats,

    fn floats(b: *Builder, n: usize) Error![]f32 {
        if (n > b.floats_left) return tooLarge(b.diag);
        b.floats_left -= n;
        const s = try b.a.alloc(f32, n);
        @memset(s, 0);
        return s;
    }

    fn mulAdd(b: *Builder, x: usize, y: usize, z: usize) Error!usize {
        const m = std.math.mul(usize, x, y) catch return tooLarge(b.diag);
        return std.math.add(usize, m, z) catch return tooLarge(b.diag);
    }
};

/// Sequential reader over the flat weight blob (nam-rs `Reader`).
const Reader = struct {
    w: []const f32,
    i: usize = 0,

    fn take(r: *Reader, b: *Builder, n: usize) Error![]f32 {
        if (n > r.w.len - r.i) return fail(b.diag, error.WeightCountMismatch, "weight blob exhausted while building", .{});
        const out = try b.floats(n);
        @memcpy(out, r.w[r.i .. r.i + n]);
        r.i += n;
        return out;
    }

    fn remaining(r: *const Reader) usize {
        return r.w.len - r.i;
    }
};

const Activation = union(enum) {
    tanh,
    relu,
    sigmoid,
    leaky_relu: f32,

    fn fromSpec(spec: ActivationSpec, diag: ?*Diagnostic) Error!Activation {
        switch (spec) {
            .named => |n| {
                if (std.mem.eql(u8, n.name, "Tanh")) return .tanh;
                if (std.mem.eql(u8, n.name, "ReLU")) return .relu;
                if (std.mem.eql(u8, n.name, "Sigmoid")) return .sigmoid;
                if (std.mem.eql(u8, n.name, "LeakyReLU")) return .{ .leaky_relu = n.negative_slope orelse 0.01 };
                return fail(diag, error.UnsupportedActivation, "\"{s}\"", .{n.name});
            },
            .unsupported => return fail(diag, error.UnsupportedFeature, "activation: unsupported shape", .{}),
        }
    }

    inline fn apply(self: Activation, x: f32) f32 {
        return switch (self) {
            .tanh => std.math.tanh(x),
            .relu => if (x > 0.0) x else 0.0,
            .sigmoid => sigmoid(x),
            .leaky_relu => |slope| if (x > 0.0) x else slope * x,
        };
    }

    fn applySlice(self: Activation, xs: []f32) void {
        for (xs) |*v| v.* = self.apply(v.*);
    }
};

inline fn sigmoid(x: f32) f32 {
    return 1.0 / (1.0 + @exp(-x));
}

/// `out[t] += w * src[t]`, explicitly vectorized (LLVM does not vectorize the scalar
/// loop here). Element-wise with no reassociation, so results are identical.
inline fn axpy(out: []f32, src: []const f32, w: f32) void {
    const lanes = 8;
    const V = @Vector(lanes, f32);
    const wv: V = @splat(w);
    var t: usize = 0;
    while (t + lanes <= out.len) : (t += lanes) {
        const y: V = out[t..][0..lanes].*;
        const x: V = src[t..][0..lanes].*;
        out[t..][0..lanes].* = y + wv * x;
    }
    while (t < out.len) : (t += 1) out[t] += w * src[t];
}

/// Causal, dilated, optionally grouped 1-D convolution with a ring-buffer history
/// (nam-rs `Conv1d`). Weights `[group][out_per_group][in_per_group][kernel]`, then an
/// optional `[out_ch]` bias. Only the planar block path is ported: nam-rs documents it
/// as bit-for-bit equivalent to its per-sample path.
const Conv1d = struct {
    in_ch: usize,
    out_ch: usize,
    kernel: usize,
    dilation: usize,
    out_per_group: usize,
    in_per_group: usize,
    weights: []const f32,
    bias: ?[]const f32,
    ring: []f32,
    ring_len: usize,
    pos: usize,
    staged: []f32,
    staged_stride: usize,

    fn init(b: *Builder, in_ch: usize, out_ch: usize, kernel: usize, dilation: usize, groups: usize, weights: []const f32, bias: ?[]const f32) Error!Conv1d {
        if (groups == 0 or in_ch % groups != 0 or out_ch % groups != 0 or kernel == 0)
            return fail(b.diag, error.UnsupportedFeature, "grouped conv: out ({d}) and in ({d}) must both be divisible by groups ({d})", .{ out_ch, in_ch, groups });
        std.debug.assert(weights.len == out_ch * in_ch * kernel / groups);
        const ring_len = try b.mulAdd(kernel - 1, dilation, 1);
        const staged_stride = try b.mulAdd(1, ring_len - 1, MAX_BLOCK);
        return .{
            .in_ch = in_ch,
            .out_ch = out_ch,
            .kernel = kernel,
            .dilation = dilation,
            .out_per_group = out_ch / groups,
            .in_per_group = in_ch / groups,
            .weights = weights,
            .bias = bias,
            .ring = try b.floats(try b.mulAdd(in_ch, ring_len, 0)),
            .ring_len = ring_len,
            .pos = ring_len - 1,
            .staged = try b.floats(try b.mulAdd(in_ch, staged_stride, 0)),
            .staged_stride = staged_stride,
        };
    }

    /// `block_in` is planar `[ch * n + t]` with at least `in_ch` rows; `block_out` is
    /// `out_ch * n`. `n <= MAX_BLOCK`. Allocation-free.
    fn processBlock(self: *Conv1d, block_in: []const f32, block_out: []f32, n: usize) void {
        std.debug.assert(n <= MAX_BLOCK);
        if (n == 0) return;
        if (n == 1) return self.processSample(block_in, block_out);
        const hist_len = self.ring_len - 1;
        const s = self.staged_stride;

        // Stage the history tail (oldest first) then this block, one row per input
        // channel. The oldest history column is (pos + 2) mod ring_len.
        if (hist_len > 0) {
            var col = (self.pos + 2) % self.ring_len;
            for (0..hist_len) |h| {
                const rb = col * self.in_ch;
                for (0..self.in_ch) |j| self.staged[j * s + h] = self.ring[rb + j];
                col += 1;
                if (col == self.ring_len) col = 0;
            }
        }
        for (0..self.in_ch) |j| {
            const row = j * s;
            @memcpy(self.staged[row + hist_len .. row + hist_len + n], block_in[j * n .. j * n + n]);
        }

        for (0..self.out_ch) |o| {
            const bval: f32 = if (self.bias) |bias| bias[o] else 0.0;
            @memset(block_out[o * n .. o * n + n], bval);
        }
        const opg = self.out_per_group;
        const ipg = self.in_per_group;
        for (0..self.out_ch) |o| {
            const g = o / opg;
            const in_base = g * ipg;
            const wo = o * ipg * self.kernel;
            const out = block_out[o * n .. o * n + n];
            for (0..self.kernel) |k| {
                const back = (self.kernel - 1 - k) * self.dilation;
                for (0..ipg) |jl| {
                    const w = self.weights[wo + jl * self.kernel + k];
                    const base = (in_base + jl) * s + hist_len - back;
                    axpy(out, self.staged[base .. base + n], w);
                }
            }
        }

        // Advance the ring; only the last ring_len columns can survive.
        const keep = @min(n, self.ring_len);
        var col = (self.pos + 1 + (n - keep)) % self.ring_len;
        for (n - keep..n) |t| {
            const base = col * self.in_ch;
            for (0..self.in_ch) |j| self.ring[base + j] = block_in[j * n + t];
            col += 1;
            if (col == self.ring_len) col = 0;
        }
        self.pos = (self.pos + n) % self.ring_len;
    }

    /// One column (nam-rs `Conv1d::process_sample`): reads the taps straight from the
    /// ring, with the same accumulation order as the block path (bias, then tap, then
    /// input channel), so the two are interchangeable.
    fn processSample(self: *Conv1d, input: []const f32, out: []f32) void {
        self.pos += 1;
        if (self.pos == self.ring_len) self.pos = 0;
        const base = self.pos * self.in_ch;
        @memcpy(self.ring[base .. base + self.in_ch], input[0..self.in_ch]);
        const opg = self.out_per_group;
        const ipg = self.in_per_group;
        for (0..self.out_ch) |o| {
            var acc: f32 = if (self.bias) |bias| bias[o] else 0.0;
            const in_base = (o / opg) * ipg;
            const wo = o * ipg * self.kernel;
            for (0..self.kernel) |k| {
                const back = (self.kernel - 1 - k) * self.dilation;
                var col = self.pos + self.ring_len - back;
                if (col >= self.ring_len) col -= self.ring_len;
                const rbase = col * self.in_ch + in_base;
                for (0..ipg) |jl| acc += self.weights[wo + jl * self.kernel + k] * self.ring[rbase + jl];
            }
            out[o] = acc;
        }
    }

    fn reset(self: *Conv1d) void {
        @memset(self.ring, 0);
        self.pos = self.ring_len - 1;
    }
};

/// Feature-wise linear modulation (nam-rs `FiLM`): `out = in * scale (+ shift)`, the
/// scale/shift rows produced by a 1×1 conv over the conditioning.
const FiLM = struct {
    conv: Conv1d,
    input_dim: usize,
    shift: bool,
    out_rows: usize,
    ss_blk: []f32,

    fn init(b: *Builder, condition_dim: usize, input_dim: usize, shift: bool, groups: usize, weights: []const f32, bias: []const f32) Error!FiLM {
        const out_rows = if (shift) 2 * input_dim else input_dim;
        return .{
            .conv = try Conv1d.init(b, condition_dim, out_rows, 1, 1, groups, weights, bias),
            .input_dim = input_dim,
            .shift = shift,
            .out_rows = out_rows,
            .ss_blk = try b.floats(out_rows * MAX_BLOCK),
        };
    }

    /// Out-of-place; `out` must not alias `input`.
    fn processBlock(self: *FiLM, input: []const f32, condition: []const f32, out: []f32, n: usize) void {
        const d = self.input_dim;
        const ss = self.ss_blk[0 .. self.out_rows * n];
        self.conv.processBlock(condition, ss, n);
        if (self.shift) {
            for (0..d) |i| {
                for (0..n) |t| out[i * n + t] = input[i * n + t] * ss[i * n + t] + ss[(d + i) * n + t];
            }
        } else {
            for (0..d * n) |k| out[k] = input[k] * ss[k];
        }
    }

    fn processBlockInPlace(self: *FiLM, buf: []f32, condition: []const f32, n: usize) void {
        const d = self.input_dim;
        const ss = self.ss_blk[0 .. self.out_rows * n];
        self.conv.processBlock(condition, ss, n);
        if (self.shift) {
            for (0..d) |i| {
                for (0..n) |t| buf[i * n + t] = buf[i * n + t] * ss[i * n + t] + ss[(d + i) * n + t];
            }
        } else {
            for (0..d * n) |k| buf[k] *= ss[k];
        }
    }

    fn reset(self: *FiLM) void {
        self.conv.reset();
    }
};

/// Activation gating over a layer's pre-activation rows (nam-rs `Gating`).
const Gating = struct {
    mode: GatingMode,
    primary: Activation,
    secondary: Activation,
    bottleneck: usize,

    fn inputRows(self: Gating) usize {
        return if (self.mode == .none) self.bottleneck else 2 * self.bottleneck;
    }

    fn processBlock(self: Gating, z: []const f32, out: []f32, n: usize) void {
        const bn = self.bottleneck;
        switch (self.mode) {
            .none => for (0..bn * n) |k| {
                out[k] = self.primary.apply(z[k]);
            },
            .gated => for (0..bn) |c| {
                for (0..n) |t| {
                    const v = self.primary.apply(z[c * n + t]);
                    const s = self.secondary.apply(z[(c + bn) * n + t]);
                    out[c * n + t] = v * s;
                }
            },
            .blended => for (0..bn) |c| {
                for (0..n) |t| {
                    const raw = z[c * n + t];
                    const alpha = self.secondary.apply(z[(c + bn) * n + t]);
                    const v = self.primary.apply(raw);
                    out[c * n + t] = alpha * v + (1.0 - alpha) * raw;
                }
            },
        }
    }
};

/// One dilated WaveNet layer (nam-rs `Layer`, NAMCore `Layer::Process` order).
const Layer = struct {
    conv: Conv1d,
    mixin: Conv1d,
    layer1x1: ?Conv1d,
    head1x1: ?Conv1d,
    films: [8]?FiLM,
    gating: Gating,
    channels: usize,
    bottleneck: usize,
    condition_size: usize,
    mid: usize,
    head_contrib_width: usize,
    conv_pre_blk: []f32,
    conv_out_blk: []f32,
    mix_blk: []f32,
    mix_pre_blk: []f32,
    z_blk: []f32,
    act_blk: []f32,
    act_film_blk: []f32,
    head_contrib_blk: []f32,
    res_blk: []f32,

    /// `input`/`out`: `channels * n`; `condition`: at least `condition_size` rows of `n`;
    /// `head_accum`: `head_contrib_width * n`, accumulated into.
    fn processBlock(self: *Layer, input: []const f32, condition: []const f32, head_accum: []f32, out: []f32, n: usize) void {
        const mid = self.mid;
        const ch = self.channels;
        const bn = self.bottleneck;
        const hcw = self.head_contrib_width;
        const cond_w = self.condition_size * n;

        // 1. conv with optional pre/post FiLM.
        var conv_in: []const f32 = input;
        if (self.films[0]) |*f| {
            f.processBlock(input, condition, self.conv_pre_blk[0 .. ch * n], n);
            conv_in = self.conv_pre_blk[0 .. ch * n];
        }
        const conv_out = self.conv_out_blk[0 .. mid * n];
        self.conv.processBlock(conv_in, conv_out, n);
        if (self.films[1]) |*f| f.processBlockInPlace(conv_out, condition, n);

        // 2. input mixin with optional pre/post FiLM.
        var mix_in: []const f32 = condition;
        if (self.films[2]) |*f| {
            f.processBlock(condition, condition, self.mix_pre_blk[0..cond_w], n);
            mix_in = self.mix_pre_blk[0..cond_w];
        }
        const mix = self.mix_blk[0 .. mid * n];
        self.mixin.processBlock(mix_in, mix, n);
        if (self.films[3]) |*f| f.processBlockInPlace(mix, condition, n);

        // 3. z = conv_out + mix, optional activation_pre FiLM.
        const z = self.z_blk[0 .. mid * n];
        for (z, conv_out, mix) |*zi, c, m| zi.* = c + m;
        if (self.films[4]) |*f| f.processBlockInPlace(z, condition, n);

        // 4. gating into act, then activation_post FiLM.
        const act = self.act_blk[0 .. bn * n];
        self.gating.processBlock(z, act, n);
        if (self.films[5]) |*f| {
            if (self.gating.mode == .none) {
                f.processBlockInPlace(act, condition, n);
            } else {
                const act_film = self.act_film_blk[0 .. bn * n];
                f.processBlock(act, condition, act_film, n);
                @memcpy(act, act_film);
            }
        }

        // 5. head contribution.
        const hc = self.head_contrib_blk[0 .. hcw * n];
        if (self.head1x1) |*h| {
            h.processBlock(act, hc, n);
            if (self.films[7]) |*f| f.processBlockInPlace(hc, condition, n);
        } else {
            @memcpy(hc, act);
        }
        for (head_accum[0 .. hcw * n], hc) |*a, c| a.* += c;

        // 6. residual.
        if (self.layer1x1) |*l| {
            const res = self.res_blk[0 .. ch * n];
            l.processBlock(act, res, n);
            if (self.gating.mode == .blended) {
                if (self.films[6]) |*f| f.processBlockInPlace(res, condition, n);
            }
            for (out[0 .. ch * n], res, input[0 .. ch * n]) |*o, r, x| o.* = r + x;
        } else {
            @memcpy(out[0 .. ch * n], input[0 .. ch * n]);
        }
    }

    fn reset(self: *Layer) void {
        self.conv.reset();
        self.mixin.reset();
        if (self.layer1x1) |*l| l.reset();
        if (self.head1x1) |*h| h.reset();
        for (&self.films) |*f| {
            if (f.*) |*film| film.reset();
        }
    }
};

/// Input rechannel, a stack of layers, and a head rechannel (nam-rs `LayerArray`).
const LayerArray = struct {
    rechannel: Conv1d,
    layers: []Layer,
    head_rechannel: Conv1d,
    channels: usize,
    head_in: usize,
    head_size: usize,
    cur_blk: []f32,
    nxt_blk: []f32,
    head_accum_blk: []f32,

    fn processBlock(self: *LayerArray, input: []const f32, condition: []const f32, head_prev: []const f32, head_out: []f32, array_out: []f32, n: usize) void {
        const ch = self.channels;
        const hin = self.head_in;
        self.rechannel.processBlock(input, self.cur_blk[0 .. ch * n], n);
        @memcpy(self.head_accum_blk[0 .. hin * n], head_prev[0 .. hin * n]);
        for (self.layers) |*layer| {
            layer.processBlock(self.cur_blk[0 .. ch * n], condition, self.head_accum_blk[0 .. hin * n], self.nxt_blk[0 .. ch * n], n);
            std.mem.swap([]f32, &self.cur_blk, &self.nxt_blk);
        }
        self.head_rechannel.processBlock(self.head_accum_blk[0 .. hin * n], head_out, n);
        @memcpy(array_out[0 .. ch * n], self.cur_blk[0 .. ch * n]);
    }

    fn reset(self: *LayerArray) void {
        self.rechannel.reset();
        self.head_rechannel.reset();
        for (self.layers) |*l| l.reset();
    }
};

/// Post-stack head: `(activation, conv)` pairs run in chain order (nam-rs `PostStackHead`).
const PostStackHead = struct {
    activation: Activation,
    convs: []Conv1d,
    in_channels: usize,
    out_channels: usize,
    scratch_a: []f32,
    scratch_b: []f32,

    /// `work` is `[in_channels][n]`, already `head_scale`-scaled, modified in place.
    /// Returns the last conv's output `[out_channels][n]`.
    fn processBlock(self: *PostStackHead, work: []f32, n: usize) []const f32 {
        for (self.convs, 0..) |*conv, i| {
            const in_w = conv.in_ch * n;
            const out_w = conv.out_ch * n;
            if (i == 0) {
                self.activation.applySlice(work[0..in_w]);
                conv.processBlock(work[0..in_w], self.scratch_a[0..out_w], n);
            } else {
                const src = if (i % 2 == 1) self.scratch_a else self.scratch_b;
                const dst = if (i % 2 == 1) self.scratch_b else self.scratch_a;
                self.activation.applySlice(src[0..in_w]);
                conv.processBlock(src[0..in_w], dst[0..out_w], n);
            }
        }
        const last = if (self.convs.len % 2 == 1) self.scratch_a else self.scratch_b;
        return last[0 .. self.out_channels * n];
    }

    fn reset(self: *PostStackHead) void {
        for (self.convs) |*c| c.reset();
    }
};

// ─────────────────────────────── WaveNet ───────────────────────────────

/// A ready-to-run WaveNet with all scratch pre-allocated (nam-rs `WaveNet`).
pub const WaveNet = struct {
    arrays: []LayerArray,
    post_stack_head: ?*PostStackHead,
    head_scale_scratch: []f32,
    condition_dsp: ?*Runtime,
    cond_out_ch: usize,
    cond_dsp_out: []f32,
    head_scale: f32,
    receptive_field: usize,
    head_in0: usize,
    head_a_blk: []f32,
    head_b_blk: []f32,
    sig_a_blk: []f32,
    sig_b_blk: []f32,
    cond_blk: []f32,

    fn build(b: *Builder, model: *const NamModel, allow_multi_output: bool) Error!*WaveNet {
        const cfg = switch (model.config) {
            .wave_net => |*c| c,
            else => return fail(b.diag, error.UnsupportedArchitecture, "\"{s}\"", .{model.architecture}),
        };

        // check_unsupported_features
        if (cfg.in_channels != 1) return fail(b.diag, error.UnsupportedFeature, "in_channels != 1", .{});
        if (cfg.layers.len == 0) return fail(b.diag, error.UnsupportedFeature, "WaveNet with no layer-arrays", .{});
        for (cfg.layers) |*la| {
            const first = la.gatingMode();
            for (la.gating_modes) |g| if (g != first) return fail(b.diag, error.UnsupportedFeature, "mixed gating modes", .{});
        }
        try checkBounds(b, cfg);

        if (!allow_multi_output and cfg.post_stack_head == null) {
            const out_ch = cfg.layers[cfg.layers.len - 1].head_size;
            if (out_ch != 1) return fail(b.diag, error.UnsupportedFeature, "top-level WaveNet must be mono-output, but produces {d} channels (a multi-channel WaveNet is only valid as a nested condition_dsp)", .{out_ch});
        }

        var condition_dsp: ?*Runtime = null;
        if (cfg.condition_dsp) |nested| {
            const r = try b.a.create(Runtime);
            r.* = try Runtime.fromNamConditioning(b, nested);
            condition_dsp = r;
        }
        const cond_out_ch: usize = if (condition_dsp) |c| c.numOutputChannels() else 1;
        for (cfg.layers, 0..) |*la, i| {
            if (condition_dsp != null) {
                if (la.condition_size != cond_out_ch)
                    return fail(b.diag, error.UnsupportedFeature, "condition_size of layer-array {d} ({d}) != condition_dsp output channels ({d})", .{ i, la.condition_size, cond_out_ch });
            } else if (la.condition_size > 1) {
                // nam-rs would index past the one-row conditioning and panic.
                return fail(b.diag, error.UnsupportedFeature, "condition_size of layer-array {d} ({d}) > 1 without a condition_dsp", .{ i, la.condition_size });
            }
            const avail: usize = if (i == 0) 1 else cfg.layers[i - 1].channels;
            if (la.input_size > avail)
                return fail(b.diag, error.UnsupportedFeature, "input_size of layer-array {d} ({d}) exceeds the {d} rows it receives", .{ i, la.input_size, avail });
        }

        const expected = try expectedWeightCount(b, cfg);
        if (expected != model.weights.len)
            return fail(b.diag, error.WeightCountMismatch, "config implies {d} weights, file has {d}", .{ expected, model.weights.len });

        var r: Reader = .{ .w = model.weights };
        const arrays = try b.a.alloc(LayerArray, cfg.layers.len);
        for (cfg.layers, arrays) |*la, *arr| arr.* = try buildArray(b, &r, la);
        for (1..arrays.len) |i| {
            const produced = arrays[i - 1].head_size;
            const consumed = arrays[i].head_in;
            if (produced != consumed)
                return fail(b.diag, error.UnsupportedFeature, "layer-array head-carry width mismatch: array {d} head_size {d} != array {d} head_in {d}", .{ i - 1, produced, i, consumed });
        }

        var post_stack_head: ?*PostStackHead = null;
        if (cfg.post_stack_head) |*hc| {
            const h = try b.a.create(PostStackHead);
            h.* = try buildPostStackHead(b, &r, hc, arrays[arrays.len - 1].head_size);
            post_stack_head = h;
        }
        const head_scale = (try r.take(b, 1))[0];
        if (r.remaining() != 0) return fail(b.diag, error.WeightCountMismatch, "build consumed fewer weights than expected", .{});

        var max_ch: usize = 1;
        var max_head: usize = 1;
        var max_head_in: usize = 1;
        for (arrays) |*a| {
            max_ch = @max(max_ch, a.channels);
            max_head = @max(max_head, a.head_size);
            max_head_in = @max(max_head_in, a.head_in);
        }
        const head_w = @max(max_ch, max_head, max_head_in, 1);
        const sig_w = max_ch;
        const head_in_channels: usize = @max(if (post_stack_head) |h| h.in_channels else 0, 1);
        const rf_base: usize = if (condition_dsp) |c| c.receptiveField() else 1;

        const self = try b.a.create(WaveNet);
        self.* = .{
            .arrays = arrays,
            .post_stack_head = post_stack_head,
            .head_scale_scratch = try b.floats(head_in_channels * MAX_BLOCK),
            .condition_dsp = condition_dsp,
            .cond_out_ch = cond_out_ch,
            .cond_dsp_out = try b.floats(cond_out_ch * MAX_BLOCK),
            .head_scale = head_scale,
            .receptive_field = configReceptiveField(cfg, rf_base),
            .head_in0 = arrays[0].head_in,
            .head_a_blk = try b.floats(head_w * MAX_BLOCK),
            .head_b_blk = try b.floats(head_w * MAX_BLOCK),
            .sig_a_blk = try b.floats(sig_w * MAX_BLOCK),
            .sig_b_blk = try b.floats(sig_w * MAX_BLOCK),
            .cond_blk = try b.floats(MAX_BLOCK),
        };
        return self;
    }

    /// Receptive field in samples (warmup length / latency).
    pub fn receptiveField(self: *const WaveNet) usize {
        return self.receptive_field;
    }

    /// Process mono samples in place, in `MAX_BLOCK` chunks. Allocation-free.
    pub fn processBuffer(self: *WaveNet, io: []f32) void {
        var off: usize = 0;
        while (off < io.len) {
            const n = @min(io.len - off, MAX_BLOCK);
            self.processChunk(io[off .. off + n], n);
            off += n;
        }
    }

    /// One mono sample: a one-element `processBuffer`.
    pub fn processSample(self: *WaveNet, x: f32) f32 {
        var one = [1]f32{x};
        self.processBuffer(&one);
        return one[0];
    }

    fn numOutputChannels(self: *const WaveNet) usize {
        if (self.post_stack_head) |h| return h.out_channels;
        return self.arrays[self.arrays.len - 1].head_size;
    }

    fn runArraysBlock(self: *WaveNet, n: usize) void {
        const cond_ch = self.cond_out_ch;
        if (self.condition_dsp) |c| {
            c.processBlockMulti(self.cond_blk[0..n], self.cond_dsp_out[0 .. cond_ch * n], n);
        } else {
            @memcpy(self.cond_dsp_out[0..n], self.cond_blk[0..n]);
        }
        const cond = self.cond_dsp_out[0 .. cond_ch * n];

        @memset(self.head_a_blk[0 .. self.head_in0 * n], 0);
        for (self.arrays, 0..) |*arr, i| {
            const input: []const f32 = if (i == 0) self.cond_blk[0..n] else self.sig_a_blk[0 .. self.arrays[i - 1].channels * n];
            arr.processBlock(
                input,
                cond,
                self.head_a_blk[0 .. arr.head_in * n],
                self.head_b_blk[0 .. arr.head_size * n],
                self.sig_b_blk[0 .. arr.channels * n],
                n,
            );
            std.mem.swap([]f32, &self.head_a_blk, &self.head_b_blk);
            std.mem.swap([]f32, &self.sig_a_blk, &self.sig_b_blk);
        }
    }

    fn processChunk(self: *WaveNet, chunk: []f32, n: usize) void {
        @memcpy(self.cond_blk[0..n], chunk);
        self.runArraysBlock(n);
        if (self.post_stack_head) |head| {
            const scaled = self.head_scale_scratch[0 .. head.in_channels * n];
            for (scaled, self.head_a_blk[0 .. head.in_channels * n]) |*s, h| s.* = self.head_scale * h;
            const out = head.processBlock(scaled, n);
            @memcpy(chunk, out[0..n]);
        } else {
            for (chunk, self.head_a_blk[0..n]) |*s, h| s.* = self.head_scale * h;
        }
    }

    /// Multi-channel output twin, used when this WaveNet is a nested `condition_dsp`.
    fn processBlockMulti(self: *WaveNet, input: []const f32, out: []f32, n: usize) void {
        @memcpy(self.cond_blk[0..n], input[0..n]);
        self.runArraysBlock(n);
        if (self.post_stack_head) |head| {
            const scaled = self.head_scale_scratch[0 .. head.in_channels * n];
            for (scaled, self.head_a_blk[0 .. head.in_channels * n]) |*s, h| s.* = self.head_scale * h;
            const oc = head.out_channels;
            const produced = head.processBlock(scaled, n);
            @memcpy(out[0 .. oc * n], produced[0 .. oc * n]);
        } else {
            const oc = self.arrays[self.arrays.len - 1].head_size;
            for (out[0 .. oc * n], self.head_a_blk[0 .. oc * n]) |*o, h| o.* = self.head_scale * h;
        }
    }

    /// Reset all ring buffers to silence.
    pub fn reset(self: *WaveNet) void {
        for (self.arrays) |*a| a.reset();
        if (self.post_stack_head) |h| h.reset();
        if (self.condition_dsp) |c| c.reset();
    }
};

/// Zig-only bounds: reject absurd dimensions before anything is sized from them.
fn checkBounds(b: *Builder, cfg: *const WaveNetConfig) Error!void {
    for (cfg.layers) |*la| {
        const dims = [_]usize{ la.input_size, la.condition_size, la.channels, la.bottleneck, la.head_size, la.head1x1.out_channels orelse 0 };
        for (dims) |d| if (d > max_dim) return tooLarge(b.diag);
        if (la.head_kernel_size > max_kernel) return tooLarge(b.diag);
        for (la.kernel_sizes, la.dilations) |k, d| {
            if (k > max_kernel or d > max_dilation) return tooLarge(b.diag);
        }
    }
    if (cfg.post_stack_head) |h| {
        if (h.channels > max_dim or h.out_channels > max_dim) return tooLarge(b.diag);
        for (h.kernel_sizes) |k| {
            if (k > max_kernel) return tooLarge(b.diag);
            // nam-rs underflows `k - 1` on a zero kernel; reject instead.
            if (k == 0) return fail(b.diag, error.UnsupportedFeature, "post-stack head kernel_sizes entries must be >= 1", .{});
        }
    }
}

fn configReceptiveField(cfg: *const WaveNetConfig, base: usize) usize {
    var rf = base;
    for (cfg.layers) |*la| {
        for (la.kernel_sizes, la.dilations) |k, d| rf += (k - 1) * d;
        rf += la.head_kernel_size - 1;
    }
    if (cfg.post_stack_head) |h| {
        for (h.kernel_sizes) |k| rf += k - 1;
    }
    return rf;
}

const Counter = struct {
    b: *Builder,

    fn mul(c: Counter, x: usize, y: usize) Error!usize {
        return std.math.mul(usize, x, y) catch tooLarge(c.b.diag);
    }

    fn add(c: Counter, x: usize, y: usize) Error!usize {
        return std.math.add(usize, x, y) catch tooLarge(c.b.diag);
    }

    /// Grouped conv weight count `out * in * k / groups` (bias excluded).
    fn convW(c: Counter, out: usize, in_ch: usize, k: usize, groups: usize) Error!usize {
        if (out % groups != 0 or in_ch % groups != 0)
            return fail(c.b.diag, error.UnsupportedFeature, "grouped conv: out ({d}) and in ({d}) must both be divisible by groups ({d})", .{ out, in_ch, groups });
        return (try c.mul(try c.mul(out, in_ch), k)) / groups;
    }

    fn film(c: Counter, f: FilmConfig, input_dim: usize, cond: usize) Error!usize {
        if (!f.active) return 0;
        const out_rows = if (f.shift) try c.mul(2, input_dim) else input_dim;
        return c.add(try c.convW(out_rows, cond, 1, f.groups), out_rows);
    }
};

fn filmInputDims(la: *const LayerArrayConfig, mid: usize, head1x1_out: usize) [8]usize {
    return .{ la.channels, mid, la.condition_size, mid, mid, la.bottleneck, la.channels, head1x1_out };
}

/// nam-rs `array_weight_count`: the weights one layer-array consumes, in `buildArray` order.
fn arrayWeightCount(b: *Builder, la: *const LayerArrayConfig) Error!usize {
    const c: Counter = .{ .b = b };
    const gated = la.gatingMode() != .none;
    const mid = if (gated) try c.mul(2, la.bottleneck) else la.bottleneck;
    const head1x1_out = la.head1x1.out_channels orelse la.channels;
    const cond = la.condition_size;
    const film_dims = filmInputDims(la, mid, head1x1_out);

    var total = try c.mul(la.channels, la.input_size);
    for (la.kernel_sizes) |k| {
        var layer = try c.add(try c.convW(mid, la.channels, k, la.groups_input), mid);
        layer = try c.add(layer, try c.convW(mid, cond, 1, la.groups_input_mixin));
        if (la.layer1x1.active)
            layer = try c.add(layer, try c.add(try c.convW(la.channels, la.bottleneck, 1, la.layer1x1.groups), la.channels));
        if (la.head1x1.active)
            layer = try c.add(layer, try c.add(try c.convW(head1x1_out, la.bottleneck, 1, la.head1x1.groups), head1x1_out));
        for (la.films, film_dims) |f, d| layer = try c.add(layer, try c.film(f, d, cond));
        total = try c.add(total, layer);
    }
    const head_in = if (la.head1x1.active) head1x1_out else la.bottleneck;
    total = try c.add(total, try c.mul(try c.mul(la.head_size, head_in), la.head_kernel_size));
    if (la.head_bias) total = try c.add(total, la.head_size);
    return total;
}

fn postStackHeadWeightCount(b: *Builder, head: *const PostStackHeadConfig, in_channels: usize) Error!usize {
    const c: Counter = .{ .b = b };
    if (head.kernel_sizes.len == 0) return fail(b.diag, error.UnsupportedFeature, "post-stack head with no convs", .{});
    var total: usize = 0;
    var cin = in_channels;
    for (head.kernel_sizes, 0..) |k, i| {
        const cout = if (i + 1 == head.kernel_sizes.len) head.out_channels else head.channels;
        total = try c.add(total, try c.add(try c.mul(try c.mul(cout, cin), k), cout));
        cin = cout;
    }
    return total;
}

fn expectedWeightCount(b: *Builder, cfg: *const WaveNetConfig) Error!usize {
    const c: Counter = .{ .b = b };
    var total: usize = 0;
    for (cfg.layers) |*la| total = try c.add(total, try arrayWeightCount(b, la));
    if (cfg.post_stack_head) |*h| {
        total = try c.add(total, try postStackHeadWeightCount(b, h, cfg.layers[cfg.layers.len - 1].head_size));
    }
    return c.add(total, 1);
}

fn buildPostStackHead(b: *Builder, r: *Reader, hc: *const PostStackHeadConfig, in_channels: usize) Error!PostStackHead {
    if (hc.out_channels != 1) return fail(b.diag, error.UnsupportedFeature, "post-stack head out_channels != 1", .{});
    const activation = try Activation.fromSpec(hc.activation, b.diag);
    const n = hc.kernel_sizes.len;
    const convs = try b.a.alloc(Conv1d, n);
    var cin = in_channels;
    var max_w: usize = @max(in_channels, 1);
    for (hc.kernel_sizes, convs, 0..) |k, *conv, i| {
        const cout = if (i + 1 == n) hc.out_channels else hc.channels;
        const w = try r.take(b, cout * cin * k);
        const bias = try r.take(b, cout);
        conv.* = try Conv1d.init(b, cin, cout, k, 1, 1, w, bias);
        max_w = @max(max_w, cout);
        cin = cout;
    }
    return .{
        .activation = activation,
        .convs = convs,
        .in_channels = in_channels,
        .out_channels = hc.out_channels,
        .scratch_a = try b.floats(max_w * MAX_BLOCK),
        .scratch_b = try b.floats(max_w * MAX_BLOCK),
    };
}

fn buildArray(b: *Builder, r: *Reader, la: *const LayerArrayConfig) Error!LayerArray {
    const mode = la.gatingMode();
    const mid = if (mode != .none) 2 * la.bottleneck else la.bottleneck;
    const head1x1_out = la.head1x1.out_channels orelse la.channels;
    const cond = la.condition_size;
    const film_dims = filmInputDims(la, mid, head1x1_out);
    const head_contrib_width = if (la.head1x1.active) head1x1_out else la.bottleneck;

    const before = r.remaining();
    const rechannel_w = try r.take(b, la.channels * la.input_size);
    const layers = try b.a.alloc(Layer, la.dilations.len);
    for (layers, la.dilations, la.kernel_sizes, 0..) |*layer, d, k, i| {
        const gating: Gating = .{
            .mode = mode,
            .primary = try Activation.fromSpec(la.activations[i], b.diag),
            .secondary = try Activation.fromSpec(la.secondary_activations[i], b.diag),
            .bottleneck = la.bottleneck,
        };
        const conv_w = try r.take(b, mid * la.channels * k / la.groups_input);
        const conv_b = try r.take(b, mid);
        const mix_w = try r.take(b, mid * cond / la.groups_input_mixin);
        var layer1x1: ?Conv1d = null;
        if (la.layer1x1.active) {
            const w = try r.take(b, la.channels * la.bottleneck / la.layer1x1.groups);
            const bias = try r.take(b, la.channels);
            layer1x1 = try Conv1d.init(b, la.bottleneck, la.channels, 1, 1, la.layer1x1.groups, w, bias);
        }
        var head1x1: ?Conv1d = null;
        if (la.head1x1.active) {
            const w = try r.take(b, head1x1_out * la.bottleneck / la.head1x1.groups);
            const bias = try r.take(b, head1x1_out);
            head1x1 = try Conv1d.init(b, la.bottleneck, head1x1_out, 1, 1, la.head1x1.groups, w, bias);
        }
        var films: [8]?FiLM = @splat(null);
        for (la.films, film_dims, &films) |f, input_dim, *slot| {
            if (!f.active) continue;
            const out_rows = if (f.shift) 2 * input_dim else input_dim;
            const w = try r.take(b, out_rows * cond / f.groups);
            const bias = try r.take(b, out_rows);
            slot.* = try FiLM.init(b, cond, input_dim, f.shift, f.groups, w, bias);
        }
        layer.* = .{
            .conv = try Conv1d.init(b, la.channels, mid, k, d, la.groups_input, conv_w, conv_b),
            .mixin = try Conv1d.init(b, cond, mid, 1, 1, la.groups_input_mixin, mix_w, null),
            .layer1x1 = layer1x1,
            .head1x1 = head1x1,
            .films = films,
            .gating = gating,
            .channels = la.channels,
            .bottleneck = la.bottleneck,
            .condition_size = cond,
            .mid = mid,
            .head_contrib_width = head_contrib_width,
            .conv_pre_blk = try b.floats(la.channels * MAX_BLOCK),
            .conv_out_blk = try b.floats(mid * MAX_BLOCK),
            .mix_blk = try b.floats(mid * MAX_BLOCK),
            .mix_pre_blk = try b.floats(cond * MAX_BLOCK),
            .z_blk = try b.floats(mid * MAX_BLOCK),
            .act_blk = try b.floats(la.bottleneck * MAX_BLOCK),
            .act_film_blk = try b.floats(la.bottleneck * MAX_BLOCK),
            .head_contrib_blk = try b.floats(head_contrib_width * MAX_BLOCK),
            .res_blk = try b.floats(la.channels * MAX_BLOCK),
        };
    }

    const head_w = try r.take(b, la.head_size * head_contrib_width * la.head_kernel_size);
    const head_b: ?[]f32 = if (la.head_bias) try r.take(b, la.head_size) else null;
    std.debug.assert(before - r.remaining() == try arrayWeightCount(b, la));

    return .{
        .rechannel = try Conv1d.init(b, la.input_size, la.channels, 1, 1, 1, rechannel_w, null),
        .layers = layers,
        .head_rechannel = try Conv1d.init(b, head_contrib_width, la.head_size, la.head_kernel_size, 1, 1, head_w, head_b),
        .channels = la.channels,
        .head_in = head_contrib_width,
        .head_size = la.head_size,
        .cur_blk = try b.floats(la.channels * MAX_BLOCK),
        .nxt_blk = try b.floats(la.channels * MAX_BLOCK),
        .head_accum_blk = try b.floats(head_contrib_width * MAX_BLOCK),
    };
}

// ─────────────────────────────── LSTM ───────────────────────────────

/// One LSTM layer; gate order i, f, g, o; `W` is `(4H) × (input + H)` row-major.
const LstmCell = struct {
    hidden_size: usize,
    input_size: usize,
    w: []const f32,
    b: []const f32,
    h0: []const f32,
    c0: []const f32,
    h: []f32,
    c: []f32,
    xh: []f32,
    gates: []f32,

    fn process(self: *LstmCell, x: []const f32) []const f32 {
        const h = self.hidden_size;
        const row = self.input_size + h;
        @memcpy(self.xh[0..self.input_size], x);
        @memcpy(self.xh[self.input_size..], self.h);
        for (0..4 * h) |g| {
            const base = g * row;
            var acc = self.b[g];
            for (0..row) |k| acc += self.w[base + k] * self.xh[k];
            self.gates[g] = acc;
        }
        for (0..h) |j| {
            const i = sigmoid(self.gates[j]);
            const f = sigmoid(self.gates[h + j]);
            const g_ = std.math.tanh(self.gates[2 * h + j]);
            const o = sigmoid(self.gates[3 * h + j]);
            const c = f * self.c[j] + i * g_;
            self.c[j] = c;
            self.h[j] = o * std.math.tanh(c);
        }
        return self.h;
    }

    fn reset(self: *LstmCell) void {
        @memcpy(self.h, self.h0);
        @memcpy(self.c, self.c0);
    }
};

/// A ready-to-run LSTM (nam-rs `Lstm`). State starts from the exported initial
/// hidden/cell vectors, not zeros.
pub const Lstm = struct {
    cells: []LstmCell,
    head_w: []const f32,
    head_b: f32,
    buf_a: []f32,
    buf_b: []f32,

    fn build(b: *Builder, model: *const NamModel) Error!*Lstm {
        const cfg = switch (model.config) {
            .lstm => |c| c,
            else => return fail(b.diag, error.UnsupportedArchitecture, "\"{s}\"", .{model.architecture}),
        };
        if (cfg.hidden_size > max_dim or cfg.num_layers > max_layers) return tooLarge(b.diag);
        // nam-rs feeds a one-element input row; any other width would panic there.
        if (cfg.input_size != 1) return fail(b.diag, error.UnsupportedFeature, "LSTM input_size != 1", .{});
        const expected = try lstmWeightCount(b, cfg);
        if (expected != model.weights.len)
            return fail(b.diag, error.WeightCountMismatch, "config implies {d} weights, file has {d}", .{ expected, model.weights.len });

        const h = cfg.hidden_size;
        var r: Reader = .{ .w = model.weights };
        const cells = try b.a.alloc(LstmCell, cfg.num_layers);
        for (cells, 0..) |*cell, layer| {
            const in_dim = if (layer == 0) cfg.input_size else h;
            const w = try r.take(b, 4 * h * (in_dim + h));
            const bias = try r.take(b, 4 * h);
            const h0 = try r.take(b, h);
            const c0 = try r.take(b, h);
            cell.* = .{
                .hidden_size = h,
                .input_size = in_dim,
                .w = w,
                .b = bias,
                .h0 = h0,
                .c0 = c0,
                .h = try b.floats(h),
                .c = try b.floats(h),
                .xh = try b.floats(in_dim + h),
                .gates = try b.floats(4 * h),
            };
            cell.reset();
        }
        const head_w = try r.take(b, h);
        const head_b = (try r.take(b, 1))[0];
        const self = try b.a.create(Lstm);
        self.* = .{
            .cells = cells,
            .head_w = head_w,
            .head_b = head_b,
            .buf_a = try b.floats(@max(h, 1)),
            .buf_b = try b.floats(@max(h, 1)),
        };
        return self;
    }

    pub fn processBuffer(self: *Lstm, io: []f32) void {
        for (io) |*s| s.* = self.processSample(s.*);
    }

    pub fn processSample(self: *Lstm, x: f32) f32 {
        if (self.cells.len == 0) return self.head_b;
        const h = self.cells[0].hidden_size;
        const x0 = [1]f32{x};
        @memcpy(self.buf_a[0..h], self.cells[0].process(&x0));
        for (self.cells[1..]) |*cell| {
            @memcpy(self.buf_b[0..h], cell.process(self.buf_a[0..h]));
            std.mem.swap([]f32, &self.buf_a, &self.buf_b);
        }
        var y = self.head_b;
        for (0..h) |j| y += self.head_w[j] * self.buf_a[j];
        return y;
    }

    pub fn reset(self: *Lstm) void {
        for (self.cells) |*c| c.reset();
        @memset(self.buf_a, 0);
        @memset(self.buf_b, 0);
    }
};

fn lstmWeightCount(b: *Builder, cfg: LstmConfig) Error!usize {
    const c: Counter = .{ .b = b };
    const h = cfg.hidden_size;
    var total: usize = 0;
    for (0..cfg.num_layers) |layer| {
        const in_dim = if (layer == 0) cfg.input_size else h;
        total = try c.add(total, try c.mul(try c.mul(4, h), try c.add(in_dim, h)));
        total = try c.add(total, try c.mul(4, h));
        total = try c.add(total, h);
        total = try c.add(total, h);
    }
    return c.add(try c.add(total, h), 1);
}

// ─────────────────────────────── Slimmable / dispatch ───────────────────────────────

/// A width-selectable set of pre-built submodels (nam-rs `Slimmable`). Switching is a
/// single index write; each submodel keeps its own state.
pub const Slimmable = struct {
    submodels: []Runtime,
    max_values: []f32,
    active: usize,

    pub fn len(self: *const Slimmable) usize {
        return self.submodels.len;
    }

    pub fn isEmpty(self: *const Slimmable) bool {
        return self.submodels.len == 0;
    }

    pub fn activeIndex(self: *const Slimmable) usize {
        return self.active;
    }

    /// Select by index, clamping out-of-range to the last (full) submodel.
    pub fn select(self: *Slimmable, index: usize) void {
        self.active = @min(index, self.submodels.len - 1);
    }

    /// Activate the first submodel whose `max_value` exceeds `value`, else the last.
    pub fn setSlimSize(self: *Slimmable, value: f32) void {
        for (self.max_values, 0..) |m, i| {
            if (m > value) {
                self.active = i;
                return;
            }
        }
        self.active = self.submodels.len - 1;
    }
};

/// A runnable model of any supported architecture (the nam-rs `Model` enum). Owned by
/// a `Model`, which holds the arena; use it through `Model`.
pub const Runtime = union(enum) {
    wave_net: *WaveNet,
    lstm: *Lstm,
    slimmable: *Slimmable,

    fn fromNam(b: *Builder, model: *const NamModel) Error!Runtime {
        switch (model.config) {
            .wave_net => return .{ .wave_net = try WaveNet.build(b, model, false) },
            .lstm => return .{ .lstm = try Lstm.build(b, model) },
            .slimmable => |cfg| {
                if (cfg.submodels.len == 0) return fail(b.diag, error.UnsupportedFeature, "empty SlimmableContainer", .{});
                const s = try b.a.create(Slimmable);
                s.* = .{
                    .submodels = try b.a.alloc(Runtime, cfg.submodels.len),
                    .max_values = try b.a.alloc(f32, cfg.submodels.len),
                    .active = cfg.submodels.len - 1,
                };
                for (cfg.submodels, s.submodels, s.max_values) |*sm, *rt, *mv| {
                    rt.* = try fromNam(b, &sm.model);
                    mv.* = sm.max_value;
                }
                return .{ .slimmable = s };
            },
        }
    }

    fn fromNamConditioning(b: *Builder, model: *const NamModel) Error!Runtime {
        return switch (model.config) {
            .wave_net => .{ .wave_net = try WaveNet.build(b, model, true) },
            else => fromNam(b, model),
        };
    }

    pub fn processBuffer(self: Runtime, io: []f32) void {
        switch (self) {
            .wave_net => |w| w.processBuffer(io),
            .lstm => |l| l.processBuffer(io),
            .slimmable => |s| s.submodels[s.active].processBuffer(io),
        }
    }

    pub fn processSample(self: Runtime, x: f32) f32 {
        return switch (self) {
            .wave_net => |w| w.processSample(x),
            .lstm => |l| l.processSample(x),
            .slimmable => |s| s.submodels[s.active].processSample(x),
        };
    }

    pub fn reset(self: Runtime) void {
        switch (self) {
            .wave_net => |w| w.reset(),
            .lstm => |l| l.reset(),
            .slimmable => |s| for (s.submodels) |m| m.reset(),
        }
    }

    pub fn receptiveField(self: Runtime) usize {
        return switch (self) {
            .wave_net => |w| w.receptive_field,
            .lstm => 0,
            .slimmable => |s| s.submodels[s.active].receptiveField(),
        };
    }

    fn numOutputChannels(self: Runtime) usize {
        return switch (self) {
            .wave_net => |w| w.numOutputChannels(),
            .lstm => 1,
            .slimmable => |s| s.submodels[s.active].numOutputChannels(),
        };
    }

    fn processBlockMulti(self: Runtime, input: []const f32, out: []f32, n: usize) void {
        switch (self) {
            .wave_net => |w| w.processBlockMulti(input, out, n),
            .lstm => |l| {
                @memcpy(out[0..n], input[0..n]);
                l.processBuffer(out[0..n]);
            },
            .slimmable => |s| s.submodels[s.active].processBlockMulti(input, out, n),
        }
    }
};

/// A loaded, runnable model: the runtime, the arena that owns all of its memory, and
/// the sample rate the file expects. Build it off the audio thread; process on it.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    runtime: Runtime,
    /// `NamModel.expectedSampleRate()` of the file it was built from.
    expected_sample_rate: f64,

    /// Build the runtime matching `nam.architecture` (nam-rs `Model::from_nam`). All
    /// allocation happens here; `nam` may be freed afterwards.
    pub fn fromNam(gpa: Allocator, nam: *const NamModel, diag: ?*Diagnostic) Error!*Model {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var b: Builder = .{ .a = arena.allocator(), .diag = diag };
        const runtime = try Runtime.fromNam(&b, nam);
        const self = try b.a.create(Model);
        self.* = .{ .arena = arena, .runtime = runtime, .expected_sample_rate = nam.expectedSampleRate() };
        return self;
    }

    /// Parse `.nam` JSON bytes and build the runtime.
    pub fn loadBytes(gpa: Allocator, json: []const u8, diag: ?*Diagnostic) Error!*Model {
        const parsed = try NamModel.fromJsonStr(gpa, json, diag);
        defer parsed.deinit();
        return fromNam(gpa, &parsed.value, diag);
    }

    /// Read a `.nam` file, parse it and build the runtime.
    pub fn loadFile(gpa: Allocator, io: std.Io, path: []const u8, diag: ?*Diagnostic) Error!*Model {
        const bytes = try readFile(gpa, io, path, diag);
        defer gpa.free(bytes);
        return loadBytes(gpa, bytes, diag);
    }

    /// Free everything the model owns (including `self`).
    pub fn deinit(self: *Model) void {
        var arena = self.arena;
        arena.deinit();
    }

    /// The sample rate in Hz the model expects. The model does not resample.
    pub fn expectedSampleRate(self: *const Model) f64 {
        return self.expected_sample_rate;
    }

    /// Process mono samples in place. Allocation-free; any length (chunked internally).
    pub fn processBuffer(self: *Model, io: []f32) void {
        self.runtime.processBuffer(io);
    }

    /// Process `input` into `output` (the first `min(len)` samples). Allocation-free.
    pub fn process(self: *Model, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        if (input.ptr != output.ptr) @memmove(output[0..n], input[0..n]);
        self.runtime.processBuffer(output[0..n]);
    }

    /// Process one mono sample. Allocation-free.
    pub fn processSample(self: *Model, x: f32) f32 {
        return self.runtime.processSample(x);
    }

    /// Reset all internal state to the model's initial conditions. Allocation-free.
    pub fn reset(self: *Model) void {
        self.runtime.reset();
    }

    /// Processing latency in samples (WaveNet receptive field; 0 for LSTM).
    pub fn receptiveField(self: *const Model) usize {
        return self.runtime.receptiveField();
    }

    /// The width-selectable container, if this model is one.
    pub fn asSlimmable(self: *Model) ?*Slimmable {
        return switch (self.runtime) {
            .slimmable => |s| s,
            else => null,
        };
    }
};

// ─────────────────────────────── tests ───────────────────────────────

const testing = std.testing;
/// Fixtures, read at test time relative to the working directory (run `zig test
/// src/nam.zig` from impl/zig/source; @embedFile cannot reach outside src/):
/// - `input.bin`: 8000 little-endian f32 samples (two sines, LCG noise, an impulse).
/// - `tiny_*.nam`: small models with deterministic LCG weights: a standard two-array
///   A1 WaveNet (plain and gated), an A2 WaveNet exercising gating/blending,
///   bottleneck, grouped convs, head1x1, all eight FiLM sites, multi-tap layer heads
///   and a post-stack head, a WaveNet with a two-output WaveNet `condition_dsp`, and a
///   two-layer LSTM.
/// - `marshall_jcm800.nam`: a real A2 SlimmableContainer capture (two WaveNets).
/// - `<model>.out.bin`: the output of nam-rs 0.4.0 `Model::process_buffer` on
///   `input.bin` (`marshall_jcm800.slim0.out.bin` with submodel 0 selected), written by
///   a throwaway Rust program. The Zig tests never need Rust: the fixtures are data.
const fixture_dir = "testdata/nam/";

fn readFixture(name: []const u8) ![]u8 {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, fixture_dir ++ "{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(max_json_bytes));
}

fn readF32s(name: []const u8) ![]f32 {
    const bytes = try readFixture(name);
    defer testing.allocator.free(bytes);
    const out = try testing.allocator.alloc(f32, bytes.len / 4);
    for (out, 0..) |*v, i| v.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    return out;
}

fn maxAbsDiff(a: []const f32, b: []const f32) f32 {
    var m: f32 = 0;
    for (a, b) |x, y| m = @max(m, @abs(x - y));
    if (std.math.isNan(m)) return std.math.inf(f32);
    return m;
}

const tolerance: f32 = 1e-4;

/// Load `<name>.nam`, run the shared input through it three ways (per sample + odd
/// chunks; one whole-buffer call after `reset`; out-of-place `process`), and compare
/// each with the nam-rs reference output `<ref_name>.out.bin`.
fn differential(name: []const u8, ref_name: []const u8, slim_index: ?usize) !f32 {
    var nb: [128]u8 = undefined;
    const json = try readFixture(try std.fmt.bufPrint(&nb, "{s}.nam", .{name}));
    defer testing.allocator.free(json);
    const input = try readF32s("input.bin");
    defer testing.allocator.free(input);
    const expected = try readF32s(try std.fmt.bufPrint(&nb, "{s}.out.bin", .{ref_name}));
    defer testing.allocator.free(expected);
    try testing.expectEqual(input.len, expected.len);

    var diag: Diagnostic = .{};
    const model = Model.loadBytes(testing.allocator, json, &diag) catch |e| {
        std.debug.print("load {s} failed: {s}\n", .{ name, diag.message() });
        return e;
    };
    defer model.deinit();
    if (slim_index) |i| model.asSlimmable().?.select(i);

    const buf = try testing.allocator.dupe(f32, input);
    defer testing.allocator.free(buf);
    // Per-sample for the first 37 samples, then irregular chunks around MAX_BLOCK.
    var off: usize = 0;
    while (off < 37) : (off += 1) buf[off] = model.processSample(buf[off]);
    const chunks = [_]usize{ 1, 7, 1023, 1024, 1025, 2049 };
    for (chunks) |c| {
        const n = @min(c, buf.len - off);
        model.processBuffer(buf[off .. off + n]);
        off += n;
    }
    model.processBuffer(buf[off..]);
    const d1 = maxAbsDiff(buf, expected);

    model.reset();
    @memcpy(buf, input);
    model.processBuffer(buf);
    const d2 = maxAbsDiff(buf, expected);

    model.reset();
    @memset(buf, 0);
    model.process(input, buf);
    const d3 = maxAbsDiff(buf, expected);

    const d = @max(d1, d2, d3);
    if (d > tolerance) std.debug.print("nam differential {s} (ref {s}): {d} samples, max |zig - nam-rs| = {e}\n", .{ name, ref_name, input.len, d });
    try testing.expect(d <= tolerance);
    return d;
}

test "differential: tiny A1 WaveNet matches nam-rs" {
    _ = try differential("tiny_wavenet_a1", "tiny_wavenet_a1", null);
}

test "differential: tiny gated A1 WaveNet matches nam-rs" {
    _ = try differential("tiny_wavenet_a1_gated", "tiny_wavenet_a1_gated", null);
}

test "differential: tiny A2 WaveNet (gating, FiLM, groups, head1x1, post-stack head) matches nam-rs" {
    _ = try differential("tiny_wavenet_a2", "tiny_wavenet_a2", null);
}

test "differential: WaveNet with a multi-channel condition_dsp matches nam-rs" {
    _ = try differential("tiny_wavenet_condition_dsp", "tiny_wavenet_condition_dsp", null);
}

test "differential: tiny LSTM matches nam-rs" {
    _ = try differential("tiny_lstm", "tiny_lstm", null);
}

test "differential: real A2 SlimmableContainer capture matches nam-rs (full and slim)" {
    _ = try differential("marshall_jcm800", "marshall_jcm800", null);
    _ = try differential("marshall_jcm800", "marshall_jcm800.slim0", 0);
}

test "sample rate, metadata and receptive field" {
    const json = try readFixture("tiny_wavenet_a1.nam");
    defer testing.allocator.free(json);
    const parsed = try NamModel.fromJsonStr(testing.allocator, json, null);
    defer parsed.deinit();
    const nam = &parsed.value;
    try testing.expectEqualStrings("0.5.4", nam.version);
    try testing.expectEqualStrings("WaveNet", nam.architecture);
    try testing.expectEqual(@as(f64, 48000), nam.expectedSampleRate());
    const md = nam.metadataTyped();
    try testing.expectEqualStrings("tiny test", md.name.?);
    try testing.expectEqual(@as(f32, -12.5), md.loudness.?);
    try testing.expectEqual(@as(f32, 12), md.input_level_dbu.?);
    try testing.expectEqual(@as(?f32, null), md.output_level_dbu);
    try testing.expectEqual(@as(u32, 11), md.date.?.month);
    try testing.expectEqual(@as(?bool, true), nam.includesCab());
    const model = try Model.fromNam(testing.allocator, nam, null);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 1 + 2 * (2 * 63)), model.receptiveField());
    try testing.expectEqual(@as(f64, 48000), model.expectedSampleRate());

    const g = try readFixture("tiny_wavenet_a1_gated.nam");
    defer testing.allocator.free(g);
    const gm = try Model.loadBytes(testing.allocator, g, null);
    defer gm.deinit();
    try testing.expectEqual(@as(f64, 44100), gm.expectedSampleRate());

    const m = try readFixture("marshall_jcm800.nam");
    defer testing.allocator.free(m);
    const mp = try NamModel.fromJsonStr(testing.allocator, m, null);
    defer mp.deinit();
    try testing.expectEqual(@as(?bool, false), mp.value.includesCab());
    try testing.expectEqual(@as(usize, 2), mp.value.config.slimmable.submodels.len);
}

test "loadFile reads a model from a path" {
    var diag: Diagnostic = .{};
    const model = try Model.loadFile(testing.allocator, testing.io, fixture_dir ++ "tiny_lstm.nam", &diag);
    defer model.deinit();
    try testing.expect(model.runtime == .lstm);
    try testing.expectEqual(@as(usize, 0), model.receptiveField());
    try testing.expectError(error.Io, Model.loadFile(testing.allocator, testing.io, fixture_dir ++ "missing.nam", &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "failed to read .nam file: "));
}

test "slimmable dial selects like NAM Core" {
    const json = try readFixture("marshall_jcm800.nam");
    defer testing.allocator.free(json);
    const model = try Model.loadBytes(testing.allocator, json, null);
    defer model.deinit();
    const s = model.asSlimmable().?;
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    s.setSlimSize(0.3);
    try testing.expectEqual(@as(usize, 0), s.activeIndex());
    s.setSlimSize(0.5);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    s.setSlimSize(7);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    s.select(99);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
}

test "crate doc example: one-layer ReLU WaveNet doubles its input" {
    const json =
        \\{"version": "0.5.4", "architecture": "WaveNet",
        \\ "config": {"layers": [{"input_size": 1, "condition_size": 1, "channels": 1, "head_size": 1,
        \\   "kernel_size": 1, "dilations": [1], "activation": "ReLU", "gated": false, "head_bias": false}],
        \\   "head": null, "head_scale": 1.0},
        \\ "weights": [1.0, 2.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0]}
    ;
    const model = try Model.loadBytes(testing.allocator, json, null);
    defer model.deinit();
    var buf = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    model.processBuffer(&buf);
    for (buf, [_]f32{ 0.2, 0.4, 0.6, 0.8 }) |got, want| try testing.expectApproxEqAbs(want, got, 1e-7);
    try testing.expectEqual(DEFAULT_SAMPLE_RATE, model.expectedSampleRate());
}

test "processing does not allocate" {
    // Every fixture is built with a counting allocator; processing after the build
    // must leave the allocation count unchanged.
    const names = [_][]const u8{ "tiny_wavenet_a1.nam", "tiny_wavenet_a2.nam", "tiny_wavenet_condition_dsp.nam", "tiny_lstm.nam", "marshall_jcm800.nam" };
    for (names) |name| {
        const json = try readFixture(name);
        defer testing.allocator.free(json);
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const model = try Model.loadBytes(failing.allocator(), json, null);
        const allocs = failing.allocations;
        var buf: [3000]f32 = undefined;
        for (&buf, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.01);
        model.processBuffer(&buf);
        _ = model.processSample(0.5);
        model.reset();
        try testing.expectEqual(allocs, failing.allocations);
        model.deinit();
    }
}

fn expectLoadError(expected: Error, json: []const u8) !void {
    var diag: Diagnostic = .{};
    if (Model.loadBytes(testing.allocator, json, &diag)) |m| {
        m.deinit();
        std.debug.print("expected {s} for: {s}\n", .{ @errorName(expected), json });
        return error.TestExpectedError;
    } else |e| {
        if (e != expected) std.debug.print("got {s} ({s}) for: {s}\n", .{ @errorName(e), diag.message(), json });
        try testing.expectEqual(expected, e);
        try testing.expect(diag.len > 0);
    }
}

const one_layer_prefix =
    \\{"version":"0.5.4","architecture":"WaveNet","config":{"layers":[{"input_size":1,"condition_size":1,
;

test "malformed and oversized inputs are rejected, never a crash" {
    try expectLoadError(error.Json, "");
    try expectLoadError(error.Json, "{");
    try expectLoadError(error.Json, "[1,2,3]");
    try expectLoadError(error.Json, "{\"version\":\"1\"}");
    try expectLoadError(error.Json, "{\"version\":\"1\",\"architecture\":\"Transformer\",\"config\":{},\"weights\":[]}");
    try expectLoadError(error.Json, "{\"version\":1,\"architecture\":\"LSTM\",\"config\":{},\"weights\":[]}");
    try expectLoadError(error.Json, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":-2,\"num_layers\":1},\"weights\":[]}");
    try expectLoadError(error.Json, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":2,\"num_layers\":1},\"weights\":[\"x\"]}");
    try expectLoadError(error.Json, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":2.5,\"num_layers\":1},\"weights\":[]}");
    try expectLoadError(error.Json, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":2,\"num_layers\":1},\"weights\":[1e999]}");
    // Weight count disagrees with the architecture (needs 2*4*... = 43 for H=2,L=1).
    try expectLoadError(error.WeightCountMismatch, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":2,\"num_layers\":1},\"weights\":[1,2,3]}");
    try expectLoadError(error.UnsupportedFeature, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":2,\"hidden_size\":2,\"num_layers\":1},\"weights\":[]}");
    try expectLoadError(error.ConfigTooLarge, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":1000000000,\"num_layers\":1},\"weights\":[]}");
    try expectLoadError(error.ConfigTooLarge, "{\"version\":\"1\",\"architecture\":\"LSTM\",\"config\":{\"input_size\":1,\"hidden_size\":18446744073709551615,\"num_layers\":1},\"weights\":[]}");
    try expectLoadError(error.UnsupportedFeature, "{\"version\":\"1\",\"architecture\":\"SlimmableContainer\",\"config\":{\"submodels\":[]},\"weights\":[]}");

    // WaveNet: one-layer doc model with one field changed at a time.
    const tail = "\"head\":null,\"head_scale\":1.0},\"weights\":[1,2,0,0,1,0,1,1]}";
    try expectLoadError(error.WeightCountMismatch, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ "\"head\":null,\"head_scale\":1.0},\"weights\":[1,2,0,0,1,0,1]}");
    try expectLoadError(error.UnsupportedActivation, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"Swish\"}]," ++ tail);
    try expectLoadError(error.UnsupportedFeature, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":[[\"Tanh\"]]}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"kernel_sizes\":[1],\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":0,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":0,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[0],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\",\"groups_input\":0}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\",\"gating_mode\":\"wat\"}]," ++ tail);
    try expectLoadError(error.Json, one_layer_prefix ++ "\"channels\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.UnsupportedFeature, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1,1],\"activation\":\"ReLU\",\"gating_mode\":[\"none\",\"gated\"]}]," ++ tail);
    try expectLoadError(error.UnsupportedFeature, one_layer_prefix ++ "\"channels\":1,\"head_size\":2,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.UnsupportedFeature, one_layer_prefix ++ "\"channels\":2,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\",\"groups_input\":3}]," ++ tail);
    // Would make nam-rs index out of bounds: more input or conditioning rows than exist.
    try expectLoadError(error.UnsupportedFeature, "{\"version\":\"0.5.4\",\"architecture\":\"WaveNet\",\"config\":{\"layers\":[{\"input_size\":2,\"condition_size\":1,\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.UnsupportedFeature, "{\"version\":\"0.5.4\",\"architecture\":\"WaveNet\",\"config\":{\"layers\":[{\"input_size\":1,\"condition_size\":2,\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.UnsupportedFeature, "{\"version\":\"0.5.4\",\"architecture\":\"WaveNet\",\"config\":{\"layers\":[],\"head_scale\":1.0},\"weights\":[1]}");
    try expectLoadError(error.UnsupportedFeature, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}],\"in_channels\":2," ++ tail);
    try expectLoadError(error.UnsupportedFeature, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}],\"head\":{\"channels\":1,\"out_channels\":1,\"kernel_sizes\":[0],\"activation\":\"Tanh\"},\"head_scale\":1.0},\"weights\":[1]}");
    // Absurd sizes: huge dilation/kernel/channels and an overflowing product.
    try expectLoadError(error.ConfigTooLarge, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":2,\"dilations\":[1000000000000],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.ConfigTooLarge, one_layer_prefix ++ "\"channels\":1,\"head_size\":1,\"kernel_size\":99999999,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    try expectLoadError(error.ConfigTooLarge, one_layer_prefix ++ "\"channels\":4611686018427387904,\"head_size\":1,\"kernel_size\":1,\"dilations\":[1],\"activation\":\"ReLU\"}]," ++ tail);
    // Oversized document.
    const big = try testing.allocator.alloc(u8, max_json_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try expectLoadError(error.ConfigTooLarge, big);
    // Nesting deeper than max_nesting.
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(testing.allocator);
    for (0..max_nesting + 2) |_| try nested.appendSlice(testing.allocator, "{\"version\":\"1\",\"architecture\":\"SlimmableContainer\",\"weights\":[],\"config\":{\"submodels\":[{\"max_value\":1,\"model\":");
    try nested.appendSlice(testing.allocator, "{}");
    for (0..max_nesting + 2) |_| try nested.appendSlice(testing.allocator, "}]}}");
    try expectLoadError(error.UnsupportedFeature, nested.items);
}

test "layer-array normalization follows nam-rs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = one_layer_prefix ++
        \\"channels":2,"kernel_size":3,"dilations":[1,2,4],"activation":"Tanh","head_size":1}],
        \\"head":null,"head_scale":2.0},"weights":[]}
    ;
    const nam = try NamModel.parseLeaky(arena.allocator(), json, null);
    const la = nam.config.wave_net.layers[0];
    try testing.expectEqual(@as(usize, 2), la.bottleneck);
    try testing.expectEqualSlices(usize, &.{ 3, 3, 3 }, la.kernel_sizes);
    try testing.expectEqual(GatingMode.none, la.gatingMode());
    try testing.expectEqual(@as(usize, 1), la.head_kernel_size);
    try testing.expect(!la.head_bias);
    try testing.expect(la.layer1x1.active);
    try testing.expect(!la.head1x1.active);
    try testing.expectEqual(FilmConfig.INACTIVE, la.films[0]);
    try testing.expectEqualStrings("Tanh", la.activations[2].named.name);
    try testing.expectEqualStrings("Sigmoid", la.secondary_activations[0].named.name);
    try testing.expectEqual(@as(f32, 2.0), nam.config.wave_net.head_scale);

    try testing.expectEqual(FilmConfig.INACTIVE, FilmConfig.fromValue(null));
    try testing.expectEqual(FilmConfig.INACTIVE, FilmConfig.fromValue(.{ .bool = false }));
    try testing.expectEqual(FilmConfig{ .active = true, .shift = true, .groups = 1 }, FilmConfig.fromValue(.{ .bool = true }));
    try testing.expectEqual(GatingMode.blended, GatingMode.fromName("blended").?);
    try testing.expectEqual(@as(?GatingMode, null), GatingMode.fromName("wat"));
}

test "includesCab follows nam-rs" {
    const cases = [_]struct { ?[]const u8, ?bool }{
        .{ null, null },        .{ "amp", false },   .{ " Pedal_Amp ", false },
        .{ "outboard", false }, .{ "space", false }, .{ "amp_cab", true },
        .{ "amp-cab", true },   .{ "CAB", true },    .{ "amp_pedal_cab", true },
        .{ "full-rig", true },  .{ "ir", true },     .{ "cable", null },
        .{ "cabless", null },   .{ "studio", null }, .{ "experimental", null },
    };
    for (cases) |c| {
        const md: Metadata = .{ .gear_type = c[0] };
        try testing.expectEqual(c[1], md.includesCab());
    }
}

test "fuzz: truncated and mutated fixtures never crash" {
    const json = try readFixture("tiny_wavenet_a2.nam");
    defer testing.allocator.free(json);
    const buf = try testing.allocator.dupe(u8, json);
    defer testing.allocator.free(buf);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var cut: usize = 0;
    while (cut < json.len) : (cut += 97) {
        if (Model.loadBytes(testing.allocator, json[0..cut], null)) |m| m.deinit() else |_| {}
    }
    const alphabet = "0123456789-.e,:[]{}\" tfnul";
    var samples: [256]f32 = undefined;
    for (0..300) |_| {
        @memcpy(buf, json);
        for (0..1 + rand.uintLessThan(usize, 4)) |_| {
            buf[rand.uintLessThan(usize, buf.len)] = alphabet[rand.uintLessThan(usize, alphabet.len)];
        }
        if (Model.loadBytes(testing.allocator, buf, null)) |m| {
            for (&samples, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i % 17)) * 0.05 - 0.4;
            m.processBuffer(&samples);
            m.deinit();
        } else |_| {}
    }
}

test "ReleaseFast timing: 48000 samples through each fixture" {
    // Three ways: one processBuffer call (MAX_BLOCK chunks), 256-frame callbacks, and
    // processSample per sample (as the maqam-live audio callback does).
    const names = [_][]const u8{ "tiny_wavenet_a1", "tiny_wavenet_a1_gated", "tiny_wavenet_a2", "tiny_wavenet_condition_dsp", "tiny_lstm", "marshall_jcm800" };
    const buf = try testing.allocator.alloc(f32, 48000);
    defer testing.allocator.free(buf);
    for (names) |name| {
        var nb: [128]u8 = undefined;
        const json = try readFixture(try std.fmt.bufPrint(&nb, "{s}.nam", .{name}));
        defer testing.allocator.free(json);
        const model = try Model.loadBytes(testing.allocator, json, null);
        defer model.deinit();
        var ms: [3]f64 = undefined;
        for (&ms, 0..) |*m, mode| {
            model.reset();
            for (buf, 0..) |*v, i| v.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.0144);
            const t0 = std.Io.Timestamp.now(testing.io, .awake);
            switch (mode) {
                0 => model.processBuffer(buf),
                1 => {
                    var off: usize = 0;
                    while (off < buf.len) : (off += 256) model.processBuffer(buf[off..@min(off + 256, buf.len)]);
                },
                else => for (buf) |*v| {
                    v.* = model.processSample(v.*);
                },
            }
            const ns = t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).nanoseconds;
            m.* = @as(f64, @floatFromInt(ns)) / 1e6;
        }
        if (@import("builtin").mode == .fast) std.debug.print("nam timing ({s}) {s}: 48000 samples in {d:.2} ms (one call), {d:.2} ms (256-frame blocks), {d:.2} ms (per sample)\n", .{ @tagName(@import("builtin").mode), name, ms[0], ms[1], ms[2] });
    }
}
