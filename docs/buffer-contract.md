# Buffer contract

**Status:** implemented in `src/core/buffer/` for milestone M1 (`docs/DELIA_REFACTOR_PLAN.md`,
section 4). Every acceptance item in section 9 has a test in `src/core/buffer/root.zig`.
**Example:** `docs/examples/audio_block_sketch.zig` is the design sketch that preceded the
implementation. It uses older names (`BlockError`, `block()`, `slot()`); the code in
`src/core/buffer/` is authoritative.

| File | Contents |
|---|---|
| `root.zig` | public surface and tests; root of the `buffer` module, the only file other modules import |
| `block.zig` | `AudioBlock`, `ConstAudioBlock` |
| `storage.zig` | `OwnedAudioBuffer`, `AudioBufferPool` |
| `ops.zig` | `clear`, `copy`, `accumulate`, `interleave`, `deinterleave`, `blocksOverlap` |
| `shape.zig` | `Shape`, `AudioBufferError`, alignment and size arithmetic |

The new types live alongside `src/common/audio_buffer.zig`. The old types stay untouched
until the scheduler migrates in M3.

## 1. Types

| Type | Owns memory | Allocator | Writable | Role |
|---|---|---|---|---|
| `OwnedAudioBuffer(T)` | yes | passed to `init` and `deinit`, not stored | via `borrowBlock()` | one buffer: analysis, tests, device adapters |
| `AudioBufferPool(T)` | yes | passed to `init` and `deinit`, not stored | via `borrowSlot()` | graph scratch: N same-shaped slots, one allocation |
| `AudioBlock(T)` | no | none | yes | what a kernel or node writes to |
| `ConstAudioBlock(T)` | no | none | no | what a kernel or node reads from |

`T` is `f32` or `f64`; anything else is a compile error. Graph audio is `f32`.

Blocks are small values (slice plus three integers) and are passed by value. Owning types are
not copied: one value, one `deinit`.

## 2. Layout

A block is contiguous planar storage described by four fields:

```text
samples          borrowed sample storage
channel_count    number of channels, at least 1
frame_count      valid frames for this operation (runtime usize)
channel_stride   samples between adjacent channel starts

channel(c) = samples[c * channel_stride ..][0 .. frame_count]
```

- `frame_count` is how much audio is valid now. `channel_stride` is where channels physically
  start. They are equal only for tightly packed storage.
- `frame_count` is a plain `usize`. `specs.BlockSize` remains the type for the *declared maximum*
  block size in preparation options; it is not the type of a block's current length.
- Samples at `channel(c)[frame_count..channel_stride]` are padding. No operation reads or writes
  them.
- Sample rate and device format are not part of a block. They live in the prepare/process context.

## 3. Creating views

Validated when a block is created, returning an error (never a panic) on failure:

| Check | Error |
|---|---|
| `channel_count >= 1` | `zero_channels` |
| `frame_count <= channel_stride` | `frames_exceed_stride` |
| `channel_count * channel_stride` does not overflow | `size_overflow` |
| `samples.len >= channel_count * channel_stride` | `storage_too_small` |
| sub-block or slot range inside the parent | `out_of_range` |

`channel(c)` only asserts `c < channel_count`. Everything it relies on was checked at creation.

**Sub-blocks.** `subBlock(first_frame, frame_count)` keeps `channel_count` and `channel_stride`
and moves the base of `samples` forward by `first_frame`. It never repacks. Two sub-blocks
covering different frame ranges of one parent share no samples.

**Zero frames.** `frame_count == 0` is a valid block. `channel(c)` is an empty slice and every
operation on it does nothing.

**Const.** `AudioBlock.asConst()` gives a `ConstAudioBlock` over the same samples. There is no
conversion back.

## 4. Owning storage

- Channel starts are aligned to 64 bytes. To keep that true, the owner rounds the requested
  frame capacity up to a multiple of `64 / @sizeOf(T)` samples and uses that as `channel_stride`.
  `max_frames` stays the requested capacity: `borrowBlock(n)` and `borrowSlot(i, n)` reject `n > max_frames`.
- Storage is zeroed at `init`.
- A pool slot spans `channel_count * channel_stride` samples. Slot `i` and slot `j` never share
  samples.
- The pool is a fixed shape. A different channel count, frame capacity, or slot count means
  building a new pool during preparation and releasing the old one after rendering has stopped
  using it. There is no in-place resize.

## 5. Lifetime

- A block is valid until its owner's `deinit`, or, for device memory, until the access interval
  that produced it ends (for ALSA MMAP: between a successful begin and its commit).
