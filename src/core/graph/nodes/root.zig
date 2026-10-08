pub const Oscillator = @import("oscillator.zig").Oscillator;
pub const Gain = @import("gain.zig").Gain;

test {
    _ = @import("oscillator.zig");
    _ = @import("gain.zig");
}
