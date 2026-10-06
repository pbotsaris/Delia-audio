//! `AudioCard` represents a single ALSA audio card, managing its details,
//! playback, and capture ports. This struct interacts with ALSA to retrieve
//! and manage audio port information and settings.

const std = @import("std");
const utils = @import("utils");

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

const AlsaError = @import("error.zig").AlsaError;
const FormatType = @import("settings.zig").FormatType;
const StreamType = @import("settings.zig").StreamType;
const SampleRate = @import("common").audio_specs.SampleRate;
const ChannelCount = @import("settings.zig").ChannelCount;
const settings = @import("settings.zig");
const SupportedSettings = @import("SupportedSettings.zig");

const AudioCard = @This();

pub const CardError = error{
    playback_not_found,
    capture_not_found,
    playback_out_of_bounds,
    capture_out_of_bounds,
    invalid_settings,
    invalid_supported_settings,
};

const Identifier = struct {
    device: c_int,
    card: c_int,
};

pub const FindBy = enum {
    name,
    id,
};

const AudioCardSettings = struct {
    format: ?FormatType = null,
    sample_rate: ?SampleRate = null,
    channels: ?ChannelCount = null,
    access_type: ?settings.AccessType = null,
};

/// `AudioCardInfo` holds detailed information about an ALSA audio card or port.
/// This includes its identifier, name, and various settings related to playback or capture ports.
///
/// This struct is typically used within the `AudioCard` struct to manage individual ports on an audio card.
pub const AudioCardInfo = struct {
    pub const AudioCardInfoType = enum {
        card,
        device,
    };

    /// The index of the audio card or port.
    index: c_int,
    /// The ALSA id string for the card or port.
    id: []u8 = undefined,
    /// The ALSA name string for the card or port.
    name: []u8 = undefined,

    /// A sentinel-terminated identifier string used for interaction with the C API.
    /// This string typically follows the format `"hw:{card},{port}"` for ports or `"hw:{card}"` for cards.
    identifier: [:0]u8 = undefined,
    /// Supported settings for this audio port according to ALSA.
    /// Only applicable for playback or capture details. Card-level details won't have this information,
    supported_settings: ?SupportedSettings = null,
    /// The currently selected settings (format, sample rate, channels) for this audio card or port.
    selected_settings: AudioCardSettings,
    /// The type of stream (playback or capture) associated with this audio card or port.
    stream_type: ?StreamType = null,
    allocator: std.mem.Allocator,

    type: AudioCardInfoType,

    //// Initializes an `AudioCardInfo` from ALSA C types.
    ///
    /// - `allocator`: The memory allocator to use for dynamic allocations.
    /// - `ident`: The identifier for the card and port, consisting of card and port indices.
    /// - `id`: The ALSA id string.
    /// - `name`: The name of the audio card or device.
    /// - Returns: An initialized `AudioCardInfo` instance.
    /// - Errors: Can return errors related to memory allocations.
    pub fn init(allocator: std.mem.Allocator, ident: Identifier, id: [*c]const u8, name: [*c]const u8) !AudioCardInfo {
        var details = AudioCardInfo{
            .allocator = allocator,
            .index = if (ident.device >= 0) ident.device else ident.card,
            .selected_settings = AudioCardSettings{},
            .type = if (ident.device >= 0) .device else .card,
        };

        const spanned_id = std.mem.span(id);
        const spanned_name = std.mem.span(name);
        const ident_len = getLength(ident);

        details.id = try details.allocator.alloc(u8, spanned_id.len);
        details.name = try details.allocator.alloc(u8, spanned_name.len);
        var identifier = try details.allocator.alloc(u8, ident_len);
        defer details.allocator.free(identifier);

        @memcpy(details.id, spanned_id);
        @memcpy(details.name, spanned_name);

        if (ident.device >= 0) {
            identifier = try std.fmt.bufPrint(identifier, "hw:{d},{d}", .{ ident.card, ident.device });
        } else {
            identifier = try std.fmt.bufPrint(identifier, "hw:{d}", .{ident.card});
        }

        // for sentinel termination
        details.identifier = try details.allocator.dupeZ(u8, identifier);
        return details;
    }

    /// Adds supported formats for this audio card or port based on the stream type.
    /// This function tests for all avaiable formats, sample rates, and channel counts.
    ///
    /// - `stream_type`: The type of stream (playback or capture) for which to add supported formats.
    /// This function updates the `supported_settings` and `stream_type` fields of the `AudioCardInfo`.
    pub fn addSupportedFormats(self: *AudioCardInfo, stream_type: StreamType) void {
        self.supported_settings = SupportedSettings.init(self.allocator, self.identifier, stream_type);
        self.stream_type = stream_type;

        const ss = self.supported_settings orelse return;

        // defaults
        self.selected_settings.format = ss.default(FormatType);
        self.selected_settings.sample_rate = ss.default(SampleRate);
        self.selected_settings.channels = ss.default(ChannelCount);
        self.selected_settings.access_type = ss.default(settings.AccessType);
    }

    pub fn format(self: AudioCardInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        // null means the info is for a card, not a port, so we adjust indentation
        if (self.supported_settings == null) {
            try writer.print("  │  Ident:       {s}\n", .{self.identifier});
            try writer.print("  │   ID:          {s}\n", .{self.id});
            try writer.print("  │   Name:        {s}\n", .{self.name});
            try writer.print("  │   Index:       {d}\n", .{self.index});
            try writer.print("  │\n", .{});
            return;
        }

        try writer.print("  │    │   Ident:       {s}\n", .{self.identifier});
        try writer.print("  │    │   ID:          {s}\n", .{self.id});
        try writer.print("  │    │   Name:        {s}\n", .{self.name});
        try writer.print("  │    │   Index:       {d}\n", .{self.index});

        if (self.stream_type) |st| {
            try writer.print("  │    │   Stream Type: {s}\n", .{@tagName(st)});
        }
        try writer.print("  │    │\n", .{});

        if (self.supported_settings) |ss| {
            try writer.print("{f}", .{ss});
        }
    }

    pub fn deinit(self: *AudioCardInfo) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.identifier);

        if (self.supported_settings) |*sf| {
            sf.deinit(self.allocator);
        }
    }

    fn getLength(ident: Identifier) usize {
        if (ident.device >= 0) return std.fmt.count("hw:{d},{d}", .{ ident.card, ident.device });
        return std.fmt.count("hw:{d}", .{ident.card});
    }
};

