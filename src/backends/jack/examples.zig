// TODO: Do the callback for jack, you have something already in place but you may need to figure out

const jack = @import("jack.zig");
const std = @import("std");

const Client = jack.client.JackClient;
const Hardware = jack.Hardware;
const AudioData = jack.audio_data.AudioData(f32);

const log = std.log.scoped(.jack);

// similar to alsa, you can define a callback within a context so you have
// the flexibility of changing internal state of the context
const Context = struct {
    pub fn callback(self: *Context, in: AudioData, out: AudioData) void {
        _ = in;
        _ = out;
        _ = self;
    }
};

const JackClient = jack.client.JackClient(Context, .{ .log_level = .info });

pub fn testJack() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var context = Context{};
    const allocator = gpa.allocator();

    var client = JackClient.init(allocator, &context, .{
        .client_name = "delia",
        .server_name = null,
    }) catch |err| {
        log.err("Failed to init jack client: {!}", .{err});
        return;
    };

    defer client.deinit();

    // Client will load all the hardware port upon initialization
    // Checking the hardware ports

    // for (client.hardware.playbacks) |playback| {
    //     log.info("Playback: {s}", .{playback.name});
    // }

    // for (client.hardware.captures) |captures| {
    //     log.info("Capture: {s}", .{captures.name});
    // }

    // when selecting group of ports, like channels from the same card
    // we can use findPortGroup which will return a list of ports that matches
    // the given name. This function assumes that ports on the same card have similar names
    // of none is find the returned slice is empty
    const webcam_captures = client.hardware.findPortGroup("webcam", .capture);

    for (webcam_captures) |webcam_capture| {
        const port = client.registerPortFor(webcam_capture) catch |err| {
            log.err("Failed to register port: {!}", .{err});
            return;
        };

        port.connect(webcam_capture) catch |err| {
            log.err("Failed to connect port: {!}", .{err});
            return;
        };
    }

    const playbacks = client.hardware.findPortGroup("speaker", .playback);

    for (playbacks) |playback| {
        const port = client.registerPortFor(playback) catch |err| {
            log.err("Failed to register port: {!}", .{err});
            return;
        };

        port.connect(playback) catch |err| {
            log.err("Failed to connect port: {!}", .{err});
            return;
        };
    }
}
