//! `Hardware` manages ALSA audio cards and ports on identifier system.
//! It handles the initialization, selection, and configuration of audio cards
//! and ports. This struct interacts with the ALSA API to gather and manage
//! information about available audio cards and their capabilities.
//!
const std = @import("std");
const log = std.log.scoped(.alsa);
const utils = @import("../../../utils/utils.zig");

const AlsaError = @import("error.zig").AlsaError;
const FormatType = @import("settings.zig").FormatType;
const StreamType = @import("settings.zig").StreamType;
const SampleRate = @import("../../../common/audio_specs.zig").SampleRate;
const ChannelCount = @import("settings.zig").ChannelCount;

pub const AudioCard = @import("AudioCard.zig");

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

const Hardware = @This();

const HardwareError = error{
    cards_out_of_bounds,
    card_not_found,
    invalid_identifier,
    no_port_counterpart_available,
};

const FindBy = AudioCard.FindBy;

/// A list of audio cards detected on the system.
cards: std.ArrayList(AudioCard),
/// Index of the currently selected audio card.
selected_card: usize = 0,
/// Index of the currently selected audio port on the selected card.
selected_port: usize = 0,
/// The type of audio stream currently selected (playback or capture).
selected_stream_type: StreamType = StreamType.playback,
/// The total number of audio cards detected on the system.
card_count: usize = 0,

allocator: std.mem.Allocator,

/// Initializes the `Hardware` struct, gathering information about the
/// available audio cards on the system.
///
/// - `allocator`: The memory allocator to be used for dynamic allocations.
/// - Returns: An initialized `Hardware` struct.
/// - Errors: Can return errors related to ALSA operations or memory allocations.
pub fn init(allocator: std.mem.Allocator) !Hardware {
    var alsa = Hardware{ .cards = .empty, .allocator = allocator };
    try loadSystemCards(&alsa);
    return alsa;
}

pub fn deinit(self: *Hardware) void {
    for (self.cards.items) |*card| {
        card.*.deinit();
    }

    self.cards.deinit(self.allocator);
}
/// Retrieves an `AudioCard` by its index in the list of detected cards.
///
/// - `at`: The index of the audio card.
/// - Returns: The `AudioCard` at the specified index.
/// - Errors: Returns an error if the index is out of bounds.
pub fn getAudioCardAt(self: Hardware, at: usize) HardwareError!AudioCard {
    if (at >= self.cards.items.len) {
        return HardwareError.cards_out_of_bounds;
    }

    return self.cards.items[at];
}

/// Searches for `AudioCard` by matching a pattern to `.name` or `id`.
///  - `by`: The field to search for the pattern.
///  - `pattern`: The pattern to search for.
///  - Returns: The first `AudioCard` that matches the pattern or `null` if no match is found.
pub fn findCardBy(self: Hardware, by: FindBy, pattern: []const u8) ?AudioCard {
    for (self.cards.items) |card| {
        const haystack = switch (by) {
            FindBy.name => card.details.name,
            FindBy.id => card.details.id,
        };

        const matches = utils.findPattern(
            haystack,
            pattern,
            .{ .case_sensitive = false },
        );

        // return the first match
        if (matches) |_| return card;
    }

    return null;
}

/// Retrieves an `AudioCard` by its identifier.
///
/// - `ident`: The identifier string of the audio card.
/// - Returns: The `AudioCard` with the specified identifier.
/// - Errors: Returns an error if the identifier is invalid or if no matching card is found.
pub fn getAudioCardByIdent(self: Hardware, ident: []const u8) HardwareError!AudioCard {
    try validateIdentifier(ident);

    for (self.cards.items) |card| {

        // first we try to match the identifier just with the card index e.g. hw:0
        var split = std.mem.splitScalar(u8, card.details.identifier, ',');

        if (split.next()) |i| {
            if (std.mem.eql(u8, ident, i)) {
                return card;
            }
        }

        // then, in case the user is trying to match with also the device/port identifier e.g. hw:0,0
        if (std.mem.eql(u8, card.details.identifier, ident)) {
            return card;
        }
    }

    return HardwareError.card_not_found;
}

/// Selects an audio card by its index.
///
/// - `at`: The index of the audio card to select.
/// - Errors: Returns an error if the index is out of bounds.
pub fn selectAudioCardAt(self: *Hardware, at: usize) !void {
    if (at >= self.cards.items.len) {
        return HardwareError.cards_out_of_bounds;
    }

    self.selected_card = at;
}

/// Selects an audio card by matching a pattern to `.name` or `id`.
/// - `by`: The field to search for the pattern.
/// - `pattern`: The pattern to search for.
/// - Errors: Returns an error if no matching card is found.
/// - Returns: The first `AudioCard` that matches the pattern.
pub fn selectAudioCardBy(self: *Hardware, by: FindBy, pattern: []const u8) !void {
    for (self.cards.items, 0..) |card, i| {
        const haystack = switch (by) {
            FindBy.name => card.details.name,
            FindBy.id => card.details.id,
        };

        const matches = utils.findPattern(
            haystack,
            pattern,
            .{ .case_sensitive = false },
        );

        if (matches) |_| {
            self.selected_card = i;
            return;
        }
    }

    return HardwareError.card_not_found;
}

