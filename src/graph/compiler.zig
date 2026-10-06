//! Graph compiler: turns a `GraphBuilder` into an `ExecutionPlan`.
//! Contract: docs/graph-contract.md section 4.
//!
//! Everything here runs at preparation time. It allocates and may fail; the plan it returns
//! renders without doing either.
//!
//! Slot numbering. Every (node, output port) gets its own pool slot, numbered in node index
//! order. Mix slots come after those: one per input port with more than one producer, then
//! one for the graph output if it has more than one producer. No slot is reused within a
//! render call, so a producer's output stays readable by every consumer.
//!
//!     osc -> gain_a -+
//!         -> gain_b -+-> output        slots: osc 0, gain_a 1, gain_b 2, output mix 3
//!
//!     process osc        -> 0
//!     process gain_a   0 -> 1
//!     process gain_b   0 -> 2
//!     clear 3, accumulate 3 += 1, accumulate 3 += 2, copy_out 3

const std = @import("std");
const specs = @import("common").audio_specs;
const graph_node = @import("node.zig");
const plan = @import("plan.zig");
const buffer = @import("buffer");
const b = @import("builder.zig");

const ConstAudioBlock = buffer.ConstAudioBlock;
const AudioBlock = buffer.AudioBlock;
const Slot = plan.Slot;
const Edge = b.Edge;
const PortRef = b.Edge.PortRef;
const Op = plan.Op;
const AudioBufferPool = buffer.AudioBufferPool;

/// What the plan is prepared for. Every node receives the same values in `prepare`, and the
/// pool is sized from `max_frames` and `channel_count`.
pub fn CompileOptions(comptime T: type) type {
    return struct {
        sample_rate: T,
        max_frames: specs.BlockSize,
        channel_count: usize,
    };
}

pub const CompileError = error{
    /// An input port has no producer.
    disconnected_input,
    /// `connectOutput` was never called on the builder.
    no_output,
    cycle_detected,
} || graph_node.NodeError || buffer.AudioBufferError || std.mem.Allocator.Error;

/// Namespace for `compile`, so the sample type is stated once: `Compiler(f32).compile(...)`.
pub fn Compiler(comptime T: type) type {
    const Builder = b.GraphBuilder(T);
    const Plan = plan.ExecutionPlan(T);

    return struct {
        /// Builds a plan for `builder`. The caller owns the result and releases it with
        /// `plan.deinit(allocator)` before the builder's `deinit`: the plan borrows the nodes.
        ///
        /// Transactional: on any error nothing allocated here survives and the builder is
        /// unchanged. Nodes may already have been prepared, so `prepare` must be repeatable.
        ///
        /// Intermediate tables live in an arena that is freed on every exit. `slot.refs` is
        /// the one allocation made for the plan before `finish`, hence the errdefer below.
        pub fn compile(allocator: std.mem.Allocator, builder: *const Builder, opts: CompileOptions(T)) CompileError!Plan {
            if (builder.outputs.items.len == 0) return CompileError.no_output;

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var comp = Compilation(T){
                .arena = arena.allocator(),
                .builder = builder,
                .options = opts,
            };

            try comp.buildPortTable();
            try comp.checkInputConnected();
            try comp.kahnSort();
            try comp.assignSlots();
            try comp.prepareNodes();

            try comp.emitOps(allocator);
            errdefer allocator.free(comp.slot.refs);

            return comp.finish(allocator);
        }
    };
}

