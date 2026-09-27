const std = @import("std");
const waves = @import("waves.zig");
const utils = @import("utils.zig");
const test_data = @import("test_data.zig");
const complex_list = @import("complex_list.zig");

const log = @import("log.zig").log;

const Direction = enum {
    forward,
    inverse,
};

pub const WindowSize = enum(usize) {
    wz_4 = 4,
    wz_2 = 2,
    wz_8 = 8,
    wz_16 = 16,
    wz_32 = 32,
    wz_64 = 64,
    wz_128 = 128,
    wz_256 = 256,
    wz_512 = 512,
    wz_1024 = 1024,
    wz_2048 = 2048,
    wz_4096 = 4096,
    wz_8192 = 8192,

    pub fn fromInt(int: usize) ?WindowSize {
        switch (int) {
            2 => return .wz_2,
            4 => return .wz_4,
            8 => return .wz_8,
            16 => return .wz_16,
            32 => return .wz_32,
            64 => return .wz_64,
            128 => return .wz_128,
            256 => return .wz_256,
            512 => return .wz_512,
            1024 => return .wz_1024,
            2048 => return .wz_2048,
            4096 => return .wz_4096,
            8192 => return .wz_8192,
            else => return null,
        }
    }
};

const Error = error{
    invalid_input_size,
    overflow,
} || std.mem.Allocator.Error || complex_list.ComplexListError;

