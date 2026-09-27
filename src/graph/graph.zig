const std = @import("std");
const bitmap = @import("bitmap.zig");
pub const nodes = @import("nodes/nodes.zig");
pub const scheduler = @import("scheduler.zig");

/// Audio processing graph containing nodes, edges, and graph processing logic.
/// Designed to manage the execution order of nodes based on their dependencies.
/// Supports dynamic node connections and topological sorting.
pub fn Graph(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("AudioGraph only supports f32 and f64");
    }

    return struct {
        const Self = @This();
        const GenericNode = nodes.interface.GenericNode(T);

        /// Array of all nodes in the graph. Each node stores its own state and processing logic.
        nodes: std.ArrayList(GenericNode),

        /// Directed edges defining the connections between nodes.
        /// `from` and `to` indicate the source and destination node indices.
        edges: std.ArrayList(Edges),

        /// Memory allocator for dynamic allocations within the graph.
        allocator: std.mem.Allocator,

        /// Graph configuration options, such as static buffer size limits.
        options: GraphOptions,

        /// Configuration options for graph initialization.
        pub const GraphOptions = struct {
            comptime max_static_size: usize = 1024,
        };

        const GraphError = error{
            invalid_node,
            cycle_detected,
        };

        /// Represents a directed connection from one node to another.
        const Edges = struct {
            from: usize,
            to: usize,
        };

        /// Handle to a graph node, enabling operations like connecting nodes.
        const NodeHandle = struct {
            index: usize,
            graph: *Self,

            /// Connects the current node to another node within the same graph.
            /// Creates an edge from the current node (`self`) to the target node (`to`).
            pub fn connect(self: NodeHandle, to: NodeHandle) !void {
                try self.graph.connect(self, to);
            }
        };

        pub fn init(allocator: std.mem.Allocator, opts: GraphOptions) Self {
            return .{
                .nodes = .empty,
                .edges = .empty,
                .allocator = allocator,
                .options = opts,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |*node| {
                node.destroy();
            }

            self.nodes.deinit(self.allocator);
            self.edges.deinit(self.allocator);
        }

        /// Creates a directed connection between two nodes.
        /// Adds an edge from the `from` node to the `to` node.
        pub fn connect(self: *Self, from: NodeHandle, to: NodeHandle) !void {
            try self.edges.append(self.allocator, .{ .from = from.index, .to = to.index });
        }

        /// Adds a new node to the graph and returns a handle to it.
        /// The node type must implement the `GenericNode` interface.
        pub fn addNode(self: *Self, node: anytype) !NodeHandle {
            const generic_node = try GenericNode.createNode(self.allocator, node);
            const index = self.nodes.items.len;
            try self.nodes.append(self.allocator, generic_node);

            return .{ .index = index, .graph = self };
        }

        /// Updates the status of a node by index, useful for runtime changes.
        // TODO: this may become a batch update operation
        pub fn updateNodeStatus(self: *Self, index: usize, status: nodes.interface.NodeStatus) void {
            self.nodes.items[index].status.store(status, .seq_cst);
        }

        /// Exports the graph to a DOT format file for visualization.
        /// The output is compatible with tools like Graphviz.
        pub fn debugGraph(self: Self, io: std.Io, path: []const u8) !void {
            var file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);

            var buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &buffer);
            const writer = &file_writer.interface;
            try self.exportDot(writer);
            try writer.flush();
        }

        // Performs a topological sort of the graph, returning a `TopologyQueue`.
        /// Ensures nodes are sorted based on their dependencies for correct execution order.
        /// Allocates dynamic memory for sorting. Do not use in real-time contexts.
        /// Returned TopologyQueue is owned by the caller and must be manually deinitialized.
        pub fn topologicalSortAlloc(self: Self, allocator: std.mem.Allocator) !TopologyQueue {
            const node_count = self.nodes.items.len;

            var results = try TopologyQueue.init(allocator, node_count);
            errdefer results.deinit();

            if (node_count <= self.options.max_static_size) {
                try self.topologicalStatic(&results);
            } else unreachable; // TODO, dynamic version for very long graphs

            return results;
        }

        /// Static topological sorting optimized for smaller graphs.
        /// Uses preallocated arrays based on the static size limit defined in `GraphOptions`.
        fn topologicalStatic(self: Self, results: *TopologyQueue) !void {
            var in_degrees: [self.options.max_static_size]u32 = .{0} ** self.options.max_static_size;
            var visited = bitmap.StaticBitMap(self.options.max_static_size).init();
            var queue: [self.options.max_static_size]usize = undefined;

            var queue_len: usize = 0;
            var queue_start: usize = 0;

            const node_count = self.nodes.items.len;

            var inputs: [self.options.max_static_size]usize = undefined;
            var inputs_count: usize = 0;

            for (self.edges.items) |edge| {
                if (edge.to >= node_count) return GraphError.invalid_node;
                in_degrees[edge.to] += 1;
            }

            for (in_degrees[0..node_count], 0..) |deg, i| {
                if (deg != 0) continue;

                queue[queue_len] = i;
                queue_len += 1;
            }

            while (queue_start < queue_len) {
                const node_index = queue[queue_start];
                queue_start += 1;

                if (visited.isSet(node_index)) continue;
                try visited.set(node_index);

                inputs_count = 0;

                for (self.edges.items) |edge| {
                    if (edge.to == node_index) {
                        inputs[inputs_count] = edge.from;
                        inputs_count += 1;
                    }
                }

                try results.append(node_index, inputs[0..inputs_count]);

                for (self.edges.items) |edge| {
                    if (edge.from == node_index) {
                        in_degrees[edge.to] -= 1;
                        queue[queue_len] = edge.to;
                        queue_len += 1;
                    }
                }
            }

            if (results.nodes.len != node_count) {
                return GraphError.cycle_detected;
            }
        }

        // for debugging purposes
        fn exportDot(self: Self, writer: anytype) !void {
            try writer.writeAll("digraph AudioGraph {\n");
            try writer.writeAll("    rankdir=LR;\n");
            try writer.writeAll("    node [shape=box];\n\n");

            for (self.nodes.items, 0..) |node, i| {
                const node_type = @typeName(@TypeOf(node));
                try writer.print("    node{d} [label=\"{s}\"];\n", .{ i, node_type });
            }

            try writer.writeAll("\n");

            for (self.edges.items) |edge| {
                try writer.print("    node{d} -> node{d};\n", .{ edge.from, edge.to });
            }

            try writer.writeAll("}\n");
        }
    };
}

