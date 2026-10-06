//! Root of the `common` module: audio_specs enums and the old audio_buffer views.
//! audio_buffer is legacy-only and goes when src/legacy/ does.
pub const audio_specs = @import("audio_specs.zig");
pub const audio_buffer = @import("audio_buffer.zig");

test {
    _ = audio_specs;
    _ = audio_buffer;
}
