//! Public surface of the buffer module. Everything outside `core/buffer/` imports this file.
//! The contract is docs/buffer-contract.md; the tests below follow its acceptance list.

const std = @import("std");
const audio_block = @import("block.zig");
const storage = @import("storage.zig");
const shape = @import("shape.zig");
const ops = @import("ops.zig");

// Exports
pub const AudioBlock = audio_block.AudioBlock;
pub const ConstAudioBlock = audio_block.ConstAudioBlock;
pub const OwnedAudioBuffer = storage.OwnedAudioBuffer;
pub const AudioBufferPool = storage.AudioBufferPool;

pub const AudioBufferError = shape.AudioBufferError;
pub const Shape = shape.Shape;
pub const storage_alignment = shape.storage_alignment;

pub const blocksOverlap = ops.blocksOverlap;
pub const clear = ops.clear;
pub const copy = ops.copy;
pub const accumulate = ops.accumulate;
pub const interleave = ops.interleave;
pub const deinterleave = ops.deinterleave;


pub fn ProcessContext(comptime T: type) type {
    return struct {
        inputs: []const ConstAudioBlock(T),
        outputs: []const AudioBlock(T),
        frame_count: usize,
    };
}

test {
    _ = audio_block;
    _ = storage;
    _ = shape;
    _ = ops;
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;
const expectEqualSlices = testing.expectEqualSlices;

fn expectAll(comptime T: type, expected: T, actual: []const T) !void {
    for (actual) |sample| try expectEqual(expected, sample);
}

test "AudioBlock - mono, stereo and multichannel views address the right samples" {
    inline for (.{ 1, 2, 6 }) |channel_count| {
        var samples: [channel_count * 4]f32 = undefined;
        for (&samples, 0..) |*sample, i| sample.* = @floatFromInt(i);

        const block = try AudioBlock(f32).init(&samples, .{
            .channel_count = channel_count,
            .frame_count = 4,
            .channel_stride = 4,
        });

        for (0..channel_count) |ch| {
            const first: f32 = @floatFromInt(ch * 4);
            try expectEqualSlices(f32, &.{ first, first + 1, first + 2, first + 3 }, block.channel(ch));
        }
    }
}

test "AudioBlock - f64 blocks" {
    var samples = [_]f64{ 1, 2, 3, 4 };
    const block = try AudioBlock(f64).init(&samples, .{ .channel_count = 2, .frame_count = 2, .channel_stride = 2 });

    try expectEqualSlices(f64, &.{ 3, 4 }, block.channel(1));
}

test "AudioBlock - partial block: channel starts at stride, not at frame_count" {
    var samples: [2 * 512]f32 = undefined;
    const block = try AudioBlock(f32).init(&samples, .{
        .channel_count = 2,
        .frame_count = 128,
        .channel_stride = 512,
    });

    try expectEqual(128, block.channel(1).len);
    try expectEqual(&samples[512], &block.channel(1)[0]);
}

test "AudioBlock - storage requirement follows stride, not frame count" {
    // 2 channels * 8 stride needs 16 samples even when only 2 frames are valid
    var samples: [15]f32 = undefined;

    try expectError(error.storage_too_small, AudioBlock(f32).init(&samples, .{
        .channel_count = 2,
        .frame_count = 2,
        .channel_stride = 8,
    }));
}

test "AudioBlock - sub-block preserves stride and rejects out of range" {
    var samples = [_]f32{0} ** (2 * 8);
    const block = try AudioBlock(f32).init(&samples, .{
        .channel_count = 2,
        .frame_count = 8,
        .channel_stride = 8,
    });

    const sub = try block.subBlock(2, 3);
    try expectEqual(8, sub.channel_stride);
    try expectEqual(3, sub.frame_count);

    for (0..sub.channel_count) |ch| @memset(sub.channel(ch), 1);

    const expected = [_]f32{ 0, 0, 1, 1, 1, 0, 0, 0 } ** 2;
    try expectEqualSlices(f32, &expected, &samples);

    try expectError(error.out_of_range, block.subBlock(6, 3));
    try expectError(error.out_of_range, block.subBlock(std.math.maxInt(usize), 2));

    // a sub-block of a sub-block is still relative to the original storage
    const nested = try sub.subBlock(1, 1);
    try expectEqual(&samples[8 + 3], &nested.channel(1)[0]);
}

test "AudioBlock - zero-frame block is valid and operations are no-ops" {
    var samples = [_]f32{7} ** 16;
    var other = [_]f32{1} ** 16;
    const block = try AudioBlock(f32).init(&samples, .{ .channel_count = 2, .frame_count = 0, .channel_stride = 8 });
    const src = try ConstAudioBlock(f32).init(&other, .{ .channel_count = 2, .frame_count = 0, .channel_stride = 8 });

    try expectEqual(0, block.channel(1).len);

    clear(f32, block);
    try copy(f32, block, src);
    try accumulate(f32, block, src);
    try deinterleave(f32, block, &.{});

    try expectAll(f32, 7, &samples);
}

test "AudioBlock - rejects bad shapes" {
    var samples: [16]f32 = undefined;
    const Block = AudioBlock(f32);

    try expectError(error.zero_channels, Block.init(&samples, .{ .channel_count = 0, .frame_count = 8, .channel_stride = 8 }));
    try expectError(error.frames_exceed_stride, Block.init(&samples, .{ .channel_count = 2, .frame_count = 9, .channel_stride = 8 }));
    try expectError(error.storage_too_small, Block.init(&samples, .{ .channel_count = 3, .frame_count = 8, .channel_stride = 8 }));
    try expectError(error.size_overflow, Block.init(&samples, .{ .channel_count = std.math.maxInt(usize), .frame_count = 1, .channel_stride = 2 }));
}

test "AudioBlock - asConst shares samples and is read-only" {
    var samples = [_]f32{ 1, 2, 3, 4 };
    const block = try AudioBlock(f32).init(&samples, .{ .channel_count = 2, .frame_count = 2, .channel_stride = 2 });
    const const_block = block.asConst();

    try expect(@TypeOf(const_block.channel(0)) == []const f32);
    try expect(@TypeOf(block.channel(0)) == []f32);

    block.channel(1)[0] = 9;
    try expectEqual(9, const_block.channel(1)[0]);
}

test "OwnedAudioBuffer - aligned channel starts, zeroed, bounded by max_frames" {
    var owned = try OwnedAudioBuffer(f32).init(testing.allocator, 2, 100);
    defer owned.deinit(testing.allocator);

    // 100 frames rounds up to 112 so channel 1 starts on a 64-byte boundary
    try expectEqual(112, owned.channel_stride);
    try expectEqual(100, owned.max_frames);
    try expectAll(f32, 0, owned.storage);

    const block = try owned.borrowBlock(100);
    try expect(@intFromPtr(block.channel(0).ptr) % 64 == 0);
    try expect(@intFromPtr(block.channel(1).ptr) % 64 == 0);

    try expectError(error.out_of_range, owned.borrowBlock(101));
}

test "OwnedAudioBuffer - f64 stride rounds to 8 samples" {
    var owned = try OwnedAudioBuffer(f64).init(testing.allocator, 2, 100);
    defer owned.deinit(testing.allocator);

    try expectEqual(104, owned.channel_stride);
    try expect(@intFromPtr((try owned.borrowBlock(100)).channel(1).ptr) % 64 == 0);
}

test "OwnedAudioBuffer - rejects zero channels" {
    try expectError(error.zero_channels, OwnedAudioBuffer(f32).init(testing.allocator, 0, 64));
}

test "AudioBufferPool - slots are independent and bounded" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{
        .slot_count = 3,
        .channel_count = 2,
        .max_frames = 64,
    });
    defer pool.deinit(testing.allocator);

    try expectAll(f32, 0, pool.storage);

    const a = try pool.borrowSlot(0, 64);
    const b = try pool.borrowSlot(1, 64);
    const c = try pool.borrowSlot(2, 64);

    for (0..2) |ch| @memset(b.channel(ch), 1);

    try expect(!blocksOverlap(f32, a.asConst(), b.asConst()));
    try expect(!blocksOverlap(f32, b.asConst(), c.asConst()));

    for (0..2) |ch| {
        try expectAll(f32, 0, a.channel(ch));
        try expectAll(f32, 0, c.channel(ch));
        try expect(@intFromPtr(c.channel(ch).ptr) % 64 == 0);
    }

    try expectError(error.out_of_range, pool.borrowSlot(3, 64));
    try expectError(error.out_of_range, pool.borrowSlot(0, 65));
}

