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
- Working order is M1, M3, M2. M0, M1 and M3 are done; the next milestone is M2 (planned scalar FFT), then M4 (ALSA on the new graph).

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

ALSA is linked statically from `vendor/alsa/src/.libs/libasound.a`, built on first `zig build` from the submodule; it is attached to the `alsa` and `legacy_backends` modules only. zBench is pinned to v0.13.0, the last release that targets Zig 0.16.

### Modules

Every subsystem is a named module declared in `build.zig`, and files import across folders by module name, never by relative path:

| module | root file | imports |
|---|---|---|
| `buffer` | `src/core/buffer/root.zig` | — |
| `utils` | `src/utils/root.zig` | — |
| `common` | `src/common/root.zig` (`audio_specs`, `audio_buffer`) | — |
| `dsp` | `src/dsp/dsp.zig` | `common` |
| `graph` | `src/graph/root.zig` | `buffer`, `common` |
| `alsa` | `src/backends/alsa/root.zig` | `buffer` (+ ALSA) |
| `backends` | `src/backends/root.zig` | `alsa` |
| `legacy_graph` | `src/legacy/graph/graph.zig` | `common`, `dsp` |
| `legacy_backends` | `src/legacy/backends/backends.zig` | `common`, `utils`, `dsp` (+ ALSA) |
| root | `src/main.zig` | all of the above |

So `src/graph/plan.zig` writes `const buffer = @import("buffer");` and `const specs = @import("common").audio_specs;`. Within a module, sibling files are still imported by relative path (`@import("node.zig")`, `@import("nodes/root.zig")`). Two compiler rules make the table the real dependency graph: a file belongs to exactly one module, and a module may only import files under its root's directory. A new cross-module edge is therefore a `addImport` line in `build.zig`, and a cycle is a compile error. `root.zig` is the module-root filename by convention (what `zig init` uses); nothing depends on the name.

### Tests

The test runner only collects `test` blocks from the files of the module it is given, so `build.zig` emits one test binary per module (`test_buffer`, `test_graph`, ..., `test_root`) and `zig build test` runs them all; `-Dtest-filter` applies to each. Within a module, tests are aggregated through explicit `test { _ = file; }` blocks in the module root (0.16 has no `refAllDeclsRecursive`), so a new file only gets tested once it is added to its root's `test` block. Function bodies are analysed lazily: code that no test or entry point calls is not compiled. `main.zig` uses `std.testing.refAllDecls` on the example namespaces to keep them compiling. `src/dsp/filters/` is not wired into `dsp.zig` yet.

Run a single file's tests directly only when it imports no named module. Leaf modules and files qualify:

```sh
zig test src/dsp/transforms.zig
zig test src/core/buffer/root.zig --test-filter "AudioBlock"
```

Anything that says `@import("buffer")`, `@import("common")`, etc. (all of `graph/`, `backends/alsa/`, `legacy/`, `dsp/waves.zig`) has no module table under bare `zig test`; use `zig build test -Dtest-filter=...`. The sketches in `docs/examples/` are self-contained and run with `zig test docs/examples/<file>.zig`.

`zig ast-check <file>` checks one file for syntax and AST-level errors with no build wiring. Use it as the first pass on any file you touch; it does not catch std API mismatches.

### Python bindings