- Blocks are not stored across process calls by nodes. A node receives its blocks each call.
- Owners are created and destroyed outside the render path.

## 6. Operations

Free functions over blocks. None allocate, lock, log, or touch padding.

| Operation | Meaning | Shape rule | Overlap rule |
|---|---|---|---|
| `clear(dst)` | `dst = 0` over active frames | none | n/a |
| `copy(dst, src)` | `dst = src` | same channel and frame count; strides may differ | must be disjoint |
| `accumulate(dst, src)` | `dst += src` | same channel and frame count; strides may differ | must be disjoint |
| `interleave(dst, src)` | planar block to packed interleaved slice | `dst.len == channels * frames` | must be disjoint |
| `deinterleave(dst, src)` | packed interleaved slice to planar block | `src.len == channels * frames` | must be disjoint |

- A shape violation returns `shape_mismatch`. An overlap violation returns `forbidden_overlap`.
  Nothing is written when an operation fails.
- **Copying is not mixing.** Fan-in uses `clear` then `accumulate` per contribution.
- Channel mapping (mono to stereo, downmix) is a separate, explicit operation. `copy` never
  guesses.
- Raw storage copy (ignoring shape) is not offered on blocks.
- Interleaved audio exists only at device and file boundaries. Kernels and nodes see planar
  blocks and never branch on layout per sample.

## 7. Aliasing

"Overlap" means at least one *active* sample is reachable through both blocks. It is decided per
channel slice, so padding and disjoint frame ranges do not count.

Every kernel states which of these it supports:

| Mode | Meaning |
|---|---|
| disjoint | input and output share no active samples |
| exact in-place | input and output are the same block: same base, shape, and stride |
| partial overlap | anything else. Always forbidden. |

The default is disjoint only. A kernel supports exact in-place only if it says so and has a test
for it.

## 8. Node I/O

```text
Node(T).ProcessContext                        defined in src/graph/nodes/node.zig
    inputs       []const ConstAudioBlock(T)    one block per input port
    outputs      []const AudioBlock(T)         one block per output port
    frame_count  usize
```

The type lives with the node contract, not here: `core/buffer` knows nothing about nodes. The
rules below are what the buffer layer promises to a node; `docs/graph-contract.md` covers the
rest of the node interface.

- Every block in one call has `frame_count == ctx.frame_count`, and
  `frame_count <= max block size` declared at preparation.
- A source node has zero inputs. It does not get a zero-channel block.
- Outputs are disjoint from inputs and from each other. In-place execution is a later compiler
  optimization for nodes that declare exact in-place support; nodes are written as if it never
  happens.
- A node writes every active frame of every output, every call. Output contents on entry are
  unspecified.
- Port counts and channel counts are fixed at preparation. `process` does not validate them and
  does not return an error.
- Fan-in is not a node's concern: a port receives one block. Summing several producers into
  that block is an explicit mix operation emitted by the graph compiler.

## 9. Acceptance tests

- [x] mono, stereo, and multichannel views address the right samples
- [x] partial block: channel `c` starts at `c * channel_stride`
- [x] sub-block preserves stride; out-of-range sub-block rejected
- [x] zero-frame block: valid, operations are no-ops
- [x] bad shapes rejected: zero channels, frames over stride, overflow, short storage
- [x] pool slots independent; slot index and frame count bounds rejected
- [x] channel starts aligned in owned storage
- [x] `copy` and `accumulate`: shape mismatch rejected, overlap rejected, differing strides accepted
- [x] failed operation leaves the destination unchanged
- [x] `accumulate` sums; `copy` replaces
- [x] interleave/deinterleave round trip; wrong packed length rejected
- [x] writes confined to active frames (sentinel in padding and in frames past `frame_count`)
- [x] owner `init` cleans up under allocation failure (`std.testing.checkAllAllocationFailures`)
- [x] a node processes a partial block through separate input and output without touching its input
      (moved to `src/graph/nodes/node.zig` with `ProcessContext`)

## 10. Open questions

Revisit when the first real consumer needs an answer, not before.

- ~~Does any node need ports with different channel counts in one pool?~~ Closed by
  `docs/graph-contract.md` section 2: every port carries the graph's channel count, the pool
  stays uniform.
- ~~Should render-path operations keep returning errors once the graph compiler validates shapes
  at preparation?~~ Closed by `docs/graph-contract.md` section 5: ops keep their errors,
  `ExecutionPlan.render` discharges them once after its entry check.
- Strided and interleaved *views* (as opposed to conversion functions) for device adapters:
  add only if M4 shows a copy that matters.
