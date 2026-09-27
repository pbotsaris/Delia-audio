const std = @import("std");
const dsp = @import("dsp/dsp.zig");
const zbench = @import("zbench");

fn fftPowerOfTwo(allocator: std.mem.Allocator) void {
    const transform = dsp.transforms.FourierDynamic(f32);

    var w = dsp.waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [4096]f32 = undefined;
    const sine = w.sine(&buffer);

    var out = transform.fft(allocator, sine) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };

    out.deinit();
}

fn fftNonPowerOfTwo(allocator: std.mem.Allocator) void {
    const transform = dsp.transforms.FourierDynamic(f32);
    var w = dsp.waves.Wave(f32).init(400.0, 1.0, 44100.0);

    var buffer: [4099]f32 = undefined;
    const sine = w.sine(&buffer);

    var out = transform.fft(allocator, sine) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };

    out.deinit();
}

fn fftStatic(allocator: std.mem.Allocator) void {
    const transform = dsp.transforms.FourierStatic(f32, .wz_4096);

    var w = dsp.waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [4096]f32 = undefined;
    const sine = w.sine(&buffer);

    // this could easily be a fixed-size allocator and would improve performance
    // as complex vector is always modified in place
    var complex_list = transform.ComplexList.initFrom(allocator, sine) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };

    defer complex_list.deinit();

    complex_list = transform.fft(&complex_list) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
}

fn sineWave(_: std.mem.Allocator) void {
    var w = dsp.waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [4096]f32 = undefined;

    const sine = w.sine(&buffer);
    _ = sine;

    return;
}

fn sineWaveSampleBySample(_: std.mem.Allocator) void {
    var w = dsp.waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [4096]f32 = undefined;

    for (0..buffer.len) |i| {
        buffer[i] = w.sineSample();
    }

    return;
}

fn vectorizedSineWave(_: std.mem.Allocator) void {
    var w = dsp.waves.VectorizedWave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [4096]f32 = undefined;

    const sine = w.sine(&buffer);
    _ = sine;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    try bench.add("fft power-of-2", fftPowerOfTwo, .{});
    try bench.add("fft non power-of-2", fftNonPowerOfTwo, .{});
    try bench.add("fft static", fftStatic, .{});
    try bench.add("sin", sineWave, .{});
    try bench.add("sin smpl by smpl", sineWaveSampleBySample, .{});
    try bench.add("vec sine", vectorizedSineWave, .{});
    try bench.run(init.io, std.Io.File.stdout());
}