/// `FourierStatic` provides FFT operations without heap allocation.
/// This is designed for cases where the FFT size is known at compile time.
/// This type is not tread-safe and should not be shared between threads.
/// Input vectors are modified in place.
/// For dynamic FFT sizes or non-power-of-two inputs, see `FourierDynamic`.
///
/// - **FFT Size**: Must be known at compile time and specified via the `FFTSize` enum.
/// - **T**: Supported types are `f32` and `f64`.
/// - **Memory Management**: Uses a fixed buffer allocator for stack-based memory allocation, avoiding the overhead of heap operations.
pub fn FourierStatic(comptime T: type, comptime size: WindowSize) type {
    if (T != f32 and T != f64) {
        @compileError("FourierTransforms only supports f32 and f64");
    }

    return struct {
        pub const ComplexType = std.math.Complex(T);
        pub const ComplexList = complex_list.ComplexList(T);

        const window_size: usize = @intFromEnum(size);
        const levels: usize = std.math.log2(window_size);

        var internal_buffer: [window_size * @sizeOf(ComplexType)]u8 align(@alignOf(T)) = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&internal_buffer);
        const static_allocator = fba.allocator();

        pub fn complexVectorSize() usize {
            return window_size * @sizeOf(ComplexType);
        }

        pub fn maxBinCount() usize {
            return @divFloor(window_size, 2);
        }

        /// A helper function to initialize a `ComplexVector` from an audio signal vector.
        ///
        /// - **Parameters**:
        ///     - `heap_allocator`: Allocator for the `ComplexVector`.
        ///     - `vec`: Input vector containing the audio signal.
        /// - **Returns**: Initialized `ComplexVector`. Throws an error if the input size is invalid.
        pub fn createComplexVectorFrom(allocator: std.mem.Allocator, vec: []T) !ComplexList {
            return try ComplexList.initFrom(allocator, vec);
        }

        pub fn createUninitializedComplexVector(allocator: std.mem.Allocator) !ComplexList {
            return ComplexList.init(allocator, window_size);
        }

        /// Conveniently reuses an existing `ComplexVector` buffer for another FFT iteration by writing new input data to the vector.
        ///
        /// - **Parameters**:
        ///     - `vec`: The `ComplexVector` to be reused.
        ///     - `input`: The new input signal to be written into the `ComplexVector`.
        /// - **Returns**: Updated `ComplexVector`. Throws an error if input size is invalid.
        pub fn fillComplexVector(list: *ComplexList, input: []T) Error!ComplexList {
            if (list.len != input.len or list.len != window_size) {
                log.err(
                    "FourierStatic.fillComplexVector: Invalid input size: list.len: {d}, input.len: {d}, window_size: {d}",
                    .{ list.len, input.len, window_size },
                );
                return Error.invalid_input_size;
            }

            for (input, 0..input.len) |item, i| {
                try list.set(i, ComplexType.init(item, 0));
            }

            return list.*;
        }

        /// Fills the `ComplexVector` with input data and pads the remaining buffer with zeros.
        /// This is useful when the input signal length is smaller than the `ComplexVector` buffer size.
        /// The remaining unused space in the buffer is zero-padded.
        /// The input signal must not exceed the vector size and/or the `fft_size`.
        ///
        /// - **Parameters**:
        ///     - `vec`: The `ComplexVector` to be partially filled and padded.
        ///     - `input`: The input signal to be written into the `ComplexVector`. Can be smaller than the buffer size.
        /// - **Returns**: The updated `ComplexVector`, padded with zeros for the remaining space.
        /// Throws an error if the input exceeds the buffer size.
        pub fn fillComplexVectorWithPadding(list: *ComplexList, input: []T) Error!ComplexList {
            if (input.len > list.len or input.len > window_size) {
                log.err(
                    "FourierStatic.fillComplexVectorWithPadding: Invalid input size: list.len: {d}, input.len: {d}, window_size: {d}",
                    .{ list.len, input.len, window_size },
                );
                return Error.invalid_input_size;
            }

            if (input.len == list.len) return fillComplexVector(list, input);

            for (input, 0..input.len) |item, i| {
                try list.set(i, ComplexType.init(item, 0));
            }

            for (input.len..list.len) |i| {
                try list.set(i, ComplexType.init(0, 0));
            }

            return list.*;
        }

        ///  Computes the FFT on the input vector in place.
        ///  The input vector must be of size `fft_size`.
        ///
        /// - **Parameters**:
        ///     - `inout`: Input/output vector, modified in place.
        /// - **Returns**: Transformed `ComplexVector`. Throws an error if input size is invalid.
        pub fn fft(inout: *ComplexList) Error!ComplexList {
            if (inout.len != window_size) {
                log.err(
                    "FourierStatic.fft: Invalid input size: inout.len: {d}, window_size: {d}",
                    .{ inout.len, window_size },
                );

                return Error.invalid_input_size;
            }

            return fftRadix2(inout, .forward);
        }

        /// Computes the inverse FFT on the input vector in place.
        /// The input vector must be of size `fft_size`.
        ///
        /// - **Parameters**:
        ///     - `inout`: Input/output vector, modified in place.
        /// - **Returns**: Transformed `ComplexVector`. Throws an error if input size is invalid.
        pub fn ifft(inout: *ComplexList) Error!ComplexList {
            if (inout.len != window_size) {
                log.err(
                    "FourierStatic.ifft: Invalid input size: inout.len: {d}, window_size: {d}",
                    .{ inout.len, window_size },
                );
                return Error.invalid_input_size;
            }

            var out = try fftRadix2(inout, .inverse);
            out.normalize();

            return out;
        }

        /// Calculates the magnitude (amplitude) of each element in the `ComplexVector` and writes the result to the output buffer.
        /// Input and output lengths must match.
        ///
        /// - **Parameters**:
        ///     - `vec`: The `ComplexVector` containing complex FFT data.
        ///     - `scale`: The magnitude scale to use (linear or decibel).
        ///     - `out`: Output buffer to store magnitudes.
        /// - **Returns**: Filled output buffer. Throws an error if sizes do not match.
        pub fn magnitude(list: ComplexList, scale: complex_list.MagnitudeScale, out: []T) Error![]T {
            return list.magnitude(scale, out);
        }

        /// Computes the phase (angle) of each element in the `ComplexVector` and writes the result to the output buffer.
        ///
        /// - **Parameters**:
        ///     - `vec`: The `ComplexVector` containing complex FFT data.
        ///     - `out`: Output buffer to store phase angles.
        /// - **Returns**: Filled output buffer. Throws an error if sizes do not match.
        pub fn phase(list: ComplexList, out: []T) Error![]T {
            return list.phase(out);
        }

        /// Convolves two complex vectors using FFT and modifies the both inputs in place.
        /// Returns the avec as the result of the convolution.
        ///
        /// - **Parameters**:
        ///     - `avec`, `bvec`: Input vectors to be convolved.
        /// - **Returns**: Convolved `ComplexVector`. Throws an error if input sizes are invalid.
        pub fn convolve(alist: *ComplexList, blist: *ComplexList) !ComplexList {
            var alist_ffted = try fft(alist);
            const blist_ffted = try fft(blist);

            for (0..alist_ffted.len) |i| {
                const aitem = alist_ffted.get(i) orelse return Error.invalid_input_size;
                const bitem = blist_ffted.get(i) orelse return Error.invalid_input_size;

                try alist_ffted.set(i, aitem.mul(bitem));
            }

            // ifft normalizes the output
            return try ifft(&alist_ffted);
        }

        fn fftRadix2(inout: *ComplexList, direction: Direction) Error!ComplexList {
            const exp_table_len: usize = @divFloor(window_size, 2);

            var exp_table = try ComplexList.init(static_allocator, exp_table_len);
            defer exp_table.deinit();

            for (0..exp_table_len) |i| {
                const pi: T = if (direction == .inverse) -2.0 * std.math.pi else 2.0 * std.math.pi;
                const angle: T = pi * @as(T, @floatFromInt(i)) / @as(T, @floatFromInt(inout.len));
                const exp = ComplexType.init(std.math.cos(angle), -std.math.sin(angle));

                try exp_table.set(i, exp);
            }

            // bit-reversal permutation
            // https://en.wikipedia.org/wiki/Bit-reversal_permutation
            for (0..window_size) |idx| {
                const rev_idx = reverseBits(idx, levels);

                if (idx > rev_idx) {
                    const rev_item = inout.get(rev_idx) orelse return Error.invalid_input_size;
                    const item = inout.get(idx) orelse return Error.invalid_input_size;
                    try inout.set(idx, rev_item);
                    try inout.set(rev_idx, item);
                }
            }

            // Cooley-Tukey decimation-in-time radix-2 FFT
            var full_size: usize = 2;

            while (full_size <= window_size) : (full_size *= 2) {
                const half_size: usize = @divFloor(full_size, 2);
                const table_step: usize = @divFloor(inout.len, full_size);
                var idx: usize = 0;

                while (idx < window_size) : (idx += full_size) {
                    var inner_idx = idx;
                    var table_idx: usize = 0;

                    while (inner_idx < idx + half_size) : (inner_idx += 1) {
                        const out_idx = inner_idx + half_size;

                        const exp = exp_table.get(table_idx) orelse return Error.invalid_input_size;
                        const out_index_item = inout.get(out_idx) orelse return Error.invalid_input_size;

                        const tmp = out_index_item.mul(exp);
                        var temp2 = inout.get(inner_idx) orelse return Error.invalid_input_size;

                        try inout.set(out_idx, temp2.sub(tmp));
                        try inout.set(inner_idx, temp2.add(tmp));

                        table_idx += table_step;
                    }
                }

                // Prevent overflow in 'size *= 2'
                if (full_size == window_size) break;
            }

            return inout.*;
        }
    };
}

