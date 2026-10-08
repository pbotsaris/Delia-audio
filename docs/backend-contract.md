# Backend contract

**Status:** in progress for milestone M4 (`docs/DELIA_REFACTOR_PLAN.md`, section 9).
`src/backends/alsa/` implements sections 3 to 7 for playback (`device.zig`, `pcm.zig`,
`loop.zig`, `convert.zig`, see its `README.md`); the old backend and graph were deleted in
October 2026, before the M4a hardware run, and are in git history. Remaining for M4a:
`src/examples.zig` on `ExecutionPlan` and the documented `hw:` run.
**Sketches:** two self-contained files under `docs/examples/`.
`device_loop_sketch.zig` (9 tests, `zig test docs/examples/device_loop_sketch.zig`) drives the
loop with a scripted PCM, so the transfer rules in section 4 are tested without hardware.
`alsa_device_sketch.zig` (6 tests) is the real seam and the device; it links alsa-lib
(`zig test docs/examples/alsa_device_sketch.zig -I vendor/alsa/include vendor/alsa/src/.libs/libasound.a -lc`)
and runs the whole open/negotiate/prepare/render/stop/close path on ALSA's `null` plugin, which
every machine with alsa-lib has.

Builds on `docs/buffer-contract.md` (blocks, lifetime, layout at boundaries) and
`docs/graph-contract.md` (what `ExecutionPlan.render` accepts). The engine-facing side of a
backend is the callback signature in section 2; everything else here is how the backend upholds it.

| File | Contents | Links alsa-lib |
|---|---|---|
| `src/backends/alsa/convert.zig` | `SampleFormat`, `SampleConverter(fmt)`: device bytes to and from planar `f32` blocks, one pass. Backend-neutral in content; moves up to `src/backends/` when a second backend needs it | no |
| `src/backends/alsa/loop.zig` | `PcmError`, `Region`, `Stats`, `LoopOptions`, `PlaybackLoop(Ctx, Pcm, fmt)`: the policy, generic over the seam | no |
| `src/backends/alsa/pcm.zig` | `AlsaPcm`: the seam over `snd_pcm_*`; `regionFromArea` | yes |
| `src/backends/alsa/device.zig` | `PlaybackDevice(Ctx, fmt)` (later `CaptureDevice`, `FullDuplexDevice`): open, negotiate, prepare, own the seam and the loop | yes |
| `src/core/buffer/ops.zig` | existing `interleave`/`deinterleave`: `f32` layout change only, used when the device already delivers `f32` | no |

`loop.zig` has no C import on purpose: `zig test` on it needs nothing, and the loop's tests
drive it with a scripted `Pcm` instead of a device.

## 1. Slices

M4 is delivered in three slices with separate exit criteria. Each one is a working state.

| Slice | Scope | Exit |
|---|---|---|
| M4a | half-duplex playback on MMAP interleaved; callback receives blocks; `convert.zig` for `S16_LE`; `src/examples.zig` renders an `ExecutionPlan`; `src/legacy/` and `src/common/audio_buffer.zig` deleted | documented hardware run; `zig build test` has no legacy tests |
| M4b | `Pcm` seam; half-duplex loop rewritten on it against section 4; `stop()` | every section 4 rule has a scripted test |
| M4c | full-duplex on the seam: common frame count, per-stream recovery, linked and unlinked, RW path | scripted duplex tests; documented full-duplex hardware run |

## 2. Callback

Three sizes, three words. `buffer_size` in the legacy driver meant the period; the new backend
uses ALSA's own terms.

```text
period        frames the device hands over per wakeup (ALSA period_size); the loop's unit.
              Option: period_frames (type specs.BufferSize until that enum is renamed).
block         what one callback call receives: an AudioBlock(f32) with frame_count <= period_frames.
              One per period, unless a short `begin` splits a period into several.
graph block   what render() takes: frame_count <= plan.max_frames. The callback sub-blocks the
              device block into these. Same type, no new word.
buffer        the hardware ring, period * n_periods (ALSA buffer_size). The loop never sees it.
```

