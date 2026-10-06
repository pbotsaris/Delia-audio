const std = @import("std");

const c_alsa = @cImport({
    @cInclude("asoundlib.h");
});

const settings = @import("settings.zig");
const FormatType = settings.FormatType;
const StreamType = settings.StreamType;
const Channels = settings.ChannelCount;
const AccessType = settings.AccessType;

const SampleRate = @import("../../../common/audio_specs.zig").SampleRate;

const log = std.log.scoped(.alsa);
const SupportedSettings = @This();

formats: std.ArrayList(FormatType),
sample_rates: std.ArrayList(SampleRate),
channel_counts: std.ArrayList(Channels),
access_types: std.ArrayList(settings.AccessType),
sample_rate_min: u32,
sample_rate_max: u32,

pub fn init(allocator: std.mem.Allocator, hw_identifier: [:0]const u8, stream_type: StreamType) ?SupportedSettings {
    var params: ?*c_alsa.snd_pcm_hw_params_t = null;
    var pcm_handle: ?*c_alsa.snd_pcm_t = null;

    var err = c_alsa.snd_pcm_hw_params_malloc(&params);
    defer c_alsa.snd_pcm_hw_params_free(params);

    if (err < 0) {
        log.err("Could not get supported formats. Malloc Fialed: {s}", .{c_alsa.snd_strerror(err)});
        return null;
    }

    err = c_alsa.snd_pcm_open(&pcm_handle, hw_identifier, @intFromEnum(stream_type), 0);

    defer {
        if (pcm_handle != null and c_alsa.snd_pcm_close(pcm_handle) < 0) {
            log.warn("SupportedFormats: Failed to close PCM for StreamType {s}", .{@tagName(stream_type)});
        }
    }

    if (err < 0) {
        log.err("Could not get supported formats. Failed to open Stream type {s}: {s}", .{ @tagName(stream_type), c_alsa.snd_strerror(err) });
        return null;
    }

    err = c_alsa.snd_pcm_hw_params_any(pcm_handle, params);

    if (err < 0) {
        log.err("Could not get supported formats. Failed init harware params: {s}", .{c_alsa.snd_strerror(err)});
        return null;
    }

    var supported_formats: std.ArrayList(FormatType) = .empty;
    var supported_sample_rates: std.ArrayList(SampleRate) = .empty;
    var supported_channels_counts: std.ArrayList(Channels) = .empty;
    var access_types: std.ArrayList(settings.AccessType) = .empty;

    for (settings.formats) |f| {
        if (f < 0) continue; // skip FormatType.unknown
        if (c_alsa.snd_pcm_hw_params_test_format(pcm_handle, params, f) >= 0) {
            supported_formats.append(allocator, @enumFromInt(f)) catch {
                log.warn("Could not append format {d}", .{f});
            };
        }
    }

    for (settings.sample_rates) |sr| {
        if (c_alsa.snd_pcm_hw_params_test_rate(pcm_handle, params, sr, 0) >= 0) {
            supported_sample_rates.append(allocator, @enumFromInt(sr)) catch {
                const sr_tag = @tagName(@as(SampleRate, @enumFromInt(sr)));
                log.warn("SupportedSettings: Could not append sample rate settings {s}", .{sr_tag});
            };
        }
    }

    for (settings.channel_counts) |c| {
        if (c_alsa.snd_pcm_hw_params_test_channels(pcm_handle, params, c) >= 0) {
            supported_channels_counts.append(allocator, @enumFromInt(c)) catch {
                const c_tag = @tagName(@as(Channels, @enumFromInt(c)));
                log.warn("SupportedSettings: Could not append channel settings {s}", .{c_tag});
            };
        }
    }

    for (settings.access_types) |a| {
        if (c_alsa.snd_pcm_hw_params_test_access(pcm_handle, params, a) >= 0) {
            access_types.append(allocator, @enumFromInt(a)) catch {
                const a_tag = @tagName(@as(settings.AccessType, @enumFromInt(a)));
                log.warn("SupportedSettings: Could not append access type settings {s}", .{a_tag});
            };
        }
    }

    var rate_min: u32 = 0;

    err = c_alsa.snd_pcm_hw_params_get_rate_min(params, &rate_min, 0);

    if (err < 0) {
        log.warn("Could not get min sample rate: {s}", .{c_alsa.snd_strerror(err)});
    }

    var rate_max: u32 = 0;

    err = c_alsa.snd_pcm_hw_params_get_rate_max(params, &rate_max, 0);

    if (err < 0) {
        log.warn("Could not get max sample rate: {s}", .{c_alsa.snd_strerror(err)});
    }

    return .{
        .formats = supported_formats,
        .sample_rates = supported_sample_rates,
        .channel_counts = supported_channels_counts,
        .access_types = access_types,
        .sample_rate_min = rate_min,
        .sample_rate_max = rate_max,
    };
}

