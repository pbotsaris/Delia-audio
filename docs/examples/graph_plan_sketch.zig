//! Design sketch for docs/graph-contract.md sections 3 to 5: builder, compiler, execution plan.
//! Not part of the build.
//!
//!     zig test docs/examples/graph_plan_sketch.zig
//!
//! A file under docs/ cannot import src/, so the first ~150 lines are stand-ins for things
//! that already exist. In src/ they are replaced by:
//!
//!     buffer = @import("buffer")    AudioBlock, ConstAudioBlock, AudioBufferPool,
//!                                                       clear, copy, accumulate
//!     node   = @import("nodes/node.zig")                Node(T), Ports, NodeError
//!     specs  = @import("../common/audio_specs.zig")     BlockSize for CompileOptions.max_frames
//!     nodes  = @import("nodes/root.zig")               Gain, Oscillator (tests only)
//!
//! The parts worth implementing as written are marked "port as is". The file layout in src/ is
//! builder.zig, compiler.zig and plan.zig; the sketch keeps them in one file, separated by rules.

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
        samples: []T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn channel(self: @This(), c: usize) []T {
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
        }

        pub fn asConst(self: @This()) ConstAudioBlock(T) {
            return .{ .samples = self.samples, .channel_count = self.channel_count, .frame_count = self.frame_count, .channel_stride = self.channel_stride };
        }
    };
}

pub fn AudioBufferPool(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Options = struct { slot_count: usize, channel_count: usize, max_frames: usize };

        storage: []T,
        slot_count: usize,
        channel_count: usize,
        max_frames: usize,
        channel_stride: usize,

        pub fn init(allocator: std.mem.Allocator, opts: Options) !Self {
            const storage = try allocator.alloc(T, opts.slot_count * opts.channel_count * opts.max_frames);
            @memset(storage, 0);
            return .{ .storage = storage, .slot_count = opts.slot_count, .channel_count = opts.channel_count, .max_frames = opts.max_frames, .channel_stride = opts.max_frames };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn borrowSlot(self: Self, index: usize, frame_count: usize) error{out_of_range}!AudioBlock(T) {
            if (index >= self.slot_count or frame_count > self.max_frames) return error.out_of_range;
            const per_slot = self.channel_count * self.channel_stride;
            return .{ .samples = self.storage[index * per_slot ..][0..per_slot], .channel_count = self.channel_count, .frame_count = frame_count, .channel_stride = self.channel_stride };
        }
    };
}

const OpError = error{ shape_mismatch, forbidden_overlap };

pub fn clear(comptime T: type, dst: AudioBlock(T)) void {
    for (0..dst.channel_count) |c| @memset(dst.channel(c), 0);
}

pub fn copy(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) OpError!void {
    if (dst.channel_count != src.channel_count or dst.frame_count != src.frame_count) return error.shape_mismatch;
    for (0..dst.channel_count) |c| @memcpy(dst.channel(c), src.channel(c));
}

pub fn accumulate(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) OpError!void {
    if (dst.channel_count != src.channel_count or dst.frame_count != src.frame_count) return error.shape_mismatch;
    for (0..dst.channel_count) |c| {
        for (dst.channel(c), src.channel(c)) |*d, s| d.* += s;
    }
}

// ===========================================================================
// Stand-in for src/graph/nodes/node.zig. Same shape as the real Node(T), fewer checks.
// ===========================================================================

pub const Ports = struct { inputs: u8, outputs: u8 };
pub const NodeError = error{allocation_error};

