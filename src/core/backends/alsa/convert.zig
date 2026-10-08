const std = @import("std");
const buffer = @import("buffer");

const ConstAudioBlock = buffer.ConstAudioBlock;
const AudioBlock = buffer.AudioBlock;

pub const SampleFormat = enum {
    s16_le,
    f32_le,
};

pub const ConvertError = error{size_mismatch};

pub fn SampleConverter(comptime fmt: SampleFormat) type {
    return struct {
        pub const format = fmt;
        pub const bytes_per_sample: usize = switch (fmt) {
            .s16_le => 2,
            .f32_le => 4,
        };

        /// Device bytes for `frame_count` frames and `channel_count` channels for either layout
        pub fn byteLength(channel_count: usize, frame_count: usize) usize {
            return frame_count * channel_count * bytes_per_sample;
        }

        /// Encodes a single sample into the destination buffer. The destination buffer must be at least `bytes_per_sample` bytes long.
        pub inline fn encode(dst: *[bytes_per_sample]u8, sample: f32) void {
            switch (fmt) {
                .s16_le => {
                    const clamped = std.math.clamp(sample, -1.0, 1.0);
                    const scaled: i16 = @intFromFloat(@round(clamped * std.math.maxInt(i16)));
                    // little endian write
                    std.mem.writeInt(i16, dst, scaled, .little);
                },
                .f32_le => std.mem.writeInt(u32, dst, @bitCast(sample), .little),
            }
        }

        /// Decodes a single sample from the source buffer. The source buffer must be at least `bytes_per_sample` bytes long.
        pub inline fn decode(src: *const [bytes_per_sample]u8) f32 {
            return switch (fmt) {
                .s16_le => @as(f32, @floatFromInt(std.mem.readInt(i16, src, .little))) / std.math.maxInt(i16),
                .f32_le => @as(f32, @bitCast(std.mem.readInt(u32, src, .little))),
            };
        }

        pub fn writeInterleaved(dst: []u8, src: ConstAudioBlock(f32)) ConvertError!void {
            if (dst.len != byteLength(src.channel_count, src.frame_count)) return ConvertError.size_mismatch;

            const bytes_per_frame = src.channel_count * bytes_per_sample;

            for (0..src.channel_count) |ch| {
                var at = ch * bytes_per_sample;

                for (src.channel(ch)) |sample| {
                    encode(dst[at..][0..bytes_per_sample], sample);
                    at += bytes_per_frame;
                }
            }
        }

        pub fn readInterleaved(dst: AudioBlock(f32), src: []const u8) ConvertError!void {
            if (src.len != byteLength(dst.channel_count, dst.frame_count)) return ConvertError.size_mismatch;

            const bytes_per_frame = dst.channel_count * bytes_per_sample;

            for (0..dst.channel_count) |ch| {
                var at = ch * bytes_per_sample;

                for (dst.channel(ch)) |*sample| {
                    sample.* = decode(src[at..][0..bytes_per_sample]);
                    at += bytes_per_frame;
                }
            }
        }
    };
}