/// Selects an audio card by its identifier(e.g. `hw:0`).
///
/// - `ident`: The identifier string of the audio card to select.
/// - Errors: Returns an error if the identifier is invalid or if no matching card is found.
pub fn selectAudioCardByIdent(self: *Hardware, ident: []const u8) HardwareError!void {
    try validateIdentifier(ident);

    for (0.., self.cards.items) |i, card| {
        if (std.mem.eql(u8, card.details.identifier, ident)) {
            self.selected_card = i;
            return;
        }
    }

    return HardwareError.card_not_found;
}

/// Selects an audio port on the selected audio card by its index.
///
/// - `stream_type`: The type of stream (playback or capture).
/// - `at`: The index of the audio port to select.
/// - Errors: Returns an error if the index is out of bounds or if no cards are available.
pub fn selectAudioPortAt(self: *Hardware, stream_type: StreamType, at: usize) !void {
    try errWhenEmpty(self.cards.items.len);

    const selected_card = self.cards.items[self.selected_card];

    const ports = switch (stream_type) {
        StreamType.capture => selected_card.captures,
        StreamType.playback => selected_card.playbacks,
    };

    if (at >= ports.items.len) {
        return switch (stream_type) {
            StreamType.capture => AudioCard.CardError.capture_out_of_bounds,
            StreamType.playback => AudioCard.CardError.playback_out_of_bounds,
        };
    }

    self.selected_port = at;
    self.selected_stream_type = stream_type;
}

/// Selects an audio port on the selected audio card by its identifier (e.g. `hw:0`).
///
/// - `stream_type`: The type of stream (playback or capture).
/// - `ident`: The identifier string of the audio port to select.
/// - Errors: Returns an error if the identifier is invalid, if no cards are available, or if no matching port is found.
pub fn selectAudioPortByIdent(self: *Hardware, stream_type: StreamType, ident: []const u8) !void {
    try validateIdentifier(ident);
    try errWhenEmpty(self.cards.items.len);

    const selected_card = self.cards.items[self.selected_card];
    self.selected_port = try selected_card.getIndexOf(stream_type, ident);
    self.selected_stream_type = stream_type;
}

pub fn selectAudioPortBy(self: *Hardware, stream_type: StreamType, by: FindBy, pattern: []const u8) !void {
    try errWhenEmpty(self.cards.items.len);

    const selected_card = self.cards.items[self.selected_card];

    const ports = switch (stream_type) {
        StreamType.capture => selected_card.captures,
        StreamType.playback => selected_card.playbacks,
    };

    const port = AudioCard.findBy(ports, by, pattern);

    if (port) |p| {
        self.selected_port = try selected_card.getIndexOf(stream_type, p.identifier);
        self.selected_stream_type = stream_type;
        return;
    }

    return HardwareError.card_not_found;
}

/// Retrieves the currently selected `AudioCard`.
/// - Returns: The currently selected `AudioCard`.
///
/// - Errors: Returns an error if no cards are available.
pub fn getSelectedAudioCard(self: Hardware) HardwareError!AudioCard {
    try errWhenEmpty(self.cards.items.len);
    return self.cards.items[self.selected_card];
}

/// Retrieves the currently selected audio port.
///
/// - Returns: The `AudioCard.AudioCardInfo` of the selected port.
/// - Errors: Returns an error if no cards are available
pub fn getSelectedAudioPort(self: Hardware) !AudioCard.AudioCardInfo {
    try errWhenEmpty(self.cards.items.len);

    const card = self.cards.items[self.selected_card];

    if (self.selected_stream_type == StreamType.playback) {
        return try card.getPlaybackAt(self.selected_port);
    }

    return try card.getCaptureAt(self.selected_port);
}
/// Retrieves the counterpart of the currently selected audio port.
///
/// If the selected port is a capture port, this function attempts to find the corresponding playback port
/// with the same identifier, and vice versa. This allows for identifying the paired input/output device
/// on hardware that supports simultaneous capture and playback.
///
/// # Returns:
/// - The `AudioCard.AudioCardInfo` of the counterpart port.
/// - An error if no cards are available or if the hardware does not support both playback and capture on the same card.
pub fn getSelectedAudioPortCounterpart(self: Hardware) !AudioCard.AudioCardInfo {
    const card = self.cards.items[self.selected_card];
    const selected_port = try self.getSelectedAudioPort();

    // the counterpart port has the same indentifer but we need to look in the other list
    const index = switch (self.selected_stream_type) {
        StreamType.capture => card.getIndexOf(.playback, selected_port.identifier),
        StreamType.playback => card.getIndexOf(.capture, selected_port.identifier),
    } catch {
        return HardwareError.no_port_counterpart_available;
    };

    return switch (self.selected_stream_type) {
        StreamType.capture => card.getPlaybackAt(index),
        StreamType.playback => card.getCaptureAt(index),
    };
}