// Details of the audio card, such as id, name, and identifier string.
details: AudioCardInfo,
/// List of capture stream ports available on this audio card.
captures: std.ArrayList(AudioCardInfo),
/// List of playback stream ports available on this audio card.
playbacks: std.ArrayList(AudioCardInfo),
// default to playback

allocator: std.mem.Allocator,

/// Initializes an `AudioCard` with the specified details.
///
/// - `allocator`: The memory allocator to be used for dynamic allocations.
/// - `details`: The details of the audio card.
/// - Returns: An initialized `AudioCard`.
/// - Errors: Can return errors related to memory allocations.
pub fn init(allocator: std.mem.Allocator, details: AudioCardInfo) AudioCard {
    return AudioCard{ //
        .allocator = allocator,
        .details = details,
        .captures = .empty,
        .playbacks = .empty,
    };
}

/// Adds a playback port to the audio card.
///
/// - `index`: The device index of the playback port.
/// - `id`: The ALSA ID string for the port.
/// - `name`: The name of the playback port.
/// - Errors: Returns errors related to ALSA operations or memory allocations.
pub fn addPlayback(self: *AudioCard, index: c_int, id: [*c]const u8, name: [*c]const u8) !void {
    var details = try AudioCardInfo.init(self.allocator, .{ .card = self.details.index, .device = index }, id, name);
    details.addSupportedFormats(StreamType.playback);

    try self.playbacks.append(self.allocator, details);
}

/// Adds a capture port to the audio card.
///
/// - `index`: The device index of the capture port.
/// - `id`: The ALSA ID string for the port.
/// - `name`: The name of the capture port.
/// - Errors: Returns errors related to ALSA operations or memory allocations.
pub fn addCapture(self: *AudioCard, index: c_int, id: [*c]const u8, name: [*c]const u8) !void {
    var details = try AudioCardInfo.init(self.allocator, .{ .card = self.details.index, .device = index }, id, name);
    details.addSupportedFormats(StreamType.capture);

    try self.captures.append(self.allocator, details);
}

