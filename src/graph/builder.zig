const std = @import("std");
const buffer = @import("../core/buffer/buffer.zig");
const specs = @import("../common/audio_specs.zig");
const nodes = @import("./nodes/nodes.zig");
const Node = @import("./nodes/node.zig").Node;

pub const Edge = struct {
    pub const PortRef = struct {
        node: u32,
        port: u8,
    };

    from: PortRef,
    to: PortRef,
};

pub const NodeHandle = struct {
    index: u32,
};

pub const BuilderError = error{ invalid_handle, port_out_of_range } || std.mem.Allocator.Error;

/// Graph builder is mutable only at editing time.
/// owns the node healp; a plan borrows them.
/// nothing can be done while a plan is rendering.
/// First must stop, edit, recompile, and then start again.
pub fn GraphBuilder(comptime T: type) type {
    buffer.requireFloat(T, "GraphBuilder");

    return struct {
        const Self = @This();
        const PortRef = Edge.PortRef;

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node(T)) = .empty,
        edges: std.ArrayList(Edge) = .empty,

        /// Producers feeding the graph output, in insertion order.
        /// More than one output means a mix.
        outputs: std.ArrayList(Edge.PortRef) = .empty,

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

        pub fn addNode(self: *Self, impl: anytype) BuilderError!NodeHandle {
            const node = try Node(T).createNode(self.allocator, impl);
            errdefer node.destroy(self.allocator);

            try self.nodes.append(self.allocator, node);
            return .{ .index = @intCast(self.nodes.items.len - 1) };
        }

        pub fn connect(self: *Self, from: NodeHandle, to: NodeHandle) BuilderError!void {
            const from_port: PortRef = .{ .node = from.index, .port = 0 };
            const to_port: PortRef = .{ .node = to.index, .port = 0 };

            try self.connectPorts(from_port, to_port);
        }

        pub fn connectPorts(self: *Self, from: PortRef, to: PortRef) BuilderError!void {
            const producer = try self.getNode(from.node);
            const consumer = try self.getNode(to.node);

            if (from.port >= producer.ports.outputs) return BuilderError.port_out_of_range;
            if (to.port >= consumer.ports.inputs) return BuilderError.port_out_of_range;

            try self.edges.append(self.allocator, .{ .from = from, .to = to });
        }

        pub fn connectOutput(self: *Self, from: NodeHandle) BuilderError!void {
            const producer = try self.getNode(from.index);

            if (producer.ports.outputs == 0) return BuilderError.port_out_of_range;

            try self.outputs.append(self.allocator, .{ .node = from.index, .port = 0 });
        }

        fn getNode(self: Self, node_index: u32) BuilderError!Node(T) {
            if (node_index >= self.nodes.items.len) return BuilderError.invalid_handle;

            return self.nodes.items[node_index];
        }
    };
}
