const std = @import("std");
const graph = @import("graph.zig");
const specs = @import("common").audio_specs;
const audio_buffer = @import("common").audio_buffer;

const log = std.log.scoped(.graph);

pub fn Scheduler(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("Scheduler only supports f32 and f64");
    }

    return struct {
        const Self = @This();
        const GenericNode = graph.nodes.interface.GenericNode(T);
        const GainNode = graph.nodes.utils.GainNode(T);

        const SineNode = graph.nodes.wave.SineNode(T);

        const PrepareContext = GenericNode.PrepareContext;
        const ProcessContext = GenericNode.ProcessContext;

        audio_graph: graph.Graph(T),
        allocator: std.mem.Allocator,
        topology_queue: ?graph.TopologyQueue = null,
        buffers: ?audio_buffer.UniformChannelViews(T) = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .audio_graph = graph.Graph(T).init(allocator, .{}),
                .allocator = allocator,
            };
        }

        // this is just an example, graphs as built dynamically
        pub fn build_graph(self: *Self, sample_rate: specs.SampleRate) !void {
            var sine_node = try self.audio_graph.addNode(SineNode.init(540.0, 1.0, sample_rate.toFloat(T)));

            const gain_node = try self.audio_graph.addNode(GainNode{ .gain = 0.5 });
            try sine_node.connect(gain_node);
        }

        /// Builds the next plan completely before replacing the current one, so a failure
        /// leaves the previous queue and pool in place.
        pub fn prepare(self: *Self, ctx: PrepareContext) !void {
            for (self.audio_graph.nodes.items) |*node| {
                try node.prepare(ctx);
            }

            var queue = try self.audio_graph.topologicalSortAlloc(self.allocator);
            errdefer queue.deinit();

            // assigns buffer index to each node and returns the number of buffers required
            const n_views = try queue.analyzeBufferRequirementsAlloc();

            if (!self.canReuseBuffers(n_views, ctx)) {
                const buffers = try audio_buffer.UniformChannelViews(T).init(self.allocator, .{
                    .n_views = n_views,
                    .n_channels = ctx.n_channels,
                    .block_size = ctx.block_size,
                    .access = ctx.access_pattern,
                });

                if (self.buffers) |*old| old.deinit();
                self.buffers = buffers;
            }

            if (self.topology_queue) |*old| old.deinit();
            self.topology_queue = queue;
        }

        fn canReuseBuffers(self: Self, n_views: usize, ctx: PrepareContext) bool {
            const buffers = self.buffers orelse return false;

            return buffers.opts.n_views >= n_views and
                buffers.opts.n_channels == ctx.n_channels and
                buffers.opts.block_size == ctx.block_size and
                buffers.opts.access == ctx.access_pattern;
        }

        pub fn processGraph(self: *Self) !void {
            // WORK IN PROGRESS NOT READY TODO
            const queue = self.topology_queue orelse return;
            var buffers = self.buffers orelse return;

            var processed_count: usize = 0;
            const total_nodes = queue.nodes.len;

            while (processed_count < total_nodes) {
                const queue_items = queue.nodes.slice();

                for (0..queue_items.len) |idx| {
                    // queue_item has information about the index of nodes in the graph
                    // the inputs/dependencies of the node
                    // which buffer to use when processing the node
                    const queue_item = queue_items.get(idx);
                    var graph_node = self.audio_graph.nodes.items[queue_item.graph_index];

                    if (graph_node.nodeStatus() == .processed) continue;

                    const all_inputs_ready: bool = blk: {
                        for (queue_item.inputs) |input_index| {
                            const input_node = self.audio_graph.nodes.items[input_index];
                            if (input_node.nodeStatus() != .processed) break :blk false;
                        }

                        break :blk true;
                    };

                    if (!all_inputs_ready) continue;

                    for (queue_item.inputs) |input_index| {
                        const parent_queue_item = queue.getFromGraphIndex(input_index);
                        const parent_buffer_index = parent_queue_item.buffer_index;

                        if (parent_buffer_index != queue_item.buffer_index) {
                            // todo check for nulls here
                            var parent_view = buffers.getView(parent_buffer_index.?);
                            var child_view = buffers.getView(queue_item.buffer_index.?);

                            try child_view.copyFrom(parent_view);
                            parent_view.zero();
                        }
                    }

                    const node_buffer_view = buffers.getView(queue_item.buffer_index.?);

                    // when to copy and when to share?
                    const ctx = ProcessContext{ .buffer = node_buffer_view };
                    graph_node.process(ctx);

                    self.audio_graph.updateNodeStatus(queue_item.graph_index, .processed);
                    processed_count += 1;
                }
            }
        }

        pub fn getOutputBuffer(self: Self) ?audio_buffer.UnmanagedChannelView(T) {
            const queue = self.topology_queue orelse return null;

            const queue_last = queue.getLast();
            const buffer_index = queue_last.buffer_index orelse return null;
            var buffers = self.buffers orelse return null;

            for (self.audio_graph.nodes.items) |*node| {
                node.setStatus(.ready);
            }

            return buffers.getView(buffer_index);
        }

        pub fn blockSize(self: *Self) usize {
            return @intFromEnum(self.buffers.?.opts.block_size);
        }

        // pub fn process(self: *Self) !void {
        //     const queue = self.topology_queue orelse return;
        //     var buffers = self.buffers orelse return;
        //     var buffer = buffers.getView(0);

        //     const ctx = ProcessContext{ .buffer = &buffer };

        //     outer: for (queue.nodes.items(.graph_index), queue.nodes.items(.inputs)) |node_index, inputs| {
        //         for (inputs) |input_index| {
        //             const input_node = self.audio_graph.nodes.items[input_index];
        //             if (input_node.nodeStatus() != .processed) {
        //                 continue :outer;
        //             }
        //         }

        //         var node = self.audio_graph.nodes.items[node_index];
        //         self.audio_graph.updateNodeStatus(node_index, .ready);
        //         node.process(ctx);

        //         self.audio_graph.updateNodeStatus(node_index, .processed);
        //     }
        // }

        pub fn deinit(self: *Self) void {
            self.audio_graph.deinit();

            if (self.buffers) |*buffer| {
                buffer.deinit();
            }

            if (self.topology_queue) |*queue| {
                queue.deinit();
            }
        }
    };
}

