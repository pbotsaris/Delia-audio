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
- Working order is M1, M3, M2. M0 and M1 are done; the next milestone is M3 (offline graph slice on the new buffer contract).

## Toolchain

Target is **Zig 0.16.0** (the system compiler). The migration from 0.13 is complete, including `src/python.zig` (`docs/ZIG_016_MIGRATION.md` is the log). Do not pin or install 0.13; write all new code against 0.16 std (unmanaged `ArrayList`, `std.Io` writers, `{f}` custom formatters, `callconv(.c)`, lowercase `@typeInfo` tags, `DebugAllocator`).

**JACK has been removed** (`src/backends/jack/`, the `vendor/jack` submodule, the JACK detection in `build.zig`). Do not reintroduce it; the last JACK code is in git history before the `remove jack backend` commit.

## Build and test commands

The `vendor/alsa` submodule (alsa-lib, built statically) must be present (`git submodule update --init`).

```sh
zig build                          # first run configures+makes vendor/alsa (needs autotools/make)
zig build run                      # runs src/main.zig (currently a scratch entry point that calls one example)
zig build check                    # compile-only; this is what zls build-on-save uses (zls.json)
zig build test                     # all tests
zig build test -Dtest-filter=FFT   # only tests whose name contains the string (repeatable)
zig build bench                    # zbench microbenchmarks in src/benchmarks.zig (compare with bench.txt)
```

`run`, `check`, and `test` share one root module (`src/main.zig`) in `build.zig`, so ALSA is wired once. ALSA is linked statically from `vendor/alsa/src/.libs/libasound.a`, built on first `zig build` from the submodule. zBench is pinned to v0.13.0, the last release that targets Zig 0.16.

Tests are aggregated through explicit `test { _ = module; }` blocks: `src/main.zig` references the aggregators (`src/dsp/dsp.zig`, `src/graph/graph.zig`, `src/graph/nodes/nodes.zig`, `src/backends/backends.zig`, `src/backends/alsa/alsa.zig`, `src/core/buffer/buffer.zig`), and each aggregator references its files. 0.16 has no `refAllDeclsRecursive`, so a new file only gets tested once it is added to its aggregator's `test` block. Function bodies are analysed lazily: code that no test or entry point calls is not compiled. `main.zig` uses `std.testing.refAllDecls` on the example namespaces to keep them compiling. `src/dsp/filters/` is not wired into `dsp.zig` yet.

Run a single file's tests directly. Pure Zig files need nothing extra:

```sh
zig test src/dsp/transforms.zig
zig test src/graph/graph.zig --test-filter "TopologyQueue"
```

Files that `@cImport` ALSA need the include path, the static lib, and libc:

```sh
zig test src/backends/alsa/driver.zig -I vendor/alsa/include vendor/alsa/src/.libs/libasound.a -lc
```

`zig test` makes the given file the module root, so files with `../` imports (most of `graph/` and `backends/alsa/`) must be tested through a root under `src/` or via `zig build test`.

`zig ast-check <file>` checks one file for syntax and AST-level errors with no build wiring. Use it as the first pass on any file you touch; it does not catch std API mismatches.

### Python bindings

