# Zig 0.13 → 0.16 migration plan

**Date:** 26 September 2026
**Decision:** Move Delia to Zig 0.16.0 (system compiler) and remove JACK as a dependency. This is milestone M0 of `DELIA_REFACTOR_PLAN.md`: the goal is a green `zig build test` on 0.16 with behaviour unchanged, not a refactor. Structural changes wait until the baseline is green.

## How this list was produced

Each subsystem was compiled under 0.16 with a throwaway test root (`refAllDecls` over every file) so the errors below are what the compiler actually reports on the first pass. Later passes will surface more once the first errors are fixed; the "known but not yet reported" section lists what will appear next, verified against the 0.16 std source in `/usr/lib/zig/std`.

Baseline: last successful build was Zig 0.13.0 (`zig-out/bin/audio_engine_proto`). Current source is 13k lines excluding `src/backends/jack/`.

## Tools

- `zig ast-check <file>` parses one file with no build wiring and reports syntax and AST-level errors (duplicate names, undeclared identifiers, deprecated syntax). It cannot see std API changes, but it is the first gate for every file: run it over the whole tree before and after each step. On 26 Sep 2026 it reports only the `audio_data.zig` `T` shadowing and the dead scratch files.

  ```sh
  for f in $(find src -name '*.zig'); do zig ast-check "$f" || echo "^ $f"; done
  ```

- `zig test <file>` for files with no `../` imports (`common/`, `dsp/filters/iir.zig`, `graph/bitmap.zig`, `logging.zig`). A file with parent-directory imports must be tested through a root under `src/` (or `zig build test` once Step 1 lands), because `zig test` makes the given file the module root.
- `zig build check` once Step 1 is done; it is what zls build-on-save uses.

## Status (26 Sep 2026)

Steps 1–8 are done on branch `zig-0.16`: `zig build check`, `zig build test` (114 tests), `zig build bench` and `zig build run` all succeed on 0.16.0. Step 9 (`python.zig`) is not started. The hardware check (`playbackSineWave` producing audio) has not been run.

Corrections found while doing the work are marked **Correction** below.

## Order of work

Do it bottom-up so each layer's tests pass before the next layer is touched. Commit after each step.

1. **Build files** (`build.zig.zon`, `build.zig`). Nothing compiles until this is done.
2. **Delete JACK** (`src/backends/jack/`, `vendor/jack` submodule, JACK branches in `build.zig`, `jack` entries in `backends.zig`, `logging.zig`, `main.zig`).
3. **Delete dead scratch** that is unreachable and would only add noise: `src/temp.zig`, `src/backends/alsa/ref_deleme.zig`, `src/backends/alsa/audio_loop.zig` (imports a nonexistent `device.zig`), `src/graph/audio_graph.zig` (empty), `src/backends/alsa/MixerInfo.zig` (uses `snd_mixer_ctl_t`, which does not exist in the ALSA headers; not exported from `alsa.zig`), `src/root.zig` (template leftover).
4. **`common/` + `logging.zig`** (small, everything depends on them).
5. **`dsp/`** (one file blocks it: `complex_matrix.zig`).
6. **`graph/`**.
7. **`backends/alsa/`** (largest share of the work).
8. **Entry points**: `main.zig`, `examples.zig`, `benchmarks.zig`.
9. **`python.zig`** last, and only if the notebooks are still wanted on 0.16. It is not part of `zig build`.

## Step 1: build files — DONE (26 Sep 2026)

`build.zig.zon`: name `.delia`, fingerprint `0x692f92c535f6f9e8`, `minimum_zig_version = "0.16.0"`, zBench pinned to **v0.13.0** (the last release targeting 0.16; v0.14.x and `main` require 0.17-dev). `zig fetch --save` refuses to parse a manifest that still contains an old-format hash, so the old entry had to be removed before fetching.

`build.zig`: one shared root module for `run`/`check`/`test`, ALSA linked on the module, JACK and the `audio_backend` options module removed, `-Dtest-filter` added, artifacts renamed `delia`/`delia_check`/`delia_bench`. `std.fs.accessAbsolute` no longer exists in build scripts; the libasound existence check is now `b.build_root.handle.access(b.graph.io, rel_path, .{})`.

`zig build test` now gets through the build script and reports the first two source errors: `audio_data.zig` `T` shadowing and `refAllDeclsRecursive` in `main.zig`. `main.zig` will next fail on `@import("audio_backend")` and `backends.jack` (Step 2).

The original shapes, kept for reference:

`build.zig.zon` (0.16 shape, from `zig init`):

