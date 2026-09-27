const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

const FormatType = @import("settings.zig").FormatType;
const Format = @import("format.zig").Format;

pub const AudioDataError = error{
    invalid_type,
    invalid_size,
    invalid_float_range,
    out_of_bounds,
    unexpected_buffer_size,
};

pub fn GenericAudioData(format_type: FormatType) type {
    return struct {
        const Self = @This();

        const T = format_type.ToType();

        format: Format(T),
        channels: u32,
        sample_rate: u32,
        data: []u8,
        position: usize,

        // GenericAudioData will always expose sample as floats to the callers
        // We must be mindful of the precision loss, so for 24 and 32 bits audio, we use f64 precision.
        pub fn FloatType() type {
            return switch (T) {
                f64, u32, i32 => f64,
                else => f32,
            };
        }

        pub fn init(data: []u8, channels: u32, sample_rate: u32, format: Format(T)) Self {
            return Self{
                .format = format,
                .channels = channels,
                .sample_rate = sample_rate,
                .data = data,
                .position = 0,
            };
        }

        pub inline fn writeSample(self: *Self, sample: FloatType()) AudioDataError!void {
            const sample_size = @sizeOf(T);

            if (sample_size != self.format.byte_rate) {
                return AudioDataError.invalid_size;
            }

            if (!self.hasSpace(sample_size)) return AudioDataError.out_of_bounds;

            var bytes: [sample_size]u8 = undefined;
            const endianness: std.builtin.Endian = if (self.format.byte_order == .big_endian) .big else .little;

            switch (T) {
                f32, f64 => writeFloat(&bytes, sample, endianness),
                else => std.mem.writeInt(T, &bytes, linearMapIn(sample), endianness),
            }

            @memcpy(self.data[self.position .. self.position + sample_size], &bytes);
            self.position += sample_size;
        }

        pub fn write(self: *Self, samples: []FloatType()) AudioDataError!void {
            for (samples) |sample| {
                try writeSample(self, sample);
            }
        }

        pub fn readSample(self: *Self) ?FloatType() {
            if (self.data.len == 0) return null;
            if (self.position >= self.data.len) return null;

            const actual_sample_size: usize = @sizeOf(T);

            var sample_buffer: [actual_sample_size]u8 = undefined;
            @memcpy(&sample_buffer, self.data[self.position .. self.position + actual_sample_size]);

            const endianness: std.builtin.Endian = if (self.format.byte_order == .big_endian) .big else .little;

            const sample: FloatType() = switch (T) {
                f32, f64 => readFloat(&sample_buffer, endianness),
                else => linearMapOut(std.mem.readInt(T, &sample_buffer, endianness)),
            };

            self.position += actual_sample_size;

            return sample;
        }

        pub fn readAllAlloc(self: *Self, allocator: std.mem.Allocator) !?[]FloatType() {
            if (self.data.len == 0) return null;
            if (self.position >= self.data.len) return null;

            const sample_size_as_float = @sizeOf(FloatType());
            const actual_sample_size = @sizeOf(T);

            // if the sample size is not a multiple of the data length, there is a bug. It should never happen
            if (self.data.len % actual_sample_size != 0) {
                return AudioDataError.unexpected_buffer_size;
            }

            const samples_len = @divFloor(self.data.len, sample_size_as_float);
            var samples = try allocator.alloc(FloatType(), samples_len);

            for (0..samples_len) |sample_index| {
                const sample: FloatType() = self.readSample() orelse return samples;
                samples[sample_index] = sample;
            }

            return samples;
        }

        pub fn readAll(self: *Self, samples: []FloatType()) ![]FloatType() {
            if (self.data.len == 0) return samples;

            const sample_size_as_float = @sizeOf(FloatType());
            const actual_sample_size = @sizeOf(T);

            // if the sample size is not a multiple of the data length, there is a bug. It should never happen
            if (self.data.len % actual_sample_size != 0) {
                return AudioDataError.unexpected_buffer_size;
            }

            const samples_len = @divFloor(self.data.len, sample_size_as_float);

            if (samples.len < samples_len) {
                return AudioDataError.invalid_size;
            }

            for (0..samples_len) |sample_index| {
                const sample: FloatType() = self.readSample() orelse return samples;
                samples[sample_index] = sample;
            }

            return samples;
        }

        pub fn rewind(self: *Self) void {
            self.position = 0;
        }

        pub fn bufferSizeInSamples(self: Self) usize {
            return @divFloor(self.data.len, @sizeOf(T));
        }

        pub fn bufferSizeInFrames(self: Self) usize {
            return @divFloor(self.bufferSizeInSamples(), self.channels);
        }

        pub fn totalSampleCount(self: Self) usize {
            return self.bufferSizeInSamples() * self.channels;
        }

        pub fn seek(self: *Self, sample_position: usize) !void {
            const sample_size = @sizeOf(T);
            const new_position = sample_position * sample_size;

            if (new_position >= self.data.len) {
                return AudioDataError.out_of_bounds;
            }

            self.position = new_position;
        }

        // maps [-1.0 - 1.0] float to the format type value and range
        fn linearMapIn(sample: FloatType()) T {
            const max: FloatType() = if (T != f32 and T != f64) @floatFromInt(std.math.maxInt(T)) else 0.0;
            const signed_max = if (sample > 0) max else max + 1.0;

            return switch (T) {
                f32, f64 => sample,
                i8, i16, i32 => @as(T, @intFromFloat(sample * signed_max)),
                u8, u16, u32 => @as(T, @intFromFloat((sample + 1.0) / 2.0 * max)),
                else => @compileError("Invalid AudioData Format Type"),
            };
        }

        fn linearMapOut(sample: T) FloatType() {
            const max: FloatType() = if (T != f32 and T != f64) @floatFromInt(std.math.maxInt(T)) else 0.0;
            const signed_max = if (sample > 0) max else max + 1.0;

            return switch (T) {
                f32, f64 => sample,
                i8, i16, i32 => return @as(FloatType(), @floatFromInt(sample)) / signed_max,
                u8, u16, u32 => return (@as(FloatType(), @floatFromInt(sample)) / max * 2.0) - 1.0,
                else => @compileError("Invalid AudioData Format Type"),
            };
        }

        fn hasSpace(self: Self, sample_size: i32) bool {
            // cast to signed to prevent wrapping when negative
            const len: i32 = @intCast(self.data.len);
            const position: i32 = @intCast(self.position);
            const remaning: i32 = len - position;

            if (remaning < 0) return false; // this will never happen but....

            return remaning >= sample_size;
        }

        fn readFloat(sample_buffer: *[@sizeOf(T)]u8, endianness: std.builtin.Endian) T {
            const FT = switch (@sizeOf(T)) {
                1 => u8,
                2 => u16,
                4 => u32,
                8 => u64,
                else => u64,
            };

            const sample = std.mem.readInt(FT, sample_buffer, endianness);
            return @bitCast(sample);
        }

        fn writeFloat(buffer: *[@sizeOf(T)]u8, sample: T, endianness: std.builtin.Endian) void {
            const FT = switch (@sizeOf(T)) {
                1 => u8,
                2 => u16,
                4 => u32,
                8 => u64,
                else => u64,
            };

            std.mem.writeInt(FT, buffer, @bitCast(sample), endianness);
        }
    };
}