pub fn Node(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const PrepareContext = struct { sample_rate: T, max_frames: usize, channel_count: usize };
        pub const ProcessContext = struct {
            inputs: []const ConstAudioBlock(T),
            outputs: []const AudioBlock(T),
            frame_count: usize,
        };

        pub const VTable = struct {
            prepare: *const fn (*anyopaque, PrepareContext) NodeError!void,
            process: *const fn (*anyopaque, ProcessContext) void,
            destroy: *const fn (std.mem.Allocator, *anyopaque) void,
        };

        ptr: *anyopaque,
        vtable: *const VTable,
        ports: Ports,
        name: []const u8,

        pub fn createNode(allocator: std.mem.Allocator, impl: anytype) std.mem.Allocator.Error!Self {
            const ptr = try allocator.create(@TypeOf(impl));
            ptr.* = impl;
            return init(ptr);
        }

        pub fn init(ptr: anytype) Self {
            const PtrType = @TypeOf(ptr);
            const Impl = @TypeOf(ptr.*);
            const gen = struct {
                fn prepareFn(ctx: *anyopaque, c: PrepareContext) NodeError!void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    try self.prepare(c);
                }
                fn processFn(ctx: *anyopaque, c: ProcessContext) void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    self.process(c);
                }
                fn destroyFn(allocator: std.mem.Allocator, ctx: *anyopaque) void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    allocator.destroy(self);
                }
                const vtable = VTable{ .prepare = prepareFn, .process = processFn, .destroy = destroyFn };
            };
            return .{ .ptr = ptr, .vtable = &gen.vtable, .ports = Impl.ports, .name = Impl.name };
        }

        pub fn prepare(self: Self, ctx: PrepareContext) NodeError!void {
            try self.vtable.prepare(self.ptr, ctx);
        }
        pub fn process(self: Self, ctx: ProcessContext) void {
            std.debug.assert(ctx.inputs.len == self.ports.inputs);
            std.debug.assert(ctx.outputs.len == self.ports.outputs);
            self.vtable.process(self.ptr, ctx);
        }
        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            self.vtable.destroy(allocator, self.ptr);
        }
    };
}

// Stand-ins for nodes/gain.zig and nodes/oscillator.zig, used by the tests.

pub fn TestGain(comptime T: type) type {
    return struct {
        gain: T,
        pub const ports: Ports = .{ .inputs = 1, .outputs = 1 };
        pub const name: []const u8 = "Gain";
        pub fn prepare(_: *@This(), _: Node(T).PrepareContext) NodeError!void {}
        pub fn process(self: *@This(), ctx: Node(T).ProcessContext) void {
            for (0..ctx.outputs[0].channel_count) |c| {
                for (ctx.outputs[0].channel(c), ctx.inputs[0].channel(c)) |*o, i| o.* = i * self.gain;
            }
        }
    };
}

pub fn TestSine(comptime T: type) type {
    return struct {
        freq: T,
        phase: T = 0,
        inc: T = 0,
        pub const ports: Ports = .{ .inputs = 0, .outputs = 1 };
        pub const name: []const u8 = "Sine";
        pub fn prepare(self: *@This(), ctx: Node(T).PrepareContext) NodeError!void {
            self.inc = 2 * std.math.pi * self.freq / ctx.sample_rate;
        }
        pub fn process(self: *@This(), ctx: Node(T).ProcessContext) void {
            const out = ctx.outputs[0];
            for (out.channel(0)) |*o| {
                o.* = @sin(self.phase);
                self.phase += self.inc;
            }
            for (1..out.channel_count) |c| @memcpy(out.channel(c), out.channel(0));
        }
    };
}

// ===========================================================================
// src/graph/builder.zig. Port as is.
// ===========================================================================

pub const NodeHandle = struct { index: u32 };

/// One end of an edge. The graph output is not a node, so it has no PortRef; the builder keeps
/// its producers in a separate list.
pub const PortRef = struct { node: u32, port: u8 };

pub const Edge = struct { from: PortRef, to: PortRef };

pub const BuilderError = error{ invalid_handle, port_out_of_range } || std.mem.Allocator.Error;

