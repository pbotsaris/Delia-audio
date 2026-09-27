const std = @import("std");
const shape = @import("shape.zig");

const AudioBufferError = shape.AudioBufferError;
const Shape = shape.Shape;

pub const Mutability = enum { mutable, constant };

/// Writable borrowed view. No allocator, no destruction.
pub fn AudioBlock(comptime T: type) type {
    return Block(T, .mutable);
}

/// Read-only borrowed view.
pub fn ConstAudioBlock(comptime T: type) type {
    return Block(T, .constant);
}

fn Block(comptime T: type, comptime mutability: Mutability) type {
    shape.requireFloat(T, "AudioBlock");

    return struct {
        const Self = @This();

        pub const Samples = switch (mutability) {
            .mutable => []T,
            .constant => []const T,
        };

        samples: Samples,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn init(samples: Samples, block_shape: Shape) AudioBufferError!Self {
            const required_size = try shape.requiredSamples(block_shape);
            if (samples.len < required_size) return error.storage_too_small;

            return .{
                .samples = samples[0..required_size],
                .channel_count = block_shape.channel_count,
                .frame_count = block_shape.frame_count,
                .channel_stride = block_shape.channel_stride,
            };
        }

        pub fn channel(self: Self, channel_index: usize) Samples {
            std.debug.assert(channel_index < self.channel_count);
            return self.samples[channel_index * self.channel_stride ..][0..self.frame_count];
        }

        /// Same storage and stride, fewer valid frames.
        pub fn subBlock(self: Self, start_frame: usize, frame_count: usize) AudioBufferError!Self {
            const end = std.math.add(usize, start_frame, frame_count) catch return error.out_of_range;
            if (end > self.frame_count) return error.out_of_range;

            return .{
                // shifting the base keeps channel(channel_index) = base + channel_index * stride valid
                .samples = self.samples[start_frame..],
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            };
        }

        /// One way only: a const block never becomes writable again.
        pub fn asConst(self: Self) ConstAudioBlock(T) {
            return .{
                .samples = self.samples,
                .channel_count = self.channel_count,
                .frame_count = self.frame_count,
                .channel_stride = self.channel_stride,
            };
        }
    };
}