/// Sets the number of channels for the selected audio port.
///
/// - `channel_count`: The desired channel count.
/// - Errors: Returns an error if no cards are available or if the channel count is invalid or not supported.
pub fn setSelectedChannelCount(self: *Hardware, channel_count: ChannelCount) !void {
    try errWhenEmpty(self.cards.items.len);

    var card = self.cards.items[self.selected_card];
    try card.setChannelCount(self.selected_stream_type, self.selected_port, channel_count);
}

/// Sets the audio format for the selected audio port.
///
/// - `format`: The desired audio format.
/// - Errors: Returns an error if no cards are available or if the format is invalid or not supported.
pub fn setSelectedFormat(self: *Hardware, fmt: FormatType) !void {
    try errWhenEmpty(self.cards.items.len);

    var card = self.cards.items[self.selected_card];
    try card.setFormat(self.selected_stream_type, self.selected_port, fmt);
}

/// Sets the sample rate for the selected audio port.
///
/// - `format`: The desired audio format.
/// - Errors: Returns an error if no cards are available or if the sample rate is invalid or not supported.
pub fn setSelectedSampleRate(self: *Hardware, sample_rate: SampleRate) !void {
    try errWhenEmpty(self.cards.items.len);

    var card = self.cards.items[self.selected_card];
    try card.setSampleRate(self.selected_stream_type, self.selected_port, sample_rate);
}

pub fn format(self: Hardware, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Audio Hardware Info\n", .{});

    for (0.., self.cards.items) |i, card| {
        try writer.print("Card {d}\n", .{i});
        try writer.print("{f}", .{card});
        try writer.print("\n", .{});
    }
}

// Private

fn validateIdentifier(ident: []const u8) HardwareError!void {
    if (ident.len == 0) {
        return HardwareError.invalid_identifier;
    }

    if (ident.len < 3 or !std.mem.eql(u8, ident[0..2], "hw")) {
        return HardwareError.invalid_identifier;
    }
}

fn addCard(self: *Hardware, card: AudioCard) !void {
    try self.cards.append(self.allocator, card);
}

fn loadSystemCards(self: *Hardware) !void {
    var card: c_int = -1;

    while (c_alsa.snd_card_next(&card) >= 0 and card >= 0) {
        var ctl: ?*c_alsa.snd_ctl_t = null;
        var buffer: [32]u8 = undefined;

        const card_name = try std.fmt.bufPrintZ(&buffer, "hw:{d}", .{card});
        var res = c_alsa.snd_ctl_open(&ctl, card_name, 0);

        if (res < 0) {
            log.warn("Failed to open control interface for card {d}: {s}", .{ card, c_alsa.snd_strerror(res) });
            continue;
        }

        var info: ?*c_alsa.snd_ctl_card_info_t = null;
        res = c_alsa.snd_ctl_card_info_malloc(&info);

        if (res < 0) {
            log.warn("Failed to allocate card info for card {d}: {s}", .{ card, c_alsa.snd_strerror(res) });
            continue;
        }

        defer c_alsa.snd_ctl_card_info_free(info);

        res = c_alsa.snd_ctl_card_info(ctl, info);

        if (res < 0) {
            log.warn("Failed to get card info for card {d}: {s}", .{ card, c_alsa.snd_strerror(res) });
            continue;
        }

        const card_details = try AudioCard.AudioCardInfo.init(self.allocator, .{ .card = card, .device = -1 }, c_alsa.snd_ctl_card_info_get_id(info), c_alsa.snd_ctl_card_info_get_name(info));
        var alsa_card = AudioCard.init(self.allocator, card_details);

        alsa_card = (try getCard(&alsa_card, ctl, StreamType.playback)).*;
        alsa_card = (try getCard(&alsa_card, ctl, StreamType.capture)).*;

        try self.addCard(alsa_card);
        res = c_alsa.snd_ctl_close(ctl);

        if (res < 0) {
            log.warn("Failed to close control interface for card {d}: {s}", .{ card, c_alsa.snd_strerror(res) });
        }
    }
}

