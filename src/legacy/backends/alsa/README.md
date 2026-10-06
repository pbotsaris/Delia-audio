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
- **Accurate Rate Calculation**: This method provides a highly accurate measurement of the device’s actual sample rate, independent of interrupt jitter.
- **Buffer Size Independence**: Unlike legacy systems, this method does not rely on buffer size because the CPU can take the snapshot at any time, ensuring precise timing information.
- **CoreAudio Approach**: In systems like CoreAudio, the clock snapshot struct is passed at every callback, abstracting the details by always providing the most recent snapshot, ensuring accurate timing.
- **ALSA Timing Functions**: In ALSA, you can use functions like `snd_pcm_status_get_htstamp`, `snd_pcm_status_get_audio_htstamp`, and `snd_pcm_status_get_audio_htstamp_report` to retrieve precise timestamps and calculate drift.
- **Decoupling from Period Size**: Accurate rate calculation in modern systems is independent of period size, unlike in legacy systems or higher-level audio loop APIs.

### Dropouts and Overruns

- **Playback Overrun**: If you stop writing to the playback device, ALSA will eventually experience an overrun, causing playback to stop. Subsequent write attempts will return an error.
- **No Dropouts**: ALSA does not handle dropouts automatically. If you want to prevent the playback from stopping (and instead produce silence), you must write zeros to the buffer yourself.
- **Closer to Hardware**: This behavior is closer to how hardware typically works, providing more control at the expense of higher complexity.