/// `FourierDynamic` provides a flexible FFT API that supports heap allocation and dynamic FFT sizes.
/// It can handle non-power-of-two sizes using the Bluestein algorithm, although with reduced performance compared to radix-2 FFT.
///
/// - **FFT Size**: Dynamic and can vary at runtime. Power-of-two sizes are handled using radix-2 FFT, while non-power-of-two sizes are processed using the Bluestein algorithm.
/// - **T**: Supported types are `f32` and `f64`.
pub fn FourierDynamic(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("FourierTransforms only supports f32 and f64");
    }

    return struct {
        pub const ComplexType = std.math.Complex(T);
        pub const ComplexList = complex_list.ComplexList(T);

        /// A helper function to initialize a `ComplexVector` from an audio signal vector.
        ///
        /// - **Parameters**:
        ///     - `heap_allocator`: Allocator for the `ComplexVector`.
        ///     - `len`: The length of of the desired `ComplexVector`.
        /// - **Returns**: Initialized `ComplexVector`. Errors if memory allocation fails.
        pub fn createUninitializedComplexVector(allocator: std.mem.Allocator, len: usize) !ComplexList {
            return try ComplexList.init(allocator, len);
        }

        /// A simple Discrete Fourier Transform (DFT) implementation for testing purposes.
        ///
        /// - **Parameters**:
        ///     - `allocator`: Allocator for dynamic memory management.
        ///     - `in`: Input vector with the audio signal.
        /// - **Returns**: DFT-transformed `ComplexVector`.
        pub fn dft(allocator: std.mem.Allocator, in: []T) !ComplexList {
            var out = try ComplexList.init(allocator, in.len);

            const n = in.len;

            for (0..n) |k| {
                var sum = ComplexType.init(0.0, 0.0);

                for (0..n) |t| {
                    const angle = 2.0 *
                        std.math.pi *
                        @as(T, @floatFromInt(t)) *
                        @as(T, @floatFromInt(k)) /
                        @as(T, @floatFromInt(n));

                    const exp = ComplexType.init(std.math.cos(angle), -std.math.sin(angle));
                    sum = sum.add(exp.mul(ComplexType.init(in[t], 0)));
                }

                try out.set(k, sum);
            }

            return out;
        }

        /// Computes the FFT dynamically, choosing the appropriate algorithm based on input size (radix-2 or Bluestein).
        ///
        /// - **Parameters**:
        ///     - `allocator`: Allocator for dynamic memory management.
        ///     - `in`: Input vector.
        /// - **Returns**: FFT-transformed `ComplexVector`. Throws an error if input size is invalid.
        pub fn fft(allocator: std.mem.Allocator, in: []T) Error!ComplexList {
            if (in.len == 0) return ComplexList.init(allocator, 0);

            var inout = try ComplexList.initFrom(allocator, in);
            errdefer inout.deinit();

            if (isPowerOfTwo(in.len)) return try fftRadix2(allocator, &inout, .forward)
            // more complex algorithms are used for non power of two sizes
            else return try fftBluestein(allocator, &inout, .forward);
        }

        /// Computes the inverse FFT dynamically, applying either radix-2 or Bluestein as necessary.
        ///
        /// - **Parameters**:
        ///     - `allocator`: Allocator for dynamic memory management.
        ///     - `inout`: Input/output vector, modified in place.
        /// - **Returns**: Inverse FFT-transformed `ComplexVector`. Throws an error if input size is invalid.
        pub fn ifft(allocator: std.mem.Allocator, inout: *ComplexList) Error!ComplexList {
            if (inout.len == 0) return inout.*;

            var out =
                if (isPowerOfTwo(inout.len)) try fftRadix2(allocator, inout, .inverse) //
            else try fftBluestein(allocator, inout, .inverse);

            // Scaling the output
            for (0..out.len) |i| {
                const len = ComplexType.init(@as(T, @floatFromInt(out.len)), 0);
                const item = out.get(i) orelse return Error.invalid_input_size;
                try out.set(i, item.div(len));
            }

            return out;
        }

        /// Convolves two complex vectors using FFT. This method creates copies of the input vectors to avoid in-place modification.
        ///
        /// - **Parameters**:
        ///     - `allocator`: Allocator for dynamic memory management.
        ///     - `avec`, `bvec`: Input vectors to be convolved.
        /// - **Returns**: Convolved `ComplexVector`. Throws an error if input sizes are invalid.
        pub fn convolve(allocator: std.mem.Allocator, alist: []T, blist: []T) !ComplexList {
            var alist_complex = try ComplexList.initFrom(allocator, alist);
            var blist_complex = try ComplexList.initFrom(allocator, blist);

            // avec_complex returns
            defer blist_complex.deinit();

            for (alist, 0..alist.len) |item, i| try alist_complex.setScalar(i, item);
            for (blist, 0..blist.len) |item, i| try blist_complex.setScalar(i, item);

            return convolveInPlace(allocator, &alist_complex, &blist_complex);
        }

        /// Calculates the magnitude (amplitude) of each element in the `ComplexVector` and allocates an output buffer to store the results.
        /// The input vector contains complex FFT data, and the output buffer will store the magnitudes.
        ///
        /// - **Parameters**:
        ///     - `allocator`: The memory allocator used to allocate the output buffer.
        ///     - `scale`: The magnitude scale to use (linear or decibel).
        ///     - `vec`: The `ComplexVector` containing complex FFT data.
        /// - **Returns**: Allocated buffer filled with magnitudes. Throws an error if allocation fails.
        pub fn magnitude(allocator: std.mem.Allocator, scale: complex_list.MagnitudeScale, vec: ComplexList) Error![]T {
            return vec.magnitudeAlloc(allocator, scale);
        }

        /// Computes the phase (angle) of each element in the `ComplexVector` and allocates an output buffer to store the results.
        /// The input vector contains complex FFT data, and the output buffer will store the phase angles.
        ///
        /// - **Parameters**:
        ///     - `allocator`: The memory allocator used to allocate the output buffer.
        ///     - `vec`: The `ComplexVector` containing complex FFT data.
        /// - **Returns**: Allocated buffer filled with phase angles. Throws an error if allocation fails.
        pub fn phase(allocator: std.mem.Allocator, vec: ComplexList) Error![]T {
            return vec.phaseAlloc(allocator);
        }

        // Private

        fn fftComplex(allocator: std.mem.Allocator, inout: *ComplexList, direction: Direction) Error!ComplexList {
            if (inout.len == 0) return ComplexList.init(allocator, 0);

            if (isPowerOfTwo(inout.len)) return try fftRadix2(allocator, inout, direction)
            // more complex algorithms are used for non power of two sizes
            else return try fftBluestein(allocator, inout, direction);
        }

        fn fftRadix2(allocator: std.mem.Allocator, inout: *ComplexList, direction: Direction) Error!ComplexList {
            // sanity check for power of two
            if (!isPowerOfTwo(inout.len)) return Error.invalid_input_size;

            // calculate "levels" needed to split the input down to a single element
            const n: usize = inout.len;
            const levels: usize = std.math.log2(n);

            const exp_table_len: usize = @divFloor(inout.len, 2);
            var exp_table = try ComplexList.init(allocator, exp_table_len);
            defer exp_table.deinit();

            for (0..exp_table_len) |i| {
                const pi: T = if (direction == .inverse) -2.0 * std.math.pi else 2.0 * std.math.pi;
                const angle: T = pi * @as(T, @floatFromInt(i)) / @as(T, @floatFromInt(inout.len));
                const exp = ComplexType.init(std.math.cos(angle), -std.math.sin(angle));

                try exp_table.set(i, exp);
            }

            for (0..inout.len) |idx| {
                const rev_idx = reverseBits(idx, levels);

                if (idx > rev_idx) {
                    const item_idx = inout.get(idx) orelse return Error.invalid_input_size;
                    const item_rev_idx = inout.get(rev_idx) orelse return Error.invalid_input_size;

                    try inout.set(idx, item_rev_idx);
                    try inout.set(rev_idx, item_idx);
                }
            }

            // Cooley-Tukey decimation-in-time radix-2 FFT
            var size: usize = 2;

            while (size <= inout.len) : (size *= 2) {
                const half_size: usize = @divFloor(size, 2);
                const table_step: usize = @divFloor(inout.len, size);
                var idx: usize = 0;

                while (idx < inout.len) : (idx += size) {
                    var inner_idx = idx;
                    var table_idx: usize = 0;

                    while (inner_idx < idx + half_size) : (inner_idx += 1) {
                        const out_idx = inner_idx + half_size;
                        const table_item = exp_table.get(table_idx) orelse return Error.invalid_input_size;
                        const out_idx_item = inout.get(out_idx) orelse return Error.invalid_input_size;
                        const inner_idx_item = inout.get(inner_idx) orelse return Error.invalid_input_size;

                        const table_out_item = out_idx_item.mul(table_item);

                        try inout.set(out_idx, inner_idx_item.sub(table_out_item));
                        try inout.set(inner_idx, inner_idx_item.add(table_out_item));

                        table_idx += table_step;
                    }
                }

                if (size == inout.len) break;
            }

            return inout.*;
        }

        fn fftBluestein(allocator: std.mem.Allocator, inout: *ComplexList, direction: Direction) Error!ComplexList {
            var conv_len: usize = 1;

            // Find power of 2 conv_len such that -> conv_len  >= in.len * 2 + 1;
            while (conv_len / 2 < inout.len) {
                // sanity check for overflows
                if (conv_len > std.math.maxInt(usize) / 2) return Error.overflow;
                conv_len *= 2;
            }

            var exp_table = try ComplexList.init(allocator, inout.len);
            defer exp_table.deinit();

            var alist = try ComplexList.init(allocator, conv_len);
            defer alist.deinit();

            var blist = try ComplexList.init(allocator, conv_len);
            defer blist.deinit();

            // trig tables
            for (0..inout.len) |i| {
                const idx: usize = (i * i) % (inout.len * 2);
                const pi: T = if (direction == .inverse) -std.math.pi else std.math.pi;
                const angle = pi * @as(T, @floatFromInt(idx)) / @as(T, @floatFromInt(inout.len));
                const exp = ComplexType.init(std.math.cos(angle), -std.math.sin(angle));

                try exp_table.set(i, exp);
            }

            for (0..inout.len) |i| {
                const item = inout.get(i) orelse return Error.invalid_input_size;
                const exp = exp_table.get(i) orelse return Error.invalid_input_size;

                try alist.set(i, item.mul(exp));
            }

            const item = exp_table.get(0) orelse return Error.invalid_input_size;
            try blist.set(0, item);

            for (1..inout.len) |i| {
                const exp = exp_table.get(i) orelse return Error.invalid_input_size;
                const conj = exp.conjugate();
                try blist.set(i, conj);
                try blist.set(conv_len - i, conj);
            }

            // convolution phase here
            // Note that this function will modify both alist and blist in place
            // returns alist
            alist = try convolveInPlace(allocator, &alist, &blist);

            for (0..inout.len) |i| {
                const list_item = alist.get(i) orelse return Error.invalid_input_size;
                const exp = exp_table.get(i) orelse return Error.invalid_input_size;

                try inout.set(i, list_item.mul(exp));
            }

            return inout.*;
        }

        fn convolveInPlace(allocator: std.mem.Allocator, avec: *ComplexList, bvec: *ComplexList) !ComplexList {
            var alist_ffted = try fftComplex(allocator, avec, Direction.forward);
            const blist_ffted = try fftComplex(allocator, bvec, Direction.forward);

            for (0..alist_ffted.len) |i| {
                const aitem = alist_ffted.get(i) orelse return Error.invalid_input_size;
                const bitem = blist_ffted.get(i) orelse return Error.invalid_input_size;

                try alist_ffted.set(i, aitem.mul(bitem));
            }

            var avec_inversed = try fftComplex(allocator, &alist_ffted, Direction.inverse);

            for (0..avec_inversed.len) |i| {
                const len = ComplexType.init(@as(T, @floatFromInt(avec.len)), 0);
                const item = avec_inversed.get(i) orelse return Error.invalid_input_size;
                try avec_inversed.set(i, item.div(len));
            }

            return avec_inversed;
        }
    };
}