fn getCard(card: *AudioCard, ctl: ?*c_alsa.snd_ctl_t, stream_type: StreamType) !*AudioCard {
    var device: c_int = -1;
    var res: c_int = -1;

    while (c_alsa.snd_ctl_pcm_next_device(ctl, &device) >= 0 and device >= 0) {
        var pcm_info: ?*c_alsa.snd_pcm_info_t = null;

        res = c_alsa.snd_pcm_info_malloc(&pcm_info);

        if (res < 0) {
            log.warn("Failed to allocate PCM info for device {d}: {s}", .{ device, c_alsa.snd_strerror(res) });
            continue;
        }

        defer c_alsa.snd_pcm_info_free(pcm_info);

        c_alsa.snd_pcm_info_set_device(pcm_info, @as(c_uint, @intCast(device)));
        c_alsa.snd_pcm_info_set_subdevice(pcm_info, 0);
        c_alsa.snd_pcm_info_set_stream(pcm_info, @intFromEnum(stream_type));
        res = c_alsa.snd_ctl_pcm_info(ctl, pcm_info);

        if (res < 0) {
            log.warn("Failed to get PCM info for device {d}: {s}", .{ device, c_alsa.snd_strerror(res) });
            continue;
        }
        switch (stream_type) {
            StreamType.capture => try card.addCapture(device, c_alsa.snd_pcm_info_get_id(pcm_info), c_alsa.snd_pcm_info_get_name(pcm_info)),
            StreamType.playback => try card.addPlayback(device, c_alsa.snd_pcm_info_get_id(pcm_info), c_alsa.snd_pcm_info_get_name(pcm_info)),
        }
    }

    return card;
}

fn errWhenEmpty(len: usize) HardwareError!void {
    if (len == 0) {
        log.err("Hardware: No cards available", .{});
        return HardwareError.card_not_found;
    }
}

test "getAudioCardAt returns correct AudioCard or error" {
    const allocator = std.testing.allocator;
    const AudioCardInfo = AudioCard.AudioCardInfo;

    // Mocking the Hardware and AudioCard setup
    var hardware = Hardware{
        .cards = .empty,
        .allocator = allocator,
    };

    defer hardware.deinit();

    const ident1 = "hw:0";
    const ident2 = "hw:1";

    try hardware.cards.append(allocator, 
        AudioCard.init(
            allocator,
            try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, ident1, "Card 1"),
        ),
    );

    try hardware.cards.append(allocator, 
        AudioCard.init(
            allocator,
            try AudioCardInfo.init(allocator, .{ .card = 1, .device = 0 }, ident2, "Card 2"),
        ),
    );

    // Test: Retrieve the first card
    const card1 = try hardware.getAudioCardAt(0);
    try std.testing.expectEqualStrings("Card 1", card1.details.name);

    // Test: Retrieve the second card
    const card2 = try hardware.getAudioCardAt(1);
    try std.testing.expectEqualStrings("Card 2", card2.details.name);

    // Test: Out of bounds access
    const result = hardware.getAudioCardAt(2);
    try std.testing.expectError(HardwareError.cards_out_of_bounds, result);
}

test "getAudioCardByIdent returns correct AudioCard or error" {
    const allocator = std.testing.allocator;
    const AudioCardInfo = AudioCard.AudioCardInfo;

    // Mocking the Hardware and AudioCard setup
    var hardware = Hardware{
        .cards = .empty,
        .allocator = allocator,
    };
    defer hardware.deinit();

    // both ways should work to retrieve the card, the port/device identifier is optional
    const ident1 = "hw:0";
    const ident2 = "hw:1,0";

    try hardware.cards.append(allocator, 
        AudioCard.init(allocator, try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "someid", "Card 1")),
    );
    try hardware.cards.append(allocator, 
        AudioCard.init(allocator, try AudioCardInfo.init(allocator, .{ .card = 1, .device = 0 }, "someid2", "Card 2")),
    );

    const card2 = try hardware.getAudioCardByIdent(ident2);
    try std.testing.expectEqualStrings("Card 2", card2.details.name);

    const card1 = try hardware.getAudioCardByIdent(ident1);
    try std.testing.expectEqualStrings("Card 1", card1.details.name);

    const result = hardware.getAudioCardByIdent("hw:2,3");
    try std.testing.expectError(HardwareError.card_not_found, result);
}

test "selectAudioPortAt and selectAudioPortByIdent select correct port or return errors" {
    const allocator = std.testing.allocator;
    const AudioCardInfo = AudioCard.AudioCardInfo;

    // Mocking the Hardware and AudioCard setup
    var hardware = Hardware{
        .cards = .empty,
        .allocator = allocator,
    };
    defer hardware.deinit();

    // Mock AudioCard with playbacks and captures
    var card = AudioCard.init(
        allocator,
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "audiocard_id", "Card 1"),
    );

    // Manually add playback and capture ports to avoid ALSA API calls
    try card.playbacks.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "playback_id", "Playback 1"),
    );
    try card.captures.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 1 }, "capture_id", "Capture 1"),
    );

    // Add card to hardware
    try hardware.cards.append(allocator, card);

    try hardware.selectAudioPortAt(StreamType.playback, 0);
    try std.testing.expectEqual(0, hardware.selected_port);
    try std.testing.expectEqual(StreamType.playback, hardware.selected_stream_type);

    try hardware.selectAudioPortByIdent(StreamType.capture, "hw:0,1");
    try std.testing.expectEqual(0, hardware.selected_port);
    try std.testing.expectEqual(StreamType.capture, hardware.selected_stream_type);

    const result = hardware.selectAudioPortAt(StreamType.playback, 1);
    try std.testing.expectError(AudioCard.CardError.playback_out_of_bounds, result);

    const result2 = hardware.selectAudioPortByIdent(StreamType.playback, "invalid_id");
    try std.testing.expectError(HardwareError.invalid_identifier, result2);
}

