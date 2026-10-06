const std = @import("std");
const dsp = @import("dsp");
const graph = @import("graph");
const audio_specs = @import("common").audio_specs;
const ex = @import("examples.zig");

const backends = @import("backends");
const legacy_backends = @import("legacy_backends"); // examples.zig plays through it until M4a

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

    // legacy_backends.alsa.examples.printingHardwareInfo();
    // legacy_backends.alsa.examples.findAndPrintCardPortInfo("USB");
    // legacy_backends.alsa.examples.selectAudioPortCounterpart();
    // legacy_backends.alsa.examples.fullDuplexCallbackWithLatencyProbe();
    // legacy_backends.alsa.examples.halfDuplexCapture();
    // legacy_backends.alsa.examples.fullDuplexCallbackUnlinkedDevices();
    // legacy_backends.alsa.examples.playbackSineWave();
    // legacy_backends.alsa.examples.usingHardwareToInitDevice();
}

test {
    // Each module is its own test root in build.zig; this block only covers main.zig's
    // own files. Examples have no tests; reference them so they keep compiling.
    std.testing.refAllDecls(legacy_backends.alsa.examples);
    std.testing.refAllDecls(ex.Example);
}