// Utility function

//  fft_idx: index to be reversed
//  width: the number of bits to reverse based on fft levels
//  e.g. so if in.len = 8, width would be 3 because log2(8) = 3
inline fn reverseBits(fft_idx: usize, width: usize) usize {
    // u6 because usize is 64 bits and log2(64) = 6
    return @bitReverse(fft_idx) >> @as(u6, @intCast(@bitSizeOf(usize) - width));
}

inline fn reverseBitsDiscrete(val: usize, width: usize) usize {
    var result: usize = 0;
    var idx: usize = val;
    var i: usize = 0;

    while (i < width) : (i += 1) {
        result = (result << 1) | (idx & 1);
        idx >>= 1;
    }

    return result;
}

inline fn isPowerOfTwo(n: usize) bool {
    return n != 0 and n & (n - 1) == 0;
}

const testing = std.testing;

test "FourierDynamic: dft simple" {
    const allocator = std.testing.allocator;
    var input_signal = [_]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75, -1.0 };

    const transforms = FourierDynamic(f32);
    var output = try transforms.dft(allocator, &input_signal);
    defer output.deinit();

    for (0..output.len) |i| {
        const re = output.get(i).?.re;
        const im = output.get(i).?.im;
        try testing.expectApproxEqRel(test_data.expected_simple_dft[i].re, re, 0.0001);
        try testing.expectApproxEqRel(test_data.expected_simple_dft[i].im, im, 0.0001);
    }
}

