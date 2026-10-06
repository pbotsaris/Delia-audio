const std = @import("std");
const c = @cImport({
    @cInclude("asoundlib.h");
});

const SampleFormat = @import("./convert.zig").SampleFormat;
const SampleConverter = @import("./convert.zig").SampleConverter;
const PlaybackLoop = @import("./loop.zig").PlaybackLoop;
const LoopError = @import("./loop.zig").LoopError;
const LoopStats = @import("./loop.zig").Stats;
const AlsaPcm = @import("./pcm.zig").AlsaPcm;

pub const DeviceError = error{
    open_failed,
    prepare_failed,
    hw_params_invalid,
    area_geometry_invalid,
    sw_params_invalid,
    access_unsupported, // only MMAP_INTERLEAVED for now
    format_unsupported,
    rate_unsupported,
    channels_unsupported,
    period_changed, // the hardware moved period or buffer size away from the request
    write_failed,
    not_prepared, // the device is not prepared for writing
} || std.mem.Allocator.Error;

const RealtimeError = DeviceError || LoopError;

pub const DeviceOptions = struct {
    ident: [:0]const u8 = "default",
    sample_rate: u32,
    channel_count: u32,
    period_frames: usize,
    n_periods: u32 = 2,
    timeout_ms: u32 = 100,
};

/// What the hardware actually agreed to. The plan is compiled against these, not the request.
pub const NegociatedConfig = struct {
    sample_rate: u32,
    channel_count: u32,
    period_frames: usize,
    buffer_frames: usize,
};

