pub const nodes = @import("nodes/nodes.zig");
pub const Node = @import("nodes/node.zig").Node;

test {
    _ = @import("nodes/nodes.zig");
    _ = @import("nodes/node.zig");
}
