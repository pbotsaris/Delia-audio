const std = @import("std");
const block = @import("block.zig");
const shape = @import("shape.zig");

const AudioBufferError = shape.AudioBufferError;

pub fn OwnedAudioBuffer(comptime T: type) type {
    shape.requireFloat(T, "OwnedAudioBuffer");

    return struct {
        const Self = @This();
        const alignment = shape.storage_alignment.toByteUnits();

        pub const Options = struct {
            channel_count: usize,
            max_frames: usize,
        };

        storage: []align(alignment) T,
        channel_count: usize,
        max_frames: usize,
        channel_stride: usize,

        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            const stride = try shape.strideFor(T, options.max_frames);
            const len = try shape.requiredSamples(.{
                .channel_count = options.channel_count,
                .frame_count = options.max_frames,
                .channel_stride = stride,
            });

            const storage = try allocator.alignedAlloc(T, shape.storage_alignment, len);
            @memset(storage, 0);

            return .{
                .storage = storage,
                .channel_count = options.channel_count,
                .max_frames = options.max_frames,
                .channel_stride = stride,
            };
        }

        /// Unmanaged: the allocator is passed back in, the buffer does not carry one.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = undefined;
        }

        /// Borrow the first `frame_count` frames of the buffer as a block.
        pub fn borrowBlock(self: Self, frame_count: usize) AudioBufferError!block.AudioBlock(T) {
            if (frame_count > self.max_frames) return error.out_of_range;

            return block.AudioBlock(T).init(self.storage, .{
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            });
        }
    };
}

/// N same-shaped slots in one alloc. Never shares samples between slots.
pub fn AudioBufferPool(comptime T: type) type {
    shape.requireFloat(T, "AudioBufferPool");

    return struct {
        const Self = @This();
        const alignment = shape.storage_alignment.toByteUnits();

        pub const Options = struct {
            slot_count: usize,
            channel_count: usize,
            max_frames: usize,
        };

        storage: []align(alignment) T,
        slot_count: usize,
        channel_count: usize,
        max_frames: usize,
        channel_stride: usize,

        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            const stride = try shape.strideFor(T, options.max_frames);
            const per_slot = try shape.requiredSamples(.{
                .frame_count = options.max_frames,
                .channel_count = options.channel_count,
                .channel_stride = stride,
            });

            const len = std.math.mul(usize, per_slot, options.slot_count) catch return error.size_overflow;
            const storage = try allocator.alignedAlloc(T, shape.storage_alignment, len);
            @memset(storage, 0);

            return .{
                .storage = storage,
                .slot_count = options.slot_count,
                .channel_count = options.channel_count,
                .max_frames = options.max_frames,
                .channel_stride = stride,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn borrowSlot(self: Self, index: usize, frame_count: usize) AudioBufferError!block.AudioBlock(T) {
            if (index >= self.slot_count) return error.out_of_range;
            if (frame_count > self.max_frames) return error.out_of_range;

            const per_slot = self.channel_count * self.channel_stride;
            const slot_storage = self.storage[index * per_slot ..][0..per_slot];

            return block.AudioBlock(T).init(slot_storage, .{
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            });
        }
    };
}
