//! Design sketch for docs/backend-contract.md sections 2, 4, 5 and 7: the playback loop over a
//! scripted PCM, the boundary conversion, and the callback-on-blocks signature.
//! Not part of the build.
//!
//!     zig test docs/examples/device_loop_sketch.zig
//!
//! A file under docs/ cannot import src/, so the first ~90 lines are stand-ins for things that
//! already exist. In src/ they are replaced by:
//!
//!     buffer = @import("../core/buffer/buffer.zig")    AudioBlock, ConstAudioBlock, OwnedAudioBuffer
//!
//! The parts worth implementing as written are marked "port as is" and land in:
//!
//!     src/backends/convert.zig          SampleFormat, SampleConverter(fmt)   backend-neutral
//!     src/backends/alsa/pcm.zig         PcmError, Region, AlsaPcm
//!     src/backends/alsa/driver.zig      PlaybackLoop and the device types around it
//!
//! `ScriptedPcm` is a test double and stays in test code; `AlsaPcm` (not sketched) wraps
//! snd_pcm_* with the same functions and no policy. The loop is half-duplex playback only; M4c
//! adds capture and the common-frame-count rule on the same shape.
//!
//! The scripted PCM reports a full period available while prepared, like a real playback
//! buffer, so the first period renders straight away and `start` is only called once the
//! buffer has filled.

const std = @import("std");

// ===========================================================================
// Stand-ins for src/core/buffer. Same names and field layout; minimal checks.
// ===========================================================================

