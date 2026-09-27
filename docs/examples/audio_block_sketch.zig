//! Design sketch for docs/buffer-contract.md, written before the implementation.
//! Not part of the build. The real code is src/core/buffer/, which uses different names
//! (AudioBufferError, borrowBlock, borrowSlot) and one block definition for both views.
//!
//!     zig test docs/examples/audio_block_sketch.zig

const std = @import("std");

/// Channel starts in owned storage are aligned to this many bytes.
pub const storage_alignment: std.mem.Alignment = .@"64";

pub const BlockError = error{
    zero_channels,
    frames_exceed_stride,
    size_overflow,
    storage_too_small,
    out_of_range,
    shape_mismatch,
    forbidden_overlap,
};

pub const Shape = struct {
    channel_count: usize,
    frame_count: usize,
    channel_stride: usize,
};

fn requireFloat(comptime T: type, comptime name: []const u8) void {
    if (T != f32 and T != f64) @compileError(name ++ " only supports f32 and f64");
}

// ---------------------------------------------------------------------------
// Borrowed views
// ---------------------------------------------------------------------------

pub fn ConstAudioBlock(comptime T: type) type {
    requireFloat(T, "ConstAudioBlock");

    return struct {
        const Self = @This();

        samples: []const T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        pub fn init(samples: []const T, shape: Shape) BlockError!Self {
            const required = try requiredSamples(shape);
            if (samples.len < required) return error.storage_too_small;

            return .{
                .samples = samples[0..required],
                .channel_count = shape.channel_count,
                .frame_count = shape.frame_count,
                .channel_stride = shape.channel_stride,
            };
        }

        pub fn channel(self: Self, c: usize) []const T {
            std.debug.assert(c < self.channel_count);
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
        }

        pub fn subBlock(self: Self, first_frame: usize, frame_count: usize) BlockError!Self {
            const end = std.math.add(usize, first_frame, frame_count) catch return error.out_of_range;
            if (end > self.frame_count) return error.out_of_range;

            return .{
                .samples = self.samples[first_frame..],
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            };
        }
    };
}

pub fn AudioBlock(comptime T: type) type {
    requireFloat(T, "AudioBlock");

    return struct {
        const Self = @This();

        samples: []T,
        channel_count: usize,
        frame_count: usize,
        channel_stride: usize,

        /// Checked constructor. Every other way of getting a block derives from a checked one.
        pub fn init(samples: []T, shape: Shape) BlockError!Self {
            const required = try requiredSamples(shape);
            if (samples.len < required) return error.storage_too_small;

            return .{
                .samples = samples[0..required],
                .channel_count = shape.channel_count,
                .frame_count = shape.frame_count,
                .channel_stride = shape.channel_stride,
            };
        }

        pub fn channel(self: Self, c: usize) []T {
            std.debug.assert(c < self.channel_count);
            return self.samples[c * self.channel_stride ..][0..self.frame_count];
        }

        /// Same storage and stride, fewer valid frames.
        pub fn subBlock(self: Self, first_frame: usize, frame_count: usize) BlockError!Self {
            const end = std.math.add(usize, first_frame, frame_count) catch return error.out_of_range;
            if (end > self.frame_count) return error.out_of_range;

            return .{
                // shifting the base keeps channel(c) = base + c * stride valid
                .samples = self.samples[first_frame..],
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            };
        }

        /// One way only: a const block never becomes writable again.
        pub fn asConst(self: Self) ConstAudioBlock(T) {
            return .{
                .samples = self.samples,
                .channel_count = self.channel_count,
                .frame_count = self.frame_count,
                .channel_stride = self.channel_stride,
            };
        }
    };
}

fn requiredSamples(shape: Shape) BlockError!usize {
    if (shape.channel_count == 0) return error.zero_channels;
    if (shape.frame_count > shape.channel_stride) return error.frames_exceed_stride;

    return std.math.mul(usize, shape.channel_count, shape.channel_stride) catch
        error.size_overflow;
}

// ---------------------------------------------------------------------------
// Owning storage
// ---------------------------------------------------------------------------

/// Rounds a frame capacity up so that every channel start lands on `storage_alignment`.
fn strideFor(comptime T: type, max_frames: usize) BlockError!usize {
    const samples_per_unit = storage_alignment.toByteUnits() / @sizeOf(T);
    const padded = std.math.add(usize, max_frames, samples_per_unit - 1) catch return error.size_overflow;
    return padded - padded % samples_per_unit;
}

