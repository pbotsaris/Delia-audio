/// This module exposes the Delia DSP library to Python, providing bindings
/// for testing and visualization of DSP algorithms, especially using tools like
/// matplotlib and NumPy.
/// Note that this is not optmized for performance, as it is intended for testing during development.
const py = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

const std = @import("std");
const dsp = @import("dsp/dsp.zig");

// using float64 across the board
const T: type = f64;
var zero: usize = 0;

pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = @import("logging.zig").logFn,
};

const log = std.log.scoped(.delia);

fn magnitude(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*]py.PyObject {
    _ = self;

    const pylist: [*c]py.PyObject = parseArgument(args, "O") //
    orelse return @as([*c]py.PyObject, (@ptrFromInt(zero)));

    const pylist_size: usize = @intCast(py.PyList_Size(pylist));
    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(pylist_size)));

    for (0..pylist_size) |i| {
        const item = py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyComplex_Check(item) == 0) {
            return handleError(pylist_result, "List must contain only complex numbers.");
        }

        const complex = std.math.Complex(T).init(py.PyComplex_RealAsDouble(item), py.PyComplex_ImagAsDouble(item));
        const mag = complex.magnitude();

        const py_float: [*c]py.PyObject = py.PyFloat_FromDouble(mag);

        if (py_float == null) {
            return handleError(pylist_result, "Failed to create float object.");
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(i)), py_float);
    }

    return pylist_result;
}

fn decibelFromMagnitude(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    var pylist: [*c]py.PyObject = null;
    var reference: T = 0;

    if (py.PyArg_ParseTuple(args, "Od", &pylist, &reference) == 0) {
        return handleError(null, "Failed to parse arguments");
    }

    if (reference == 0) {
        return handleError(null, "Reference must be greater than 0.");
    }

    if (py.PyList_Check(pylist) == 0) {
        return handleError(null, "Argument must be a list.");
    }

    const pylist_size: usize = @intCast(py.PyList_Size(pylist));

    if (pylist_size == 0) {
        return handleError(null, "List must not be empty.");
    }

    const py_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(pylist_size)));

    const utils = dsp.utils.Utils(T);

    for (0..pylist_size) |i| {
        const item = py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyFloat_Check(item) == 0) {
            return handleError(py_result, "List must contain only floats.");
        }

        // 0.5 reference gives 0db a sine +1 to -1
        const db = utils.DecibelsFromMagnitude(py.PyFloat_AsDouble(item), reference);
        const py_float: [*c]py.PyObject = py.PyFloat_FromDouble(db);

        if (py_float == null) {
            return handleError(py_result, "Failed to create float object.");
        }

        _ = py.PyList_SetItem(py_result, @as(py.Py_ssize_t, @intCast(i)), py_float);
    }

    return py_result;
}

fn phase(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    const pylist = parseArgument(args, "O") orelse return @as([*c]py.PyObject, (@ptrFromInt(zero)));

    const pylist_size: usize = @intCast(py.PyList_Size(pylist));
    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(pylist_size)));

    for (0..pylist_size) |i| {
        const item = py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyComplex_Check(item) == 0) {
            return handleError(pylist_result, "List must contain only complex numbers.");
        }

        const utils = dsp.utils.Utils(T);

        const complex = utils.ComplexType.init(py.PyComplex_RealAsDouble(item), py.PyComplex_ImagAsDouble(item));
        const phs = py.PyFloat_FromDouble(utils.phase(complex));

        if (phs == null) {
            return handleError(pylist_result, "Failed to create float object.");
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(i)), phs);
    }

    return pylist_result;
}