```text
PlaybackDevice(Ctx, fmt)     callback: fn (ctx: *Ctx, out: AudioBlock(f32)) void
CaptureDevice(Ctx, fmt)      callback: fn (ctx: *Ctx, in: ConstAudioBlock(f32)) void
FullDuplexDevice(Ctx, fmt)   callback: fn (ctx: *Ctx, in: ConstAudioBlock(f32), out: AudioBlock(f32)) void
```

- The callback never sees device bytes, sample formats, or interleaving. It sees planar `f32`
  blocks, the graph's native representation.
- `0 < frame_count <= period_frames`. The backend never calls the callback with zero frames.
- Full duplex: `in.frame_count == out.frame_count`, always. Channel counts may differ between the
  two streams; neither is adjusted to the other.
- `out` contents on entry are unspecified. The callback writes every active frame of every
  channel; the backend does not clear it first. (Same rule as a node output, buffer-contract 8.)
- Blocks are valid for the duration of the call only. A block over MMAP memory is valid between
  the `begin` that produced it and its `commit` (buffer-contract 5).
- The callback follows plan 8.1: no allocation, locks, logging, I/O, or waiting. The backend does
  not enforce this; the test in section 9 (render allocates nothing) is the check.
- Device period and graph block are unrelated. The callback renders `out` as a sequence of
  `subBlock`s of at most `plan.max_frames`; `render` accepts any `frame_count <= max_frames`.

## 3. Preparation

Everything negotiated or allocated happens in `init`/`prepare`, before `start`.

- **Access and format are negotiated best-first** and the result is fixed for the device's
  lifetime. The chosen row decides the boundary step in section 5; it is logged once at prepare,
  never in the loop.

  | Preference | Access | Format | Boundary step |
  |---|---|---|---|
  | 1 | `MMAP_NONINTERLEAVED` | `FLOAT_LE` (native) | none: the areas are a planar `f32` block, zero copy |
  | 2 | `MMAP_NONINTERLEAVED` | integer | per-channel sample decode, no reordering |
  | 3 | `MMAP_INTERLEAVED` | `FLOAT_LE` (native) | `ops.interleave`/`deinterleave` |
  | 4 | `MMAP_INTERLEAVED` | integer | `SampleConverter(fmt).readInterleaved`/`writeInterleaved` |
  | 5 | `RW_INTERLEAVED` | any | row 3 or 4 into the device's transfer buffer |

  M4a implements row 4 only (the common `hw:` case). Rows 1 to 3 and 5 reject at prepare with
  `unsupported_access` until implemented; the callback type does not change when they are added.

- **Staging.** Rows 2 to 5 need planar `f32` storage between the callback and the device. The
  device owns it: one `OwnedAudioBuffer(f32)` per stream, `channels x period_frames`,
  allocated in `prepare`, freed in `deinit`. Row 1 needs none.
- **Configuration checks** that belong here, not at render: the plan's `channel_count` equals the
  stream's channels; the plan's `sample_rate` equals the negotiated rate (ALSA may change the
  requested rate; read it back); `period_frames * n_periods` equals the hardware buffer that was
  actually set. A `shape_mismatch` from `render` inside the callback is a bug in this section.
- MMAP area geometry (`first`, `step`, bytes per sample) is validated once here against the
  negotiated format. The loop trusts it.
- `timeout` for `snd_pcm_wait` is finite. Infinite waits make `stop()` unobservable.

## 4. Transfer

One period per iteration. Rules for the MMAP loops; the RW path differs where noted.

- `avail_update` is called immediately before `begin`, each time. Never reuse an earlier value.
- `begin` may return fewer frames than requested, including zero. The returned count is the
  **only** frame count for this block: it sizes the block, the callback, and the `commit`.
- Full duplex: begin both streams, take
  `frame_count = min(capture.frame_count, playback.frame_count)`, and commit exactly that on
  both. The callback sees one `frame_count`. The unused tail of the longer region is not touched
  and not committed.
- A failed `begin` leaves no usable region. Recover, count a discontinuity, abandon the block.
  The callback is not called and nothing is committed. The areas pointer from the failed call is
  never dereferenced.