/// Mutable, editing-time only. Owns the node heap copies; a plan borrows them. Nothing here is
/// touched while a plan is rendering: stop, edit, recompile, restart.
pub fn GraphBuilder(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node(T)) = .empty,
        edges: std.ArrayList(Edge) = .empty,
        /// Producers feeding the graph output, in insertion order. More than one means a mix.
        outputs: std.ArrayList(PortRef) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |n| n.destroy(self.allocator);
            self.nodes.deinit(self.allocator);
            self.edges.deinit(self.allocator);
            self.outputs.deinit(self.allocator);
            self.* = undefined;
        }

        /// Copies `impl` to the heap. The handle is an index; it stays valid until `deinit`.
        pub fn addNode(self: *Self, impl: anytype) BuilderError!NodeHandle {
            const n = try Node(T).createNode(self.allocator, impl);
            errdefer n.destroy(self.allocator);

            try self.nodes.append(self.allocator, n);
            return .{ .index = @intCast(self.nodes.items.len - 1) };
        }

        /// (from, output 0) -> (to, input 0). Enough for every node that exists today.
        pub fn connect(self: *Self, from: NodeHandle, to: NodeHandle) BuilderError!void {
            try self.connectPorts(from, 0, to, 0);
        }

        /// Port numbers are checked here, against the node's declared `ports`, so a bad edge
        /// fails at the call site rather than at compile time.
        pub fn connectPorts(self: *Self, from: NodeHandle, from_port: u8, to: NodeHandle, to_port: u8) BuilderError!void {
            const producer = try self.node(from);
            const consumer = try self.node(to);

            if (from_port >= producer.ports.outputs or to_port >= consumer.ports.inputs) return error.port_out_of_range;

            try self.edges.append(self.allocator, .{
                .from = .{ .node = from.index, .port = from_port },
                .to = .{ .node = to.index, .port = to_port },
            });
        }

        /// (from, output 0) feeds the graph output. Call it more than once to mix.
        pub fn connectOutput(self: *Self, from: NodeHandle) BuilderError!void {
            const producer = try self.node(from);
            if (producer.ports.outputs == 0) return error.port_out_of_range;

            try self.outputs.append(self.allocator, .{ .node = from.index, .port = 0 });
        }

        fn node(self: Self, handle: NodeHandle) BuilderError!Node(T) {
            if (handle.index >= self.nodes.items.len) return error.invalid_handle;
            return self.nodes.items[handle.index];
        }
    };
}

// ===========================================================================
// src/graph/plan.zig. Port as is.
// ===========================================================================

pub const Slot = u32;

/// What the render loop executes. Slots index the pool; `process` slices point into the plan's
/// `slot_refs` backing array. There is nothing else to look up at render time.
pub const Op = union(enum) {
    clear: Slot,
    accumulate: struct { dst: Slot, src: Slot },
    process: struct { node: u32, inputs: []const Slot, outputs: []const Slot },
    copy_out: Slot,
};

pub fn ExecutionPlan(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Copies of the builder's wrappers. The impl pointers still belong to the builder.
        nodes: []Node(T),
        ops: []const Op,
        slot_refs: []Slot,
        pool: AudioBufferPool(T),
        /// Refilled per `process` op; sized to the largest port count in the plan.
        in_scratch: []ConstAudioBlock(T),
        out_scratch: []AudioBlock(T),
        max_frames: usize,
        channel_count: usize,

        /// The render path. One shape check, then the op list. No allocation, no lookup, no
        /// status. Block-op errors are unreachable: the compiler proved every shape and pool
        /// slots are disjoint by construction.
        pub fn render(self: *Self, out: AudioBlock(T)) error{shape_mismatch}!void {
            const n = out.frame_count;
            if (out.channel_count != self.channel_count or n > self.max_frames) return error.shape_mismatch;
            if (n == 0) return;

            for (self.ops) |op| switch (op) {
                .clear => |s| clear(T, self.slot(s, n)),
                .accumulate => |a| accumulate(T, self.slot(a.dst, n), self.slot(a.src, n).asConst()) catch unreachable,
                .process => |p| {
                    for (p.inputs, 0..) |s, i| self.in_scratch[i] = self.slot(s, n).asConst();
                    for (p.outputs, 0..) |s, i| self.out_scratch[i] = self.slot(s, n);

                    self.nodes[p.node].process(.{
                        .inputs = self.in_scratch[0..p.inputs.len],
                        .outputs = self.out_scratch[0..p.outputs.len],
                        .frame_count = n,
                    });
                },
                .copy_out => |s| copy(T, out, self.slot(s, n).asConst()) catch unreachable,
            };
        }

        fn slot(self: *Self, s: Slot, n: usize) AudioBlock(T) {
            // s < slot_count and n <= max_frames were both established before this runs
            return self.pool.borrowSlot(s, n) catch unreachable;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.pool.deinit(allocator);
            allocator.free(self.out_scratch);
            allocator.free(self.in_scratch);
            allocator.free(self.slot_refs);
            allocator.free(self.ops);
            allocator.free(self.nodes);
            self.* = undefined;
        }
    };
}

// ===========================================================================
// src/graph/compiler.zig. Port as is.
// ===========================================================================

pub const CompileError = error{ unconnected_input, no_output, cycle_detected } || NodeError || std.mem.Allocator.Error;

pub fn CompileOptions(comptime T: type) type {
    return struct {
        sample_rate: T,
        /// specs.BlockSize in src; the pool gets @intFromEnum of it.
        max_frames: usize,
        channel_count: usize,
    };
}