const testing = std.testing;

test "AudioData.init initializes correctly" {
    var buffer: [128]u8 = undefined;
    const channels = 2;
    const format_type = FormatType.signed_16bits_little_endian;
    const mockFormat = Format(format_type.ToType()){
        .format_type = format_type,
        .signedness = .signed,
        .byte_order = .little_endian,
        .bit_depth = 16,
        .byte_rate = 2,
        .physical_width = 16,
        .physical_byte_rate = 2,
        .sample_type = 0,
    };

    const data = GenericAudioData(format_type).init(&buffer, channels, 44100, mockFormat);

    try testing.expectEqual(mockFormat, data.format);
    try testing.expectEqual(channels, data.channels);
    try testing.expectEqualSlices(u8, buffer[0..], data.data);
    try testing.expectEqual(0, data.position);
}

// Mock FormatTypes
const signed_int_le = FormatType.signed_32bits_little_endian;
const signed_int_be = FormatType.signed_32bits_big_endian;
const signed_16_int_le = FormatType.signed_16bits_little_endian;
const signed_16_int_be = FormatType.signed_16bits_big_endian;
const unsigned_int_le = FormatType.unsigned_32bits_little_endian;
const unsigned_int_be = FormatType.unsigned_32bits_big_endian;
const unsigned_16_int_le = FormatType.unsigned_16bits_little_endian;
const unsigned_16_int_be = FormatType.unsigned_16bits_big_endian;
const float_le = FormatType.float64_little_endian;
const float_be = FormatType.float64_big_endian;
const float_32_le = FormatType.float_32bits_little_endian;
const float_32_be = FormatType.float64_little_endian;