test "FourierDynamic: dft sine" {
    const allocator = std.testing.allocator;

    var w = waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [128]f32 = undefined;
    const sine = w.sine(&buffer);

    const transforms = FourierDynamic(f32);
    var output = try transforms.dft(allocator, sine);
    defer output.deinit();

    try testing.expectEqual(output.len, test_data.expected_sine_dft.len);

    for (0..output.len) |i| {
        const re = output.get(i).?.re;
        const im = output.get(i).?.im;
        try testing.expectApproxEqAbs(test_data.expected_sine_dft[i].re, re, 0.001);
        try testing.expectApproxEqAbs(test_data.expected_sine_dft[i].im, im, 0.001);
    }
}

test "FourierDynamic: fft simple power of 2 vs dft" {
    const allocator = std.testing.allocator;
    var input_signal = [8]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };

    const transforms = FourierDynamic(f32);
    var fft_out = try transforms.fft(allocator, &input_signal);
    var dft_out = try transforms.dft(allocator, &input_signal);
    defer fft_out.deinit();
    defer dft_out.deinit();

    for (0..input_signal.len) |i| {
        const fft = fft_out.get(i).?;
        const dft = dft_out.get(i).?;

        try testing.expectApproxEqAbs(fft.re, dft.re, 0.0001);
        try testing.expectApproxEqAbs(fft.im, dft.im, 0.0001);
    }
}