fn sineWave(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) log.err("Memory leak detected", .{});

    var freq: u32 = undefined;
    var amp: T = undefined;
    var sr: usize = undefined;
    var dur: T = undefined;

    if (py.PyArg_ParseTuple(args, "IdKd", &freq, &amp, &sr, &dur) == 0) {
        return handleError(null, "Failed to parse arguments");
    }

    var w = dsp.waves.Wave(T).init(@floatFromInt(freq), amp, @floatFromInt(sr));
    const buf_size: usize = w.bufferSizeFor(dur);

    var allocator = gpa.allocator();

    var buf = allocator.alloc(T, buf_size) catch {
        return handleError(null, "Failed to allocate memory");
    };

    defer allocator.free(buf);
    buf = w.sine(buf);

    const list: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(buf_size)));

    if (list == null) return handleError(list, "Failed to create list");

    var i: usize = 0;

    while (i < buf_size) : (i += 1) {
        const py_float: [*c]py.PyObject = py.PyFloat_FromDouble(buf[i]);
        if (py_float == null) return handleError(list, "Failed to create float object.");

        _ = py.PyList_SetItem(list, @as(isize, @intCast(i)), py_float);
    }

    return list;
}

// FFT and IFFT in the heap as we are not too worried about speed when testing in in Python

fn fft(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*]py.PyObject {
    _ = self;

    const pylist: [*c]py.PyObject = parseArgument(args, "O") //
    orelse return @as([*c]py.PyObject, (@ptrFromInt(zero)));

    const pylist_size: usize = @intCast(py.PyList_Size(pylist));
    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(pylist_size)));

    if (pylist_result == null) {
        return handleError(pylist_result, "Failed to create result list.");
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) log.err("Memory leak detected", .{});

    const allocator = gpa.allocator();
    const transform = dsp.transforms.FourierDynamic(T);

    var buffer = allocator.alloc(T, pylist_size) catch {
        return handleError(pylist_result, "Failed to allocate memory for buffer.");
    };

    defer allocator.free(buffer);

    for (0..pylist_size) |i| {
        buffer[i] = py.PyFloat_AsDouble(py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i))));
    }

    var vec = transform.fft(allocator, buffer) catch {
        return handleError(pylist_result, "Failed to perform FFT.");
    };

    defer vec.deinit();

    for (0..pylist_size) |i| {
        const item = vec.get(i) orelse return handleError(pylist_result, "Failed to access item in ComplexList.");

        const py_complex: [*c]py.PyObject = py.PyComplex_FromDoubles(item.re, item.im);

        if (py_complex == null) {
            return handleError(pylist_result, "Failed to create complex object.");
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(i)), py_complex);
    }

    return pylist_result;
}

fn ifft(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    const pylist: [*c]py.PyObject = parseArgument(args, "O") orelse return @as([*c]py.PyObject, (@ptrFromInt(zero)));

    const pylist_size: usize = @intCast(py.PyList_Size(pylist));
    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(pylist_size)));

    if (pylist_result == null) {
        return handleError(pylist_result, "Failed to create result list.");
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) log.err("Memory leak detected", .{});

    const allocator = gpa.allocator();
    const transform = dsp.transforms.FourierDynamic(T);

    var vec = transform.createUninitializedComplexVector(allocator, pylist_size) catch {
        return handleError(pylist_result, "Failed to allocate memory for complex vector.");
    };

    defer vec.deinit();

    for (0..pylist_size) |i| {
        const item = py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyComplex_Check(item) == 0) {
            return handleError(pylist_result, "List must contain only complex numbers.");
        }

        const complex = transform.ComplexType.init(py.PyComplex_RealAsDouble(item), py.PyComplex_ImagAsDouble(item));

        vec.set(i, complex) catch {
            return handleError(pylist_result, "Failed to set item in ComplexList.");
        };
    }

    vec = transform.ifft(allocator, &vec) catch {
        return handleError(pylist_result, "Failed to perform IFFT.");
    };

    for (0..pylist_size) |i| {
        const item = vec.get(i) orelse return handleError(pylist_result, "Failed to access item in ComplexList.");
        const py_complex: [*c]py.PyObject = py.PyComplex_FromDoubles(item.re, item.im);

        if (py_complex == null) {
            return handleError(pylist_result, "Failed to create complex object.");
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(i)), py_complex);
    }

    return pylist_result;
}