pub fn default(self: SupportedSettings, SettingType: type) ?SettingType {
    switch (SettingType) {
        SampleRate => {
            if (self.sample_rates.items.len == 0) return null;

            return self.sample_rates.items[0];
        },
        FormatType => {
            if (self.formats.items.len == 0) return null;
            return self.formats.items[0];
        },
        Channels => {
            if (self.channel_counts.items.len == 0) return null;
            return self.channel_counts.items[0];
        },
        AccessType => {
            // we prefer mmap interleaved
            for (self.access_types.items) |a| {
                if (a == AccessType.mmap_interleaved) return a;
                if (a == AccessType.mmap_noninterleaved) return a;
            }

            if (self.access_types.items.len == 0) return null;

            return self.access_types.items[0];
        },
        else => unreachable,
    }
}

pub fn format(self: SupportedSettings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const default_access = self.default(AccessType);

    try writer.print("  │    │     ├──  Supported Settings: \n", .{});
    try writer.print("  │    │     │     Formats({d}):\n", .{self.formats.items.len});
    for (0.., self.formats.items) |i, f| {
        if (i == 0) {
            try writer.print("  │    │     │    - {s} (default)\n", .{@tagName(f)});
        } else try writer.print("  │    │     │    - {s}\n", .{@tagName(f)});
    }

    try writer.print("  │    │     ├── Sample Rates({d}):\n", .{self.sample_rates.items.len});
    try writer.print("  │    │     ├ * min: {d} | max: {d}\n", .{ self.sample_rate_min, self.sample_rate_max });
    for (0.., self.sample_rates.items) |i, sr| {
        if (i == 0) {
            try writer.print("  │    │     │    - {d}hz (default)\n", .{@intFromEnum(sr)});
        } else try writer.print("  │    │     │    - {d}hz\n", .{@intFromEnum(sr)});
    }

    try writer.print("  │    │     ├── Channel Count({d}):\n", .{self.channel_counts.items.len});
    for (0.., self.channel_counts.items) |i, c| {
        if (i == 0) {
            try writer.print("  │    │     │     - {s}: {d} (default)\n", .{ @tagName(c), @intFromEnum(c) });
        } else try writer.print("  │    │     │     - {s}: {d}\n", .{ @tagName(c), @intFromEnum(c) });
    }

    try writer.print("  │    │     ├── Access Type({d}):\n", .{self.access_types.items.len});
    for (self.access_types.items) |a| {
        if (a == default_access) {
            try writer.print("  │    │     │     - {s} (default)\n", .{@tagName(a)});
        } else try writer.print("  │    │     │     - {s}\n", .{@tagName(a)});
    }

    try writer.print("  │    │     └──\n", .{});
}

pub fn deinit(self: *SupportedSettings, allocator: std.mem.Allocator) void {
    self.formats.deinit(allocator);
    self.sample_rates.deinit(allocator);
    self.channel_counts.deinit(allocator);
    self.access_types.deinit(allocator);
}
