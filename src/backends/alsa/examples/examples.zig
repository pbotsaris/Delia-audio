const std = @import("std");
const alsa = @import("../alsa.zig");
const wave = @import("../../../dsp/waves.zig");
const latency = @import("../latency.zig");

const log = std.log.scoped(.alsa);

// providing the format and the context in which you callback will ruin from
// at comptime type will allow operation on device to be type safe
const HalfDuplexDevice = alsa.driver.HalfDuplexDevice(HalfDuplexPlaybackContext, .{
    .format = .signed_16bits_little_endian,
});

const HalfDuplexCaptureDevice = alsa.driver.HalfDuplexDevice(HalfDuplexCaptureContext, .{
    .format = .signed_16bits_little_endian,
});

//enabling latency probing at comptime
// you mut provide a callback (see below) other will call a noop callback
const FullDuplexDeviceWithProbe = alsa.driver.FullDuplexDevice(FullDuplexContext, .{
    .format = .signed_16bits_little_endian,
    .probe_enabled = true,
});

const FullDuplexDevice = alsa.driver.FullDuplexDevice(FullDuplexContext, .{
    .format = .signed_16bits_little_endian,
});

const HalfDuplexPlaybackContext = struct {
    const Self = @This();
    const T = HalfDuplexDevice.FloatType();

    w: wave.Wave(T) = wave.Wave(T).init(100.0, 0.2, 48000.0),

    pub fn callback(self: *Self, data: HalfDuplexDevice.AudioDataType()) void {
        self.w.setSampleRate(@floatFromInt(data.sample_rate));

        for (0..data.totalSampleCount()) |_| {
            const sample = self.w.sineSample();

            for (0..data.channels) |_| {
                data.writeSample(sample) catch {
                    return;
                };
            }
        }
    }
};

const HalfDuplexCaptureContext = struct {
    const Self = @This();

    pub fn callback(_: *Self, data: HalfDuplexDevice.AudioDataType()) void {
        log.debug("in sample rate: {d}\n", .{data.sample_rate});
        log.debug("in format: {f}\n", .{data.format});
        log.debug("in channels: {d}\n", .{data.channels});
        log.debug("in total sample count: {d}\n", .{data.totalSampleCount()});
    }
};

const FullDuplexContext = struct {
    const Self = @This();

    w: wave.Wave(f32) = wave.Wave(f32).init(100.0, 0.2, 48000.0),

    const AudioDataType = FullDuplexDeviceWithProbe.AudioDataType();
    const T = FullDuplexDeviceWithProbe.FloatType();

    // writes in to out
    pub fn callback(self: *Self, in: AudioDataType, out: AudioDataType) void {
        self.w.setSampleRate(@floatFromInt(in.sample_rate));

        for (0..in.totalSampleCount()) |_| {
            var maybe_sample: ?T = null;

            // of more than one channel, just grab the last one
            for (0..in.channels) |_| {
                maybe_sample = in.readSample();
            }

            // write the sample to all channels
            for (0..out.channels) |_| {
                const sample = maybe_sample orelse 0.0;

                out.writeSample(sample) catch {
                    return;
                };
            }
        }
    }
};

pub fn playbackSineWave() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    var dev = HalfDuplexDevice.init(allocator, .{
        .sample_rate = .sr_44100,
        .channels = .stereo,
        .stream_type = .playback,
        .buffer_size = .buf_512,
        .ident = "hw:3,0",
    }) catch |err| {
        log.err("Failed to init device: {}", .{err});
        return;
    };

    defer dev.deinit() catch |err| {
        log.err("Failed to deinit device: {}", .{err});
    };

    dev.prepare() catch |err| {
        log.err("Failed to prepare device: {}", .{err});
    };

    var ctx = HalfDuplexPlaybackContext{ .w = wave.Wave(f32).init(100.0, 0.2, 48000.0) };

    dev.start(&ctx, @field(HalfDuplexPlaybackContext, "callback")) catch |err| {
        log.err("Failed to start device: {}", .{err});
    };
}

pub fn halfDuplexCapture() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    var dev = HalfDuplexCaptureDevice.init(allocator, .{
        .sample_rate = .sr_44100,
        .channels = .stereo,
        .stream_type = .capture,
        .buffer_size = .buf_512,
        .ident = "hw:3,0",
    }) catch |err| {
        log.err("Failed to init device: {}", .{err});
        return;
    };

    defer dev.deinit() catch |err| {
        log.err("Failed to deinit device: {}", .{err});
    };

    dev.prepare() catch |err| {
        log.err("Failed to prepare device: {}", .{err});
    };

    var ctx = HalfDuplexCaptureContext{};

    dev.start(&ctx, @field(HalfDuplexCaptureContext, "callback")) catch |err| {
        log.err("Failed to start device: {}", .{err});
    };
}

