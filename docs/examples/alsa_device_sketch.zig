//! Design sketch for docs/backend-contract.md sections 3, 6 and 7: the real `Pcm` seam over
//! alsa-lib and the playback device that negotiates, prepares and owns it.
//! Not part of the build. Links alsa-lib, so it needs the include path and static library:
//!
//!     zig test docs/examples/alsa_device_sketch.zig -I vendor/alsa/include vendor/alsa/src/.libs/libasound.a -lc
//!
//! A file under docs/ cannot import src/, so the first ~200 lines are stand-ins for things that
//! already exist. In src/ they are replaced by:
//!
//!     buffer  = @import("../../core/buffer/root.zig")   AudioBlock, ConstAudioBlock, OwnedAudioBuffer
//!     convert = @import("convert.zig")                     SampleFormat, SampleConverter
//!     loop    = @import("loop.zig")                        PcmError, Region, PlaybackLoop
//!
//! The parts worth implementing as written are marked "port as is" and land in:
//!
//!     src/backends/alsa/pcm.zig       AlsaPcm, regionFromArea (the only file besides driver.zig
//!                                     that imports asoundlib.h; loop.zig stays pure Zig)
//!     src/backends/alsa/driver.zig    PlaybackDevice, DeviceOptions, Negotiated, DeviceError
//!
//! The device test opens ALSA's `null` plugin, which exists on every machine with alsa-lib and
//! accepts any configuration, so the whole open -> negotiate -> prepare -> run -> stop -> close
//! path runs without a sound card. It skips if `null` cannot be opened.

const std = @import("std");

const c = @cImport({
    @cInclude("asoundlib.h");
});

// ===========================================================================
// Stand-ins for src/core/buffer and src/backends/alsa/convert.zig. Same names and layout.
// ===========================================================================

pub fn ConstAudioBlock(comptime T: type) type {
    return struct {
        samples: []const T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn channel(self: @This(), ch: usize) []const T {
            return self.samples[ch * self.channel_stride ..][0..self.frame_count];
        }
    };
}

pub fn AudioBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        samples: []T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn channel(self: Self, ch: usize) []T {
            return self.samples[ch * self.channel_stride ..][0..self.frame_count];
        }

        pub fn asConst(self: Self) ConstAudioBlock(T) {
            return .{ .samples = self.samples, .channel_count = self.channel_count, .frame_count = self.frame_count, .channel_stride = self.channel_stride };
        }
    };
}

pub fn OwnedAudioBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: []T,
        channel_count: usize,
        max_frames: usize,
        channel_stride: usize,

        pub fn init(allocator: std.mem.Allocator, channel_count: usize, max_frames: usize) !Self {
            const storage = try allocator.alloc(T, channel_count * max_frames);
            @memset(storage, 0);
            return .{ .storage = storage, .channel_count = channel_count, .max_frames = max_frames, .channel_stride = max_frames };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn borrowBlock(self: Self, frame_count: usize) error{out_of_range}!AudioBlock(T) {
            if (frame_count > self.max_frames) return error.out_of_range;
            return .{ .samples = self.storage, .channel_count = self.channel_count, .frame_count = frame_count, .channel_stride = self.channel_stride };
        }
    };
}

pub const SampleFormat = enum { s16_le, f32_le };

pub fn SampleConverter(comptime fmt: SampleFormat) type {
    return struct {
        pub const bytes_per_sample: usize = switch (fmt) {
            .s16_le => 2,
            .f32_le => 4,
        };

        pub fn byteLength(channel_count: usize, frame_count: usize) usize {
            return frame_count * channel_count * bytes_per_sample;
        }

        pub inline fn encode(dst: *[bytes_per_sample]u8, sample: f32) void {
            switch (fmt) {
                .s16_le => std.mem.writeInt(i16, dst, @intFromFloat(@round(std.math.clamp(sample, -1.0, 1.0) * std.math.maxInt(i16))), .little),
                .f32_le => std.mem.writeInt(u32, dst, @bitCast(sample), .little),
            }
        }

        pub fn writeInterleaved(dst: []u8, src: ConstAudioBlock(f32)) error{size_mismatch}!void {
            if (dst.len != byteLength(src.channel_count, src.frame_count)) return error.size_mismatch;
            const frame_bytes = src.channel_count * bytes_per_sample;
            for (0..src.channel_count) |ch| {
                var at = ch * bytes_per_sample;
                for (src.channel(ch)) |sample| {
                    encode(dst[at..][0..bytes_per_sample], sample);
                    at += frame_bytes;
                }
            }
        }
    };
}