// Mock Formats for Signed Integers (Little-Endian and Big-Endian)
const signed_16_int_format_le = Format(signed_16_int_le.ToType()){
    .format_type = signed_16_int_le,
    .signedness = .signed,
    .byte_order = .little_endian,
    .bit_depth = 16,
    .byte_rate = 2,
    .physical_width = 16,
    .physical_byte_rate = 2,
    .sample_type = 0,
};

const signed_16_int_format_be = Format(signed_16_int_be.ToType()){
    .format_type = signed_16_int_be,
    .signedness = .signed,
    .byte_order = .big_endian,
    .bit_depth = 16,
    .byte_rate = 2,
    .physical_width = 16,
    .physical_byte_rate = 2,
    .sample_type = 0,
};

// Mock Formats for Signed Integers (Little-Endian and Big-Endian)
const signed_int_format_le = Format(signed_int_le.ToType()){
    .format_type = signed_16_int_le,
    .signedness = .signed,
    .byte_order = .little_endian,
    .bit_depth = 32,
    .byte_rate = 4,
    .physical_width = 32,
    .physical_byte_rate = 4,
    .sample_type = 0,
};

const signed_int_format_be = Format(signed_int_be.ToType()){
    .format_type = signed_16_int_be,
    .signedness = .signed,
    .byte_order = .big_endian,
    .bit_depth = 32,
    .byte_rate = 4,
    .physical_width = 32,
    .physical_byte_rate = 2,
    .sample_type = 0,
};

const unsigned_int_16_format_le = Format(unsigned_int_le.ToType()){
    .format_type = unsigned_int_le,
    .signedness = .unsigned,
    .byte_order = .little_endian,
    .bit_depth = 16,
    .byte_rate = 2,
    .physical_width = 16,
    .physical_byte_rate = 2,
    .sample_type = 0,
};

const unsigned_int_16_format_be = Format(unsigned_int_be.ToType()){
    .format_type = unsigned_int_be,
    .signedness = .unsigned,
    .byte_order = .big_endian,
    .bit_depth = 16,
    .byte_rate = 2,
    .physical_width = 16,
    .physical_byte_rate = 2,
    .sample_type = 0,
};

// Mock Formats for Unsigned Integers (Little-Endian and Big-Endian)
const unsigned_int_format_le = Format(unsigned_int_le.ToType()){
    .format_type = unsigned_int_le,
    .signedness = .unsigned,
    .byte_order = .little_endian,
    .bit_depth = 32,
    .byte_rate = 4,
    .physical_width = 32,
    .physical_byte_rate = 4,
    .sample_type = 0,
};

const unsigned_int_format_be = Format(unsigned_int_be.ToType()){
    .format_type = unsigned_int_be,
    .signedness = .unsigned,
    .byte_order = .big_endian,
    .bit_depth = 32,
    .byte_rate = 4,
    .physical_width = 32,
    .physical_byte_rate = 4,
    .sample_type = 0,
};

const float_32_format_le = Format(float_32_le.ToType()){
    .format_type = float_le,
    .signedness = .signed, // floats are always signed
    .byte_order = .little_endian,
    .bit_depth = 32,
    .byte_rate = 4,
    .physical_width = 32,
    .physical_byte_rate = 4,
    .sample_type = 0,
};

const float_32_format_be = Format(float_32_be.ToType()){
    .format_type = float_be,
    .signedness = .signed, // floats are always signed
    .byte_order = .big_endian,
    .bit_depth = 32,
    .byte_rate = 4,
    .physical_width = 32,
    .physical_byte_rate = 4,
    .sample_type = 0,
};

// Mock Formats for Float (Little-Endian and Big-Endian)
const float_format_le = Format(float_le.ToType()){
    .format_type = float_le,
    .signedness = .signed, // floats are always signed
    .byte_order = .little_endian,
    .bit_depth = 64,
    .byte_rate = 8,
    .physical_width = 64,
    .physical_byte_rate = 8,
    .sample_type = 0,
};

const float_format_be = Format(float_be.ToType()){
    .format_type = float_be,
    .signedness = .signed, // floats are always signed
    .byte_order = .big_endian,
    .bit_depth = 64,
    .byte_rate = 8,
    .physical_width = 64,
    .physical_byte_rate = 8,
    .sample_type = 0,
};