- `commit` returning fewer frames than requested, or an error, is a **discontinuity**, not a
  rollback. Frames that were rendered but not committed are lost; the callback is not called
  again for them. The policy is: recover, count, continue with the next period.
- Zero progress (`begin` returns 0, or `commit` returns 0) is bounded: after
  `max_zero_transfers` consecutive occurrences the loop returns `no_progress`.
- Negative ALSA results are converted to errors at the `Pcm` seam. No unsigned cast ever sees a
  negative value; no success path returns a negative count.
- RW path: a short `write` keeps the un-written remainder of the staging block and retries
  without calling the callback again. A short `read` is a discontinuity for that period.
- Discontinuity output policy: on recovery the playback stream is restarted from silence by the
  device (`snd_pcm_prepare`); the backend does not clear staging or reset node state. Resetting
  DSP state is the engine's decision (M5), not the backend's.

## 5. Boundary step

Two independent axes, resolved once at prepare (section 3):

- **Layout**: interleaved (`index = frame * channels + channel`) or planar
  (`index = channel * stride + frame`). `ops.interleave`/`deinterleave` change layout only; both
  sides are `f32`.
- **Sample format**: how one sample is encoded (`S16_LE`, `S32_LE`, `FLOAT_LE`, ...). Decoding one
  sample knows nothing about layout.

`convert.zig` is the one place that does both in a single loop, because the device buffer needs
both and two passes would cost a scratch buffer. It is still two concepts: the function names
carry the layout (`readInterleaved`), the type parameter carries the encoding.

```text
SampleFormat                 enum { s16_le, s32_le, f32_le, ... }   a tag, no kernels

SampleConverter(comptime fmt: SampleFormat)
    bytes_per_sample         comptime usize
    byteLength(channels, frames)                              usize
    encode(dst: *[bytes_per_sample]u8, sample: f32)           one sample, no layout
    decode(src: *const [bytes_per_sample]u8)                  f32
    readInterleaved(dst: AudioBlock(f32), src: []const u8)    ConvertError!void
    writeInterleaved(dst: []u8, src: ConstAudioBlock(f32))    ConvertError!void
    readPlanar / writePlanar                                  later, for non-interleaved devices
```

- A comptime-specialized type, same idiom as `HalfDuplexDevice(Ctx, opts)`: a loop does
  `const Convert = SampleConverter(fmt)` once and the format never appears in a call again.
  Not methods on the enum (a comptime `self` reads like runtime dispatch and is not), and not
  generic over the float type (graph audio is `f32`; add `T` when a consumer needs `f64`).
- `src.len` (or `dst.len`) must equal `byteLength(channel_count, frame_count)`; otherwise
  `size_mismatch` and nothing is written.
- Integer encode **clamps to [-1, 1] first**, then scales symmetrically by `maxInt` and rounds to
  nearest. `@intFromFloat` on an unclamped value is checked UB on the audio thread.
- Integer decode divides by the same `maxInt`. Round trip error is at most `1 / maxInt`.
- `f32` only. No `f64` intermediate; 24/32-bit formats decode straight to `f32`.
- Padding (`frame_count..channel_stride`) is never read or written.

## 6. Lifecycle

```text
closed -> configured -> prepared -> running -> stopped
                            ^          |
                            +-- recovering (xrun, suspend)
```

- `start(ctx, callback)` runs the loop on the calling thread until `stop()` or an unrecoverable
  error. `stop()` may be called from another thread; it sets an atomic flag that the loop checks
  once per period, so with a finite `timeout` it returns within one period plus one timeout.
- Recovery is owned by the loop thread. Nothing else calls `snd_pcm_prepare`/`snd_pcm_resume`.
- Each stream recovers itself. A playback xrun does not prepare the capture handle, and the other
  way round. Linked streams recover through the master only, because `snd_pcm_link` joins their
  state transitions.
- Recovery that fails after a bounded retry returns from `start` with the error; the device is in
  `stopped` and `prepare` is needed before `start` again.
- Diagnostics are bounded counters on the loop (`xruns`, `discontinuities`, `zero_transfers`,
  `short_commits`), read and formatted off the loop thread. The loop does not print.
  `xrunRecovery`'s `std.debug.print` moves behind this rule.