test "FourierDynamic: fft simple non power of 2 vs dft" {
    const allocator = std.testing.allocator;
    var input_signal = [9]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75, -1.0 };

    const transforms = FourierDynamic(f32);
    var fft_out = try transforms.fft(allocator, &input_signal);
    var dft_out = try transforms.dft(allocator, &input_signal);
    defer fft_out.deinit();
    defer dft_out.deinit();

    for (0..input_signal.len) |i| {
        const fft = fft_out.get(i).?;
        const dft = dft_out.get(i).?;

        try testing.expectApproxEqAbs(fft.re, dft.re, 0.0001);
        try testing.expectApproxEqAbs(fft.im, dft.im, 0.0001);
    }
}

test "FourierDynamic: inverse fft simple power of two" {
    const allocator = std.testing.allocator;
    var input_signal = [8]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, 0.75 };

    const transforms = FourierDynamic(f32);

    var fft_out = try transforms.fft(allocator, &input_signal);
    defer fft_out.deinit();

    var inversed = try transforms.ifft(allocator, &fft_out);

    for (0..input_signal.len) |i| {
        const inversed_item = inversed.get(i).?;
        try testing.expectApproxEqAbs(input_signal[i], inversed_item.re, 0.0001);
    }
}

test "FourierDynamic: inverse fft simple power non power of two" {
    const allocator = std.testing.allocator;
    var input_signal = [9]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, 0.75, -1.0 };

    const transforms = FourierDynamic(f32);

    var fft_out = try transforms.fft(allocator, &input_signal);
    defer fft_out.deinit();

    var inversed = try transforms.ifft(allocator, &fft_out);

    for (0..input_signal.len) |i| {
        const inversed_item = inversed.get(i).?;
        try testing.expectApproxEqAbs(input_signal[i], inversed_item.re, 0.0001);
    }
}

