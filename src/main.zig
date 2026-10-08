const std = @import("std");
const dsp = @import("dsp");
const graph = @import("graph");
const audio_specs = @import("common").audio_specs;
const ex = @import("examples.zig");

const backends = @import("backends");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = @import("logging.zig").logFn,
};

const log = std.log.scoped(.main);

pub fn main() !void {
    graph.examples.offlineFanIn();
}

test {
    // Each module is its own test root in build.zig; this block only covers main.zig's
    // own files. Examples have no tests; reference them so they keep compiling.
    std.testing.refAllDecls(ex);
}
