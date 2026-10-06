const std = @import("std");
const SampleRate = @import("common").audio_specs.SampleRate;
const BufferSize = @import("common").audio_specs.BufferSize;

const c_alsa = @cImport({
    @cInclude("alsa/asoundlib.h");
});

pub const StreamType = enum(c_uint) {
    playback = c_alsa.SND_PCM_STREAM_PLAYBACK,
    capture = c_alsa.SND_PCM_STREAM_CAPTURE,

    pub fn toggle(self: StreamType) StreamType {
        return switch (self) {
            .playback => .capture,
            .capture => .playback,
        };
    }
};

pub const StartThreshold = enum(u32) {
    immediate = 0,
    fill_one_period = 1,
    disabled = 0x7fffffff,
};

pub const ChannelCount = enum(u32) {
    mono = 1,
    stereo = 2,
    quad = 4,
    six = 6,
    eight = 8,
    ten = 10,
    twelve = 12,
    fourteen = 14,
    sixteen = 16,
    eighteen = 18,
    twenty = 20,
    twenty_two = 22,
    twenty_four = 24,
    twenty_six = 26,
    twenty_eight = 28,
};

/// interleaved channels     [L1 R1 L2 R2 L3 R3 3R...]
/// non-interleaved channels [L1 L2 L3 L4 L5 L6... R1 R2 R3 R4 R5 R6...]
pub const AccessType = enum(c_uint) {
    /// read-only access: simpler API
    /// use `snd_pcm_readi` and `snd_pcm_writei` to read/write smaples.
    rw_interleaved = c_alsa.SND_PCM_ACCESS_RW_INTERLEAVED,
    rw_noninterleaved = c_alsa.SND_PCM_ACCESS_RW_NONINTERLEAVED,

    /// MMAP access: more efficient
    /// can directly map the ALSA b uffer into the application's memory space
    mmap_interleaved = c_alsa.SND_PCM_ACCESS_MMAP_INTERLEAVED,
    mmap_noninterleaved = c_alsa.SND_PCM_ACCESS_MMAP_NONINTERLEAVED,

    // NOTE: ommting `SND_PCM_ACCESS_MMAP_COMPLEX`
};

/// The `Mode` enum defines the operating mode for the audio device.
/// This implementation currently does not use any of the modes, but this may change in the future.
pub const Mode = enum(c_int) {
    none = 0,
    // NOT IN USE

    //  opens in non-blocking mode: calls to read/write audio data will return immediately.
    //  Mostly used in conjunction with `poll` or `select` to handle audio I/O asynchronously.
    //nonblock = c_alsa.SND_PCM_NONBLOCK,

    // async for when handling audio I/O asynchronously
    // async_mode = c_alsa.SND_PCM_ASYNC,
    // prevents automatic resampling when sample rate doesn't match hardware
    // no_resample = c_alsa.SND_PCM_NO_AUTO_RESAMPLE,
    // prevents from automatically ajudisting the number of channel
    // no_autochannel = c_alsa.SND_PCM_NO_AUTO_CHANNELS,
    // prevents from automatically ajusting the sample format
    // no_autoformat = c_alsa.SND_PCM_NO_AUTO_FORMAT,
};

pub const Signedness = enum(u32) {
    signed,
    unsigned,
};

pub const ByteOrder = enum(u32) {
    little_endian,
    big_endian,
};