test "AudioData.linearMapIn 32 bits precision" {
    const signed_int = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const unsigned_int = if (native_endian == .little) unsigned_16_int_le else unsigned_16_int_be;
    const float_32 = if (native_endian == .little) float_32_le else float_32_be;

    const SignedAudioData = GenericAudioData(signed_int);
    const UnsignedAudioData = GenericAudioData(unsigned_int);
    const FloatAudioData = GenericAudioData(float_32);

    const max_sample: f32 = 1.0;
    const min_sample: f32 = -1.0;
    const mid_sample: f32 = 0.0;
    const one_quarter_sample: f32 = -0.5;
    const three_quarter_sample: f32 = 0.5;

    // Signed Int Samples
    const sample_max_int: i16 = SignedAudioData.linearMapIn(max_sample);
    const sample_min_int: i16 = SignedAudioData.linearMapIn(min_sample);
    const sample_mid_int: i16 = SignedAudioData.linearMapIn(mid_sample);
    const sample_one_quarter_int: i16 = SignedAudioData.linearMapIn(one_quarter_sample);
    const sample_three_quarter_int: i16 = SignedAudioData.linearMapIn(three_quarter_sample);

    // Unsigned Int Samples
    const sample_max_uint: u16 = UnsignedAudioData.linearMapIn(max_sample);
    const sample_min_uint: u16 = UnsignedAudioData.linearMapIn(min_sample);
    const sample_mid_uint: u16 = UnsignedAudioData.linearMapIn(mid_sample);
    const sample_one_quarter_uint: u16 = UnsignedAudioData.linearMapIn(one_quarter_sample);
    const sample_three_quarter_uint: u16 = UnsignedAudioData.linearMapIn(three_quarter_sample);

    // Float32 Samples
    const sample_max_float: f32 = FloatAudioData.linearMapIn(max_sample);
    const sample_min_float: f32 = FloatAudioData.linearMapIn(min_sample);
    const sample_mid_float: f32 = FloatAudioData.linearMapIn(mid_sample);
    const sample_one_quarter_float: f32 = FloatAudioData.linearMapIn(one_quarter_sample);
    const sample_three_quarter_float: f32 = FloatAudioData.linearMapIn(three_quarter_sample);

    // Signed Int Assertions
    try std.testing.expectEqual(std.math.maxInt(i16), sample_max_int);
    try std.testing.expectEqual(-std.math.maxInt(i16) - 1, sample_min_int); // Corrected to handle two's complement
    try std.testing.expectEqual(0, sample_mid_int);

    // -1 and +1 to correct the two's complement asymmetry
    const quarter_int_expected = (-std.math.maxInt(i16) - 1) + @divFloor(std.math.maxInt(i16) + 1, 2);
    const three_quarter_int_expected = @divFloor(std.math.maxInt(i16), 2);

    try std.testing.expectEqual(quarter_int_expected, sample_one_quarter_int);
    try std.testing.expectEqual(three_quarter_int_expected, sample_three_quarter_int);

    // Unsigned Int Assertions
    try std.testing.expectEqual(sample_max_uint, std.math.maxInt(u16));
    try std.testing.expectEqual(sample_min_uint, 0);
    try std.testing.expectEqual(sample_mid_uint, std.math.maxInt(u16) / 2);

    const quarter_uint_expected = std.math.maxInt(u16) / 4;
    const three_quarter_uint_expected = (3 * std.math.maxInt(u16)) / 4;

    try std.testing.expectEqual(quarter_uint_expected, sample_one_quarter_uint);
    try std.testing.expectEqual(three_quarter_uint_expected, sample_three_quarter_uint);

    // Float32 Assertions
    try std.testing.expectEqual(1.0, sample_max_float);
    try std.testing.expectEqual(-1.0, sample_min_float);
    try std.testing.expectEqual(0.0, sample_mid_float);
    try std.testing.expectEqual(-0.5, sample_one_quarter_float);
    try std.testing.expectEqual(0.5, sample_three_quarter_float);
}