const testing = std.testing;

const TestScheduler = Scheduler(f32);
const TestGain = graph.nodes.utils.GainNode(f32);

const test_prepare_ctx: TestScheduler.PrepareContext = .{
    .block_size = .blk_64,
    .n_channels = 2,
    .sample_rate = 48000,
    .access_pattern = .non_interleaved,
};

test "Scheduler: prepare reuses the pool when the requirements are unchanged" {
    var scheduler = TestScheduler.init(testing.allocator);
    defer scheduler.deinit();

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });

    try scheduler.prepare(test_prepare_ctx);
    const first_pool = scheduler.buffers.?.buffer;

    try scheduler.prepare(test_prepare_ctx);
    const second_pool = scheduler.buffers.?.buffer;

    try testing.expectEqual(first_pool.ptr, second_pool.ptr);
    try testing.expectEqual(first_pool.len, second_pool.len);
}

test "Scheduler: prepare grows the pool when the graph needs more buffers" {
    var scheduler = TestScheduler.init(testing.allocator);
    defer scheduler.deinit();

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    try scheduler.prepare(test_prepare_ctx);
    try testing.expectEqual(1, scheduler.buffers.?.opts.n_views);

    // independent nodes cannot share a buffer
    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    try scheduler.prepare(test_prepare_ctx);

    try testing.expectEqual(3, scheduler.buffers.?.opts.n_views);
    try testing.expectEqual(3 * 2 * 64, scheduler.buffers.?.buffer.len);

    // every assigned buffer index must be inside the pool
    for (scheduler.topology_queue.?.nodes.items(.buffer_index)) |buffer_index| {
        try testing.expect(buffer_index.? < scheduler.buffers.?.opts.n_views);
    }
}

test "Scheduler: prepare rebuilds the pool when channel count, block size or access change" {
    var scheduler = TestScheduler.init(testing.allocator);
    defer scheduler.deinit();

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    try scheduler.prepare(test_prepare_ctx);

    var ctx = test_prepare_ctx;
    ctx.n_channels = 4;
    try scheduler.prepare(ctx);
    try testing.expectEqual(4, scheduler.buffers.?.opts.n_channels);
    try testing.expectEqual(4 * 64, scheduler.buffers.?.buffer.len);

    ctx.block_size = .blk_128;
    try scheduler.prepare(ctx);
    try testing.expectEqual(128, scheduler.blockSize());
    try testing.expectEqual(4 * 128, scheduler.buffers.?.buffer.len);

    ctx.access_pattern = .interleaved;
    try scheduler.prepare(ctx);
    try testing.expectEqual(.interleaved, scheduler.buffers.?.opts.access);

    const view = scheduler.getOutputBuffer().?;
    try testing.expectEqual(4, view.n_channels);
    try testing.expectEqual(128, view.block_size);
    try testing.expectEqual(.interleaved, view.access);
}

fn prepareTwice(allocator: std.mem.Allocator) !void {
    var scheduler = TestScheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    try scheduler.prepare(test_prepare_ctx);

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    try scheduler.prepare(test_prepare_ctx);
}

test "Scheduler: a failed prepare leaks nothing and frees nothing twice" {
    try testing.checkAllAllocationFailures(testing.allocator, prepareTwice, .{});
}

test "Scheduler: a failed prepare leaves the previous plan usable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var scheduler = TestScheduler.init(failing.allocator());
    defer scheduler.deinit();

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });
    try scheduler.prepare(test_prepare_ctx);

    const pool_before = scheduler.buffers.?.buffer;
    const queue_len_before = scheduler.topology_queue.?.nodes.len;

    _ = try scheduler.audio_graph.addNode(TestGain{ .gain = 1 });

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, scheduler.prepare(test_prepare_ctx));

    try testing.expectEqual(pool_before.ptr, scheduler.buffers.?.buffer.ptr);
    try testing.expectEqual(queue_len_before, scheduler.topology_queue.?.nodes.len);
}
