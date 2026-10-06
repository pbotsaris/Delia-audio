//! Design sketch for docs/graph-contract.md section 2: the node interface and the first two
//! nodes, before the builder/compiler/plan exist. Not part of the build.
//!
//!     zig test docs/examples/graph_node_sketch.zig
//!
//! A file under docs/ cannot import src/, so the block types and the oscillator below are
//! minimal stand-ins. In src/ they are replaced by:
//!
//!     buffer   = @import("buffer")     AudioBlock, ConstAudioBlock, ProcessContext
//!     specs    = @import("../common/audio_specs.zig")     BlockSize for PrepareContext.max_frames
//!     dsp      = @import("../dsp/dsp.zig")                waves.Wave(T).sine for the Sine node
//!
//! The parts worth implementing as written are marked "port as is".

const std = @import("std");

// ---------------------------------------------------------------------------
// Stand-ins for src/core/buffer/root.zig. Same field names and channel() rule; no validation.
// ---------------------------------------------------------------------------

fn requireFloat(comptime T: type, comptime name: []const u8) void {
    if (T != f32 and T != f64) @compileError(name ++ " only supports f32 and f64");
}

pub fn ConstAudioBlock(comptime T: type) type {
    return struct {
        samples: []const T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn channel(self: @This(), c: usize) []const T {
            std.debug.assert(c < self.channel_count);
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
        }
    };
}

pub fn AudioBlock(comptime T: type) type {
    return struct {
        samples: []T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn channel(self: @This(), c: usize) []T {
            std.debug.assert(c < self.channel_count);
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
        }

        pub fn asConst(self: @This()) ConstAudioBlock(T) {
            return .{
                .samples = self.samples,
                .channel_count = self.channel_count,
                .frame_count = self.frame_count,
                .channel_stride = self.channel_stride,
            };
        }
    };
}

pub fn ProcessContext(comptime T: type) type {
    return struct {
        inputs: []const ConstAudioBlock(T),
        outputs: []const AudioBlock(T),
        frame_count: usize,
    };
}

// ---------------------------------------------------------------------------
// Node interface. Port as is into src/graph/node.zig, swapping the stand-ins for real imports.
// ---------------------------------------------------------------------------

/// Port counts are fixed per node type. The compiler reads them to validate edges and to size
/// the per-op input/output slices; nothing at render time consults them.
pub const Ports = struct {
    inputs: u8,
    outputs: u8,
};

pub const NodeError = error{allocation_error};

pub fn Node(comptime T: type) type {
    requireFloat(T, "Node");

    return struct {
        const Self = @This();

        pub const PrepareContext = struct {
            sample_rate: T,
            /// Declared maximum. In src this is specs.BlockSize; the sketch has no enum to borrow.
            max_frames: usize,
            channel_count: usize,
        };

        pub const VTable = struct {
            name: *const fn (*anyopaque) []const u8,
            prepare: *const fn (*anyopaque, PrepareContext) NodeError!void,
            process: *const fn (*anyopaque, ProcessContext(T)) void,
            destroy: *const fn (*anyopaque, std.mem.Allocator) void,
        };

        ptr: *anyopaque,
        vtable: *const VTable,
        ports: Ports,

        /// Heap-copies `node` so the builder can hand out stable pointers. Paired with `destroy`.
        pub fn createNode(allocator: std.mem.Allocator, node: anytype) NodeError!Self {
            const ptr = allocator.create(@TypeOf(node)) catch return error.allocation_error;
            ptr.* = node;

            return init(ptr);
        }

        /// Wraps an existing single-item pointer. All interface checks happen here, at comptime.
        pub fn init(ptr: anytype) Self {
            const PtrType = @TypeOf(ptr);
            const ptr_info = @typeInfo(PtrType);

            if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
                @compileError("Node.init requires a pointer to a single struct");
            }

            const Impl = @TypeOf(ptr.*);
            const impl_name = @typeName(Impl);

            if (!@hasDecl(Impl, "ports")) {
                @compileError(impl_name ++ " must declare `pub const ports: Ports`");
            }
            if (@TypeOf(Impl.ports) != Ports) {
                @compileError(impl_name ++ ".ports must be of type Ports");
            }
            inline for (.{ "name", "prepare", "process" }) |decl| {
                if (!@hasDecl(Impl, decl)) {
                    @compileError(impl_name ++ " must implement `" ++ decl ++ "`");
                }
            }

            const gen = struct {
                fn nameFn(ctx: *anyopaque) []const u8 {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    return self.name();
                }

                fn prepareFn(ctx: *anyopaque, prepare_ctx: PrepareContext) NodeError!void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    try self.prepare(prepare_ctx);
                }

                fn processFn(ctx: *anyopaque, process_ctx: ProcessContext(T)) void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    self.process(process_ctx);
                }

                fn destroyFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                    const self: PtrType = @ptrCast(@alignCast(ctx));
                    allocator.destroy(self);
                }

                const vtable: VTable = .{
                    .name = nameFn,
                    .prepare = prepareFn,
                    .process = processFn,
                    .destroy = destroyFn,
                };
            };

            return .{
                .ptr = ptr,
                .vtable = &gen.vtable,
                .ports = Impl.ports,
            };
        }

        pub fn name(self: Self) []const u8 {
            return self.vtable.name(self.ptr);
        }

        pub fn prepare(self: Self, ctx: PrepareContext) NodeError!void {
            try self.vtable.prepare(self.ptr, ctx);
        }

        pub fn process(self: Self, ctx: ProcessContext(T)) void {
            std.debug.assert(ctx.inputs.len == self.ports.inputs);
            std.debug.assert(ctx.outputs.len == self.ports.outputs);

            self.vtable.process(self.ptr, ctx);
        }

        /// Only for nodes made by `createNode`. The builder calls this from its `deinit`.
        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            self.vtable.destroy(self.ptr, allocator);
        }
    };
}