/// The `SampleType` enum defines the possible data types for audio samples in the audio engine.
// This enum is essential because the exact format of audio samples is determined at runtime
// based on the configuration provided by the ALSA API. As such, type checks are required at runtime
// to ensure the correct handling of audio buffers, preventing data corruption and undefined behavior.
pub const SampleType = enum(u32) {
    t_i8,
    t_u8,
    t_i16,
    t_u16,
    t_i20,
    t_u20,
    t_i24,
    t_u24,
    t_i32,
    t_u32,
    t_f32,
    t_f64,
    t_u8_3, // 3 bytes per sample
    t_u8_C, // compressed format will need decoding

    /// Checks if the provided type `T` matches the expected `SampleType`.
    ///
    /// This function is used to validate that the actual data type being processed
    /// corresponds to the `SampleType` that was determined at runtime.
    ///
    /// # Parameters
    /// - `T`: The type to be checked against the `SampleType`.
    ///
    /// # Returns
    /// - `true` if `T` matches the expected `SampleType`.
    /// - `false` otherwise.
    ///
    /// # Example
    /// ```
    /// const sample_type = SampleType.t_i16;
    /// assert(sample_type.isValidType(i16) == true);
    /// assert(sample_type.isValidType(u8) == false);
    /// ```
    pub fn isValidType(self: SampleType, T: type) bool {
        return switch (T) {
            u8 => return self == .t_u8 or self == .t_u8_C,
            i8 => return self == .t_i8,
            u16 => return self == .t_u16,
            i16 => return self == .t_i16,
            u20 => return self == .t_u20,
            i20 => return self == .t_i20,
            u24 => return self == .t_u24,
            i24 => return self == .t_i24,
            u32 => return self == .t_u32,
            i32 => return self == .t_i32,
            f32 => return self == .t_f32,
            f64 => return self == .t_f64,
            [3]u8 => return self == .t_u8_3,
            else => false,
        };
    }
};

