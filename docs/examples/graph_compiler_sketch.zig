//! Alternative shape for the compiler in docs/examples/graph_plan_sketch.zig: a `Compiler(T)`
//! namespace whose `compile` reads like the step list in docs/graph-contract.md section 4, with
//! the intermediate tables held in a private `Compilation` struct, one method per step.
//! Same output as the single-function version; the tests below check that op for op.
//!
//!     zig test docs/examples/graph_compiler_sketch.zig
//!
//! Imports the builder, plan and stand-ins from the plan sketch. In src/ this is compiler.zig.

const std = @import("std");
const sketch = @import("graph_plan_sketch.zig");

const Node = sketch.Node;
const GraphBuilder = sketch.GraphBuilder;
const ExecutionPlan = sketch.ExecutionPlan;
const AudioBufferPool = sketch.AudioBufferPool;
const AudioBlock = sketch.AudioBlock;
const ConstAudioBlock = sketch.ConstAudioBlock;
const Edge = sketch.Edge;
const PortRef = sketch.PortRef;
const Op = sketch.Op;
const Slot = sketch.Slot;
const CompileError = sketch.CompileError;
const CompileOptions = sketch.CompileOptions;

pub fn Compiler(comptime T: type) type {
    return struct {
        const Builder = GraphBuilder(T);
        const Plan = ExecutionPlan(T);

        /// Steps in contract order. Scratch lives in the arena and dies on every exit. The only
        /// non-arena allocation before `finish` is `slot_refs`, covered by the errdefer below.
        pub fn compile(allocator: std.mem.Allocator, builder: *const Builder, options: CompileOptions(T)) CompileError!Plan {
            if (builder.outputs.items.len == 0) return error.no_output;

            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            var c = Compilation{
                .arena = arena_state.allocator(),
                .builder = builder,
                .options = options,
            };

            try c.buildPortTables();
            try c.checkInputsConnected();
            try c.sortNodes();
            try c.assignSlots();
            try c.prepareNodes();

            try c.emitOps(allocator);
            errdefer allocator.free(c.slot_refs);

            return c.finish(allocator);
        }

        /// Intermediate state. Fields are filled in step order; each step reads only what the
        /// steps before it produced. Nothing here outlives `compile`.
        const Compilation = struct {
            arena: std.mem.Allocator,
            builder: *const Builder,
            options: CompileOptions(T),

            // buildPortTables: input port (node, p) is row in_base[node] + p; same for outputs
            in_base: []u32 = &.{},
            out_base: []u32 = &.{},

            // checkInputsConnected
            producer_count: []u32 = &.{},

            // sortNodes
            order: []const u32 = &.{},

            // assignSlots: one slot per output port, then one mix slot per fan-in port
            mix_slot: []?Slot = &.{},
            output_mix: ?Slot = null,
            slot_count: Slot = 0,

            // emitOps: ops are arena-backed, slot_refs is plan-owned (allocator)
            ops: std.ArrayList(Op) = .empty,
            slot_refs: []Slot = &.{},

            fn nodes(self: Compilation) []const Node(T) {
                return self.builder.nodes.items;
            }

            fn edges(self: Compilation) []const Edge {
                return self.builder.edges.items;
            }

            fn inputPortCount(self: Compilation) u32 {
                return self.in_base[self.nodes().len];
            }

            fn outputPortCount(self: Compilation) u32 {
                return self.out_base[self.nodes().len];
            }

            fn outputSlot(self: Compilation, ref: PortRef) Slot {
                return self.out_base[ref.node] + ref.port;
            }

            fn buildPortTables(self: *Compilation) CompileError!void {
                const node_count = self.nodes().len;

                self.in_base = try self.arena.alloc(u32, node_count + 1);
                self.out_base = try self.arena.alloc(u32, node_count + 1);
                self.in_base[0] = 0;
                self.out_base[0] = 0;

                for (self.nodes(), 0..) |n, i| {
                    self.in_base[i + 1] = self.in_base[i] + n.ports.inputs;
                    self.out_base[i + 1] = self.out_base[i] + n.ports.outputs;
                }
            }

            fn checkInputsConnected(self: *Compilation) CompileError!void {
                self.producer_count = try self.arena.alloc(u32, self.inputPortCount());
                @memset(self.producer_count, 0);

                for (self.edges()) |e| self.producer_count[self.in_base[e.to.node] + e.to.port] += 1;
                for (self.producer_count) |c| if (c == 0) return error.unconnected_input;
            }

            /// Kahn's algorithm with a fixed tie-break: among ready nodes, the lowest index goes
            /// first, so the order never depends on edge insertion order.
            fn sortNodes(self: *Compilation) CompileError!void {
                const node_count = self.nodes().len;

                const in_degree = try self.arena.alloc(u32, node_count);
                @memset(in_degree, 0);
                for (self.edges()) |e| in_degree[e.to.node] += 1;

                const placed = try self.arena.alloc(bool, node_count);
                @memset(placed, false);

                const order = try self.arena.alloc(u32, node_count);

                for (order) |*slot| {
                    const next = for (in_degree, placed, 0..) |d, done, i| {
                        if (!done and d == 0) break i;
                    } else return error.cycle_detected;

                    placed[next] = true;
                    slot.* = @intCast(next);

                    for (self.edges()) |e| {
                        if (e.from.node == next) in_degree[e.to.node] -= 1;
                    }
                }

                self.order = order;
            }

            fn assignSlots(self: *Compilation) CompileError!void {
                self.slot_count = self.outputPortCount();

                self.mix_slot = try self.arena.alloc(?Slot, self.inputPortCount());
                @memset(self.mix_slot, null);

                for (self.producer_count, self.mix_slot) |count, *mix| {
                    if (count > 1) {
                        mix.* = self.slot_count;
                        self.slot_count += 1;
                    }
                }

                if (self.builder.outputs.items.len > 1) {
                    self.output_mix = self.slot_count;
                    self.slot_count += 1;
                }
            }

            fn prepareNodes(self: *Compilation) CompileError!void {
                for (self.nodes()) |n| try n.prepare(.{
                    .sample_rate = self.options.sample_rate,
                    .max_frames = self.options.max_frames,
                    .channel_count = self.options.channel_count,
                });
            }

            /// For each node in order: clear + accumulate for every fan-in port, then process.
            /// Then the graph output. `slot_refs` is allocated here because the process ops
            /// slice into it and the plan keeps it. It is freed here if this step fails, and by
            /// the caller if a later step fails.
            fn emitOps(self: *Compilation, allocator: std.mem.Allocator) CompileError!void {
                self.slot_refs = try allocator.alloc(Slot, self.inputPortCount() + self.outputPortCount());
                errdefer allocator.free(self.slot_refs);

                var next_ref: usize = 0;

                for (self.order) |ni| {
                    const n = self.nodes()[ni];

                    const inputs = self.slot_refs[next_ref..][0..n.ports.inputs];
                    next_ref += n.ports.inputs;
                    for (inputs, 0..) |*input_slot, p| input_slot.* = try self.emitInput(ni, @intCast(p));

                    const outputs = self.slot_refs[next_ref..][0..n.ports.outputs];
                    next_ref += n.ports.outputs;
                    for (outputs, 0..) |*output_slot, p| output_slot.* = self.out_base[ni] + @as(u32, @intCast(p));

                    try self.ops.append(self.arena, .{ .process = .{ .node = ni, .inputs = inputs, .outputs = outputs } });
                }

                try self.emitOutput();
            }

            /// Returns the slot the node reads for (node, port): the producer's output slot, or a
            /// mix slot that the emitted clear/accumulate ops fill first.
            fn emitInput(self: *Compilation, node_index: u32, port: u8) CompileError!Slot {
                const row = self.in_base[node_index] + port;
                const mix = self.mix_slot[row] orelse {
                    for (self.edges()) |e| {
                        if (e.to.node == node_index and e.to.port == port) return self.outputSlot(e.from);
                    }
                    unreachable; // checkInputsConnected guarantees at least one producer
                };

                try self.ops.append(self.arena, .{ .clear = mix });
                for (self.edges()) |e| {
                    if (e.to.node == node_index and e.to.port == port) {
                        try self.ops.append(self.arena, .{ .accumulate = .{ .dst = mix, .src = self.outputSlot(e.from) } });
                    }
                }
                return mix;
            }

            fn emitOutput(self: *Compilation) CompileError!void {
                const graph_outputs = self.builder.outputs.items;

                const mix = self.output_mix orelse {
                    try self.ops.append(self.arena, .{ .copy_out = self.outputSlot(graph_outputs[0]) });
                    return;
                };

                try self.ops.append(self.arena, .{ .clear = mix });
                for (graph_outputs) |o| try self.ops.append(self.arena, .{ .accumulate = .{ .dst = mix, .src = self.outputSlot(o) } });
                try self.ops.append(self.arena, .{ .copy_out = mix });
            }

            /// Copies what the plan keeps out of the arena and allocates the pool. Each
            /// allocation has an errdefer; `slot_refs` is the caller's to free on failure.
            fn finish(self: *Compilation, allocator: std.mem.Allocator) CompileError!Plan {
                var max_inputs: usize = 0;
                var max_outputs: usize = 0;
                for (self.nodes()) |n| {
                    max_outputs = @max(max_outputs, n.ports.outputs);
                    max_inputs = @max(max_inputs, n.ports.inputs);
                }

                const plan_ops = try allocator.dupe(Op, self.ops.items);
                errdefer allocator.free(plan_ops);

                const plan_nodes = try allocator.dupe(Node(T), self.nodes());
                errdefer allocator.free(plan_nodes);

                const in_scratch = try allocator.alloc(ConstAudioBlock(T), max_inputs);
                errdefer allocator.free(in_scratch);

                const out_scratch = try allocator.alloc(AudioBlock(T), max_outputs);
                errdefer allocator.free(out_scratch);

                var pool = try AudioBufferPool(T).init(allocator, .{
                    .slot_count = self.slot_count,
                    .channel_count = self.options.channel_count,
                    .max_frames = self.options.max_frames,
                });
                errdefer pool.deinit(allocator);

                return .{
                    .nodes = plan_nodes,
                    .ops = plan_ops,
                    .slot_refs = self.slot_refs,
                    .pool = pool,
                    .in_scratch = in_scratch,
                    .out_scratch = out_scratch,
                    .max_frames = self.options.max_frames,
                    .channel_count = self.options.channel_count,
                };
            }
        };
    };
}