/// Builder -> plan. Everything temporary lives in an arena that is freed on every exit; the
/// plan's own arrays are allocated last, each with an errdefer, so a failure leaves nothing
/// behind and the builder untouched. Nodes may have been prepared; prepare is repeatable.
pub fn compile(comptime T: type, allocator: std.mem.Allocator, builder: *const GraphBuilder(T), options: CompileOptions(T)) CompileError!ExecutionPlan(T) {
    const nodes = builder.nodes.items;
    const edges = builder.edges.items;
    const graph_outputs = builder.outputs.items;
    const node_count = nodes.len;

    if (graph_outputs.len == 0) return error.no_output;
    var arena_state = std.heap.ArenaAllocator.init(allocator);

    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -- port tables: input port (node, p) is row in_base[node] + p, same for outputs --------

    const in_base = try arena.alloc(u32, node_count + 1);
    const out_base = try arena.alloc(u32, node_count + 1);
    in_base[0] = 0;
    out_base[0] = 0;
    for (nodes, 0..) |n, i| {
        in_base[i + 1] = in_base[i] + n.ports.inputs;
        out_base[i + 1] = out_base[i] + n.ports.outputs;
    }
    const input_port_count = in_base[node_count];
    const output_port_count = out_base[node_count];

    // -- validate: every input port has at least one producer --------------------------------

    const producer_count = try arena.alloc(u32, input_port_count);
    @memset(producer_count, 0);
    for (edges) |e| producer_count[in_base[e.to.node] + e.to.port] += 1;
    for (producer_count) |c| if (c == 0) return error.unconnected_input;

    // -- order ------------------------------------------------------------------------------

    const order = try topologicalOrder(arena, node_count, edges);

    // -- slots: one per output port, then one mix slot per fan-in port ----------------------

    var slot_count: Slot = output_port_count;

    const mix_slot = try arena.alloc(?Slot, input_port_count);
    @memset(mix_slot, null);
    for (producer_count, 0..) |c, p| {
        if (c > 1) {
            mix_slot[p] = slot_count;
            slot_count += 1;
        }
    }

    const output_mix: ?Slot = if (graph_outputs.len > 1) blk: {
        defer slot_count += 1;
        break :blk slot_count;
    } else null;

    // -- prepare, in node index order ---------------------------------------------------------

    for (nodes) |n| try n.prepare(.{
        .sample_rate = options.sample_rate,
        .max_frames = options.max_frames,
        .channel_count = options.channel_count,
    });

    // -- emit ops ---------------------------------------------------------------------------

    const slot_refs = try allocator.alloc(Slot, input_port_count + output_port_count);
    errdefer allocator.free(slot_refs);
    var next_ref: usize = 0;

    var ops: std.ArrayList(Op) = .empty; // arena-backed; duplicated into the plan at the end

    for (order) |ni| {
        const n = nodes[ni];

        const inputs = slot_refs[next_ref..][0..n.ports.inputs];
        next_ref += n.ports.inputs;

        for (inputs, 0..) |*input_slot, p| {
            const port = in_base[ni] + p;

            if (mix_slot[port]) |mix| {
                try ops.append(arena, .{ .clear = mix });
                for (edges) |e| {
                    if (e.to.node == ni and e.to.port == p) {
                        try ops.append(arena, .{ .accumulate = .{ .dst = mix, .src = outputSlot(out_base, e.from) } });
                    }
                }
                input_slot.* = mix;
            } else {
                for (edges) |e| {
                    if (e.to.node == ni and e.to.port == p) input_slot.* = outputSlot(out_base, e.from);
                }
            }
        }

        const outputs = slot_refs[next_ref..][0..n.ports.outputs];
        next_ref += n.ports.outputs;
        for (outputs, 0..) |*output_slot, p| output_slot.* = out_base[ni] + @as(u32, @intCast(p));

        try ops.append(arena, .{ .process = .{ .node = @intCast(ni), .inputs = inputs, .outputs = outputs } });
    }

    if (output_mix) |mix| {
        try ops.append(arena, .{ .clear = mix });
        for (graph_outputs) |o| try ops.append(arena, .{ .accumulate = .{ .dst = mix, .src = outputSlot(out_base, o) } });
        try ops.append(arena, .{ .copy_out = mix });
    } else {
        try ops.append(arena, .{ .copy_out = outputSlot(out_base, graph_outputs[0]) });
    }

    // -- plan storage -----------------------------------------------------------------------

    var max_inputs: usize = 0;
    var max_outputs: usize = 0;
    for (nodes) |n| {
        max_inputs = @max(max_inputs, n.ports.inputs);
        max_outputs = @max(max_outputs, n.ports.outputs);
    }

    const plan_ops = try allocator.dupe(Op, ops.items);
    errdefer allocator.free(plan_ops);

    const plan_nodes = try allocator.dupe(Node(T), nodes);
    errdefer allocator.free(plan_nodes);

    const in_scratch = try allocator.alloc(ConstAudioBlock(T), max_inputs);
    errdefer allocator.free(in_scratch);

    const out_scratch = try allocator.alloc(AudioBlock(T), max_outputs);
    errdefer allocator.free(out_scratch);

    var pool = try AudioBufferPool(T).init(allocator, .{
        .slot_count = slot_count,
        .channel_count = options.channel_count,
        .max_frames = options.max_frames,
    });
    errdefer pool.deinit(allocator);

    return .{
        .nodes = plan_nodes,
        .ops = plan_ops,
        .slot_refs = slot_refs,
        .pool = pool,
        .in_scratch = in_scratch,
        .out_scratch = out_scratch,
        .max_frames = options.max_frames,
        .channel_count = options.channel_count,
    };
}

