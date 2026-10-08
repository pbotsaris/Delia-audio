//! Node contract: docs/graph-contract.md section 2, docs/buffer-contract.md section 8.
//! `Node(T)` is the type-erased wrapper the builder stores and the plan calls. Port counts
//! and the name are comptime declarations on the implementing struct, checked in `init`.

const std = @import("std");
const buffer = @import("buffer");
const specs = @import("common").audio_specs;

pub const Ports = struct {
    inputs: u8,
    outputs: u8,
};

pub const NodeError = error{
    allocation_error,
};

pub fn Node(comptime T: type) type {
    buffer.requireFloat(T, "Node");

    return struct {
        const Self = @This();

        pub const PrepareContext = struct {
            sample_rate: T,
            max_frames: specs.BlockSize,
            channel_count: usize,
        };

        /// One block per port. Every block has `frame_count == ctx.frame_count`; outputs are
        /// disjoint from inputs and from each other; a node writes every active frame of every
        /// output.
        pub const ProcessContext = struct {
            inputs: []const buffer.ConstAudioBlock(T),
            outputs: []const buffer.AudioBlock(T),
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

        /// Heap-copies `node` so the builder can hand out stable pointers. Paired with `destroy`.
        pub fn createNode(allocator: std.mem.Allocator, node: anytype) std.mem.Allocator.Error!Self {
            const ptr = try allocator.create(@TypeOf(node));
            ptr.* = node;

            return init(ptr);
        }

        fn checkPtrType(comptime PtrType: type) void {
            const ptr_info = @typeInfo(PtrType);

            if (ptr_info != .pointer) {
                @compileError("Node.init requires a pointer type to instantiate.");
            }

            if (ptr_info.pointer.size != .one) {
                @compileError("Node.init requires a pointer to a single struct to instantiate.");
            }
        }

        fn checkImpl(comptime Impl: type) void {
            const impl_name = @typeName(Impl);

            if (!@hasDecl(Impl, "ports")) {
                @compileError(impl_name ++ " must declare `pub const ports: Ports`.");
            }

            if (@TypeOf(Impl.ports) != Ports) {
                @compileError(impl_name ++ ".ports must be of type `Ports`.");
            }

            if (!@hasDecl(Impl, "name")) {
                @compileError(impl_name ++ " must declare `pub const name: []const u8`.");
            }

            if (@TypeOf(Impl.name) != []const u8) {
                @compileError(impl_name ++ ".name must be of type `[]const u8`.");
            }

            inline for (.{ "prepare", "process" }) |decl| {
                if (!@hasDecl(Impl, decl)) {
                    @compileError(impl_name ++ " must implement `" ++ decl ++ "`.");
                }
            }
        }

        /// Wraps an existing single-item pointer. All interface checks happen here, at comptime.
        pub fn init(ptr: anytype) Self {
            const PtrType = @TypeOf(ptr);
            const Impl = @TypeOf(ptr.*);

            checkPtrType(PtrType);
            checkImpl(Impl);

            const gen = struct {
                fn prepareFn(ctx: *anyopaque, prepare_ctx: PrepareContext) NodeError!void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    try self.prepare(prepare_ctx);
                }

                fn processFn(ctx: *anyopaque, process_ctx: ProcessContext) void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    self.process(process_ctx);
                }

                fn destroyFn(allocator: std.mem.Allocator, ctx: *anyopaque) void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    allocator.destroy(self);
                }

                const vtable = VTable{
                    .prepare = prepareFn,
                    .process = processFn,
                    .destroy = destroyFn,
                };
            };

            return .{
                .ptr = ptr,
                .vtable = &gen.vtable,
                .ports = Impl.ports,
                .name = Impl.name,
            };
        }

        pub fn prepare(self: Self, ctx: PrepareContext) NodeError!void {
            try self.vtable.prepare(self.ptr, ctx);
        }

        pub fn process(self: Self, ctx: ProcessContext) void {
            std.debug.assert(ctx.inputs.len == self.ports.inputs);
            std.debug.assert(ctx.outputs.len == self.ports.outputs);

            self.vtable.process(self.ptr, ctx);
        }

        /// Only for nodes made by `createNode`. The builder calls this from its `deinit`.
        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            self.vtable.destroy(allocator, self.ptr);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: the wrapper itself, with two throwaway nodes. Real nodes test themselves.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectAll(comptime T: type, expected: T, actual: []const T) !void {
    for (actual) |sample| try testing.expectEqual(expected, sample);
}