// ===========================================================================
// Stand-in for src/backends/alsa/loop.zig: same as device_loop_sketch.zig.
// ===========================================================================

pub const PcmError = error{ xrun, suspended, io, timeout };
pub const LoopError = error{ no_progress, failed_recovery } || PcmError;

pub const Region = struct {
    bytes: []u8,
    frame_count: usize,
};

pub const Stats = struct {
    periods: u64 = 0,
    blocks: u64 = 0,
    xruns: u64 = 0,
    discontinuities: u64 = 0,
    short_commits: u64 = 0,
    zero_transfers: u64 = 0,
};

pub const LoopOptions = struct {
    channel_count: usize,
    period_frames: usize,
    timeout_ms: u32 = 100,
    max_zero_transfers: usize = 5,
};

pub fn PlaybackLoop(comptime Ctx: type, comptime Pcm: type, comptime fmt: SampleFormat) type {
    return struct {
        const Self = @This();
        pub const Callback = *const fn (ctx: *Ctx, out: AudioBlock(f32)) void;
        const Convert = SampleConverter(fmt);
        const Readiness = enum { ready, skip_period };

        pcm: *Pcm,
        staging: OwnedAudioBuffer(f32),
        opts: LoopOptions,
        running: std.atomic.Value(bool) = .init(false),
        started: bool = false,
        stats: Stats = .{},

        pub fn init(allocator: std.mem.Allocator, pcm: *Pcm, opts: LoopOptions) !Self {
            return .{ .pcm = pcm, .staging = try OwnedAudioBuffer(f32).init(allocator, opts.channel_count, opts.period_frames), .opts = opts };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(!self.running.load(.acquire));
            self.staging.deinit(allocator);
        }

        pub fn start(self: *Self, ctx: *Ctx, callback: Callback) LoopError!void {
            self.running.store(true, .release);
            defer self.running.store(false, .release);
            while (self.running.load(.acquire)) try self.runPeriod(ctx, callback);
        }

        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
        }

        pub fn runPeriod(self: *Self, ctx: *Ctx, callback: Callback) LoopError!void {
            self.stats.periods += 1;
            const avail = self.pcm.availUpdate() catch |err| return self.recover(err);
            if (try self.waitPeriod(avail) == .skip_period) return;

            var remaining = self.opts.period_frames;
            var zero_progress: usize = 0;
            while (remaining > 0) {
                const region = self.pcm.mmapBegin(remaining) catch |err| {
                    self.stats.discontinuities += 1;
                    return self.recover(err);
                };
                if (region.frame_count == 0) {
                    zero_progress += 1;
                    self.stats.zero_transfers += 1;
                    if (zero_progress >= self.opts.max_zero_transfers) return error.no_progress;
                    _ = self.pcm.mmapCommit(0) catch |err| return self.recover(err);
                    continue;
                }
                zero_progress = 0;

                const block = self.staging.borrowBlock(region.frame_count) catch unreachable;
                callback(ctx, block);
                self.stats.blocks += 1;
                Convert.writeInterleaved(region.bytes[0..Convert.byteLength(self.opts.channel_count, region.frame_count)], block.asConst()) catch unreachable;

                const committed = self.pcm.mmapCommit(region.frame_count) catch |err| {
                    self.stats.discontinuities += 1;
                    return self.recover(err);
                };
                if (committed != region.frame_count) {
                    self.stats.short_commits += 1;
                    self.stats.discontinuities += 1;
                    return self.recover(error.xrun);
                }
                remaining -= committed;
            }
        }

        fn recover(self: *Self, err: PcmError) LoopError!void {
            switch (err) {
                error.xrun, error.suspended => {
                    self.stats.xruns += 1;
                    self.pcm.recover(err) catch return error.failed_recovery;
                    self.started = false;
                },
                error.timeout => {},
                error.io => return error.io,
            }
        }

        fn waitPeriod(self: *Self, avail: usize) LoopError!Readiness {
            if (avail >= self.opts.period_frames) return .ready;
            if (!self.started) {
                try self.pcm.start();
                self.started = true;
                return .skip_period;
            }
            self.pcm.wait(self.opts.timeout_ms) catch |err| {
                try self.recover(err);
                return .skip_period;
            };
            return .ready;
        }
    };
}