/// Node in the topology queue containing its graph index, input dependencies,
/// and an optional buffer index assigned during analysis.
/// buffer_index must be assigned during analyzeBufferRequirementsAlloc.
pub const TopologyQueueNode = struct {
    /// Index of the node in the graph
    graph_index: usize,
    /// Indices of the nodes that this node depends on
    inputs: []usize,
    /// Index of the buffer assigned to this node. Assigned during graph analysis
    buffer_index: ?usize = null,

    pub fn hasSameBuffer(self: TopologyQueueNode, other: TopologyQueueNode) bool {
        return self.buffer_index == other.buffer_index;
    }
};

/// Result of a graph's topological sort, maintaining node execution order
/// and buffer allocation strategy. Manages its own memory allocation.
/// Not designed to be resized after initialization.
pub const TopologyQueue = struct {
    nodes: std.MultiArrayList(TopologyQueueNode),
    // maps graph node index to topology queue index
    graph_to_queue_index: []usize,
    allocator: std.mem.Allocator,

    /// Initializes queue with fixed capacity. Cannot be resized.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !TopologyQueue {
        var nds = std.MultiArrayList(TopologyQueueNode){};
        try nds.ensureTotalCapacity(allocator, capacity);

        return .{
            .allocator = allocator,
            .nodes = nds,
            .graph_to_queue_index = try allocator.alloc(usize, capacity),
        };
    }

    pub fn getFromGraphIndex(self: TopologyQueue, graph_index: usize) TopologyQueueNode {
        const queue_index = self.graph_to_queue_index[graph_index];
        return self.nodes.get(queue_index);
    }

    pub fn getLast(self: TopologyQueue) TopologyQueueNode {
        return self.nodes.get(self.nodes.len - 1);
    }

    /// Appends node and its dependencies to queue, taking ownership of inputs slice
    pub fn append(self: *TopologyQueue, graph_index: usize, inputs: []usize) !void {
        const node_inputs = try self.allocator.alloc(usize, inputs.len);

        // we want execution queue to own the node_inputs memory
        @memcpy(node_inputs, inputs);

        self.graph_to_queue_index[graph_index] = self.nodes.len;

        self.nodes.appendAssumeCapacity(.{
            .graph_index = graph_index,
            .inputs = node_inputs,
        });
    }

    /// Analyzes the TopologyQueue to determine buffer requirements for graph processing.
    /// Assigns buffer indices to nodes' `buffer_index` field and returns total number of buffers required.
    /// Because of referencing counting, parent nodes share buffers with their last connected child.
    /// Caller can reference `buffer_index` to determine which buffer to use for each node.
    /// And the returned number of buffers to allocate memory.
    ///
    /// Note: Allocates temporary memory. Avoid in real-time contexts.
    pub fn analyzeBufferRequirementsAlloc(queue: *TopologyQueue) !usize {

        // ref_counts keeps track of the number of references to each node
        var ref_counts: std.ArrayList(usize) = .empty;
        // free_buffers keeps track of the indexes of the buffers that are not being used
        var free_buffers: std.ArrayList(usize) = .empty;

        defer ref_counts.deinit(queue.allocator);
        defer free_buffers.deinit(queue.allocator);

        try ref_counts.resize(queue.allocator, queue.nodes.len);
        @memset(ref_counts.items, 0);

        // reference counting
        for (queue.nodes.items(.inputs)) |inputs| {
            for (inputs) |input_graph_idx| {
                const input_queue_idx = queue.graph_to_queue_index[input_graph_idx];
                ref_counts.items[input_queue_idx] += 1;
            }
        }

        var next_buffer_idx: usize = 0;

        // update buffer indexes
        for (queue.nodes.items(.inputs), 0..) |inputs, queue_idx| {
            for (inputs) |input_graph_idx| {
                const input_queue_idx = queue.graph_to_queue_index[input_graph_idx];
                ref_counts.items[input_queue_idx] -= 1;

                if (ref_counts.items[input_queue_idx] == 0) {
                    // must not be null otherwise there is a bug
                    const buffer_idx = queue.nodes.items(.buffer_index)[input_queue_idx].?;

                    try free_buffers.append(queue.allocator, buffer_idx);
                }
            }

            if (free_buffers.items.len > 0) {
                queue.nodes.items(.buffer_index)[queue_idx] = free_buffers.pop();
                continue;
            }

            queue.nodes.items(.buffer_index)[queue_idx] = next_buffer_idx;
            next_buffer_idx += 1;
        }

        return next_buffer_idx;
    }

    pub fn deinit(self: *TopologyQueue) void {
        for (self.nodes.items(.inputs)) |inputs| {
            self.allocator.free(inputs);
        }

        self.nodes.deinit(self.allocator);
        self.allocator.free(self.graph_to_queue_index);
    }
};