test "FourierDynamic: fft sine power of two" {
    const allocator = std.testing.allocator;

    var w = waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [128]f32 = undefined;
    const sine = w.sine(&buffer);

    const transforms = FourierDynamic(f32);
    var output = try transforms.fft(allocator, sine);
    defer output.deinit();

    try testing.expectEqual(output.len, test_data.expected_sine_dft.len);

    for (0..output.len) |i| {
        const re = output.get(i).?.re;
        const im = output.get(i).?.im;
        try testing.expectApproxEqAbs(test_data.expected_sine_dft[i].re, re, 0.001);
        try testing.expectApproxEqAbs(test_data.expected_sine_dft[i].im, im, 0.001);
    }
}

test "FourierDynamic: inverse fft sine wave power non power of two" {
    const allocator = std.testing.allocator;

    var w = waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [128]f32 = undefined;
    const sine = w.sine(&buffer);

    // TODO: this seems wrong?
    const transforms = FourierDynamic(f32);
    var output = try transforms.fft(allocator, sine);
    defer output.deinit();

    var fft_out = try transforms.fft(allocator, &buffer);
    defer fft_out.deinit();

    var inversed = try transforms.ifft(allocator, &fft_out);

    for (0..buffer.len) |i| {
        const inversed_item = inversed.get(i).?;
        try testing.expectApproxEqAbs(buffer[i], inversed_item.re, 0.0001);
    }
}

test "FourierDynamic: magnitude calculation" {
    const allocator = std.testing.allocator;
    const len = 8;

    const transform = FourierDynamic(f32);

    var input = [len]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };

    var complex_vector = try transform.fft(allocator, &input);
    defer complex_vector.deinit();

    const magnitudes = try complex_vector.magnitudeAlloc(allocator, .linear);
    defer allocator.free(magnitudes);

    const expected = [len]f32{ 1.0, 2.613125929752753, 1.4142135623730951, 1.082392200292394, 1.0, 1.082392200292394, 1.4142135623730951, 2.613125929752753 };

    for (magnitudes, 0..magnitudes.len) |item, i| {
        try testing.expectApproxEqAbs(expected[i], item, 0.0001);
    }
}

test "FourierDynamic: phases calculation" {
    const allocator = std.testing.allocator;
    const len = 8;

    const transform = FourierDynamic(f32);

    var input = [len]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };

    var complex_vector = try transform.fft(allocator, &input);
    defer complex_vector.deinit();

    const phases = try complex_vector.phaseAlloc(allocator);
    defer allocator.free(phases);

    const expected = [len]f32{ 0.0, -1.1780972450961724, -0.7853981633974483, -0.39269908169872425, 0.0, 0.39269908169872425, 0.7853981633974483, 1.1780972450961724 };

    for (phases, 0..phases.len) |item, i| {
        try testing.expectApproxEqAbs(expected[i], item, 0.0001);
    }
}

test "FourierDynamic: convolution" {
    const allocator = std.testing.allocator;

    var input_a = [_]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };
    var input_b = [_]f32{ 0.5, -0.5, 0.25, -0.25, 0.0, 0.75, -0.75, 1.0 };

    const transform = FourierDynamic(f32);

    var result = try transform.convolve(allocator, &input_a, &input_b);
    defer result.deinit();

    const expected = [8]f32{ 1.375, 0.12499999999999994, 0.375, -0.375, -0.625, 0.625, -1.125, 0.625 };

    for (0..result.len) |i| {
        const item = result.get(i).?;
        try testing.expectApproxEqAbs(expected[i], item.re, 0.0001);
    }
}

test "FourierStatic: fft multiple simple input" {
    const allocator = std.testing.allocator;
    const fft_size: WindowSize = WindowSize.wz_8;
    var input_signal = [3][@intFromEnum(fft_size)]f32{
        .{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, 0.75 },
        .{ 0.3, 0.4, 0.9, 0.8, 0.4, 0.1, 0.0, 0.75 },
        .{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 },
    };

    // static fourier the fft_size is known at compile time
    // it does no interal heap allocator
    const transform = FourierStatic(f32, fft_size);

    // we need a complex vector to process the input
    // but the allocation can be done before the fft calculation
    // and it can be reused for multiple fft
    var complex_vec = try transform.createComplexVectorFrom(allocator, &input_signal[0]);
    defer complex_vec.deinit();

    // transform 3 times. we always modify the same complex vector
    for (0..input_signal.len) |i| {
        complex_vec = try transform.fft(&complex_vec);
        complex_vec = try transform.ifft(&complex_vec);

        // run 3 times reset the complex vector
        for (0..complex_vec.len) |j| {
            const item = complex_vec.get(j).?;
            try testing.expectApproxEqAbs(input_signal[i][j], item.re, 0.0001);
        }

        // reset the input signal
        if (i + 1 < input_signal.len) {
            complex_vec = try transform.fillComplexVector(&complex_vec, &input_signal[i + 1]);
        }
    }
}