// ===========================================================================
// pcm.zig: AlsaPcm (port as is). Contract section 7.
//
// The real seam. Borrows the handle the device owns; no deinit. Converts negative ALSA results
// to PcmError so no unsigned cast downstream ever sees one. Holds exactly one piece of state,
// the mmap offset, because `begin` produces it and `commit` needs it back.
// ===========================================================================

pub const AlsaPcm = struct {
    const Self = @This();

    handle: *c.snd_pcm_t,
    bytes_per_frame: usize,
    offset: c.snd_pcm_uframes_t = 0,

    pub fn availUpdate(self: *Self) PcmError!usize {
        const n = c.snd_pcm_avail_update(self.handle);
        if (n < 0) return errnoToPcm(n);
        return @intCast(n);
    }

    pub fn start(self: *Self) PcmError!void {
        const r = c.snd_pcm_start(self.handle);
        if (r < 0) return errnoToPcm(r);
    }

    /// 0 from snd_pcm_wait means the timeout elapsed, not success.
    pub fn wait(self: *Self, timeout_ms: u32) PcmError!void {
        const r = c.snd_pcm_wait(self.handle, @intCast(timeout_ms));
        if (r == 0) return error.timeout;
        if (r < 0) return errnoToPcm(r);
    }

    pub fn mmapBegin(self: *Self, want: usize) PcmError!Region {
        var areas: ?*const c.snd_pcm_channel_area_t = null;
        var frames: c.snd_pcm_uframes_t = want;

        const r = c.snd_pcm_mmap_begin(self.handle, &areas, &self.offset, &frames);
        if (r < 0) return errnoToPcm(r);

        // interleaved access: one area describes every channel; geometry was validated at prepare
        const area = areas orelse return error.io;
        return regionFromArea(area, self.offset, frames, self.bytes_per_frame) orelse error.io;
    }

    pub fn mmapCommit(self: *Self, frame_count: usize) PcmError!usize {
        const r = c.snd_pcm_mmap_commit(self.handle, self.offset, frame_count);
        if (r < 0) return errnoToPcm(r);
        return @intCast(r);
    }

    /// xrun: prepare. suspended: resume until the device stops saying EAGAIN, then prepare if
    /// resume still failed. Bounded. The loop decides what a recovery means; this just does it.
    pub fn recover(self: *Self, err: PcmError) PcmError!void {
        if (err == error.suspended) {
            var retries: u32 = 10;
            var r = c.snd_pcm_resume(self.handle);
            while (r == -c.EAGAIN and retries > 0) : (retries -= 1) {
                sleepMs(10);
                r = c.snd_pcm_resume(self.handle);
            }
            if (r >= 0) return;
        }
        const r = c.snd_pcm_prepare(self.handle);
        if (r < 0) return errnoToPcm(r);
    }

    pub fn state(self: *Self) c.snd_pcm_state_t {
        return c.snd_pcm_state(self.handle);
    }

    /// Geometry of the mmap area without transferring anything: begin(0) then commit(0).
    /// The device calls this once at prepare to validate `first` and `step`.
    pub fn inspectArea(self: *Self) PcmError!c.snd_pcm_channel_area_t {
        _ = try self.availUpdate();
        var areas: ?*const c.snd_pcm_channel_area_t = null;
        var frames: c.snd_pcm_uframes_t = 0;
        const r = c.snd_pcm_mmap_begin(self.handle, &areas, &self.offset, &frames);
        if (r < 0) return errnoToPcm(r);
        const area = (areas orelse return error.io).*;
        _ = try self.mmapCommit(0);
        return area;
    }

    /// `r` is a negative ALSA result; c_int from most calls, snd_pcm_sframes_t from avail/commit.
    fn errnoToPcm(r: anytype) PcmError {
        const errno: c_int = @intCast(-r);
        return switch (errno) {
            c.EPIPE => error.xrun,
            c.ESTRPIPE => error.suspended,
            else => error.io,
        };
    }
};