fn initOwnedAndPool(allocator: std.mem.Allocator) !void {
    var owned = try OwnedAudioBuffer(f32).init(allocator, 2, 64);
    defer owned.deinit(allocator);

    var pool = try AudioBufferPool(f32).init(allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 64 });
    defer pool.deinit(allocator);
}

test "owners clean up under allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, initOwnedAndPool, .{});
}

test "blocksOverlap - decided per channel over active frames" {
    var samples = [_]f32{0} ** 16;
    const block = try AudioBlock(f32).init(&samples, .{ .channel_count = 2, .frame_count = 8, .channel_stride = 8 });

    const first_half = (try block.subBlock(0, 4)).asConst();
    const second_half = (try block.subBlock(4, 4)).asConst();
    const middle = (try block.subBlock(2, 4)).asConst();
    const empty = (try block.subBlock(2, 0)).asConst();

    try expect(blocksOverlap(f32, block.asConst(), block.asConst()));
    try expect(blocksOverlap(f32, first_half, middle));
    try expect(!blocksOverlap(f32, first_half, second_half));
    try expect(!blocksOverlap(f32, block.asConst(), empty));
}

test "copy and accumulate - reject shape mismatch and overlap, leave destination unchanged" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    const dst = try pool.borrowSlot(0, 16);
    const src = try pool.borrowSlot(1, 16);

    for (0..2) |ch| {
        @memset(dst.channel(ch), 3);
        @memset(src.channel(ch), 5);
    }

    var mono_samples = [_]f32{5} ** 16;
    const mono = try ConstAudioBlock(f32).init(&mono_samples, .{ .channel_count = 1, .frame_count = 16, .channel_stride = 16 });
    const shorter = (try src.subBlock(0, 8)).asConst();

    try expectError(error.shape_mismatch, copy(f32, dst, mono));
    try expectError(error.shape_mismatch, copy(f32, dst, shorter));
    try expectError(error.shape_mismatch, accumulate(f32, dst, mono));
    try expectError(error.shape_mismatch, accumulate(f32, dst, shorter));

    try expectError(error.forbidden_overlap, copy(f32, dst, dst.asConst()));
    try expectError(error.forbidden_overlap, accumulate(f32, dst, dst.asConst()));
    try expectError(error.forbidden_overlap, copy(f32, try dst.subBlock(0, 8), (try dst.subBlock(4, 8)).asConst()));

    for (0..2) |ch| try expectAll(f32, 3, dst.channel(ch));

    // different frame ranges of one parent share storage but no samples
    try copy(f32, try dst.subBlock(0, 8), (try dst.subBlock(8, 8)).asConst());
}