// ===========================================================================
// Tests: both compilers must agree on every graph the plan sketch tests.
// ===========================================================================

const testing = std.testing;

const test_options: CompileOptions(f32) = .{ .sample_rate = 48000, .max_frames = 64, .channel_count = 2 };

const Sine = sketch.TestSine;
const Gain = sketch.TestGain;

const Shape = enum { chain, fan_in, diamond, reversed_insertion };

fn build(builder: *GraphBuilder(f32), shape: Shape) !void {
    switch (shape) {
        .chain => {
            const sine = try builder.addNode(Sine(f32){ .freq = 440 });
            const gain = try builder.addNode(Gain(f32){ .gain = 0.5 });
            try builder.connect(sine, gain);
            try builder.connectOutput(gain);
        },
        .fan_in => {
            const sine = try builder.addNode(Sine(f32){ .freq = 440 });
            const a = try builder.addNode(Gain(f32){ .gain = 0.25 });
            const b = try builder.addNode(Gain(f32){ .gain = 0.5 });
            try builder.connect(sine, a);
            try builder.connect(sine, b);
            try builder.connectOutput(a);
            try builder.connectOutput(b);
        },
        .diamond => {
            const sine = try builder.addNode(Sine(f32){ .freq = 440 });
            const a = try builder.addNode(Gain(f32){ .gain = 0.25 });
            const b = try builder.addNode(Gain(f32){ .gain = 0.5 });
            const c = try builder.addNode(Gain(f32){ .gain = 2 });
            try builder.connect(sine, a);
            try builder.connect(sine, b);
            try builder.connect(a, c);
            try builder.connect(b, c);
            try builder.connectOutput(c);
        },
        .reversed_insertion => {
            const gain = try builder.addNode(Gain(f32){ .gain = 1 });
            const sine = try builder.addNode(Sine(f32){ .freq = 440 });
            try builder.connect(sine, gain);
            try builder.connectOutput(gain);
        },
    }
}