test "selectAudioPortBy selects correct port or returns errors" {
    const allocator = std.testing.allocator;
    const AudioCardInfo = AudioCard.AudioCardInfo;

    // Mocking the Hardware and AudioCard setup
    var hardware = Hardware{
        .cards = .empty,
        .allocator = allocator,
    };
    defer hardware.deinit();

    // Mock AudioCard with playbacks and captures
    var card = AudioCard.init(
        allocator,
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "audiocard_id", "Card 1"),
    );

    // Manually add playback and capture ports to avoid ALSA API calls
    try card.playbacks.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "playback_id", "Playback 1"),
    );
    try card.captures.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 1 }, "capture_id", "Capture 1"),
    );

    // Add card to hardware
    try hardware.cards.append(allocator, card);

    try hardware.selectAudioPortBy(StreamType.playback, FindBy.id, "playback_id");
    try std.testing.expectEqual(0, hardware.selected_port);
    try std.testing.expectEqual(StreamType.playback, hardware.selected_stream_type);

    try hardware.selectAudioPortBy(StreamType.capture, FindBy.id, "capture_id");
    try std.testing.expectEqual(0, hardware.selected_port);
    try std.testing.expectEqual(StreamType.capture, hardware.selected_stream_type);

    const result = hardware.selectAudioPortBy(StreamType.playback, FindBy.id, "invalid_id");
    try std.testing.expectError(HardwareError.card_not_found, result);
}

test "findCardBy finds correct card or returns null" {
    const allocator = std.testing.allocator;
    const AudioCardInfo = AudioCard.AudioCardInfo;

    // Mocking the Hardware and AudioCard setup
    var hardware = Hardware{
        .cards = .empty,
        .allocator = allocator,
    };
    defer hardware.deinit();

    try hardware.cards.append(allocator, 
        AudioCard.init(
            allocator,
            try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "someid1", "Card 1"),
        ),
    );

    try hardware.cards.append(allocator, 
        AudioCard.init(
            allocator,
            try AudioCardInfo.init(allocator, .{ .card = 1, .device = 0 }, "someid2", "Card 2"),
        ),
    );

    const card1 = hardware.findCardBy(FindBy.id, "someid1");
    try std.testing.expect(card1 != null);
    try std.testing.expectEqualStrings("Card 1", card1.?.details.name);

    const card2 = hardware.findCardBy(FindBy.name, "Card 2");
    try std.testing.expect(card2 != null);
    try std.testing.expectEqualStrings("Card 2", card2.?.details.name);

    const noCard = hardware.findCardBy(FindBy.id, "nonexistent");
    try std.testing.expect(noCard == null);
}

test "getSelectedAudioPortCounterpart finds counterpart or returns error" {
    const allocator = std.testing.allocator;
    const AudioCardInfo = AudioCard.AudioCardInfo;

    var hardware = Hardware{
        .cards = .empty,
        .allocator = allocator,
        .selected_card = 0,
        .selected_port = 0,
        .selected_stream_type = StreamType.playback,
    };
    defer hardware.deinit();

    // Mock AudioCard with playback and capture ports having matching identifiers
    var card = AudioCard.init(
        allocator,
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "hw:0", "Card 1"),
    );

    // Add playback and capture ports with the same identifier to simulate counterparts
    try card.playbacks.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "hw:0,0", "Playback 1"),
    );

    try card.captures.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 0, .device = 0 }, "hw:0,0", "Capture 1"),
    );

    try hardware.cards.append(allocator, card);

    try hardware.selectAudioPortAt(StreamType.playback, 0);
    const capture_port = try hardware.getSelectedAudioPortCounterpart();
    try std.testing.expectEqualStrings("Capture 1", capture_port.name);

    try hardware.selectAudioPortAt(StreamType.capture, 0);
    const playback_port = try hardware.getSelectedAudioPortCounterpart();
    try std.testing.expectEqualStrings("Playback 1", playback_port.name);

    var card_no_counterpart = AudioCard.init(
        allocator,
        try AudioCardInfo.init(allocator, .{ .card = 1, .device = 0 }, "hw:1", "Card 2"),
    );

    try card_no_counterpart.playbacks.append(allocator, 
        try AudioCardInfo.init(allocator, .{ .card = 1, .device = 0 }, "hw:1,0", "Playback Only"),
    );

    try hardware.cards.append(allocator, card_no_counterpart);
    hardware.selected_card = 1;
    hardware.selected_port = 0;
    hardware.selected_stream_type = StreamType.playback;

    const result = hardware.getSelectedAudioPortCounterpart();
    try std.testing.expectError(HardwareError.no_port_counterpart_available, result);
}

