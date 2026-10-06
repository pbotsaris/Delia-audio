const std = @import("std");
const c = @cImport({
    @cInclude("asoundlib.h");
});

const SampleFormat = @import("./convert.zig").SampleFormat;

pub const DeviceError = error{
    open_failed,
    hw_params_invalid,
    area_geometry_invalid,
    sw_params_invalid,
    access_unsupported, // only MMAP_INTERLEAVED for now
    format_unsupported,
    rate_unsupported,
    channels_unsupported,
    period_changed, // the hardware moved period or buffer size away from the request
    write_failed,
    not_prepared, // the device is not prepared for writing
} || std.mem.Allocator.Error;


// pub fn PlaybackDevice(comptime: Ctx, type, comptime fmt: SampleFormat){
//
// }
