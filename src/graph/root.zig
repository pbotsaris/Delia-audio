pub const nodes = @import("nodes/root.zig");
pub const Node = @import("node.zig").Node;
pub const builder = @import("builder.zig");
pub const plan = @import("plan.zig");
pub const compiler = @import("compiler.zig");
pub const examples = @import("examples.zig");

test {
    _ = @import("nodes/root.zig");
    _ = @import("node.zig");
    _ = builder;
    _ = plan;
    _ = compiler;
    _ = examples;
}

// ---------------------------------------------------------------------------
// Smoke tests for builder.zig and plan.zig on their own. The acceptance tests
// (docs/graph-contract.md section 7) are in compiler.zig.
// ---------------------------------------------------------------------------

const std = @import("std");
const buffer = @import("buffer");
const testing = std.testing;

test "builder - add, connect, mark output, reject bad edges" {
    var g = builder.GraphBuilder(f32).init(testing.allocator);
    defer g.deinit();

    const osc = try g.addNode(nodes.Oscillator(f32).init(.sine, 440, 1));
    const gain = try g.addNode(nodes.Gain(f32){ .gain = 0.5 });

    try g.connect(osc, gain);
    try g.connectOutput(gain);

    try testing.expectEqual(2, g.nodes.items.len);
    try testing.expectEqual(1, g.edges.items.len);
    try testing.expectEqual(1, g.outputs.items.len);

    try testing.expectEqual(builder.Edge.PortRef{ .node = 0, .port = 0 }, g.edges.items[0].from);
    try testing.expectEqual(builder.Edge.PortRef{ .node = 1, .port = 0 }, g.edges.items[0].to);
    try testing.expectEqualStrings("Oscillator", g.nodes.items[0].name);

    // oscillator has no input port; gain has one output port, so port 1 is out of range
    try testing.expectError(error.port_out_of_range, g.connect(gain, osc));
    try testing.expectError(error.port_out_of_range, g.connectPorts(.{ .node = 1, .port = 1 }, .{ .node = 1, .port = 0 }));
    try testing.expectError(error.invalid_handle, g.connect(osc, .{ .index = 9 }));
}

test "plan - hand-built Oscillator -> Gain -> copy_out renders one block" {
    const allocator = testing.allocator;
    const Plan = plan.ExecutionPlan(f32);

    var osc = nodes.Oscillator(f32).init(.sine, 440, 1);
    var gain = nodes.Gain(f32){ .gain = 0.5 };

    const node_list = try allocator.alloc(Node(f32), 2);
    defer allocator.free(node_list);
    node_list[0] = Node(f32).init(&osc);
    node_list[1] = Node(f32).init(&gain);

    for (node_list) |n| try n.prepare(.{ .sample_rate = 48000, .max_frames = .blk_64, .channel_count = 2 });

    // slot 0: oscillator output, slot 1: gain output
    const slot_refs = try allocator.alloc(plan.Slot, 2);
    defer allocator.free(slot_refs);

    slot_refs[0] = 0;
    slot_refs[1] = 1;

    const ops = try allocator.alloc(plan.Op, 3);
    defer allocator.free(ops);
    ops[0] = .{ .process = .{ .node = 0, .inputs = slot_refs[0..0], .outputs = slot_refs[0..1] } };
    ops[1] = .{ .process = .{ .node = 1, .inputs = slot_refs[0..1], .outputs = slot_refs[1..2] } };
    ops[2] = .{ .copy_out = 1 };

    var pool = try buffer.AudioBufferPool(f32).init(allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 64 });
    defer pool.deinit(allocator);

    const in_scratch = try allocator.alloc(buffer.ConstAudioBlock(f32), 1);
    defer allocator.free(in_scratch);
    const out_scratch = try allocator.alloc(buffer.AudioBlock(f32), 1);
    defer allocator.free(out_scratch);

    // every field is owned by this test, so no plan.deinit here
    var p: Plan = .{
        .nodes = node_list,
        .ops = ops,
        .slot_refs = slot_refs,
        .pool = pool,
        .scratch = .{
            .in = in_scratch,
            .out = out_scratch,
        },
        .sample_rate = 48000,
        .max_frames = .blk_64,
        .channel_count = 2,
    };

    var owned = try buffer.OwnedAudioBuffer(f32).init(allocator, .{ .channel_count = 2, .max_frames = 64 });
    defer owned.deinit(allocator);
    const out = try owned.borrowBlock(16);

    try p.render(out);

    for (out.channel(0), 0..) |sample, n| {
        const expected: f64 = 0.5 * @sin(2 * std.math.pi * 440 * @as(f64, @floatFromInt(n)) / 48000);
        try testing.expectApproxEqAbs(@as(f32, @floatCast(expected)), sample, 1e-5);
    }
    try testing.expectEqualSlices(f32, out.channel(0), out.channel(1));

    // wrong channel count is rejected before anything runs
    var mono = try buffer.OwnedAudioBuffer(f32).init(allocator, .{ .channel_count = 1, .max_frames = 16 });
    defer mono.deinit(allocator);
    try testing.expectError(error.shape_mismatch, p.render(try mono.borrowBlock(16)));
}
