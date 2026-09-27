const std = @import("std");

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

pub fn stateToStr(state: c_uint) []const u8 {
    return switch (state) {
        c_alsa.SND_PCM_STATE_OPEN => "OPEN",
        c_alsa.SND_PCM_STATE_SETUP => "SETUP",
        c_alsa.SND_PCM_STATE_PREPARED => "PREPARED",
        c_alsa.SND_PCM_STATE_RUNNING => "RUNNING",
        c_alsa.SND_PCM_STATE_XRUN => "XRUN",
        c_alsa.SND_PCM_STATE_DRAINING => "DRAINING",
        c_alsa.SND_PCM_STATE_PAUSED => "PAUSED",
        c_alsa.SND_PCM_STATE_SUSPENDED => "SUSPENDED",
        c_alsa.SND_PCM_STATE_DISCONNECTED => "DISCONNECTED",
        else => "UNKNOWN",
    };
}

pub fn tstampToStr(tstamp_status: c_alsa.snd_pcm_tstamp_t) []const u8 {
    return switch (tstamp_status) {
        c_alsa.SND_PCM_TSTAMP_NONE => "NONE",
        c_alsa.SND_PCM_TSTAMP_ENABLE => "ENABLE",
        else => "UNKNOWN",
    };
}

/// Blocks the calling thread for `ns` nanoseconds. Resumes the sleep if a signal interrupts it.
pub fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;

    while (std.c.nanosleep(&req, &rem) != 0) {
        if (std.c.errno(-1) != .INTR) return;
        req = rem;
    }
}
