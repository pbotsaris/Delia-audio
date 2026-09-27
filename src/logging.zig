const std = @import("std");
const ANSI = @import("ansi.zig");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = ANSI.logColor(level);

    const scope_prefix = "(" ++ switch (scope) {
        .main,
        .alsa,
        .dsp,
        .graph,
        std.log.default_log_scope,
        => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,
    } ++ "):  ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print(color ++ prefix ++ format ++ ANSI.reset ++ "\n", args) catch return;
}