fn outputSlot(out_base: []const u32, ref: PortRef) Slot {
    return out_base[ref.node] + ref.port;
}

/// Kahn's algorithm with a fixed tie-break: among ready nodes, the lowest index goes first.
/// O(n^2) scan instead of a queue, because the order must not depend on edge insertion order
/// and n is small at compile time.
fn topologicalOrder(arena: std.mem.Allocator, node_count: usize, edges: []const Edge) CompileError![]const u32 {
    const in_degree = try arena.alloc(u32, node_count);
    @memset(in_degree, 0);
    for (edges) |e| in_degree[e.to.node] += 1;

    const placed = try arena.alloc(bool, node_count);
    @memset(placed, false);

    const order = try arena.alloc(u32, node_count);

    for (order) |*slot| {
        const next = for (in_degree, placed, 0..) |d, done, i| {
            if (!done and d == 0) break i;
        } else return error.cycle_detected;

        placed[next] = true;
        slot.* = @intCast(next);

        for (edges) |e| {
            if (e.from.node == next) in_degree[e.to.node] -= 1;
        }
    }

    return order;
}

// ===========================================================================
// Tests: the acceptance list in docs/graph-contract.md section 7.
// ===========================================================================

const testing = std.testing;

const test_options: CompileOptions(f32) = .{ .sample_rate = 48000, .max_frames = 64, .channel_count = 2 };

fn referenceSine(freq: f64, n: usize) f32 {
    return @floatCast(@sin(2 * std.math.pi * freq * @as(f64, @floatFromInt(n)) / 48000));
}

/// Owned output storage for tests: 2 channels, `max` frames, tightly packed.
const OutBuffer = struct {
    samples: []f32,
    max: usize,

    fn init(allocator: std.mem.Allocator, max: usize) !OutBuffer {
        const samples = try allocator.alloc(f32, 2 * max);
        @memset(samples, 0);
        return .{ .samples = samples, .max = max };
    }
    fn deinit(self: OutBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
    fn block(self: OutBuffer, first_frame: usize, frame_count: usize) AudioBlock(f32) {
        return .{ .samples = self.samples[first_frame..], .channel_count = 2, .frame_count = frame_count, .channel_stride = self.max };
    }
    fn channel(self: OutBuffer, c: usize) []f32 {
        return self.samples[c * self.max ..][0..self.max];
    }
};

fn buildChain(builder: *GraphBuilder(f32)) !void {
    const sine = try builder.addNode(TestSine(f32){ .freq = 440 });
    const gain = try builder.addNode(TestGain(f32){ .gain = 0.5 });
    try builder.connect(sine, gain);
    try builder.connectOutput(gain);
}

test "chain: Sine -> Gain -> output over four blocks matches the reference, phase continuous" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    const out = try OutBuffer.init(testing.allocator, 256);
    defer out.deinit(testing.allocator);

    for (0..4) |b| try plan.render(out.block(b * 64, 64));

    for (out.channel(0), 0..) |sample, n| try testing.expectApproxEqAbs(0.5 * referenceSine(440, n), sample, 1e-4);
    try testing.expectEqualSlices(f32, out.channel(0), out.channel(1));
}