pub fn OwnedAudioBuffer(comptime T: type) type {
    requireFloat(T, "OwnedAudioBuffer");

    return struct {
        const Self = @This();
        const alignment = storage_alignment.toByteUnits();

        storage: []align(alignment) T,
        channel_count: usize,
        max_frames: usize,
        channel_stride: usize,

        pub fn init(allocator: std.mem.Allocator, channel_count: usize, max_frames: usize) !Self {
            const stride = try strideFor(T, max_frames);
            const len = try requiredSamples(.{
                .channel_count = channel_count,
                .frame_count = max_frames,
                .channel_stride = stride,
            });

            const storage = try allocator.alignedAlloc(T, storage_alignment, len);
            @memset(storage, 0);

            return .{
                .storage = storage,
                .channel_count = channel_count,
                .max_frames = max_frames,
                .channel_stride = stride,
            };
        }

        /// Unmanaged: the allocator is passed back in, the buffer does not carry one.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = undefined;
        }

        /// Borrow the first `frame_count` frames. The block is valid until `deinit`.
        pub fn block(self: Self, frame_count: usize) BlockError!AudioBlock(T) {
            if (frame_count > self.max_frames) return error.out_of_range;

            return AudioBlock(T).init(self.storage, .{
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            });
        }
    };
}

/// N same-shaped slots in one allocation. Slot `i` never shares samples with slot `j`.
pub fn AudioBufferPool(comptime T: type) type {
    requireFloat(T, "AudioBufferPool");

    return struct {
        const Self = @This();
        const alignment = storage_alignment.toByteUnits();

        pub const Options = struct {
            slot_count: usize,
            channel_count: usize,
            max_frames: usize,
        };

        storage: []align(alignment) T,
        slot_count: usize,
        channel_count: usize,
        max_frames: usize,
        channel_stride: usize,

        pub fn init(allocator: std.mem.Allocator, opts: Options) !Self {
            const stride = try strideFor(T, opts.max_frames);
            const per_slot = try requiredSamples(.{
                .channel_count = opts.channel_count,
                .frame_count = opts.max_frames,
                .channel_stride = stride,
            });
            const len = std.math.mul(usize, per_slot, opts.slot_count) catch return error.size_overflow;

            const storage = try allocator.alignedAlloc(T, storage_alignment, len);
            @memset(storage, 0);

            return .{
                .storage = storage,
                .slot_count = opts.slot_count,
                .channel_count = opts.channel_count,
                .max_frames = opts.max_frames,
                .channel_stride = stride,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn slot(self: Self, index: usize, frame_count: usize) BlockError!AudioBlock(T) {
            if (index >= self.slot_count) return error.out_of_range;
            if (frame_count > self.max_frames) return error.out_of_range;

            const per_slot = self.channel_count * self.channel_stride;

            return AudioBlock(T).init(self.storage[index * per_slot ..][0..per_slot], .{
                .channel_count = self.channel_count,
                .frame_count = frame_count,
                .channel_stride = self.channel_stride,
            });
        }
    };
}

// ---------------------------------------------------------------------------
// Operations. None of these allocate, log, or touch samples outside active frames.
// ---------------------------------------------------------------------------

fn slicesOverlap(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len == 0 or b.len == 0) return false;

    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);

    return a_start < b_start + b.len * @sizeOf(T) and b_start < a_start + a.len * @sizeOf(T);
}

/// True when any active sample is reachable through both blocks. Compares channel by channel,
/// so two sub-blocks covering different frame ranges of one parent do not overlap.
pub fn blocksOverlap(comptime T: type, a: ConstAudioBlock(T), b: ConstAudioBlock(T)) bool {
    for (0..a.channel_count) |ca| {
        for (0..b.channel_count) |cb| {
            if (slicesOverlap(T, a.channel(ca), b.channel(cb))) return true;
        }
    }
    return false;
}

fn requireSameShape(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) BlockError!void {
    if (dst.channel_count != src.channel_count) return error.shape_mismatch;
    if (dst.frame_count != src.frame_count) return error.shape_mismatch;
}

pub fn clear(comptime T: type, dst: AudioBlock(T)) void {
    for (0..dst.channel_count) |c| @memset(dst.channel(c), 0);
}

/// dst = src. Same shape, disjoint storage. Strides may differ.
pub fn copy(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) BlockError!void {
    try requireSameShape(T, dst, src);
    if (blocksOverlap(T, dst.asConst(), src)) return error.forbidden_overlap;

    for (0..dst.channel_count) |c| @memcpy(dst.channel(c), src.channel(c));
}