// TOO: Maybe one day expose mixer info in alsa AudioCard, but to be honest
// the information here is still limited other then knowing the the channel configuration names
// For USB audio maybe we need udevlib to get more descriptive information
//
//test "alsa mixer test" {
//    var mixer: ?*c_alsa.snd_mixer_t = null;
//    if (c_alsa.snd_mixer_open(&mixer, 0) != 0) {
//        std.debug.print("Failed to open mixer", .{});
//        return;
//    }
//
//    defer {
//        const res = c_alsa.snd_mixer_close(mixer);
//        _ = res;
//    }
//
//    if (c_alsa.snd_mixer_attach(mixer, "hw:3") != 0) {
//        std.debug.print("Failed to attach mixer", .{});
//        return;
//    }
//
//    if (c_alsa.snd_mixer_selem_register(mixer, null, null) != 0) {
//        std.debug.print("Failed to register mixer", .{});
//        return;
//    }
//
//    if (c_alsa.snd_mixer_load(mixer) != 0) {
//        std.debug.print("Failed to load mixer", .{});
//        return;
//    }
//
//    var elem: ?*c_alsa.snd_mixer_elem_t = c_alsa.snd_mixer_first_elem(mixer);
//
//    while (elem != null) {
//        const name = c_alsa.snd_mixer_selem_get_name(elem);
//        std.debug.print("name: {s}\n", .{name});
//
//        const has_playback_ctrl: bool = c_alsa.snd_mixer_selem_has_playback_volume(elem) == 1;
//        const has_capture_ctrl: bool = c_alsa.snd_mixer_selem_has_capture_volume(elem) == 1;
//
//        if (has_playback_ctrl) {
//            var min: c_long = 0;
//            var max: c_long = 0;
//            if (c_alsa.snd_mixer_selem_get_playback_volume_range(elem, &min, &max) != 0) {
//                std.debug.print("Failed to get volume range\n", .{});
//                return;
//            }
//            std.debug.print("Playback Control: min: {d}, max: {d}\n", .{ min, max });
//        }
//
//        if (has_capture_ctrl) {
//            var min: c_long = 0;
//            var max: c_long = 0;
//            if (c_alsa.snd_mixer_selem_get_capture_volume_range(elem, &min, &max) != 0) {
//                std.debug.print("Failed to get volume range\n", .{});
//                return;
//            }
//            std.debug.print("Capture Control: min: {d}, max: {d}\n", .{ min, max });
//        }
//
//        if (!has_playback_ctrl and !has_capture_ctrl) {
//            std.debug.print("No volume control\n", .{});
//        }
//
//        var ch: c_alsa.snd_mixer_selem_channel_id_t = c_alsa.SND_MIXER_SCHN_FRONT_LEFT;
//        while (ch <= c_alsa.SND_MIXER_SCHN_LAST) : (ch += 1) {
//            if (c_alsa.snd_mixer_selem_has_playback_channel(elem, ch) != 0) {
//                std.debug.print("  - Playback Channel: {s}\n", .{c_alsa.snd_mixer_selem_channel_name(ch)});
//            }
//        }
//
//        elem = c_alsa.snd_mixer_elem_next(elem);
//    }
//}

