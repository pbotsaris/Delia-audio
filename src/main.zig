const std = @import("std");
const dsp = @import("dsp/dsp.zig");
const graph = @import("graph/graph.zig");
const audio_specs = @import("common/audio_specs.zig");
const ex = @import("examples.zig");

const backends = @import("backends/backends.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = @import("logging.zig").logFn,
};

const log = std.log.scoped(.main);

// fn examplePlaybackAndGraph() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//     var e = try ex.Example.init(allocator, audio_specs.SampleRate.sr_44100);
//
//     try e.prepare();
//     try e.run();
//     try e.deinit();
// }
pub fn main() !void {
    //    examplePlaybackAndGraph() catch |err| {
    //        log.err("Failed to run example: {!}", .{err});
    //    };

    graph.examples.offlineFanIn();

    // backends.alsa.examples.printingHardwareInfo();
    // backends.alsa.examples.findAndPrintCardPortInfo("USB");
    // backends.alsa.examples.selectAudioPortCounterpart();
    // backends.alsa.examples.fullDuplexCallbackWithLatencyProbe();
    // backends.alsa.examples.fullDuplexCallbackWithLatencyProbe();
    // backends.alsa.examples.halfDuplexCapture();
    // backends.alsa.examples.fullDuplexCallbackUnlinkedDevices();
    // backends.alsa.examples.playbackSineWave();

    // backends.alsa.examples.usingHardwareToInitDevice();
}

test {
    _ = backends;
    _ = dsp;
    _ = graph;
    _ = @import("legacy/graph/graph.zig"); // old scheduler; examples.zig uses it until M4
    _ = audio_specs;
    _ = @import("common/audio_buffer.zig");
    _ = @import("core/buffer/buffer.zig");
    _ = @import("utils/utils.zig");

    // examples have no tests; reference them so they keep compiling
    std.testing.refAllDecls(backends.alsa.examples);
    std.testing.refAllDecls(ex.Example);
}