// create a callback to probe the latency of the device
// the data argument will hold the latency information
fn probeCallback(data: latency.LatencyData) void {
    var actual_time_buf: [64]u8 = undefined;
    var expect_time_buf: [64]u8 = undefined;
    var total_latency_buf: [64]u8 = undefined;
    var avg_latency_buf: [64]u8 = undefined;
    var buffer_latency_buf: [64]u8 = undefined;
    var start_time_buf: [64]u8 = undefined;
    var end_time_buf: [64]u8 = undefined;

    // the time it tooks to process the frames
    const actual_time = data.actual_time.formatBuf(&actual_time_buf) catch |err| {
        // Note that you must catch errors in this callback as it is being called in the audio loop.
        // we don't want this kind of side effects to crash the audio loop
        log.warn("Failed to format actual time: {t}", .{err});
        return;
    };

    // the time it should have taken to process the frames vs what it actually took
    const expect_time = data.expect_time.formatBuf(&expect_time_buf) catch |err| {
        log.warn("Failed to format expect time: {t}", .{err});
        return;
    };

    // the latency introduced by the hardware buffering
    const buf_lat = data.buffer_latency.formatBuf(&buffer_latency_buf) catch |err| {
        log.warn("Failed to format buffer latency: {t}", .{err});
        return;
    };

    // the total latency acrued across the number of cycles (buffer_cycles)
    const total_latency = data.total_latency.formatBuf(&total_latency_buf) catch |err| {
        log.warn("Failed to format latency: {t}", .{err});
        return;
    };

    // the average latency for one cycle so basically total latency / buffer_cycles
    const average_latency = data.average_latency.formatBuf(&avg_latency_buf) catch |err| {
        log.warn("Failed to format average latency: {t}", .{err});
        return;
    };

    // the time the probe started
    const start_time = data.start_time.formatBuf(&start_time_buf) catch |err| {
        log.warn("Failed to format start time: {t}", .{err});
        return;
    };

    // the time the probe ended
    const end_time = data.end_time.formatBuf(&end_time_buf) catch |err| {
        log.warn("Failed to format end time: {t}", .{err});
        return;
    };

    log.info(
        \\
        \\ Start Time: {s}
        \\ End Time: {s}
        \\ Actual Time: {s}
        \\ Expected Time: {s}
        \\ Total Latency: {s}
        \\ Average Latency: {s}
        \\ Buffer Latency: {s}
        \\ Frames Processed: {d} frames
        \\ Buffers Processed: {d} 
    , .{
        start_time,
        end_time,
        actual_time,
        expect_time,
        total_latency,
        average_latency,
        buf_lat,
        data.frames_processed,
        data.cycles,
    });
}

pub fn fullDuplexCallbackWithLatencyProbe() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    var dev = FullDuplexDeviceWithProbe.init(allocator, .{
        .sample_rate = .sr_44100,
        .buffer_size = .buf_512,
        // you can have different channel configurations for playback and capture
        .channels = .{ .playback = .stereo, .capture = .stereo },
        // you can use different cards for playback and capture
        .ident = .{ .playback = "hw:3,0", .capture = "hw:3,0" },
        .probe_options = .{
            .callback = probeCallback,
            // the number buffer_size * n_periods to process before calculating the latency
            .buffer_cycles = 10,
        },
    }) catch |err| {
        log.err("Failed to init device: {t}", .{err});
        return;
    };

    defer dev.deinit() catch |err| {
        log.err("Failed to deinit device: {t}", .{err});
    };

    dev.prepare() catch |err| {
        log.err("Failed to prepare device: {t}", .{err});
    };

    var ctx = FullDuplexContext{};

    dev.start(&ctx, @field(FullDuplexContext, "callback")) catch |err| {
        log.err("Failed to start device: {any}", .{err});
    };
}

