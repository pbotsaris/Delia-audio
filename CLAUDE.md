# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Delia is a Zig DSP library and realtime audio runtime, built as a learning project (DSP, realtime systems, memory design, optimization). It has a convenient allocating "analysis" layer (used from Python notebooks) and a realtime layer (graph + device backends) that must not allocate while rendering. Both are meant to share the same numerical kernels.

**Read `docs/DELIA_REFACTOR_PLAN.md` before proposing structural changes.** It is the agreed architecture and roadmap. Key rules from it:

- Separate owning storage, borrowed views, numerical kernels, and convenience APIs. Ownership and cost must be visible; helpers are fine, hidden allocation/resizing/logging in hot loops is not.
- Separate preparation (validate, allocate, build tables, negotiate formats) from processing (execute over prepared state). Nothing in the render path allocates, locks, logs synchronously, or waits on another thread.
- Migrate one subsystem at a time with comparison tests. No repo-wide rename, no rewrite from scratch. Old implementations stay until the replacement is proven, but they are not treated as correctness oracles.
- Initial scope: planar `f32` graph audio, single render thread, acyclic graph, declared max block size, one clock domain. Reject unsupported configs explicitly.
- Linux backend is direct ALSA. JACK or PipeWire interop is optional future work, not a dependency. A Delia-owned server comes later, on top of the engine.
- Milestones M0..M7 (baseline, buffer contracts, planned FFT, offline graph slice, backend integration, control/plan replacement, measured optimization, server). The immediate next work is **ownership and execution contracts**, not SIMD.
- Working order is M1, M3, M4, M2. M0, M1 and M3 are done; M4a (ALSA playback on the new graph) is in progress: the backend code is in and tested on the `null` plugin, `src/examples.zig` and the documented `hw:` run are still owed. Then M4b (scripted-PCM tests), M4c (full duplex), M2 (planned scalar FFT).

## Toolchain

Target is **Zig 0.16.0** (the system compiler). The migration from 0.13 is complete, including `src/python.zig` (`docs/ZIG_016_MIGRATION.md` is the log). Do not pin or install 0.13; write all new code against 0.16 std (unmanaged `ArrayList`, `std.Io` writers, `{f}` custom formatters, `callconv(.c)`, lowercase `@typeInfo` tags, `DebugAllocator`).

**JACK has been removed** (`src/backends/jack/`, the `vendor/jack` submodule, the JACK detection in `build.zig`). Do not reintroduce it; the last JACK code is in git history before the `remove jack backend` commit.

## Build and test commands

The `vendor/alsa` submodule (alsa-lib, built statically) must be present (`git submodule update --init`).

```sh
zig build                          # first run configures+makes vendor/alsa (needs autotools/make)
zig build run                      # runs src/main.zig (scratch entry point; currently the offline graph example)
zig build check                    # compile-only; this is what zls build-on-save uses (zls.json)
zig build test                     # all tests
zig build test -Dtest-filter=FFT   # only tests whose name contains the string (repeatable)
zig build bench                    # zbench microbenchmarks in src/benchmarks.zig (compare with bench.txt)
```

ALSA is linked statically from `vendor/alsa/src/.libs/libasound.a`, built on first `zig build` from the submodule; it is attached to the `alsa` module only. zBench is pinned to v0.13.0, the last release that targets Zig 0.16.

### Modules

Every subsystem is a named module declared in `build.zig`, and files import across folders by module name, never by relative path:

| module | root file | imports |
|---|---|---|
| `buffer` | `src/core/buffer/root.zig` | — |
| `utils` | `src/utils/root.zig` | — |
| `common` | `src/common/root.zig` (`audio_specs`) | — |
| `dsp` | `src/dsp/dsp.zig` | `common` |
| `graph` | `src/graph/root.zig` | `buffer`, `common` |
| `alsa` | `src/backends/alsa/root.zig` | `buffer` (+ ALSA) |
| `backends` | `src/backends/root.zig` | `alsa` |
| root | `src/main.zig` | all of the above |

`utils` currently has no importer besides root; it stays as a leaf module with its own tests.

So `src/graph/plan.zig` writes `const buffer = @import("buffer");` and `const specs = @import("common").audio_specs;`. Within a module, sibling files are still imported by relative path (`@import("node.zig")`, `@import("nodes/root.zig")`). Two compiler rules make the table the real dependency graph: a file belongs to exactly one module, and a module may only import files under its root's directory. A new cross-module edge is therefore a `addImport` line in `build.zig`, and a cycle is a compile error. `root.zig` is the module-root filename by convention (what `zig init` uses); nothing depends on the name.

### Tests