//       c_alsa.snd_ctl_elem_list_free(list);
//  }
//test "alsa control elements query by device/subdevice" {
//    const card_name = "hw:3"; // Change this to match your system
//                              // const target_device = 0; // Change to filter a specific device (e.g., hw:3,0)
//                              // const target_subdevice = 0; // Usually 0 unless multiple subdevices exist
//
//    var ctl: ?*c_alsa.snd_ctl_t = null;
//
//    if (c_alsa.snd_ctl_open(&ctl, card_name, 0) != 0) {
//        std.debug.print("❌ Failed to open control interface for {s}\n", .{card_name});
//        return;
//    }
//
//    defer {
//        _ = c_alsa.snd_ctl_close(ctl);
//    }
//
//    var list: ?*c_alsa.snd_ctl_elem_list_t = null;
//    if (c_alsa.snd_ctl_elem_list_malloc(&list) != 0) {
//        std.debug.print("❌ Failed to allocate control element list\n", .{});
//        return;
//    }
//
//    defer {
//
//    if (c_alsa.snd_ctl_elem_list(ctl, list) != 0) {
//        std.debug.print("❌ Failed to list control elements\n", .{});
//        return;
//    }
//
//    const count = c_alsa.snd_ctl_elem_list_get_count(list);
//    std.debug.print("\n🔹 Found {d} control elements:\n", .{count});
//
//    if (c_alsa.snd_ctl_elem_list_alloc_space(list, count) != 0) {
//        std.debug.print("❌ Failed to allocate space for elements\n", .{});
//        return;
//    }
//
//    if (c_alsa.snd_ctl_elem_list(ctl, list) != 0) {
//        std.debug.print("❌ Failed to retrieve element list\n", .{});
//        return;
//    }
//
//    var elem_info: ?*c_alsa.snd_ctl_elem_info_t = null;
//    if (c_alsa.snd_ctl_elem_info_malloc(&elem_info) != 0) {
//        std.debug.print("❌ Failed to allocate control element info\n", .{});
//        return;
//    }
//
//    defer {
//        c_alsa.snd_ctl_elem_info_free(elem_info);
//    }
//
//    var elem_id: ?*c_alsa.snd_ctl_elem_id_t = null;
//    if (c_alsa.snd_ctl_elem_id_malloc(&elem_id) != 0) {
//        std.debug.print("❌ Failed to allocate element ID\n", .{});
//        return;
//    }
//
//    defer {
//        c_alsa.snd_ctl_elem_id_free(elem_id);
//    }
//
//    for (0..count) |i| {
//        c_alsa.snd_ctl_elem_list_get_id(list, @intCast(i), elem_id);
//        c_alsa.snd_ctl_elem_info_set_id(elem_info, elem_id);
//
//        if (c_alsa.snd_ctl_elem_info(ctl, elem_info) != 0) {
//            std.debug.print("❌ Failed to retrieve info for element {d}\n", .{i});
//            continue;
//        }
//
//        const numid = c_alsa.snd_ctl_elem_info_get_numid(elem_info);
//        const iface = c_alsa.snd_ctl_elem_info_get_interface(elem_info);
//        const name = c_alsa.snd_ctl_elem_info_get_name(elem_info);
//        const index = c_alsa.snd_ctl_elem_info_get_index(elem_info);
//
//        const device = c_alsa.snd_ctl_elem_info_get_device(elem_info);
//        const subdevice = c_alsa.snd_ctl_elem_info_get_subdevice(elem_info);
//
//        // **FILTERING: Only print if it belongs to the target device/subdevice**
//        if (iface == c_alsa.SND_CTL_ELEM_IFACE_MIXER) {
//            std.debug.print("\n🔸 NumID: {d}, Device: {d}, Subdevice: {d}, Interface: {s}, Name: {s}, Index: {d}\n", .{
//                numid, device, subdevice,
//                switch (iface) {
//                    c_alsa.SND_CTL_ELEM_IFACE_CARD => "CARD",
//                    c_alsa.SND_CTL_ELEM_IFACE_MIXER => "MIXER",
//                    c_alsa.SND_CTL_ELEM_IFACE_PCM => "PCM",
//                    else => "OTHER",
//                },
//                name,
//                index,
//            });
//
//            // Classify the control elements
//        }
//    }
//}