/// dst += src. This is mixing; `copy` is not.
pub fn accumulate(comptime T: type, dst: AudioBlock(T), src: ConstAudioBlock(T)) BlockError!void {
    try requireSameShape(T, dst, src);
    if (blocksOverlap(T, dst.asConst(), src)) return error.forbidden_overlap;

    for (0..dst.channel_count) |c| {
        for (dst.channel(c), src.channel(c)) |*d, s| d.* += s;
    }
}

/// Device/file boundary: planar block -> tightly packed interleaved frames.
pub fn interleave(comptime T: type, dst: []T, src: ConstAudioBlock(T)) BlockError!void {
    if (dst.len != src.channel_count * src.frame_count) return error.shape_mismatch;

    for (0..src.channel_count) |c| {
        for (src.channel(c), 0..) |sample, frame| {
            dst[frame * src.channel_count + c] = sample;
        }
    }
}

/// Device/file boundary: tightly packed interleaved frames -> planar block.
pub fn deinterleave(comptime T: type, dst: AudioBlock(T), src: []const T) BlockError!void {
    if (src.len != dst.channel_count * dst.frame_count) return error.shape_mismatch;

    for (0..dst.channel_count) |c| {
        for (dst.channel(c), 0..) |*sample, frame| {
            sample.* = src[frame * dst.channel_count + c];
        }
    }
}

// ---------------------------------------------------------------------------
// Node I/O: separate inputs and outputs, one block per port.
// ---------------------------------------------------------------------------

pub fn ProcessContext(comptime T: type) type {
    return struct {
        inputs: []const ConstAudioBlock(T),
        outputs: []const AudioBlock(T),
        frame_count: usize,
    };
}

const ExampleGain = struct {
    gain: f32,

    fn process(self: *ExampleGain, ctx: ProcessContext(f32)) void {
        const in = ctx.inputs[0];
        const out = ctx.outputs[0];

        for (0..out.channel_count) |c| {
            for (out.channel(c), in.channel(c)) |*o, i| o.* = i * self.gain;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: one per acceptance item in the contract.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "partial block: channel 1 starts at stride, not at frame_count" {
    var storage: [2 * 512]f32 = undefined;
    const block = try AudioBlock(f32).init(&storage, .{
        .channel_count = 2,
        .frame_count = 128,
        .channel_stride = 512,
    });

    try testing.expectEqual(@as(usize, 128), block.channel(1).len);
    try testing.expectEqual(&storage[512], &block.channel(1)[0]);
}

test "sub-block preserves stride and confines writes to active frames" {
    var storage = [_]f32{0} ** (2 * 8);
    const block = try AudioBlock(f32).init(&storage, .{
        .channel_count = 2,
        .frame_count = 8,
        .channel_stride = 8,
    });

    const sub = try block.subBlock(2, 3);
    for (0..sub.channel_count) |c| @memset(sub.channel(c), 1);

    const expected = [_]f32{ 0, 0, 1, 1, 1, 0, 0, 0 } ** 2;
    try testing.expectEqualSlices(f32, &expected, &storage);
    try testing.expectError(error.out_of_range, block.subBlock(6, 3));
}

test "rejects bad shapes" {
    var storage: [16]f32 = undefined;
    const B = AudioBlock(f32);

    try testing.expectError(error.zero_channels, B.init(&storage, .{ .channel_count = 0, .frame_count = 8, .channel_stride = 8 }));
    try testing.expectError(error.frames_exceed_stride, B.init(&storage, .{ .channel_count = 2, .frame_count = 9, .channel_stride = 8 }));
    try testing.expectError(error.storage_too_small, B.init(&storage, .{ .channel_count = 3, .frame_count = 8, .channel_stride = 8 }));
    try testing.expectError(error.size_overflow, B.init(&storage, .{ .channel_count = std.math.maxInt(usize), .frame_count = 1, .channel_stride = 2 }));
}

test "zero-frame block is valid and every operation on it is a no-op" {
    var storage = [_]f32{7} ** 16;
    const block = try AudioBlock(f32).init(&storage, .{ .channel_count = 2, .frame_count = 0, .channel_stride = 8 });

    try testing.expectEqual(@as(usize, 0), block.channel(1).len);
    clear(f32, block);
    try testing.expectEqual(@as(f32, 7), storage[0]);
}

test "owned buffer: aligned channel starts, stride independent of frame count" {
    var owned = try OwnedAudioBuffer(f32).init(testing.allocator, 2, 100);
    defer owned.deinit(testing.allocator);

    // 100 frames rounds up to 112 so channel 1 starts on a 64-byte boundary
    try testing.expectEqual(@as(usize, 112), owned.channel_stride);

    const block = try owned.block(100);
    try testing.expect(@intFromPtr(block.channel(0).ptr) % 64 == 0);
    try testing.expect(@intFromPtr(block.channel(1).ptr) % 64 == 0);
    try testing.expectError(error.out_of_range, owned.block(101));
}

test "pool slots are independent" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{
        .slot_count = 3,
        .channel_count = 2,
        .max_frames = 64,
    });
    defer pool.deinit(testing.allocator);

    const a = try pool.slot(0, 64);
    const b = try pool.slot(1, 64);

    for (0..2) |c| @memset(a.channel(c), 1);

    try testing.expect(!blocksOverlap(f32, a.asConst(), b.asConst()));
    for (0..2) |c| {
        for (b.channel(c)) |sample| try testing.expectEqual(@as(f32, 0), sample);
    }
    try testing.expectError(error.out_of_range, pool.slot(3, 64));
}

test "copy rejects shape mismatch and overlap, allows different strides" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    const dst = try pool.slot(0, 16);

    try testing.expectError(error.shape_mismatch, copy(f32, dst, (try pool.slot(1, 8)).asConst()));
    try testing.expectError(error.forbidden_overlap, copy(f32, dst, dst.asConst()));
    try testing.expectError(error.forbidden_overlap, copy(f32, try dst.subBlock(0, 8), (try dst.subBlock(4, 8)).asConst()));

    // different frame ranges of one parent share storage but no samples
    try copy(f32, try dst.subBlock(0, 8), (try dst.subBlock(8, 8)).asConst());

    // tightly packed source, padded destination
    var packed_storage = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const packed_src = try ConstAudioBlock(f32).init(&packed_storage, .{ .channel_count = 2, .frame_count = 4, .channel_stride = 4 });
    const padded_dst = try pool.slot(0, 4);

    try copy(f32, padded_dst, packed_src);
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, padded_dst.channel(0));
    try testing.expectEqualSlices(f32, &.{ 5, 6, 7, 8 }, padded_dst.channel(1));
}

