const std = @import("std");
const specs = @import("../common/audio_specs.zig");

pub const AccessPattern = enum {
    interleaved,
    non_interleaved,
};

pub const ViewOption = struct {
    n_channels: usize,
    block_size: specs.BlockSize,
    access: AccessPattern,
};

pub const ViewsOptions = struct {
    n_views: usize,
    n_channels: usize,
    block_size: specs.BlockSize,
    access: AccessPattern,
};

pub const ChannelViewError = error{
    invalid_buffer_length,
    shape_mismatch,
};

pub fn ChannelView(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("ChannelView only supports f32 and f64");
    }

    return struct {
        const Self = @This();

        buffer: []T,
        n_channels: usize,
        block_size: usize,
        access: AccessPattern,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, opts: ViewOption) !Self {
            const buffer_len = @as(usize, @intFromEnum(opts.block_size) * opts.n_channels);

            return Self{
                .buffer = try allocator.alloc(T, buffer_len),
                .block_size = @intFromEnum(opts.block_size),
                .n_channels = opts.n_channels,
                .access = opts.access,
                .allocator = allocator,
            };
        }

        // note there is no bounds checking here. program will just crash if you try to read out of bounds
        pub inline fn readSample(self: Self, at_channel: usize, at_frame: usize) T {
            return switch (self.access) {
                .interleaved => self.buffer[at_frame * self.n_channels + at_channel],
                .non_interleaved => self.buffer[at_channel * self.block_size + at_frame],
            };
        }

        pub inline fn writeSample(self: Self, at_channel: usize, at_frame: usize, sample: T) void {
            switch (self.access) {
                .interleaved => self.buffer[at_frame * self.n_channels + at_channel] = sample,
                .non_interleaved => self.buffer[at_channel * self.block_size + at_frame] = sample,
            }
        }

        pub inline fn copyFrom(self: Self, other: Self) !void {
            if (self.buffer.len != other.buffer.len) {
                return ChannelViewError.invalid_buffer_length;
            }

            // same length is not enough: 2x8 and 4x4 would copy samples into the wrong channels
            if (self.n_channels != other.n_channels or
                self.block_size != other.block_size or
                self.access != other.access)
            {
                return ChannelViewError.shape_mismatch;
            }

            @memcpy(self.buffer, other.buffer);
        }

        pub inline fn totalSampleCount(self: Self) usize {
            return self.buffer.len;
        }

        pub inline fn zero(self: Self) void {
            @memset(self.buffer, 0);
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }
    };
}

pub fn UnmanagedChannelView(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("UnmanagedChannelView only supports f32 and f64");
    }

    return struct {
        const Self = @This();

        buffer: []T,
        n_channels: usize,
        block_size: usize,
        access: AccessPattern,

        pub fn init(buffer: []T, opts: ViewOption) ChannelViewError!Self {
            const block_size: usize = @intFromEnum(opts.block_size);

            if (opts.n_channels * block_size != buffer.len) {
                return ChannelViewError.invalid_buffer_length;
            }

            return Self{
                .buffer = buffer,
                .n_channels = opts.n_channels,
                .block_size = block_size,
                .access = opts.access,
            };
        }

        // these functions are short enough, duplication is fine
        pub inline fn readSample(self: Self, at_channel: usize, at_frame: usize) T {
            return switch (self.access) {
                .interleaved => self.buffer[at_frame * self.n_channels + at_channel],
                .non_interleaved => self.buffer[at_channel * self.block_size + at_frame],
            };
        }

        pub inline fn writeSample(self: Self, at_channel: usize, at_frame: usize, sample: T) void {
            switch (self.access) {
                .interleaved => self.buffer[at_frame * self.n_channels + at_channel] = sample,
                .non_interleaved => self.buffer[at_channel * self.block_size + at_frame] = sample,
            }
        }

        // we don't need pointers self, we are chaning the inner memory in buffer
        pub inline fn copyFrom(self: Self, other: Self) !void {
            if (self.buffer.len != other.buffer.len) {
                return ChannelViewError.invalid_buffer_length;
            }

            // same length is not enough: 2x8 and 4x4 would copy samples into the wrong channels
            if (self.n_channels != other.n_channels or
                self.block_size != other.block_size or
                self.access != other.access)
            {
                return ChannelViewError.shape_mismatch;
            }

            @memcpy(self.buffer, other.buffer);
        }

        pub inline fn totalSampleCount(self: Self) usize {
            return self.buffer.len;
        }

        // we don't need pointers self, we are chaning the inner memory in buffer
        pub inline fn zero(self: Self) void {
            @memset(self.buffer, 0);
        }
    };
}