pub const FormatType = enum(c_int) {
    // unknown = c_alsa.SND_PCM_FORMAT_UNKNOWN,

    signed_8bits = c_alsa.SND_PCM_FORMAT_S8,
    // 8-bit integer formats
    unsigned_8bits = c_alsa.SND_PCM_FORMAT_U8,

    // 16-bit integer formats
    signed_16bits_little_endian = c_alsa.SND_PCM_FORMAT_S16_LE,
    signed_16bits_big_endian = c_alsa.SND_PCM_FORMAT_S16_BE,
    unsigned_16bits_little_endian = c_alsa.SND_PCM_FORMAT_U16_LE,
    unsigned_16bits_big_endian = c_alsa.SND_PCM_FORMAT_U16_BE,

    // 20-bit integer formats
    signed_20bits_little_endian = c_alsa.SND_PCM_FORMAT_S20_LE,
    signed_20bits_big_endian = c_alsa.SND_PCM_FORMAT_S20_BE,
    unsigned_20bits_little_endian = c_alsa.SND_PCM_FORMAT_U20_LE,
    unsigned_20bits_big_endian = c_alsa.SND_PCM_FORMAT_U20_BE,

    // 24-bit integer formats
    signed_24bits_little_endian = c_alsa.SND_PCM_FORMAT_S24_LE,
    signed_24bits_big_endian = c_alsa.SND_PCM_FORMAT_S24_BE,
    unsigned_24bits_little_endian = c_alsa.SND_PCM_FORMAT_U24_LE,
    unsigned_24bits_big_endian = c_alsa.SND_PCM_FORMAT_U24_BE,

    // 32-bit integer formats
    signed_32bits_little_endian = c_alsa.SND_PCM_FORMAT_S32_LE,
    signed_32bits_big_endian = c_alsa.SND_PCM_FORMAT_S32_BE,
    unsigned_32bits_little_endian = c_alsa.SND_PCM_FORMAT_U32_LE,
    unsigned_32bits_big_endian = c_alsa.SND_PCM_FORMAT_U32_BE,

    // 32-bit floating-point formats
    float_32bits_little_endian = c_alsa.SND_PCM_FORMAT_FLOAT_LE,
    float_32bits_big_endian = c_alsa.SND_PCM_FORMAT_FLOAT_BE,

    // 64-bit floating-point formats
    float64_little_endian = c_alsa.SND_PCM_FORMAT_FLOAT64_LE,
    float64_big_endian = c_alsa.SND_PCM_FORMAT_FLOAT64_BE,

    // 3-byte per sample formats
    // These formats use 3 bytes per sample instead of 4, making them more compact than the regular 24-bit formats

    // CURRENTLY NOT SUPPORTING packed formats until we have hardware to test it
    // 24-bit packed formats (3 bytes per sample)
    // signed_24bits_packed3_little_endian = c_alsa.SND_PCM_FORMAT_S24_3LE,
    // signed_24bits_packed3_big_endian = c_alsa.SND_PCM_FORMAT_S24_3BE,
    // unsigned_24bits_packed3_little_endian = c_alsa.SND_PCM_FORMAT_U24_3LE,
    // unsigned_24bits_packed3_big_endian = c_alsa.SND_PCM_FORMAT_U24_3BE,

    // // 20-bit packed formats (3 bytes per sample)
    // signed_20bits_packed3_little_endian = c_alsa.SND_PCM_FORMAT_S20_3LE,
    // signed_20bits_packed3_big_endian = c_alsa.SND_PCM_FORMAT_S20_3BE,
    // unsigned_20bits_packed3_little_endian = c_alsa.SND_PCM_FORMAT_U20_3LE,
    // unsigned_20bits_packed3_big_endian = c_alsa.SND_PCM_FORMAT_U20_3BE,

    // // 18-bit packed formats (3 bytes per sample)
    // signed_18bits_packed3_little_endian = c_alsa.SND_PCM_FORMAT_S18_3LE,
    // signed_18bits_packed3_big_endian = c_alsa.SND_PCM_FORMAT_S18_3BE,
    // unsigned_18bits_packed3_little_endian = c_alsa.SND_PCM_FORMAT_U18_3LE,
    // unsigned_18bits_packed3_big_endian = c_alsa.SND_PCM_FORMAT_U18_3BE,

    // Compressed formats
    mu_law = c_alsa.SND_PCM_FORMAT_MU_LAW, // µ-law compression, common in North American telephony
    a_law = c_alsa.SND_PCM_FORMAT_A_LAW, // A-law compression, common in European telephony
    ima_adpcm = c_alsa.SND_PCM_FORMAT_IMA_ADPCM, // IMA ADPCM compression
    mpeg = c_alsa.SND_PCM_FORMAT_MPEG,
    gsm = c_alsa.SND_PCM_FORMAT_GSM, // GSM 6.10 compression, used in mobile telephony

    // IEC 958 subframe formats
    // These formats represent subframes of data as defined by the IEC 958 standard, commonly used in digital audio interfaces like S/PDIF
    iec958_subframe_little_endian = c_alsa.SND_PCM_FORMAT_IEC958_SUBFRAME_LE,
    iec958_subframe_big_endian = c_alsa.SND_PCM_FORMAT_IEC958_SUBFRAME_BE,

    // Not in use
    //
    // G.723 ADPCM formats
    // G.723 is a codec used for voice compression, especially in telephony
    // g723_24 = c_alsa.SND_PCM_FORMAT_G723_24, // G.723, 24 kbps
    // g723_24_1b = c_alsa.SND_PCM_FORMAT_G723_24_1B, // G.723, 24 kbps, 1-byte alignment
    // g723_40 = c_alsa.SND_PCM_FORMAT_G723_40, // G.723, 40 kbps
    // g723_40_1b = c_alsa.SND_PCM_FORMAT_G723_40_1B, // G.723, 40 kbps, 1-byte alignment
    /////////////////////////////////////////////////////////////

    // Note in use
    //
    // DSD (Direct Stream Digital) formats
    // DSD is a high-resolution audio format used in SACDs (Super Audio CDs) and other high-fidelity audio systems
    // dsd_u8 = c_alsa.SND_PCM_FORMAT_DSD_U8,
    // dsd_u16_little_endian = c_alsa.SND_PCM_FORMAT_DSD_U16_LE,
    // dsd_u16_big_endian = c_alsa.SND_PCM_FORMAT_DSD_U16_BE,
    // dsd_u32_little_endian = c_alsa.SND_PCM_FORMAT_DSD_U32_LE,
    // dsd_u32_big_endian = c_alsa.SND_PCM_FORMAT_DSD_U32_BE,
    /////////////////////////////////////////////////////////////

    // Special format - Not in use
    // This is a catch-all for formats that don't fit into the standard categories, used for custom or non-standard formats
    // special = c_alsa.SND_PCM_FORMAT_SPECIAL,

    ////////// these types are redudant -  they are little endian as above  ///////////
    // signed_16bits = c_alsa.SND_PCM_FORMAT_S16,
    // unsigned_16bits = c_alsa.SND_PCM_FORMAT_U16,
    // signed_24bits = c_alsa.SND_PCM_FORMAT_S24,
    // unsigned_24bits = c_alsa.SND_PCM_FORMAT_U24,
    // signed_32bits = c_alsa.SND_PCM_FORMAT_S32,
    // unsigned_32bits = c_alsa.SND_PCM_FORMAT_U32,
    // float_32bits = c_alsa.SND_PCM_FORMAT_FLOAT,
    // float_64bits = c_alsa.SND_PCM_FORMAT_FLOAT64,
    // signed_20bits = c_alsa.SND_PCM_FORMAT_S20,
    // unsigned_20bits = c_alsa.SND_PCM_FORMAT_U20,
    // iec958_subframe = c_alsa.SND_PCM_FORMAT_IEC958_SUBFRAME,
    ///////////////////////////////////////////

    /// Maps a `FormatType` to the corresponding `SampleType`.
    ///
    /// This function converts an ALSA `FormatType` into the appropriate `SampleType` for handling
    /// audio data. The conversion accounts for various audio formats, including different bit depths,
    /// signedness, and byte orders.
    ///
    /// - Returns the matching `SampleType` for the given `FormatType`.
    /// - Handles special cases like packed formats and compressed formats.
    ///
    /// Example:
    /// ```
    /// const sample_type = FormatType.signed_16bits_little_endian.toSampleType();
    /// assert(sample_type == SampleType.t_i16);
    /// ```
    pub fn toSampleType(self: FormatType) SampleType {
        return switch (self) {
            .signed_8bits => .t_i8,
            .unsigned_8bits => .t_u8,

            .signed_16bits_little_endian, .signed_16bits_big_endian => .t_i16,
            .unsigned_16bits_little_endian, .unsigned_16bits_big_endian => .t_u16,

            // NOTE: that Alsa uses 32 word packed in 4bytesm with the lower 20 bits used
            // The data is LSB justified, meaning the data is packed towards the least significant bit
            .signed_20bits_little_endian, .signed_20bits_big_endian => .t_i20,
            .unsigned_20bits_little_endian, .unsigned_20bits_big_endian => .t_u20,

            // NOTE: that in ALSA this uses 32bits words using the bottom 3 bytes
            .signed_24bits_little_endian, .signed_24bits_big_endian => .t_i24,
            .unsigned_24bits_little_endian, .unsigned_24bits_big_endian => .t_u24,

            .signed_32bits_little_endian, .signed_32bits_big_endian => .t_i32,
            .unsigned_32bits_little_endian, .unsigned_32bits_big_endian => .t_u32,

            // ranges from -1.0 to 1.0
            .float_32bits_little_endian, .float_32bits_big_endian => .t_f32,
            .float64_little_endian, .float64_big_endian => .t_f64,

            // NOT SUPPORTED (for now)
            //.signed_24bits_packed3_little_endian,
            //.signed_24bits_packed3_big_endian,
            //.unsigned_24bits_packed3_little_endian,
            //.unsigned_24bits_packed3_big_endian,
            //.signed_20bits_packed3_little_endian,
            //.signed_20bits_packed3_big_endian,
            //.unsigned_20bits_packed3_little_endian,
            //.unsigned_20bits_packed3_big_endian,
            //.signed_18bits_packed3_little_endian,
            //.signed_18bits_packed3_big_endian,
            //.unsigned_18bits_packed3_little_endian,
            //.unsigned_18bits_packed3_big_endian,
            //=> .t_u8_3,

            // Generally 32bits with audio in 16, 20, 24 bits
            // and the remaining bits is used for syncronization
            .iec958_subframe_little_endian, .iec958_subframe_big_endian => .t_u32,

            // Compressed formats
            // will need decoding logic
            else => .t_u8_C,
        };
    }

    pub fn ToType(self: FormatType) type {
        return switch (self) {
            .signed_8bits => i8,
            .unsigned_8bits => u8,

            .signed_16bits_little_endian, .signed_16bits_big_endian => i16,
            .unsigned_16bits_little_endian, .unsigned_16bits_big_endian => u16,

            // NOTE: that Alsa uses 32 word packed in 4bytesm with the lower 20 bits used
            // The data is LSB justified, meaning the data is packed towards the least significant bit
            .signed_20bits_little_endian, .signed_20bits_big_endian => i32,
            .unsigned_20bits_little_endian, .unsigned_20bits_big_endian => u32,

            // NOTE: that in ALSA this uses 32bits words using the bottom 3 bytes
            .signed_24bits_little_endian, .signed_24bits_big_endian => i32,
            .unsigned_24bits_little_endian, .unsigned_24bits_big_endian => u32,

            .signed_32bits_little_endian, .signed_32bits_big_endian => i32,
            .unsigned_32bits_little_endian, .unsigned_32bits_big_endian => u32,

            // ranges from -1.0 to 1.0
            .float_32bits_little_endian, .float_32bits_big_endian => f32,
            .float64_little_endian, .float64_big_endian => f64,

            // NOT SUPPORTED (for now)
            // .signed_24bits_packed3_little_endian,
            // .signed_24bits_packed3_big_endian,
            // .unsigned_24bits_packed3_little_endian,
            // .unsigned_24bits_packed3_big_endian,
            // .signed_20bits_packed3_little_endian,
            // .signed_20bits_packed3_big_endian,
            // .unsigned_20bits_packed3_little_endian,
            // .unsigned_20bits_packed3_big_endian,
            // .signed_18bits_packed3_little_endian,
            // .signed_18bits_packed3_big_endian,
            // .unsigned_18bits_packed3_little_endian,
            // .unsigned_18bits_packed3_big_endian,
            // => [3]u8,

            // Generally 32bits with audio in 16, 20, 24 bits
            // and the remaining bits is used for syncronization
            .iec958_subframe_little_endian, .iec958_subframe_big_endian => u32,

            // Compressed formats
            // will need decoding logic
            else => u8,
        };
    }
};

