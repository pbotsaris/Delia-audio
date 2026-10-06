//! ALSA backend on docs/backend-contract.md. M4a: playback, MMAP interleaved, S16_LE.
pub const loop = @import("loop.zig");
pub const convert = @import("convert.zig");
pub const pcm = @import("pcm.zig");
pub const device = @import("device.zig");

test {
    _ = loop;
    _ = convert;
    _ = pcm;
    _ = device;
}