`pydelia-build/` builds `src/python.zig` into a CPython extension with `zig build-lib` (see `builder.py`). `src/python.zig` includes `Python.h` by name; the include path comes from the `-I` flags `builder.py` passes (setuptools adds the active interpreter's include dir), so build it from the Python env you will import it in: `cd pydelia-build && python setup.py build_ext --inplace`. It is not part of `zig build` or `zig build test`, so `builder.py` declares the `dsp` and `common` modules itself with `--dep`/`-M` flags; keep that list in step with the module table in `build.zig`. It uses `f64` throughout; it is a testing/visualization surface for the notebooks in `notebooks/`, not a performance path.

## Architecture

Three layers, wired together only at the top:

```
dsp/        allocating analysis kernels (FFT, waves, filters, complex storage)
graph/      GraphBuilder -> Compiler -> ExecutionPlan, on core/buffer (contract: docs/graph-contract.md)
backends/   ALSA devices; comptime-specialized on a user Context type + callback
core/       buffer/ (buffer contract: docs/buffer-contract.md); used by graph/
common/     audio_specs (BufferSize/BlockSize/SampleRate enums) and audio_buffer (old views + pool)
legacy/     graph/: the old Graph -> TopologyQueue -> Scheduler, frozen until M4
```

`src/graph/examples.zig` shows the offline path (build, compile, render, interleave). `src/examples.zig` is ALSA playback on the legacy scheduler and is the only non-test user of `legacy/`. Nothing new imports `legacy/`.

### Comptime Context pattern (backends)

Every device type is a generic over the caller's context struct: `alsa.driver.HalfDuplexDevice(Ctx, .{ .format = ... })`, `FullDuplexDevice(...)`. The device is `start(ctx_ptr, callback)`ed with a callback of the form `fn (ctx: *Ctx, data: Device.AudioDataType()) void`. The sample format is a comptime option, and `Device.FloatType()` gives the float type the callback works in. `GenericAudioData(format)` wraps the raw device byte buffer and converts to/from that float type on `write`/`readSample`.

ALSA device options are negotiated at `init`/`prepare` (hardware buffer = `buffer_size * n_periods`, MMAP interleaved with RW fallback). `Hardware` enumerates cards/ports and can find them by substring; `fromHardware` builds a device from a selection. Recovery, linking and transfer invariants for the duplex loops are known-fragile; the plan's section 9.2 lists concrete repair candidates in `driver.zig`.

### Graph pipeline

Three phases in three files, plus the node contract. Import through the `graph` module (`src/graph/root.zig`).

- `node.zig`: `Node(T)` is the type-erased wrapper (`ptr`, `vtable`, `ports`, `name`). A node is a struct with `pub const ports: Ports`, `pub const name: []const u8`, `prepare(*Self, PrepareContext) NodeError!void` and `process(*Self, ProcessContext) void`; `Node(T).init` checks all of it at comptime. `ProcessContext` has separate `inputs` and `outputs`, one block per port. Nodes never allocate in `process` and carry no status: order is the compiler's decision. Implementations live in `nodes/` (`Gain`, `Oscillator`).
- `builder.zig`: `GraphBuilder(T)` is mutable and editing-time only. `addNode` heap-copies the struct; `connect`, `connectPorts` and `connectOutput` reject `invalid_handle` and `port_out_of_range` at the call site. The graph output is not a node. The builder owns the nodes and outlives every plan compiled from it.
- `compiler.zig`: `Compiler(T).compile(allocator, &builder, options)` validates (`no_output`, `disconnected_input`, `cycle_detected`), sorts (Kahn, lowest ready index first, so the op list is deterministic), assigns one pool slot per output port plus one mix slot per fan-in port, prepares nodes, and emits a flat `Op` list. It is transactional: intermediate tables live in an arena, and a failure leaves nothing allocated.
- `plan.zig`: `ExecutionPlan(T).render(out)` checks the caller's block once, then runs `clear`, `accumulate`, `process` and `copy_out` ops over the pool. No allocation, status checks or lookups. Block-op errors are `catch unreachable` there because the compiler proved the shapes.

Tests in `compiler.zig` pin exact slot counts and op lists; keep them when touching slot assignment. Every port carries the graph's channel count. Slot reuse and in-place execution are not implemented (open questions in the contract). Replacing a plan means stop, edit, recompile, restart.

`src/legacy/graph/` holds the previous implementation (`Graph`, `TopologyQueue`, `Scheduler` on `UniformChannelViews`). Do not add features to it; it is deleted when the ALSA callback runs on `ExecutionPlan.render`.

### Buffers

Two implementations coexist until the ALSA backend migrates in M4.

**New (`core/buffer/`, contract in `docs/buffer-contract.md`):** import only the `buffer` module (`src/core/buffer/root.zig`). `AudioBlock(T)` and `ConstAudioBlock(T)` are borrowed planar views (`samples`, `channel_count`, `frame_count`, `channel_stride`) generated from one private `Block(T, mutability)` in `block.zig`; `channel(c)` returns a slice of the active frames. `OwnedAudioBuffer` and `AudioBufferPool` (`storage.zig`) own 64-byte-aligned storage, take the allocator in `init`/`deinit` without storing it, and lend blocks through `borrowBlock`/`borrowSlot`. `ops.zig` has `clear`, `copy`, `accumulate`, `interleave`, `deinterleave`; they return `shape_mismatch` or `forbidden_overlap` and write nothing on failure. `ProcessContext` is defined on `Node(T)` in `src/graph/node.zig`, not here. Interleaved audio exists only as packed slices at device/file boundaries.

**Old (`common/audio_buffer.zig`):** `ChannelView` owns storage, `UnmanagedChannelView` borrows it, `UniformChannelViews` is one contiguous pool exposing N views. Access is interleaved or non-interleaved via a runtime tag; `block_size` doubles as physical stride. Still used by the legacy graph and scheduler. Do not add features to it.

### DSP

`dsp/transforms.zig` has `FourierStatic(T, WindowSize)` (comptime size, namespace-level shared scratch, rebuilds twiddles per call) and `FourierDynamic(T)` (radix-2 or Bluestein, allocating, plus a reference `dft`). `ComplexList` is interleaved complex storage with owned/unowned modes; its `resize` changes storage without updating `len`. The plan collapses static/dynamic into reference DFT + `FftPlan`/`FftWorkspace` + allocating analysis adapter. `dsp/reference/fft.c` is a C reference implementation kept for comparison; it is not wired into the build or any test.

## Conventions

- Zig standard naming (see `src/style_guide.zig`): `TypeName`, `functionName`, `snake_case` values, file named after the type when the file *is* a struct (`Hardware.zig`, `AudioCard.zig`).
- Functions that allocate and hand ownership to the caller end in `Alloc` (`topologicalSortAlloc`, `magnitudeAlloc`, `readAllAlloc`).
- Logging goes through `std.log.scoped(.alsa | .graph | .dsp | .main)`; `src/logging.zig` filters unknown scopes below `err`. `main.zig`/`examples.zig` set `std_options` with `logFn` from there.
- Generic types gate `T` with `@compileError` for anything but `f32`/`f64`.
- Sizes are enums (`BufferSize.buf_512`, `BlockSize.blk_256`, `SampleRate.sr_48000`), converted with `@intFromEnum` or `.toFloat(T)`.
