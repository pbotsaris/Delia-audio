//! Top-level examples: the pieces wired together. The M4a one plays an `ExecutionPlan`
//! through `backends.alsa.device.PlaybackDevice` (docs/backend-contract.md, section 9:
//! the fan-in graph from `graph.examples` on `hw:`, 60 s at 512/48000, zero xruns).
//!
//! Shape of it: a Ctx struct owns the plan and a pool slot sized `plan.max_frames`; its
//! callback sub-blocks `out` into graph blocks and calls `plan.render` on each. The plan is
//! compiled against `device.negotiated.sample_rate`, not the requested rate.
const std = @import("std");
const graph = @import("graph");
const backends = @import("backends");
const audio_specs = @import("common").audio_specs;

const log = std.log.scoped(.main);
