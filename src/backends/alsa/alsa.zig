//! ALSA backend on docs/backend-contract.md. M4a: playback, MMAP interleaved, S16_LE.
pub const loop = @import("loop.zig");
pub const convert = @import("convert.zig");

test {
    _ = loop;
    _ = convert;
}
