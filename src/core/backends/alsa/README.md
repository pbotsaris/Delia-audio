# ALSA backend

Direct alsa-lib playback for Delia's realtime layer. The device negotiates with the hardware,
owns a ring-buffer transfer loop, and hands the user a callback that receives planar `f32`
blocks (`AudioBlock(f32)`), the graph's native representation. The callback never sees device
bytes, sample formats or interleaving.

Scope today: half-duplex playback, `MMAP_INTERLEAVED` access, `S16_LE` or `FLOAT_LE` sample
format, one period per loop iteration, the loop running on the caller's thread. Capture and
full duplex are not implemented yet.

## Files

| File | Contents | Links alsa-lib |
|---|---|---|
| `device.zig` | `PlaybackDevice(Ctx, fmt)`: open, negotiate hw/sw params, prepare, own the seam and the loop | yes |
| `loop.zig` | `PlaybackLoop(Ctx, Pcm, fmt)`: the per-period transfer policy, generic over the `Pcm` seam; `Stats`, `LoopOptions`, `LoopError` | no |
| `pcm.zig` | `AlsaPcm`: the seam over `snd_pcm_*`; negative results become `PcmError` here; the module's only `@cImport` | yes |
| `convert.zig` | `SampleFormat`, `SampleConverter(fmt)`: device bytes to and from planar `f32` blocks in one pass | no |
| `examples.zig` | backend-only examples: a device, a context, a callback, no graph | yes |
| `root.zig` | module root; its `test` block aggregates the files above | — |

Everything that touches alsa-lib goes through `pcm.c`. Each `@cImport` produces its own opaque
`snd_pcm_t`, so a second import in another file would not be assignable to the first.
`loop.zig` has no C import on purpose: its tests drive it with a scripted `Pcm` instead of a
device.

## Usage

```zig
const alsa = @import("backends").alsa;

const Ctx = struct {
    phase: f32 = 0,

    fn callback(self: *Ctx, out: buffer.AudioBlock(f32)) void {
        // write every active frame of every channel; nothing is cleared first
        for (0..out.frame_count) |i| {
            const s = @sin(self.phase);
            for (0..out.channel_count) |ch| out.channel(ch)[i] = 0.2 * s;
            self.phase += 2.0 * std.math.pi * 440.0 / 48000.0;
        }
    }
};

const Device = alsa.device.PlaybackDevice(Ctx, .s16_le);

var device = try Device.init(.{
    .ident = "hw:0,0",
    .sample_rate = 48000,
    .channel_count = 2,
    .period_frames = 512,
    .n_periods = 2,
});
defer device.deinit(allocator);

try device.prepare(allocator);
// device.negotiated holds the rate the hardware actually agreed to; use it, not the request

var ctx = Ctx{};
try device.start(&ctx, Ctx.callback); // blocks until device.stop() or an unrecoverable error

const stats = device.getStats();     // periods, blocks, xruns, discontinuities, ...
```

Callback rules:

- Signature `fn (ctx: *Ctx, out: AudioBlock(f32)) void`.
- `0 < out.frame_count <= period_frames`. A period normally arrives as one block, but when
  `snd_pcm_mmap_begin` returns fewer frames than requested (the ring wraps) the period is
  delivered as several smaller blocks. Phase and other state must therefore live in `Ctx`,
  never be derived from the block size.
- `out` is uninitialised on entry. Write every frame.
- No allocation, locks, logging, I/O or waiting inside the callback. The loop is the only
  place that waits.
- The block is borrowed from the device's staging buffer and is valid for the call only.

## How the device works

### `init`: open and negotiate

`snd_pcm_open` in blocking mode, then hardware parameters in this order:

1. access `MMAP_INTERLEAVED` (anything else fails with `access_unsupported`)
2. format from the comptime `SampleFormat` (`S16_LE` or `FLOAT_LE`)
3. channels, exact
4. rate with `set_rate_near`
5. period size with `set_period_size_near`, buffer size with `set_buffer_size_near`
   (`period_frames * n_periods`)