// Start devices with different cards for playback and capture
// sync is managed manually by the driver as oppose to relying on the alsa
//  Note that devices must be operating in the same sample rate, format and buffer size
//  otherwise the driver will fail to start the devices
pub fn fullDuplexCallbackUnlinkedDevices() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    var hardware = alsa.Hardware.init(allocator) catch |err| {
        log.err("Failed to initialize hardware: {t}", .{err});
        return;
    };

    defer hardware.deinit();

    // looking for my webcam card that contains capture
    const maybe_audio_card = hardware.findCardBy(.name, "Webcam");

    const audio_card: alsa.Hardware.AudioCard = maybe_audio_card orelse {
        log.err("Failed to find audio card", .{});
        return;
    };

    const capture = audio_card.getCaptureAt(0) catch |err| {
        log.err("Failed to get capture port: {t}", .{err});
        return;
    };

    std.debug.print("Capturing with: {f}", .{capture});

    const samples_rate = capture.selected_settings.sample_rate orelse {
        log.err("Failed to get capture sample rate", .{});
        return;
    };

    const channels = capture.selected_settings.channels orelse {
        log.err("Failed to get capture channels", .{});
        return;
    };

    // note: if playback does not support the capture sample rate, driver will fail to start
    var dev = FullDuplexDeviceWithProbe.init(allocator, .{
        .sample_rate = samples_rate,
        .channels = .{ .playback = .stereo, .capture = channels },
        .ident = .{ .playback = "hw:3,0", .capture = capture.identifier },
        .buffer_size = .buf_512,
        .n_periods = 8,
        .probe_options = .{
            .callback = probeCallback,
            // the number buffer_size * n_periods to process before calculating the latency
            .buffer_cycles = 40,
        },
    }) catch |err| {
        log.err("Failed to init device: {t}", .{err});
        return;
    };

    defer {
        dev.deinit() catch |err| {
            log.err("Failed to deinit device: {t}", .{err});
        };
    }

    dev.prepare() catch |err| {
        log.err("Failed to prepare device: {t}", .{err});
        return;
    };

    var ctx = FullDuplexContext{};

    dev.start(&ctx, @field(FullDuplexContext, "callback")) catch |err| {
        log.err("Failed to start device: {t}", .{err});
    };
}

pub fn printingHardwareInfo() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    // hardware holds information about your system's audio cards and ports
    var hardware = alsa.Hardware.init(allocator) catch |err| {
        log.err("Failed to start device: {}", .{err});
        return;
    };

    defer hardware.deinit();

    // To have an overview of the available audio cards, ports as well as their supported settings
    // you can just print the hardware object
    std.debug.print("{f}", .{hardware});
}

pub fn findAndPrintCardPortInfo(card_name: []const u8) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    // hardware holds information about your system's audio cards and ports
    var hardware = alsa.Hardware.init(allocator) catch |err| {
        log.err("Failed to start device: {}", .{err});
        return;
    };

    defer hardware.deinit();

    const found_card = hardware.findCardBy(.name, card_name);

    if (found_card) |card| {
        std.debug.print("{f}", .{card});
        return;
    }

    std.debug.print("Card {s} not found", .{card_name});
}

pub fn findingCardAndPortBy() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    var hardware = alsa.Hardware.init(allocator) catch |err| {
        log.err("Failed to start device: {}", .{err});
        return;
    };

    defer hardware.deinit();

    const found_card = hardware.findCardBy(.name, "webcam");

    if (found_card) |card| {
        // webcams don't have playback ports, generally :)
        const found_port = card.findCaptureBy(.name, "USB");

        std.debug.print("{?f}", .{found_port});
        return;
    }

    std.debug.print("Card not found", .{});
}

pub fn selectAudioPortCounterpart() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) log.err("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    var hardware = alsa.Hardware.init(allocator) catch |err| {
        log.err("Failed to initialize hardware: {}", .{err});
        return;
    };

    defer hardware.deinit();

    hardware.selectAudioCardBy(.name, "USB") catch |err| {
        log.err("Failed to select audio card: {}", .{err});
        return;
    };

    hardware.selectAudioPortBy(.playback, .name, "USB Audio #1") catch |err| {
        log.err("Failed to select audio port: {}", .{err});
        return;
    };
    const port = hardware.getSelectedAudioPort() catch |err| {
        log.err("Failed to get selected port: {}", .{err});
        return;
    };

    const counterpart = hardware.getSelectedAudioPortCounterpart() catch |err| {
        log.err("Failed to get counterpart: {}", .{err});
        return;
    };

    std.debug.print("SELECTED PORT:\n{f}", .{port});
    std.debug.print("COUNTERPART PORT:\n{f}", .{counterpart});
}

