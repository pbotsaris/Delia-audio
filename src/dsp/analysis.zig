//TODO: Maybe revise this module and allow for more control such as we window_function size as well as introduce padding
const std = @import("std");
const transforms = @import("transforms.zig");
const ComplexMatrix = @import("complex_matrix.zig").ComplexMatrix;
const ComplexList = @import("complex_list.zig").ComplexList;
const utils = @import("utils.zig");
const waves = @import("waves.zig");
const test_data = @import("test_data.zig");

const log = @import("log.zig").log;

pub const Windowfunction = enum {
    hann,
    blackman,
};

pub const Error = error{
    invalid_hop_size,
    invalid_input_size,
};

pub const HopSize = enum(usize) {
    sixteenth_window = 16,
    eighth_window = 8,
    quarter_window = 4,
    half_window = 2,
    three_quarter_window = 34,

    const Self = @This();

    pub fn toInt(self: Self) usize {
        return if (self == .three_quarter_window) 4 else @intFromEnum(self);
    }

    pub fn fromSize(hop_size: usize, window_size: usize) Self {
        const fraction: f32 = @as(f32, @floatFromInt(hop_size)) / @as(f32, @floatFromInt(window_size));

        return Self.fromFloat(fraction);
    }

    pub fn fromFloat(float: f32) Self {
        if (float <= 0.0625) return .sixteenth_window;
        if (float <= 0.125) return .eighth_window;
        if (float <= 0.25) return .quarter_window;
        if (float <= 0.5) return .half_window;

        return .three_quarter_window;
    }

    pub fn calcSize(self: Self, win_size: usize) usize {
        return @divFloor(win_size, self.toInt());
    }
};

pub fn ShortTimeFourierStatic(comptime T: type, comptime window_size: transforms.WindowSize) type {
    if (T != f32 and T != f64) {
        @compileError("Short Time Fourier Transform only supports f32 and f64 types");
    }

    return struct {
        const Self = @This();
        const Matrix = ComplexMatrix(T);
        const List = ComplexList(T);
        const Window = WindowTable();

        pub const Options = struct {
            comptime window_function: Windowfunction = .hann,
            hop_size: HopSize = .half_window,
            normalize: bool = true,
        };

        const transform = transforms.FourierStatic(T, window_size);
        const win_size: usize = @intFromEnum(window_size);

        hop_size: usize,
        win_table: Window,
        normalize: bool,

        pub fn init(opts: Options) !Self {
            if (opts.hop_size.toInt() > win_size) {
                log.err("ShortTimeFourierStatic.init:  Hop size {d} is greater than window size {d}", .{ opts.hop_size.toInt(), win_size });
                return Error.invalid_hop_size;
            }

            return .{
                .hop_size = opts.hop_size.calcSize(win_size),
                // precomputes the window table and and sum
                .win_table = Window.init(opts.window_function),
                .normalize = opts.normalize,
            };
        }

        // most make a note that the input is modified by this function, there are no copies
        pub fn stft(self: Self, allocator: std.mem.Allocator, input: []T) !Matrix {
            if (input.len < win_size) {
                log.err("ShortTimeFourierStatic.stft: Input size {d} is less than window size {d}", .{ input.len, win_size });
                return Error.invalid_input_size;
            }

            const n_windows: usize = @divFloor((input.len - win_size), self.hop_size) + 1;

            var output = try Matrix.init(allocator, .{
                .rows = @divFloor(win_size, 2) + 1, // frequency bins
                .cols = n_windows, // time slices
                .direction = .column_major,
            });

            try output.zeros(); // maybe remove to improve performance

            // inout is allocated on the stack and reused for each window
            var list_buf: [win_size * @sizeOf(List.ComplexType) + 1]u8 align(@alignOf(T)) = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&list_buf);
            const static_allocator = fba.allocator();
            var inout = try List.init(static_allocator, win_size);

            // Apply window and normalization(when applicable) to input before FFT
            for (0..input.len) |i| {
                const table_index = i % win_size; // wrap around the window size

                input[i] *= self.win_table.table[table_index];
                if (self.normalize) input[i] /= self.win_table.sum;
            }

            for (0..n_windows) |win_index| {
                const start = win_index * self.hop_size;
                const segment = input[start .. start + win_size];

                inout = try transform.fillComplexVector(&inout, segment);
                inout = try transform.fft(&inout);

                //  setRowOrColumn discards negative frequencies
                //  because it fills the matrix column and ignores the rest
                try output.setRowOrColumn(win_index, inout);
            }

            return output;
        }

        fn WindowTable() type {
            return struct {
                const WinTable = @This();
                const util = utils.Utils(T);
                const wz: usize = @intFromEnum(window_size);

                sum: T,
                table: [wz]T,

                fn init(comptime win_func: Windowfunction) WinTable {
                    var s = WinTable{
                        .sum = 0,
                        .table = undefined,
                    };

                    for (0..wz) |i| {
                        const window_func = switch (win_func) {
                            .hann => util.hanning(i, wz),
                            .blackman => util.blackman(i, wz),
                        };

                        s.sum += window_func;
                        s.table[i] = window_func;
                    }

                    return s;
                }
            };
        }
    };
}