pub fn ConstAudioBlock(comptime T: type) type {
    return struct {
        samples: []const T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn channel(self: @This(), c: usize) []const T {
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
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

        pub fn channel(self: Self, c: usize) []T {
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
        }

        pub fn subBlock(self: Self, start_frame: usize, frame_count: usize) error{out_of_range}!Self {
            if (start_frame + frame_count > self.frame_count) return error.out_of_range;
            return .{ .samples = self.samples[start_frame..], .channel_count = self.channel_count, .frame_count = frame_count, .channel_stride = self.channel_stride };
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
            // the real one rounds the stride up to a 64-byte multiple; the sketch adds 16 frames of
            // padding so tests can plant a sentinel past frame_count
            const stride = max_frames + 16;
            const storage = try allocator.alloc(T, channel_count * stride);
            @memset(storage, 0);
            return .{ .storage = storage, .channel_count = channel_count, .max_frames = max_frames, .channel_stride = stride };
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

// ===========================================================================
// convert.zig (port as is). Contract section 5.
//
// Two axes: the function name carries the layout of the byte side (interleaved, later planar),
// the type parameter carries the sample encoding. Blocks are always planar f32, so the
// converter is specialized on the format only. The loop instantiates it once:
//
//     const Convert = SampleConverter(fmt);
//     Convert.writeInterleaved(region.bytes, block.asConst())
//
// Same comptime-specialization idiom as GenericAudioData(format) and HalfDuplexDevice(Ctx, opts).
// ===========================================================================

/// Backend-neutral tag: how one sample is encoded. ALSA's FormatType maps onto it at prepare;
/// CoreAudio's AudioStreamBasicDescription would too. No kernels live here.
pub const SampleFormat = enum {
    s16_le,
    f32_le,
};

pub const ConvertError = error{size_mismatch};

pub fn SampleConverter(comptime fmt: SampleFormat) type {
    return struct {
        pub const format = fmt;

        pub const bytes_per_sample: usize = switch (fmt) {
            .s16_le => 2,
            .f32_le => 4,
        };

        /// Device bytes for `frame_count` frames of `channel_count` channels, either layout.
        pub fn byteLength(channel_count: usize, frame_count: usize) usize {
            return frame_count * channel_count * bytes_per_sample;
        }

        /// One sample, no layout knowledge. Clamp first: @intFromFloat on 1.0001 * 32767 is checked UB.
        pub inline fn encode(dst: *[bytes_per_sample]u8, sample: f32) void {
            switch (fmt) {
                .s16_le => {
                    const clamped = std.math.clamp(sample, -1.0, 1.0);
                    const scaled: i16 = @intFromFloat(@round(clamped * std.math.maxInt(i16)));
                    std.mem.writeInt(i16, dst, scaled, .little);
                },
                .f32_le => std.mem.writeInt(u32, dst, @bitCast(sample), .little),
            }
        }

        pub inline fn decode(src: *const [bytes_per_sample]u8) f32 {
            return switch (fmt) {
                .s16_le => @as(f32, @floatFromInt(std.mem.readInt(i16, src, .little))) / std.math.maxInt(i16),
                .f32_le => @bitCast(std.mem.readInt(u32, src, .little)),
            };
        }

        /// planar f32 block -> interleaved device bytes. Writes nothing on size_mismatch.
        pub fn writeInterleaved(dst: []u8, src: ConstAudioBlock(f32)) ConvertError!void {
            if (dst.len != byteLength(src.channel_count, src.frame_count)) return error.size_mismatch;

            // channel-outer keeps the planar read contiguous; the interleaved write strides by a frame
            const frame_bytes = src.channel_count * bytes_per_sample;
            for (0..src.channel_count) |c| {
                var at = c * bytes_per_sample;
                for (src.channel(c)) |sample| {
                    encode(dst[at..][0..bytes_per_sample], sample);
                    at += frame_bytes;
                }
            }
        }

        /// interleaved device bytes -> planar f32 block. Writes nothing on size_mismatch.
        pub fn readInterleaved(dst: AudioBlock(f32), src: []const u8) ConvertError!void {
            if (src.len != byteLength(dst.channel_count, dst.frame_count)) return error.size_mismatch;

            const frame_bytes = dst.channel_count * bytes_per_sample;
            for (0..dst.channel_count) |c| {
                var at = c * bytes_per_sample;
                for (dst.channel(c)) |*sample| {
                    sample.* = decode(src[at..][0..bytes_per_sample]);
                    at += frame_bytes;
                }
            }
        }

        // readPlanar / writePlanar for non-interleaved devices (contract 3, rows 1 and 2):
        // per-channel decode with no reordering. Not before a device that offers it is at hand.
    };
}

// ===========================================================================
// pcm.zig: the seam (port the shape as is). Contract section 7.
//
// `Region.frame_count <= want`, may be 0. Negative ALSA results become errors here; nothing
// downstream sees a signed count.
// ===========================================================================

pub const PcmError = error{ xrun, suspended, io, timeout };

pub const Region = struct {
    bytes: []u8,
    frame_count: usize,
};

pub const PcmState = enum { prepared, running, xrun, suspended };

// ===========================================================================
// driver.zig: the playback loop (port as is, with AlsaPcm for Pcm). Contract sections 2, 4, 6.
// ===========================================================================

pub const LoopError = error{ no_progress, recovery_failed } || PcmError;

pub const Stats = struct {
    periods: u64 = 0,
    blocks: u64 = 0, // callback calls; one per period unless begin shortens
    xruns: u64 = 0,
    discontinuities: u64 = 0,
    short_commits: u64 = 0,
    zero_transfers: u64 = 0,
};

pub const LoopOptions = struct {
    channel_count: usize,
    period_frames: usize,
    timeout_ms: u32 = 100, // finite: stop() must be observable (section 3)
    max_zero_transfers: usize = 5,
};

pub fn PlaybackLoop(comptime Ctx: type, comptime Pcm: type, comptime fmt: SampleFormat) type {
    return struct {
        const Self = @This();

        pub const Callback = *const fn (ctx: *Ctx, out: AudioBlock(f32)) void;

        const Convert = SampleConverter(fmt);

        pcm: *Pcm,
        staging: OwnedAudioBuffer(f32),
        opts: LoopOptions,
        running: std.atomic.Value(bool) = .init(false),
        started: bool = false,
        stats: Stats = .{},

        /// prepare: the only allocation this type performs
        pub fn init(allocator: std.mem.Allocator, pcm: *Pcm, opts: LoopOptions) !Self {
            return .{
                .pcm = pcm,
                .staging = try OwnedAudioBuffer(f32).init(allocator, opts.channel_count, opts.period_frames),
                .opts = opts,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(!self.running.load(.acquire));
            self.staging.deinit(allocator);
        }

        /// Runs on the caller's thread until stop() or an unrecoverable error.
        pub fn start(self: *Self, ctx: *Ctx, callback: Callback) LoopError!void {
            self.running.store(true, .release);
            defer self.running.store(false, .release);

            while (self.running.load(.acquire)) {
                try self.runPeriod(ctx, callback);
            }
        }

        /// Callable from any thread. The loop notices within one period plus one wait timeout.
        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
        }

        /// One period. Public so tests can drive it step by step.
        pub fn runPeriod(self: *Self, ctx: *Ctx, callback: Callback) LoopError!void {
            self.stats.periods += 1;

            // readiness: the loop may wait here; the callback may not (plan 8.1)
            const avail = self.pcm.availUpdate() catch |err| return self.recover(err);

            if (avail < self.opts.period_frames) {
                if (!self.started) {
                    try self.pcm.start();
                    self.started = true;
                    return;
                }
                self.pcm.wait(self.opts.timeout_ms) catch |err| return self.recover(err);
            }

            var remaining = self.opts.period_frames;
            var zero_progress: usize = 0;

            while (remaining > 0) {
                // a failed begin leaves no region: recover, abandon the period, callback not called
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

                // region.frame_count <= remaining <= period_frames == staging.max_frames: proven at prepare
                const block = self.staging.borrowBlock(region.frame_count) catch unreachable;

                callback(ctx, block);
                self.stats.blocks += 1;

                const byte_len = Convert.byteLength(self.opts.channel_count, region.frame_count);
                Convert.writeInterleaved(region.bytes[0..byte_len], block.asConst()) catch unreachable;

                const committed = self.pcm.mmapCommit(region.frame_count) catch |err| {
                    self.stats.discontinuities += 1;
                    return self.recover(err);
                };

                // short commit is a discontinuity, not a rollback: the lost frames are not re-rendered
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
                    self.pcm.recover(err) catch return error.recovery_failed;
                    // snd_pcm_prepare leaves the stream stopped; the next period starts it again
                    self.started = false;
                },
                error.timeout => {}, // stop() may have been called; the while in start() decides
                error.io => return error.io,
            }
        }
    };
}

// ===========================================================================
// Test double: ScriptedPcm. Stays in test code.
//
// Device memory is a ring of two periods. Every committed byte is appended to `wire`, which is
// what "the hardware played". Outcomes for begin/commit come from a script; when the script is
// exhausted, begin honours the request and commit commits everything.
// ===========================================================================

const ScriptedPcm = struct {
    const Self = @This();

    pub const Step = union(enum) {
        begin_frames: usize, // begin returns min(want, n)
        begin_fail: PcmError,
        commit_frames: usize, // commit returns min(requested, n)
        commit_fail: PcmError,
        avail_fail: PcmError,
    };

    allocator: std.mem.Allocator,
    ring: []u8,
    frame_bytes: usize,
    period_frames: usize,
    head: usize = 0, // byte offset of the next begin
    wire: std.ArrayList(u8) = .empty,
    script: []const Step,
    next_step: usize = 0,
    state: PcmState = .prepared,
    recoveries: u32 = 0,
    sentinel: u8 = 0xAA,

    fn init(allocator: std.mem.Allocator, channel_count: usize, bps: usize, period_frames: usize, script: []const Step) !Self {
        const frame_bytes = channel_count * bps;
        const ring = try allocator.alloc(u8, frame_bytes * period_frames * 2);
        @memset(ring, 0xAA);
        return .{ .allocator = allocator, .ring = ring, .frame_bytes = frame_bytes, .period_frames = period_frames, .script = script };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.ring);
        self.wire.deinit(self.allocator);
    }

    fn take(self: *Self, comptime tag: std.meta.Tag(Step)) ?@FieldType(Step, @tagName(tag)) {
        if (self.next_step >= self.script.len) return null;
        const step = self.script[self.next_step];
        if (step != tag) return null;
        self.next_step += 1;
        return @field(step, @tagName(tag));
    }

    pub fn availUpdate(self: *Self) PcmError!usize {
        if (self.take(.avail_fail)) |err| {
            self.state = .xrun;
            return err;
        }
        return self.period_frames;
    }

    pub fn start(self: *Self) PcmError!void {
        self.state = .running;
    }

    pub fn wait(_: *Self, _: u32) PcmError!void {}

    pub fn mmapBegin(self: *Self, want: usize) PcmError!Region {
        if (self.take(.begin_fail)) |err| {
            self.state = .xrun;
            return err;
        }
        const frames = if (self.take(.begin_frames)) |n| @min(want, n) else want;
        // never hand out a region that wraps; a real ring does the same by shortening
        const until_wrap = (self.ring.len - self.head) / self.frame_bytes;
        const granted = @min(frames, until_wrap);
        return .{ .bytes = self.ring[self.head..][0 .. granted * self.frame_bytes], .frame_count = granted };
    }

    pub fn mmapCommit(self: *Self, frame_count: usize) PcmError!usize {
        if (self.take(.commit_fail)) |err| {
            self.state = .xrun;
            return err;
        }
        const committed = if (self.take(.commit_frames)) |n| @min(frame_count, n) else frame_count;
        const bytes = committed * self.frame_bytes;
        self.wire.appendSlice(self.allocator, self.ring[self.head..][0..bytes]) catch return error.io;
        self.head = (self.head + bytes) % self.ring.len;
        return committed;
    }

    pub fn recover(self: *Self, _: PcmError) PcmError!void {
        self.recoveries += 1;
        self.state = .prepared;
    }

    pub fn getState(self: Self) PcmState {
        return self.state;
    }
};

// ===========================================================================
// Tests. A sine "node" with phase in the context plays the role of the ExecutionPlan: splitting a period
// must be invisible because state lives in the node, not in the block.
// ===========================================================================

const testing = std.testing;

const Sine = struct {
    phase: f32 = 0,
    increment: f32,
    calls: u32 = 0,
    frames_seen: std.ArrayList(usize) = .empty,
    allocator: std.mem.Allocator,
    amplitude: f32 = 0.5,

    fn deinit(self: *Sine) void {
        self.frames_seen.deinit(self.allocator);
    }

    fn render(ctx: *Sine, out: AudioBlock(f32)) void {
        ctx.calls += 1;
        ctx.frames_seen.append(ctx.allocator, out.frame_count) catch unreachable; // test bookkeeping only

        for (0..out.frame_count) |n| {
            const s = ctx.amplitude * @sin(ctx.phase);
            ctx.phase += ctx.increment;
            if (ctx.phase > std.math.tau) ctx.phase -= std.math.tau;
            for (0..out.channel_count) |c| out.channel(c)[n] = s;
        }
    }
};

const channels = 2;
const period = 512;
const S16 = SampleConverter(.s16_le);
const Loop = PlaybackLoop(Sine, ScriptedPcm, .s16_le);

fn offlineReferenceAlloc(allocator: std.mem.Allocator, frame_count: usize) ![]u8 {
    var sine = Sine{ .increment = std.math.tau * 440.0 / 48000.0, .allocator = allocator };
    defer sine.deinit();

    var buf = try OwnedAudioBuffer(f32).init(allocator, channels, frame_count);
    defer buf.deinit(allocator);

    const block = try buf.borrowBlock(frame_count);
    Sine.render(&sine, block);

    const bytes = try allocator.alloc(u8, S16.byteLength(channels, frame_count));
    try S16.writeInterleaved(bytes, block.asConst());
    return bytes;
}

test "prediction: blocks of 512, 300 and 212 frames equal one offline render of 1024" {
    const allocator = testing.allocator;
    const script = [_]ScriptedPcm.Step{ .{ .begin_frames = 512 }, .{ .begin_frames = 300 }, .{ .begin_frames = 212 } };

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &script);
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period });
    defer loop.deinit(allocator);

    var sine = Sine{ .increment = std.math.tau * 440.0 / 48000.0, .allocator = allocator };
    defer sine.deinit();

    // a prepared playback buffer is all free space, so the first period renders straight away
    try loop.runPeriod(&sine, Sine.render); // 512
    try loop.runPeriod(&sine, Sine.render); // 300 + 212

    try testing.expectEqualSlices(usize, &.{ 512, 300, 212 }, sine.frames_seen.items);

    const reference = try offlineReferenceAlloc(allocator, 1024);
    defer allocator.free(reference);

    try testing.expectEqualSlices(u8, reference, pcm.wire.items);
    try testing.expectEqual(0, loop.stats.discontinuities);
}