6. `snd_pcm_hw_params` to apply, then read everything back

The period is the loop's unit and the staging buffer's capacity, so if the hardware moved
period or buffer size the device fails with `period_changed`. A moved rate is not an error: it
is reported in `device.negotiated.sample_rate`, and whatever renders audio must be configured
against that value. alsa-lib's `hw_params` struct is freed before `init` returns; only the
negotiated numbers are kept.

### `prepare`: software parameters, geometry, staging

- `avail_min = period_frames`: `snd_pcm_wait` wakes when one period is free.
- `start_threshold = buffer_frames + 1`: the stream never auto-starts on write. The loop starts
  it explicitly, once the ring is full (see below).
- `stop_threshold = buffer_frames`: an underrun stops the stream (ALSA's default behaviour).
- `snd_pcm_prepare`.
- One `snd_pcm_mmap_begin(0)` / `snd_pcm_mmap_commit(0)` to read the area geometry. `first` and
  `step` must be byte-aligned and `step / 8` must equal the negotiated bytes per frame. This is
  checked once here; the loop trusts it afterwards.
- Allocate the staging buffer: an `OwnedAudioBuffer(f32)` of `channel_count x period_frames`.
  This is the only allocation the backend makes, and the only memory the callback writes.

### `start`: the loop

`start` runs on the calling thread and returns when `stop()` is called from another thread or
when the loop hits an error it cannot recover from. One iteration handles one period:

```text
avail = snd_pcm_avail_update()
if avail < period_frames:
    if the stream has not been started yet:    snd_pcm_start(); next period
    else:                                       snd_pcm_wait(timeout_ms)
remaining = period_frames
while remaining > 0:
    region = snd_pcm_mmap_begin(remaining)      may return fewer frames, including zero
    callback(ctx, staging[0..region.frame_count])
    writeInterleaved(region.bytes, staging)     f32 planar -> device bytes
    committed = snd_pcm_mmap_commit(region.frame_count)
    remaining -= committed
```

Why the explicit start: after `prepare` the whole ring is free, so the first `n_periods`
iterations fill it without waiting. Only when `avail` drops below one period does the loop
call `snd_pcm_start`, so the hardware begins playing from a full buffer rather than racing the
first write. After an xrun recovery (`snd_pcm_prepare`) the stream is stopped again and the same
fill-then-start sequence repeats.

Transfer rules:

- `avail_update` is called fresh every period, never reused.
- The frame count returned by `mmap_begin` is the only frame count for that block: it sizes the
  callback's block, the conversion, and the commit.
- A `mmap_begin` that fails leaves no usable region. The callback is not called, nothing is
  committed, a discontinuity is counted and the loop recovers.
- A `mmap_commit` that returns fewer frames than asked (or fails) is a discontinuity, not a
  retry. The rendered frames that were not committed are lost; the callback is not called again
  for them.
- Zero progress (`begin` or `commit` returning 0) is bounded: after `max_zero_transfers` in a
  row the loop returns `no_progress`.

Recovery:

- `-EPIPE` (xrun) and `-ESTRPIPE` (suspended) are converted to `PcmError.xrun` / `.suspended`
  at the seam. The loop counts an xrun and calls `AlsaPcm.recover`: `snd_pcm_resume` with a
  bounded retry on `EAGAIN` for suspend, then `snd_pcm_prepare`. Playback restarts from silence
  on the next period; staging is not cleared and the callback's state is not reset.
- A `snd_pcm_wait` timeout is not an error: the loop just checks the running flag and goes
  around again. This is what makes `stop()` observable, so `timeout_ms` must be finite.
- Any other negative result is `PcmError.io` and ends `start`. A recovery that itself fails ends
  `start` with `failed_recovery`. In both cases call `prepare` again before `start`.

Diagnostics are bounded counters in `Stats` (`periods`, `blocks`, `xruns`, `discontinuities`,
`short_commits`, `zero_transfers`), read with `getStats()` after `start` returns. The loop
never prints.

### `stop` and `deinit`

`stop()` sets an atomic flag the loop reads once per period, so it returns `start` within one
period plus one `timeout_ms`. `deinit` must come after `start` has returned: it frees staging,
`snd_pcm_drop`s pending frames and closes the handle.

## Sample conversion

`SampleConverter(fmt)` does layout and encoding in one pass because the device buffer needs
both and two passes would cost a scratch buffer:

- `writeInterleaved(dst: []u8, src: ConstAudioBlock(f32))` and
  `readInterleaved(dst: AudioBlock(f32), src: []const u8)`; `dst.len`/`src.len` must equal
  `byteLength(channel_count, frame_count)` or nothing is written (`size_mismatch`).
- Integer encode clamps to `[-1, 1]` first, then scales by `maxInt` and rounds. An unclamped
  `@intFromFloat` is checked undefined behaviour on the audio thread.
- Integer decode divides by the same `maxInt`; round trip error is at most `1 / maxInt`.
- `f32` only, no `f64` intermediate.

## Tests

```sh
zig build test -Dtest-filter=PlaybackDevice -Dtest-filter=PlaybackLoop -Dtest-filter=regionFromArea -Dtest-filter=errnoToPcm
```

`PlaybackDevice renders periods on the null device` runs the whole init/prepare/start/stop/deinit
path on ALSA's `null` plugin, which every machine with alsa-lib has. It accepts any format and
geometry, so it proves the plumbing, not the negotiation; the hardware table below does that.

## Hardware runs

One row per card. Target: the fan-in graph from `src/graph/examples.zig`, 60 s at 512/48000,
zero xruns.

| Date | Card (`ident`) | Kernel | alsa-lib | Access | Format | Rate | Period x n | Duration | xruns | discontinuities | short_commits | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | | | | |

---

## Notes about ALSA

- **No Audio Callback**: ALSA does not provide an audio callback mechanism like some other audio APIs. Instead, you work directly with the underlying buffers.
- **Buffer Management**: ALSA exposes the underlying buffer used by the driver. The basic idea is to directly fill the same buffer that the ALSA driver uses.
- **Device Types**: An ALSA device can be either playback or capture, but not both simultaneously. However, most sound cards provide separate devices for each.

### Audio Loop

- **Lower-Level Programming**: Implementing an audio loop in ALSA requires more low-level programming compared to some other APIs.
- **Capture Mode**: In capture mode, ALSA fills the buffer with audio data, and the application reads from the same buffer. ALSA provides a DMA (Direct Memory Access) pointer that indicates where the driver is currently writing data. This pointer can help determine where to read from.

    ```
                 Available for reading
    |------------------------------------------------|
    [ [*] [*] [*] [*] [*] [*] [*] [*] [*] [*] [*] [*]]
       ^DMA Pointer                          ^Driver Pointer
    ```

- **Indirect Access**: ALSA abstracts away direct DMA pointer access. Functions like `snd_pcm_avail`, `snd_pcm_avail_update`, and `snd_pcm_avail_delay` provide information on the number of frames available for reading. You can then use this number to determine how many frames you can safely read from the buffer.
- **Buffer Locking**: Use `snd_pcm_mmap_begin` to lock the buffer for reading or writing, and `snd_pcm_mmap_commit` to unlock it. The pointer returned by `snd_pcm_mmap_begin` gives you direct access to the buffer for reading or writing.
- **Handling Buffer Wrap-Around**: You must implement an inner loop to handle cases where the DMA pointer wraps around the buffer.

Here is a simple example in C++/pseudo-code:

```c++
snd_pcm_start(...);

while (running) {
    auto n = snd_pcm_avail(...);

    for (auto i = 0; i < n; i++) {
        auto [dma_ptr, max] = snd_pcm_mmap_begin(...);
        // Implement the audio callback
        audio_callback(dma_ptr, max);
        snd_pcm_mmap_commit(...);

        assert(i < 2); // Only reading 2 frames at a time
        n -= max;
    }

    snd_pcm_wait(...); // Wait for more data
}
```

- **Separate Devices for Capture and Playback**: Capture and playback are handled by separate devices, but this is manageable in the implementation.
- **Shared Audio Loop**: You can include both devices in the same audio loop, sharing the buffer and thread. Here's a simplified pseudo-code example:

```c++
snd_pcm_start(playback_device);
snd_pcm_start(capture_device);

while (running) {
    snd_pcm_wait(capture_device);
    snd_pcm_wait(playback_device);

    // Ensuring that the callback is always called within the size of buffer_size
    auto n = snd_pcm_avail(min(capture_device, buffer_size));

    // --- Ignoring buffer wrap-around. Handle this with subloops in real code. ---

    auto [src, _] = snd_pcm_mmap_begin(capture_device, n);
    auto [dst, _] = snd_pcm_mmap_begin(playback_device, n);
    memcpy(dst, src, n * sizeof(float) * nb_channels);

    snd_pcm_mmap_commit(capture_device, dst, n);
    snd_pcm_mmap_commit(playback_device, dst, n);
    // --
}
```

### Opening Devices

- **Separate Devices**: Since ALSA treats capture and playback as separate devices, they must be started independently, leading to potential synchronization issues.
- **Buffer Size Considerations**: The buffer size must be large enough to handle worst-case scenarios. For example, if the capture device is faster than the playback device, the playback might need to wait for sufficient data to be captured.
- **Latency Concerns**: A larger buffer size can increase latency.
- **Synchronizing Devices**: ALSA provides the `snd_pcm_link` API to link two devices. A single `snd_pcm_start` will start both devices simultaneously, ensuring synchronization if they share the same synchronization ID (which can be obtained with `snd_pcm_info_get_sync`).
- **Buffer Optimization**: Once devices are linked, buffer optimization can reduce latency to levels comparable to CoreAudio or WASAPI. Multiple devices, even from different hardware, can be linked together.

### Configuration Space

- **Full Configuration at Start**: When you first open the device, you start with the full configuration space (`snd_pcm_hw_params_any`).
- **Interdependent Parameters**: On resource-limited systems, configuration parameters can be interdependent. For example, increasing the number of channels might require reducing the sample rate.
- **Probing for Limits**: You can probe the device and system to determine the boundaries of the configuration space:
  - `snd_pcm_hw_params_get_channels_max` and `snd_pcm_hw_params_get_channels_min` for channels.
  - `snd_pcm_hw_params_get_rate_max` and `snd_pcm_hw_params_get_rate_min` for sample rate.
  - `snd_pcm_hw_params_get_buffer_size_max` and `snd_pcm_hw_params_get_buffer_size_min` for buffer size.
  - `snd_pcm_hw_params_get_buffer_duration_max` and `snd_pcm_hw_params_get_buffer_duration_min` for buffer duration.
- **Constraint Optimization**: As a developer, you constrain the configuration space based on what the system can handle, allowing the API to optimize the remaining parameters for the best performance.

### Buffer Size

Buffer size in ALSA can refer to different concepts depending on the context. ALSA defines three related terms:

#### Audio Buffer / ALSA Buffer Size

- **Definition**: This refers to the total size, in samples, of the hardware buffer in memory.

#### Period Size

- **Definition**: The buffer can be divided into smaller chunks called periods. The hardware typically operates by filling these periods sequentially.
- **Example**: With a buffer size of 1024 and a period size of 256:

    ```
    [[*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*][*]]
    |---------------------------- Buffer size: 1024 ----------------------------|

    |----- Period -----||----- Period -----||----- Period -----||----- Period -----|
                       ^Wake-up CPU         ^Wake-up CPU        ^Wake-up CPU
    ```

- **Interrupts**: Interrupts occur (waking up the CPU) when the DMA pointer crosses a period boundary.
- **Unblocking `snd_pcm_wait`**: When `snd_pcm_wait` unblocks, the DMA pointer is at the start of a period.
- **Buffer Depth**: More than one period should be available to avoid underruns, similar to double or triple buffering in other APIs.
- **Minimum Periods**: At least two periods are needed to prevent underruns, as the CPU needs time to wake up and write to the buffer.
- **Relation to Higher-Level APIs**: In traditional audio APIs with callbacks, this period size often corresponds to what is referred to as the `buffer_size`.
- **Disabling Period Interrupts**: You can disable period interrupts altogether (setting the number of periods to zero), potentially relying on period interrupts from another device.

#### FIFO / Block Size

- **Buffer Location**: The audio buffer could reside in the audio card or system RAM.
- **Trade-offs**:
  - **In Audio Card**: Requires onboard RAM in the device, which can be costly.
  - **In System RAM**: Requires frequent CPU access to system RAM, which can be inefficient.
- **Optimal Setup**: Ideally, a small buffer is located on the audio card (device) and a larger buffer in system RAM.
- **FIFO Size**: This device buffer size is known as the `fifo_size` in ALSA, typically small (32-128 samples).
- **Block Size**: The number of samples the audio device reads/writes from memory in a single burst. Latency can never be lower than the block size.
- **Querying `fifo_size`**: Use `snd_pcm_hw_params_get_fifo_size` to query the `fifo_size`.

### Timing

#### Legacy Systems
- **Independent Clocks**: The audio device has its own clock, which needs to be synchronized with the system clock to maintain accurate audio timing.
- **DMA Wrap-Around**: During the DMA buffer wrap-around, the system would take a snapshot of both the system clock and the audio device clock.
- **Rate Calculation**: The period size divided by the wrap-around time gives the average actual sample rate of the device.
- **Interrupt Jitter**: This approach suffers from interrupt jitter, typically around ±300ms, leading to imprecise timing.
- **Large Ring Buffers**: Legacy systems used large ring buffers to mitigate clock drift and jitter, which unfortunately introduced additional latency.

#### Modern Systems
- **Hardware Counters**: Newer audio devices include a counter that increments according to the audio device clock. This counter is crucial for accurate timing.
- **Synchronized System and Device Counters**: Modern audio devices are usually connected via a bus (e.g., PCIe, USB), which is also clocked. The device typically has access to the system or bus clock, allowing it to maintain a second counter that increments according to the system clock.
- **Atomic Counter Snapshots**: The audio device often has a register that allows the CPU to take an atomic snapshot of both the system clock counter and the device clock counter simultaneously. This allows the CPU to accurately calculate clock drift between the device and the system.
- **Accurate Rate Calculation**: This method provides a highly accurate measurement of the device's actual sample rate, independent of interrupt jitter.
- **Buffer Size Independence**: Unlike legacy systems, this method does not rely on buffer size because the CPU can take the snapshot at any time, ensuring precise timing information.
- **CoreAudio Approach**: In systems like CoreAudio, the clock snapshot struct is passed at every callback, abstracting the details by always providing the most recent snapshot, ensuring accurate timing.
- **ALSA Timing Functions**: In ALSA, you can use functions like `snd_pcm_status_get_htstamp`, `snd_pcm_status_get_audio_htstamp`, and `snd_pcm_status_get_audio_htstamp_report` to retrieve precise timestamps and calculate drift.
- **Decoupling from Period Size**: Accurate rate calculation in modern systems is independent of period size, unlike in legacy systems or higher-level audio loop APIs.

### Dropouts and Overruns

- **Playback Overrun**: If you stop writing to the playback device, ALSA will eventually experience an overrun, causing playback to stop. Subsequent write attempts will return an error.
- **No Dropouts**: ALSA does not handle dropouts automatically. If you want to prevent the playback from stopping (and instead produce silence), you must write zeros to the buffer yourself.
- **Closer to Hardware**: This behavior is closer to how hardware typically works, providing more control at the expense of higher complexity.
