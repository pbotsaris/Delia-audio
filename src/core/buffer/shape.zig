const std = @import("std");

pub const AudioBufferError = error{
    zero_channels,
    frames_exceed_stride,
    storage_too_small,
    out_of_range,
    size_overflow,
    shape_mismatch,
    forbidden_overlap,
};

pub const Shape = struct {
    channel_count: usize,
    frame_count: usize,
    channel_stride: usize,
};

/// Channel starts in owned storage are aligned to this many bytes.
pub const storage_alignment: std.mem.Alignment = .@"64";

pub fn requireFloat(comptime T: type, comptime name: []const u8) void {
    if (T != f32 and T != f64) @compileError(name ++ " only supports f32 and f64");
}

/// Round a frame capacity up so that every channel start lands on `storage_alignment`.
pub fn strideFor(comptime T: type, max_frames: usize) AudioBufferError!usize {
    const samples_per_unit = storage_alignment.toByteUnits() / @sizeOf(T);
    const padded = std.math.add(usize, max_frames, samples_per_unit - 1) catch return error.size_overflow;

    return padded - (padded % samples_per_unit);
}

/// Samples a block of this shape spans. Depends on the stride, not on the valid frame count.
pub fn requiredSamples(shape: Shape) AudioBufferError!usize {
    if (shape.channel_count == 0) return error.zero_channels;
    if (shape.frame_count > shape.channel_stride) return error.frames_exceed_stride;

    return std.math.mul(usize, shape.channel_count, shape.channel_stride) catch return error.size_overflow;
}