test "failed begin: callback not called, region untouched, recovery counted, next period proceeds" {
    const allocator = testing.allocator;
    const script = [_]ScriptedPcm.Step{.{ .begin_fail = error.xrun }};

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &script);
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period });
    defer loop.deinit(allocator);

    var sine = Sine{ .increment = 0.1, .allocator = allocator };
    defer sine.deinit();

    try loop.runPeriod(&sine, Sine.render); // begin fails

    try testing.expectEqual(0, sine.calls);
    try testing.expectEqual(1, pcm.recoveries);
    try testing.expectEqual(1, loop.stats.discontinuities);
    try testing.expectEqual(0, pcm.wire.items.len);
    for (pcm.ring) |b| try testing.expectEqual(0xAA, b); // nothing dereferenced a failed begin

    // recovery left the stream prepared; the next period renders as normal
    try loop.runPeriod(&sine, Sine.render);
    try testing.expectEqual(1, sine.calls);
    try testing.expectEqual(period * channels * 2, pcm.wire.items.len);
}

test "short commit: discontinuity, lost frames are not re-rendered" {
    const allocator = testing.allocator;
    const script = [_]ScriptedPcm.Step{.{ .commit_frames = 100 }};

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &script);
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period });
    defer loop.deinit(allocator);

    var sine = Sine{ .increment = 0.1, .allocator = allocator };
    defer sine.deinit();

    try loop.runPeriod(&sine, Sine.render); // renders 512, device takes 100

    try testing.expectEqual(1, sine.calls); // not called again for the 412 lost frames
    try testing.expectEqual(1, loop.stats.short_commits);
    try testing.expectEqual(1, loop.stats.discontinuities);
    try testing.expectEqual(1, pcm.recoveries);
    try testing.expectEqual(100 * channels * 2, pcm.wire.items.len);
}