The test runner only collects `test` blocks from the files of the module it is given, so `build.zig` emits one test binary per module (`test_buffer`, `test_graph`, ..., `test_root`) and `zig build test` runs them all; `-Dtest-filter` applies to each. Within a module, tests are aggregated through explicit `test { _ = file; }` blocks in the module root (0.16 has no `refAllDeclsRecursive`), so a new file only gets tested once it is added to its root's `test` block. Function bodies are analysed lazily: code that no test or entry point calls is not compiled. `main.zig` uses `std.testing.refAllDecls` on the example namespaces to keep them compiling. `src/dsp/filters/` is not wired into `dsp.zig` yet.

Run a single file's tests directly only when it imports no named module. Leaf modules and files qualify:

```sh
zig test src/dsp/transforms.zig
zig test src/core/buffer/root.zig --test-filter "AudioBlock"
```

Anything that says `@import("buffer")`, `@import("common")`, etc. (all of `graph/`, `backends/alsa/`, `dsp/waves.zig`) has no module table under bare `zig test`; use `zig build test -Dtest-filter=...`. The sketches in `docs/examples/` are self-contained and run with `zig test docs/examples/<file>.zig`.

`zig ast-check <file>` checks one file for syntax and AST-level errors with no build wiring. Use it as the first pass on any file you touch; it does not catch std API mismatches.

### Python bindings