pub fn PlaybackDevice(comptime Ctx: type, comptime fmt: SampleFormat) type {
    return struct {
        const Self = @This();
        pub const Loop = PlaybackLoop(Ctx, fmt);
        pub const Callback = Loop.Callback;
        const Converter = SampleConverter(fmt);

        const alsa_format: c.snd_pcm_format_t = switch (fmt) {
            .s16_le => c.SND_PCM_FORMAT_S16_LE,
            .s32_le => c.SND_PCM_FORMAT_S32_LE,
        };

        handle: *c.snd_pcm_t,
        negociated_config: NegociatedConfig,
        timeout_ms: u32,
        pcm: AlsaPcm,
        loop: ?Loop = null, // set by prepare

        /// Open and negotiate hardware parameters. Allocates nothing of ours; alsa-lib's
        /// hw_params struct is freed before returning, only the negotiated values are kept.
        pub fn init(opts: DeviceOptions) !Self {
            var maybe_handle: ?*c.snd_pcm_t = null;

            const result = c.snd_pcm_open(&maybe_handle, opts.ident.ptr, c.SND_PCM_STREAM_PLAYBACK, 0);

            if (result < 0) return DeviceError.open_failed;
            const handle = maybe_handle orelse return DeviceError.open_failed;

            // any error we just close the device
            errdefer _ = c.snd_pcm_close(handle);

            var maybe_params: ?*c.snd_pcm_hw_params_t = null;

            if (c.snd_pcm_hw_params_malloc(&maybe_params) < 0) return DeviceError.hw_params;
            const params = maybe_params.?;
            defer c.snd_pcm_hw_params_free(params);

            if (c.snd_pcm_hw_params_any(handle, params) < 0) return DeviceError.hw_params;

            // negotiation table, contract section 3: M4a implements row 4 only
            if (c.snd_pcm_hw_params_set_access(handle, params, c.SND_PCM_ACCESS_MMAP_INTERLEAVED) < 0) return DeviceError.access_unsupported;
            if (c.snd_pcm_hw_params_set_format(handle, params, alsa_format) < 0) return DeviceError.format_unsupported;
            if (c.snd_pcm_hw_params_set_channels(handle, params, opts.channel_count) < 0) return DeviceError.channels_unsupported;

            var rate: c_uint = opts.sample_rate;
            var dir: c_int = 0;
            if (c.snd_pcm_hw_params_set_rate_near(handle, params, &rate, &dir) < 0) return DeviceError.rate_unsupported;

            var period: c.snd_pcm_uframes_t = opts.period_frames;
            var buffer: c.snd_pcm_uframes_t = opts.period_frames * opts.n_periods;
            if (c.snd_pcm_hw_params_set_period_size_near(handle, params, &period, &dir) < 0) return DeviceError.period_changed;
            if (c.snd_pcm_hw_params_set_buffer_size_near(handle, params, &buffer) < 0) return DeviceError.period_changed;

            if (c.snd_pcm_hw_params(handle, params) < 0) return DeviceError.hw_params;

            // read back what was set; `_near` may have moved any of these
            if (c.snd_pcm_hw_params_get_period_size(params, &period, &dir) < 0) return DeviceError.hw_params;
            if (c.snd_pcm_hw_params_get_buffer_size(params, &buffer) < 0) return DeviceError.hw_params;
            if (c.snd_pcm_hw_params_get_rate(params, &rate, &dir) < 0) return DeviceError.hw_params;

            // the period is the loop's unit and the staging capacity: a different one is an error.
            // A different rate is not: the caller compiles the plan against `negotiated.sample_rate`.
            if (period != opts.period_frames or buffer != opts.period_frames * opts.n_periods) return DeviceError.period_changed;

            return .{
                .handle = handle,
                .negotiated_config = .{ .sample_rate = rate, .channel_count = opts.channel_count, .period_frames = period, .buffer_frames = buffer },
                .timeout_ms = opts.timeout_ms,
                .pcm = .{ .handle = handle, .bytes_per_frame = opts.channel_count * Converter.bytes_per_sample },
            };
        }

        pub fn prepare(self: *Self, allocator: std.mem.Allocator) DeviceError!void {
            var maybe_sw: ?*c.snd_pcm_sw_params_t = null;

            if (c.snd_pcm_sw_params_malloc(&maybe_sw) < 0) return DeviceError.sw_params_invalid;

            const sw = maybe_sw orelse return DeviceError.sw_params_invalid;

            defer c.snd_pcm_sw_params_free(sw);

            const neg = self.negociated_config;

            if (c.snd_pcm_sw_params_current(self.handle, sw) < 0) return error.sw_params;

            // wake when one period is free; the loop starts the stream itself, so the start
            // threshold is "never": buffer_frames + 1 disables automatic start
            if (c.snd_pcm_sw_params_set_avail_min(self.handle, sw, neg.period_frames) < 0) return DeviceError.sw_params_invalid;
            if (c.snd_pcm_sw_params_set_start_threshold(self.handle, sw, neg.buffer_frames + 1) < 0) return DeviceError.sw_params_invalid;
            if (c.snd_pcm_sw_params_set_stop_threshold(self.handle, sw, neg.buffer_frames) < 0) return DeviceError.sw_params_invalid;
            // the legacy driver set all of the above and never applied them (driver.zig:525-533)
            if (c.snd_pcm_sw_params(self.handle, sw) < 0) return DeviceError.sw_params_invalid;

            if (c.snd_pcm_prepare(self.handle) < 0) return DeviceError.prepare_failed;

            // validate area geometry once, here, not per period
            const area = self.pcm.inspectArea() catch return DeviceError.area_geometry_invalid;
            if (area.first % 8 != 0 or area.step % 8 != 0) return DeviceError.area_geometry_invalid;
            if (area.step / 8 != self.pcm.bytes_per_frame) return DeviceError.area_geometry_invalid;

            self.loop = try Loop.init(allocator, &self.pcm, .{
                .channel_count = neg.channel_count,
                .period_frames = neg.period_frames,
                .timeout_ms = self.timeout_ms,
            });
        }

        pub fn start(self: *Self, ctx: *Ctx, callback: Callback) RealtimeError!void {
            // we need the reference to not create a copy from the Optional
            const loop = &(self.loop orelse return RealtimeError.not_prepared);
            return loop.start(ctx, callback);
        }

        pub fn stop(self: *Self) void {
            if (self.loop) |*loop| loop.stop();
        }

        pub fn getStats(self: *const Self) LoopStats {
            return if (self.loop) |loop| loop.stats else .{};
        }

        /// After stop. Drops pending frames;
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.loop) |*loop| loop.deinit(allocator);
            _ = c.snd_pcm_drop(self.handle);
            _ = c.snd_pcm_close(self.handle);
            self.* = undefined;
        }
    };
}
