//! Backend-only examples: a device, a Ctx and a callback, no graph. Candidates: a sine on
//! `PlaybackDevice(Ctx, .s16_le)` with `stop()` from a second thread; printing `getStats()`
//! after a run; opening `null` versus `hw:` and comparing `negotiated` with the request.
//! Graph playback lives in `src/examples.zig`.
const std = @import("std");
const buffer = @import("buffer");
const device = @import("device.zig");

const log = std.log.scoped(.alsa);