/// Intermediate state of one `compile` call. Fields are filled in step order and each step
/// reads only what earlier steps produced. Nothing here outlives `compile`.
fn Compilation(comptime T: type) type {
    const Builder = b.GraphBuilder(T);
    const Node = graph_node.Node(T);
    const Plan = plan.ExecutionPlan(T);

    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        builder: *const Builder,
        options: CompileOptions(T),

        /// Prefix sums of port counts, one entry per node plus a final total. A port's row is
        /// `in[node] + port` or `out[node] + port`. An output row is also that port's slot.
        port_table: struct {
            in: []u32 = &.{},
            out: []u32 = &.{},
        } = .{},

        /// Number of edges arriving at each input port, indexed by input row.
        producer_count: []u32 = &.{},

        /// Node indices in execution order.
        node_order: []u32 = &.{},

        /// Slots 0..outputPortCount() are one per output port; mix slots follow.
        slot: struct {
            /// Mix slot per input port row, null when the port has a single producer.
            port_mix: []?Slot = &.{},
            /// Mix slot for the graph output, null when it has a single producer.
            output_mix: ?Slot = null,
            /// Total slots the pool needs.
            count: u32 = 0,
            /// Backing array the process ops slice into. Owned by the plan once `finish` returns.
            refs: []Slot = &.{},
        } = .{},

        /// Arena-backed while compiling; `finish` copies it into the plan.
        ops: std.ArrayList(Op) = .empty,

        fn getNodes(self: Self) []const Node {
            return self.builder.nodes.items;
        }

        fn getEdges(self: Self) []const Edge {
            return self.builder.edges.items;
        }

        fn inputPortCount(self: Self) u32 {
            const nodes = self.getNodes();
            return self.port_table.in[nodes.len];
        }

        fn outputPortCount(self: Self) u32 {
            const nodes = self.getNodes();
            return self.port_table.out[nodes.len];
        }

        /// Pool slot a producer writes to.
        fn outputSlot(self: Self, ref: PortRef) Slot {
            return self.port_table.out[ref.node] + ref.port;
        }

        /// Row of an input port in `producer_count` and `slot.port_mix`.
        fn inputRow(self: Self, ref: PortRef) u32 {
            return self.port_table.in[ref.node] + ref.port;
        }

        fn buildPortTable(self: *Self) CompileError!void {
            const nodes = self.getNodes();

            self.port_table.in = try self.arena.alloc(Slot, nodes.len + 1);
            self.port_table.out = try self.arena.alloc(Slot, nodes.len + 1);

            self.port_table.in[0] = 0;
            self.port_table.out[0] = 0;

            for (nodes, 0..) |node, i| {
                self.port_table.in[i + 1] = self.port_table.in[i] + node.ports.inputs;
                self.port_table.out[i + 1] = self.port_table.out[i] + node.ports.outputs;
            }
        }

        /// Counts producers per input port and rejects a port that has none.
        fn checkInputConnected(self: *Self) CompileError!void {
            self.producer_count = try self.arena.alloc(u32, self.inputPortCount());
            @memset(self.producer_count, 0);

            for (self.getEdges()) |edge| {
                self.producer_count[self.inputRow(edge.to)] += 1;
            }

            for (self.producer_count) |count| {
                if (count == 0) return CompileError.disconnected_input;
            }
        }

        /// Kahn's algorithm. Among the nodes that are ready, the lowest index goes first, so the
        /// order depends on the graph and never on edge insertion order. That costs a scan per
        /// node, O(n^2) overall, which is acceptable at compile time.
        /// Running out of ready nodes before every node is placed means there is a cycle.
        fn kahnSort(self: *Self) CompileError!void {
            const node_count = self.getNodes().len;

            const in_degrees = try self.arena.alloc(u32, node_count);
            @memset(in_degrees, 0);

            for (self.getEdges()) |edge| {
                in_degrees[edge.to.node] += 1;
            }

            const placed = try self.arena.alloc(bool, node_count);
            @memset(placed, false);

            const order = try self.arena.alloc(Slot, node_count);

            for (order) |*slot| {
                const next = for (in_degrees, placed, 0..) |degree, done, i| {
                    if (!done and degree == 0) break i;
                } else return CompileError.cycle_detected;

                placed[next] = true;
                slot.* = @intCast(next);

                for (self.getEdges()) |edge| {
                    if (edge.from.node == next) in_degrees[edge.to.node] -= 1;
                }
            }

            self.node_order = order;
        }

        /// Reserves the mix slots after the output port slots. See the numbering at the top.
        fn assignSlots(self: *Self) CompileError!void {
            self.slot.count = self.outputPortCount();
            self.slot.port_mix = try self.arena.alloc(?Slot, self.inputPortCount());
            @memset(self.slot.port_mix, null);

            for (self.producer_count, self.slot.port_mix) |count, *mix| {
                if (count > 1) {
                    mix.* = self.slot.count;
                    self.slot.count += 1;
                }
            }

            if (self.builder.outputs.items.len > 1) {
                self.slot.output_mix = self.slot.count;
                self.slot.count += 1;
            }
        }

        /// Node index order, after validation, so a rejected graph prepares nothing.
        fn prepareNodes(self: *Self) CompileError!void {
            for (self.getNodes()) |node| try node.prepare(.{
                .sample_rate = self.options.sample_rate,
                .max_frames = self.options.max_frames,
                .channel_count = self.options.channel_count,
            });
        }

        /// Emits, per node in execution order, the mix ops its inputs need and then its
        /// `process` op; the graph output comes last. Each process op's `inputs` and `outputs`
        /// are consecutive ranges of `slot.refs`, which is allocated from `allocator` because
        /// the plan keeps it.
        fn emitOps(self: *Self, allocator: std.mem.Allocator) CompileError!void {
            self.slot.refs = try allocator.alloc(Slot, self.inputPortCount() + self.outputPortCount());
            errdefer allocator.free(self.slot.refs);

            var next_ref: usize = 0;

            for (self.node_order) |node_index| {
                const node = self.getNodes()[node_index];

                const inputs = self.slot.refs[next_ref..][0..node.ports.inputs];
                next_ref += node.ports.inputs;

                for (inputs, 0..) |*input, port| {
                    input.* = try self.emitInput(node_index, @intCast(port));
                }

                const outputs = self.slot.refs[next_ref..][0..node.ports.outputs];
                next_ref += node.ports.outputs;

                for (outputs, 0..) |*output, port| {
                    output.* = self.outputSlot(.{ .node = node_index, .port = @intCast(port) });
                }

                try self.ops.append(self.arena, .{ .process = .{ .node = node_index, .inputs = inputs, .outputs = outputs } });
            }

            try self.emitOutput();
        }

        /// Returns the slot a node reads for one input port. With a single producer that is the
        /// producer's slot and nothing is emitted. With several, emits `clear` and one
        /// `accumulate` per producer in edge insertion order, and returns the mix slot.
        fn emitInput(self: *Self, node_index: u32, port: u8) CompileError!Slot {
            const row = self.inputRow(.{ .node = node_index, .port = port });

            const mix = self.slot.port_mix[row] orelse {
                for (self.getEdges()) |edge| {
                    const found = edge.to.node == node_index and edge.to.port == port;
                    if (found) return self.outputSlot(edge.from);
                }

                unreachable; // checkInputConnected guarantees at least one producer
            };

            try self.ops.append(self.arena, .{ .clear = mix });

            for (self.getEdges()) |edge| {
                const found = edge.to.node == node_index and edge.to.port == port;
                const op: Op = .{ .accumulate = .{ .dst = mix, .src = self.outputSlot(edge.from) } };

                if (found) try self.ops.append(self.arena, op);
            }

            return mix;
        }

        /// Same rule as `emitInput`, for the graph output, followed by `copy_out`.
        fn emitOutput(self: *Self) CompileError!void {
            const graph_outs = self.builder.outputs.items;

            const mix = self.slot.output_mix orelse {
                const first_out = graph_outs[0];
                try self.ops.append(self.arena, .{ .copy_out = self.outputSlot(first_out) });
                return;
            };

            try self.ops.append(self.arena, .{ .clear = mix });

            for (graph_outs) |out| {
                const op: Op = .{ .accumulate = .{ .dst = mix, .src = self.outputSlot(out) } };
                try self.ops.append(self.arena, op);
            }

            try self.ops.append(self.arena, .{ .copy_out = mix });
        }

        /// Allocates what the plan owns and hands over `slot.refs`. Scratch arrays are sized to
        /// the widest node. The node wrappers are copied; the node state stays in the builder.
        fn finish(self: *Self, allocator: std.mem.Allocator) CompileError!Plan {
            var max_ins: usize = 0;
            var max_outs: usize = 0;

            for (self.getNodes()) |node| {
                max_ins = @max(max_ins, node.ports.inputs);
                max_outs = @max(max_outs, node.ports.outputs);
            }

            const plan_ops = try allocator.dupe(Op, self.ops.items);
            errdefer allocator.free(plan_ops);

            const plan_nodes = try allocator.dupe(Node, self.getNodes());
            errdefer allocator.free(plan_nodes);

            const scratch_ins = try allocator.alloc(ConstAudioBlock(T), max_ins);
            errdefer allocator.free(scratch_ins);

            const scratch_outs = try allocator.alloc(AudioBlock(T), max_outs);
            errdefer allocator.free(scratch_outs);

            var pool = try AudioBufferPool(T).init(allocator, .{
                .slot_count = self.slot.count,
                .channel_count = self.options.channel_count,
                .max_frames = self.options.max_frames.toUsize(),
            });
            errdefer pool.deinit(allocator);

            return .{
                .nodes = plan_nodes,
                .ops = plan_ops,
                .slot_refs = self.slot.refs,
                .pool = pool,
                .scratch = .{ .in = scratch_ins, .out = scratch_outs },
                .sample_rate = self.options.sample_rate,
                .max_frames = self.options.max_frames,
                .channel_count = self.options.channel_count,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: the acceptance list in docs/graph-contract.md section 7.
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_nodes = @import("nodes/root.zig");

const Oscillator = test_nodes.Oscillator(f32);
const Gain = test_nodes.Gain(f32);
const TestBuilder = b.GraphBuilder(f32);
const TestCompiler = Compiler(f32);

const test_options: CompileOptions(f32) = .{
    .sample_rate = 48000,
    .max_frames = .blk_64,
    .channel_count = 2,
};

fn referenceSine(n: usize) f32 {
    return @floatCast(@sin(2 * std.math.pi * 440.0 * @as(f64, @floatFromInt(n)) / 48000.0));
}

fn expectScaledSine(scale: f32, first_frame: usize, actual: []const f32) !void {
    for (actual, first_frame..) |sample, n| {
        try testing.expectApproxEqAbs(scale * referenceSine(n), sample, 1e-4);
    }
}

fn buildChain(builder: *TestBuilder) !void {
    const osc = try builder.addNode(Oscillator.init(.sine, 440, 1));
    const gain = try builder.addNode(Gain{ .gain = 0.5 });

    try builder.connect(osc, gain);
    try builder.connectOutput(gain);
}

fn buildFanIn(builder: *TestBuilder) !void {
    const osc = try builder.addNode(Oscillator.init(.sine, 440, 1));
    const quarter = try builder.addNode(Gain{ .gain = 0.25 });
    const half = try builder.addNode(Gain{ .gain = 0.5 });

    try builder.connect(osc, quarter);
    try builder.connect(osc, half);
    try builder.connectOutput(quarter);
    try builder.connectOutput(half);
}

test "compile - chain renders four blocks that match the reference, phase continuous" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    var owned = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 256 });
    defer owned.deinit(testing.allocator);
    const out = try owned.borrowBlock(256);

    for (0..4) |block| try compiled.render(try out.subBlock(block * 64, 64));

    try expectScaledSine(0.5, 0, out.channel(0));
    try testing.expectEqualSlices(f32, out.channel(0), out.channel(1));
}

