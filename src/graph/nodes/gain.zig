const std = @import("std");
const buffer = @import("../../core/buffer/buffer.zig");
const node = @import("node.zig");

pub fn Gain(comptime T: type) type {
    buffer.requireFloat(T, "Gain");

    return struct {
        gain: T,

        const Self = @This();
        const Node = node.Node(T);

        pub const ports: node.Ports = .{ .inputs = 1, .outputs = 1 };
        pub const name: []const u8 = "Gain";

        pub fn prepare(_: *Self, _: Node.PrepareContext) node.NodeError!void {}

        pub fn process(self: *Self, ctx: Node.ProcessContext) void {
            const input = ctx.inputs[0];
            const output = ctx.outputs[0];

            for (0..output.channel_count) |ch| {
                for (output.channel(ch), input.channel(ch)) |*out, in| {
                    out.* = in * self.gain;
                }
            }
        }
    };
}

const testing = std.testing;

fn expectAll(comptime T: type, expected: T, actual: []const T) !void {
    for (actual) |sample| try testing.expectEqual(expected, sample);
}

test "Gain - scales every channel of a partial block, leaves padding and input alone" {
    var pool = try buffer.AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    const full_out = try pool.borrowSlot(1, 16);

    for (0..2) |ch| @memset(full_out.channel(ch), 9);
    const in = try pool.borrowSlot(0, 5);
    const out = try pool.borrowSlot(1, 5);
    for (0..2) |ch| @memset(in.channel(ch), 1);

    var gain = Gain(f32){ .gain = 0.5 };
    const gain_node = node.Node(f32).init(&gain);

    try testing.expectEqual(node.Ports{ .inputs = 1, .outputs = 1 }, gain_node.ports);
    try testing.expectEqualStrings("Gain", gain_node.name);

    try gain_node.prepare(.{ .sample_rate = 48000, .max_frames = .blk_16, .channel_count = 2 });
    gain_node.process(.{ .inputs = &.{in.asConst()}, .outputs = &.{out}, .frame_count = 5 });

    for (0..2) |ch| {
        try expectAll(f32, 0.5, full_out.channel(ch)[0..5]);
        try expectAll(f32, 9, full_out.channel(ch)[5..]);
        try expectAll(f32, 1, in.channel(ch));
    }
}

test "Gain - per-sample values, f64" {
    var in_samples = [_]f64{ 1, -2, 3, 0 };
    var out_samples = [_]f64{0} ** 4;

    const in = try buffer.ConstAudioBlock(f64).init(&in_samples, .{ .channel_count = 2, .frame_count = 2, .channel_stride = 2 });
    const out = try buffer.AudioBlock(f64).init(&out_samples, .{ .channel_count = 2, .frame_count = 2, .channel_stride = 2 });

    var gain = Gain(f64){ .gain = 3 };
    node.Node(f64).init(&gain).process(.{ .inputs = &.{in}, .outputs = &.{out}, .frame_count = 2 });

    try testing.expectEqualSlices(f64, &.{ 3, -6, 9, 0 }, &out_samples);
}