pub const formats: [@typeInfo(FormatType).@"enum".fields.len]c_int = blk: {
    const info = @typeInfo(FormatType);
    const len = info.@"enum".fields.len;
    var temp: [len]c_int = undefined;

    for (0..len) |i| {
        temp[i] = info.@"enum".fields[i].value;
    }

    break :blk temp;
};

pub const access_types: [@typeInfo(AccessType).@"enum".fields.len]c_uint = blk: {
    const info = @typeInfo(AccessType);
    const len = info.@"enum".fields.len;
    var temp: [len]c_uint = undefined;

    for (0..len) |i| {
        temp[i] = info.@"enum".fields[i].value;
    }

    break :blk temp;
};

pub const sample_rates: [@typeInfo(SampleRate).@"enum".fields.len]u32 = blk: {
    const info = @typeInfo(SampleRate);
    const len = info.@"enum".fields.len;
    var temp: [len]u32 = undefined;

    for (0..len) |i| {
        temp[i] = info.@"enum".fields[i].value;
    }

    break :blk temp;
};

pub const channel_counts: [@typeInfo(ChannelCount).@"enum".fields.len]u32 = blk: {
    const info = @typeInfo(ChannelCount);
    const len = info.@"enum".fields.len;
    var temp: [len]u32 = undefined;

    for (0..len) |i| {
        temp[i] = info.@"enum".fields[i].value;
    }

    break :blk temp;
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "StreamType values match ALSA constants" {
    try expectEqual(c_alsa.SND_PCM_STREAM_PLAYBACK, @intFromEnum(StreamType.playback));
    try expectEqual(c_alsa.SND_PCM_STREAM_CAPTURE, @intFromEnum(StreamType.capture));
}

test "AccessType values match ALSA constants" {
    try expectEqual(c_alsa.SND_PCM_ACCESS_RW_INTERLEAVED, @intFromEnum(AccessType.rw_interleaved));
    //  try expectEqual(c_alsa.SND_PCM_ACCESS_MMAP_NONINTERLEAVED, @intFromEnum(AccessType.mmap_noninterleaved));
}

test "SampleType.isValidType works correctly" {
    try expect(SampleType.t_i8.isValidType(i8));
    try expect(SampleType.t_u8.isValidType(u8));
    try expect(SampleType.t_u8_C.isValidType(u8));
    try expect(SampleType.t_i16.isValidType(i16));
    try expect(SampleType.t_u16.isValidType(u16));
    try expect(SampleType.t_i20.isValidType(i20));
    try expect(SampleType.t_u20.isValidType(u20));
    try expect(SampleType.t_i24.isValidType(i24));
    try expect(SampleType.t_u24.isValidType(u24));
    try expect(SampleType.t_i32.isValidType(i32));
    try expect(SampleType.t_u32.isValidType(u32));
    try expect(SampleType.t_f32.isValidType(f32));
    try expect(SampleType.t_f64.isValidType(f64));
    try expect(SampleType.t_u8_3.isValidType([3]u8));
    try expect(!SampleType.t_i8.isValidType(u8));
    try expect(!SampleType.t_u8.isValidType(i8));
    try expect(!SampleType.t_u8_C.isValidType(i8));
    try expect(!SampleType.t_i16.isValidType(u16));
    try expect(!SampleType.t_u16.isValidType(i16));
    try expect(!SampleType.t_i20.isValidType(u20));
    try expect(!SampleType.t_u20.isValidType(i20));
    try expect(!SampleType.t_i24.isValidType(u24));
    try expect(!SampleType.t_u24.isValidType(i24));
    try expect(!SampleType.t_i32.isValidType(u32));
    try expect(!SampleType.t_u32.isValidType(i32));
    try expect(!SampleType.t_f32.isValidType(f64));
    try expect(!SampleType.t_f64.isValidType(f32));
    try expect(!SampleType.t_u8_3.isValidType([4]u8));
}

test "FormatType.toSampleType works correctly" {
    // 8-bit integer formats
    try expectEqual(SampleType.t_i8, FormatType.signed_8bits.toSampleType());
    try expectEqual(SampleType.t_u8, FormatType.unsigned_8bits.toSampleType());

    // 16-bit integer formats
    try expectEqual(SampleType.t_i16, FormatType.signed_16bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_i16, FormatType.signed_16bits_big_endian.toSampleType());
    try expectEqual(SampleType.t_u16, FormatType.unsigned_16bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_u16, FormatType.unsigned_16bits_big_endian.toSampleType());

    // 20-bit integer formats
    try expectEqual(SampleType.t_i20, FormatType.signed_20bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_i20, FormatType.signed_20bits_big_endian.toSampleType());
    try expectEqual(SampleType.t_u20, FormatType.unsigned_20bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_u20, FormatType.unsigned_20bits_big_endian.toSampleType());

    // 24-bit integer formats
    try expectEqual(SampleType.t_i24, FormatType.signed_24bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_i24, FormatType.signed_24bits_big_endian.toSampleType());
    try expectEqual(SampleType.t_u24, FormatType.unsigned_24bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_u24, FormatType.unsigned_24bits_big_endian.toSampleType());

    // 32-bit integer formats
    try expectEqual(SampleType.t_i32, FormatType.signed_32bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_i32, FormatType.signed_32bits_big_endian.toSampleType());
    try expectEqual(SampleType.t_u32, FormatType.unsigned_32bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_u32, FormatType.unsigned_32bits_big_endian.toSampleType());

    // 32-bit floating-point formats
    try expectEqual(SampleType.t_f32, FormatType.float_32bits_little_endian.toSampleType());
    try expectEqual(SampleType.t_f32, FormatType.float_32bits_big_endian.toSampleType());

    // 64-bit floating-point formats
    try expectEqual(SampleType.t_f64, FormatType.float64_little_endian.toSampleType());
    try expectEqual(SampleType.t_f64, FormatType.float64_big_endian.toSampleType());

    // 24-bit packed formats (3 bytes per sample)
    // try expectEqual(SampleType.t_u8_3, FormatType.signed_24bits_packed3_little_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.signed_24bits_packed3_big_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.unsigned_24bits_packed3_little_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.unsigned_24bits_packed3_big_endian.toSampleType());

    // 20-bit packed formats (3 bytes per sample)
    // try expectEqual(SampleType.t_u8_3, FormatType.signed_20bits_packed3_little_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.signed_20bits_packed3_big_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.unsigned_20bits_packed3_little_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.unsigned_20bits_packed3_big_endian.toSampleType());

    // 18-bit packed formats (3 bytes per sample)
    // try expectEqual(SampleType.t_u8_3, FormatType.signed_18bits_packed3_little_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.signed_18bits_packed3_big_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.unsigned_18bits_packed3_little_endian.toSampleType());
    // try expectEqual(SampleType.t_u8_3, FormatType.unsigned_18bits_packed3_big_endian.toSampleType());

    // IEC 958 subframe formats
    try expectEqual(SampleType.t_u32, FormatType.iec958_subframe_little_endian.toSampleType());
    try expectEqual(SampleType.t_u32, FormatType.iec958_subframe_big_endian.toSampleType());

    // Compressed formats
    try expectEqual(SampleType.t_u8_C, FormatType.mu_law.toSampleType());
    try expectEqual(SampleType.t_u8_C, FormatType.a_law.toSampleType());
    try expectEqual(SampleType.t_u8_C, FormatType.ima_adpcm.toSampleType());
    try expectEqual(SampleType.t_u8_C, FormatType.mpeg.toSampleType());
    try expectEqual(SampleType.t_u8_C, FormatType.gsm.toSampleType());
}

test "formats array contains correct values" {
    try expectEqual(c_alsa.SND_PCM_FORMAT_S8, formats[0]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U8, formats[1]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S16_LE, formats[2]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S16_BE, formats[3]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U16_LE, formats[4]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U16_BE, formats[5]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S20_LE, formats[6]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S20_BE, formats[7]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U20_LE, formats[8]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U20_BE, formats[9]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S24_LE, formats[10]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S24_BE, formats[11]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U24_LE, formats[12]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U24_BE, formats[13]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S32_LE, formats[14]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_S32_BE, formats[15]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U32_LE, formats[16]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_U32_BE, formats[17]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_FLOAT_LE, formats[18]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_FLOAT_BE, formats[19]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_FLOAT64_LE, formats[20]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_FLOAT64_BE, formats[21]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_S24_3LE, formats[23]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_S24_3BE, formats[24]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_U24_3LE, formats[25]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_U24_3BE, formats[26]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_S20_3LE, formats[27]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_S20_3BE, formats[28]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_U20_3LE, formats[29]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_U20_3BE, formats[30]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_S18_3LE, formats[31]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_S18_3BE, formats[32]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_U18_3LE, formats[33]);
    //try expectEqual(c_alsa.SND_PCM_FORMAT_U18_3BE, formats[34]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_MU_LAW, formats[22]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_A_LAW, formats[23]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_IMA_ADPCM, formats[24]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_MPEG, formats[25]);
    try expectEqual(c_alsa.SND_PCM_FORMAT_GSM, formats[26]);
    //   try expectEqual(c_alsa.SND_PCM_FORMAT_IEC958_SUBFRAME_LE, formats[40]);
}

test "channel_counts array contains correct values" {
    try expectEqual(1, channel_counts[0]);
    try expectEqual(2, channel_counts[1]);
    try expectEqual(4, channel_counts[2]);
    try expectEqual(6, channel_counts[3]);
    try expectEqual(8, channel_counts[4]);
}