`pydelia-build/` builds `src/python.zig` into a CPython extension with `zig build-lib` (see `builder.py`). `src/python.zig` includes `Python.h` by name; the include path comes from the `-I` flags `builder.py` passes (setuptools adds the active interpreter's include dir), so build it from the Python env you will import it in: `cd pydelia-build && python setup.py build_ext --inplace`. It is not part of `zig build` or `zig build test`. It uses `f64` throughout; it is a testing/visualization surface for the notebooks in `notebooks/`, not a performance path.

## Architecture

Three layers, wired together only at the top (`src/examples.zig` shows the full path):

```
dsp/        allocating analysis kernels (FFT, waves, filters, complex storage)
graph/      Graph -> TopologyQueue -> Scheduler, with a UniformChannelViews buffer pool
backends/   ALSA devices; comptime-specialized on a user Context type + callback
common/     audio_buffer (old views + pool) and audio_specs (BufferSize/BlockSize/SampleRate enums)
core/       buffer/ (new buffer contract); nothing else imports it yet
```

### Comptime Context pattern (backends)

Every device type is a generic over the caller's context struct: `alsa.driver.HalfDuplexDevice(Ctx, .{ .format = ... })`, `FullDuplexDevice(...)`. The device is `start(ctx_ptr, callback)`ed with a callback of the form `fn (ctx: *Ctx, data: Device.AudioDataType()) void`. The sample format is a comptime option, and `Device.FloatType()` gives the float type the callback works in. `GenericAudioData(format)` wraps the raw device byte buffer and converts to/from that float type on `write`/`readSample`.

ALSA device options are negotiated at `init`/`prepare` (hardware buffer = `buffer_size * n_periods`, MMAP interleaved with RW fallback). `Hardware` enumerates cards/ports and can find them by substring; `fromHardware` builds a device from a selection. Recovery, linking and transfer invariants for the duplex loops are known-fragile; the plan's section 9.2 lists concrete repair candidates in `driver.zig`.

### Graph pipeline

- `Graph(T)` holds `GenericNode` type-erased nodes (vtable: `name/prepare/process/destroy`) and edges. `addNode` copies the node struct onto the heap. Only `f32`/`f64` are accepted (compile error otherwise).
- `topologicalSortAlloc` produces a `TopologyQueue` (Kahn's algorithm on stack arrays bounded by `GraphOptions.max_static_size`, default 1024; cycles return `cycle_detected`).
- `TopologyQueue.analyzeBufferRequirementsAlloc` does reference-counted buffer assignment: a producer's buffer is freed for reuse once its last consumer runs, so a parent shares a buffer with its last-connected child. Tests in `graph.zig` pin exact buffer indices; keep them when touching this.
- `Scheduler(T)` owns the graph, the queue, and the `UniformChannelViews` pool. `prepare` calls each node's `prepare`, sorts, analyzes, and builds the new queue and pool before replacing the old ones; the pool is reused only when view count, channel count, block size and access all still fit. `processGraph` is explicitly WIP: it still polls node status each block and copies parent views into child views on buffer mismatch. The plan replaces this with a compiled flat operation list executed without status checks or topology discovery.

Nodes implement `prepare(*Self, PrepareContext)`, `process(*Self, ProcessContext)`, `name`. `ProcessContext` carries a borrowed `UnmanagedChannelView`; nodes never allocate in `process`.

### Buffers

Two implementations coexist until the graph migrates in M3.

**New (`core/buffer/`, contract in `docs/buffer-contract.md`):** import only `core/buffer/buffer.zig`. `AudioBlock(T)` and `ConstAudioBlock(T)` are borrowed planar views (`samples`, `channel_count`, `frame_count`, `channel_stride`) generated from one private `Block(T, mutability)` in `block.zig`; `channel(c)` returns a slice of the active frames. `OwnedAudioBuffer` and `AudioBufferPool` (`storage.zig`) own 64-byte-aligned storage, take the allocator in `init`/`deinit` without storing it, and lend blocks through `borrowBlock`/`borrowSlot`. `ops.zig` has `clear`, `copy`, `accumulate`, `interleave`, `deinterleave`; they return `shape_mismatch` or `forbidden_overlap` and write nothing on failure. `ProcessContext(T)` has separate `inputs` and `outputs`. Interleaved audio exists only as packed slices at device/file boundaries.

**Old (`common/audio_buffer.zig`):** `ChannelView` owns storage, `UnmanagedChannelView` borrows it, `UniformChannelViews` is one contiguous pool exposing N views. Access is interleaved or non-interleaved via a runtime tag; `block_size` doubles as physical stride. Still used by the graph and scheduler. Do not add features to it.

### DSP

`dsp/transforms.zig` has `FourierStatic(T, WindowSize)` (comptime size, namespace-level shared scratch, rebuilds twiddles per call) and `FourierDynamic(T)` (radix-2 or Bluestein, allocating, plus a reference `dft`). `ComplexList` is interleaved complex storage with owned/unowned modes; its `resize` changes storage without updating `len`. The plan collapses static/dynamic into reference DFT + `FftPlan`/`FftWorkspace` + allocating analysis adapter. `dsp/reference/fft.c` is a C reference implementation kept for comparison; it is not wired into the build or any test.

## Conventions

- Zig standard naming (see `src/style_guide.zig`): `TypeName`, `functionName`, `snake_case` values, file named after the type when the file *is* a struct (`Hardware.zig`, `AudioCard.zig`).
- Functions that allocate and hand ownership to the caller end in `Alloc` (`topologicalSortAlloc`, `magnitudeAlloc`, `readAllAlloc`).
- Logging goes through `std.log.scoped(.alsa | .graph | .dsp | .main)`; `src/logging.zig` filters unknown scopes below `err`. `main.zig`/`examples.zig` set `std_options` with `logFn` from there.
- Generic types gate `T` with `@compileError` for anything but `f32`/`f64`.
- Sizes are enums (`BufferSize.buf_512`, `BlockSize.blk_256`, `SampleRate.sr_48000`), converted with `@intFromEnum` or `.toFloat(T)`.