pub fn ShortTimeFourierDynamic(comptime T: type) type {
    return struct {
        const Self = @This();
        const transform = transforms.FourierDynamic(T);
        const Matrix = ComplexMatrix(T);
        const List = ComplexList(T);

        const Options = struct {
            window_size: transforms.WindowSize,
            hop_size: HopSize,
            window_function: Windowfunction = .hann,
            normalize: bool = false,
        };

        const WindowTable = struct {
            const util = utils.Utils(T);

            sum: T,
            table: []T,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, win_func: Windowfunction, window_size: usize) !WindowTable {
                var table = try allocator.alloc(T, window_size);
                var sum: T = 0.0;

                for (0..window_size) |i| {
                    const window_func: T = switch (win_func) {
                        .hann => util.hanning(i, window_size),
                        .blackman => util.blackman(i, window_size),
                    };

                    sum += window_func;
                    table[i] = window_func;
                }

                return .{
                    .sum = sum,
                    .table = table,
                    .allocator = allocator,
                };
            }

            pub fn deinit(self: WindowTable) void {
                self.allocator.free(self.table);
            }
        };

        window_size: usize,
        hop_size: usize,
        normalize: bool,
        win_table: WindowTable,
        window: Windowfunction,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, opts: Options) !Self {
            if (opts.hop_size.toInt() > @intFromEnum(opts.window_size)) {
                log.err("ShortTimeFourierDynamic.init Hop size {d} is greater than window size {d}", .{ opts.hop_size.toInt(), @intFromEnum(opts.window_size) });
                return Error.invalid_hop_size;
            }
            return .{
                .window_size = @intFromEnum(opts.window_size),
                .hop_size = opts.hop_size.calcSize(@intFromEnum(opts.window_size)),
                .normalize = opts.normalize,
                .win_table = try WindowTable.init(allocator, opts.window_function, @intFromEnum(opts.window_size)),
                .window = opts.window_function,
                .allocator = allocator,
            };
        }

        pub fn stft(self: Self, allocator: std.mem.Allocator, input: []T) !Matrix {
            if (input.len < self.window_size) {
                log.err("ShortTimeFourierDynamic.stft: Input size {d} is less than window size {d}", .{ input.len, self.window_size });
                return Error.invalid_input_size;
            }

            const n_windows: usize = @divFloor((input.len - self.window_size), self.hop_size) + 1;

            // caller must provide the allocator here matrix belongs to the caller
            var output = try Matrix.init(allocator, .{
                .rows = @divFloor(self.window_size, 2) + 1,
                .cols = n_windows,
                .direction = .column_major,
            });

            try output.zeros();

            // for the Dynamic version, we allocate to prevent modifying the input
            var windowed_input = try self.allocator.alloc(T, input.len);
            defer allocator.free(windowed_input);

            for (0..input.len) |i| {
                const table_index = i % self.window_size;
                windowed_input[i] = input[i] * self.win_table.table[table_index];
                if (self.normalize) windowed_input[i] /= self.win_table.sum;
            }

            for (0..n_windows) |win_index| {
                const start = win_index * self.hop_size;
                const segment = windowed_input[start .. start + self.window_size];

                var inout = try transform.fft(self.allocator, segment);
                defer inout.deinit();

                try output.setRowOrColumn(win_index, inout);
            }

            return output;
        }

        pub fn deinit(self: Self) void {
            self.win_table.deinit();
        }
    };
}