// just an example to use in the graph
const GainNode = struct {
    gain: f64,

    const Self = @This();
    const PrepareContext = nodes.interface.GenericNode(f64).PrepareContext;
    const ProcessContext = nodes.interface.GenericNode(f64).ProcessContext;
    const Error = nodes.interface.NodeError;

    // for testing, no need to implement
    pub fn process(_: *Self, _: ProcessContext) void {}
    pub fn prepare(_: *Self, _: PrepareContext) Error!void {}

    pub fn name(_: *Self) []const u8 {
        return "GainNode";
    }
};

test "Graph: connect nodes validation" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    const node_a = try graph.addNode(GainNode{ .gain = 0.2 });
    const node_b = try graph.addNode(GainNode{ .gain = 0.5 });
    try node_a.connect(node_b);

    try std.testing.expectEqual(graph.edges.items.len, 1);
    try std.testing.expectEqual(graph.edges.items[0].from, node_a.index);
    try std.testing.expectEqual(graph.edges.items[0].to, node_b.index);
}

test "Graph: topological sort validation" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    const node_a = try graph.addNode(GainNode{ .gain = 0.2 });
    const node_b = try graph.addNode(GainNode{ .gain = 0.5 });
    const node_c = try graph.addNode(GainNode{ .gain = 0.3 });

    try node_a.connect(node_b);
    try node_b.connect(node_c);

    var result = try graph.topologicalSortAlloc(allocator);
    defer result.deinit();

    // Verify correct order
    try std.testing.expectEqual(result.nodes.items(.graph_index)[0], node_a.index);
    try std.testing.expectEqual(result.nodes.items(.graph_index)[1], node_b.index);
    try std.testing.expectEqual(result.nodes.items(.graph_index)[2], node_c.index);
}