fn stft(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    var pylist: [*c]py.PyObject = null;
    var window_size: usize = 0;
    var hop_size: usize = 0;

    if (py.PyArg_ParseTuple(args, "Okk", &pylist, &window_size, &hop_size) == 0) {
        return handleError(null, "Failed to parse arguments");
    }

    if (py.PyList_Check(pylist) == 0) {
        return handleError(null, "Argument must be a list.");
    }

    const pylist_size: usize = @intCast(py.PyList_Size(pylist));

    if (pylist_size == 0) {
        return handleError(null, "List must not be empty.");
    }

    if (window_size == 0 or hop_size == 0) {
        log.err("window_size: {d}, hop_size: {d}", .{ window_size, hop_size });
        return handleError(null, "Window and hop sizes must be greater than 0.");
    }

    if (window_size <= hop_size) {
        log.err("window_size: {d}, hop_size: {d}", .{ window_size, hop_size });
        return handleError(null, "Window size must be greater than hop size.");
    }

    if (window_size >= pylist_size) {
        log.err("window_size: {d}, list: {d}", .{ window_size, pylist_size });
        return handleError(null, "Window size must be less than the size of the input list.");
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) log.err("Memory leak detected", .{});

    const allocator = gpa.allocator();

    const win_size = dsp.transforms.WindowSize.fromInt(window_size) orelse {
        return handleError(null, "Invalid window size. It must be a power of 2 between 16 and 8192.");
    };

    const short_time = dsp.analysis.ShortTimeFourierDynamic(T).init(allocator, .{
        .window_size = win_size,
        .hop_size = dsp.analysis.HopSize.fromSize(hop_size, window_size),
        .normalize = true,
        .window_function = .hann,
    }) catch |err| {
        log.err("STFT Error: {any}", .{err});
        return handleError(null, "Failed to initialize STFT Object.");
    };

    defer short_time.deinit();

    const signal = allocator.alloc(T, pylist_size) catch |err| {
        log.err("Allocation Error: {any}", .{err});
        return handleError(null, "Failed to allocate memory for signal.");
    };

    defer allocator.free(signal);

    for (0..pylist_size) |i| {
        const item = py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyFloat_Check(item) == 0) {
            return handleError(null, "List must contain only floats.");
        }

        signal[i] = py.PyFloat_AsDouble(item);
    }

    var mat = short_time.stft(allocator, signal) catch |err| {
        log.err("STFT Error: {any}", .{err});
        return handleError(null, "Failed to perform STFT.");
    };

    defer mat.deinit();

    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(mat.rows)));

    if (pylist_result == null) {
        return handleError(pylist_result, "Failed to create result list.");
    }

    for (0..mat.rows) |row| {
        const inner_list: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(mat.cols)));

        if (inner_list == null) {
            return handleError(pylist_result, "Failed to create inner list.");
        }

        for (0..mat.cols) |col| {
            const mat_item = mat.get(row, col) orelse return handleError(pylist_result, "Failed to access item in ComplexMatrix.");
            const py_item = py.PyComplex_FromDoubles(mat_item.re, mat_item.im);

            if (py.PyComplex_Check(py_item) == 0) {
                return handleError(pylist_result, "Failed to create complex object.");
            }

            _ = py.PyList_SetItem(inner_list, @as(py.Py_ssize_t, @intCast(col)), py_item);
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(row)), inner_list);
    }

    return pylist_result;
}

