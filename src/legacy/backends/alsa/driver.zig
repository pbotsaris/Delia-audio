//! The `Device` struct abstracts the initialization and management of an ALSA audio device.
//! It encapsulates all the necessary configurations and states required to set up and operate
//! an audio device for playback or capture operations. This struct allows users to specify
//! various options related to audio format, buffering, access types, and operational modes,
//! providing a flexible interface for interacting with ALSA.
//!
//! The Hardware buffer size and period size are calculated based on the user-defined buffer size
//! for minimizing latency and optimizing performance. This can be further customized by adjusting
//! the opts.n_periods to increase the number of periods per hardware buffer.

const std = @import("std");

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

const log = std.log.scoped(.alsa);
const latency = @import("latency.zig");
const utils = @import("utils.zig");

pub const Hardware = @import("Hardware.zig");
pub const Format = @import("format.zig").Format;
pub const Signedness = @import("settings.zig").Signedness;
pub const ByteOrder = @import("settings.zig").ByteOrder;
pub const FormatType = @import("settings.zig").FormatType;
pub const AccessType = @import("settings.zig").AccessType;
pub const StreamType = @import("settings.zig").StreamType;
pub const StartThreshold = @import("settings.zig").StartThreshold;
pub const ChannelCount = @import("settings.zig").ChannelCount;
pub const Mode = @import("settings.zig").Mode;
const GenericAudioData = @import("audio_data.zig").GenericAudioData;

pub const SampleRate = @import("common").audio_specs.SampleRate;
pub const BufferSize = @import("common").audio_specs.BufferSize;

const ProbeOptions = struct {
    callback: latency.ProbeCallback,
    buffer_cycles: u32,
};

const HalfDuplexDeviceOptions = struct {
    sample_rate: SampleRate = SampleRate.sr_44100,
    channels: ChannelCount = ChannelCount.stereo,
    stream_type: StreamType = StreamType.playback,
    // no default allowed because alsa may segfault depending on linux audio configuration
    ident: [:0]const u8,
    buffer_size: BufferSize = BufferSize.buf_1024,
    timeout: i32 = -1,
    n_periods: u32 = 5,
    start_thresh: StartThreshold = .disabled,
    must_prepare: bool = true,
    probe_options: ?ProbeOptions = null,
};

pub const DeviceHardwareError = error{
    open_stream,
    alsa_allocation,
    access_type,
    audio_format,
    channel_count,
    sample_rate,
    buffer_size,
    hardware_params,
    linking_devices,
    invalid_hardware_struct,
} || std.mem.Allocator.Error;

pub const DeviceSoftwareError = error{
    software_params,
    alsa_allocation,
    set_avail_min,
    set_start_stop_threshold,
    set_period_event,
    set_silence,
    set_timestamp,
    prepare,
} || std.mem.Allocator.Error;

pub const AudioLoopError = error{
    start,
    xrun,
    suspended,
    missmatch,
    unexpected,
    timeout,
    unsupported,
    audio_buffer_nonalignment,
    poll_alloc,
    buffer_size,
};

pub const DeviceComptimeOptions = struct {
    format: FormatType,
    probe_enabled: bool = false,
};