test "AudioData.linearMapIn 64 bits precision" {
    const signed_int = if (native_endian == .little) signed_int_le else signed_int_be;
    const unsigned_int = if (native_endian == .little) unsigned_int_le else unsigned_int_be;
    const float_32 = if (native_endian == .little) float_le else float_be;

    const SignedAudioData = GenericAudioData(signed_int);
    const UnsignedAudioData = GenericAudioData(unsigned_int);
    const FloatAudioData = GenericAudioData(float_32);

    const max_sample: f64 = 1.0;
    const min_sample: f64 = -1.0;
    const mid_sample: f64 = 0.0;
    const one_quarter_sample: f64 = -0.5;
    const three_quarter_sample: f64 = 0.5;

    // Signed Int Samples
    const sample_max_int: i32 = SignedAudioData.linearMapIn(max_sample);
    const sample_min_int: i32 = SignedAudioData.linearMapIn(min_sample);
    const sample_mid_int: i32 = SignedAudioData.linearMapIn(mid_sample);
    const sample_one_quarter_int: i32 = SignedAudioData.linearMapIn(one_quarter_sample);
    const sample_three_quarter_int: i32 = SignedAudioData.linearMapIn(three_quarter_sample);

    // Unsigned Int Samples
    const sample_max_uint: u32 = UnsignedAudioData.linearMapIn(max_sample);
    const sample_min_uint: u32 = UnsignedAudioData.linearMapIn(min_sample);
    const sample_mid_uint: u32 = UnsignedAudioData.linearMapIn(mid_sample);
    const sample_one_quarter_uint: u32 = UnsignedAudioData.linearMapIn(one_quarter_sample);
    const sample_three_quarter_uint: u32 = UnsignedAudioData.linearMapIn(three_quarter_sample);

    // Floats
    const sample_max_float: f64 = FloatAudioData.linearMapIn(max_sample);
    const sample_min_float: f64 = FloatAudioData.linearMapIn(min_sample);
    const sample_mid_float: f64 = FloatAudioData.linearMapIn(mid_sample);
    const sample_one_quarter_float: f64 = FloatAudioData.linearMapIn(one_quarter_sample);
    const sample_three_quarter_float: f64 = FloatAudioData.linearMapIn(three_quarter_sample);

    // Signed Int Assertions
    try std.testing.expectEqual(std.math.maxInt(i32), sample_max_int);
    try std.testing.expectEqual(-std.math.maxInt(i32) - 1, sample_min_int);
    try std.testing.expectEqual(0, sample_mid_int);

    //  -1 and +1 to correct the two's complement asymmetry
    const quarter_int_expected = (-std.math.maxInt(i32) - 1) + @divFloor(std.math.maxInt(i32) + 1, 2);
    const three_quarter_int_expected = @divFloor(std.math.maxInt(i32), 2);

    try std.testing.expectEqual(sample_one_quarter_int, quarter_int_expected);
    try std.testing.expectEqual(sample_three_quarter_int, three_quarter_int_expected);

    // Unsigned Int Assertions
    try std.testing.expectEqual(std.math.maxInt(u32), sample_max_uint);
    try std.testing.expectEqual(0, sample_min_uint);
    try std.testing.expectEqual(std.math.maxInt(u32) / 2, sample_mid_uint);

    const quarter_uint_expected = std.math.maxInt(u32) / 4;
    const three_quarter_uint_expected = (3 * std.math.maxInt(u32)) / 4;

    try std.testing.expectEqual(sample_one_quarter_uint, quarter_uint_expected);
    try std.testing.expectEqual(three_quarter_uint_expected, sample_three_quarter_uint);

    // Float32 Assertions
    try std.testing.expectEqual(1.0, sample_max_float);
    try std.testing.expectEqual(-1.0, sample_min_float);
    try std.testing.expectEqual(0.0, sample_mid_float);
    try std.testing.expectEqual(-0.5, sample_one_quarter_float);
    try std.testing.expectEqual(0.5, sample_three_quarter_float);
}