const TestConstant = struct {
    value: f32,
    prepare_calls: usize = 0,
    last_sample_rate: f32 = 0,

    pub const ports: Ports = .{ .inputs = 0, .outputs = 1 };
    pub const name: []const u8 = "TestConstant";

    pub fn prepare(self: *TestConstant, ctx: Node(f32).PrepareContext) NodeError!void {
        self.prepare_calls += 1;
        self.last_sample_rate = ctx.sample_rate;
    }

    pub fn process(self: *TestConstant, ctx: Node(f32).ProcessContext) void {
        for (ctx.outputs) |out| {
            for (0..out.channel_count) |ch| @memset(out.channel(ch), self.value);
        }
    }
};

const TestScale = struct {
    scale: f64,

    pub const ports: Ports = .{ .inputs = 1, .outputs = 1 };
    pub const name: []const u8 = "TestScale";

    pub fn prepare(_: *TestScale, _: Node(f64).PrepareContext) NodeError!void {}

    pub fn process(self: *TestScale, ctx: Node(f64).ProcessContext) void {
        for (0..ctx.outputs[0].channel_count) |ch| {
            for (ctx.outputs[0].channel(ch), ctx.inputs[0].channel(ch)) |*o, i| o.* = i * self.scale;
        }
    }
};

const test_prepare_ctx: Node(f32).PrepareContext = .{
    .sample_rate = 48000,
    .max_frames = .blk_16,
    .channel_count = 2,
};

test "Node - init reads ports and name from the implementation" {
    var constant = TestConstant{ .value = 1 };
    const node = Node(f32).init(&constant);

    try testing.expectEqual(Ports{ .inputs = 0, .outputs = 1 }, node.ports);
    try testing.expectEqualStrings("TestConstant", node.name);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&constant)), node.ptr);
}

test "Node - prepare and process dispatch to the implementation" {
    var owned = try buffer.OwnedAudioBuffer(f32).init(testing.allocator, .{ .channel_count = 2, .max_frames = 8 });
    defer owned.deinit(testing.allocator);

    var constant = TestConstant{ .value = 0.25 };
    const node = Node(f32).init(&constant);

    try node.prepare(test_prepare_ctx);
    try testing.expectEqual(1, constant.prepare_calls);
    try testing.expectEqual(48000, constant.last_sample_rate);

    // prepare is repeatable: a second compile with a new rate must be honoured
    try node.prepare(.{ .sample_rate = 96000, .max_frames = .blk_16, .channel_count = 2 });
    try testing.expectEqual(2, constant.prepare_calls);
    try testing.expectEqual(96000, constant.last_sample_rate);

    const out = try owned.borrowBlock(8);
    node.process(.{ .inputs = &.{}, .outputs = &.{out}, .frame_count = 8 });

    for (0..2) |ch| try expectAll(f32, 0.25, out.channel(ch));
}

test "Node - separate input and output over a partial block, input untouched" {
    var pool = try buffer.AudioBufferPool(f64).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    // sentinel over the full capacity of the output, then process only 5 frames
    const full_out = try pool.borrowSlot(1, 16);
    for (0..2) |ch| @memset(full_out.channel(ch), 9);

    const in = try pool.borrowSlot(0, 5);
    const out = try pool.borrowSlot(1, 5);
    for (0..2) |ch| @memset(in.channel(ch), 1);

    var scale = TestScale{ .scale = 0.5 };
    const node = Node(f64).init(&scale);
    node.process(.{ .inputs = &.{in.asConst()}, .outputs = &.{out}, .frame_count = 5 });

    for (0..2) |ch| {
        try expectAll(f64, 0.5, full_out.channel(ch)[0..5]);
        try expectAll(f64, 9, full_out.channel(ch)[5..]);
        try expectAll(f64, 1, in.channel(ch));
    }
}

test "Node - createNode heap-copies, destroy frees, state lives on the heap copy" {
    const node = try Node(f32).createNode(testing.allocator, TestConstant{ .value = 2 });
    defer node.destroy(testing.allocator);

    try testing.expectEqualStrings("TestConstant", node.name);

    try node.prepare(test_prepare_ctx);
    const impl: *TestConstant = @ptrCast(@alignCast(node.ptr));
    try testing.expectEqual(1, impl.prepare_calls);
}

fn createAndDestroy(allocator: std.mem.Allocator) !void {
    const node = try Node(f32).createNode(allocator, TestConstant{ .value = 0 });
    node.destroy(allocator);
}

test "Node - createNode reports allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, createAndDestroy, .{});
}
