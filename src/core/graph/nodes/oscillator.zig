const std = @import("std");
const buffer = @import("buffer");
const node = @import("../node.zig");

pub const Waveform = enum {
    sine,
    square,
    triangle,
    sawtooth,
};

/// Naive waveforms. Square, sawtooth and triangle are not band-limited and alias above a few
/// hundred Hz; they are here for tests and rough listening, not as a final oscillator design.
pub fn Oscillator(comptime T: type) type {
    buffer.requireFloat(T, "Oscillator");

    return struct {
        freq: T,
        amp: T,
        waveform: Waveform,
        phase: T = 0.0,
        sample_rate: T = 0.0,
        inc: T = 0.0,

        const Self = @This();
        const Node = node.Node(T);
        const two_pi: T = 2 * std.math.pi;

        pub const ports: node.Ports = .{ .inputs = 0, .outputs = 1 };
        pub const name: []const u8 = "Oscillator";

        /// `prepare` sets the sample rate; until then the oscillator cannot run.
        pub fn init(waveform: Waveform, freq: T, amp: T) Self {
            return .{ .freq = freq, .amp = amp, .waveform = waveform };
        }

        pub fn prepare(self: *Self, ctx: Node.PrepareContext) node.NodeError!void {
            self.sample_rate = ctx.sample_rate;
            self.inc = two_pi * self.freq / self.sample_rate;
        }

        /// Renders channel 0 contiguously, then duplicates it. Phase advances once per frame,
        /// so every channel carries the same signal and phase is continuous across calls.
        pub fn process(self: *Self, ctx: Node.ProcessContext) void {
            const output = ctx.outputs[0];
            const first = output.channel(0);

            for (first) |*out| {
                out.* = self.sample();
                self.advancePhase();
            }

            for (1..output.channel_count) |ch| @memcpy(output.channel(ch), first);
        }

        fn sample(self: Self) T {
            const t = self.phase / two_pi;

            const shape: T = switch (self.waveform) {
                .sine => @sin(self.phase),
                .square => if (t < 0.5) 1.0 else -1.0,
                .sawtooth => 2.0 * t - 1.0,
                .triangle => 1.0 - 4.0 * @abs(t - 0.5),
            };

            return shape * self.amp;
        }

        fn advancePhase(self: *Self) void {
            self.phase += self.inc;
            if (self.phase >= two_pi) self.phase -= two_pi;
        }
    };
}

const testing = std.testing;

fn expectAll(comptime T: type, expected: T, actual: []const T) !void {
    for (actual) |sample| try testing.expectEqual(expected, sample);
}

const test_prepare_ctx: node.Node(f32).PrepareContext = .{
    .sample_rate = 48000,
    .max_frames = .blk_16,
    .channel_count = 2,
};

fn referenceSine(freq: f64, sample_rate: f64, n: usize) f32 {
    return @floatCast(@sin(2 * std.math.pi * freq * @as(f64, @floatFromInt(n)) / sample_rate));
}

test "Oscillator - sine matches an f64 reference, all channels, only active frames" {
    var pool = try buffer.AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 1, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    const full = try pool.borrowSlot(0, 16);
    for (0..2) |ch| @memset(full.channel(ch), 9);

    var osc = Oscillator(f32).init(.sine, 440, 1);
    const osc_node = node.Node(f32).init(&osc);

    try testing.expectEqual(node.Ports{ .inputs = 0, .outputs = 1 }, osc_node.ports);
    try testing.expectEqualStrings("Oscillator", osc_node.name);

    try osc_node.prepare(test_prepare_ctx);

    const out = try pool.borrowSlot(0, 12);
    osc_node.process(.{ .inputs = &.{}, .outputs = &.{out}, .frame_count = 12 });

    for (out.channel(0), 0..) |sample, n| {
        try testing.expectApproxEqAbs(referenceSine(440, 48000, n), sample, 1e-5);
    }
    try testing.expectEqualSlices(f32, out.channel(0), out.channel(1));

    for (0..2) |ch| try expectAll(f32, 9, full.channel(ch)[12..]);
}

test "Oscillator - phase continues across calls: 8 + 8 frames equal 16" {
    var owned_split = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 1, .max_frames = 16 });
    defer owned_split.deinit(testing.allocator);
    var owned_whole = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 1, .max_frames = 16 });
    defer owned_whole.deinit(testing.allocator);

    var split = Oscillator(f32).init(.sine, 1000, 0.5);
    var whole = Oscillator(f32).init(.sine, 1000, 0.5);
    const split_node = node.Node(f32).init(&split);
    const whole_node = node.Node(f32).init(&whole);
    try split_node.prepare(test_prepare_ctx);
    try whole_node.prepare(test_prepare_ctx);

    const both = try owned_split.borrowBlock(16);
    split_node.process(.{ .inputs = &.{}, .outputs = &.{try both.subBlock(0, 8)}, .frame_count = 8 });
    split_node.process(.{ .inputs = &.{}, .outputs = &.{try both.subBlock(8, 8)}, .frame_count = 8 });

    const all = try owned_whole.borrowBlock(16);
    whole_node.process(.{ .inputs = &.{}, .outputs = &.{all}, .frame_count = 16 });

    try testing.expectEqualSlices(f32, all.channel(0), both.channel(0));
}

test "Oscillator - prepare is repeatable and rescales the increment" {
    var osc = Oscillator(f32).init(.sine, 440, 1);
    const osc_node = node.Node(f32).init(&osc);

    try osc_node.prepare(test_prepare_ctx);
    const inc_48k = osc.inc;

    try osc_node.prepare(.{ .sample_rate = 96000, .max_frames = .blk_16, .channel_count = 2 });
    try testing.expectApproxEqAbs(inc_48k / 2, osc.inc, 1e-7);
}

test "Oscillator - square, sawtooth and triangle over one period" {
    // 4 frames per period at sample_rate / 4, so phase visits 0, 1/4, 1/2, 3/4 exactly
    var storage = [_]f64{0} ** 4;
    const out = try buffer.AudioBlock(f64).init(&storage, .{ .channel_count = 1, .frame_count = 4, .channel_stride = 4 });
    const prepare_ctx: node.Node(f64).PrepareContext = .{ .sample_rate = 48000, .max_frames = .blk_4, .channel_count = 1 };

    const cases = [_]struct { waveform: Waveform, expected: [4]f64 }{
        .{ .waveform = .square, .expected = .{ 1, 1, -1, -1 } },
        .{ .waveform = .sawtooth, .expected = .{ -1, -0.5, 0, 0.5 } },
        .{ .waveform = .triangle, .expected = .{ -1, 0, 1, 0 } },
    };

    for (cases) |case| {
        var osc = Oscillator(f64).init(case.waveform, 12000, 1);
        const osc_node = node.Node(f64).init(&osc);
        try osc_node.prepare(prepare_ctx);
        osc_node.process(.{ .inputs = &.{}, .outputs = &.{out}, .frame_count = 4 });

        for (case.expected, storage) |expected, actual| {
            try testing.expectApproxEqAbs(expected, actual, 1e-12);
        }
    }
}