test "ShortTimeFourierStatic: Initialization" {
    var stft = try ShortTimeFourierStatic(f32, .wz_64).init(.{
        .window_function = .hann,
        .hop_size = .quarter_window,
    });
    try std.testing.expectEqual(stft.hop_size, 16);

    stft = try ShortTimeFourierStatic(f32, .wz_64).init(.{
        .window_function = .hann,
        .hop_size = .eighth_window,
    });
    try std.testing.expectEqual(stft.hop_size, 8);

    stft = try ShortTimeFourierStatic(f32, .wz_64).init(.{
        .window_function = .hann,
        .hop_size = .half_window,
    });

    try std.testing.expectEqual(stft.hop_size, 32);

    const err = ShortTimeFourierStatic(f32, .wz_2).init(.{
        .window_function = .hann,
        .hop_size = .quarter_window,
    });

    try std.testing.expectError(Error.invalid_hop_size, err);
}

test "ShortTimeFourierStatic: STFT" {
    const allocator = std.testing.allocator;

    const stft = try ShortTimeFourierStatic(f32, .wz_64).init(.{
        .window_function = .hann,
        .hop_size = .quarter_window,
        .normalize = false,
    });

    try std.testing.expectEqual(stft.hop_size, 16);
    var mat = try stft.stft(allocator, &test_data.stft_sine_intput);
    defer mat.deinit();

    try std.testing.expectEqual(mat.rows, test_data.stft_expected.len);
    try std.testing.expectEqual(mat.cols, test_data.stft_expected[0].len);

    for (0..mat.rows) |row| {
        for (0..mat.cols) |col| {
            // TODO: get a test case
            const expected = test_data.stft_expected[row][col];
            const actual = mat.get(row, col).?;

            _ = expected;
            _ = actual;

            //         try std.testing.expectApproxEqAbs(expected.im, actual.im, 1);
            //         try std.testing.expectApproxEqAbs(expected.re, actual.re, 1);
        }
    }
}

test "ShortTimeFourierStatic: returns an error when input size is less than window size" {
    const allocator = std.testing.allocator;
    const short_time = try ShortTimeFourierStatic(f64, .wz_512).init(.{});

    var input: [128]f64 = undefined;
    var w = waves.Wave(f64).init(400.0, 1.0, 44100.0);

    const sine_input = w.sine(&input);
    const err = short_time.stft(allocator, sine_input);

    try std.testing.expectError(Error.invalid_input_size, err);
}

test "ShortTimeFourierDynamic: Initialization" {
    const allocator = std.testing.allocator;

    const stft = try ShortTimeFourierDynamic(f32).init(allocator, .{
        .window_size = .wz_64,
        .hop_size = .quarter_window,
        .window_function = .hann,
        .normalize = false,
    });

    defer stft.deinit();

    try std.testing.expectEqual(stft.hop_size, 16);
    try std.testing.expectEqual(stft.window_size, 64);
    try std.testing.expectEqual(stft.normalize, false);
    try std.testing.expectEqual(stft.window, .hann);
}

test "ShorttimeFourierDynamic: Run" {
    const allocator = std.testing.allocator;

    var input: [128]f32 = undefined;
    var w = waves.Wave(f32).init(400.0, 1.0, 44100.0);

    const sine_input = w.sine(&input);

    const stft = try ShortTimeFourierDynamic(f32).init(allocator, .{
        .window_size = .wz_64,
        .hop_size = .quarter_window,
        .window_function = .hann,
        .normalize = false,
    });

    defer stft.deinit();

    var mat = try stft.stft(allocator, sine_input);

    defer mat.deinit();

    for (0..mat.cols) |col| {
        for (0..mat.rows) |row| {
            // TODO: get a test case
            const actual = mat.get(row, col).?;
            _ = actual;
            //       std.debug.print("Actual ({d}x{d}): re: {d:.4}, im: {d:.4}\n", .{ row, col, actual.re, actual.im });
            //_ = actual;
        }
    }
}
