const std = @import("std");
const utils = @import("utils.zig");

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

const log = std.log.scoped(.alsa);

const s_to_us = 1_000_000;

pub fn noopCallback(_: LatencyData) void {}

const ProbeOptions = struct {
    sample_rate: u32,
    hardware_buffer_size: u32,
    buffer_cycles: u32 = 3,
};

/// LatencyData struct is passed in to the user-defined callback function
/// when a probe is complete
pub const LatencyData = struct {
    start_time: TimeSpec,
    end_time: TimeSpec,
    expect_time: TimestampDiff,
    actual_time: TimestampDiff,
    total_latency: TimestampDiff,
    average_latency: TimestampDiff,
    buffer_latency: TimestampDiff,
    frames_processed: usize,
    cycles: u32,
};

pub const ProbeCallback = *const fn (probe: LatencyData) void;

/// Probe struct is used to measure the latency of an audio device
pub const Probe = struct {
    /// The time the probe was started
    start_time: ?TimeSpec = null,
    /// The harware buffer size, or the number of per cycle.
    hardware_buffer_size: u32,
    /// The sample rate of the audio device
    sample_rate: u32,
    /// The number of hardware buffer cycles the probe will run before calculating the latency
    buffer_cycles: u32,
    /// Counts the number of frames processed to calculate the expected time
    frames_processed: usize = 0,
    /// The maximum number of frames to process before calculating the latency
    max_frames: usize,
    /// The user-defined callback function that is called when the probe is complete
    callback: ProbeCallback,
    /// The latency introduced by the hardware buffering
    buffer_latency: TimestampDiff,

    pub fn init(callback: ProbeCallback, opts: ProbeOptions) Probe {
        const buff_latency_micros = opts.hardware_buffer_size * s_to_us / opts.sample_rate;

        return .{
            .sample_rate = opts.sample_rate,
            .hardware_buffer_size = opts.hardware_buffer_size,
            .frames_processed = 0,
            .buffer_cycles = opts.buffer_cycles,
            .max_frames = opts.buffer_cycles * opts.hardware_buffer_size,
            .callback = callback,
            .buffer_latency = TimestampDiff.fromMicros(buff_latency_micros),
        };
    }

    /// Start the probe
    pub fn start(self: *Probe) void {
        self.start_time = getMonotonicTime() catch {
            return;
        };
    }

    /// Called in the audio loop as it processes frames to count the number of frames processed
    pub fn addFrames(self: *Probe, frames: c_long) void {
        self.frames_processed += @intCast(frames);

        if (self.frames_processed >= self.max_frames) {
            self.calcLatency();
            self.reset();
        }
    }

    /// Reset the probe to start a new measurement
    pub fn reset(self: *Probe) void {
        self.start_time = getMonotonicTime() catch {
            return;
        };

        self.frames_processed = 0;
    }

    /// Calculate the latency and call the user-defined callback function
    pub fn calcLatency(self: *Probe) void {
        const now = getMonotonicTime() catch {
            return;
        };

        const expect_time = TimestampDiff.fromMicros(self.framesToMicros());

        const start_time = self.start_time orelse {
            log.warn("Failed to calculate latency. Start time is null.", .{});
            return;
        };

        const actual_time = start_time.diff(now);

        const latency = actual_time.diff(expect_time);

        const data = LatencyData{
            .start_time = start_time,
            .end_time = now,
            .actual_time = actual_time,
            .expect_time = expect_time,
            .total_latency = latency,
            .average_latency = latency.div(@as(i64, @intCast(self.buffer_cycles))),
            .buffer_latency = self.buffer_latency,
            .frames_processed = self.frames_processed,
            .cycles = self.buffer_cycles,
        };

        self.callback(data);
    }

    pub inline fn framesToMicros(self: Probe) i64 {
        return @intCast(@divFloor(self.frames_processed * s_to_us, self.sample_rate));
    }
};