/// Pure arithmetic over an interleaved area, separated so it can be tested without a device.
/// Returns null when the area's stride disagrees with the negotiated frame size.
fn regionFromArea(area: *const c.snd_pcm_channel_area_t, offset: c.snd_pcm_uframes_t, frame_count: c.snd_pcm_uframes_t, bytes_per_frame: usize) ?Region {
    const step_bytes: usize = area.step / 8;
    if (step_bytes != bytes_per_frame) return null;

    const base: [*]u8 = @ptrCast(area.addr orelse return null);
    const start: usize = area.first / 8 + offset * step_bytes;
    return .{ .bytes = base[start..][0 .. frame_count * step_bytes], .frame_count = frame_count };
}

fn sleepMs(ms: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&req, null);
}

// ===========================================================================
// driver.zig: PlaybackDevice (port as is). Contract sections 3 and 6.
//
// Owns the handle and the loop. init opens and negotiates hardware parameters; prepare sets
// software parameters, validates the area geometry, and builds the seam and the loop. Nothing
// is allocated after prepare. Not movable after prepare: the loop points at `self.pcm`.
// ===========================================================================

pub const DeviceOptions = struct {
    ident: [:0]const u8 = "default",
    sample_rate: u32,
    channel_count: u32,
    period_frames: usize,
    n_periods: u32 = 2,
    timeout_ms: u32 = 100,
};

/// What the hardware actually agreed to. The plan is compiled against these, not the request.
pub const Negotiated = struct {
    sample_rate: u32,
    channel_count: u32,
    period_frames: usize,
    buffer_frames: usize,

};
pub const DeviceError = error{
    open,
    hw_params,
    access_unsupported, // only MMAP_INTERLEAVED in M4a (contract 3, row 4)
    format_unsupported,
period_changed, // the hardware moved period or buffer size away from the request
    channels_unsupported,
    rate_unsupported,
    prepare,
sw_params,
    area_geometry,
    not_prepared,
} || std.mem.Allocator.Error;