```zig
.{
    .name = .delia,                       // enum literal, no longer a string
    .version = "0.0.0",
    .fingerprint = 0x...,                 // run `zig build` once; the compiler prints the value to paste
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zbench = .{ .url = "...", .hash = "..." },   // re-fetch: the old hash format is rejected
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

zBench must be bumped to a release that supports 0.16; run `zig fetch --save <url>` to get the new hash format.

`build.zig`: every `addExecutable`/`addTest` now takes `.root_module = b.createModule(...)` instead of `.root_source_file`/`.target`/`.optimize`. Include paths, object files, libc and options attach to the module, not the compile step:

```zig
const mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
mod.addIncludePath(alsa.joinIncludePath(b));
mod.addObjectFile(alsa.joinLibPath(b));
mod.link_libc = true;

const exe = b.addExecutable(.{ .name = "delia", .root_module = mod });
const tests = b.addTest(.{ .root_module = mod });
```

Because `exe`, `check`, and `tests` all share one root, build one module and reuse it for all three instead of repeating the ALSA wiring three times. Drop `AudioBackend`, `detectLinuxAudioBackend`, and the `audio_backend` options module entirely with JACK.

While here: add `-Dtest-filter` support (`b.option([]const []const u8, "test-filter", ...)` → `tests.filters`) so single tests can run through `zig build test`.

## Step 4–8: source changes, grouped by API

Counts are occurrences outside `jack/` and the dead files above.

### Containers: `std.ArrayList` is now unmanaged (≈30 declarations, ≈26 `.init(allocator)` calls)

Files: `graph/graph.zig` (9), `backends/alsa/Hardware.zig` (8), `SupportedSettings.zig` (8), `AudioCard.zig` (5), `MultiArrayList` in `graph.zig` (2, already unmanaged; unaffected).

```zig
// 0.13                                          // 0.16
var l = std.ArrayList(T).init(allocator);        var l: std.ArrayList(T) = .empty;
try l.append(x);                                 try l.append(allocator, x);
l.deinit();                                      l.deinit(allocator);
try l.resize(n);                                 try l.resize(allocator, n);
l.pop()   // returns T                           l.pop()   // returns ?T
```

**Correction:** `TopologyQueue.analyzeBufferRequirementsAlloc` needed no change at its `free_buffers.pop()`: the destination field is `?usize`, so the `?T` return assigns directly.

`SupportedSettings` had no allocator and a by-value `deinit`; it is now `deinit(self: *SupportedSettings, allocator)`, and `AudioCardInfo.deinit` takes `*AudioCardInfo`. `std.ArrayListUnmanaged` is an alias and still works, so mechanically replacing `ArrayList(T).init(a)` with `ArrayListUnmanaged(T){}` is an acceptable intermediate step; rename to `ArrayList` at the end.

### `@typeInfo` tags are lowercase (17 sites)

Files: `backends/alsa/settings.zig` (12), `dsp/complex_matrix.zig` (3+, line 151 is a `switch` on `.Int`), `graph/nodes/node_interface.zig` (2, `.Pointer`, and `ptr_info.Pointer.size != .One` → `ptr_info.pointer.size != .one`).

`.Int → .int`, `.Float → .float`, `.Enum → .@"enum"`, `.Struct → .@"struct"`, `.Pointer → .pointer`, `.Optional → .optional`, `.Array → .array`, `.Vector → .vector`, `.Fn → .@"fn"`, `.ComptimeInt → .comptime_int`, `.Bool → .bool`.

### Custom `format` methods (6 sites) and `{any}` on those types (7 call sites)

Files: `Hardware.zig`, `AudioCard.zig` (2), `format.zig`, `SupportedSettings.zig`, `driver.zig`.

`std.fmt.FormatOptions` is gone. New signature and it is only invoked through the `{f}` specifier:

```zig
pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void { ... }
// callers: log.info("{f}", .{hardware});   not {any} or {s}
```

Inside, `writer.print(...)`, `writer.writeAll(...)` are unchanged. Enum tags print with `{t}` instead of `@tagName(x)` + `{s}` (the old form still compiles and was left alone).

**Correction:** `{}` and `{any}` on a type with a `format` method compile but print a field dump instead of calling `format`; `{s}` and `{d}` on such a type are compile errors. `{!}` on a caught error value is also a compile error; those sites now use `{t}`.

### Allocators (20 sites)

`std.heap.GeneralPurposeAllocator(.{})` → `std.heap.DebugAllocator(.{})` (`alsa/examples/examples.zig` ×10, `python.zig` ×6, `main.zig`). `page_allocator` and `FixedBufferAllocator` are unchanged. In tests keep `std.testing.allocator`.

### Logging (`src/logging.zig`, and `std_options` in 3 roots)

- `pub const std_options = .{...}` → `pub const std_options: std.Options = .{...}`.
- `logFn` scope parameter: `comptime scope: @TypeOf(.EnumLiteral)` → `comptime scope: @EnumLiteral()`.
- `std.debug.lockStdErr()` / `std.io.getStdErr().writer()` → `std.debug.lockStderr(&buf)` returns a `LockedStderr`; use `.terminal()` (or its writer) and `std.debug.unlockStderr()`. Simplest: copy the body of `std.log.defaultLogFileTerminal` from `/usr/lib/zig/std/log.zig` and keep the scope filter + ANSI colour on top.

### `std.mem.split` → `std.mem.splitScalar` / `splitSequence` (Hardware.zig:113)

### Sleeping (`driver.zig`, 2 sites via `std.time.sleep`)

There is no `std.time.sleep` or `std.Thread.sleep`. Sleeping goes through an `Io`: `std.Io.sleep(io, duration, clock)`. The ALSA driver has no `Io` in scope. **Correction:** `std.posix.nanosleep` and `std.c.usleep` do not exist in 0.16 either. The driver uses `sleepNs` in `backends/alsa/utils.zig`, built on `std.c.nanosleep` via the existing libc link, which keeps it free of the `Io` plumbing until the realtime layer decides how it wants it.

### Files and writers (`graph.zig:debugGraph`, `benchmarks.zig`)

`std.fs.cwd().createFile(path, .{})` now needs an `Io` (`std.Io.Dir.cwd().createFile(io, path, .{})`) and `file.writer()` needs `(io, &buffer)`. `debugGraph` is a debugging aid; give it an `io: std.Io` parameter and take it from `std.testing.io` in tests. `benchmarks.zig` gets `io` from `main(init: std.process.Init)` (`init.io`). **Correction:** zBench v0.13.0 takes the file itself, `bench.run(init.io, std.Io.File.stdout())`; no writer or `flush()`.

### Entry points (`main.zig`, `benchmarks.zig`)

`pub fn main() !void` still works, but the 0.16 idiom is `pub fn main(init: std.process.Init) !void`, which hands you `init.gpa`, `init.arena`, and `init.io`. Use it in `benchmarks.zig` (it needs `io`), keep `main.zig` minimal.

### Test aggregation (`main.zig`)

`std.testing.refAllDeclsRecursive` no longer exists. Done with `test { _ = module; }` blocks in each aggregator (`main.zig`, `dsp.zig`, `graph.zig`, `nodes.zig`, `backends.zig`, `alsa.zig`). Note `refAllDecls` is not recursive: nested types must be listed explicitly or referenced from a test.

### `callconv(.C)` → `callconv(.c)` (11 sites, all in `python.zig`)

### Misc, one-offs

- `backends/alsa/audio_data.zig:19,26`: a field and a decl are both named `T`; 0.16 rejects the shadowing. The unused `comptime T` field was deleted.
- `driver.zig`: `snd_pcm_mmap_begin` now translates its `areas` parameter as `[*c][*c]const`, so the area pointers are `?*const snd_pcm_channel_area_t`.
- `dsp/analysis.zig` and `dsp/transforms.zig`: the `[N]u8` scratch buffers behind `FixedBufferAllocator` relied on the buffer happening to be aligned for `T`; under 0.16 the STFT test failed with `OutOfMemory`. Both now declare `align(@alignOf(T))`.
- `driver.zig:1323` and `examples.zig:76` looped `for (n)` over an integer (never analysed before); now `for (0..n)`.
- Not fixed, pre-existing: `src/examples.zig` `Example.deinit` calls `device.deinit()` twice; `dsp/utils.zig:26,79` call `std.math.pow` without the type argument in functions nothing calls; `dsp/filters/iir.zig` is unfinished and unreachable.
- `src/utils/utils.zig`, `dsp/analysis.zig`, `dsp/test_data.zig`: no first-pass errors, but re-check after `format` changes.
- `@cImport` still works in 0.16 (the ALSA probe translated `asoundlib.h` fine).
- `std.math.Complex`, `std.atomic.Value`, `std.MultiArrayList`, `std.mem.span`, `@Vector`, `std.debug.print`: unchanged.

## Step 9: `python.zig`

Not part of `zig build`; built by `pydelia-build/builder.py` with `zig build-lib`. Changes: `callconv(.c)` ×11, `DebugAllocator` ×6, `std_options` type. The hardcoded conda include path (`/home/pedro/.conda/envs/audio_engine/include/python3.12/Python.h`) should become an `-I` flag from `builder.py`. Decide whether to keep the bindings at all before spending time here; the plan's analysis layer may supersede them.

## Verification

- `zig build check` clean.
- `zig build test` green with the same test count as the 0.13 baseline (record the count first: run the old binary's tests if a 0.13 toolchain is briefly available, otherwise count `test "` declarations in reachable files).
- `zig build bench` runs and numbers are within noise of `bench.txt` (record compiler version and optimize mode in `bench.txt`).
- `zig build run` with one ALSA example (`playbackSineWave`) produces audio. This is the only hardware check; it confirms the static libasound link and the MMAP path survived.
- `zig ast-check` clean over the whole tree.

## Out of scope for this migration

Renaming buffer types, splitting FFT plan/workspace, compiling the graph, ALSA transfer invariants. Those are M1–M4. Keeping this step mechanical is what makes the diff reviewable.
