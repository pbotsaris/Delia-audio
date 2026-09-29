//! Execution plan: what the compiler produces and the render path runs.
//! Contract: docs/graph-contract.md section 5. Built by `Compiler(T).compile`.

const std = @import("std");
const Node = @import("node.zig").Node;
const buffer = @import("../core/buffer/buffer.zig");
const specs = @import("../common/audio_specs.zig");

/// Index of a block in the plan's pool.
pub const Slot = u32;

/// One step of the render loop. Everything an op needs is in the op, so nothing is looked up at render time.
pub const Op = union(enum) {
    /// Zero a mix slot before accumulating into it.
    clear: Slot,
    /// `dst += src`: one producer's contribution to a mix slot.
    accumulate: struct { dst: Slot, src: Slot },
    /// Run a node. `inputs` and `outputs` are slices of the plan's `slot_refs`.
    process: struct { node: u32, inputs: []const Slot, outputs: []const Slot },
    /// Copy the graph output into the caller's block. Always the last op.
    copy_out: Slot,
};

/// Owns the pool, the op list and its scratch. Borrows the node state from the builder, so
/// it is released before the builder. Not reentrant: one render thread per plan.
pub fn ExecutionPlan(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Copies of the builder's wrappers; the node state itself stays in the builder.
        nodes: []Node(T),
        ops: []const Op,
        /// Backing array for the `process` ops' slot slices.
        slot_refs: []Slot,
        /// Pool of audio blocks for the plan's nodes and mix slots. T
        pool: buffer.AudioBufferPool(T),
        /// Block lists handed to a node, refilled per `process` op. Sized to the widest node.
        scratch: struct {
            in: []buffer.ConstAudioBlock(T),
            out: []buffer.AudioBlock(T),
        },
        /// What the plan was prepared for. `max_frames` is a capacity, not a block length.
        sample_rate: T,
        max_frames: specs.BlockSize,
        channel_count: usize,

        /// Renders `output.frame_count` frames into `output`, which may be any length up to
        /// `max_frames` and must have the plan's channel count; otherwise `shape_mismatch`
        /// and nothing is written. Zero frames is a no-op.
        ///
        /// Does not allocate, lock or log. Block-op errors are unreachable here: the compiler
        /// proved every shape and pool slots are disjoint.
        pub fn render(self: *Self, output: buffer.AudioBlock(T)) error{shape_mismatch}!void {
            const frame = output.frame_count;

            if (output.channel_count != self.channel_count) return error.shape_mismatch;
            if (frame > self.max_frames.toUsize()) return error.shape_mismatch;
            if (frame == 0) return;

            for (self.ops) |op| switch (op) {
                .clear => |slot| {
                    buffer.clear(T, self.getSlotAudioBlock(slot, frame));
                },
                .accumulate => |acc| {
                    const dst_block = self.getSlotAudioBlock(acc.dst, frame);
                    const src_block = self.getSlotAudioBlock(acc.src, frame).asConst();
                    buffer.accumulate(T, dst_block, src_block) catch unreachable;
                },

                .process => |proc| {
                    for (proc.inputs, 0..) |sample, i| {
                        self.scratch.in[i] = self.getSlotAudioBlock(sample, frame).asConst();
                    }

                    for (proc.outputs, 0..) |sample, i| {
                        self.scratch.out[i] = self.getSlotAudioBlock(sample, frame);
                    }

                    const ctx = Node(T).ProcessContext{
                        .inputs = self.scratch.in[0..proc.inputs.len],
                        .outputs = self.scratch.out[0..proc.outputs.len],
                        .frame_count = frame,
                    };

                    self.nodes[proc.node].process(ctx);
                },
                .copy_out => |slot| {
                    const out_block = self.getSlotAudioBlock(slot, frame).asConst();
                    buffer.copy(T, output, out_block) catch unreachable;
                },
            };
        }

        fn getSlotAudioBlock(self: *Self, slot: Slot, at_frame: usize) buffer.AudioBlock(T) {
            return self.pool.borrowSlot(slot, at_frame) catch unreachable;
        }

        /// Same allocator as `compile`. Call outside the render path, before the builder's `deinit`.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.pool.deinit(allocator);
            allocator.free(self.scratch.out);
            allocator.free(self.scratch.in);
            allocator.free(self.slot_refs);
            allocator.free(self.ops);
            allocator.free(self.nodes);
            self.* = undefined;
        }
    };
}