test "zero progress is bounded" {
    const allocator = testing.allocator;
    const script = [_]ScriptedPcm.Step{ .{ .begin_frames = 0 }, .{ .begin_frames = 0 }, .{ .begin_frames = 0 } };

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &script);
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period, .max_zero_transfers = 3 });
    defer loop.deinit(allocator);

    var sine = Sine{ .increment = 0.1, .allocator = allocator };
    defer sine.deinit();

    try testing.expectError(error.no_progress, loop.runPeriod(&sine, Sine.render));
    try testing.expectEqual(3, loop.stats.zero_transfers);
    try testing.expectEqual(0, sine.calls);
}

test "stop() from another thread returns start()" {
    const allocator = testing.allocator;

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &.{});
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period });
    defer loop.deinit(allocator);

    var sine = Sine{ .increment = 0.1, .allocator = allocator };
    defer sine.deinit();

    const Stopper = struct {
        fn run(l: *Loop) void {
            while (!l.running.load(.acquire)) std.atomic.spinLoopHint();
            l.stop();
        }
    };

    const thread = try std.Thread.spawn(.{}, Stopper.run, .{&loop});
    try loop.start(&sine, Sine.render);
    thread.join();

    try testing.expect(!loop.running.load(.acquire));
    try testing.expect(loop.stats.periods >= 1);
}

