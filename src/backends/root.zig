//! Device backends on the new buffer and graph contracts (docs/backend-contract.md).
pub const alsa = @import("alsa");

test {
    _ = alsa;
}
