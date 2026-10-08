//! Root of the `common` module: the audio_specs enums (BufferSize, BlockSize, SampleRate).
pub const audio_specs = @import("audio_specs.zig");

test {
    _ = audio_specs;
}