//This example shows how to use the hardware object to initialize a device
pub fn usingHardwareToInitDevice() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) log.err("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    // hardware holds information about your system's audio cards and ports
    var hardware = alsa.Hardware.init(allocator) catch |err| {
        log.err("Failed to initialize hardware: {}", .{err});
        return;
    };

    defer hardware.deinit();

    // To have an overview of the available audio cards, ports as well as their supported settings
    // you can just print the hardware object
    //
    //  std.debug.print("{f}", .{hardware});
    //
    //  For every card and port there is a hint on how to select an specific card or port. You can use those instead selecting by name
    //     ├──  Select Methods:
    //     │    │  hardware.selectPortAt(.playback, 0)
    //     │    │  card.selectPlaybackAt(0)
    //     │    └──
    //

    // select the audio card and port
    // by index
    // hardware.selectAudioCardAt(3) catch |err| {
    //     log.err("Failed to select audio card: {}", .{err});
    //     return;
    // };

    // or by name / alsa id. Harware attempts to match the name with the card's name or id
    // Replace "Audio" with the name of your card
    hardware.selectAudioCardBy(.name, "Audio") catch |err| {
        log.err("Failed to select audio card: {}", .{err});
        return;
    };

    // by index
    // hardware.selectAudioPortAt(.playback, 0) catch |err| {
    //     log.err("Failed to select audio port: {}", .{err});
    //     return;
    // };

    // or again by name / alsa id. Note that this function will return the first match
    // For my audio Card for Example the Ports are all called USB Audio #1, USB Audio #2, etc
    //  So I need to be specific
    //  Replace "USB Audio #1" with the name of your port
    hardware.selectAudioPortBy(.playback, .name, "USB Audio #1") catch |err| {
        log.err("Failed to select audio port: {}", .{err});
        return;
    };

    hardware.setSelectedFormat(.signed_16bits_little_endian) catch |err| {
        // hardware will fail to select if the setting is not supported by the hardware
        log.err("Format settings not supported: {}", .{err});
        return;
    };

    hardware.setSelectedChannelCount(.stereo) catch |err| {
        log.err("Channel settings not supported: {}", .{err});
        return;
    };

    hardware.setSelectedSampleRate(.sr_44100) catch |err| {
        log.err("Sample rate settings not supported: {}", .{err});
        return;
    };

    // now you can initialize the device knowing that your settings are supported
    //  The hardware object will provide the basic info to initialize the device
    //  but it is possible to configure the device with more options.
    //  Below an example of setting the buffer size
    var device = HalfDuplexDevice.fromHardware(allocator, hardware, .{ .buffer_size = .buf_1024 }) catch |err| {
        log.err("Failed to init device: {}", .{err});
        return;
    };

    defer device.deinit() catch |err| {
        log.err("Failed to deinit device: {}", .{err});
    };

    //printing the devices format for an overview
    std.debug.print("{f}", .{device});

    // Prepare the device for playback with the minimum available strategy
    device.prepare() catch |err| {
        std.debug.print("Failed to prepare device: {}", .{err});
        return;
    };
}

// This example shows how to manually use your hardware information to initialize a device
pub fn manuallyInitializingDevice() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) std.debug.print("Failed to deinit allocator.", .{});

    const allocator = gpa.allocator();

    // hardware holds information about your system's audio cards and ports
    var hardware = alsa.Hardware.init(allocator) catch |err| {
        std.debug.print("Failed to initialize hardware: {}", .{err});
        return;
    };

    defer hardware.deinit();

    // grab the first audio card and the first playback port
    const card = hardware.getAudioCardByIdent("hw:0") catch |err| {
        std.debug.print("Failed to get audio card: {}", .{err});
        return;
    };
    const playback = card.getPlaybackAt(0) catch |err| {
        std.debug.print("Failed to get playback port: {}", .{err});
        return;
    };

    // you can check the supported settings for the card and port
    // playback.supported_settings.?.formats
    // playback.supported_settings.?.channels
    // playback.supported_settings.?.sample_rates

    // device will fail if settings are not supported by the hardware
    var device = HalfDuplexDevice.init(allocator, .{
        // you must provide sample rate, chnanels, format and steam type.
        .sample_rate = .sr_44100,
        .channels = .stereo,
        .stream_type = .playback,
        .ident = playback.identifier,
    }) catch |err| {
        std.debug.print("Failed to init device: {}", .{err});
        return;
    };

    defer device.deinit() catch |err| {
        std.debug.print("Failed to deinit device: {}", .{err});
    };

    std.debug.print("{f}", .{device});

    device.prepare() catch |err| {
        std.debug.print("Failed to prepare device: {}", .{err});
    };
}