test "AudioData.linearMapOut 32 bits precision" {
    const signed_int = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const unsigned_int = if (native_endian == .little) unsigned_16_int_le else unsigned_16_int_be;
    const float_32 = if (native_endian == .little) float_32_le else float_32_be;

    const SignedAudioData = GenericAudioData(signed_int);
    const UnsignedAudioData = GenericAudioData(unsigned_int);
    const FloatAudioData = GenericAudioData(float_32);

    // look int othe asymetre of the ints, probably need to revise how the mapping is being calculated
    // and the maxInt how is used
    const signed_int_max: i16 = std.math.maxInt(i16);
    const signed_int_min: i16 = -std.math.maxInt(i16) - 1; // need to add 1 to handle two's complement
    const signed_int_quarter: i16 = -std.math.maxInt(i16) + @divFloor(std.math.maxInt(i16), 2);
    const signed_int_three_quarter: i16 = @divFloor(std.math.maxInt(i16), 2);

    const unsigned_int_max: u16 = std.math.maxInt(u16);
    const unsigned_int_mid: u16 = @divFloor(std.math.maxInt(u16), 2);
    const unsigned_int_quarter: u16 = @divFloor(std.math.maxInt(u16), 4);
    const unsigned_int_three_quarter: u16 = unsigned_int_quarter * 3;

    const sample_int_max = SignedAudioData.linearMapOut(signed_int_max);
    const sample_int_min = SignedAudioData.linearMapOut(signed_int_min);
    const sample_int_mid = SignedAudioData.linearMapOut(0);
    const sample_int_quarter = SignedAudioData.linearMapOut(signed_int_quarter);
    const sample_int_three_quarter = SignedAudioData.linearMapOut(signed_int_three_quarter);

    const sample_uint_max = UnsignedAudioData.linearMapOut(unsigned_int_max);
    const sample_uint_min = UnsignedAudioData.linearMapOut(0);
    const sample_uint_mid = UnsignedAudioData.linearMapOut(unsigned_int_mid);
    const sample_uint_quarter = UnsignedAudioData.linearMapOut(unsigned_int_quarter);
    const sample_uint_three_quarter = UnsignedAudioData.linearMapOut(unsigned_int_three_quarter);

    const sample_float_max = FloatAudioData.linearMapOut(1.0);
    const sample_float_min = FloatAudioData.linearMapOut(-1.0);
    const sample_float_mid = FloatAudioData.linearMapOut(0.0);
    const sample_float_quarter = FloatAudioData.linearMapOut(-0.5);
    const sample_float_three_quarter = FloatAudioData.linearMapOut(0.5);

    try testing.expectEqual(1.0, sample_int_max);
    try testing.expectEqual(-1.0, sample_int_min);
    try testing.expectEqual(0.0, sample_int_mid);
    try testing.expectEqual(-0.5, sample_int_quarter);

    // this is a rounding error for signed 16 bits as maxInt(i16) = 32767 and
    // three quarter in or 0.5 would map to 32767 / 2 = 16383.5 which cannot really be represented
    // as an integer
    try testing.expectEqual(4.9998474e-1, sample_int_three_quarter);

    try testing.expectEqual(1.0, sample_uint_max);
    try testing.expectEqual(-1.0, sample_uint_min);

    // Similarly to signed ints, maxInt(u16) = 65535 and mid = 32767.5 which cannot be represented as an integer
    // the quarter and three quarter are also rounded to the nearest integer
    try testing.expectEqual(-1.5258789e-5, sample_uint_mid);
    try testing.expectEqual(-5.000229e-1, sample_uint_quarter);
    try testing.expectEqual(4.9993134e-1, sample_uint_three_quarter);

    try testing.expectEqual(1.0, sample_float_max);
    try testing.expectEqual(-1.0, sample_float_min);
    try testing.expectEqual(0.0, sample_float_mid);
    try testing.expectEqual(-0.5, sample_float_quarter);
    try testing.expectEqual(0.5, sample_float_three_quarter);
}

