//! Every module's tests, for `zig build test`. A module is listed here once it lands.
test {
    _ = @import("util.zig");
    _ = @import("channel.zig");
    _ = @import("eventlog.zig");
    _ = @import("wav.zig");
    _ = @import("term.zig");
    _ = @import("net.zig");
    _ = @import("device.zig");
    _ = @import("realtime.zig");
    _ = @import("coreaudio.zig");
    _ = @import("tuning.zig");
    _ = @import("fx.zig");
    _ = @import("vcf.zig");
    _ = @import("analog.zig");
    _ = @import("sympathetics.zig");
    _ = @import("nam.zig");
    _ = @import("command.zig");
    _ = @import("synth.zig");
    _ = @import("sequencer.zig");
    _ = @import("session.zig");
    _ = @import("shared.zig");
    _ = @import("audio.zig");
    _ = @import("png.zig");
    _ = @import("carpet.zig");
    _ = @import("record.zig");
    _ = @import("app.zig");
    _ = @import("ui.zig");
    _ = @import("main.zig");
}