`pydelia-build/` builds `src/python.zig` into a CPython extension with `zig build-lib` (see `builder.py`). `src/python.zig` includes `Python.h` by name; the include path comes from the `-I` flags `builder.py` passes (setuptools adds the active interpreter's include dir), so build it from the Python env you will import it in: `cd pydelia-build && python setup.py build_ext --inplace`. It is not part of `zig build` or `zig build test`, so `builder.py` declares the `dsp` and `common` modules itself with `--dep`/`-M` flags; keep that list in step with the module table in `build.zig`. It uses `f64` throughout; it is a testing/visualization surface for the notebooks in `notebooks/`, not a performance path.

## Architecture

Three layers, wired together only at the top:

```
dsp/        allocating analysis kernels (FFT, waves, filters, complex storage)
graph/      GraphBuilder -> Compiler -> ExecutionPlan, on core/buffer (contract: docs/graph-contract.md)
backends/   alsa/: PlaybackDevice -> PlaybackLoop -> AlsaPcm seam, on core/buffer (contract: docs/backend-contract.md)
core/       buffer/ (buffer contract: docs/buffer-contract.md); used by graph/ and backends/
common/     audio_specs (BufferSize/BlockSize/SampleRate enums)
```

`src/graph/examples.zig` shows the offline path (build, compile, render, interleave). `src/examples.zig` is the top-level playback example (an `ExecutionPlan` through `PlaybackDevice`) and `src/backends/alsa/examples.zig` holds backend-only examples; both are skeletons being written by hand as part of M4a. The old graph, scheduler, backend and buffer views (`src/legacy/`, `src/common/audio_buffer.zig`) were deleted in October 2026; they are in git history before the `remove legacy graph and backend` commit. Do not reintroduce them.

### ALSA backend

Four files under `src/backends/alsa/` (details in its `README.md`), imported through the `backends` module as `backends.alsa.device`, `.loop`, `.pcm`, `.convert`:

- `device.zig`: `PlaybackDevice(Ctx, fmt)` is generic over the caller's context struct and a comptime `SampleFormat`. `init(DeviceOptions)` opens and negotiates hw params (MMAP interleaved only; a moved period or buffer is `period_changed`, a moved rate is reported in `negotiated`). `prepare(allocator)` applies sw params, validates the mmap area geometry once, and allocates the staging buffer. `start(ctx, callback)` runs the loop on the calling thread until `stop()` (callable from another thread) or an unrecoverable error; `deinit(allocator)` after stop.
- `loop.zig`: `PlaybackLoop(Ctx, Pcm, fmt)` is the transfer policy, generic over the `Pcm` seam so tests drive it with a scripted PCM. Callback is `fn (ctx: *Ctx, out: AudioBlock(f32)) void` with `0 < frame_count <= period_frames`; the callback writes every frame and never allocates, locks, logs or waits. Counters live in `Stats`; the loop never prints.
- `pcm.zig`: `AlsaPcm` is the thin seam over `snd_pcm_*` and holds the module's **only** `@cImport` (`pcm.c`); a second one would yield an incompatible opaque `snd_pcm_t`. Negative ALSA results become `PcmError` here, nowhere else.
- `convert.zig`: `SampleConverter(fmt)` encodes/decodes device bytes to and from planar `f32` blocks in one pass; integer encode clamps before scaling.

### Graph pipeline

Three phases in three files, plus the node contract. Import through the `graph` module (`src/graph/root.zig`).

- `node.zig`: `Node(T)` is the type-erased wrapper (`ptr`, `vtable`, `ports`, `name`). A node is a struct with `pub const ports: Ports`, `pub const name: []const u8`, `prepare(*Self, PrepareContext) NodeError!void` and `process(*Self, ProcessContext) void`; `Node(T).init` checks all of it at comptime. `ProcessContext` has separate `inputs` and `outputs`, one block per port. Nodes never allocate in `process` and carry no status: order is the compiler's decision. Implementations live in `nodes/` (`Gain`, `Oscillator`).
- `builder.zig`: `GraphBuilder(T)` is mutable and editing-time only. `addNode` heap-copies the struct; `connect`, `connectPorts` and `connectOutput` reject `invalid_handle` and `port_out_of_range` at the call site. The graph output is not a node. The builder owns the nodes and outlives every plan compiled from it.
- `compiler.zig`: `Compiler(T).compile(allocator, &builder, options)` validates (`no_output`, `disconnected_input`, `cycle_detected`), sorts (Kahn, lowest ready index first, so the op list is deterministic), assigns one pool slot per output port plus one mix slot per fan-in port, prepares nodes, and emits a flat `Op` list. It is transactional: intermediate tables live in an arena, and a failure leaves nothing allocated.
- `plan.zig`: `ExecutionPlan(T).render(out)` checks the caller's block once, then runs `clear`, `accumulate`, `process` and `copy_out` ops over the pool. No allocation, status checks or lookups. Block-op errors are `catch unreachable` there because the compiler proved the shapes.

Tests in `compiler.zig` pin exact slot counts and op lists; keep them when touching slot assignment. Every port carries the graph's channel count. Slot reuse and in-place execution are not implemented (open questions in the contract). Replacing a plan means stop, edit, recompile, restart.

### Buffers

`core/buffer/`, contract in `docs/buffer-contract.md`: import only the `buffer` module (`src/core/buffer/root.zig`). `AudioBlock(T)` and `ConstAudioBlock(T)` are borrowed planar views (`samples`, `channel_count`, `frame_count`, `channel_stride`) generated from one private `Block(T, mutability)` in `block.zig`; `channel(c)` returns a slice of the active frames. `OwnedAudioBuffer` and `AudioBufferPool` (`storage.zig`) own 64-byte-aligned storage, take the allocator plus an `Options` struct in `init` (`.{ .channel_count, .max_frames }`, plus `.slot_count` for the pool) and the allocator again in `deinit` without storing it, and lend blocks through `borrowBlock`/`borrowSlot`. `ops.zig` has `clear`, `copy`, `accumulate`, `interleave`, `deinterleave`; they return `shape_mismatch` or `forbidden_overlap` and write nothing on failure. `ProcessContext` is defined on `Node(T)` in `src/graph/node.zig`, not here. Interleaved audio exists only as packed slices at device/file boundaries.

### DSP

`dsp/transforms.zig` has `FourierStatic(T, WindowSize)` (comptime size, namespace-level shared scratch, rebuilds twiddles per call) and `FourierDynamic(T)` (radix-2 or Bluestein, allocating, plus a reference `dft`). `ComplexList` is interleaved complex storage with owned/unowned modes; its `resize` changes storage without updating `len`. The plan collapses static/dynamic into reference DFT + `FftPlan`/`FftWorkspace` + allocating analysis adapter. `dsp/reference/fft.c` is a C reference implementation kept for comparison; it is not wired into the build or any test.

## Conventions

- Zig standard naming (see `src/style_guide.zig`): `TypeName`, `functionName`, `snake_case` values, file named after the type when the file *is* a struct (`Hardware.zig`, `AudioCard.zig`).
- Functions that allocate and hand ownership to the caller end in `Alloc` (`topologicalSortAlloc`, `magnitudeAlloc`, `readAllAlloc`).
- Logging goes through `std.log.scoped(.alsa | .graph | .dsp | .main)`; `src/logging.zig` filters unknown scopes below `err`. `main.zig`/`examples.zig` set `std_options` with `logFn` from there.
- Generic types gate `T` with `@compileError` for anything but `f32`/`f64`.
- Sizes are enums (`BufferSize.buf_512`, `BlockSize.blk_256`, `SampleRate.sr_48000`), converted with `@intFromEnum` or `.toFloat(T)`.
- Two or more parameters of the same type go in an options struct so the call site names them (`OwnedAudioBuffer.init(allocator, .{ .channel_count = 2, .max_frames = 512 })`, `LoopOptions`, `DeviceOptions`). A swapped `(period_frames, channel_count)` once compiled and would have panicked on the first audio period.
