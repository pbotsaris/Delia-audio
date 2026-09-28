const std = @import("std");
const Node = @import("nodes/node.zig").Node;
const buffer = @import("../core/buffer/buffer.zig");
const specs = @import("../common/audio_specs.zig");

pub const Slot = u32;

/// What the render loop will execute.
/// Slots index the pool
/// `process` slices points into the plan's `slots_refs` backing array.
///  Once is done, there is nothing to look up at render time.
pub const Op = union(enum) {
    clear: Slot,
    accumulate: struct { dst: Slot, src: Slot },
    process: struct { node: u32, inputs: []const Slot, outputs: []const Slot },
    copy_out: Slot,
};

pub fn ExecutionPlan(comptime T: type) type {
    return struct {
        const Self = @This();
        const BufferError = buffer.AudioBufferError;

        nodes: []Node(T),
        ops: []const Op,
        slot_refs: []Slot,
        pool: buffer.AudioBufferPool(T),
        scratch: struct {
            in: []buffer.ConstAudioBlock(T),
            out: []buffer.AudioBlock(T),
        },
        max_frames: specs.BlockSize,
        channel_count: usize,

        pub fn render(self: *Self, output: buffer.AudioBlock(T)) error{shape_mismatch}!void {
            const frame = output.frame_count;

            if (output.channel_count != self.channel_count) return error.shape_mismatch;
            if (frame > self.max_frames.toUsize()) return error.shape_mismatch;

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
