/// Represents a collection of JACK hardware ports.
///
/// This struct manages both playback and capture ports available in JACK.
/// Ports are retrieved and stored on initialization, allowing for efficient access.
const std = @import("std");
const log = std.log.scoped(.jack);

const c_jack = @cImport({
    @cInclude("jack/jack.h");
});

const c = @import("client.zig");
const Client = c.JackClient;
const PortType = c.PortType;

const utils = @import("../../utils/utils.zig");

const JackHardwareError = error{
    no_ports_found,
};

/// Represents a JACK hardware port.
///
/// Fields:
/// - `uuid`: Unique identifier for the port.
/// - `ptr`: Pointer to the JACK port.
/// - `name`: Port name as a mutable slice.
///
/// Provides a `format` method for structured output.
pub const JackHardwarePort = struct {
    uuid: c_jack.jack_uuid_t, // u64
    ptr: *c_jack.jack_port_t,
    name: []u8,
    type: PortType,

    pub fn format(self: JackHardwarePort, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("│ fullname:  {s}\n", .{self.name});
        try writer.print("│ uuid:      {d}\n", .{self.uuid});
        try writer.print("│\n", .{});
    }
};

/// Jack hardware playback ports.
playbacks: []JackHardwarePort,
/// Jack hardware capture ports.
captures: []JackHardwarePort,
allocator: std.mem.Allocator,

const pb_flags = c_jack.JackPortIsPhysical | c_jack.JackPortIsInput;
const cap_flags = c_jack.JackPortIsPhysical | c_jack.JackPortIsOutput;

const Self = @This();

pub fn init(allocator: std.mem.Allocator, client: *c_jack.jack_client_t) !Self {
    return .{
        .allocator = allocator,
        .playbacks = try getPortsAlloc(allocator, client, pb_flags),
        .captures = try getPortsAlloc(allocator, client, cap_flags),
    };
}

/// Finds a contiguous group of JACK hardware ports that match a given name pattern.
///
/// This function searches for ports containing `name` (case-insensitive) within the specified `port_type` (`.playback` or `.capture`).
///
/// It assumes that if multiple matching ports appear sequentially in the list, they belong to the same group (e.g. different channels of the same card).
///
/// ### Returns:
/// - A slice containing the sequentially matched ports.
/// - If no matches are found, returns an empty slice.
pub fn findPortGroup(self: Self, name: []const u8, port_type: PortType) []JackHardwarePort {
    const ports = switch (port_type) {
        .playback => self.playbacks,
        .capture => self.captures,
    };

    var left_index: usize = 0;
    var right_index: usize = 0;
    var consecutive_matches: usize = 0;

    for (ports, 0..ports.len) |port, i| {
        _ = utils.findPattern(port.name, name, .{ .case_sensitive = false }) orelse {
            consecutive_matches = 0;
            continue;
        };

        if (consecutive_matches == 0) {
            left_index = i;
            right_index = i + 1;
            consecutive_matches = 1;
            continue;
        }

        consecutive_matches += 1;
        right_index += 1;
    }

    return ports[left_index..right_index];
}

/// Finds the first JACK hardware port that matches a given name pattern.
///
/// This function searches for a port containing `name` (case-insensitive) within the specified
/// `port_type` (`.playback` or `.capture`). It returns the first matching port found.
///
/// ### Returns:
/// - The first matching `JackHardwarePort`.
/// - If no match is found, returns `null`.
pub fn findPort(self: Self, name: []const u8, port_type: PortType) ?JackHardwarePort {
    const ports = switch (port_type) {
        .playback => self.playbacks,
        .capture => self.captures,
    };

    for (ports) |port| {
        const maybe_match = utils.findPattern(port.name, name, .{ .case_sensitive = false });
        if (maybe_match) |_| {
            return port;
        }
    }

    return null;
}

pub fn deinit(self: Self) void {
    for (self.playbacks) |port| {
        self.allocator.free(port.name);
    }

    for (self.captures) |port| {
        self.allocator.free(port.name);
    }

    self.allocator.free(self.playbacks);
    self.allocator.free(self.captures);
}

fn getPortsAlloc(allocator: std.mem.Allocator, client: *c_jack.jack_client_t, flags: c_ulong) ![]JackHardwarePort {
    const maybe_ports = c_jack.jack_get_ports(client, null, null, flags);
    defer c_jack.jack_free(@as(?*anyopaque, @ptrCast(maybe_ports)));

    if (maybe_ports == null) return JackHardwareError.no_ports_found;

    var len: usize = 0;
    while (maybe_ports[len] != null) : (len += 1) {}

    const ports = try allocator.alloc(JackHardwarePort, len);

    var i: usize = 0;
    while (maybe_ports[i] != null) : (i += 1) {
        const jack_port_info = maybe_ports[i] orelse continue;

        const port_ptr = c_jack.jack_port_by_name(client, jack_port_info) orelse {
            log.warn("Failed to get port by name for port: {s}.\nThis port is being skipped.\n", .{jack_port_info});
            continue;
        };

        const spanned_port_info = std.mem.span(jack_port_info);
        const name_buf = try allocator.alloc(u8, spanned_port_info.len);
        @memcpy(name_buf, spanned_port_info);

        ports[i].name = name_buf;
        ports[i].ptr = port_ptr;
        ports[i].uuid = c_jack.jack_port_uuid(port_ptr);
        ports[i].type = if (flags == pb_flags) PortType.playback else PortType.capture;
    }

    return ports;
}
