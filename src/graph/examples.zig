//! Offline use of the graph: build, compile, render blocks, interleave at the boundary.
//! No device is involved, so this is also the backend-independent path the tests use.
//! Contract: docs/graph-contract.md.

const std = @import("std");
const buffer = @import("../core/buffer/buffer.zig");
const specs = @import("../common/audio_specs.zig");
const nodes = @import("nodes/nodes.zig");

const GraphBuilder = @import("builder.zig").GraphBuilder;
const Compiler = @import("compiler.zig").Compiler;
const ExecutionPlan = @import("plan.zig").ExecutionPlan;

const log = std.log.scoped(.graph);

/// Renders `frame_count` frames in blocks of at most `plan.max_frames` and returns them as
/// packed interleaved samples, which is what a device or a file expects. The caller owns the
/// result. The last block is partial when `frame_count` is not a multiple of the block size.
pub fn renderInterleavedAlloc(comptime T: type, allocator: std.mem.Allocator, plan: *ExecutionPlan(T), frame_count: usize) ![]T {
    const max_frames = plan.max_frames.toUsize();
    const channel_count = plan.channel_count;

    const interleaved = try allocator.alloc(T, frame_count * channel_count);
    errdefer allocator.free(interleaved);

    // planar scratch for one block; the plan copies its output here
    var planar = try buffer.OwnedAudioBuffer(T).init(allocator, channel_count, max_frames);
    defer planar.deinit(allocator);

    var first_frame: usize = 0;

    while (first_frame < frame_count) {
        const frames = @min(max_frames, frame_count - first_frame);
        const block = try planar.borrowBlock(frames);

        try plan.render(block);

        // we are using just a plain buffer here b ut the idea is that will be a more efficient interleaver in the future, and we want to test the interface
        const dst = interleaved[first_frame * channel_count ..][0 .. frames * channel_count];
        try buffer.interleave(T, dst, block.asConst());

        first_frame += frames;
    }

    return interleaved;
}

/// `renderInterleavedAlloc` for a duration. The frame count is `seconds * plan.sample_rate`
/// rounded to the nearest frame; negative or non-finite durations are `invalid_duration`.
pub fn renderSecondsInterleavedAlloc(comptime T: type, allocator: std.mem.Allocator, plan: *ExecutionPlan(T), seconds: T) ![]T {
    if (!std.math.isFinite(seconds) or seconds < 0) return error.invalid_duration;

    const frame_count: usize = @intFromFloat(@round(seconds * plan.sample_rate));
    return renderInterleavedAlloc(T, allocator, plan, frame_count);
}

/// Oscillator(440 Hz) -> Gain(0.25) and Gain(0.5), both mixed into the output: one second of
/// stereo audio at 48 kHz, rendered offline.
pub fn offlineFanIn() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    renderFanIn(allocator) catch |err| {
        log.err("offline render failed: {t}", .{err});
    };
}

fn renderFanIn(allocator: std.mem.Allocator) !void {
    const sample_rate = specs.SampleRate.sr_48000;

    // 1. build: mutable, editing time only
    var builder = GraphBuilder(f32).init(allocator);
    defer builder.deinit();

    const osc = try builder.addNode(nodes.Oscillator(f32).init(.sine, 440, 1));
    const quiet = try builder.addNode(nodes.Gain(f32){ .gain = 0.25 });
    const loud = try builder.addNode(nodes.Gain(f32){ .gain = 0.5 });

    try builder.connect(osc, quiet);
    try builder.connect(osc, loud);
    try builder.connectOutput(quiet);
    try builder.connectOutput(loud);

    // 2. compile: validates, orders, assigns slots, prepares nodes, allocates the pool
    var plan = try Compiler(f32).compile(allocator, &builder, .{
        .sample_rate = sample_rate.toFloat(f32),
        .max_frames = .blk_256,
        .channel_count = 2,
    });
    defer plan.deinit(allocator); // before the builder: the plan borrows its nodes

    // 3. render: no allocation inside plan.render
    const samples = try renderSecondsInterleavedAlloc(f32, allocator, &plan, 1.0);
    defer allocator.free(samples);

    var peak: f32 = 0;
    for (samples) |sample| peak = @max(peak, @abs(sample));

    log.info("rendered {d} frames, {d} channels, {d} ops, {d} pool slots, peak {d:.4}", .{
        samples.len / plan.channel_count,
        plan.channel_count,
        plan.ops.len,
        plan.pool.slot_count,
        peak,
    });
}

const testing = std.testing;

test "renderInterleavedAlloc - blocks with a partial tail, interleaved stereo" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    const osc = try builder.addNode(nodes.Oscillator(f32).init(.sine, 440, 1));
    const gain = try builder.addNode(nodes.Gain(f32){ .gain = 0.5 });
    try builder.connect(osc, gain);
    try builder.connectOutput(gain);

    var plan = try Compiler(f32).compile(testing.allocator, &builder, .{
        .sample_rate = 48000,
        .max_frames = .blk_64,
        .channel_count = 2,
    });
    defer plan.deinit(testing.allocator);

    // 64 + 64 + 22
    const frame_count = 150;
    const samples = try renderInterleavedAlloc(f32, testing.allocator, &plan, frame_count);
    defer testing.allocator.free(samples);

    try testing.expectEqual(frame_count * 2, samples.len);

    for (0..frame_count) |n| {
        const phase = 2 * std.math.pi * 440.0 * @as(f64, @floatFromInt(n)) / 48000.0;
        const expected: f32 = @floatCast(0.5 * @sin(phase));

        try testing.expectApproxEqAbs(expected, samples[n * 2], 1e-4);
        try testing.expectEqual(samples[n * 2], samples[n * 2 + 1]);
    }
}

test "renderSecondsInterleavedAlloc - duration follows the plan's sample rate" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    const osc = try builder.addNode(nodes.Oscillator(f32).init(.sine, 440, 1));
    try builder.connectOutput(osc);

    var plan = try Compiler(f32).compile(testing.allocator, &builder, .{
        .sample_rate = 44100,
        .max_frames = .blk_64,
        .channel_count = 2,
    });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(44100, plan.sample_rate);

    // 0.1 s at 44.1 kHz is 4410 frames: 68 blocks of 64 and one of 58
    const samples = try renderSecondsInterleavedAlloc(f32, testing.allocator, &plan, 0.1);
    defer testing.allocator.free(samples);

    try testing.expectEqual(4410 * 2, samples.len);

    try testing.expectError(error.invalid_duration, renderSecondsInterleavedAlloc(f32, testing.allocator, &plan, -1));
    try testing.expectError(error.invalid_duration, renderSecondsInterleavedAlloc(f32, testing.allocator, &plan, std.math.inf(f32)));
}

test "renderInterleavedAlloc - zero frames gives an empty slice" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    const osc = try builder.addNode(nodes.Oscillator(f32).init(.sine, 440, 1));
    try builder.connectOutput(osc);

    var plan = try Compiler(f32).compile(testing.allocator, &builder, .{
        .sample_rate = 48000,
        .max_frames = .blk_64,
        .channel_count = 1,
    });
    defer plan.deinit(testing.allocator);

    const samples = try renderInterleavedAlloc(f32, testing.allocator, &plan, 0);
    defer testing.allocator.free(samples);

    try testing.expectEqual(0, samples.len);
}

test "offline example runs and releases everything" {
    try renderFanIn(testing.allocator);
}