pub fn UniformChannelViews(T: type) type {
    if (T != f32 and T != f64) {
        @compileError("ChannelViews only supports f32 and f64");
    }

    return struct {
        const Self = @This();

        buffer: []T,
        opts: ViewsOptions,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, opts: ViewsOptions) !Self {
            const samples_per_view = @as(usize, @intFromEnum(opts.block_size) * opts.n_channels);

            return .{
                .buffer = try allocator.alloc(T, opts.n_views * samples_per_view),
                .opts = opts,
                .allocator = allocator,
            };
        }

        pub fn getView(self: *Self, index: usize) UnmanagedChannelView(T) {
            const samples_per_view = self.opts.n_channels * @as(usize, @intFromEnum(self.opts.block_size));
            const start = index * samples_per_view;

            const buffer = self.buffer[start .. start + samples_per_view];

            return UnmanagedChannelView(T).init(buffer, .{
                .n_channels = self.opts.n_channels,
                .block_size = self.opts.block_size,
                .access = self.opts.access,
                // should never happen
            }) catch unreachable;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }
    };
}

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;

test "ChannelView - initialization with valid parameters" {
    const allocator = std.testing.allocator;
    var view = try ChannelView(f32).init(allocator, .{
        .n_channels = 2,
        .block_size = .blk_128,
        .access = .interleaved,
    });
    defer view.deinit();
    try expectEqual(view.n_channels, 2);
    try expectEqual(view.block_size, 128);
    try expectEqual(view.access, .interleaved);
    try expectEqual(view.buffer.len, 256);
}

test "UnmanagedChannelView - initialization and error handling" {
    const allocator = std.testing.allocator;
    const buffer = try allocator.alloc(f32, 256);
    defer allocator.free(buffer);

    const view = try UnmanagedChannelView(f32).init(buffer, .{
        .n_channels = 2,
        .block_size = .blk_128,
        .access = .interleaved,
    });
    try expectEqual(view.n_channels, 2);
    try expectEqual(view.block_size, 128);

    // Invalid buffer length
    try expectError(error.invalid_buffer_length, UnmanagedChannelView(f32).init(buffer, .{
        .n_channels = 3,
        .block_size = .blk_128,
        .access = .interleaved,
    }));
}

test "UniformChannelViews - basic operations" {
    const allocator = std.testing.allocator;
    var views = try UniformChannelViews(f32).init(allocator, .{
        .n_views = 2,
        .n_channels = 2,
        .block_size = .blk_128,
        .access = .interleaved,
    });
    defer views.deinit();

    // Get and test first view
    var view0 = views.getView(0);
    view0.writeSample(0, 0, 1.0);
    view0.writeSample(1, 0, 2.0);
    try expectEqual(view0.readSample(0, 0), 1.0);
    try expectEqual(view0.readSample(1, 0), 2.0);

    // Get and test second view
    var view1 = views.getView(1);
    view1.writeSample(0, 0, 3.0);
    view1.writeSample(1, 0, 4.0);
    try expectEqual(view1.readSample(0, 0), 3.0);
    try expectEqual(view1.readSample(1, 0), 4.0);
}