/// Searches for a playback port based on the specified criteria.
///
/// - `by`: The field to seach: `.name` for the name of the port or `.id` for the ALSA id.
/// - `pattern`: The pattern to match against.
/// - Returns: The FIRST matching `AudioCardInfo` if found, null otherwise.
pub fn findPlaybackBy(self: AudioCard, by: FindBy, pattern: []const u8) ?AudioCardInfo {
    return findBy(self.playbacks, by, pattern);
}

// Retrieves a playback port by its index.
///
/// - `at`: The index of the playback port to retrieve.
/// - Returns: The `AudioCardInfo` of the specified playback port.
/// - Errors: Returns an error if the index is out of bounds.
pub fn getPlaybackAt(self: AudioCard, at: usize) CardError!AudioCardInfo {
    if (at >= self.playbacks.items.len) {
        return CardError.playback_out_of_bounds;
    }

    return self.playbacks.items[at];
}

/// Searches for a capture port based on the specified criteria.
///
/// - `by`: The field to seach: `.name` for the name of the port or `.id` for the ALSA id.
/// - `pattern`: The pattern to match against.
/// - Returns: The FIRST matching `AudioCardInfo` if found, null otherwise.
pub fn findCaptureBy(self: AudioCard, by: FindBy, pattern: []const u8) ?AudioCardInfo {
    return findBy(self.captures, by, pattern);
}

/// Retrieves a capture port by its index.
///
/// - `at`: The index of the capture port to retrieve.
/// - Returns: The `AudioCardInfo` of the specified capture port.
/// - Errors: Returns an error if the index is out of bounds.
pub fn getCaptureAt(self: AudioCard, at: usize) CardError!AudioCardInfo {
    if (at >= self.captures.items.len) {
        return CardError.capture_out_of_bounds;
    }

    return self.captures.items[at];
}

/// Retrieves a playback port by its identifier.
///
/// - `ident`: The identifier(e.g. `hw:0,1`) string of the playback port.
/// - Returns: The `AudioCardInfo` of the specified playback port.
/// - Errors: Returns an error if no matching port is found.
pub fn getPlaybackByIdent(self: AudioCard, ident: []const u8) CardError!AudioCardInfo {
    for (self.playbacks.items) |playback| {
        if (std.mem.eql(u8, playback.identifier, ident)) {
            return playback;
        }
    }

    return CardError.playback_not_found;
}

/// Retrieves a capture port by its identifier.
///
/// - `ident`: The identifier (e.g. `hw:0,1`) string of the capture port.
/// - Returns: The `AudioCardInfo` of the specified capture port.
/// - Errors: Returns an error if no matching port is found.
pub fn getCaptureByIdent(self: AudioCard, ident: []const u8) CardError!AudioCardInfo {
    for (self.captures.items) |capture| {
        if (std.mem.eql(u8, capture.identifier, ident)) {
            return capture;
        }
    }

    return CardError.capture_not_found;
}

/// Retrieves the index of a port by its identifier and stream type.
///
/// - `stream_type`: The type of stream (playback or capture).
/// - `ident`: The identifier string(e.g. `hw:0,1`) of the port.
/// - Returns: The index of the port with the specified identifier.
/// - Errors: Returns an error if no matching port is found.
pub fn getIndexOf(self: AudioCard, stream_type: StreamType, ident: []const u8) CardError!usize {
    const items = if (stream_type == StreamType.playback) self.playbacks.items else self.captures.items;

    for (0.., items) |i, item| {
        if (std.mem.eql(u8, item.identifier, ident)) {
            return i;
        }
    }

    return if (stream_type == StreamType.playback) CardError.playback_not_found else CardError.capture_not_found;
}

/// Sets the channel count for the specified port.
///
/// - `stream_type`: The type of stream (playback or capture).
/// - `at`: The index of the port.
/// - `channel_count`: The desired channel count.
/// - Errors: Returns an error if the index is out of bounds or if the channel count is invalid.
pub fn setChannelCount(self: *AudioCard, stream_type: StreamType, at: usize, channel_count: ChannelCount) CardError!void {
    if (stream_type == .capture and at >= self.captures.items.len) {
        return CardError.capture_out_of_bounds;
    }

    if (stream_type == .playback and at >= self.playbacks.items.len) {
        return CardError.playback_out_of_bounds;
    }

    // take a reference to mutate the selected settings
    const port = if (stream_type == .playback) &self.playbacks.items[at] else &self.captures.items[at];

    const ss = port.supported_settings orelse return CardError.invalid_supported_settings;

    for (ss.channel_counts.items) |channel| {
        if (channel == channel_count) {
            port.*.selected_settings.channels = channel;
            return;
        }
    }

    return CardError.invalid_settings;
}