test "compile - chain: op list and slot count are pinned" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqual(2, compiled.pool.slot_count);
    try testing.expectEqual(3, compiled.ops.len);

    try testing.expectEqual(0, compiled.ops[0].process.node);
    try testing.expectEqualSlices(Slot, &.{}, compiled.ops[0].process.inputs);
    try testing.expectEqualSlices(Slot, &.{0}, compiled.ops[0].process.outputs);

    try testing.expectEqual(1, compiled.ops[1].process.node);
    try testing.expectEqualSlices(Slot, &.{0}, compiled.ops[1].process.inputs);
    try testing.expectEqualSlices(Slot, &.{1}, compiled.ops[1].process.outputs);

    try testing.expectEqual(Op{ .copy_out = 1 }, compiled.ops[2]);
}

test "compile - partial last block (64, 64, 17) is continuous; zero frames is a no-op" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    var owned = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 145 });
    defer owned.deinit(testing.allocator);
    const out = try owned.borrowBlock(145);

    try compiled.render(try out.subBlock(0, 64));
    try compiled.render(try out.subBlock(64, 0));
    try compiled.render(try out.subBlock(64, 64));
    try compiled.render(try out.subBlock(128, 17));

    try expectScaledSine(0.5, 0, out.channel(0));
}

test "compile - render writes every slot's active frames and nothing past them" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    @memset(compiled.pool.storage, 9);

    var owned = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 64 });
    defer owned.deinit(testing.allocator);
    try compiled.render(try owned.borrowBlock(10));

    for (0..compiled.pool.slot_count) |slot| {
        const full = try compiled.pool.borrowSlot(slot, 64);

        for (0..2) |ch| {
            for (full.channel(ch)[0..10]) |sample| try testing.expect(sample != 9);
            for (full.channel(ch)[10..]) |sample| try testing.expectEqual(9, sample);
        }
    }
}