test "chain: op list and slot count are pinned" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(2, plan.pool.slot_count);
    try testing.expectEqual(3, plan.ops.len);

    try testing.expectEqual(0, plan.ops[0].process.node);
    try testing.expectEqualSlices(Slot, &.{}, plan.ops[0].process.inputs);
    try testing.expectEqualSlices(Slot, &.{0}, plan.ops[0].process.outputs);

    try testing.expectEqual(1, plan.ops[1].process.node);
    try testing.expectEqualSlices(Slot, &.{0}, plan.ops[1].process.inputs);
    try testing.expectEqualSlices(Slot, &.{1}, plan.ops[1].process.outputs);

    try testing.expectEqual(Op{ .copy_out = 1 }, plan.ops[2]);
}

test "partial last block (64, 64, 17) is still continuous; zero frames is a no-op" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    const out = try OutBuffer.init(testing.allocator, 145);
    defer out.deinit(testing.allocator);

    try plan.render(out.block(0, 64));
    try plan.render(out.block(64, 0));
    try plan.render(out.block(64, 64));
    try plan.render(out.block(128, 17));

    for (out.channel(0), 0..) |sample, n| try testing.expectApproxEqAbs(0.5 * referenceSine(440, n), sample, 1e-4);
}

test "render writes every slot's active frames and nothing past them" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    @memset(plan.pool.storage, 9);

    const out = try OutBuffer.init(testing.allocator, 10);
    defer out.deinit(testing.allocator);
    try plan.render(out.block(0, 10));

    for (0..plan.pool.slot_count) |s| {
        const full = try plan.pool.borrowSlot(s, 64);
        for (0..2) |c| {
            for (full.channel(c)[0..10]) |sample| try testing.expect(sample != 9);
            for (full.channel(c)[10..]) |sample| try testing.expectEqual(9, sample);
        }
    }
}

test "render allocates nothing" {
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = counting.allocator();

    var builder = GraphBuilder(f32).init(allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var plan = try compile(f32, allocator, &builder, test_options);
    defer plan.deinit(allocator);

    const out = try OutBuffer.init(allocator, 64);
    defer out.deinit(allocator);

    const before = counting.alloc_index;
    for (0..100) |_| try plan.render(out.block(0, 64));
    try testing.expectEqual(before, counting.alloc_index);
}

test "fan-out and fan-in: Sine -> Gain(0.25), Sine -> Gain(0.5), both -> output" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    const sine = try builder.addNode(TestSine(f32){ .freq = 440 });
    const a = try builder.addNode(TestGain(f32){ .gain = 0.25 });
    const b = try builder.addNode(TestGain(f32){ .gain = 0.5 });
    try builder.connect(sine, a);
    try builder.connect(sine, b);
    try builder.connectOutput(a);
    try builder.connectOutput(b);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    // pinned: 3 output slots + 1 output mix; process x3, clear, acc, acc, copy_out
    try testing.expectEqual(4, plan.pool.slot_count);
    try testing.expectEqual(7, plan.ops.len);
    try testing.expectEqual(Op{ .clear = 3 }, plan.ops[3]);
    try testing.expectEqual(Op{ .accumulate = .{ .dst = 3, .src = 1 } }, plan.ops[4]);
    try testing.expectEqual(Op{ .accumulate = .{ .dst = 3, .src = 2 } }, plan.ops[5]);
    try testing.expectEqual(Op{ .copy_out = 3 }, plan.ops[6]);

    const out = try OutBuffer.init(testing.allocator, 64);
    defer out.deinit(testing.allocator);
    try plan.render(out.block(0, 64));

    for (out.channel(0), 0..) |sample, n| try testing.expectApproxEqAbs(0.75 * referenceSine(440, n), sample, 1e-4);
}

