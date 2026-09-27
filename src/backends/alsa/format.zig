const std = @import("std");

pub const FormatType = @import("settings.zig").FormatType;
pub const Signedness = @import("settings.zig").Signedness;
pub const ByteOrder = @import("settings.zig").ByteOrder;
pub const SampleType = @import("settings.zig").SampleType;
const AlsaError = @import("error.zig").AlsaError;

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

pub fn Format(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn maxSize() usize {
            switch (T) {
                f64, f32 => |FT| return std.math.floatMax(FT),
                else => |IT| return std.math.maxInt(IT),
            }
        }

        // the format type as per ALSA definitions
        format_type: FormatType,
        // the signedness of the format: signed or unsigned
        signedness: Signedness,
        // the byte order of the format: little or big endian
        byte_order: ByteOrder,
        // The number of bits per sample: 8, 16, 24, 32 bits. Negative if not applicable
        bit_depth: i32,
        // The number of bytes per sample: 1, 2, 3, 4 bytes. Negative if not applicable
        byte_rate: i32,
        // This is the same as bit_depth but also includes any padding bits. Relevant for formats like S24_3LE that are not packed
        // Negative if not applicable
        physical_width: i32,
        // same as byte_rate but for physical width. Negative if not applicable
        physical_byte_rate: i32,
        // This is a dummy value informing the underlying type of the format, only useful for type information.
        sample_type: T,

        pub fn init(fmt: FormatType) Self {
            const int_fmt = @intFromEnum(fmt);
            const is_little_endian: bool = c_alsa.snd_pcm_format_little_endian(int_fmt) == 1;
            const is_signed: bool = c_alsa.snd_pcm_format_signed(int_fmt) == 1;

            const byte_order = if (is_little_endian) ByteOrder.little_endian else ByteOrder.big_endian;
            const sign_type = if (is_signed) Signedness.signed else Signedness.unsigned;

            const bit_depth = c_alsa.snd_pcm_format_width(int_fmt);
            const physical_width = c_alsa.snd_pcm_format_physical_width(int_fmt);

            return .{
                .format_type = fmt,
                .signedness = sign_type,
                .byte_order = byte_order,
                .bit_depth = bit_depth,
                .byte_rate = if (bit_depth >= 0) @divFloor(bit_depth, 8) else -1,
                .physical_byte_rate = if (physical_width >= 0) @divFloor(physical_width, 8) else -1,
                .physical_width = bit_depth,
                // TODO: this could be an array so type check
                .sample_type = 0, // dummy value, this field is use only to get the underlying type of the format
            };
        }

        pub fn Type(self: Self) type {
            return @TypeOf(self.sample_type);
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("  Format\n", .{});
            try writer.print("  ├── signedness:         {s}\n", .{@tagName(self.signedness)});
            try writer.print("  ├── byte_order:         {s}\n", .{@tagName(self.byte_order)});
            try writer.print("  ├── byte_rate:          {d}\n", .{self.byte_rate});
            try writer.print("  ├── bit_depth:          {d}\n", .{self.bit_depth});
            try writer.print("  ├── physical_width:     {d}\n", .{self.physical_width});
            try writer.print("  ├── physical_byte_rate: {d}\n", .{self.physical_byte_rate});
            try writer.print("  └─  sample_type:        {any}\n", .{@TypeOf(self.sample_type)});
        }
    };
}
