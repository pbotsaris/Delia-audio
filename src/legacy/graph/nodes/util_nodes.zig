const node_interface = @import("node_interface.zig");
const std = @import("std");

pub fn GainNode(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("GainNode operates on f32 or f64");
    }

    const GenericNode = node_interface.GenericNode(T);

    return struct {
        gain: T,

        const Self = @This();
        const PrepareContext = GenericNode.PrepareContext;
        const ProcessContext = GenericNode.ProcessContext;
        const Error = node_interface.NodeError;

        pub fn name(_: *Self) []const u8 {
            return "GainNode";
        }

        pub fn process(self: *Self, ctx: ProcessContext) void {
            for (0..ctx.buffer.block_size) |frame_index| {
                for (0..ctx.buffer.n_channels) |ch_index| {
                    const sample = ctx.buffer.readSample(ch_index, frame_index);
                    ctx.buffer.writeSample(ch_index, frame_index, sample * self.gain);
                }
            }
        }

        pub fn prepare(_: *Self, _: PrepareContext) Error!void {}
    };
}