test "AudioData.linearMapOut 64 bits precision" {
    const signed_int = if (native_endian == .little) signed_int_le else signed_int_be;
    const unsigned_int = if (native_endian == .little) unsigned_int_le else unsigned_int_be;
    const float = if (native_endian == .little) float_le else float_be;

    const SignedAudioData = GenericAudioData(signed_int);
    const UnsignedAudioData = GenericAudioData(unsigned_int);
    const FloatAudioData = GenericAudioData(float);

    // look int othe asymetre of the ints, probably need to revise how the mapping is being calculated
    // and the maxInt how is used
    const signed_int_max: i32 = std.math.maxInt(i32);
    const signed_int_min: i32 = -std.math.maxInt(i32) - 1; // need to add 1 to handle two's complement
    const signed_int_quarter: i32 = -std.math.maxInt(i32) + @divFloor(std.math.maxInt(i32), 2);
    const signed_int_three_quarter: i32 = @divFloor(std.math.maxInt(i32), 2);

    const unsigned_int_max: u32 = std.math.maxInt(u32);
    const unsigned_int_mid: u32 = @divFloor(std.math.maxInt(u32), 2);
    const unsigned_int_quarter: u32 = @divFloor(std.math.maxInt(u32), 4);
    const unsigned_int_three_quarter: u32 = unsigned_int_quarter * 3;

    const sample_int_max = SignedAudioData.linearMapOut(signed_int_max);
    const sample_int_min = SignedAudioData.linearMapOut(signed_int_min);
    const sample_int_mid = SignedAudioData.linearMapOut(0);
    const sample_int_quarter = SignedAudioData.linearMapOut(signed_int_quarter);
    const sample_int_three_quarter = SignedAudioData.linearMapOut(signed_int_three_quarter);
    const sample_uint_max = UnsignedAudioData.linearMapOut(unsigned_int_max);
    const sample_uint_min = UnsignedAudioData.linearMapOut(0);
    const sample_uint_mid = UnsignedAudioData.linearMapOut(unsigned_int_mid);
    const sample_uint_quarter = UnsignedAudioData.linearMapOut(unsigned_int_quarter);
    const sample_uint_three_quarter = UnsignedAudioData.linearMapOut(unsigned_int_three_quarter);

    const sample_float_max = FloatAudioData.linearMapOut(1.0);
    const sample_float_min = FloatAudioData.linearMapOut(-1.0);
    const sample_float_mid = FloatAudioData.linearMapOut(0.0);
    const sample_float_quarter = FloatAudioData.linearMapOut(-0.5);
    const sample_float_three_quarter = FloatAudioData.linearMapOut(0.5);

    try testing.expectEqual(1.0, sample_int_max);
    try testing.expectEqual(-1.0, sample_int_min);
    try testing.expectEqual(0.0, sample_int_mid);
    try testing.expectEqual(-0.5, sample_int_quarter);

    //  similar to the 16 bits precission, the three quarter is rounded to the nearest integer
    try testing.expectEqual(4.9999999976716936e-1, sample_int_three_quarter);

    try testing.expectEqual(1.0, sample_uint_max);
    try testing.expectEqual(-1.0, sample_uint_min);

    //  similar to the 16 bits precission, rounded to the nearest integer
    try testing.expectEqual(-2.3283064365386963e-10, sample_uint_mid);
    try testing.expectEqual(-5.00000000349246e-1, sample_uint_quarter);
    try testing.expectEqual(4.999999989522621e-1, sample_uint_three_quarter);

    try testing.expectEqual(1.0, sample_float_max);
    try testing.expectEqual(-1.0, sample_float_min);
    try testing.expectEqual(0.0, sample_float_mid);
    try testing.expectEqual(-0.5, sample_float_quarter);
    try testing.expectEqual(0.5, sample_float_three_quarter);
}

test "AudioData.write writes a single sample correctly" {
    var signed_buffer: [128]u8 = undefined;
    var unsigned_buffer: [128]u8 = undefined;
    var float_buffer: [128]u8 = undefined;

    const channels = 2;

    const signed_int = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const unsigned_int = if (native_endian == .little) unsigned_int_le else unsigned_int_be;
    const float = if (native_endian == .little) float_le else float_be;

    const signed_int_format = if (native_endian == .little) signed_16_int_format_le else signed_16_int_format_be;
    const unsigned_int_format = if (native_endian == .little) unsigned_int_format_le else unsigned_int_format_be;
    const float_format = if (native_endian == .little) float_format_le else float_format_be;

    var signed_int_data = GenericAudioData(signed_int).init(&signed_buffer, channels, 44100, signed_int_format);
    var unsigned_int_data = GenericAudioData(unsigned_int).init(&unsigned_buffer, channels, 44100, unsigned_int_format);
    var float_data = GenericAudioData(float).init(&float_buffer, channels, 44100, float_format);

    const signed_sample: f32 = 1.0;
    const unsigned_sample: f64 = -1.0;
    const float_sample: f64 = 123456.789;

    try signed_int_data.writeSample(signed_sample);

    signed_int_data.rewind();

    try unsigned_int_data.writeSample(unsigned_sample);
    unsigned_int_data.rewind();

    try float_data.writeSample(float_sample);
    float_data.rewind();

    const signed_written_sample: f32 = signed_int_data.readSample() orelse 0;
    try testing.expectEqual(signed_sample, signed_written_sample);

    const unsigned_written_sample: f64 = unsigned_int_data.readSample() orelse 0;
    try testing.expectEqual(unsigned_sample, unsigned_written_sample);

    const float_written_sample: f64 = float_data.readSample() orelse 0;
    try testing.expectEqual(float_sample, float_written_sample);
}