pub fn PlaybackDevice(comptime Ctx: type, comptime fmt: SampleFormat) type {
    return struct {
        const Self = @This();

        pub const Loop = PlaybackLoop(Ctx, AlsaPcm, fmt);
        pub const Callback = Loop.Callback;
        const Convert = SampleConverter(fmt);

        const alsa_format: c.snd_pcm_format_t = switch (fmt) {
            .s16_le => c.SND_PCM_FORMAT_S16_LE,
            .f32_le => c.SND_PCM_FORMAT_FLOAT_LE,
        };

        handle: *c.snd_pcm_t,
        negotiated: Negotiated,
        timeout_ms: u32,
        pcm: AlsaPcm,
        loop: ?Loop = null, // set by prepare

        /// Open and negotiate hardware parameters. Allocates nothing of ours; alsa-lib's
        /// hw_params struct is freed before returning, only the negotiated values are kept.
        pub fn init(opts: DeviceOptions) DeviceError!Self {
            var maybe_handle: ?*c.snd_pcm_t = null;
            if (c.snd_pcm_open(&maybe_handle, opts.ident.ptr, c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.open;
            const handle = maybe_handle.?;
            errdefer _ = c.snd_pcm_close(handle);
            var maybe_params: ?*c.snd_pcm_hw_params_t = null;

            if (c.snd_pcm_hw_params_malloc(&maybe_params) < 0) return error.hw_params;
            const params = maybe_params.?;
            defer c.snd_pcm_hw_params_free(params);

            if (c.snd_pcm_hw_params_any(handle, params) < 0) return error.hw_params;

            // negotiation table, contract section 3: M4a implements row 4 only
            if (c.snd_pcm_hw_params_set_access(handle, params, c.SND_PCM_ACCESS_MMAP_INTERLEAVED) < 0) return error.access_unsupported;
            if (c.snd_pcm_hw_params_set_format(handle, params, alsa_format) < 0) return error.format_unsupported;
            if (c.snd_pcm_hw_params_set_channels(handle, params, opts.channel_count) < 0) return error.channels_unsupported;

            var rate: c_uint = opts.sample_rate;
            var dir: c_int = 0;
            if (c.snd_pcm_hw_params_set_rate_near(handle, params, &rate, &dir) < 0) return error.rate_unsupported;

            var period: c.snd_pcm_uframes_t = opts.period_frames;
            var buffer: c.snd_pcm_uframes_t = opts.period_frames * opts.n_periods;
            if (c.snd_pcm_hw_params_set_period_size_near(handle, params, &period, &dir) < 0) return error.period_changed;
            if (c.snd_pcm_hw_params_set_buffer_size_near(handle, params, &buffer) < 0) return error.period_changed;

            if (c.snd_pcm_hw_params(handle, params) < 0) return error.hw_params;

            // read back what was set; `_near` may have moved any of these
            if (c.snd_pcm_hw_params_get_period_size(params, &period, &dir) < 0) return error.hw_params;
            if (c.snd_pcm_hw_params_get_buffer_size(params, &buffer) < 0) return error.hw_params;
            if (c.snd_pcm_hw_params_get_rate(params, &rate, &dir) < 0) return error.hw_params;

            // the period is the loop's unit and the staging capacity: a different one is an error.
            // A different rate is not: the caller compiles the plan against `negotiated.sample_rate`.
            if (period != opts.period_frames or buffer != opts.period_frames * opts.n_periods) return error.period_changed;

            return .{
                .handle = handle,
                .negotiated = .{ .sample_rate = rate, .channel_count = opts.channel_count, .period_frames = period, .buffer_frames = buffer },
                .timeout_ms = opts.timeout_ms,
                .pcm = .{ .handle = handle, .bytes_per_frame = opts.channel_count * Convert.bytes_per_sample },
            };
        }

        /// Software parameters, snd_pcm_prepare, area check, staging. The only allocation.
        pub fn prepare(self: *Self, allocator: std.mem.Allocator) DeviceError!void {
            var maybe_sw: ?*c.snd_pcm_sw_params_t = null;
            if (c.snd_pcm_sw_params_malloc(&maybe_sw) < 0) return error.sw_params;
            const sw = maybe_sw.?;
            defer c.snd_pcm_sw_params_free(sw);

            const n = self.negotiated;
            if (c.snd_pcm_sw_params_current(self.handle, sw) < 0) return error.sw_params;
            // wake when one period is free; the loop starts the stream itself, so the start
            // threshold is "never": buffer_frames + 1 disables automatic start
            if (c.snd_pcm_sw_params_set_avail_min(self.handle, sw, n.period_frames) < 0) return error.sw_params;
            if (c.snd_pcm_sw_params_set_start_threshold(self.handle, sw, n.buffer_frames + 1) < 0) return error.sw_params;
            if (c.snd_pcm_sw_params_set_stop_threshold(self.handle, sw, n.buffer_frames) < 0) return error.sw_params;
            // the legacy driver set all of the above and never applied them (driver.zig:525-533)
            if (c.snd_pcm_sw_params(self.handle, sw) < 0) return error.sw_params;

            if (c.snd_pcm_prepare(self.handle) < 0) return error.prepare;

            // validate area geometry once, here, not per period
            const area = self.pcm.inspectArea() catch return error.area_geometry;
            if (area.first % 8 != 0 or area.step % 8 != 0) return error.area_geometry;
            if (area.step / 8 != self.pcm.bytes_per_frame) return error.area_geometry;

            self.loop = try Loop.init(allocator, &self.pcm, .{
                .channel_count = n.channel_count,
                .period_frames = n.period_frames,
                .timeout_ms = self.timeout_ms,
            });
        }

        /// Runs on the calling thread until stop() or an unrecoverable error.
        pub fn start(self: *Self, ctx: *Ctx, callback: Callback) (DeviceError || LoopError)!void {
            const loop = &(self.loop orelse return error.not_prepared);
            return loop.start(ctx, callback);
        }

        pub fn stop(self: *Self) void {
            if (self.loop) |*loop| loop.stop();
        }

        pub fn stats(self: *const Self) Stats {
            return if (self.loop) |loop| loop.stats else .{};
        }

        /// After stop. Drops pending frames; a drain policy is M4c.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.loop) |*loop| loop.deinit(allocator);
            _ = c.snd_pcm_drop(self.handle);
            _ = c.snd_pcm_close(self.handle);
            self.* = undefined;
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "errno mapping: EPIPE is xrun, ESTRPIPE is suspended, anything else is io" {
    try testing.expectEqual(error.xrun, AlsaPcm.errnoToPcm(-c.EPIPE));
    try testing.expectEqual(error.suspended, AlsaPcm.errnoToPcm(-c.ESTRPIPE));
    try testing.expectEqual(error.io, AlsaPcm.errnoToPcm(-c.EBADFD));
    try testing.expectEqual(error.io, AlsaPcm.errnoToPcm(-c.EINVAL));
}

test "region arithmetic: stereo s16, offset 3, 5 frames" {
    var ring: [64]u8 = undefined;
    const area = c.snd_pcm_channel_area_t{ .addr = &ring, .first = 0, .step = 32 }; // 2 ch * 16 bits

    const region = regionFromArea(&area, 3, 5, 4).?;
    try testing.expectEqual(5, region.frame_count);
    try testing.expectEqual(20, region.bytes.len);
    try testing.expectEqual(@intFromPtr(&ring[12]), @intFromPtr(region.bytes.ptr)); // 3 frames * 4 bytes

    // `first` is in bits; 16 bits = 2 bytes of leading padding
    const padded = c.snd_pcm_channel_area_t{ .addr = &ring, .first = 16, .step = 32 };
    try testing.expectEqual(@intFromPtr(&ring[14]), @intFromPtr(regionFromArea(&padded, 3, 5, 4).?.bytes.ptr));

    // stride disagreeing with the negotiated frame size is refused, not guessed
    try testing.expectEqual(null, regionFromArea(&area, 0, 1, 8));
}

const Tone = struct {
    frames: usize = 0,
    calls: usize = 0,

    fn render(self: *Tone, out: AudioBlock(f32)) void {
        self.calls += 1;
        self.frames += out.frame_count;
        for (0..out.channel_count) |ch| @memset(out.channel(ch), 0.25);
    }
};

const Device = PlaybackDevice(Tone, .s16_le);

fn openNull() !Device {
    return Device.init(.{ .ident = "null", .sample_rate = 48000, .channel_count = 2, .period_frames = 512 }) catch |err| switch (err) {
        error.open => return error.SkipZigTest,
        else => return err,
    };
}

test "null device: open, negotiate, prepare, render periods, stats, close" {
    var device = try openNull();
    defer device.deinit(testing.allocator);

    try testing.expectEqual(48000, device.negotiated.sample_rate);
    try testing.expectEqual(512, device.negotiated.period_frames);
    try testing.expectEqual(1024, device.negotiated.buffer_frames);

    try device.prepare(testing.allocator);

    var tone = Tone{};
    const loop = &device.loop.?;
    for (0..8) |_| try loop.runPeriod(&tone, Tone.render);

    const s = device.stats();
    try testing.expect(s.blocks >= 7); // the first period may only start the stream
    try testing.expectEqual(s.blocks * 512, tone.frames);
    try testing.expectEqual(0, s.discontinuities);
    try testing.expectEqual(0, s.zero_transfers);
}

test "null device: start before prepare is refused" {
    var device = try openNull();
    defer device.deinit(testing.allocator);
    var tone = Tone{};
    try testing.expectError(error.not_prepared, device.start(&tone, Tone.render));
}

test "null device: stop() from another thread returns start()" {
    var device = try openNull();
    defer device.deinit(testing.allocator);
    try device.prepare(testing.allocator);

    const Stopper = struct {
        fn run(d: *Device) void {
            while (!d.loop.?.running.load(.acquire)) std.atomic.spinLoopHint();
            d.stop();
        }
    };

    var tone = Tone{};
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{&device});
    try device.start(&tone, Tone.render);
    thread.join();

    try testing.expect(device.stats().periods >= 1);
}

test "null device: a bad configuration fails at init with the handle closed" {
    // 0 channels is refused by every PCM; the errdefer closes the handle, testing.allocator sees no leak
    try testing.expectError(error.channels_unsupported, Device.init(.{ .ident = "null", .sample_rate = 48000, .channel_count = 0, .period_frames = 512 }));
}
