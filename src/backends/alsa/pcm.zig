const std = @import("std");

const c = @cImport({
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
    sleep_ms: usize,
};

pub const AlsaPcm = struct {
    const Self = @This();

    handle: *c.snd_pcm_t,
    bytes_per_frame: usize,
    offset: c.snd_pcm_uframes_t = 0,
    recover_option: RecoverOption = .{ .retries = 5, .sleep_ms = 10 },

    pub fn availUpdate(self: *Self) PcmError!usize {
        const avail: c_long = c.snd_pcm_avail_update(self.handle);
        if (avail < 0) return self.errnoToPcm(avail);

        return @intCast(avail);
    }

    pub fn start(self: *Self) PcmError!void {
        const result = c.snd_pcm_start(self.handle);
        if (result < 0) return self.errnoToPcm(result);
    }

    pub fn wait(self: *Self, timeout_ms: u32) PcmError!void {
        const result = c.snd_pcm_wait(self.handle, @intCast(timeout_ms));

        // 0 means timeout elapsed, not successful wait, so we return a timeout error
        if (result == 0) return PcmError.timeout;

        if (result < 0) return errnoToPcm(result);
    }

    pub fn mmapBegin(self: *Self, frame_count_wanted: usize) PcmError!void {
        var areas: ?*const c.snd_pcm_channel_area_t = null;
        var frames: c.snd_pcm_uframes_t = @intCast(frame_count_wanted);

        const result = c.snd_pcm_mmap_begin(self.handle, &areas, &self.offset, &frames);
        if (result < 0) return self.errnoToPcm(result);

        // interleaved access: one area describes every channel; geometry was validated at prepare
        const area = areas orelse return PcmError.io;

        return regionFromArea(area, self.offset, frames, self.bytes_per_frame) orelse PcmError.io;
    }

    pub fn mmapCommit(self: *Self, frame_count: usize) PcmError!void {
        const result = c.snd_pcm_mmap_commit(self.handle, self.offset, @intCast(frame_count));
        if (result < 0) return self.errnoToPcm(result);

        return @intCast(result);
    }

    pub fn recover(self: *Self, err: PcmError) PcmError!void {
        const retries = self.recover_option.retries;
        const sleep_ms = self.recover_option.sleep_ms;

        if (err == PcmError.suspended) {
            const result = c.snd_pcm_resume(self.handle);
            while (result == -c.EAGAIN and retries > 0) : (retries -= 1) {
                sleepMs(sleep_ms);
                result = c.snd_pcm_resume(self.handle);
            }

            if (result >= 0) return;
        }

        const result = c.snd_pcm_prepare(self.handle);
        if (result < 0) return self.errnoToPcm(result);
    }

    fn errnoToPcm(result: anytype) PcmError {
        // integer types diverge between alsa calls start returns c_int and avail_update returns c_long
        const errno: c_int = @intCast(result);

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
