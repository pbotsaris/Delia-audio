//! Device backends on the new buffer and graph contracts (docs/backend-contract.md).
//! The previous ALSA backend is in src/legacy/backends/ until M4a's hardware run passes.
pub const alsa = @import("alsa/alsa.zig");

test {
    _ = alsa;
}