/// TimeSpec struct represents the timestamp returned by alsa's clock_gettime function
const TimeSpec = struct {
    tv_sec: i64 = 0,
    tv_nsec: i64 = 0,

    /// Compute the difference between two TimeSpec structs
    /// Returns TimpstampDiff struct
    pub fn diff(start: TimeSpec, end: TimeSpec) TimestampDiff {
        var difference = TimeSpec{};

        if (end.tv_nsec < start.tv_nsec) {
            difference.tv_sec = end.tv_sec - start.tv_sec - 1;
            difference.tv_nsec = 1_000_000_000 + end.tv_nsec - start.tv_nsec;
        } else {
            difference.tv_sec = end.tv_sec - start.tv_sec;
            difference.tv_nsec = end.tv_nsec - start.tv_nsec;
        }
        return difference.toDiffStruct();
    }

    fn toDiffStruct(self: TimeSpec) TimestampDiff {
        return .{
            .sec = self.tv_sec,
            .usec = @divFloor(self.tv_nsec, 1000),
        };
    }

    /// Formats TimeSpec as a string in the format e.g. "1h 10m 1s 2ms 3us"
    /// Truncates the resolution to microseconds
    pub fn formatBuf(self: TimeSpec, buf: []u8) ![]u8 {
        var sec = self.tv_sec;
        var nsec = self.tv_nsec;

        // Handle negative values
        const is_negative = sec < 0 or nsec < 0;

        if (is_negative) {
            if (nsec > 0) {
                // borrow a sec
                sec += 1;
                nsec -= 1_000_000_000;
            }

            sec = -sec;
            nsec = -nsec;
        }

        const total_seconds = sec;
        const hours = @divTrunc(total_seconds, 3600);
        const minutes = @divTrunc(@mod(total_seconds, 3600), 60);
        const seconds = @mod(total_seconds, 60);
        const millis = @divTrunc(nsec, 1_000_000);
        const micros = @mod(@divTrunc(nsec, 1000), 1000);

        const sign = if (is_negative) "-" else "";

        if (hours > 0) {
            return std.fmt.bufPrint(buf, "{s}{d}h {d}m {d}s {d}ms {d}us", .{ sign, hours, minutes, seconds, millis, micros });
        }

        if (minutes > 0) return std.fmt.bufPrint(buf, "{s}{d}m {d}s {d}ms {d}us", .{ sign, minutes, seconds, millis, micros });
        if (seconds > 0) return std.fmt.bufPrint(buf, "{s}{d}s {d}ms {d}us", .{ sign, seconds, millis, micros });
        if (millis > 0) return std.fmt.bufPrint(buf, "{s}{d}ms {d}us", .{ sign, millis, micros });

        return std.fmt.bufPrint(buf, "{s}{d}us", .{ sign, micros });
    }

    /// Convert TimeSpec to microseconds as an integer
    /// Truncates the resolution to microseconds
    pub fn toMicros(self: TimeSpec) i64 {
        return self.tv_sec * 1_000_000 + @divFloor(self.tv_nsec, 1000);
    }

    /// Convert TimeSpec to microseconds as an integer
    /// Truncates the resolution to microseconds
    pub fn toMillis(self: TimeSpec) f64 {
        const total_micros: f64 = @floatFromInt(self.toMicros());
        return total_micros / 1000.0;
    }
};

fn getMonotonicTime() !TimeSpec {
    var timespec: c_alsa.timespec = undefined;
    const err = c_alsa.clock_gettime(c_alsa.CLOCK_MONOTONIC_RAW, &timespec);

    if (err != 0) {
        log.warn("Could not start latency.Probe. Failed to get current time: {s} ", .{c_alsa.snd_strerror(err)});
        return error.ClockError;
    }
    return .{
        .tv_sec = @intCast(timespec.tv_sec),
        .tv_nsec = @intCast(timespec.tv_nsec),
    };
}

/// The TimestampDiff struct represents a difference between two timestamps
/// It converts the resolution to microseconds from a TimeSpec struct
pub const TimestampDiff = struct {
    sec: i64,
    usec: i64,

    fn diff(self: TimestampDiff, other: TimestampDiff) TimestampDiff {
        var sec = self.sec - other.sec;
        var usec = self.usec - other.usec;

        if (usec < 0) {
            sec -= 1;
            usec += 1_000_000;
        }

        return .{
            .sec = sec,
            .usec = usec,
        };
    }

    fn sum(self: TimestampDiff, other: TimestampDiff) TimestampDiff {
        var sec = self.sec + other.sec;
        var usec = self.usec + other.usec;

        if (usec >= 1_000_000) {
            sec += 1;
            usec -= 1_000_000;
        }

        return .{
            .sec = sec,
            .usec = usec,
        };
    }

    fn div(self: TimestampDiff, divisor: i64) TimestampDiff {
        if (divisor <= 0) {
            log.warn("latency.TimestampDiff: Cannot divide by zero.", .{});
            return self;
        }

        const self_micros = self.toMicros();
        return TimestampDiff.fromMicros(@divFloor(self_micros, divisor));
    }

    fn fromMicros(micros: i64) TimestampDiff {
        var sec = @divTrunc(micros, 1_000_000);
        var usec = @rem(micros, 1_000_000);

        if (usec < 0) {
            sec -= 1;
            usec += 1_000_000;
        }

        return .{ .sec = sec, .usec = usec };
    }

    /// Convert TimestampDiff to microseconds as an integer
    /// Truncates the resolution to microseconds
    pub fn toMicros(self: TimestampDiff) i64 {
        return (self.sec * 1_000_000 + self.usec);
    }

    /// Convert TimestampDiff to milliseconds as a float
    /// Truncates the resolution to microseconds
    pub fn toMillis(self: TimestampDiff) f64 {
        const total_micros: f64 = @floatFromInt(self.toMicros());
        return total_micros / 1000.0;
    }

    /// Formats TimeSpec as a string in the format e.g. "1s 2ms 3us"
    /// If the value is less than 1 second, the seconds are omitted
    /// Truncates the resolution to microseconds
    pub fn formatBuf(self: TimestampDiff, buf: []u8) ![]u8 {
        var micros = self.toMicros();

        const is_negative = micros < 0;

        if (is_negative) {
            micros = -micros;
        }

        const total_millis = @divTrunc(micros, 1000);
        const whole_seconds = @divTrunc(total_millis, 1000);
        const remaining_millis = @mod(total_millis, 1000);
        const remaining_micros = @mod(micros, 1000);

        if (whole_seconds > 0) {
            return std.fmt.bufPrint(buf, "{s}{d}s {d}ms {d}us", .{
                if (is_negative) "-" else "",
                whole_seconds,
                remaining_millis,
                remaining_micros,
            });
        }
        if (remaining_millis > 0) {
            return std.fmt.bufPrint(buf, "{s}{d}ms {d}us", .{
                if (is_negative) "-" else "",
                remaining_millis,
                remaining_micros,
            });
        }
        return std.fmt.bufPrint(buf, "{s}{d}us", .{ if (is_negative) "-" else "", remaining_micros });
    }
};