test "copy - accepts differing strides" {
    var owned = try OwnedAudioBuffer(f32).init(testing.allocator, 2, 4);
    defer owned.deinit(testing.allocator);

    var packed_samples = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const packed_src = try ConstAudioBlock(f32).init(&packed_samples, .{ .channel_count = 2, .frame_count = 4, .channel_stride = 4 });
    const padded_dst = try owned.borrowBlock(4);

    try expect(padded_dst.channel_stride != packed_src.channel_stride);

    try copy(f32, padded_dst, packed_src);
    try expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, padded_dst.channel(0));
    try expectEqualSlices(f32, &.{ 5, 6, 7, 8 }, padded_dst.channel(1));
}

test "accumulate sums, copy replaces" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 3, .channel_count = 1, .max_frames = 4 });
    defer pool.deinit(testing.allocator);

    const mix = try pool.borrowSlot(0, 4);
    const a = try pool.borrowSlot(1, 4);
    const b = try pool.borrowSlot(2, 4);

    @memset(a.channel(0), 0.25);
    @memset(b.channel(0), 0.5);

    clear(f32, mix);
    try accumulate(f32, mix, a.asConst());
    try accumulate(f32, mix, b.asConst());
    try expectAll(f32, 0.75, mix.channel(0));

    try copy(f32, mix, b.asConst());
    try expectAll(f32, 0.5, mix.channel(0));
}