- `deinit` after `stop`. Staging is freed here, never while the loop can touch it.

## 7. The `Pcm` seam

The loops are generic over a `Pcm` type providing exactly what they call, so scripted outcomes
can drive every branch of section 4 without hardware:

```text
availUpdate()                 error!usize
start()                       error!void
wait(timeout_ms)              error!void
mmapBegin(want)               error!Region        Region { bytes: []u8, frame_count: usize }, frame_count <= want
mmapCommit(frame_count)       error!usize         may be < frame_count
recover(err)                  error!void          prepare or resume; bounded
state()                       State
```

`AlsaPcm` is the thin real implementation: it converts negative results to errors and computes
the region slice from `areas`, `offset` and `step`. It contains no policy. The scripted one
replays a list of outcomes and records every committed byte to a "wire" so tests can compare the
device's output with an offline render.

## 8. Ownership

| Value | Owns | Freed by |
|---|---|---|
| `HalfDuplexDevice` / `FullDuplexDevice` | PCM handle(s), staging buffer(s), RW transfer buffer(s) | `deinit`, after `stop` |
| the loop | counters, running flag | with the device |
| `Ctx` | the plan and everything it needs | the caller, after `deinit` |

The device never owns or sees the `ExecutionPlan`. A block handed to the callback is borrowed
from staging or from MMAP memory; the callback keeps nothing.

## 9. Acceptance tests

Prediction, written before implementation: a 440 Hz sine rendered through the scripted device
with `begin` returning 512, 300 and 212 frames over two periods of 512 produces, on the wire,
bytes identical to one offline render of 1024 frames converted with `writeInterleaved`. The
split is invisible because phase lives in the node, not in the block.

Scripted (M4a sketch, M4b real):

- [x] blocks of 512, 300 and 212 equal one offline render byte for byte (prediction above; sketch)
- [ ] `begin` shorter than requested: callback gets exactly the returned count, commit matches
- [ ] failed `begin`: callback not called, region not touched (sentinel), recovery counted, next
      period proceeds
- [ ] short `commit`: counted as discontinuity, callback not called again for the lost frames
- [ ] zero progress: `no_progress` after `max_zero_transfers`
- [ ] `stop()` from another thread returns `start` within one period
- [ ] encode clamps: `1.5` and `-1.5` map to `maxInt` and `-maxInt`; no panic
- [ ] `S16_LE` round trip within `1 / 32767`; wrong byte length rejected, nothing written
- [ ] staging padding keeps its sentinel after a short block
- [ ] the loop allocates nothing after `prepare` (allocation count unchanged over 100 periods)
- [ ] full duplex (M4c): `begin` returns 512 and 300, both streams commit 300, callback sees 300
- [ ] full duplex (M4c): xrun on capture prepares capture only

Hardware, documented in `src/backends/alsa/README.md` with card, kernel, rate, period, access:

- [ ] M4a: `src/examples.zig` plays the fan-in graph from `src/graph/examples.zig` on `hw:` for
      60 s with zero xruns at 512/48000
- [ ] M4c: full-duplex loopback (capture fed to output) for 60 s; measured round-trip latency
      recorded

## 10. Open questions

Revisit when a consumer needs an answer.

- Rows 1 to 3 of the negotiation table. Row 1 lets `render` target device memory with no copy
  for `FLOAT_LE` non-interleaved devices; implement when a device that offers it is at hand.
- Fused convert (section 5) versus `deinterleave` then decode in two passes: measure in M6, not
  before.
- Should `ExecutionPlan` grow a `renderChunked(out)` that loops over `max_frames`, or does every
  callback write the loop? Decide after the second backend (CoreAudio) exists.
- Thread ownership: `start` on the caller's thread is the M4 rule. A device-owned thread with
  priority and affinity is M5 or later, alongside the control queue.
- Whether discontinuities should clear the output block before commit (silence) rather than
  committing stale staging. Current rule: nothing is committed for a failed block, so staging is
  never committed stale; revisit if the RW path shows otherwise.