pub fn HalfDuplexDevice(ContextType: type, comptime comptime_opts: DeviceComptimeOptions) type {
    const T = comptime_opts.format.ToType();

    return struct {
        pub fn AudioDataType() type {
            return *GenericAudioData(comptime_opts.format);
        }

        pub fn FloatType() type {
            return GenericAudioData(comptime_opts.format).FloatType();
        }

        pub fn maxFormatSize() usize {
            return Format(T).maxSize();
        }

        const Self = @This();
        // defined at compile time for this device type
        pub const FORMAT_TYPE = comptime_opts.format;
        pub const PROBE_ENABLED = comptime_opts.probe_enabled;

        const AudioLoop = HalfDuplexAudioLoop(ContextType, comptime_opts);
        pub const AudioCallback = AudioLoop.AudioCallback();

        /// Pointer to the PCM device handle.
        pcm_handle: ?*c_alsa.snd_pcm_t = null,
        /// Pointer to the hardware parameters configuration.
        hw_params: ?*c_alsa.snd_pcm_hw_params_t = null,
        /// Pointer to the software parameters configuration.
        sw_params: ?*c_alsa.snd_pcm_sw_params_t = null,
        /// Mode for opening the audio device (e.g., non-blocking, async).
        /// Currently no mode is supported.
        mode: Mode = Mode.none,
        /// Indicates whether the device is for playback or capture.
        stream_type: StreamType,
        /// Number of audio channels (e.g., 2 for stereo).
        channels: u32,
        /// Audio device's sample rate in Hz.
        sample_rate: u32,
        /// Direction flag for adjusting the sample rate, typically set by ALSA.
        dir: i32,
        /// Software buffer size in frames. This is the size of the buffer that the audio callback reads/writes.
        buffer_size: BufferSize,
        /// Total size of the hardware audio buffer in frames.
        hardware_buffer_size: u32,
        /// Size of one hardware period in frames. Same as buffer size.
        hardware_period_size: u32,
        /// Number of frames before ALSA starts reading/writing audio data.
        start_thresh: u32,
        /// Number of frames before ALSA stops reading/writting after underrun.
        stop_thresh: u32,
        /// Timeout in milliseconds for ALSA to wait before returning an error during read/write operations.
        timeout: i32,
        /// Currently only mmap interleaved is will be the default access type with automatic fallback to rw interleaved
        /// Non-interleaved access types are not yet supported.
        access_type: AccessType = AccessType.mmap_interleaved,
        /// Manages Audio sample format (e.g., 16-bit signed little-endian).
        audio_format: Format(T),
        /// this constant will is the multiplier that will define the size of the hardware buffer size.
        ///  hardware_buffer_size = user_defined_buffer_size * NB_PERIODS
        n_periods: u32,

        /// Used on RW transfers that require a buffer to read/write data
        transfer_buffer: []u8 = undefined,
        allocator: std.mem.Allocator,

        /// wether HalfDuplexDevice.prepare will explicitly call snd_pcm_prepare.
        /// Useful snd_pcm_link devices and don't want to call prepare on the slave device
        must_prepare: bool = true,

        /// Probe for measuring latency
        probe: ?latency.Probe,

        const DeviceOptionsFromHardware = struct {
            mode: Mode = Mode.none,
            buffer_size: BufferSize = BufferSize.buf_1024,
            start_thresh: StartThreshold = .fill_one_period,
            timeout: i32 = -1,
            must_prepare: bool = true,
            probe_options: ?ProbeOptions = null,
        };

        // Initializes a `Device` using the provided `Hardware` configuration and additional options.
        //
        // This function retrieves the selected audio port from the `Hardware` instance and uses its
        // settings (e.g., sample rate, channel count, format) to configure the `Device`. If specific
        // settings are not available from the hardware, default values are used. The function then
        // calls the `init` function to configure the ALSA hardware parameters.
        //
        // # Parameters:
        // - `hardware`: The `Hardware` instance that provides information about the available audio ports.
        // - `inc_opts`: Additional options for configuring the `Device`, such as mode, buffer size,
        //   start threshold, timeout, access type, and whether resampling is allowed.
        //
        // # Returns:
        // - A `Device` instance configured based on the hardware settings and the provided options.
        // - Returns an error if the hardware or options cannot be used to initialize the device.
        //
        // # Errors:
        // - Returns an error if the selected audio port cannot be retrieved or if the device initialization fails.
        pub fn fromHardware(allocator: std.mem.Allocator, hardware: Hardware, inc_opts: DeviceOptionsFromHardware) !Self {
            const port = try hardware.getSelectedAudioPort();

            const opts = HalfDuplexDeviceOptions{
                .sample_rate = port.selected_settings.sample_rate orelse return DeviceHardwareError.invalid_hardware_struct,
                .channels = port.selected_settings.channels orelse return DeviceHardwareError.invalid_hardware_struct,
                .stream_type = port.stream_type orelse return DeviceHardwareError.invalid_hardware_struct,
                .ident = port.identifier,
                .buffer_size = inc_opts.buffer_size,
                .start_thresh = inc_opts.start_thresh,
                .timeout = inc_opts.timeout,
                .must_prepare = inc_opts.must_prepare,
                .probe_options = inc_opts.probe_options,
            };

            return try init(allocator, opts);
        }

        // Initializes the ALSA device with the provided options and configures the hardware parameters.
        //
        // # Parameters:
        // - `opts`: A `DeviceOptions` structure containing various settings for the device, such as sample rate,
        //   channels, audio format, buffer size, period size, and more.
        //
        // # Returns:
        // - A `Device` instance configured and ready for playback or capture.
        // - Returns an error if the hardware parameters cannot be set or if the device initialization fails.
        //
        // # Hardware Configuration:
        // - `sample_rate`: Sets the desired sample rate. If the hardware cannot match the requested rate, an error is returned.
        // - `channels`: Configures the number of audio channels.
        // - `audio_format`: Sets the sample format (e.g., signed 16-bit little-endian).
        // - `buffer_size` and `hardware_buffer_size`: Configures the software and hardware buffer sizes, optimizing for latency.
        // - `hardware_period_size`: Defines the period size, determining the frequency of hardware interrupts.
        //
        // # Errors:
        // - Returns an error if the PCM device cannot be opened, if the hardware parameters cannot be set,
        //   or if there is a mismatch between the requested and actual sample rate.
        pub fn init(allocator: std.mem.Allocator, opts: HalfDuplexDeviceOptions) DeviceHardwareError!Self {
            var pcm_handle: ?*c_alsa.snd_pcm_t = null;
            var params: ?*c_alsa.snd_pcm_hw_params_t = null;
            var sample_rate: u32 = @intCast(@intFromEnum(opts.sample_rate));

            // we are configuring the hardware to match the software buffer size and optimize latency
            var hardware_period_size: c_ulong = @intFromEnum(opts.buffer_size);
            var hardware_buffer_size: c_ulong = hardware_period_size * @as(c_ulong, @intCast(opts.n_periods));

            var dir: i32 = 0;

            // always mode none for now
            var err = c_alsa.snd_pcm_open(&pcm_handle, opts.ident.ptr, @intFromEnum(opts.stream_type), @intFromEnum(Mode.none));

            if (err < 0) {
                log.warn("Failed to open PCM for ident '{s}': '{s}'. Attempting default...", .{ opts.ident, c_alsa.snd_strerror(err) });

                err = c_alsa.snd_pcm_open(&pcm_handle, "default", @intFromEnum(opts.stream_type), @intFromEnum(Mode.none));

                if (err < 0) {
                    log.err("Failed to open PCM for ident 'default': '{s}'", .{c_alsa.snd_strerror(err)});
                    return DeviceHardwareError.open_stream;
                }

                log.info("Successfully opened PCM for ident 'default'", .{});
            }

            errdefer {
                const e = c_alsa.snd_pcm_close(pcm_handle);
                _ = e;
            }

            err = c_alsa.snd_pcm_hw_params_malloc(&params);

            if (err < 0) {
                log.err("Failed to allocate hardware parameters: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceHardwareError.alsa_allocation;
            }

            errdefer c_alsa.snd_pcm_hw_params_free(params);

            _ = c_alsa.snd_pcm_hw_params_any(pcm_handle, params);

            // prefers mmap interleaved access type but will fallback to rw interleaved if not available
            var access_type = AccessType.mmap_interleaved;

            err = c_alsa.snd_pcm_hw_params_set_access(pcm_handle, params, @intFromEnum(access_type));

            if (err < 0) {
                log.warn("Failed to set access type '{s}': {s}", .{ @tagName(access_type), c_alsa.snd_strerror(err) });

                access_type = AccessType.rw_interleaved;

                log.warn("Attempting fallback to '{s}' access type. Note this will increase latency", .{@tagName(access_type)});
                err = c_alsa.snd_pcm_hw_params_set_access(pcm_handle, params, @intFromEnum(access_type));

                if (err < 0) {
                    log.err("Failed to set access type '{s}': {s}", .{ @tagName(access_type), c_alsa.snd_strerror(err) });
                    return DeviceHardwareError.access_type;
                }
            }

            err = c_alsa.snd_pcm_hw_params_set_format(pcm_handle, params, @intFromEnum(FORMAT_TYPE));

            if (err < 0) {
                log.err(
                    "The format is '{s}' not valid for this hardware. Please check the format options of your hardwave with hardware.formats().",
                    .{@tagName(FORMAT_TYPE)},
                );
                log.err("ALSA error: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceHardwareError.audio_format;
            }

            err = c_alsa.snd_pcm_hw_params_set_channels(pcm_handle, params, @intFromEnum(opts.channels));

            if (err < 0) {
                log.err("Failed to set channel count of {d}: {s}", .{ @intFromEnum(opts.channels), c_alsa.snd_strerror(err) });
                return DeviceHardwareError.channel_count;
            }

            err = c_alsa.snd_pcm_hw_params_set_rate_near(pcm_handle, params, &sample_rate, &dir);

            if (err < 0) {
                log.err("Failed to set sample rate of {d}: {s}", .{ sample_rate, c_alsa.snd_strerror(err) });
                return DeviceHardwareError.sample_rate;
            }

            const desired_sampe_rate: u32 = @intCast(@intFromEnum(opts.sample_rate));

            // we will not fail here, but fall back
            // full duplex devices will try to match each other on the FullDuplexDevice, if that fails, then init fails.
            if (sample_rate != desired_sampe_rate) {
                log.warn("Sample rate {d}hz requested was not accepted by alsa. ", .{desired_sampe_rate});
                log.warn("Will use the hardware sample rate {d}hz instead", .{sample_rate});
            }

            err = c_alsa.snd_pcm_hw_params_set_buffer_size_near(pcm_handle, params, &hardware_buffer_size);

            if (err < 0) {
                log.err("Failed to set hardware buffer size {d}: {s}", .{ hardware_period_size, c_alsa.snd_strerror(err) });
                return DeviceHardwareError.buffer_size;
            }

            err = c_alsa.snd_pcm_hw_params_set_period_size_near(pcm_handle, params, &hardware_period_size, &dir);

            if (err < 0) {
                log.err("Failed to set hardware period size {d}: {s}", .{ hardware_period_size, c_alsa.snd_strerror(err) });
                return DeviceHardwareError.buffer_size;
            }

            err = c_alsa.snd_pcm_hw_params(pcm_handle, params);

            if (err < 0) {
                log.err("Failed to set hardware parameters: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceHardwareError.hardware_params;
            }

            err = c_alsa.snd_pcm_hw_params_get_buffer_size(params, &hardware_buffer_size);

            if (err < 0) {
                log.err("Failed to get hardware buffer size: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceHardwareError.buffer_size;
            }

            // we calculate the expected buffer size based on the user defined buffer size
            const expected_buffer_size: u32 = @as(u32, @intCast(@intFromEnum(opts.buffer_size))) * opts.n_periods;

            if (hardware_buffer_size != @as(c_ulong, @intCast(expected_buffer_size))) {
                log.err("Hardware buffer size {d} differs from requested {d}", .{ hardware_buffer_size, expected_buffer_size });
                return DeviceHardwareError.buffer_size;
            }

            err = c_alsa.snd_pcm_hw_params_get_period_size(params, &hardware_period_size, &dir);

            if (err < 0) {
                log.err("Failed to get hardware period size: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceHardwareError.buffer_size;
            }

            const expected_period_size: u32 = @divFloor(expected_buffer_size, opts.n_periods);

            if (hardware_period_size != @as(c_ulong, @intCast(expected_period_size))) {
                log.err("Hardware period size {d} differs from requested {d}", .{ hardware_period_size, expected_period_size });
                return DeviceHardwareError.buffer_size;
            }

            const frame_size: usize = @intFromEnum(opts.channels) * @sizeOf(T);
            const buffer_bytes: usize = frame_size * @intFromEnum(opts.buffer_size);

            // start with after filling one hardware buffer size, as soon as possible, or disabled
            const start_tresh: u32 = switch (opts.start_thresh) {
                StartThreshold.fill_one_period => blk: {
                    const buffer_size = @as(u32, @intCast(@intFromEnum(opts.buffer_size)));
                    const thresh = @as(u32, @intCast(@intFromEnum(opts.start_thresh)));
                    break :blk buffer_size * opts.n_periods * thresh;
                },
                StartThreshold.disabled => @as(u32, @intCast(@intFromEnum(opts.start_thresh))),
                StartThreshold.immediate => 0,
            };

            var probe: ?latency.Probe = null;

            if (PROBE_ENABLED) {
                if (opts.probe_options) |options| {
                    probe = latency.Probe.init(options.callback, .{
                        .sample_rate = sample_rate,
                        .hardware_buffer_size = @intCast(hardware_buffer_size),
                        .buffer_cycles = options.buffer_cycles,
                    });
                } else log.warn("Probe is enabled but no callback was provided. Will call noop callback.", .{});
            }

            // used for rw transfers
            const transfer_buffer = try allocator.alloc(u8, buffer_bytes);
            @memset(transfer_buffer, 0);

            return Self{
                .pcm_handle = pcm_handle,
                .hw_params = params,
                .channels = @intFromEnum(opts.channels),
                .sample_rate = sample_rate,
                .dir = dir,
                .stream_type = opts.stream_type,
                .buffer_size = opts.buffer_size,
                .start_thresh = start_tresh,
                .stop_thresh = @as(u32, @intCast(@intFromEnum(opts.buffer_size))) * opts.n_periods,
                .timeout = opts.timeout,
                .hardware_buffer_size = @as(u32, @intCast(hardware_buffer_size)),
                .hardware_period_size = @as(u32, @intCast(hardware_period_size)),
                .n_periods = opts.n_periods,
                .audio_format = Format(T).init(FORMAT_TYPE),
                .allocator = allocator,
                .transfer_buffer = transfer_buffer,
                .must_prepare = opts.must_prepare,
                .probe = probe,
                .access_type = access_type,
            };
        }

        pub fn prepare(self: *Self) DeviceSoftwareError!void {
            var err = c_alsa.snd_pcm_sw_params_malloc(&self.sw_params);

            if (err < 0) {
                log.err("Failed to allocate software parameters: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceSoftwareError.alsa_allocation;
            }

            err = c_alsa.snd_pcm_sw_params_current(self.pcm_handle, self.sw_params);

            if (err < 0) {
                log.err("Failed to get current software parameters: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceSoftwareError.software_params;
            }

            const min_size = @intFromEnum(self.buffer_size);

            err = c_alsa.snd_pcm_sw_params_set_avail_min(self.pcm_handle, self.sw_params, min_size);

            if (err < 0) {
                log.err("Failed to set minimum available count '{s}': {s}", .{ @tagName(self.buffer_size), c_alsa.snd_strerror(err) });
                return DeviceSoftwareError.set_avail_min;
            }

            // start the playback or capture manually
            err = c_alsa.snd_pcm_sw_params_set_start_threshold(self.pcm_handle, self.sw_params, self.start_thresh);

            if (err < 0) {
                log.err("Failed to set start threshold  to '{d}' frames: {s}", .{ self.start_thresh, c_alsa.snd_strerror(err) });
                return DeviceSoftwareError.set_start_stop_threshold;
            }

            var set_start_thresh: c_alsa.snd_pcm_uframes_t = 0;

            err = c_alsa.snd_pcm_sw_params_get_start_threshold(self.sw_params, &set_start_thresh);

            if (err < 0) {
                log.err("Failed to get start threshold: {s}", .{c_alsa.snd_strerror(err)});
            }

            if (set_start_thresh != self.start_thresh) {
                log.warn("Start threshold was not set properly. Expected: {d} but found: {d}", .{ self.start_thresh, set_start_thresh });
            }

            err = c_alsa.snd_pcm_sw_params_set_stop_threshold(self.pcm_handle, self.sw_params, self.stop_thresh);

            if (err < 0) {
                log.err("Failed to set stop threshold to '{d}' frames: {s}", .{ self.stop_thresh, c_alsa.snd_strerror(err) });
                return DeviceSoftwareError.set_start_stop_threshold;
            }

            // we set the silence size to the size of the hardware buffer
            // this may change in the future if we decide to implement our silecing implementation
            const silence_size = @as(c_alsa.snd_pcm_uframes_t, @intCast(@intFromEnum(self.buffer_size))) * @as(c_alsa.snd_pcm_uframes_t, @intCast(self.n_periods));
            err = c_alsa.snd_pcm_sw_params_set_silence_size(self.pcm_handle, self.sw_params, silence_size);

            if (err < 0) {
                log.err("Failed to set silence size to  buffer size '{s}' * {d} period = {d}: {s}", .{
                    @tagName(self.buffer_size),
                    self.n_periods,
                    silence_size,
                    c_alsa.snd_strerror(err),
                });
                return DeviceSoftwareError.set_silence;
            }

            err = c_alsa.snd_pcm_sw_params_set_tstamp_mode(self.pcm_handle, self.sw_params, c_alsa.SND_PCM_TSTAMP_ENABLE);

            if (err < 0) {
                log.err("Failed to enable timestamp: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceSoftwareError.set_timestamp;
            }

            var tstamp_mode: c_alsa.snd_pcm_tstamp_t = undefined;

            err = c_alsa.snd_pcm_sw_params_get_tstamp_mode(self.sw_params, &tstamp_mode);

            if (err >= 0) {
                if (tstamp_mode != c_alsa.SND_PCM_TSTAMP_ENABLE) {
                    log.warn("Timestamp was not enabled properly. Expected: {s} but found: {s}", .{ utils.tstampToStr(c_alsa.SND_PCM_TSTAMP_ENABLE), utils.tstampToStr(tstamp_mode) });
                }
            } else log.warn("Could not verify timestamp mode: {s}", .{c_alsa.snd_strerror(err)});

            err = c_alsa.snd_pcm_sw_params_set_tstamp_type(self.pcm_handle, self.sw_params, c_alsa.SND_PCM_TSTAMP_TYPE_MONOTONIC);

            if (err < 0) {
                log.err("Failed to set timestamp type: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceSoftwareError.set_timestamp;
            }

            // No period events as we are using min_available strategy only
            if (c_alsa.snd_pcm_sw_params_set_period_event(self.pcm_handle, self.sw_params, 0) < 0) {
                log.err("Failed to disable period event: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceSoftwareError.set_period_event;
            }

            if (err < 0) {
                log.err("Failed to set software parameters: {s}", .{c_alsa.snd_strerror(err)});
                return DeviceSoftwareError.software_params;
            }

            if (self.must_prepare) {
                err = c_alsa.snd_pcm_prepare(self.pcm_handle);

                if (err < 0) {
                    log.err("Failed to prepare Audio Interface: {s}", .{c_alsa.snd_strerror(err)});
                    return DeviceSoftwareError.prepare;
                }
            }
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("\nDevice\n", .{});
            try writer.print("  Stream Type:        {s}\n", .{@tagName(self.stream_type)});
            try writer.print("  Access Type:        {s}\n", .{@tagName(self.access_type)});
            try writer.print("  Sample Rate:        {d}hz\n", .{self.sample_rate});
            try writer.print("  Channels:           {d}\n", .{self.channels});
            try writer.print("  Buffer Size:        {d} frames\n", .{@intFromEnum(self.buffer_size)});
            try writer.print("  HW Buffer Size:     {d} frames\n", .{self.hardware_buffer_size});
            try writer.print("  Timeout:            {d}ms\n", .{if (self.timeout < 0) 0 else self.timeout});
            try writer.print("  Open Mode:          {s}\n", .{@tagName(self.mode)});
            try writer.print("  Transfer Buff Size: {d} bytes\n", .{self.transfer_buffer.len});
            try writer.print("{f}\n", .{self.audio_format});
        }

        pub fn deinit(self: *Self) !void {
            if (self.access_type == .rw_interleaved) {
                self.allocator.free(self.transfer_buffer);
            }

            c_alsa.snd_pcm_hw_params_free(self.hw_params);
            c_alsa.snd_pcm_sw_params_free(self.sw_params);

            const res = c_alsa.snd_pcm_close(self.pcm_handle);

            if (res < 0) {
                log.err("Failed to close PCM: {s}", .{c_alsa.snd_strerror(res)});
                return DeviceHardwareError.alsa_allocation;
            }
        }

        pub fn start(self: Self, ctx: *ContextType, callback: AudioCallback) !void {
            var audio_loop = AudioLoop.init(self, ctx, callback);

            try audio_loop.start();
        }
    };
}

const FullDuplexIdent = struct {
    playback: [:0]const u8 = "default",
    capture: [:0]const u8 = "default",
};

const FullDuplexChannels = struct {
    playback: ChannelCount = ChannelCount.stereo,
    capture: ChannelCount = ChannelCount.stereo,
};

// note that for this implementation full duplex must have the same sample rate, channel config,and buffer size
const FullDuplexDeviceOptions = struct {
    ident: FullDuplexIdent = FullDuplexIdent{},
    sample_rate: SampleRate = SampleRate.sr_44100,
    channels: FullDuplexChannels = FullDuplexChannels{},
    buffer_size: BufferSize = BufferSize.buf_1024,
    timeout: i32 = -1,
    n_periods: u32 = 5,
    start_thresh: StartThreshold = .fill_one_period,
    master_device: StreamType = StreamType.playback,
    probe_options: ?ProbeOptions = null,
};

pub fn FullDuplexDevice(ContextType: type, comptime comptime_opts: DeviceComptimeOptions) type {
    const T = comptime_opts.format.ToType();

    return struct {
        pub fn AudioDataType() type {
            return *GenericAudioData(comptime_opts.format);
        }

        pub fn FloatType() type {
            return GenericAudioData(comptime_opts.format).FloatType();
        }

        pub fn maxFormatSize() usize {
            return Format(T).maxSize();
        }

        pub const PROBE_ENABLED = comptime_opts.probe_enabled;
        pub const FORMAT_TYPE = comptime_opts.format;

        const Self = @This();

        const AudioCallback = FullDuplexAudioLoop(ContextType, comptime_opts).AudioCallback();

        playback_device: HalfDuplexDevice(ContextType, comptime_opts),
        capture_device: HalfDuplexDevice(ContextType, comptime_opts),
        allocator: std.mem.Allocator,
        master_device: StreamType,
        same_channel_config: bool,
        is_linked: bool,

        // note that the full duplex does not offer resampling capabilities
        pub fn init(allocator: std.mem.Allocator, opts: FullDuplexDeviceOptions) DeviceHardwareError!Self {
            const Device = HalfDuplexDevice(ContextType, comptime_opts);

            const is_linked = std.mem.eql(u8, opts.ident.playback, opts.ident.capture);

            // note that slave and master is only relevant when the devices are linked
            var capture_device = try Device.init(allocator, .{
                .sample_rate = opts.sample_rate,
                .channels = opts.channels.capture,
                .stream_type = .capture,
                .ident = opts.ident.capture,
                .buffer_size = opts.buffer_size,
                .timeout = opts.timeout,
                .n_periods = opts.n_periods,
                .start_thresh = opts.start_thresh,
                .probe_options = opts.probe_options,

                // we don't need to snd_pcm_prepare the slave device when linked linked
                .must_prepare = !is_linked,
            });

            var playback_device = try Device.init(allocator, .{
                .sample_rate = opts.sample_rate,
                .channels = opts.channels.playback,
                .stream_type = .playback,
                .ident = opts.ident.playback,
                .buffer_size = opts.buffer_size,
                .timeout = opts.timeout,
                .n_periods = opts.n_periods,
                .start_thresh = opts.start_thresh,

                .probe_options = opts.probe_options,
            });

            if (is_linked) {
                log.debug("Linking playback and capture devices.", .{});
                const err = c_alsa.snd_pcm_link(capture_device.pcm_handle, playback_device.pcm_handle);

                if (err != 0) {
                    log.err("Failed to link playback and capture devices: {s}", .{c_alsa.snd_strerror(err)});
                    return DeviceHardwareError.linking_devices;
                }
            } else log.debug("FullDuplex with unlinked playback and capture devices.", .{});

            const requested_sample_rate = @as(u32, @intCast(@intFromEnum(opts.sample_rate)));

            // try to match the sample rates between playback and capture, otherwise fails init
            if (playback_device.sample_rate != requested_sample_rate) {
                log.warn("The playback device could not be initialized with sample rate {d}hz", .{requested_sample_rate});
                log.warn("Attempting to match the capture device sample rate {d}hz to playback sample rate {d}hz", .{ capture_device.sample_rate, playback_device.sample_rate });

                try capture_device.deinit();

                capture_device = try Device.init(allocator, .{
                    .sample_rate = @enumFromInt(playback_device.sample_rate),
                    .channels = opts.channels.capture,
                    .stream_type = .capture,
                    .ident = opts.ident.capture,
                    .buffer_size = opts.buffer_size,
                    .timeout = opts.timeout,
                    .n_periods = opts.n_periods,
                    .start_thresh = opts.start_thresh,
                    .probe_options = opts.probe_options,
                    .must_prepare = !is_linked,
                });

                if (capture_device.sample_rate != playback_device.sample_rate) {
                    log.err("Playback and capture devices must have the same sample rate.", .{});
                    log.err("Playback sample rate: {d}hz, Capture sample rate: {d}hz", .{ playback_device.sample_rate, capture_device.sample_rate });
                    return DeviceHardwareError.sample_rate;
                }
            }

            if (capture_device.sample_rate != requested_sample_rate) {
                log.warn("The capture device could not be initialized with sample rate {d}hz", .{requested_sample_rate});
                log.warn("Attempting to match the playback device sample rate {d}hz to capture sample rate {d}hz", .{ playback_device.sample_rate, capture_device.sample_rate });

                try playback_device.deinit();

                playback_device = try Device.init(allocator, .{
                    .sample_rate = @enumFromInt(capture_device.sample_rate),
                    .channels = opts.channels.playback,
                    .stream_type = .playback,
                    .ident = opts.ident.playback,
                    .buffer_size = opts.buffer_size,
                    .timeout = opts.timeout,
                    .n_periods = opts.n_periods,
                    .start_thresh = opts.start_thresh,
                    .probe_options = opts.probe_options,
                });

                if (playback_device.sample_rate != capture_device.sample_rate) {
                    log.err("Playback and capture devices must have the same sample rate.", .{});
                    log.err("Playback sample rate: {d}hz, Capture sample rate: {d}hz", .{ playback_device.sample_rate, capture_device.sample_rate });
                    return DeviceHardwareError.sample_rate;
                }
            }

            return .{
                .playback_device = playback_device,
                .capture_device = capture_device,
                .is_linked = is_linked,
                .allocator = allocator,
                .same_channel_config = playback_device.channels == capture_device.channels,
                .master_device = opts.master_device,
            };
        }

        pub fn prepare(self: *Self) DeviceSoftwareError!void {
            try self.playback_device.prepare();
            try self.capture_device.prepare();
        }

        pub fn start(self: Self, ctx: *ContextType, callback: AudioCallback) !void {
            var audio_loop = FullDuplexAudioLoop(ContextType, comptime_opts).init(self, ctx, callback);
            try audio_loop.start();
        }

        pub fn deinit(self: *Self) !void {
            if (self.is_linked) {
                const err = c_alsa.snd_pcm_unlink(self.playback_device.pcm_handle);

                if (err != 0) {
                    log.err("Failed to unlink playback and capture devices: {s}", .{c_alsa.snd_strerror(err)});
                    return DeviceHardwareError.linking_devices;
                }
            }

            try self.playback_device.deinit();
            try self.capture_device.deinit();
        }
    };
}

// Audio Loop Implementation

// configuration for xrun recovery retries
const MAX_RETRY = 5;
const MILLISECONDS = 1_000_000; // 1ms
const SLEEP_INCREMENT = 1.2;
//--

// if we have 5 consecutive zero transfers we will consider it an xrun
const MAX_ZERO_TRANSFERS = 5;
const BYTE_ALIGN = 8;

fn HalfDuplexAudioLoop(ContextType: type, comptime comptime_opts: DeviceComptimeOptions) type {
    return struct {
        const Self = @This();

        const format_type = comptime_opts.format;

        pub fn AudioCallback() type {
            return *const fn (ctx: *ContextType, data: *GenericAudioData(format_type)) void;
        }

        const Device = HalfDuplexDevice(ContextType, comptime_opts);

        device: HalfDuplexDevice(ContextType, comptime_opts),
        running: bool = false,
        callback: AudioCallback(),
        ctx: *ContextType,

        pub fn init(device: HalfDuplexDevice(ContextType, comptime_opts), ctx: *ContextType, callback: AudioCallback()) Self {
            return .{
                .device = device,
                .callback = callback,
                .ctx = ctx,
            };
        }

        pub fn start(self: *Self) AudioLoopError!void {
            self.running = true;

            switch (self.device.access_type) {
                // this is the only access type currently supported at this point
                AccessType.mmap_interleaved => try self.mmapTransfer(),
                else => {
                    log.err("Unsupported access type: {s}", .{@tagName(self.device.access_type)});
                    return AudioLoopError.unsupported;
                },
            }
        }

        // TODO write a simple write loop for non-mmap access types
        //    fn blockingWrite(self: *Self) !void {}

        fn mmapTransfer(self: *Self) !void {
            const buffer_size: c_ulong = @intFromEnum(self.device.buffer_size);
            var maybe_areas: ?*const c_alsa.snd_pcm_channel_area_t = null;
            var stopped: bool = true;
            var zero_transfers: usize = 0;

            if (Device.PROBE_ENABLED) {
                if (self.device.probe) |*p| p.start();
            }

            while (self.running) {
                const state: c_uint = c_alsa.snd_pcm_state(self.device.pcm_handle);

                // Check State

                switch (state) {
                    c_alsa.SND_PCM_STATE_XRUN => {
                        try self.xrunRecovery(-c_alsa.EPIPE);
                        stopped = true;
                    },

                    c_alsa.SND_PCM_STATE_SUSPENDED => try self.xrunRecovery(-c_alsa.ESTRPIPE),

                    else => {
                        if (state < 0) {
                            log.err("Unexpected state error: {s}", .{c_alsa.snd_strerror(state)});
                            return AudioLoopError.unexpected;
                        }
                    },
                }

                const avail = c_alsa.snd_pcm_avail_update(self.device.pcm_handle);

                if (avail < 0) {
                    try self.xrunRecovery(@intCast(avail));
                    continue;
                }

                if (avail < buffer_size and stopped) {
                    const err = c_alsa.snd_pcm_start(self.device.pcm_handle);
                    if (err < 0) {
                        log.err("Failed to start pcm: {s}", .{c_alsa.snd_strerror(err)});
                        return AudioLoopError.start;
                    }

                    stopped = false;
                    continue;
                }

                if (avail < buffer_size and !stopped) {
                    const err = c_alsa.snd_pcm_wait(self.device.pcm_handle, self.device.timeout);

                    if (err < 0) {
                        try self.xrunRecovery(err);
                        stopped = true;
                        continue;
                    }
                }

                // in frames
                var to_transfer = buffer_size;
                var offset: c_ulong = 0;

                while (to_transfer > 0) {
                    // we request for a transfer_size frames from begin but it may return less
                    var expected_to_transfer = to_transfer;
                    const res = c_alsa.snd_pcm_mmap_begin(self.device.pcm_handle, &maybe_areas, &offset, &expected_to_transfer);

                    if (res < 0) {
                        try self.xrunRecovery(res);
                        stopped = true;
                    }

                    const areas = maybe_areas orelse return AudioLoopError.unexpected;
                    const addr = areas.addr orelse return AudioLoopError.unexpected;

                    const verifier = AlignmentVerifier(ContextType, comptime_opts){};
                    try verifier.verifyAlignment(self.device, areas);

                    const step: c_ulong = @divFloor(areas.step, 8);
                    const buf_start: c_ulong = (@divFloor(areas.first, 8)) + (offset * step);

                    const buffer: []u8 = @as([*]u8, @ptrCast(addr))[buf_start .. buf_start + expected_to_transfer * step];

                    var audio_data =
                        GenericAudioData(format_type)
                        .init(
                        buffer,
                        self.device.channels,
                        self.device.sample_rate,
                        self.device.audio_format,
                    );

                    self.callback(self.ctx, &audio_data);

                    const frames_actually_transfered = c_alsa.snd_pcm_mmap_commit(self.device.pcm_handle, offset, expected_to_transfer);

                    if (frames_actually_transfered < 0) {
                        try self.xrunRecovery(@intCast(frames_actually_transfered));
                    } else if (frames_actually_transfered != expected_to_transfer) try self.xrunRecovery(-c_alsa.EPIPE);

                    if (frames_actually_transfered == 0) zero_transfers += 1 else zero_transfers = 0;

                    if (zero_transfers >= MAX_ZERO_TRANSFERS) {
                        log.err("Too many consecutive zero transfers. Stopping device.", .{});
                        stopped = true;
                        return AudioLoopError.xrun;
                    }

                    // comptime conditional evaluation
                    if (Device.PROBE_ENABLED) {
                        if (self.device.probe) |*p| p.addFrames(@intCast(frames_actually_transfered));
                    }

                    to_transfer -= @as(c_ulong, @intCast(frames_actually_transfered));
                }
            }
        }

        fn xrunRecovery(self: *Self, c_err: c_int) AudioLoopError!void {
            const err = if (c_err == -c_alsa.EPIPE) AudioLoopError.xrun else AudioLoopError.suspended;

            std.debug.print("Xrun recovery: {s}\n", .{c_alsa.snd_strerror(c_err)});

            const needs_prepare = switch (err) {
                AudioLoopError.xrun => true,

                AudioLoopError.suspended => blk: {
                    var res = c_alsa.snd_pcm_resume(self.device.pcm_handle);
                    var sleep: u64 = 10 * MILLISECONDS; // 10ms
                    var retries: i32 = MAX_RETRY;

                    while (res == -c_alsa.EAGAIN) {
                        log.debug("Trying to resume device. Retry: {d}", .{MAX_RETRY - retries});

                        if (retries == 0) {
                            log.err("Timeout while trying to resume device after {d} retries.", .{MAX_RETRY});
                            return AudioLoopError.timeout;
                        }

                        utils.sleepNs(sleep);

                        sleep = @intFromFloat(@as(f32, @floatFromInt(sleep)) * SLEEP_INCREMENT);
                        retries -= 1;
                        res = c_alsa.snd_pcm_resume(self.device.pcm_handle);
                    }

                    if (res < 0) break :blk true;
                    break :blk false;
                },

                else => {
                    log.err("Unexpected error: {s}", .{c_alsa.snd_strerror(c_err)});
                    return AudioLoopError.unexpected;
                },
            };

            if (!needs_prepare) return;

            const res = c_alsa.snd_pcm_prepare(self.device.pcm_handle);

            if (res < 0) {
                log.err("Failed to recover from xrun: {s}", .{c_alsa.snd_strerror(res)});
                return AudioLoopError.xrun;
            }
        }
    };
}

fn FullDuplexAudioLoop(ContextType: type, comptime_opts: DeviceComptimeOptions) type {
    return struct {
        const Self = @This();

        const format_type = comptime_opts.format;

        pub fn AudioCallback() type {
            return *const fn (ctx: *ContextType, in: *GenericAudioData(format_type), out: *GenericAudioData(format_type)) void;
        }

        const Device = FullDuplexDevice(ContextType, comptime_opts);
        const HalfDevice = HalfDuplexDevice(ContextType, comptime_opts);

        const AvailStatus = enum {
            skip,
            do_nothing,
        };

        const ZeroTransfers = struct {
            playback: usize = 0,
            capture: usize = 0,

            fn increment(self: *ZeroTransfers, stream_type: StreamType) void {
                if (stream_type == .capture) self.capture += 1 else self.playback += 1;
            }

            fn zero(self: *ZeroTransfers, stream_type: StreamType) void {
                if (stream_type == .capture) self.capture = 0 else self.playback = 0;
            }

            fn get(self: *ZeroTransfers, stream_type: StreamType) usize {
                return if (stream_type == .capture) self.capture else self.playback;
            }

            fn reachedMax(self: *ZeroTransfers) bool {
                return self.capture >= MAX_ZERO_TRANSFERS or self.playback >= MAX_ZERO_TRANSFERS;
            }
        };

        device: Device,
        running: bool = false,
        callback: AudioCallback(),
        ctx: *ContextType,
        playback_stopped: bool = false,
        capture_stopped: bool = false,
        zero_transfers: ZeroTransfers = ZeroTransfers{},
        maybe_playback_areas: ?*const c_alsa.snd_pcm_channel_area_t = null,
        maybe_capture_areas: ?*const c_alsa.snd_pcm_channel_area_t = null,
        total_frames: i64 = 0,

        pub fn init(device: Device, ctx: *ContextType, callback: AudioCallback()) Self {
            return .{
                .device = device,
                .ctx = ctx,
                .callback = callback,
            };
        }

        pub fn start(self: *Self) !void {
            self.running = true;

            if (self.device.playback_device.buffer_size != self.device.capture_device.buffer_size) {
                log.err("Capture and playback buffer size should be the same", .{});
                return AudioLoopError.buffer_size;
            }

            switch (self.device.capture_device.access_type) {
                AccessType.mmap_interleaved => {
                    if (self.device.is_linked) try self.mmapTransferLinked() else try self.mmapTransfer();
                },

                AccessType.rw_interleaved => try self.rwTransfer(),

                else => {
                    log.err("Unsupported access type: {s}", .{@tagName(self.device.capture_device.access_type)});
                    return AudioLoopError.unsupported;
                },
            }
        }

        fn mmapTransfer(self: *Self) !void {
            try self.silencePlayback();

            // capture and playback buffer size should be the same
            const buffer_size: c_ulong = @intFromEnum(self.device.playback_device.buffer_size);

            if (Device.PROBE_ENABLED) {
                if (self.device.playback_device.probe) |*p| p.start();
            }

            while (self.running) {
                try self.checkState(.playback);
                try self.checkState(.capture);

                const status = try self.checkUnlinkedAvailability(buffer_size);

                if (status == .skip) continue;

                var to_transfer: c_ulong = buffer_size;
                var playback_offset: c_ulong = 0;
                var capture_offset: c_ulong = 0;

                while (to_transfer > 0) {
                    var playback_expected_transfer = to_transfer;
                    var capture_expected_transfer = to_transfer;

                    const playback_buffer = try self.begin(&playback_offset, &playback_expected_transfer, .playback);
                    const capture_buffer = try self.begin(&capture_offset, &capture_expected_transfer, .capture);

                    var capture_data =
                        GenericAudioData(format_type)
                        .init(
                        capture_buffer,
                        self.device.capture_device.channels,
                        self.device.capture_device.sample_rate,
                        self.device.capture_device.audio_format,
                    );

                    var playback_data =
                        GenericAudioData(format_type)
                        .init(
                        playback_buffer,
                        self.device.playback_device.channels,
                        self.device.playback_device.sample_rate,
                        self.device.playback_device.audio_format,
                    );

                    self.callback(self.ctx, &capture_data, &playback_data);

                    const playback_transferred = try self.commit(playback_offset, playback_expected_transfer, .playback);
                    const capture_transferred = try self.commit(capture_offset, capture_expected_transfer, .capture);

                    const frames_transferred = @min(capture_transferred, playback_transferred);

                    if (Device.PROBE_ENABLED) {
                        if (self.device.playback_device.probe) |*p| p.addFrames(frames_transferred);
                    }

                    // log.debug("Transferred {d} frames", .{frames_transferred});
                    to_transfer -= @as(c_ulong, @intCast(frames_transferred));
                }
            }
        }

        fn mmapTransferLinked(self: *Self) !void {
            const buffer_size: c_ulong = @intFromEnum(self.device.playback_device.buffer_size);
            self.playback_stopped = true;
            // comptime check

            if (Device.PROBE_ENABLED) {
                // full duplex uses de master device to probe
                if (self.device.playback_device.probe) |*p| p.start();
            }

            while (self.running) {
                try self.checkState(.playback);
                try self.checkState(.capture);

                // will skip until we have available in master device
                const status = try self.checkLinkedAvailability(buffer_size);
                if (status == .skip) continue;

                // in frames
                var to_transfer = buffer_size;
                var playback_offset: c_ulong = 0;
                var capture_offset: c_ulong = 0;

                while (to_transfer > 0) {
                    var playback_expected_transfer = to_transfer;
                    var capture_expected_transfer = to_transfer;

                    const playback_buffer = try self.begin(&playback_offset, &playback_expected_transfer, .playback);
                    const capture_buffer = try self.begin(&capture_offset, &capture_expected_transfer, .capture);

                    var capture_data =
                        GenericAudioData(format_type)
                        .init(
                        capture_buffer,
                        self.device.capture_device.channels,
                        self.device.capture_device.sample_rate,
                        self.device.capture_device.audio_format,
                    );

                    var playback_data =
                        GenericAudioData(format_type)
                        .init(
                        playback_buffer,
                        self.device.playback_device.channels,
                        self.device.playback_device.sample_rate,
                        self.device.playback_device.audio_format,
                    );

                    self.callback(self.ctx, &capture_data, &playback_data);
                    const playback_frames_transferred = try self.commit(playback_offset, playback_expected_transfer, .playback);

                    // we don't care about the capture frames transferred for snd_pcm_link devices
                    // the playback is our master device
                    _ = try self.commit(capture_offset, capture_expected_transfer, .capture);

                    if (Device.PROBE_ENABLED) {
                        if (self.device.playback_device.probe) |*p| p.addFrames(playback_frames_transferred);
                    }

                    to_transfer -= @as(c_ulong, @intCast(playback_frames_transferred));
                }
            }
        }

        fn rwTransfer(self: *Self) !void {
            const buffer_size: c_ulong = @intFromEnum(self.device.playback_device.buffer_size);

            if (Device.PROBE_ENABLED) {
                if (self.device.playback_device.probe) |*p| p.start();
            }

            while (self.running) {
                const status = switch (self.device.is_linked) {
                    false => try self.checkUnlinkedAvailability(buffer_size),
                    true => try self.checkLinkedAvailability(buffer_size),
                };

                if (status == .skip) continue;

                var to_transfer = buffer_size;

                while (to_transfer > 0) {
                    const frames_read = try self.read(to_transfer);

                    var capture_data = GenericAudioData(format_type).init(
                        self.device.capture_device.transfer_buffer,
                        self.device.capture_device.channels,
                        self.device.capture_device.sample_rate,
                        self.device.capture_device.audio_format,
                    );

                    var playback_data = GenericAudioData(format_type).init(
                        self.device.playback_device.transfer_buffer,
                        self.device.playback_device.channels,
                        self.device.playback_device.sample_rate,
                        self.device.playback_device.audio_format,
                    );

                    self.callback(self.ctx, &capture_data, &playback_data);

                    const frames_written = try self.write(to_transfer);

                    if (frames_written != buffer_size) {
                        log.err("Written frames does not match buffer size: {d} != {d}", .{ buffer_size, frames_written });
                        return AudioLoopError.missmatch;
                    }

                    if (frames_read != buffer_size) {
                        log.err("Read frames does not match buffer size: {d} != {d}", .{ buffer_size, frames_read });
                        return AudioLoopError.missmatch;
                    }

                    const frames_transferred = @min(frames_read, frames_written);

                    if (Device.PROBE_ENABLED) {
                        if (self.device.playback_device.probe) |*p| p.addFrames(frames_transferred);
                    }

                    self.total_frames += frames_transferred;

                    to_transfer -= @as(c_ulong, @intCast(frames_transferred));
                }
            }
        }

        fn read(self: *Self, frames: c_ulong) !c_long {
            const pcm_handle = self.device.capture_device.pcm_handle;
            const buffer = self.device.capture_device.transfer_buffer;

            const f = @as(c_alsa.snd_pcm_uframes_t, @intCast(frames));
            var frames_read = c_alsa.snd_pcm_readi(pcm_handle, buffer.ptr, f);

            if (frames_read < 0) {
                log.warn("Read error: {s}", .{c_alsa.snd_strerror(@intCast(frames_read))});

                try self.xrunRecovery(@intCast(frames_read), .capture);

                frames_read = c_alsa.snd_pcm_readi(pcm_handle, buffer.ptr, f);

                if (frames_read < 0) {
                    log.err("Failed to recover from read error: {s}", .{c_alsa.snd_strerror(@intCast(frames_read))});
                    return frames_read;
                }
            }

            return frames_read;
        }

        fn write(self: *Self, frames: c_ulong) !c_long {
            const pcm_handle = self.device.playback_device.pcm_handle;
            const buffer = self.device.playback_device.transfer_buffer;
            const f = @as(c_alsa.snd_pcm_uframes_t, @intCast(frames));

            const frames_written = c_alsa.snd_pcm_writei(pcm_handle, buffer.ptr, f);

            if (frames_written < 0) {
                try self.xrunRecovery(@intCast(frames_written), .playback);
            }

            return frames_written;
        }

        inline fn checkState(self: Self, stream_type: StreamType) !void {
            const pcm_device = if (stream_type == .capture) self.device.capture_device.pcm_handle else self.device.playback_device.pcm_handle;

            const state: c_uint = c_alsa.snd_pcm_state(pcm_device);

            switch (state) {
                c_alsa.SND_PCM_STATE_XRUN => {
                    try self.xrunRecovery(-c_alsa.EPIPE, stream_type);
                },

                c_alsa.SND_PCM_STATE_SUSPENDED => try self.xrunRecovery(-c_alsa.ESTRPIPE, .playback),

                else => {
                    if (state < 0) {
                        log.err("Unexpected state error: {s}", .{c_alsa.snd_strerror(state)});
                        return AudioLoopError.unexpected;
                    }
                },
            }
        }

        fn silencePlayback(self: *Self) !void {
            const buffer_size: c_ulong = @intFromEnum(self.device.playback_device.buffer_size);

            for (0..self.device.playback_device.n_periods) |_| {
                var offset: c_ulong = 0;
                var expected_transfer: c_ulong = buffer_size;

                const playback_buffer = try self.begin(&offset, &expected_transfer, .playback);
                // we use the rw buffer to silence the playback for mmap access
                @memcpy(playback_buffer, self.device.playback_device.transfer_buffer);

                _ = try self.commit(offset, expected_transfer, .playback);
            }

            if (c_alsa.snd_pcm_start(self.device.capture_device.pcm_handle) < 0) {
                return AudioLoopError.start;
            }
            if (c_alsa.snd_pcm_start(self.device.playback_device.pcm_handle) < 0) {
                return AudioLoopError.start;
            }
        }

        inline fn checkUnlinkedAvailability(self: *Self, buffer_size: c_ulong) !AvailStatus {
            const capture_avail = c_alsa.snd_pcm_avail_update(self.device.capture_device.pcm_handle);

            if (capture_avail < 0) {
                try self.xrunRecovery(@intCast(capture_avail), .capture);
                self.capture_stopped = true;
                return .skip;
            }

            if (capture_avail < buffer_size and self.capture_stopped) {
                const err = c_alsa.snd_pcm_start(self.device.capture_device.pcm_handle);

                if (err < 0) {
                    log.err("Failed to start capture pcm: {s}", .{c_alsa.snd_strerror(err)});
                    return AudioLoopError.start;
                }

                self.capture_stopped = false;
                return .skip;
            }

            if (capture_avail < buffer_size and !self.capture_stopped) {
                // and start it, since it won't have any frames available until started.
                // Note: In linked mode, capture (slave) device starts automatically with playback (master).
                // In unlinked mode, we need to explicitly check if capture is still in PREPARED state
                // and start it, since it won't have any frames available until started.
                const state = c_alsa.snd_pcm_state(self.device.capture_device.pcm_handle);

                if (state == c_alsa.SND_PCM_STATE_PREPARED) {
                    const err = c_alsa.snd_pcm_start(self.device.capture_device.pcm_handle);

                    if (err < 0) {
                        log.err("Failed to start capture pcm: {s}", .{c_alsa.snd_strerror(err)});
                        return AudioLoopError.start;
                    }
                }

                const err = c_alsa.snd_pcm_wait(self.device.capture_device.pcm_handle, self.device.capture_device.timeout);

                if (err < 0) {
                    try self.xrunRecovery(err, .capture);
                    self.capture_stopped = true;
                    // continue
                    return .skip;
                }
            }

            const playback_avail = c_alsa.snd_pcm_avail_update(self.device.playback_device.pcm_handle);

            if (playback_avail < 0) {
                try self.xrunRecovery(@intCast(playback_avail), .playback);
                self.playback_stopped = true;
                return .skip;
            }

            if (playback_avail < buffer_size and self.playback_stopped) {
                const err = c_alsa.snd_pcm_start(self.device.playback_device.pcm_handle);

                if (err < 0) {
                    log.err("Failed to start playback pcm: {s}", .{c_alsa.snd_strerror(err)});
                    return AudioLoopError.start;
                }

                self.playback_stopped = false;
                return .skip;
            }

            if (playback_avail < buffer_size and !self.playback_stopped) {
                // Note: In unlinked mode, both capture and playback need explicit state management.
                // Even though playback isn't a slave device, it can still be in PREPARED state
                // and will need explicit starting when sufficient buffer space is available.
                // Without this check, the device can get stuck waiting after the first hardware buffer cycle.
                const state = c_alsa.snd_pcm_state(self.device.playback_device.pcm_handle);

                if (state == c_alsa.SND_PCM_STATE_PREPARED) {
                    const err = c_alsa.snd_pcm_start(self.device.playback_device.pcm_handle);

                    if (err < 0) {
                        log.err("Failed to start capture pcm: {s}", .{c_alsa.snd_strerror(err)});
                        return AudioLoopError.start;
                    }
                }

                const err = c_alsa.snd_pcm_wait(self.device.playback_device.pcm_handle, self.device.playback_device.timeout);

                if (err < 0) {
                    try self.xrunRecovery(err, .playback);
                    self.playback_stopped = true;
                    return .skip;
                }
            }

            const avail = @min(capture_avail, if (playback_avail > 0) playback_avail else capture_avail);

            if (avail < buffer_size) return .skip;

            return .do_nothing;
        }

        inline fn checkLinkedAvailability(self: *Self, buffer_size: c_ulong) !AvailStatus {
            const avail = c_alsa.snd_pcm_avail_update(self.device.playback_device.pcm_handle);

            if (avail < 0) {
                try self.xrunRecovery(@intCast(avail), .playback);
                return .skip;
            }

            if (avail < buffer_size and self.playback_stopped) {
                const err = c_alsa.snd_pcm_start(self.device.playback_device.pcm_handle);

                if (err < 0) {
                    log.err("Failed to start playback pcm: {s}", .{c_alsa.snd_strerror(err)});
                    return AudioLoopError.start;
                }

                self.playback_stopped = false;
                return .skip;
            }

            if (avail < buffer_size and !self.playback_stopped) {
                const err = c_alsa.snd_pcm_wait(self.device.playback_device.pcm_handle, self.device.playback_device.timeout);

                if (err < 0) {
                    try self.xrunRecovery(err, .playback);
                    self.playback_stopped = true;
                    return .skip;
                }
            }

            return .do_nothing;
        }

        fn begin(self: *Self, offset: *c_alsa.snd_pcm_uframes_t, expected_to_transfer: *c_alsa.snd_pcm_uframes_t, stream_type: StreamType) ![]u8 {
            var maybe_areas = if (stream_type == .capture) self.maybe_capture_areas else self.maybe_playback_areas;
            const device = if (stream_type == .capture) self.device.capture_device else self.device.playback_device;

            const res = c_alsa.snd_pcm_mmap_begin(device.pcm_handle, &maybe_areas, offset, expected_to_transfer);

            if (res < 0) {
                try self.xrunRecovery(res, stream_type);
                self.playback_stopped = true;
            }

            const areas = maybe_areas orelse return AudioLoopError.unexpected;
            const addr = areas.addr orelse return AudioLoopError.unexpected;

            const verifier = AlignmentVerifier(ContextType, comptime_opts){};

            try verifier.verifyAlignment(device, areas);

            const step: c_ulong = @divFloor(areas.step, 8);
            const buf_start: c_ulong = (@divFloor(areas.first, 8)) + (offset.* * step);

            return @as([*]u8, @ptrCast(addr))[buf_start .. buf_start + expected_to_transfer.* * step];
        }

        inline fn commit(self: *Self, offset: c_ulong, expected_to_transfer: c_ulong, stream_type: StreamType) !c_long {
            const pcm_handle = if (stream_type == .capture) self.device.capture_device.pcm_handle else self.device.playback_device.pcm_handle;

            const frames_actually_transfered = c_alsa.snd_pcm_mmap_commit(pcm_handle, offset, expected_to_transfer);

            if (frames_actually_transfered < 0) {
                try self.xrunRecovery(@intCast(frames_actually_transfered), .playback);
            } else if (frames_actually_transfered != expected_to_transfer) try self.xrunRecovery(-c_alsa.EPIPE, .playback);

            if (frames_actually_transfered == 0) {
                const state = c_alsa.snd_pcm_state(pcm_handle);

                // In linked mode, capture (slave) will yield zero transfers while in PREPARED state, which is normal
                // For unlinked mode, capture is explicitly started in checkUnlinkedAvailability() when in PREPARED state,
                if (!(self.device.is_linked and stream_type == .capture and state == c_alsa.SND_PCM_STATE_PREPARED)) {
                    self.zero_transfers.increment(stream_type);
                }
            } else self.zero_transfers.zero(stream_type);

            if (self.zero_transfers.reachedMax()) {
                log.err("Too many consecutive zero transfers. Playback: {d}, Capture: {d}. Stopping device.", .{
                    self.zero_transfers.get(.playback),
                    self.zero_transfers.get(.capture),
                });

                self.playback_stopped = true;
                return AudioLoopError.xrun;
            }

            return frames_actually_transfered;
        }

        inline fn xrunRecovery(self: Self, c_err: c_int, stream_type: StreamType) AudioLoopError!void {
            const err = if (c_err == -c_alsa.EPIPE) AudioLoopError.xrun else AudioLoopError.suspended;

            const pcm_handle = if (stream_type == .capture) self.device.capture_device.pcm_handle else self.device.playback_device.pcm_handle;

            const needs_prepare = switch (err) {
                AudioLoopError.xrun => blk: {
                    log.debug("Xrun recovery in {s} stream: {s}", .{ @tagName(stream_type), c_alsa.snd_strerror(c_err) });
                    //log.warn("Total frames at this point??: {d}", .{self.total_frames});
                    break :blk true;
                },

                AudioLoopError.suspended => blk: {
                    var res = c_alsa.snd_pcm_resume(pcm_handle);
                    var sleep: u64 = 10 * MILLISECONDS; // 10ms
                    var retries: i32 = MAX_RETRY;

                    while (res == -c_alsa.EAGAIN) {
                        log.debug("Trying to resume device. Retry: {d}", .{MAX_RETRY - retries});

                        if (retries == 0) {
                            log.err("Timeout while trying to resume device after {d} retries.", .{MAX_RETRY});
                            return AudioLoopError.timeout;
                        }

                        utils.sleepNs(sleep);

                        sleep = @intFromFloat(@as(f32, @floatFromInt(sleep)) * SLEEP_INCREMENT);
                        retries -= 1;
                        res = c_alsa.snd_pcm_resume(pcm_handle);
                    }

                    if (res < 0) break :blk true;
                    break :blk false;
                },

                else => {
                    log.err("Unexpected error: {s}", .{c_alsa.snd_strerror(c_err)});
                    return AudioLoopError.unexpected;
                },
            };

            if (!needs_prepare) return;
            if (stream_type == .capture and self.device.is_linked) return;

            const res = c_alsa.snd_pcm_prepare(pcm_handle);

            if (res < 0) {
                log.err("Failed to recover from xrun: {s}", .{c_alsa.snd_strerror(res)});
                return AudioLoopError.xrun;
            }
        }
    };
}

fn AlignmentVerifier(ContextType: type, comptime comptime_opts: DeviceComptimeOptions) type {
    return struct {
        pub inline fn verifyAlignment(_: @This(), device: HalfDuplexDevice(ContextType, comptime_opts), area: *const c_alsa.snd_pcm_channel_area_t) !void {
            if (area.first % BYTE_ALIGN != 0) {
                log.err("Area.first not byte(8) aligned. area.first == {d}", .{area.first});
                return AudioLoopError.audio_buffer_nonalignment;
            }

            const bit_depth: c_uint = @intCast(device.audio_format.bit_depth);

            if (area.step % bit_depth != 0) {
                log.err("Area.step is non-aligned with audio_format.bit_depth. area.step == {d} bits && audio_format.bit_depth == {d} bits", .{ area.step, bit_depth });
                return AudioLoopError.audio_buffer_nonalignment;
            }

            const n_channels: c_uint = @intCast(device.channels);

            if (area.step != (n_channels * bit_depth)) {
                log.err("Area.step is not equal to audio_format.bit_depth * Device.n_channels. area.step == {d} bits && audio_format.bit_depth({d}) * Device.n_channels({d})  == {d} bits", .{
                    area.step,
                    bit_depth,
                    n_channels,
                    bit_depth * n_channels,
                });
                return AudioLoopError.audio_buffer_nonalignment;
            }
        }
    };
}