test "compile - render allocates nothing" {
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = counting.allocator();

    var builder = TestBuilder.init(allocator);
    defer builder.deinit();
    try buildFanIn(&builder);

    var compiled = try TestCompiler.compile(allocator, &builder, test_options);
    defer compiled.deinit(allocator);

    var owned = try buffer.OwnedAudioBuffer(f32).init(allocator, .{ .channel_count = 2, .max_frames = 64 });
    defer owned.deinit(allocator);
    const out = try owned.borrowBlock(64);

    const before = counting.alloc_index;
    for (0..100) |_| try compiled.render(out);
    try testing.expectEqual(before, counting.alloc_index);
}

test "compile - fan-out and fan-in into the graph output sums to 0.75 * sine" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();
    try buildFanIn(&builder);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    // pinned: 3 output slots + 1 output mix; process x3, clear, accumulate x2, copy_out
    try testing.expectEqual(4, compiled.pool.slot_count);
    try testing.expectEqual(7, compiled.ops.len);
    try testing.expectEqual(Op{ .clear = 3 }, compiled.ops[3]);
    try testing.expectEqual(Op{ .accumulate = .{ .dst = 3, .src = 1 } }, compiled.ops[4]);
    try testing.expectEqual(Op{ .accumulate = .{ .dst = 3, .src = 2 } }, compiled.ops[5]);
    try testing.expectEqual(Op{ .copy_out = 3 }, compiled.ops[6]);

    var owned = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 64 });
    defer owned.deinit(testing.allocator);
    const out = try owned.borrowBlock(64);
    try compiled.render(out);

    try expectScaledSine(0.75, 0, out.channel(0));
}

