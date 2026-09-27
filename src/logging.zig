const std = @import("std");
const ANSI = @import("ansi.zig");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
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

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(color ++ prefix ++ format ++ ANSI.reset ++ "\n", args) catch return;
}