test "ChannelView - interleaved read/write f32" {
    const allocator = std.testing.allocator;
    var view = try ChannelView(f32).init(allocator, .{
        .n_channels = 2,
        .block_size = .blk_256,
        .access = .interleaved,
    });
    defer view.deinit();
    try expectEqual(view.buffer.len, 512);

    // Initialize samples
    view.writeSample(0, 0, 1.0);
    view.writeSample(1, 0, 2.0);
    view.writeSample(0, 1, 3.0);
    view.writeSample(1, 1, 4.0);

    // Verify values
    try expectEqual(view.readSample(0, 0), 1.0);
    try expectEqual(view.readSample(1, 0), 2.0);
    try expectEqual(view.readSample(0, 1), 3.0);
    try expectEqual(view.readSample(1, 1), 4.0);
}

test "ChannelView - non-interleaved read/write f32" {
    const allocator = std.testing.allocator;
    var view = try ChannelView(f32).init(allocator, .{
        .n_channels = 2,
        .block_size = .blk_1024,
        .access = .non_interleaved,
    });
    defer view.deinit();
    try expectEqual(view.buffer.len, 2048);

    view.writeSample(0, 0, 1.0);
    view.writeSample(1, 0, 2.0);
    view.writeSample(0, 1, 3.0);
    view.writeSample(1, 1, 4.0);

    try expectEqual(view.readSample(0, 0), 1.0);
    try expectEqual(view.readSample(1, 0), 2.0);
    try expectEqual(view.readSample(0, 1), 3.0);
    try expectEqual(view.readSample(1, 1), 4.0);
}

test "ChannelView - large non-interleaved buffer" {
    const allocator = std.testing.allocator;
    var view = try ChannelView(f32).init(allocator, .{
        .n_channels = 4,
        .block_size = .blk_256,
        .access = .non_interleaved,
    });
    defer view.deinit();

    // Write test pattern
    for (0..4) |channel| {
        for (0..256) |frame| {
            view.writeSample(channel, frame, @as(f32, @floatFromInt(channel * 256 + frame)));
        }
    }

    // Verify the pattern
    for (0..4) |channel| {
        for (0..256) |frame| {
            const expected = @as(f32, @floatFromInt(channel * 256 + frame));
            try expectEqual(view.readSample(channel, frame), expected);
        }
    }
}

test "UnmanagedChannelView - copyFrom rejects a different shape with the same total length" {
    var dst_samples = [_]f32{0} ** 16;
    var src_samples = [_]f32{1} ** 16;

    const dst = try UnmanagedChannelView(f32).init(&dst_samples, .{
        .n_channels = 2,
        .block_size = .blk_8,
        .access = .non_interleaved,
    });

    const other_channels = try UnmanagedChannelView(f32).init(&src_samples, .{
        .n_channels = 4,
        .block_size = .blk_4,
        .access = .non_interleaved,
    });

    const other_access = try UnmanagedChannelView(f32).init(&src_samples, .{
        .n_channels = 2,
        .block_size = .blk_8,
        .access = .interleaved,
    });

    try expectError(error.shape_mismatch, dst.copyFrom(other_channels));
    try expectError(error.shape_mismatch, dst.copyFrom(other_access));

    for (dst_samples) |sample| try expectEqual(0, sample);
}

test "UnmanagedChannelView - copyFrom copies between views of the same shape" {
    var dst_samples = [_]f32{0} ** 16;
    var src_samples = [_]f32{1} ** 16;
    const opts: ViewOption = .{ .n_channels = 2, .block_size = .blk_8, .access = .non_interleaved };

    const dst = try UnmanagedChannelView(f32).init(&dst_samples, opts);
    const src = try UnmanagedChannelView(f32).init(&src_samples, opts);

    try dst.copyFrom(src);

    for (dst_samples) |sample| try expectEqual(1, sample);
}

test "ChannelView - copyFrom rejects a different shape with the same total length" {
    const allocator = std.testing.allocator;

    var dst = try ChannelView(f32).init(allocator, .{ .n_channels = 2, .block_size = .blk_8, .access = .interleaved });
    defer dst.deinit();

    var src = try ChannelView(f32).init(allocator, .{ .n_channels = 4, .block_size = .blk_4, .access = .interleaved });
    defer src.deinit();

    dst.zero();
    @memset(src.buffer, 1);

    try expectError(error.shape_mismatch, dst.copyFrom(src));

    for (dst.buffer) |sample| try expectEqual(0, sample);
}