test "diamond: Sine -> A, Sine -> B, A -> C, B -> C, C -> output" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    const sine = try builder.addNode(TestSine(f32){ .freq = 440 });
    const a = try builder.addNode(TestGain(f32){ .gain = 0.25 });
    const b = try builder.addNode(TestGain(f32){ .gain = 0.5 });
    const c = try builder.addNode(TestGain(f32){ .gain = 2 });
    try builder.connect(sine, a);
    try builder.connect(sine, b);
    try builder.connect(a, c);
    try builder.connect(b, c);
    try builder.connectOutput(c);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    // 4 output slots + 1 mix slot for C's input; C reads the mix
    try testing.expectEqual(5, plan.pool.slot_count);
    try testing.expectEqualSlices(Slot, &.{4}, plan.ops[6].process.inputs);

    const out = try OutBuffer.init(testing.allocator, 64);
    defer out.deinit(testing.allocator);
    try plan.render(out.block(0, 64));

    for (out.channel(0), 0..) |sample, n| try testing.expectApproxEqAbs(1.5 * referenceSine(440, n), sample, 1e-4);
}

test "order does not depend on insertion order: lowest ready index first" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    // added gain first, sine second; sine must still run first
    const gain = try builder.addNode(TestGain(f32){ .gain = 1 });
    const sine = try builder.addNode(TestSine(f32){ .freq = 440 });
    try builder.connect(sine, gain);
    try builder.connectOutput(gain);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(1, plan.ops[0].process.node);
    try testing.expectEqual(0, plan.ops[1].process.node);
}

test "compile rejects: unconnected input, no output, cycle; builder rejects bad port and handle" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();

    const sine = try builder.addNode(TestSine(f32){ .freq = 440 });
    const gain = try builder.addNode(TestGain(f32){ .gain = 1 });

    try testing.expectError(error.no_output, compile(f32, testing.allocator, &builder, test_options));

    try builder.connectOutput(gain);
    try testing.expectError(error.unconnected_input, compile(f32, testing.allocator, &builder, test_options));

    try testing.expectError(error.port_out_of_range, builder.connectPorts(sine, 1, gain, 0));
    try testing.expectError(error.port_out_of_range, builder.connect(gain, sine));
    try testing.expectError(error.invalid_handle, builder.connect(sine, .{ .index = 7 }));

    // gain -> gain is a one-node cycle; every input is connected, so only the sort catches it
    try builder.connect(gain, gain);
    try testing.expectError(error.cycle_detected, compile(f32, testing.allocator, &builder, test_options));
}

test "render rejects wrong channel count and oversized block, writes nothing" {
    var builder = GraphBuilder(f32).init(testing.allocator);
    defer builder.deinit();
    try buildChain(&builder);

    var plan = try compile(f32, testing.allocator, &builder, test_options);
    defer plan.deinit(testing.allocator);

    var samples = [_]f32{7} ** 130;
    const mono: AudioBlock(f32) = .{ .samples = &samples, .channel_count = 1, .frame_count = 64, .channel_stride = 130 };
    const too_long: AudioBlock(f32) = .{ .samples = &samples, .channel_count = 2, .frame_count = 65, .channel_stride = 65 };

    try testing.expectError(error.shape_mismatch, plan.render(mono));
    try testing.expectError(error.shape_mismatch, plan.render(too_long));
    for (samples) |s| try testing.expectEqual(7, s);
}

fn buildCompileRender(allocator: std.mem.Allocator) !void {
    var builder = GraphBuilder(f32).init(allocator);
    defer builder.deinit();

    const sine = try builder.addNode(TestSine(f32){ .freq = 440 });
    const a = try builder.addNode(TestGain(f32){ .gain = 0.25 });
    const b = try builder.addNode(TestGain(f32){ .gain = 0.5 });
    try builder.connect(sine, a);
    try builder.connect(sine, b);
    try builder.connectOutput(a);
    try builder.connectOutput(b);

    var plan = try compile(f32, allocator, &builder, test_options);
    defer plan.deinit(allocator);

    var samples = [_]f32{0} ** 128;
    try plan.render(.{ .samples = &samples, .channel_count = 2, .frame_count = 64, .channel_stride = 64 });
}

test "failed compile leaks nothing and frees nothing twice" {
    try testing.checkAllAllocationFailures(testing.allocator, buildCompileRender, .{});
}

test "failed compile leaves the builder usable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var builder = GraphBuilder(f32).init(failing.allocator());
    defer builder.deinit();
    try buildChain(&builder);

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, compile(f32, failing.allocator(), &builder, test_options));

    failing.fail_index = std.math.maxInt(usize);
    var plan = try compile(f32, failing.allocator(), &builder, test_options);
    plan.deinit(failing.allocator());
}
