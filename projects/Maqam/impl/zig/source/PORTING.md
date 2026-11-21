# Porting maqam-live from Rust to Zig: conventions

The Zig implementation realizes the same specification (`../../../spec/Requirements.lean`) as the
Rust one in `../../rust/source/`. The Rust is the reference for behavior: port it faithfully, then
the Zig stands alone (it never builds, links or reads anything under `impl/rust/`).

Toolchain: Zig 0.17.1. Notable differences from older Zig:

* `@cImport` does not exist. C headers are translated in `build.zig` (`b.addTranslateC`) and
  imported as modules (`@import("alsa")`, Linux only). Only the audio device modules use C; the
  few CoreAudio and Mach declarations macOS needs are written by hand in `coreaudio.zig` and
  `realtime.zig` instead of translating the SDK headers.
* Platform code branches on `builtin.os.tag` at compile time; `device.Output` is the live device
  of the target (`device.Alsa` on Linux, `coreaudio.CoreAudio` on macOS).
* `std.ArrayList(T)` is unmanaged: `var l: std.ArrayList(T) = .empty; try l.append(gpa, x); l.deinit(gpa);`
  The same for `std.StringHashMapUnmanaged`, `std.AutoHashMapUnmanaged`.
* Files and processes go through `std.Io` (`std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`,
  `writeFile(io, .{ .sub_path, .data })`, `std.process.run(gpa, io, .{ .argv })`).
  `main` is `pub fn main(init: std.process.Init) !void` (`init.io`, `init.gpa`, `init.environ_map`).
* `std.Io.Mutex` needs an `Io`; pure modules use `util.SpinLock` for shared state instead.

Naming, so modules written separately fit together:

* Types keep their Rust names (`Phrase`, `VcfSettings`, `FxProcessor`, `Maqam`, `Pitch`).
* Functions are the camelCase of the Rust name (`snap_to_oud_lattice` -> `snapToOudLattice`,
  `Maqam::list_custom` -> `Maqam.listCustom`).
* Struct fields keep their Rust snake_case names.
* Rust enums with data become tagged unions; variants become snake_case (`AudioCmd::SetBpm` ->
  `.set_bpm`). Plain enums the same.
* A function that allocates takes `gpa: std.mem.Allocator` as its first parameter (after `self`).
  Returned slices are owned by the caller unless the doc comment says otherwise.
* Rust `Result<T, String>` with an observable message becomes a result union
  `union(enum) { ok: T, err: []const u8 }` (the message text is identical to the Rust, since a
  performer sees it); internal errors are Zig errors.

Behavior: constants, ranges, defaults, messages and help text are copied exactly; the
specification's ranges section (spec/Requirements.lean, markdown "ranges") is authoritative where
the Rust disagrees with itself. A known Rust panic is not copied: return the rejection instead
(the specification forbids a crash on any input).

Tests: every Rust `#[test]` of a ported module is ported next to the code (`test "..." {}`), and
each module is testable alone with `zig test src/<module>.zig`. `zig build test` runs them all.
