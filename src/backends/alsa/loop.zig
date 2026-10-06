const std = @import("std");
const buffer = @import("../../core/buffer/buffer.zig");
const convert = @import("convert.zig");

pub const PcmError = @import("pcm.zig").PcmError;
pub const Region = @import("pcm.zig").Region;

const AudioBlock = buffer.AudioBlock;
const OwnedAudioBuffer = buffer.OwnedAudioBuffer;

const SampleFormat = convert.SampleFormat;
const SampleConverter = convert.SampleConverter;

pub const LoopError = error{
    no_progress,
    failed_recovery,
} || PcmError;


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
    timeout_ms: u32 = 100, // finite: stop() must be observable
    max_zero_transfers: usize = 5,
};

pub const PcmState = enum { prepared, running, xrun, suspended };

pub fn PlaybackLoop(comptime Ctx: type, comptime Pcm: type, comptime fmt: SampleFormat) type {
    return struct {
        const Self = @This();

        pub const Callback = *const fn (ctx: *Ctx, out: AudioBlock(f32)) void;
        const Converter = SampleConverter(fmt);

        pcm: *Pcm,
        staging: OwnedAudioBuffer(f32),
        opts: LoopOptions,
        running: std.atomic.Value(bool) = .init(false),
        started: bool = false,
        stats: Stats = .{},

        /// Prepare: Only allocations and inits
        pub fn init(allocator: std.mem.Allocator, pcm: *Pcm, opts: LoopOptions) !Self {
            const staging_buffer = try OwnedAudioBuffer(f32).init(allocator, opts.period_frames, opts.channel_count);

            return .{
                .pcm = pcm,
                .staging = staging_buffer,
                .opts = opts,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // can only be called after stop() has been called and the loop has exited
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

            var remaining: usize = self.opts.period_frames;
            var zero_progress: usize = 0;

            while (remaining > 0) {
                const region: Region = self.pcm.mmapBegin(remaining) catch |err| {
                    self.stats.discontinuities += 1;
                    return self.recover(err);
                };

                if (region.frame_count == 0) {
                    zero_progress += 1;
                    self.stats.zero_transfers += 1;

                    if (zero_progress >= self.opts.max_zero_transfers) return LoopError.no_progress;

                    _ = self.pcm.mmapCommit(0) catch |err| return self.recover(err);
                    continue;
                }

                zero_progress = 0;

                // region.frame_count <= remaining <= period_frames == staging.max_frames; proved at prepare.
                const block = self.staging.borrowBlock(region.frame_count) catch unreachable;

                callback(ctx, block);
                self.stats.blocks += 1;

                const byte_len = Converter.byteLength(self.opts.channel_count, region.frame_count);

                Converter.writeInterleaved(region.bytes[0..byte_len], block.asConst()) catch unreachable;

                const committed_count = self.pcm.mmapCommit(region.frame_count) catch |err| {
                    self.stats.discontinuities += 1;
                    return self.recover(err);
                };

                if (committed_count != region.frame_count) {
                    self.stats.short_commits += 1;
                    self.stats.discontinuities += 1;
                    return self.recover(PcmError.xrun);
                }

                remaining -= committed_count;
            }
        }

        const Readiness = enum { ready, skip_period };

        /// Readiness: the loop may wait here; the callback may not (plan 8.1).
        /// A stream that was just started, or that timed out waiting, has nothing to transfer: skip the period.
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

        fn recover(self: *Self, err: PcmError) LoopError!void {
            switch (err) {
                error.xrun, error.suspended => {
                    self.stats.xruns += 1;
                    self.pcm.recover(err) catch return error.failed_recovery;
                    // snd_pcm_prepare leaves the stream stopped; the next period starts it again
                    self.started = false;
                },

                error.timeout => {}, // stop() may have been called; the while in start() decides
                error.io => return error.io,
            }
        }
    };
}

// Forces analysis of the generic bodies above. Replaced by the scripted-PCM tests in M4b.
test "PlaybackLoop and SampleConverter instantiate" {
    const StubPcm = struct {
        const Self = @This();

        pub fn availUpdate(_: *Self) PcmError!usize {
            return 0;
        }
        pub fn start(_: *Self) PcmError!void {}
        pub fn wait(_: *Self, _: u32) PcmError!void {}
        pub fn mmapBegin(_: *Self, _: usize) PcmError!Region {
            return error.io;
        }
        pub fn mmapCommit(_: *Self, n: usize) PcmError!usize {
            return n;
        }
        pub fn recover(_: *Self, _: PcmError) PcmError!void {}
    };
    const Ctx = struct {
        const Self = @This();

        fn cb(_: *Self, _: AudioBlock(f32)) void {}
    };
    const Loop = PlaybackLoop(Ctx, StubPcm, .s16_le);
    std.testing.refAllDecls(Loop);
    std.testing.refAllDecls(SampleConverter(.s16_le));
    std.testing.refAllDecls(SampleConverter(.f32_le));

    var pcm = StubPcm{};
    var loop = try Loop.init(std.testing.allocator, &pcm, .{ .channel_count = 2, .period_frames = 64 });
    defer loop.deinit(std.testing.allocator);
    var ctx = Ctx{};
    // first period: avail 0 and not started -> start() and return without rendering
    try loop.runPeriod(&ctx, Ctx.cb);
    try std.testing.expectEqual(1, loop.stats.periods);
}

test "s16 encode/decode round trip" {
    const S16 = SampleConverter(.s16_le);
    var bytes: [2]u8 = undefined;
    S16.encode(&bytes, 0.5);
    try std.testing.expectApproxEqAbs(0.5, S16.decode(&bytes), 1.0 / 32767.0);
    S16.encode(&bytes, 1.5);
    try std.testing.expectEqual(std.math.maxInt(i16), std.mem.readInt(i16, &bytes, .little));
}
