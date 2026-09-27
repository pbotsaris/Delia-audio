# Delia Audio: Implementation and Refactoring Plan

**Date:** 26 September 2026  
**Status:** Working architecture and implementation roadmap  
**Repository:** [pbotsaris/Delia-audio][D0]  
**Primary objective:** Develop a small, well-tested Zig audio runtime while learning DSP, realtime systems, memory design, and optimization through its implementation.

> Preserve the experiments and useful algorithms. Refactor the boundaries between ownership, preparation, execution, and convenience. Do not restart the entire project or attempt to replace every mature audio library at once.

## Reading this report

This report consolidates our discussion and adds a targeted inspection of the public `main` branch: audio buffers, complex storage, Fourier transforms, the graph scheduler, the ALSA driver, and the package manifest. Repository observations are linked to their sources. Architectural choices, proposed APIs, milestones, and acceptance criteria are recommendations, not descriptions of functionality already implemented.

**Validation limits:** This was static source inspection, not a complete repository audit. No Zig build, test suite, benchmark, or audio-hardware test was executed. No immutable commit snapshot was established; the source links below track `main`. Record a commit hash and working compiler version before implementation. Code-shaped examples are design sketches, not compiled patches.

**Baseline and revision (26 September 2026, after the Zig 0.16 migration):** The plan was reviewed against the working tree at commit `b1aaad0` with Zig 0.16.0 and zBench v0.13.0. `zig build test` passes 114/114. `build.zig.zon` declares `minimum_zig_version = "0.16.0"`. This review decided the buffer representation (4.2), added the node I/O contract (4.5), and set the milestone order to M1, M3, M2 (section 12). The buffer contract is `docs/buffer-contract.md`, with a design sketch in `docs/examples/audio_block_sketch.zig`.

**M1 complete (27 September 2026):** the buffer contract is implemented in `src/core/buffer/` and wired into `zig build test` (137/137 passing, 23 of them in `src/core/buffer/buffer.zig`). All 14 acceptance items in the contract have a test. `ProcessContext` lives in `src/core/buffer/buffer.zig`. Nothing uses the new types yet: `src/common/audio_buffer.zig`, the graph, and the ALSA backend are unchanged and migrate in M3 and M4.

## Contents