test "encode clamps instead of panicking" {
    var samples = [_]f32{ 1.5, -1.5, 0.0, 1.0 };
    const block = ConstAudioBlock(f32){ .samples = &samples, .channel_count = 1, .frame_count = 4, .channel_stride = 4 };

    var bytes: [8]u8 = undefined;
    try S16.writeInterleaved(&bytes, block);

    try testing.expectEqual(std.math.maxInt(i16), std.mem.readInt(i16, bytes[0..2], .little));
    try testing.expectEqual(-std.math.maxInt(i16), std.mem.readInt(i16, bytes[2..4], .little));
    try testing.expectEqual(0, std.mem.readInt(i16, bytes[4..6], .little));
    try testing.expectEqual(std.math.maxInt(i16), std.mem.readInt(i16, bytes[6..8], .little));
}

test "s16 round trip within 1/32767; wrong length rejected and nothing written" {
    var src_samples: [8]f32 = undefined;
    for (&src_samples, 0..) |*s, i| s.* = -0.9 + 0.25 * @as(f32, @floatFromInt(i));
    const src = ConstAudioBlock(f32){ .samples = &src_samples, .channel_count = 2, .frame_count = 4, .channel_stride = 4 };

    var bytes: [16]u8 = undefined;
    try S16.writeInterleaved(&bytes, src);

    var dst_samples = [_]f32{0} ** 8;
    const dst = AudioBlock(f32){ .samples = &dst_samples, .channel_count = 2, .frame_count = 4, .channel_stride = 4 };
    try S16.readInterleaved(dst, &bytes);

    for (src_samples, dst_samples) |a, b| try testing.expectApproxEqAbs(a, b, 1.0 / 32767.0);

    // interleaved order on the wire: frame 0 is (ch0[0], ch1[0])
    try testing.expectEqual(S16.decode(bytes[0..2]), dst.channel(0)[0]);
    try testing.expectEqual(S16.decode(bytes[2..4]), dst.channel(1)[0]);

    var short: [15]u8 = [_]u8{0x55} ** 15;
    try testing.expectError(error.size_mismatch, S16.writeInterleaved(&short, src));
    for (short) |b| try testing.expectEqual(0x55, b);

    var untouched = [_]f32{7} ** 8;
    const untouched_block = AudioBlock(f32){ .samples = &untouched, .channel_count = 2, .frame_count = 4, .channel_stride = 4 };
    try testing.expectError(error.size_mismatch, S16.readInterleaved(untouched_block, &short));
    for (untouched) |s| try testing.expectEqual(7, s);
}

