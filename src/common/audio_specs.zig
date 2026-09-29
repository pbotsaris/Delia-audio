const std = @import("std");
const builtin = @import("builtin");

pub const BufferSize = enum(usize) {
    const Self = @This();
    buf_128 = 128,
    buf_256 = 256,
    buf_512 = 512,
    buf_1024 = 1024,
    buf_2048 = 2048,
    buf_4096 = 4096,

    pub inline fn toFloat(self: Self, T: type) T {
        return @floatFromInt(@as(usize, @intFromEnum(self)));
    }
};

pub const BlockSize = enum(usize) {
    const Self = @This();

    // small blocks are use in tests
    blk_4 = 4,
    blk_8 = 8,
    blk_16 = 16,
    blk_32 = 32,
    blk_64 = 64,
    blk_128 = 128,
    blk_256 = 256,
    blk_512 = 512,
    blk_1024 = 1024,
    blk_2048 = 2048,
    pub inline fn toFloat(self: Self, T: type) T {
        return @floatFromInt(@as(usize, @intFromEnum(self)));
    }

    pub inline fn toUsize(self: Self) usize {
        return @as(usize, @intFromEnum(self));
    }
};

pub const SampleRate = enum(usize) {
    const Self = @This();

    sr_44100 = 44100,
    sr_48000 = 48000,
    sr_96000 = 96000,
    sr_192000 = 192000,

    pub inline fn toFloat(self: Self, T: type) T {
        return @floatFromInt(@as(usize, @intFromEnum(self)));
    }

    pub inline fn toUsize(self: Self) usize {
        return @as(usize, @intFromEnum(self));
    }
};

test "AudioSpecs" {
    const buf_64 = BufferSize.buf_1024;
    try std.testing.expectEqual(buf_64.toFloat(f32), 1024.0);

    const blk_64 = BlockSize.blk_64;
    try std.testing.expectEqual(blk_64.toFloat(f32), 64.0);

    const sr_44100 = SampleRate.sr_44100;
    try std.testing.expectEqual(sr_44100.toFloat(f32), 44100.0);
}