1. [Project direction and scope](#1-project-direction-and-scope)
2. [What to preserve](#2-what-to-preserve)
3. [Architectural rules](#3-architectural-rules)
4. [Audio buffers and ownership](#4-audio-buffers-and-ownership)
5. [FFT architecture](#5-fft-architecture)
6. [SIMD and replaceable kernels](#6-simd-and-replaceable-kernels)
7. [Compiled audio graph](#7-compiled-audio-graph)
8. [Realtime execution and communication](#8-realtime-execution-and-communication)
9. [ALSA duplex backend and Linux server](#9-alsa-duplex-backend-and-linux-server)
10. [CoreAudio and external dependencies](#10-coreaudio-and-external-dependencies)
11. [Proposed source organization](#11-proposed-source-organization)
12. [Implementation milestones](#12-implementation-milestones)
13. [Testing and performance evidence](#13-testing-and-performance-evidence)
14. [Learning and development workflow](#14-learning-and-development-workflow)
15. [Decisions and immediate backlog](#15-decisions-and-immediate-backlog)
16. [Source register](#16-source-register)

## 1. Project direction and scope

Build **a Zig DSP library and audio execution runtime**, with two complementary interfaces:

| Interface | Intended use | Memory and execution model |
|---|---|---|
| Realtime | Synthesizers, effects, compiled graphs, device callbacks | Prepared state, explicit buffers, bounded processing, no allocation during rendering |
| Analysis | Experiments, tests, offline rendering, Python-style workflows | Convenient ownership, allocating helpers, arbitrary transform sizes |

Both interfaces should ultimately use the same tested numerical kernels. The analysis layer is not a mistake to remove; it is a useful product surface and a development tool.

Own the components that provide the desired learning and control: buffer contracts, DSP kernels, FFT planning, graph compilation, scheduling, parameters, and backend integration. Bind complex codecs and operating-system APIs rather than making their replacement a prerequisite.

The Linux direction remains **direct ALSA integration, with a Delia-owned server as a later application of the engine**. JACK or PipeWire integration can remain optional interoperability work, not a required internal dependency. CoreAudio is another backend, not the architecture around which the engine must be organized.

Defer a general plugin host, a desktop-wide audio-server replacement, multi-device synchronization, a GUI framework, and broad codec reimplementation. Each is a separate project-sized expansion.

## 2. What to preserve

The following foundation is present in the inspected source. Presence does not establish correctness or production readiness.

| Existing area | Evidence worth preserving | Refactoring direction |
|---|---|---|
| `common/audio_buffer.zig` | Owned and borrowed channel representations, a contiguous uniform pool, and tests. [D1] | Make ownership and layout contracts explicit. |
| `dsp/complex_list.zig` | Interleaved complex storage, owning/borrowed modes, accessors, and analysis helpers. [D2] | Retain convenience while separating ownership from kernel inputs. |
| `dsp/transforms.zig` | Static radix-2, dynamic radix-2/Bluestein, DFT references, transform comparisons, and inverse tests. [D3] | Consolidate around reusable planning and independently owned workspace. |
| `graph/scheduler.zig` | Preparation, topological ordering, and buffer-requirement analysis. [D4] | Compile an explicit execution plan. |
| `backends/alsa/driver.zig` | Full-duplex callback processing, MMAP/RW paths, linked/unlinked handling, and recovery logic. [D5] | Retain the backend; harden its transfer and lifecycle contracts. |

Preserve old implementations long enough to compare behavior, but do not treat them as unquestionable correctness oracles. A reference test and its implementation can share the same mistake.

Migrate one subsystem at a time. Introduce adapters temporarily where necessary. A directory reorganization is not, by itself, an architectural improvement.

## 3. Architectural rules

### 3.1 Separate storage, views, computation, and convenience

Use four distinct responsibilities:

```text
Owning storage       allocates and releases memory
Borrowed views       describe existing memory and its layout
Numerical kernels    compute over explicit buffers
Convenience APIs     allocate, adapt, validate, and compose operations
```

Low-level code may still be pleasant to use. Small methods, typed views, and inline helpers are acceptable. The goal is **visible cost and ownership**, not deliberately inconvenient APIs.

A helper is problematic when it hides allocation, resizing, logging, ownership transfer, or representation conversion inside a hot loop. Its existence or method syntax is not evidence that it is slow.

### 3.2 Separate preparation from execution

| Phase | Proposed responsibilities |
|---|---|
| Construction/preparation | Validate configuration, allocate storage, choose algorithms, construct tables, negotiate device formats |
| Processing | Execute prepared work over existing state and buffers |
| Retirement/destruction | Release old resources only after execution has stopped using them |

Runtime-selected sizes are compatible with allocation-free execution. Conversely, a compile-time size does not establish bounded execution or safe ownership.

A missing allocator parameter is useful API discipline, but not proof: called functions and external libraries must also be inspected.

### 3.3 Start with a narrow, explicit contract

Recommended first targets: planar `f32` graph audio, `f32`/`f64` DSP where useful, one render thread, an acyclic graph, a declared maximum block size, and one supported hardware clock domain.

Treat these as intentional scope limits, not permanent limitations. Reject unsupported configurations clearly rather than approximating them silently.

## 4. Audio buffers and ownership

### 4.1 Findings to carry into the refactor

`ChannelView` allocates and owns storage; `UnmanagedChannelView` borrows it. The names can obscure that distinction. `UniformChannelViews` already offers the useful pool-and-view pattern. Both `copyFrom` implementations check total length and then copy raw samples; they do not validate channel shape or convert layouts. [D1]

Introduce names such as:

```text
OwnedAudioBuffer(T)   owns storage; has initialization and destruction
AudioBlock(T)         writable borrowed view; no allocator or destruction
ConstAudioBlock(T)    read-only borrowed view
AudioBufferPool(T)    owns graph scratch storage; exposes borrowed blocks
```

Keep sample-rate and device-format metadata in preparation/process context unless a particular buffer operation actually needs it. A memory view should not become a device abstraction.

### 4.2 Make frame count different from physical stride

The earlier conversational `AudioBlock` example used `channel * frames` to locate a channel. That works only for tightly packed channels whose physical stride equals the current valid frame count.

A reusable buffer may reserve 512 samples per channel while the current callback processes only 128. Channel 1 still starts at offset 512, not 128.

Proposed contiguous-planar view contract:

```text
samples          borrowed sample storage
channel_count    number of channels
frame_count      valid frames for this operation
channel_stride   samples between adjacent channel starts

channel(c) = samples[c * channel_stride .. c * channel_stride + frame_count]
```

Validate dimensions, multiplication overflow, storage bounds, and `frame_count <= channel_stride` when creating views. A sub-block must preserve the parent's physical stride. A zero-frame block should have defined behavior.

**Decision: contiguous storage with an explicit stride.** A block is a four-field value, needs no channel-descriptor storage, and a sub-block is a shifted base with the same stride. The alternative, a slice of channel slices, represents separately allocated channels naturally but needs descriptor storage that must itself be prepared. Revisit only if a backend delivers channels that cannot be described by one base and one stride.

`frame_count` is a runtime `usize`. The existing `BlockSize` enum cannot express a 100-frame partial block; it remains the type for the declared maximum block size in preparation options.

### 4.3 Keep layout conversion at explicit boundaries

Use planar graph buffers initially. Retain interleaved and strided views for device/file adapters. Select a layout-specific conversion or processing loop once per block rather than requiring every sample operation to interpret a runtime layout tag.

This is a design preference for Delia, not a claim that planar storage always wins. Benchmark actual kernels before making universal performance claims.

Define separate operations for raw storage copy, same-layout audio copy, layout conversion, accumulation, clearing, and channel mapping. In particular, **copying is not mixing**.

### 4.4 Ownership and aliasing contracts

Document who owns the storage and how long a view remains valid. An owning Zig value must not be casually copied and independently destroyed. A borrowed view must not outlive its owner or an MMAP region's valid access interval.

For every kernel, specify whether exact in-place operation is supported, whether input/output must be disjoint, and whether partial overlap is forbidden. Do not assume a general memory-copy primitive handles overlap.

The pool must account for channel stride and alignment, not just total sample count. Reusing a buffer requires proof that all earlier consumers have finished.

**Acceptance tests:** mono/stereo/multichannel views; partial blocks; sub-blocks; independent pool slots; layout round trips; shape mismatch rejection; forbidden overlap; and writes confined to active frames.

### 4.5 Node I/O contract

The buffer contract cannot be finished without knowing what a node receives, because that decides what the pool hands out. The current `ProcessContext` carries one buffer, so every node is implicitly in-place. That is why `processGraph()` copies a parent's view into its child's, and why fan-in overwrites rather than mixes.

**Decision: separate inputs and outputs.**

```text
ProcessContext(T)
    inputs       []const ConstAudioBlock(T)    one block per input port
    outputs      []const AudioBlock(T)         one block per output port
    frame_count  usize
```

Outputs are disjoint from inputs. A node writes every active frame of every output. A port receives exactly one block; summing several producers into it is an explicit mix operation emitted by the graph compiler (7.2), not something a node does. In-place execution becomes a later compiler optimization for nodes that declare exact in-place support.

The full rules are in `docs/buffer-contract.md`, section 8.

## 5. FFT architecture

### 5.1 What the existing implementation tells us

`FourierStatic` rebuilds its twiddle table inside each transform. Its buffer and fixed-buffer allocator are namespace-level mutable variables, not per-call stack storage. That storage is shared for a given specialization; Zig documents namespace-level variables as having global lifetime. [D3][R1]

These are reasons to separate planning and workspace. They are not measured proof that trigonometry, accessors, or allocation dominate execution time.

`ComplexList.resize()` changes storage without updating `len`; clarify whether it means reserve or logical resize, then test that contract. Its borrowed mode still carries an allocator. [D2]

### 5.2 Replace the static/dynamic split with three layers

```text
reference DFT       simple, independent correctness reference
planned FFT         prepared transform over supplied buffers
analysis helpers    allocating convenience over the planned implementation
```

Keep the useful distinction between convenient analysis and realtime execution. Avoid maintaining two unrelated implementations of the same radix-2 transform.

A separate plan/execution lifecycle is established practice; FFTW explicitly separates plan construction from execution. Its details are a reference, not an API that Delia must copy. [R2]

### 5.3 Distinguish the plan from its workspace

Recommended conceptual model:

| Component | Contents | Mutability/lifetime |
|---|---|---|
| `FftPlan(T)` | Size, transform kind, twiddles, stage information, permutation strategy, backend choice | Read-only after preparation |
| `FftWorkspace(T)` | Scratch required by that plan/backend | Mutable; exclusive to one concurrent execution |
| Input/output | Caller-supplied signal or spectrum storage | Borrowed for the operation |

An owning `FftProcessor` may combine plan and workspace for convenience. Document it as non-reentrant unless it provides independent workspaces.

Do not introduce this separation merely to create more types. Its purpose is to make sharing, lifetime, and thread safety explicit. FFTW likewise distinguishes read-only plan sharing from concurrent use of the same arrays. [R3]

Proposed usage, not a compiled API:

```text
plan = createPlan(allocator, size, transform_kind, options)
workspace = createWorkspace(allocator, plan.requirements)
validateBuffers(plan, input, output, workspace)

repeat:
    plan.execute(workspace, input, output)

release workspace and plan outside realtime execution
```

Some in-place radix-2 implementations need little or no separate execution scratch. Let the chosen algorithm declare its requirements rather than allocating a full extra array automatically.

### 5.4 Define mathematical and memory semantics first

Adopt and test an explicit convention:

```text
Forward: X[k] = sum(x[n] * exp(-i * 2*pi*k*n/N))
Inverse: x[n] = (1/N) * sum(X[k] * exp(+i * 2*pi*k*n/N))
```

Specify output ordering, transform kind, aliasing, scratch size, supported lengths, and invalid-input behavior. For a conventional real-input half-spectrum, expose `floor(N/2) + 1` complex bins; for even N this includes DC and Nyquist. KISS FFT documents that even-length layout. [R4]

Keep magnitude scaling, window compensation, one-sided amplitude scaling, power spectra, and decibel reference levels separate from the transform itself. Document whether a convolution helper computes circular convolution or pads for linear convolution.

A round-trip test alone cannot detect every convention error: a matching forward/inverse mistake may cancel. Test known spectra and compare forward results independently.

### 5.5 First implementation and later extensions

Start with a readable scalar complex radix-2 plan. Precompute reusable twiddles at preparation. Decide whether a permutation table earns its memory cost; a table is not mandatory.

Initially support a documented power-of-two range. Explicitly reject zero length; either support N=1 as identity or reject it consistently. Retain arbitrary-size analysis through the existing path until the planned replacement is ready.

Later, plan Bluestein's chirps, convolution transform, transformed kernel, and workspace. Arbitrary-size FFTs are **not inherently unsuitable for realtime**; their suitability depends on preparation, memory, and measured execution cost. Restricting the first realtime implementation to powers of two is a scope decision.

### 5.6 Use comptime selectively

Use compile-time specialization for scalar type and, where justified, kernel configuration. A fixed-size owning wrapper remains a valid future option, especially for embedded use.

Fixed-size arrays should be instance storage when they hold mutable per-execution data. Immutable precomputed tables may be shared. Avoid hidden mutable globals, excessive code generation, and large implicit stack requirements.

Compare fixed-size and runtime-sized plans with equivalent preparation before concluding that either is faster. Prefer one numerical implementation with different storage policies over duplicated algorithms.

## 6. SIMD and replaceable kernels

### 6.1 Choose the replacement boundary at useful granularity

Separating complex arithmetic from a convenience container is useful. However, replacing one scalar multiply with a vector operation does not automatically vectorize an FFT: lanes must receive independent useful work, and data movement matters.

Use a scalar implementation first, then introduce a backend boundary around an FFT stage, a batch of butterflies, or a complete transform. Avoid an indirect function call for every addition or butterfly.

```text
Analysis API / Realtime client
              |
        Public FFT contract
              |
    Backend-specific plan and workspace
              |
     Scalar or vectorized execution
```

A stable public API does **not** require identical internal plans. Different backends may use different twiddle packing, permutations, scratch sizes, or transform decompositions. Select the backend during preparation, or specialize it at compile time.

### 6.2 Treat representation as an experiment

Candidate layouts include:

```text
Interleaved complex: r0 i0 r1 i1 r2 i2 ...
Split complex:       real[] and imag[]
Blocked complex:     groups arranged around a vector width
```

None is an automatic winner. Keep a clear public representation initially and permit private backend layouts. Include conversion costs in whole-transform measurements. For pipelines that keep spectra internally, consider avoiding repeated conversions between adjacent operations.

Direct slices are a useful starting point, not a prohibition on typed views. A simple representation-aware view can improve correctness without owning memory.

### 6.3 Optimization sequence

Establish the scalar baseline; remove repeated setup; measure permutations and memory traffic; experiment with radix/stage organization; then add vectorization and optional fixed-size specialization.

For every candidate, record correctness, transform time, setup time, scratch/table memory, target CPU, compiler options, and code-size effects. Inspect generated code when a result is surprising. Test vector tails and alignment assumptions explicitly.

Treat reassociation, fused operations, and approximate math as numerical policy decisions. Preserve a trustworthy scalar path for comparison and unsupported targets. Do not promise bit-identical output across implementations unless that is a tested requirement.

## 7. Compiled audio graph

### 7.1 Separate editing from rendering

The scheduler already prepares nodes and calculates topology/buffer requirements, but `processGraph()` still examines dependency status during execution. Its buffer-reuse branch also deinitializes when capacity is sufficient and returns when it is smaller; this needs a regression test before reuse. [D4]

Target architecture:

```text
Mutable Graph
    -> validation and scheduling
    -> buffer lifetime analysis
    -> immutable execution metadata
    -> render-thread-owned mutable DSP state
```

"Immutable plan" refers to topology, operation descriptions, and assignments. Oscillator phases, filter histories, delay lines, parameter smoothing, and scratch remain mutable.

### 7.2 Compiler responsibilities

Validate ports and channel layouts; reject unsupported cycles; determine execution order; make fan-in mixing explicit; calculate buffer lifetimes; choose safe in-place operations; allocate state and buffers; emit flat operations.

Start with a DAG. Feedback requires explicit delay semantics and a scheduling design; merely placing a delay-shaped node in an ordinary cycle does not make topological sorting work.

For fan-out, preserve a producer's output until its final consumer. For fan-in, sum contributions intentionally rather than overwriting one input with another. Buffer reuse must respect both lifetime and aliasing contracts.

Prefer a correct first compiler with conservative buffer allocation. Add aggressive reuse only after comparison tests establish correctness.

### 7.3 Runtime responsibilities

Execute the prepared operations in order. Do not discover topology, resize storage, look up graph names, or repeatedly check dependency readiness.

One deliberately chosen dispatch per node/block is a reasonable initial design. It is not the same cost model as dispatching per sample. Retain evidence before replacing simple dispatch with elaborate specialization.

Prepare replacement resources transactionally: failure must leave the current graph usable. Test changed channel counts and block capacities as well as changed node counts.

### 7.4 Publication and retirement

An atomic pointer exchange is not a complete graph-swap protocol. The old graph may still own state being used by the render thread.

Initially, stop the engine before replacing a plan. Later implement bounded publication at block boundaries, render-thread acknowledgement, and off-thread reclamation. Backpressure new updates when retirement capacity is exhausted; never free a still-active plan to make room.

Define state migration and transition behavior separately. A memory-safe graph swap may still click or reset oscillators unless parameters/state are preserved or a bounded crossfade is designed.

## 8. Realtime execution and communication

### 8.1 Render-path contract

For the DSP/graph callback, require no allocation or deallocation, blocking locks, filesystem/network work, synchronous logging, lazy initialization, or waiting for another thread's result. Bound loops by prepared capacities and declared work limits.

Use checked setup and debug assertions rather than disabling safety indiscriminately. Configuration errors belong at preparation boundaries. Device failures still need explicit handling; "nearly infallible processing" does not mean ignoring hardware errors.

An ALSA driver thread may wait for device readiness between processing cycles. That pacing is different from blocking inside the graph callback. Keep normal streaming, recovery, and shutdown behavior distinct.

### 8.2 Parameter and event delivery

Start with one control producer and one audio consumer using a fixed-capacity SPSC queue. Multiple producers must be merged outside the render path or use a deliberately designed alternative; they cannot safely pretend to be one SPSC producer.

Events should carry a target, value/type, and timing information. Bound how many events one block can process. Specify queue-full behavior: reject, coalesce appropriate parameter updates, or report a drop. Never wait for capacity in the audio callback.

Sample-accurate events may require processing sub-blocks. This makes correct view strides and bounded event counts important. Continuous parameters should have explicit smoothing behavior; do not assume an atomic value change is musically click-free.

Choose atomic types supported appropriately on each target. "Lock-free" alone is not a guarantee of bounded completion for an individual operation.

### 8.3 Diagnostics and budgets

Collect bounded counters or records and format them on a non-realtime thread. Track callback duration, deadline misses, backend xruns, queue overflow, and discontinuities separately.

The nominal block duration is `frames / sample_rate`. For example, 128 frames at 48 kHz correspond to approximately 2.667 ms. DSP cannot consume that entire interval safely; adapters, scheduling, and other work need headroom.

Measured worst-observed time is useful evidence, not proof of a hard realtime bound on every operating-system configuration.

## 9. ALSA duplex backend and Linux server

### 9.1 Retain the callback-driven backend

The existing backend deserves incremental repair, not replacement merely because it uses direct ALSA. Keep the engine-facing contract independent from PCM details.

Target callback invariant:

```text
input.frame_count == output.frame_count == process_context.frame_count
```

Input and output channel counts may differ. Do not confuse equal frame counts with equal channel layouts or with proof that two physical devices share a clock.

### 9.2 Source-confirmed repair candidates

In the inspected driver, `commit()` and the suspended branch of `checkState()` route recovery to playback regardless of the requested stream. `begin()` sets playback-stopped state even for capture and can continue after a failed MMAP begin without a new successful begin. The duplex loops negotiate and commit frame counts independently. Some read/write/commit paths can return a negative ALSA result as the numeric success payload after recovery. [D5]

Treat these as concrete source-level repair candidates. Runtime consequences require tests; do not assume every device or path triggers every issue.

### 9.3 Define transfer behavior before patching individual branches

ALSA permits `snd_pcm_mmap_begin()` to reduce the requested frame count, including to zero. Its documentation requires an availability update immediately before beginning access and a matching commit to complete access. [R5]

For each callback, derive a positive common frame count from valid capture/playback regions, cap it to engine capacity, process exactly that count, and attempt to commit that count on both streams. Refresh regions after recovery; never access an area from a failed begin.

Do not treat `min(capture_committed, playback_committed)` as a rollback mechanism. One stream may already have advanced further. A short or failed commit needs a deliberate discontinuity/recovery policy, not silent accounting that pretends both transfers matched.

In the RW path, retain offsets and any pending output across partial transfers, or adopt an explicit recovery policy. Do not invoke DSP twice for samples that were already rendered merely because a write was short.

Reject or handle negative return values before unsigned conversion. Bound zero-progress behavior. On a discontinuity, specify whether to clear output, drop capture, reset buffers, and/or reset DSP state.

### 9.4 Clocking and lifecycle

ALSA stream linking joins state-management operations, but its documentation does not promise sample synchronization on hardware without that capability. [R6]

Initial supported scope should be one verified clock domain. For independent devices, later add a master-clock policy, occupancy tracking, buffering, and drift compensation/resampling, or reject the configuration. Matching nominal sample rates is insufficient evidence.

Design a lifecycle such as:

```text
closed -> configured -> prepared -> running
                                    |
                                 recovering
                                    |
                       prepared / stopped / failed
```

Keep recovery ownership on one backend thread. Use explicit policy for underrun/overrun, suspend, disconnect, unsupported configuration, and shutdown. Ensure stopping can wake a thread waiting for device readiness.

Test MMAP and RW independently. Validate format widths, area strides, interleaving, channel counts, and negotiated rates instead of assuming all devices match the initial hardware.

### 9.5 Grow a server in separate stages

First deliver an in-process engine over ALSA. Then add a server process with control messages while all DSP remains in the server. This provides useful graph ownership and routing without immediately requiring client-process DSP synchronization.

Only later add shared-memory audio and external realtime clients. That stage needs protocol versioning, permissions, client crash/timeout policy, bounded shared buffers, scheduling, and a policy for missed client deadlines. Do not make the render thread wait indefinitely for a client.

A Delia server does not automatically replace desktop session policy, device sharing, Bluetooth routing, or other system-audio services. Treat those integrations as separate scope.

## 10. CoreAudio and external dependencies

Add CoreAudio after the engine has a backend-independent offline test path. Plan for callback lifecycle, negotiated formats, buffer-size changes, device changes, timestamps, and clean shutdown. Do not make an assumed "easy backend" substitute for lifecycle tests.

Use external projects selectively:

| Reference | Proposed role | Reuse policy |
|---|---|---|
| miniaudio | Device/API and node-graph reference | Public-domain or MIT No Attribution options; inspect the selected source version. [R7] |
| KISS FFT | Readable mixed-radix reference and correctness comparison | BSD-licensed reference; audit the exact execution path before realtime reuse. [R4] |
| SuperCollider | Server, synthesis-unit, scheduling, and control concepts | GPL-3.0 project; resolve licensing before implementation reuse. [R8] |
| JUCE | Framework/API and integration reference | Review the licence for the exact version and intended distribution. [R9] |
| FFmpeg | Initial codec/container binding outside the callback | Predominantly LGPL; enabled components can change applicable terms. [R10] |

Do not assume that a port inherits production performance or realtime behavior. For example, KISS FFT documents a temporary-buffer path when input and output are the same. Verify configuration and call paths, not just a library's reputation. [R4]

Keep a dependency/provenance register: upstream version or commit, source files, licence, modifications, notices, build options, and intended distribution. Obtain appropriate licence review before shipping copied or translated code; this report is not a distribution-licence clearance.

Decode or read media into bounded buffers outside realtime processing. The audio thread should consume prepared samples, not discover files or invoke an unrestricted decoding pipeline.

## 11. Proposed source organization

Treat this as a destination, not the first refactoring task:

```text
src/
  core/                 buffer views, owning storage, formats, process context
  dsp/
    complex/            representations and non-owning math helpers
    fft/                reference, plan, workspace, scalar, vector, analysis
    filters/
    oscillators/
    delay/
    convolution/
  graph/                builder, validation, compiler, execution plan, buffers
  realtime/             bounded queues, event delivery, diagnostics
  backends/
    alsa/
    coreaudio/
  media/                WAV and external codec adapters
  analysis/             allocating workflows and integration helpers
  server/               later control/IPC layer; depends on the engine

tests/                  subsystem, integration, and fault-injection tests
bench/                  reproducible microbenchmarks and workloads
examples/               offline rendering and minimal device applications
docs/                   contracts, decisions, hardware matrix, provenance
```

Dependencies should point toward the core. Numerical kernels must not import the server, graph builder, device backend, or an allocating analysis container.

## 12. Implementation milestones

Proceed by acceptance criteria, not calendar promises. FFT and graph development can diverge after the buffer contract; the initial sine/gain graph does not depend on FFT completion.

**Order: M1, then M3, then M2.** Milestone numbers are identifiers, not the sequence. The offline graph slice is the first real consumer of the buffer contract, so it exposes contract mistakes while they are still cheap to fix. The FFT is independent of both and can follow. **M0 is complete** apart from tagging the reference point, and **M1 is complete** (see the notes at the top). The next milestone is M3.

| Milestone | Implementation scope | Exit criteria |
|---|---|---|
| M0: Reproducible baseline (done) | Pin repository/compiler/dependencies; inventory tests; preserve a reference branch | A fresh checkout has documented build/test commands; failures are recorded, not concealed |
| M1: Buffer contracts (done) | Owned/borrowed types, planar blocks, stride-aware sub-blocks, conversion helpers, node I/O contract | Ownership, bounds, layout, partial-block, and overlap tests pass |
| M2: Planned scalar FFT | Plan/workspace lifecycle; scalar radix-2; explicit normalization; analysis adapter | Independent forward/inverse tests pass; repeated execution performs no allocation; no shared mutable scratch |
| M3: Offline graph slice | Sine -> Gain -> Output; then fan-out and explicit mixer; flat execution | Deterministic offline output; repeated blocks correct; all active outputs written; no render allocations |
| M4: Backend integration | ALSA transfer/lifecycle repairs and the same graph callback; CoreAudio may follow independently | Fault-injection tests plus documented full-duplex hardware run; clean start/stop and bounded recovery policy |
| M5: Control and plan replacement | Bounded parameter events; smoothing; publication and off-thread retirement | Overflow behavior, timing, lifetime stress tests, and audible-transition policy validated |
| M6: Measured optimization | Better stages/radices, SIMD experiments, optional size specialization | Reproducible end-to-end improvements without correctness or realtime regressions |
| M7: Server expansion | Control-only server first; external audio clients later | Protocol/lifetime/deadline policies tested before adding broader routing scope |

Suggested **Delia 0.1** scope: M0-M4 for a documented configuration, with an offline renderer, a small compiled graph, a validated backend, prepared DSP, and explicit limitations. A standalone planned FFT can also be released independently of the engine.

Graph hot-swapping, a complete audio server, and the fastest FFT on every CPU are not prerequisites for a useful first release.

## 13. Testing and performance evidence

### 13.1 Numerical tests

Use deterministic inputs and seeded randomness. Test impulse, DC, bin-centered sinusoids, random complex inputs, inverse reconstruction, real-input symmetry, small boundary sizes, and arbitrary lengths when supported.

Compare small transforms against an independent DFT, preferably accumulated in higher precision. Add an external reference with normalization explicitly reconciled. Test convolution against direct convolution.

Use absolute and relative error together; pure relative error is unsuitable near zero. Set tolerances by scalar type, transform size, and expected numerical behavior. Avoid bitwise equality as the default SIMD acceptance rule.

### 13.2 Memory and execution tests

Use leak detection, allocation-failure injection, and an instrumented allocator that rejects allocation during measured rendering. That instrumentation covers only code using the allocator: audit foreign libraries and indirect allocation separately.

Test two independent FFT executors, repeated transformations, view lifetime, initialization failure cleanup, and destruction order. Test graph diamonds/fan-out, mixers/fan-in, disconnected nodes, invalid connections, and rejected cycles.

Changing block size must not move channel starts incorrectly. Changing graph configuration must not leave buffers undersized or release an active allocation.

### 13.3 Backend tests

Introduce a narrow test seam around PCM operations so scripted outcomes can simulate short/zero transfers, failed begin, failed commit, suspend, timeout, and disconnect without hardware.

Then use loopback/hardware tests to establish actual latency, channel mapping, sustained duplex operation, and recovery behavior. Record hardware, kernel/OS, device configuration, sample rate, periods, buffer sizes, and access mode.

A mocked state machine test does not replace a hardware test, and a successful hardware run does not cover all error branches.

### 13.4 Benchmark rules

Report setup separately from steady-state execution. Use equivalent transform direction, normalization, input layout, output layout, and precision. Include conversion overhead when it is part of the public API.

Record compiler version, optimization mode, CPU target/features, machine, transform sizes, warm-up, iteration count, and memory footprint. Restore inputs appropriately when benchmarking in-place transforms; consume outputs so work remains observable.

For the engine, measure complete block processing and tail latency under realistic load, not just average isolated FFT throughput. Keep hardware performance thresholds separate from portable correctness CI.

## 14. Learning and development workflow

For each change, write the contract and a prediction before the implementation. Keep a contract document to about a page of rules and a test list: it should be quicker to read than the code it governs, and it is allowed to be wrong and revised once the first consumer exists. Read a narrowly selected reference, explain the algorithm, build the simplest correct version, test it independently, and only then optimize.

Keep changes small enough to answer one question: "Does this view preserve stride?", "Does this FFT convention match the DFT?", or "Does this SIMD layout improve a complete transform?"

Use assistance for mathematical derivations, source review, adversarial test cases, ownership/lifetime review, benchmark design, and assembly interpretation. Do not accept generated code as correct merely because it is plausible or compiles.

Maintain a short decision log with the problem, alternatives, evidence, decision, and conditions for revisiting it. Preserve failed optimization experiments when their measurements explain a design choice.

Prefer readable scalar kernels over a generic kernel framework invented before the second implementation exists. Abstract where actual variation appears.

## 15. Decisions and immediate backlog

### Proposed defaults

| Question | Initial decision |
|---|---|
| Rewrite the repository from scratch? | No; migrate incrementally with comparison tests |
| Remove the convenient analysis interface? | No; layer it above explicit planned computation |
| Require compile-time FFT sizes? | No; keep optional specialization as an evidence-driven extension |
| Require all kernels to use one internal complex layout? | No; standardize the public contract, permit backend-specific internals |
| Canonical graph audio? | Planar `f32`, with explicit stride and bounded frame count |
| Buffer representation? | Contiguous storage plus `channel_stride`; not a slice of channel slices |
| Node I/O? | Separate const inputs and writable outputs per port; in-place is a later compiler optimization |
| Milestone order? | M1, M3, M2: the graph slice validates the buffer contract before the FFT work starts |
| Graph execution model? | Single render thread and precompiled DAG operations initially |
| Graph replacement? | Stop/reprepare first; bounded publication and retirement later |
| Linux backend? | Direct ALSA; Delia server as a later layer |
| Rewrite codecs? | No; isolate bindings and keep decoding off the callback |

### First implementation backlog

Listed in working order (M1, M3, M2, M4).

- [x] Record the exact starting commit, compiler version, dependency versions, and current build/test failures. Done: commit `b1aaad0`, Zig 0.16.0, zBench v0.13.0, 114/114 tests passing, `minimum_zig_version` set in the manifest. [D6]
- [ ] Tag the reference point (for example `pre-refactor`) so old implementations stay reachable for comparison.
- [x] Write `docs/buffer-contract.md`, including the node I/O contract.
- [x] Implement `src/core/buffer/block.zig` (`AudioBlock`, `ConstAudioBlock`) against the contract and add it to a `test` block reachable from `src/main.zig`.
- [x] Implement `OwnedAudioBuffer` and `AudioBufferPool`, then the block operations (`clear`, `copy`, `accumulate`, `interleave`, `deinterleave`).
- [x] Add `ProcessContext` with separate inputs and outputs, tested with a gain node and a source node.
- [ ] Add regression tests for the scheduler's inverted buffer-reuse branch and for mismatched copy shapes in the old views, before the scheduler migrates.
- [ ] Build the offline Sine -> Gain -> Output slice on the new node I/O contract; add fan-out/mixing before optimizing buffer reuse.
- [ ] Add a regression test for `ComplexList` logical length versus capacity.
- [ ] Write `docs/fft-contract.md`: direction, normalization, ordering, supported lengths, aliasing, workspace, and ownership.
- [ ] Extract an independent reference DFT and build one planned scalar radix-2 implementation.
- [ ] Keep an allocating analysis adapter so existing experiments remain useful.
- [ ] Repair ALSA return-value/recovery/transfer invariants with scripted failure tests before relying on audible playback alone.

### Release gate

Call a supported configuration production-ready only when its build is reproducible, numerical and memory tests pass, render-path restrictions are checked, deadlines have measured headroom, hardware behavior is documented, and failures/shutdown have explicit policies.

**The next substantive refactor is ownership and execution contracts, not SIMD and not a repository-wide rename.** Once those boundaries hold, FFT optimization, graph compilation, and the Linux server become separate, testable advances rather than one coupled rewrite.

## 16. Source register

Repository files were inspected from `main` on the report date. Capture commit-pinned links in the project decision log before relying on exact line locations.

| ID | Source | Relevance |
|---|---|---|
| [D0] | Delia repository | Project under review |
| [D1] | `src/common/audio_buffer.zig` | Ownership, views, pool, copy semantics, tests |
| [D2] | `src/dsp/complex_list.zig` | Storage representation, ownership mode, accessors, resize |
| [D3] | `src/dsp/transforms.zig` | Static/dynamic transforms, twiddles, reference tests |
| [D4] | `src/graph/scheduler.zig` | Preparation, execution, buffer allocation/reuse |
| [D5] | `src/backends/alsa/driver.zig` | Duplex transfer and recovery implementation |
| [D6] | `build.zig.zon` | Package/dependency declaration |
| [R1] | Zig language reference: namespace-level variables | Global lifetime of namespace storage |
| [R2] | FFTW: using plans | Plan/execution separation |
| [R3] | FFTW: thread safety | Plan sharing versus data-array ownership |
| [R4] | KISS FFT repository/README | Algorithm, spectrum layout, licensing, temporary-buffer caveat |
| [R5] | ALSA: direct MMAP access | Availability, begin, region lengths, commit semantics |
| [R6] | ALSA: PCM interface | Stream synchronization and lifecycle background |
| [R7] | miniaudio repository | Device/node-graph reference and licensing |
| [R8] | SuperCollider repository | Server architecture reference and licensing |
| [R9] | JUCE 8 licence | Version-specific reuse review |
| [R10] | FFmpeg legal information | Configuration-dependent licensing |

[D0]: https://github.com/pbotsaris/Delia-audio
[D1]: https://github.com/pbotsaris/Delia-audio/blob/main/src/common/audio_buffer.zig
[D2]: https://github.com/pbotsaris/Delia-audio/blob/main/src/dsp/complex_list.zig
[D3]: https://github.com/pbotsaris/Delia-audio/blob/main/src/dsp/transforms.zig
[D4]: https://github.com/pbotsaris/Delia-audio/blob/main/src/graph/scheduler.zig
[D5]: https://github.com/pbotsaris/Delia-audio/blob/main/src/backends/alsa/driver.zig
[D6]: https://github.com/pbotsaris/Delia-audio/blob/main/build.zig.zon
[R1]: https://ziglang.org/documentation/master/#Namespace-Level-Variables
[R2]: https://www.fftw.org/fftw3_doc/Using-Plans.html
[R3]: https://www.fftw.org/fftw3_doc/Thread-safety.html
[R4]: https://github.com/mborgerding/kissfft
[R5]: https://www.alsa-project.org/alsa-doc/alsa-lib/group___p_c_m___direct.html
[R6]: https://www.alsa-project.org/alsa-doc/alsa-lib/pcm.html
[R7]: https://github.com/mackron/miniaudio
[R8]: https://github.com/supercollider/supercollider
[R9]: https://juce.com/legal/juce-8-licence/
[R10]: https://ffmpeg.org/legal.html