//test "2alsa control elements query by device/subdevice" {
//    const card_name = "hw:3";
//    var ctl: ?*c_alsa.snd_ctl_t = null;
//    if (c_alsa.snd_ctl_open(&ctl, card_name, 0) != 0) {
//        std.debug.print("❌ Failed to open control interface for {s}\n", .{card_name});
//        return;
//    }
//    defer {
//        _ = c_alsa.snd_ctl_close(ctl);
//    }
//
//    var list: ?*c_alsa.snd_ctl_elem_list_t = null;
//    if (c_alsa.snd_ctl_elem_list_malloc(&list) != 0) {
//        std.debug.print("❌ Failed to allocate control element list\n", .{});
//        return;
//    }
//    defer {
//        c_alsa.snd_ctl_elem_list_free(list);
//    }
//
//    if (c_alsa.snd_ctl_elem_list(ctl, list) != 0) return;
//
//    const count = c_alsa.snd_ctl_elem_list_get_count(list);
//
//    if (c_alsa.snd_ctl_elem_list_alloc_space(list, count) != 0) return;
//
//    if (c_alsa.snd_ctl_elem_list(ctl, list) != 0) return;
//
//    var elem_info: ?*c_alsa.snd_ctl_elem_info_t = null;
//    if (c_alsa.snd_ctl_elem_info_malloc(&elem_info) != 0) return;
//    defer c_alsa.snd_ctl_elem_info_free(elem_info);
//
//    var elem_id: ?*c_alsa.snd_ctl_elem_id_t = null;
//    if (c_alsa.snd_ctl_elem_id_malloc(&elem_id) != 0) return;
//    defer c_alsa.snd_ctl_elem_id_free(elem_id);
//
//    std.debug.print("\n🎵 PCM Devices:\n", .{});
//    // First get PCM info
//    for (0..count) |i| {
//        c_alsa.snd_ctl_elem_list_get_id(list, @intCast(i), elem_id);
//        c_alsa.snd_ctl_elem_info_set_id(elem_info, elem_id);
//        if (c_alsa.snd_ctl_elem_info(ctl, elem_info) != 0) continue;
//
//        const iface = c_alsa.snd_ctl_elem_info_get_interface(elem_info);
//
//        if (iface == c_alsa.SND_CTL_ELEM_IFACE_PCM) {
//            const name = c_alsa.snd_ctl_elem_info_get_name(elem_info);
//            const numid = c_alsa.snd_ctl_elem_info_get_numid(elem_info);
//            const device = c_alsa.snd_ctl_elem_info_get_device(elem_info);
//            const subdevice = c_alsa.snd_ctl_elem_info_get_subdevice(elem_info);
//
//            std.debug.print("PCM Device {d}.{d}: {s} (NumID: {d})\n", .{ device, subdevice, name, numid });
//        }
//    }
//
//    std.debug.print("\n🎛️ Card Info:\n", .{});
//    // Then get CARD info
//    for (0..count) |i| {
//        c_alsa.snd_ctl_elem_list_get_id(list, @intCast(i), elem_id);
//        c_alsa.snd_ctl_elem_info_set_id(elem_info, elem_id);
//        if (c_alsa.snd_ctl_elem_info(ctl, elem_info) != 0) continue;
//
//        const iface = c_alsa.snd_ctl_elem_info_get_interface(elem_info);
//        if (iface == c_alsa.SND_CTL_ELEM_IFACE_CARD) {
//            const name = c_alsa.snd_ctl_elem_info_get_name(elem_info);
//            const numid = c_alsa.snd_ctl_elem_info_get_numid(elem_info);
//            const device = c_alsa.snd_ctl_elem_info_get_device(elem_info);
//            const subdevice = c_alsa.snd_ctl_elem_info_get_subdevice(elem_info);
//
//            std.debug.print("Card Info: {s} (NumID: {d}, Device: {d}, Subdevice: {d})\n", .{ name, numid, device, subdevice });
//        }
//    }
//
//    for (0..count) |i| {
//        c_alsa.snd_ctl_elem_list_get_id(list, @intCast(i), elem_id);
//        c_alsa.snd_ctl_elem_info_set_id(elem_info, elem_id);
//        if (c_alsa.snd_ctl_elem_info(ctl, elem_info) != 0) continue;
//
//        const iface = c_alsa.snd_ctl_elem_info_get_interface(elem_info);
//        if (iface == c_alsa.SND_CTL_ELEM_IFACE_MIXER) {
//            const name = c_alsa.snd_ctl_elem_info_get_name(elem_info);
//            const numid = c_alsa.snd_ctl_elem_info_get_numid(elem_info);
//            const device = c_alsa.snd_ctl_elem_info_get_device(elem_info);
//            const subdevice = c_alsa.snd_ctl_elem_info_get_subdevice(elem_info);
//
//            std.debug.print("Mixer Info: {s} (NumID: {d}, Device: {d}, Subdevice: {d})\n", .{ name, numid, device, subdevice });
//        }
//    }
//}

//test "another mixer test" {
//    var mixer: ?*c_alsa.snd_mixer_t = null;
//    if (c_alsa.snd_mixer_open(&mixer, 0) != 0) {
//        std.debug.print("❌ Failed to open mixer\n", .{});
//        return;
//    }
//    defer {
//        _ = c_alsa.snd_mixer_close(mixer);
//    }
//
//    // Attach to the correct card
//    const card_name = "hw:3";
//    if (c_alsa.snd_mixer_attach(mixer, card_name) != 0) {
//        std.debug.print("❌ Failed to attach mixer to {s}\n", .{card_name});
//        return;
//    }
//
//    // Register and load mixer elements
//    if (c_alsa.snd_mixer_selem_register(mixer, null, null) != 0 or
//        c_alsa.snd_mixer_load(mixer) != 0)
//    {
//        std.debug.print("❌ Failed to initialize mixer\n", .{});
//        return;
//    }
//
//    var elem: ?*c_alsa.snd_mixer_elem_t = c_alsa.snd_mixer_first_elem(mixer);
//    while (elem != null) {
//        // Get the name of the control (same as alsamixer)
//        const name = c_alsa.snd_mixer_selem_get_name(elem);
//        std.debug.print("🎛️ Mixer Element: {s}\n", .{name});
//
//        // Check if it's a playback or capture control
//        if (c_alsa.snd_mixer_selem_has_playback_volume(elem) != 0) {
//            std.debug.print("   ↳ Playback Volume Control\n", .{});
//            // Check available channels
//            for (0..8) |ch| {
//                if (c_alsa.snd_mixer_selem_has_playback_channel(elem, @intCast(ch)) != 0) {
//                    std.debug.print("   🎧 Playback Channel {d}\n", .{ch});
//                }
//            }
//        }
//        if (c_alsa.snd_mixer_selem_has_capture_volume(elem) != 0) {
//            std.debug.print("   ↳ Capture Volume Control\n", .{});
//
//            for (0..8) |ch| {
//                if (c_alsa.snd_mixer_selem_has_capture_channel(elem, @intCast(ch)) != 0) {
//                    std.debug.print("   🎤 Capture Channel {d}\n", .{ch});
//                }
//            }
//        }
//
//        // Move to the next mixer element
//        elem = c_alsa.snd_mixer_elem_next(elem);
//    }
//}