test "Graph: detect cycles" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    const node_a = try graph.addNode(GainNode{ .gain = 0.2 });
    const node_b = try graph.addNode(GainNode{ .gain = 0.5 });

    try node_a.connect(node_b);
    try node_b.connect(node_a);

    try std.testing.expectError(Graph(f64).GraphError.cycle_detected, graph.topologicalSortAlloc(allocator));
}

test "Graph: complex DAG" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    const nds = [_]Graph(f64).NodeHandle{
        try graph.addNode(GainNode{ .gain = 0.1 }),
        try graph.addNode(GainNode{ .gain = 0.2 }),
        try graph.addNode(GainNode{ .gain = 0.3 }),
        try graph.addNode(GainNode{ .gain = 0.4 }),
    };

    try nds[0].connect(nds[1]);
    try nds[0].connect(nds[2]);
    try nds[1].connect(nds[3]);
    try nds[2].connect(nds[3]);

    var result = try graph.topologicalSortAlloc(allocator);
    defer result.deinit();

    // Verify node 0 comes first and node 3 comes last
    try std.testing.expectEqual(result.nodes.items(.graph_index)[0], nds[0].index);
    try std.testing.expectEqual(result.nodes.items(.graph_index)[3], nds[3].index);
}

test "TopologyQueue: Linear Graph" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    // Create a linear chain: A → B → C → D.
    const node_a = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_b = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_c = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_d = try graph.addNode(GainNode{ .gain = 1.0 });

    try node_b.connect(node_a);
    try node_c.connect(node_b);
    try node_d.connect(node_c);

    var queue = try graph.topologicalSortAlloc(allocator);
    defer queue.deinit();

    const required_buffers = try queue.analyzeBufferRequirementsAlloc();
    try std.testing.expectEqual(1, required_buffers);

    const buff_idx_a = queue.nodes.get(queue.graph_to_queue_index[node_a.index]).buffer_index.?;
    const buff_idx_b = queue.nodes.get(queue.graph_to_queue_index[node_b.index]).buffer_index.?;
    const buff_idx_c = queue.nodes.get(queue.graph_to_queue_index[node_c.index]).buffer_index.?;
    const buff_idx_d = queue.nodes.get(queue.graph_to_queue_index[node_d.index]).buffer_index.?;

    // All nodes share the same buffer.
    try std.testing.expectEqual(buff_idx_a, buff_idx_b);
    try std.testing.expectEqual(buff_idx_b, buff_idx_c);
    try std.testing.expectEqual(buff_idx_c, buff_idx_d);
}

test "TopologyQueue: Independent Nodes Graph" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    // Create two independent nodes.
    const node_a = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_b = try graph.addNode(GainNode{ .gain = 1.0 });

    var queue = try graph.topologicalSortAlloc(allocator);
    defer queue.deinit();

    const required_buffers = try queue.analyzeBufferRequirementsAlloc();
    try std.testing.expectEqual(2, required_buffers);

    const buff_idx_a = queue.nodes.get(queue.graph_to_queue_index[node_a.index]).buffer_index.?;
    const buff_idx_b = queue.nodes.get(queue.graph_to_queue_index[node_b.index]).buffer_index.?;

    try std.testing.expect(buff_idx_a != buff_idx_b);
}

// Parent always shares buffer with it's last connected child
test "TopologyQueue: Multiple Dependencies Graph" {
    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    // Graph structure:
    //         A
    //      /  |  \
    //     B   C   D
    //      \  |  /
    //         E
    const node_a = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_b = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_c = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_d = try graph.addNode(GainNode{ .gain = 1.0 });
    const node_e = try graph.addNode(GainNode{ .gain = 1.0 });

    try node_b.connect(node_a);
    try node_c.connect(node_a);
    try node_d.connect(node_a);
    try node_e.connect(node_b);
    try node_e.connect(node_c);
    try node_e.connect(node_d);

    var queue = try graph.topologicalSortAlloc(allocator);
    defer queue.deinit();

    const required_buffers = try queue.analyzeBufferRequirementsAlloc();
    try std.testing.expectEqual(3, required_buffers);

    const buff_idx_a = queue.nodes.get(queue.graph_to_queue_index[node_a.index]).buffer_index.?;
    const buff_idx_b = queue.nodes.get(queue.graph_to_queue_index[node_b.index]).buffer_index.?;
    const buff_idx_c = queue.nodes.get(queue.graph_to_queue_index[node_c.index]).buffer_index.?;
    const buff_idx_d = queue.nodes.get(queue.graph_to_queue_index[node_d.index]).buffer_index.?;
    const buff_idx_e = queue.nodes.get(queue.graph_to_queue_index[node_e.index]).buffer_index.?;

    try std.testing.expectEqual(0, buff_idx_d);
    try std.testing.expectEqual(1, buff_idx_b);
    try std.testing.expectEqual(2, buff_idx_c);
    try std.testing.expectEqual(0, buff_idx_e);

    try std.testing.expect(buff_idx_a != buff_idx_b);
    try std.testing.expect(buff_idx_a == buff_idx_d);
    try std.testing.expect(buff_idx_e == buff_idx_d);
}