test "interleave and deinterleave - round trip, wrong packed length rejected" {
    var owned = try OwnedAudioBuffer(f32).init(testing.allocator, 2, 16);
    defer owned.deinit(testing.allocator);

    const device_in = [_]f32{ 1, -1, 2, -2, 3, -3 };
    var device_out = [_]f32{0} ** 6;

    const block = try owned.borrowBlock(3);
    try deinterleave(f32, block, &device_in);

    try expectEqualSlices(f32, &.{ 1, 2, 3 }, block.channel(0));
    try expectEqualSlices(f32, &.{ -1, -2, -3 }, block.channel(1));

    try interleave(f32, &device_out, block.asConst());
    try expectEqualSlices(f32, &device_in, &device_out);

    try expectError(error.shape_mismatch, interleave(f32, device_out[0..4], block.asConst()));
    try expectError(error.shape_mismatch, deinterleave(f32, block, device_in[0..4]));
    try expectEqualSlices(f32, &device_in, &device_out);
    try expectEqualSlices(f32, &.{ 1, 2, 3 }, block.channel(0));
}

test "interleave and deinterleave - reject packed slice that overlaps the block" {
    var samples = [_]f32{0} ** 16;
    const block = try AudioBlock(f32).init(&samples, .{ .channel_count = 2, .frame_count = 4, .channel_stride = 8 });

    try expectError(error.forbidden_overlap, interleave(f32, samples[0..8], block.asConst()));
    try expectError(error.forbidden_overlap, deinterleave(f32, block, samples[8..16]));
}

test "operations write only active frames" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 20 });
    defer pool.deinit(testing.allocator);

    // stride is 32: frames 5..20 are inactive capacity, 20..32 are padding
    try expectEqual(32, pool.channel_stride);
    @memset(pool.storage, 9);

    const dst = try pool.borrowSlot(0, 5);
    const src = try pool.borrowSlot(1, 5);
    const packed_frames = [_]f32{1} ** 10;

    clear(f32, src);
    clear(f32, dst);
    try deinterleave(f32, src, &packed_frames);
    try copy(f32, dst, src.asConst());
    try accumulate(f32, dst, src.asConst());

    const per_slot = pool.channel_count * pool.channel_stride;

    for (0..pool.slot_count) |slot_index| {
        const active: f32 = if (slot_index == 0) 2 else 1;

        for (0..pool.channel_count) |ch| {
            const start = slot_index * per_slot + ch * pool.channel_stride;
            const channel_storage = pool.storage[start..][0..pool.channel_stride];

            try expectAll(f32, active, channel_storage[0..5]);
            try expectAll(f32, 9, channel_storage[5..]);
        }
    }
}

const TestGain = struct {
    gain: f32,

    fn process(self: *TestGain, ctx: ProcessContext(f32)) void {
        const in = ctx.inputs[0];
        const out = ctx.outputs[0];

        for (0..out.channel_count) |ch| {
            for (out.channel(ch), in.channel(ch)) |*o, i| o.* = i * self.gain;
        }
    }
};

const TestConstant = struct {
    value: f32,

    fn process(self: *TestConstant, ctx: ProcessContext(f32)) void {
        for (ctx.outputs) |out| {
            for (0..out.channel_count) |ch| @memset(out.channel(ch), self.value);
        }
    }
};

test "ProcessContext - node with separate input and output over a partial block" {
    var pool = try AudioBufferPool(f32).init(testing.allocator, .{ .slot_count = 2, .channel_count = 2, .max_frames = 16 });
    defer pool.deinit(testing.allocator);

    // sentinel over the full capacity of the output, then process only 5 frames
    const full_out = try pool.borrowSlot(1, 16);
    for (0..2) |ch| @memset(full_out.channel(ch), 9);

    const in = try pool.borrowSlot(0, 5);
    const out = try pool.borrowSlot(1, 5);
    for (0..2) |ch| @memset(in.channel(ch), 1);

    var gain = TestGain{ .gain = 0.5 };
    gain.process(.{
        .inputs = &.{in.asConst()},
        .outputs = &.{out},
        .frame_count = 5,
    });

    for (0..2) |ch| {
        try expectAll(f32, 0.5, full_out.channel(ch)[0..5]);
        try expectAll(f32, 9, full_out.channel(ch)[5..]);
        try expectAll(f32, 1, in.channel(ch));
    }
}

test "ProcessContext - source node has zero inputs" {
    var owned = try OwnedAudioBuffer(f32).init(testing.allocator, 2, 8);
    defer owned.deinit(testing.allocator);

    const out = try owned.borrowBlock(8);

    var source = TestConstant{ .value = 0.25 };
    source.process(.{
        .inputs = &.{},
        .outputs = &.{out},
        .frame_count = 8,
    });

    for (0..2) |ch| try expectAll(f32, 0.25, out.channel(ch));
}