test "accumulate mixes, copy replaces" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 3, .channel_count = 1, .max_frames = 4 });
    defer pool.deinit(testing.allocator);

    const mix = try pool.slot(0, 4);
    const a = try pool.slot(1, 4);
    const b = try pool.slot(2, 4);

    @memset(a.channel(0), 0.25);
    @memset(b.channel(0), 0.5);

    clear(f32, mix);
    try accumulate(f32, mix, a.asConst());
    try accumulate(f32, mix, b.asConst());
    try testing.expectEqualSlices(f32, &.{ 0.75, 0.75, 0.75, 0.75 }, mix.channel(0));

    try copy(f32, mix, b.asConst());
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 0.5 }, mix.channel(0));
}

test "layout round trip at the boundary" {
    var owned = try OwnedAudioBuffer(f32).init(testing.allocator, 2, 16);
    defer owned.deinit(testing.allocator);

    const device_in = [_]f32{ 1, -1, 2, -2, 3, -3 };
    var device_out: [6]f32 = undefined;

    const block = try owned.block(3);
    try deinterleave(f32, block, &device_in);

    try testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, block.channel(0));
    try testing.expectEqualSlices(f32, &.{ -1, -2, -3 }, block.channel(1));

    try interleave(f32, &device_out, block.asConst());
    try testing.expectEqualSlices(f32, &device_in, &device_out);

    try testing.expectError(error.shape_mismatch, interleave(f32, device_out[0..4], block.asConst()));
}

test "node with separate input and output over a partial block" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    // sentinel in the full-capacity output, then process only 5 frames
    const full_out = try pool.slot(1, 16);
    for (0..2) |c| @memset(full_out.channel(c), 9);

    const in = try pool.slot(0, 5);
    const out = try pool.slot(1, 5);
    for (0..2) |c| @memset(in.channel(c), 1);

    var gain = ExampleGain{ .gain = 0.5 };
    gain.process(.{
        .inputs = &.{in.asConst()},
        .outputs = &.{out},
        .frame_count = 5,
    });

    for (0..2) |c| {
        try testing.expectEqualSlices(f32, &(.{0.5} ** 5), full_out.channel(c)[0..5]);
        try testing.expectEqualSlices(f32, &(.{9} ** 11), full_out.channel(c)[5..]);
        try testing.expectEqualSlices(f32, &(.{1} ** 5), in.channel(c));
    }
}
