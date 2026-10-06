const node = @import("../node.zig");
const dsp = @import("dsp");

pub fn SineNode(comptime T: type) type {
    const GenericNode = node.GenericNode(T);

    return struct {
        wave: dsp.waves.Wave(T),

        const Self = @This();
        const PrepareContext = GenericNode.PrepareContext;
        const ProcessContext = GenericNode.ProcessContext;
        const Error = node.NodeError;

        pub fn init(freq: T, amp: T, sr: T) Self {
            return .{
                .wave = dsp.waves.Wave(T).init(freq, amp, sr),
            };
        }

        pub fn name(_: *Self) []const u8 {
            return "SineNode";
        }

        pub fn process(self: *Self, ctx: ProcessContext) void {
            for (0..ctx.buffer.block_size) |frame_index| {
                const sample = self.wave.sineSample();

                for (0..ctx.buffer.n_channels) |ch_index| {
                    ctx.buffer.writeSample(ch_index, frame_index, sample);
                }
            }
        }

        pub fn prepare(self: *Self, ctx: PrepareContext) Error!void {
            self.wave.setSampleRate(ctx.sample_rate);
        }
    };
}
