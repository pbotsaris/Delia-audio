const std = @import("std");

/// The module's only `@cImport`: every file that touches alsa-lib goes through this one, since
/// each `@cImport` yields its own distinct opaque `snd_pcm_t`.
pub const c = @cImport({
    @cInclude("asoundlib.h");
});

pub const PcmError = error{
    xrun,
    suspended,
    io,
    timeout,
};

pub const Region = struct {
    bytes: []u8,
    frame_count: usize,
};

pub const RecoverOption = struct {
    retries: usize,
    sleep_ms: u64,
};

/// The seam over `snd_pcm_*` (contract section 7). Converts negative results to errors and
/// computes the region slice from `areas`, `offset` and `step`. No policy lives here.
pub const AlsaPcm = struct {
    const Self = @This();

    handle: *c.snd_pcm_t,
    bytes_per_frame: usize,
    offset: c.snd_pcm_uframes_t = 0,
    recover_option: RecoverOption = .{ .retries = 5, .sleep_ms = 10 },

    pub fn availUpdate(self: *Self) PcmError!usize {
        const avail = c.snd_pcm_avail_update(self.handle);
        if (avail < 0) return errnoToPcm(avail);

        return @intCast(avail);
    }

    pub fn start(self: *Self) PcmError!void {
        const result = c.snd_pcm_start(self.handle);
        if (result < 0) return errnoToPcm(result);
    }

    pub fn wait(self: *Self, timeout_ms: u32) PcmError!void {
        const result = c.snd_pcm_wait(self.handle, @intCast(timeout_ms));

        // 0 means timeout elapsed, not successful wait, so we return a timeout error
        if (result == 0) return PcmError.timeout;

        if (result < 0) return errnoToPcm(result);
    }

    pub fn mmapBegin(self: *Self, frame_count_wanted: usize) PcmError!Region {
        var areas: ?*const c.snd_pcm_channel_area_t = null;
        var frames: c.snd_pcm_uframes_t = @intCast(frame_count_wanted);

        const result = c.snd_pcm_mmap_begin(self.handle, &areas, &self.offset, &frames);
        if (result < 0) return errnoToPcm(result);

        // interleaved access: one area describes every channel; geometry was validated at prepare
        const area = areas orelse return PcmError.io;

        return regionFromArea(area, self.offset, frames, self.bytes_per_frame) orelse PcmError.io;
    }

    pub fn mmapCommit(self: *Self, frame_count: usize) PcmError!usize {
        const result = c.snd_pcm_mmap_commit(self.handle, self.offset, @intCast(frame_count));
        if (result < 0) return errnoToPcm(result);

        return @intCast(result);
    }

    /// xrun: prepare. suspended: resume until the device stops saying EAGAIN, then prepare if
    /// resume still failed. Bounded by `recover_option`.
    pub fn recover(self: *Self, err: PcmError) PcmError!void {
        if (err == PcmError.suspended) {
            var retries = self.recover_option.retries;
            var result = c.snd_pcm_resume(self.handle);

            while (result == -c.EAGAIN and retries > 0) : (retries -= 1) {
                sleepMs(self.recover_option.sleep_ms);
                result = c.snd_pcm_resume(self.handle);
            }

            if (result >= 0) return;
        }

        const result = c.snd_pcm_prepare(self.handle);
        if (result < 0) return errnoToPcm(result);
    }

    pub fn state(self: *Self) c.snd_pcm_state_t {
        return c.snd_pcm_state(self.handle);
    }

    /// Geometry of the mmap area without transferring anything: begin(0) then commit(0).
    /// The device calls this once at prepare to validate `first` and `step`.
    pub fn inspectArea(self: *Self) PcmError!c.snd_pcm_channel_area_t {
        _ = try self.availUpdate();

        var areas: ?*const c.snd_pcm_channel_area_t = null;
        var frames: c.snd_pcm_uframes_t = 0;

        const result = c.snd_pcm_mmap_begin(self.handle, &areas, &self.offset, &frames);
        if (result < 0) return errnoToPcm(result);

        const area = (areas orelse return PcmError.io).*;
        _ = try self.mmapCommit(0);

        return area;
    }

    /// `result` is a negative ALSA result: c_int from most calls, snd_pcm_sframes_t from avail/commit.
    fn errnoToPcm(result: anytype) PcmError {
        const errno: c_int = @intCast(-result);

        return switch (errno) {
            c.EPIPE => error.xrun,
            c.ESTRPIPE => error.suspended,
            else => error.io,
        };
    }

    /// Pure arithmetic over an interleaved area, separated so it can be tested without a device.
    /// Returns null when the area's stride disagrees with the negotiated frame size.
    fn regionFromArea(area: *const c.snd_pcm_channel_area_t, offset: c.snd_pcm_uframes_t, frame_count: c.snd_pcm_uframes_t, bytes_per_frame: usize) ?Region {
        const step_bytes: usize = area.step / 8;
        if (step_bytes != bytes_per_frame) return null;

        const addr: [*]u8 = @ptrCast(area.addr orelse return null);
        const start_at: usize = area.first / 8 + offset * step_bytes;
        return .{ .bytes = addr[start_at..][0 .. frame_count * step_bytes], .frame_count = frame_count };
    }

    fn sleepMs(ms: u64) void {
        var req: std.c.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };

        _ = std.c.nanosleep(&req, null);
    }
};

test "regionFromArea rejects a stride that disagrees with the frame size, slices otherwise" {
    var storage: [64]u8 = undefined;
    const area: c.snd_pcm_channel_area_t = .{ .addr = &storage, .first = 0, .step = 4 * 8 }; // 4 bytes/frame

    try std.testing.expectEqual(null, AlsaPcm.regionFromArea(&area, 0, 4, 8));

    const region = AlsaPcm.regionFromArea(&area, 2, 3, 4).?;
    try std.testing.expectEqual(3, region.frame_count);
    try std.testing.expectEqual(12, region.bytes.len);
    try std.testing.expectEqual(@intFromPtr(&storage[8]), @intFromPtr(region.bytes.ptr));
}

test "errnoToPcm maps EPIPE and ESTRPIPE, everything else is io" {
    try std.testing.expectEqual(PcmError.xrun, AlsaPcm.errnoToPcm(@as(c_int, -c.EPIPE)));
    try std.testing.expectEqual(PcmError.suspended, AlsaPcm.errnoToPcm(@as(c_long, -c.ESTRPIPE)));
    try std.testing.expectEqual(PcmError.io, AlsaPcm.errnoToPcm(@as(c_int, -c.EBADFD)));
}