test "staging padding keeps its sentinel after a short block" {
    const allocator = testing.allocator;
    const script = [_]ScriptedPcm.Step{.{ .begin_frames = 100 }};

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &script);
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period });
    defer loop.deinit(allocator);

    // sentinel in every frame past 100 and in the padding past period
    for (0..channels) |c| {
        @memset(loop.staging.storage[c * loop.staging.channel_stride ..][100..loop.staging.channel_stride], 99);
    }

    var sine = Sine{ .increment = 0.1, .allocator = allocator };
    defer sine.deinit();

    // one period as two blocks: 100 then 412. The second block overwrites frames 100..512 of
    // staging; the padding past 512 must survive both.
    try loop.runPeriod(&sine, Sine.render);

    try testing.expectEqualSlices(usize, &.{ 100, 412 }, sine.frames_seen.items);
    for (0..channels) |c| {
        const pad = loop.staging.storage[c * loop.staging.channel_stride ..][period..loop.staging.channel_stride];
        for (pad) |s| try testing.expectEqual(99, s);
    }
}

test "loop allocates nothing after init" {
    const allocator = testing.allocator;

    var pcm = try ScriptedPcm.init(allocator, channels, 2, period, &.{});
    defer pcm.deinit();

    var loop = try Loop.init(allocator, &pcm, .{ .channel_count = channels, .period_frames = period });
    defer loop.deinit(allocator);

    // the loop holds no allocator; if runPeriod needed one it would not compile.
    // The scripted pcm's wire and the Sine bookkeeping allocate, so this test only shows the
    // structural guarantee: the type has no allocator field.
    try testing.expect(!@hasField(Loop, "allocator"));

    var sine = Sine{ .increment = 0.1, .allocator = allocator };
    defer sine.deinit();
    for (0..10) |_| try loop.runPeriod(&sine, Sine.render);
    try testing.expectEqual(10, sine.calls);
}
