const std = @import("std");
const dsp = @import("dsp/dsp.zig");
const graph = @import("graph/graph.zig");
const audio_specs = @import("common/audio_specs.zig");
const ex = @import("examples.zig");

const backends = @import("backends/backends.zig");

pub const std_options = .{
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
    std.testing.refAllDeclsRecursive(backends);
    std.testing.refAllDeclsRecursive(dsp);
    std.testing.refAllDeclsRecursive(graph);
}