test "TopologyQueue: Complex Graph" {
    // Graph structure:
    //     B  -- C
    //   /   \   |
    // A      D  |
    //   \   / \ |
    //     E     F
    //

    const allocator = std.testing.allocator;
    var graph = Graph(f64).init(allocator, .{});
    defer graph.deinit();

    const node_a = try graph.addNode(GainNode{ .gain = 0.1 });
    const node_b = try graph.addNode(GainNode{ .gain = 0.2 });
    const node_c = try graph.addNode(GainNode{ .gain = 0.3 });
    const node_d = try graph.addNode(GainNode{ .gain = 0.4 });
    const node_e = try graph.addNode(GainNode{ .gain = 0.5 });
    const node_f = try graph.addNode(GainNode{ .gain = 0.5 });

    try node_b.connect(node_a);
    try node_b.connect(node_d);
    try node_b.connect(node_c);

    try node_c.connect(node_f);

    try node_d.connect(node_e);
    try node_d.connect(node_f);

    try node_a.connect(node_e);

    var queue = try graph.topologicalSortAlloc(allocator);
    defer queue.deinit();

    const required_buffers = try queue.analyzeBufferRequirementsAlloc();

    // Check expected number of buffers
    try std.testing.expectEqual(3, required_buffers);

    // Step 1: Collect the queue indices of each node for verification
    var node_queue_indices: std.ArrayList(usize) = .empty;
    defer node_queue_indices.deinit(allocator);
    try node_queue_indices.resize(allocator, graph.nodes.items.len);

    for (queue.nodes.items(.graph_index), 0..) |node_idx, i| {
        node_queue_indices.items[node_idx] = i;
    }

    const q_idx_a = queue.graph_to_queue_index[node_a.index];
    const buff_idx_a = queue.nodes.get(q_idx_a).buffer_index;

    const q_idx_b = queue.graph_to_queue_index[node_b.index];
    const buff_idx_b = queue.nodes.get(q_idx_b).buffer_index;

    const q_idx_c = queue.graph_to_queue_index[node_c.index];
    const buff_idx_c = queue.nodes.get(q_idx_c).buffer_index;

    const q_idx_d = queue.graph_to_queue_index[node_d.index];
    const buff_idx_d = queue.nodes.get(q_idx_d).buffer_index;

    const q_idx_e = queue.graph_to_queue_index[node_e.index];
    const buff_idx_e = queue.nodes.get(q_idx_e).buffer_index;

    const q_idx_f = queue.graph_to_queue_index[node_f.index];
    const buff_idx_f = queue.nodes.get(q_idx_f).buffer_index;

    try std.testing.expectEqual(1, buff_idx_a);
    try std.testing.expectEqual(0, buff_idx_b);
    try std.testing.expectEqual(0, buff_idx_c);
    try std.testing.expectEqual(2, buff_idx_d);
    try std.testing.expectEqual(1, buff_idx_e);
    try std.testing.expectEqual(2, buff_idx_f);

    try std.testing.expect(buff_idx_a != buff_idx_b); // A and B shouldn't share buffers
    try std.testing.expect(buff_idx_b == buff_idx_c); // B and C share buffer 0
    try std.testing.expect(buff_idx_a == buff_idx_e); // A and E share buffer 1
    try std.testing.expect(buff_idx_f == buff_idx_d); // F reuses buffer 2 from D
    try std.testing.expect(buff_idx_d != buff_idx_b); // D should not share buffer with B
}

test {
    _ = bitmap;
    _ = nodes;
    _ = scheduler;
}