test "AudioData.writeSample handles endianness correctly" {
    var buffer: [128]u8 = undefined;
    const channels = 1;

    // Initialize the data with an endianness different from the native one
    const other_endian_signed_int = if (native_endian == .little) signed_16_int_be else signed_16_int_le;
    const other_endian_format = if (native_endian == .little) signed_16_int_format_be else signed_16_int_format_le;
    var data_big_endian = GenericAudioData(other_endian_signed_int).init(&buffer, channels, 44100, other_endian_format);

    const sample: f32 = 1;

    try data_big_endian.writeSample(sample);
    data_big_endian.rewind();

    const read_sample: f32 = data_big_endian.readSample() orelse 0;
    try testing.expectEqual(sample, read_sample);
}

test "AudioData.write and read multiple samples" {
    var signed_buffer: [128]u8 = undefined;
    var float_buffer: [128]u8 = undefined;
    const channels = 2;

    const signed_int = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const float = if (native_endian == .little) float_le else float_be;

    const signed_int_format = if (native_endian == .little) signed_16_int_format_le else signed_16_int_format_be;
    const float_format = if (native_endian == .little) float_format_le else float_format_be;

    var signed_int_data = GenericAudioData(signed_int).init(&signed_buffer, channels, 44100, signed_int_format);
    var float_data = GenericAudioData(float).init(&float_buffer, channels, 44100, float_format);

    var signed_samples = [_]f32{ 1.0, -1.0, 1.0 };
    var float_samples = [_]f64{ 123456.789, -987654.321, 456789.123 };

    // Write multiple samples
    try signed_int_data.write(&signed_samples);
    try float_data.write(&float_samples);

    signed_int_data.rewind();
    float_data.rewind();

    // Read and check multiple samples
    for (signed_samples) |expected| {
        const sample: f32 = signed_int_data.readSample() orelse 0;
        try testing.expectEqual(expected, sample);
    }

    for (float_samples) |expected| {
        const sample: f64 = float_data.readSample() orelse 0;
        try testing.expectEqual(expected, sample);
    }
}

test "AudioData.writeSample returns out_of_bounds when writing out of buffer space" {
    const channels = 2;
    const nb_samples = 2;

    const format_type = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const mock_format = if (native_endian == .little) signed_16_int_format_le else signed_16_int_format_be;

    var buffer: [nb_samples * @sizeOf(i16)]u8 = undefined;

    var data = GenericAudioData(format_type).init(&buffer, channels, 44100, mock_format);
    var samples = [_]f32{ 1.0, -1.0 };

    try data.write(&samples);

    try testing.expectError(AudioDataError.out_of_bounds, data.writeSample(0.2));
}

test "AudioData.readSample returns null when reading out of bounds" {
    const channels = 2;
    const format_type = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const mock_format = if (native_endian == .little) signed_16_int_format_le else signed_16_int_format_be;

    const nb_samples = 2;
    var buffer: [nb_samples * @sizeOf(i16)]u8 = undefined;

    var data = GenericAudioData(format_type).init(&buffer, channels, 44100, mock_format);
    var samples = [_]f32{ -1.0, 1.0 };

    try data.write(&samples);
    data.rewind();

    // Read two samples, should succeed
    const sample1: f32 = data.readSample() orelse unreachable;
    try testing.expectEqual(samples[0], sample1);

    const sample2: f32 = data.readSample() orelse unreachable;
    try testing.expectEqual(samples[1], sample2);

    // Attempt to read beyond available samples, should return null
    const out_of_bounds_sample: ?f32 = data.readSample();
    try testing.expectEqual(null, out_of_bounds_sample);
}

test "AudioData.seek positions correctly" {
    const channels = 2;
    const format_type = if (native_endian == .little) signed_16_int_le else signed_16_int_be;
    const mock_format = if (native_endian == .little) signed_16_int_format_le else signed_16_int_format_be;

    const nb_samples = 4;
    var buffer: [nb_samples * @sizeOf(i16)]u8 = undefined;

    var data = GenericAudioData(format_type).init(&buffer, channels, 44100, mock_format);
    var samples = [nb_samples]f32{ -1.0, 1.0, -1.0, 1 };
    try data.write(&samples);

    // Seek to the second sample
    try data.seek(1);
    const second_sample: f32 = data.readSample() orelse unreachable;
    try testing.expectEqual(samples[1], second_sample);

    // Seek to the last sample
    try data.seek(3);
    const last_sample: f32 = data.readSample() orelse unreachable;
    try testing.expectEqual(samples[3], last_sample);

    // Seek out of bounds should return an error
    try testing.expectError(AudioDataError.out_of_bounds, data.seek(4));
}