// ---------------------------------------------------------------------------
// Gain. Port as is into src/graph/nodes/gain.zig.
// ---------------------------------------------------------------------------

pub fn Gain(comptime T: type) type {
    requireFloat(T, "Gain");

    return struct {
        gain: T,

        const Self = @This();
        pub const ports: Ports = .{ .inputs = 1, .outputs = 1 };

        pub fn name(_: *Self) []const u8 {
            return "Gain";
        }

        pub fn prepare(_: *Self, _: Node(T).PrepareContext) NodeError!void {}

        pub fn process(self: *Self, ctx: ProcessContext(T)) void {
            const in = ctx.inputs[0];
            const out = ctx.outputs[0];

            for (0..out.channel_count) |ch| {
                for (out.channel(ch), in.channel(ch)) |*o, i| o.* = i * self.gain;
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Sine. Port into src/graph/nodes/sine.zig with `wave: dsp.waves.Wave(T)` in place of the
// stand-in below; `Wave.init(freq, amp, sr)`, `setSampleRate` and `sine(output)` already exist
// with these signatures in src/dsp/waves.zig.
// ---------------------------------------------------------------------------

/// Stand-in for dsp.waves.Wave(T): same fields and methods the node uses, nothing else.
fn Wave(comptime T: type) type {
    return struct {
        freq: T,
        amp: T,
        sr: T,
        phase: T = 0,
        inc: T = 0,

        const two_pi: T = 2 * std.math.pi;

        pub fn init(freq: T, amp: T, sr: T) @This() {
            return .{ .freq = freq, .amp = amp, .sr = sr, .inc = two_pi * freq / sr };
        }

        pub fn setSampleRate(self: *@This(), sr: T) void {
            self.sr = sr;
            self.inc = two_pi * self.freq / sr;
        }

        pub fn sine(self: *@This(), output: []T) []T {
            for (output) |*sample| {
                sample.* = self.amp * @sin(self.phase);
                self.phase += self.inc;
                if (self.phase >= two_pi) self.phase -= two_pi;
            }
            return output;
        }
    };
}

pub fn Sine(comptime T: type) type {
    requireFloat(T, "Sine");

    return struct {
        wave: Wave(T),

        const Self = @This();
        pub const ports: Ports = .{ .inputs = 0, .outputs = 1 };

        /// The sample rate given here is provisional; `prepare` sets the real one.
        pub fn init(freq: T, amp: T) Self {
            return .{ .wave = Wave(T).init(freq, amp, 48000) };
        }

        pub fn name(_: *Self) []const u8 {
            return "Sine";
        }

        pub fn prepare(self: *Self, ctx: Node(T).PrepareContext) NodeError!void {
            self.wave.setSampleRate(ctx.sample_rate);
        }

        /// Renders channel 0 through the kernel, then duplicates it. The kernel advances phase
        /// once per frame, so every channel carries the same signal and the phase stays
        /// continuous across calls.
        pub fn process(self: *Self, ctx: ProcessContext(T)) void {
            const out = ctx.outputs[0];

            _ = self.wave.sine(out.channel(0));

            for (1..out.channel_count) |ch| @memcpy(out.channel(ch), out.channel(0));
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The first two are the acceptance items for section 2; the rest pin the interface.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Two-slot planar scratch: 2 channels, stride 16, frames 0..16 usable. Mirrors a pool slot.
const Scratch = struct {
    const channels = 2;
    const stride = 16;

    samples: [2][channels * stride]f32,

    fn init(fill: f32) Scratch {
        var s: Scratch = undefined;
        for (&s.samples) |*slot| @memset(slot, fill);
        return s;
    }

    fn block(self: *Scratch, slot: usize, frame_count: usize) AudioBlock(f32) {
        return .{
            .samples = &self.samples[slot],
            .channel_count = channels,
            .frame_count = frame_count,
            .channel_stride = stride,
        };
    }
};

fn expectAll(expected: f32, actual: []const f32) !void {
    for (actual) |sample| try testing.expectEqual(expected, sample);
}
test "Gain through Node(T): writes only active frames of its output, input unchanged" {
    var scratch = Scratch.init(9);

    const in = scratch.block(0, 5);
    const out = scratch.block(1, 5);
    for (0..2) |ch| @memset(in.channel(ch), 1);

    var gain = Gain(f32){ .gain = 0.5 };
    const node = Node(f32).init(&gain);

    try testing.expectEqual(Ports{ .inputs = 1, .outputs = 1 }, node.ports);
    try testing.expectEqualStrings("Gain", node.name());

    try node.prepare(.{ .sample_rate = 48000, .max_frames = 16, .channel_count = 2 });
    node.process(.{
        .inputs = &.{in.asConst()},
        .outputs = &.{out},
        .frame_count = 5,
    });

    const full_out = scratch.block(1, Scratch.stride);
    for (0..2) |ch| {
        try expectAll(0.5, full_out.channel(ch)[0..5]);
        try expectAll(9, full_out.channel(ch)[5..]);
        try expectAll(1, in.channel(ch));
    }
}

test "Sine through Node(T): zero inputs, every channel written, phase continues across calls" {
    var split = Scratch.init(9);
    var whole = Scratch.init(9);

    var sine_split = Sine(f32).init(440, 1);
    var sine_whole = Sine(f32).init(440, 1);
    const node_split = Node(f32).init(&sine_split);
    const node_whole = Node(f32).init(&sine_whole);

    try testing.expectEqual(Ports{ .inputs = 0, .outputs = 1 }, node_split.ports);

    const prepare_ctx: Node(f32).PrepareContext = .{ .sample_rate = 48000, .max_frames = 16, .channel_count = 2 };
    try node_split.prepare(prepare_ctx);
    try node_whole.prepare(prepare_ctx);

    // two calls of 8 frames into consecutive frame ranges of slot 0
    const first = split.block(0, 8);
    node_split.process(.{ .inputs = &.{}, .outputs = &.{first}, .frame_count = 8 });

    var second = split.block(0, 16);
    second.samples = second.samples[8..]; // sub-block at frame 8, same stride
    second.frame_count = 8;
    node_split.process(.{ .inputs = &.{}, .outputs = &.{second}, .frame_count = 8 });

    // one call of 16 frames
    const all = whole.block(0, 16);
    node_whole.process(.{ .inputs = &.{}, .outputs = &.{all}, .frame_count = 16 });

    for (0..2) |ch| {
        try testing.expectEqualSlices(f32, all.channel(ch), split.block(0, 16).channel(ch));
    }

    // both channels carry the same signal, and it is the expected sine
    try testing.expectEqualSlices(f32, all.channel(0), all.channel(1));
    for (all.channel(0), 0..) |sample, n| {
        const expected: f64 = @sin(2 * std.math.pi * 440 * @as(f64, @floatFromInt(n)) / 48000);
        try testing.expectApproxEqAbs(@as(f32, @floatCast(expected)), sample, 1e-5);
    }

    // slot 1 was never handed to the node
    for (0..2) |ch| try expectAll(9, split.block(1, Scratch.stride).channel(ch));
}

test "prepare is repeatable and changes the sample rate" {
    var sine = Sine(f32).init(440, 1);
    const node = Node(f32).init(&sine);

    try node.prepare(.{ .sample_rate = 48000, .max_frames = 16, .channel_count = 1 });
    const inc_48k = sine.wave.inc;

    try node.prepare(.{ .sample_rate = 96000, .max_frames = 16, .channel_count = 1 });
    try testing.expectApproxEqAbs(inc_48k / 2, sine.wave.inc, 1e-7);
}

test "createNode heap-copies and destroy frees" {
    const node = try Node(f32).createNode(testing.allocator, Gain(f32){ .gain = 2 });
    defer node.destroy(testing.allocator);

    try testing.expectEqualStrings("Gain", node.name());
    try testing.expectEqual(1, node.ports.inputs);
}

test "f64 nodes" {
    var gain = Gain(f64){ .gain = 3 };
    const node = Node(f64).init(&gain);

    var in_samples = [_]f64{ 1, 2 };
    var out_samples = [_]f64{ 0, 0 };
    const in = ConstAudioBlock(f64){ .samples = &in_samples, .channel_count = 1, .frame_count = 2, .channel_stride = 2 };
    const out = AudioBlock(f64){ .samples = &out_samples, .channel_count = 1, .frame_count = 2, .channel_stride = 2 };

    node.process(.{ .inputs = &.{in}, .outputs = &.{out}, .frame_count = 2 });
    try testing.expectEqualSlices(f64, &.{ 3, 6 }, &out_samples);
}