fn fftConvolve(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    var apylist: [*c]py.PyObject = null;
    var bpylist: [*c]py.PyObject = null;

    if (py.PyArg_ParseTuple(args, "OO", &apylist, &bpylist) == 0) {
        py.PyErr_SetString(py.PyExc_RuntimeError, "Failed to parse arguments.");
        return @as([*c]py.PyObject, (@ptrFromInt(zero)));
    }

    const apylist_size: usize = @intCast(py.PyList_Size(apylist));
    const bpylist_size: usize = @intCast(py.PyList_Size(bpylist));

    if (apylist_size != bpylist_size) {
        py.PyErr_SetString(py.PyExc_RuntimeError, "Lists must have the same size.");
        return null;
    }

    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(apylist_size)));

    if (pylist_result == null) {
        return handleError(pylist_result, "Failed to create result list.");
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) log.err("Memory leak detected", .{});

    const transform = dsp.transforms.FourierDynamic(T);
    const allocator = gpa.allocator();

    const abuffer = allocator.alloc(T, apylist_size) catch {
        return handleError(pylist_result, "Failed to allocate memory for buffer.");
    };

    const bbuffer = allocator.alloc(T, bpylist_size) catch {
        return handleError(pylist_result, "Failed to allocate memory for buffer.");
    };

    for (0..apylist_size) |i| {
        const aitem = py.PyList_GetItem(apylist, @as(py.Py_ssize_t, @intCast(i)));
        const bitem = py.PyList_GetItem(bpylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyFloat_Check(aitem) == 0 or py.PyFloat_Check(bitem) == 0) {
            return handleError(pylist_result, "List must contain only floats.");
        }

        abuffer[i] = py.PyFloat_AsDouble(aitem);
        bbuffer[i] = py.PyFloat_AsDouble(bitem);
    }

    const list = transform.convolve(allocator, abuffer, bbuffer) catch {
        return handleError(pylist_result, "Failed to perform Convolution.");
    };

    for (0..apylist_size) |i| {
        const item = list.get(i) orelse return handleError(pylist_result, "Failed to access item in ComplexList.");
        const py_complex: [*c]py.PyObject = py.PyComplex_FromDoubles(item.re, item.im);

        if (py_complex == null) {
            return handleError(pylist_result, "Failed to create complex object.");
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(i)), py_complex);
    }

    return pylist_result;
}

fn fftFrequencies(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;

    var n: T = undefined;
    var sample_rate: usize = undefined;

    if (py.PyArg_ParseTuple(args, "dK", &n, &sample_rate) == 0) {
        py.PyErr_SetString(py.PyExc_RuntimeError, "Failed to parse arguments.");
        return @as([*c]py.PyObject, (@ptrFromInt(zero)));
    }

    // heap allocation as speed does not matter here
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) log.err("Memory leak detected", .{});
    const allocator = gpa.allocator();
    const utils = dsp.utils.Utils(T);

    const out = utils.frequencyBinsAlloc(allocator, n, @as(T, @floatFromInt(sample_rate))) catch {
        return handleError(null, "Failed to allocate memory for frequency bins.");
    };

    defer allocator.free(out);

    const outlist: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(out.len)));

    for (0..out.len) |i| {
        const py_float: [*c]py.PyObject = py.PyFloat_FromDouble(out[i]);
        if (py_float == null) {
            return handleError(null, "Failed to create float object.");
        }

        _ = py.PyList_SetItem(outlist, @as(py.Py_ssize_t, @intCast(i)), py_float);
    }

    return outlist;
}

fn hanning(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    return windowFunction(self, args, .hann);
}

fn blackman(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    return windowFunction(self, args, .blackman);
}

// Helper functions

fn windowFunction(self: [*c]py.PyObject, args: [*c]py.PyObject, wf: dsp.analysis.Windowfunction) [*c]py.PyObject {
    _ = self;

    const pylist = parseArgument(args, "O") orelse return @as([*c]py.PyObject, (@ptrFromInt(zero)));
    const pylist_size: usize = @intCast(py.PyList_Size(pylist));

    const pylist_result: [*c]py.PyObject = py.PyList_New(@as(py.Py_ssize_t, @intCast(pylist_size)));

    if (pylist_result == null) {
        return handleError(pylist_result, "Failed to create result list.");
    }

    const utils = dsp.utils.Utils(T);
    var window_sum: T = undefined;

    for (0..pylist_size) |i| {
        const window_func: T =
            if (wf == .hann) utils.hanning(i, pylist_size) else utils.blackman(i, pylist_size);

        window_sum += window_func;
    }

    for (0..pylist_size) |i| {
        const item = py.PyList_GetItem(pylist, @as(py.Py_ssize_t, @intCast(i)));

        if (py.PyFloat_Check(item) == 0) {
            return handleError(pylist, "List must contain only floats.");
        }

        const sample: T = py.PyFloat_AsDouble(item);

        const window_func: T = //
            if (wf == .hann) utils.hanning(i, pylist_size) else utils.blackman(i, pylist_size);

        // note that we are normalizing the window function
        const py_float: [*c]py.PyObject = py.PyFloat_FromDouble((sample * window_func) / window_sum);

        if (py_float == null) {
            return handleError(pylist_result, "Failed to create float object.");
        }

        _ = py.PyList_SetItem(pylist_result, @as(py.Py_ssize_t, @intCast(i)), py_float);
    }

    return pylist_result;
}