test "compile - diamond mixes into the consumer's input port" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();

    const osc = try builder.addNode(Oscillator.init(.sine, 440, 1));
    const quarter = try builder.addNode(Gain{ .gain = 0.25 });
    const half = try builder.addNode(Gain{ .gain = 0.5 });
    const double = try builder.addNode(Gain{ .gain = 2 });

    try builder.connect(osc, quarter);
    try builder.connect(osc, half);
    try builder.connect(quarter, double);
    try builder.connect(half, double);
    try builder.connectOutput(double);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    // 4 output slots + 1 mix slot for the last gain's input, which reads the mix
    try testing.expectEqual(5, compiled.pool.slot_count);
    try testing.expectEqual(Op{ .clear = 4 }, compiled.ops[3]);
    try testing.expectEqualSlices(Slot, &.{4}, compiled.ops[6].process.inputs);
    try testing.expectEqual(Op{ .copy_out = 3 }, compiled.ops[7]);

    var owned = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 64 });
    defer owned.deinit(testing.allocator);
    const out = try owned.borrowBlock(64);

    try compiled.render(out);

    try expectScaledSine(1.5, 0, out.channel(0));
}

test "compile - order follows dependencies, not insertion order" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();

    const gain = try builder.addNode(Gain{ .gain = 1 });
    const osc = try builder.addNode(Oscillator.init(.sine, 440, 1));
    try builder.connect(osc, gain);
    try builder.connectOutput(gain);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqual(1, compiled.ops[0].process.node);
    try testing.expectEqual(0, compiled.ops[1].process.node);
}

test "compile - rejects no output, disconnected input and cycles" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode(Oscillator.init(.sine, 440, 1));
    const gain = try builder.addNode(Gain{ .gain = 1 });

    try testing.expectError(error.no_output, TestCompiler.compile(testing.allocator, &builder, test_options));

    try builder.connectOutput(gain);
    try testing.expectError(error.disconnected_input, TestCompiler.compile(testing.allocator, &builder, test_options));

    // a node feeding itself has every input connected, so only the sort can catch it
    try builder.connect(gain, gain);
    try testing.expectError(error.cycle_detected, TestCompiler.compile(testing.allocator, &builder, test_options));
}

test "compile - render rejects wrong channel count and oversized block" {
    var builder = TestBuilder.init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var compiled = try TestCompiler.compile(testing.allocator, &builder, test_options);
    defer compiled.deinit(testing.allocator);

    var mono = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 1, .max_frames = 64 });
    defer mono.deinit(testing.allocator);
    var long = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 65 });
    defer long.deinit(testing.allocator);

    try testing.expectError(error.shape_mismatch, compiled.render(try mono.borrowBlock(64)));
    try testing.expectError(error.shape_mismatch, compiled.render(try long.borrowBlock(65)));
    for (long.storage) |sample| try testing.expectEqual(0, sample);
}

fn buildCompileRender(allocator: std.mem.Allocator) !void {
    var builder = TestBuilder.init(allocator);

    defer builder.deinit();
    try buildFanIn(&builder);

    var compiled = try TestCompiler.compile(allocator, &builder, test_options);
    defer compiled.deinit(allocator);

    var owned = try buffer.OwnedAudioBuffer(f32).init(allocator, .{ .channel_count = 2, .max_frames = 64 });
    defer owned.deinit(allocator);
    try compiled.render(try owned.borrowBlock(64));
}

test "compile - a failed compile leaks nothing and frees nothing twice" {
    try testing.checkAllAllocationFailures(testing.allocator, buildCompileRender, .{});
}

test "compile - a failed compile leaves the builder usable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();

    var builder = TestBuilder.init(allocator);
    defer builder.deinit();
    try buildChain(&builder);

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, TestCompiler.compile(allocator, &builder, test_options));

    failing.fail_index = std.math.maxInt(usize);
    var compiled = try TestCompiler.compile(allocator, &builder, test_options);
    compiled.deinit(allocator);
}