test "FourierStatic: fft sine" {
    const allocator = std.testing.allocator;

    var w = waves.Wave(f32).init(400.0, 1.0, 44100.0);
    var buffer: [128]f32 = undefined;
    const sine = w.sine(&buffer);

    const transforms = FourierStatic(f32, .wz_128);

    var output = try transforms.ComplexList.initFrom(allocator, sine);
    defer output.deinit();

    output = try transforms.fft(&output);

    try testing.expectEqual(output.len, test_data.expected_sine_dft.len);

    for (0..output.len) |i| {
        const re = output.get(i).?.re;
        const im = output.get(i).?.im;

        try testing.expectApproxEqAbs(test_data.expected_sine_dft[i].re, re, 0.001);
        try testing.expectApproxEqAbs(test_data.expected_sine_dft[i].im, im, 0.001);
    }
}

test "FourierStatic: magnitude calculation" {
    const allocator = std.testing.allocator;
    const len = 8;

    const transform = FourierStatic(f32, .wz_8);

    var input = [len]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };
    var complex_vector = try transform.createComplexVectorFrom(allocator, &input);
    defer complex_vector.deinit();

    complex_vector = try transform.fft(&complex_vector);

    var buffer: [len]f32 = undefined;

    const magnitudes = try transform.magnitude(complex_vector, .linear, &buffer);
    const expected = [len]f32{ 1.0, 2.613125929752753, 1.4142135623730951, 1.082392200292394, 1.0, 1.082392200292394, 1.4142135623730951, 2.613125929752753 };

    for (magnitudes, 0..magnitudes.len) |item, i| {
        try testing.expectApproxEqAbs(expected[i], item, 0.0001);
    }
}

test "FourierStatic: phase calculation" {
    const allocator = std.testing.allocator;
    const len = 8;

    const transform = FourierStatic(f32, .wz_8);

    var input = [len]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };
    var complex_vector = try transform.createComplexVectorFrom(allocator, &input);
    defer complex_vector.deinit();

    complex_vector = try transform.fft(&complex_vector);

    var buffer: [len]f32 = undefined;

    const phases = try transform.phase(complex_vector, &buffer);
    const expected = [len]f32{ 0.0, -1.1780972450961724, -0.7853981633974483, -0.39269908169872425, 0.0, 0.39269908169872425, 0.7853981633974483, 1.1780972450961724 };

    for (phases, 0..phases.len) |item, i| {
        try testing.expectApproxEqAbs(expected[i], item, 0.0001);
    }
}

test "FourierStatic: convolution" {
    const allocator = std.testing.allocator;

    var input_a = [_]f32{ 1.0, 0.75, 0.5, 0.25, 0.0, -0.25, -0.5, -0.75 };
    var input_b = [_]f32{ 0.5, -0.5, 0.25, -0.25, 0.0, 0.75, -0.75, 1.0 };

    const transform = FourierStatic(f32, .wz_8);

    var complex_a = try transform.createComplexVectorFrom(allocator, &input_a);
    defer complex_a.deinit();

    var complex_b = try transform.createComplexVectorFrom(allocator, &input_b);
    defer complex_b.deinit();

    var result = try transform.convolve(&complex_a, &complex_b);

    const expected = [8]f32{ 1.375, 0.12499999999999994, 0.375, -0.375, -0.625, 0.625, -1.125, 0.625 };

    for (0..result.len) |i| {
        try testing.expectApproxEqAbs(expected[i], result.get(i).?.re, 0.0001);
    }
}

test "bit reverse test n = 8" {
    const indices = [8]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const expected = [8]usize{ 0, 4, 2, 6, 1, 5, 3, 7 }; // Bit-reversed indices for n = 8
    const width = 3; // log2(8) = 3

    for (indices, 0..indices.len) |idx, i| {
        const result1 = reverseBits(idx, width);
        const result2 = reverseBitsDiscrete(idx, width);
        try testing.expectEqual(expected[i], result1);
        try testing.expectEqual(expected[i], result2);
    }
}

test "bit reverse test for n = 16" {
    const indices = [16]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const expected = [16]usize{ 0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15 }; // Bit-reversed indices for n = 16
    const width = 4; // log2(16) = 4

    for (indices, 0..indices.len) |idx, i| {
        const result1 = reverseBits(idx, width);
        const result2 = reverseBitsDiscrete(idx, width);
        try testing.expectEqual(expected[i], result1);
        try testing.expectEqual(expected[i], result2);
    }
}