fn parseArgument(args: [*c]py.PyObject, format: [*c]const u8) ?*py.PyObject {
    var pylist: [*c]py.PyObject = null;

    if (py.PyArg_ParseTuple(args, format, &pylist) == 0) {
        py.PyErr_SetString(py.PyExc_RuntimeError, "Failed to parse arguments.");
        return null;
    }

    return pylist;
}

fn handleError(obj_dealloc: [*c]py.PyObject, message: [*c]const u8) [*c]py.PyObject {
    if (obj_dealloc != null) py.Py_DECREF(obj_dealloc);

    py.PyErr_SetString(py.PyExc_RuntimeError, message);
    return @as([*c]py.PyObject, (@ptrFromInt(zero)));
}

var methods = [_]py.PyMethodDef{
    py.PyMethodDef{
        .ml_name = "sine_wave",
        .ml_meth = sineWave,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "sineWave(freq, amp, sr, dur) -> List[int]\n--\n\nGenerate a sine wave of specified frequency, amplitude, sample rate, and duration.",
    },
    py.PyMethodDef{
        .ml_name = "fft",
        .ml_meth = fft,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "fft(data: List[float]) -> List[complex]\n--\n\nPerform a Fast Fourier Transform on the input data.",
    },
    py.PyMethodDef{
        .ml_name = "ifft",
        .ml_meth = ifft,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "ifft(data: List[complex]) -> List[complex]\n--\n\nPerform an Inverse Fast Fourier Transform on the input data.",
    },
    py.PyMethodDef{
        .ml_name = "magnitude",
        .ml_meth = magnitude,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "magnitude(data: List[complex]) -> List[float]\n--\n\nCalculate the magnitude of the input complex numbers.",
    },
    py.PyMethodDef{
        .ml_name = "phase",
        .ml_meth = phase,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "phase(data: List[complex]) -> List[float]\n--\n\nCalculate the phase of the input complex numbers.",
    },
    py.PyMethodDef{
        .ml_name = "fft_convolve",
        .ml_meth = fftConvolve,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "fft_convolve(a: List[float], b: List[float]) -> List[complex]\n--\n\nPerform a convolution of two input lists using the Fast Fourier Transform.",
    },

    py.PyMethodDef{
        .ml_name = "fft_frequencies",
        .ml_meth = fftFrequencies,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "fft_frequencies(n: float, sample_rate: float) -> List[float]\n--\n\nGenerate a list of frequency bins for the FFT.",
    },
    py.PyMethodDef{
        .ml_name = "decibels_from_magnitude",
        .ml_meth = decibelFromMagnitude,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "decibel_from_magnitude(data: List[float]) -> List[float]\n--\n\nCalculate the decibels from the input magnitudes.",
    },

    py.PyMethodDef{
        .ml_name = "hanning",
        .ml_meth = hanning,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "hanning(data: List[float]) -> List[float]\n--\n\nApply a Hanning window to the input data.",
    },

    py.PyMethodDef{
        .ml_name = "blackman",
        .ml_meth = blackman,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "blackman(data: List[float]) -> List[float]\n--\n\nApply a Blackman window to the input data.",
    },
    py.PyMethodDef{
        .ml_name = "stft",
        .ml_meth = stft,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "stft(data: List[float], window_size: int, hop_size: int) -> List[List[complex]]\n--\n\nPerform a Short Time Fourier Transform on the input data.",
    },
    // sentinel: CPython reads the table until it finds a null ml_name
    std.mem.zeroes(py.PyMethodDef),
};

var module = py.PyModuleDef{
    .m_base = py.PyModuleDef_Base{
        .ob_base = py.PyObject{
            .ob_type = null,
        },
        .m_init = null,
        .m_index = 0,
        .m_copy = null,
    },
    .m_name = "_pydelia",
    .m_doc = "Python bindings for Delia",
    .m_size = -1,
    .m_methods = &methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

pub export fn PyInit__pydelia() [*]py.PyObject {
    return py.PyModule_Create(&module);
}