// Sets the audio format for the specified port.
///
/// - `stream_type`: The type of stream (playback or capture).
/// - `at`: The index of the port.
/// - `audio_format`: The desired audio format.
/// - Errors: Returns an error if the index is out of bounds or if the format is invalid.
pub fn setFormat(self: *AudioCard, stream_type: StreamType, at: usize, audio_format: FormatType) CardError!void {
    if (stream_type == .capture and at >= self.captures.items.len) {
        return CardError.capture_out_of_bounds;
    }

    if (stream_type == .playback and at >= self.playbacks.items.len) {
        return CardError.playback_out_of_bounds;
    }

    const port = if (stream_type == .playback) &self.playbacks.items[at] else &self.captures.items[at];
    const ss = port.supported_settings orelse return CardError.invalid_supported_settings;

    for (ss.formats.items) |f| {
        if (f == audio_format) {
            port.*.selected_settings.format = f;
            return;
        }
    }

    return CardError.invalid_settings;
}

// Sets the sample rate for the specified port.
///
/// - `stream_type`: The type of stream (playback or capture).
/// - `at`: The index of the port.
/// - `sample_rate`: The desired sample rate.
/// - Errors: Returns an error if the index is out of bounds or if the format is invalid.
pub fn setSampleRate(self: *AudioCard, stream_type: StreamType, at: usize, sample_rate: SampleRate) CardError!void {
    if (stream_type == .capture and at >= self.captures.items.len) {
        return CardError.capture_out_of_bounds;
    }

    if (stream_type == .playback and at >= self.playbacks.items.len) {
        return CardError.playback_out_of_bounds;
    }

    const port = if (stream_type == .playback) &self.playbacks.items[at] else &self.captures.items[at];
    const ss = port.supported_settings orelse return CardError.invalid_supported_settings;

    for (ss.sample_rates.items) |sr| {
        if (sr == sample_rate) {
            port.*.selected_settings.sample_rate = sr;
            return;
        }
    }

    return CardError.invalid_settings;
}

pub fn format(self: AudioCard, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("\n{f}", .{self.details});
    try writer.print("  ├── Playbacks: ({d})\n", .{self.playbacks.items.len});

    if (self.playbacks.items.len == 0) {
        try writer.print("  │    ├── N/A.\n", .{});
    }

    for (0.., self.playbacks.items) |i, playback| {
        try writer.print("  │    ├── PLAYBACK PORT: {d}\n", .{i});
        try writer.print("{f}", .{playback});
        try writer.print("  │    ├──  Select Methods:\n", .{});
        try writer.print("  │    │  hardware.selectPortAt(.playback, {d})\n", .{i});
        try writer.print("  │    │  card.selectPlaybackAt({d})\n", .{i});
        try writer.print("  │    └──\n", .{});
    }

    try writer.print("  ├── Captures: ({d})\n", .{self.captures.items.len});

    if (self.captures.items.len == 0) {
        try writer.print("  │    ├── N/A.\n", .{});
    }

    for (0.., self.captures.items) |i, capture| {
        try writer.print("  │    ├── CAPTURE PORT: {d}\n", .{i});
        try writer.print("{f}", .{capture});
        try writer.print("  │    ├── Select Methods:\n", .{});
        try writer.print("  │    │ hardware.selectPortAt(.capture, {d})\n", .{i});
        try writer.print("  │    │ card.selectCaptureAt({d})\n", .{i});
        try writer.print("  │    └──\n", .{});
    }
}

pub fn deinit(self: *AudioCard) void {
    self.details.deinit();

    for (self.playbacks.items) |*playback| {
        playback.*.deinit();
    }
    for (self.captures.items) |*capture| {
        capture.*.deinit();
    }

    self.playbacks.deinit(self.allocator);
    self.captures.deinit(self.allocator);
}

pub fn findBy(collection: std.ArrayList(AudioCardInfo), by: FindBy, pattern: []const u8) ?AudioCardInfo {
    for (collection.items) |item| {
        const haystack = if (by == FindBy.name) item.name else item.id;
        const matches = utils.findPattern(haystack, pattern, .{ .case_sensitive = false });
        // return the first match
        if (matches) |_| return item;
    }

    return null;
}