test "Compiler(T).compile produces the same plan as the single-function compile" {
    for ([_]Shape{ .chain, .fan_in, .diamond, .reversed_insertion }) |shape| {
        var builder = GraphBuilder(f32).init(testing.allocator);
        defer builder.deinit();
        try build(&builder, shape);

        var expected = try sketch.compile(f32, testing.allocator, &builder, test_options);
        defer expected.deinit(testing.allocator);

        var actual = try Compiler(f32).compile(testing.allocator, &builder, test_options);
        defer actual.deinit(testing.allocator);

        try testing.expectEqual(expected.pool.slot_count, actual.pool.slot_count);
        try testing.expectEqualDeep(expected.ops, actual.ops);
        try testing.expectEqualSlices(Slot, expected.slot_refs, actual.slot_refs);
    }
}

test "Compiler(T).compile rejects what the contract says it rejects" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode(Sine(f32){ .freq = 440 });
    const gain = try builder.addNode(Gain(f32){ .gain = 1 });

    try testing.expectError(error.no_output, Compiler(f32).compile(testing.allocator, &builder, test_options));

    try builder.connectOutput(gain);
    try testing.expectError(error.unconnected_input, Compiler(f32).compile(testing.allocator, &builder, test_options));

    try builder.connect(gain, gain);
    try testing.expectError(error.cycle_detected, Compiler(f32).compile(testing.allocator, &builder, test_options));
}

fn buildCompileRender(allocator: std.mem.Allocator) !void {
    var builder = GraphBuilder(f32).init(allocator);
    defer builder.deinit();
    try build(&builder, .fan_in);

    var plan = try Compiler(f32).compile(allocator, &builder, test_options);
    defer plan.deinit(allocator);

    var samples = [_]f32{0} ** 128;
    try plan.render(.{ .samples = &samples, .channel_count = 2, .frame_count = 64, .channel_stride = 64 });
}

test "Compiler(T).compile: failed compile leaks nothing and frees nothing twice" {
    try testing.checkAllAllocationFailures(testing.allocator, buildCompileRender, .{});
}
