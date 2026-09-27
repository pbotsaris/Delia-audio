//! Operations over blocks. None of these allocate, log, or touch samples outside active frames.
//! A failed operation writes nothing.

const std = @import("std");
const block = @import("block.zig");
const shape = @import("shape.zig");

const AudioBlock = block.AudioBlock;
const ConstAudioBlock = block.ConstAudioBlock;
const AudioBufferError = shape.AudioBufferError;

/// True when any active sample is reachable through both blocks. Compares channel by channel,
/// so two sub-blocks covering different frame ranges of one parent do not overlap.
pub fn blocksOverlap(comptime T: type, a: ConstAudioBlock(T), b: ConstAudioBlock(T)) bool {
    for (0..a.channel_count) |a_ch| {
        for (0..b.channel_count) |b_ch| {
            if (slicesOverlap(T, a.channel(a_ch), b.channel(b_ch))) return true;
        }
    }

    return false;
}

pub fn clear(comptime T: type, dst: AudioBlock(T)) void {
    for (0..dst.channel_count) |ch| {
        @memset(dst.channel(ch), 0);
    }
}

/// dst = src. Same shape, disjoint storage. Strides may differ.
pub fn copy(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) AudioBufferError!void {
    try requireSameShape(T, dst, src);

    if (blocksOverlap(T, dst.asConst(), src)) return error.forbidden_overlap;

    for (0..dst.channel_count) |ch| {
        @memcpy(dst.channel(ch), src.channel(ch));
    }
}

/// dst += src. Same shape, disjoint storage. Strides may differ.
pub fn accumulate(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) AudioBufferError!void {
    try requireSameShape(T, dst, src);

    if (blocksOverlap(T, dst.asConst(), src)) return error.forbidden_overlap;

    for (0..dst.channel_count) |ch| {
        for (dst.channel(ch), src.channel(ch)) |*dst_sample, src_sample| {
            dst_sample.* += src_sample; // this is mixing, so we add the samples together
        }
    }
}

/// Planar block ->  packed interleaved frames
/// e.g. channels [L0, L1, L2] and [R0, R1, R2] -> [L0, R0, L1, R1, L2, R2]
pub fn interleave(comptime T: type, dst: []T, src: ConstAudioBlock(T)) AudioBufferError!void {
    // dst is packed interleaved, src is planar, so we can't use requireSameShape here
    if (dst.len != src.channel_count * src.frame_count) return error.shape_mismatch;

    for (0..src.channel_count) |ch| {
        if (slicesOverlap(T, dst, src.channel(ch))) return error.forbidden_overlap;
    }

    for (0..src.channel_count) |ch| {
        for (src.channel(ch), 0..) |sample, frame| {
            dst[frame * src.channel_count + ch] = sample;
        }
    }
}

/// Packed interleaved frames -> planar block
/// e.g. [L0, R0, L1, R1, L2, R2] -> channels [L0, L1, L2] and [R0, R1, R2]
pub fn deinterleave(comptime T: type, dst: AudioBlock(T), src: []const T) AudioBufferError!void {
    if (src.len != dst.channel_count * dst.frame_count) return error.shape_mismatch;

    for (0..dst.channel_count) |ch| {
        if (slicesOverlap(T, dst.channel(ch), src)) return error.forbidden_overlap;
    }

    for (0..dst.channel_count) |ch| {
        for (dst.channel(ch), 0..) |*dst_sample, frame| {
            dst_sample.* = src[frame * dst.channel_count + ch];
        }
    }
}

// Private helpers

fn slicesOverlap(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len == 0 or b.len == 0) return false;

    const a_start = @intFromPtr(a.ptr); // address
    const b_start = @intFromPtr(b.ptr);

    const a_end = a_start + a.len * @sizeOf(T);
    const b_end = b_start + b.len * @sizeOf(T);

    return a_start < b_end and b_start < a_end;
}

fn requireSameShape(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) AudioBufferError!void {
    if (dst.channel_count != src.channel_count) return error.shape_mismatch;
    if (dst.frame_count != src.frame_count) return error.shape_mismatch;
}
