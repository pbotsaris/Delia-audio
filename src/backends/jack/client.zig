const std = @import("std");

const c_jack = @cImport({
    @cInclude("jack/jack.h");
});

const c_str = @cImport({
    @cInclude("string.h");
});

const log = std.log.scoped(.jack);
const Hardware = @import("Hardware.zig");
const port_names = @import("port_names.zig");
const audio_data = @import("audio_data.zig");

// jack defaults to float32
const audio_type = c_jack.JACK_DEFAULT_AUDIO_TYPE;
const AudioData = audio_data.AudioData(f32);

pub const PortType = enum(c_int) {
    playback = c_jack.JackPortIsOutput,
    capture = c_jack.JackPortIsInput,

    pub fn toFlag(self: PortType) c_ulong {
        return @as(c_ulong, @intCast(@intFromEnum(self)));
    }
};

// logs jack errors
fn jackErrorCallback(c_msg: [*c]const u8) callconv(.C) void {
    const msg = std.mem.span(c_msg);
    std.log.err("JACK: {s}", .{msg});
}

fn jackInfoCallback(c_msg: [*c]const u8) callconv(.C) void {
    const msg = std.mem.span(c_msg);
    std.log.info("JACK: {s}", .{msg});
}

const null_init = [_]?*c_jack.jack_port_t{null} ** (port_names.max_n_ports);

pub fn JackClient(comptime Context: type, comptime comptime_opts: JackComptimeOptions) type {
    checkCallback(Context, comptime_opts.duplex_mode);

    //c_jack.jack_set_error_function

    return struct {
        const Self = @This();

        pub const PortHandler = struct {
            name: []const u8,
            port: ?*c_jack.jack_port_t,
            port_type: PortType,
            client: *JackClient(Context, comptime_opts),

            pub fn connect(self: PortHandler, hardware_port: Hardware.JackHardwarePort) !void {
                if (hardware_port.type != self.port_type) {
                    log.err("Port type mismatch {s} -> {s}:  tried to connect {s} to {s}", .{
                        self.name,
                        hardware_port.name,
                        @tagName(self.port_type),
                        @tagName(hardware_port.type),
                    });
                    return;
                }

                const port_name = c_jack.jack_port_name(self.port);
                const hardware_port_name = c_jack.jack_port_name(hardware_port.ptr);

                const err = switch (self.port_type) {
                    .capture => c_jack.jack_connect(self.client.client, hardware_port_name, port_name),
                    .playback => c_jack.jack_connect(self.client.client, port_name, hardware_port_name),
                };

                if (err != 0) {
                    switch (self.port_type) {
                        .capture => log.err("Failed to connect {s} -> {s}", .{ port_name, hardware_port_name }),
                        .playback => log.err("Failed to connect {s} -> {s}", .{ hardware_port_name, port_name }),
                    }

                    log.err("Reason: {s}", .{c_str.strerror(err)});
                    return JackClientError.failed_connect_port;
                }

                switch (self.port_type) {
                    .capture => log.info("Connected Capture:    {s} -> {s}", .{ port_name, hardware_port_name }),
                    .playback => log.info("Connected Playback:  {s} -> {s}", .{ hardware_port_name, port_name }),
                }
            }
        };

        client_name: []const u8,
        client: *c_jack.jack_client_t,
        server_name: ?[]const u8,
        allocator: std.mem.Allocator,
        hardware: Hardware,

        playbacks: [port_names.max_n_ports]?*c_jack.jack_port_t = null_init,
        n_playbacks: usize = 0,
        captures: [port_names.max_n_ports]?*c_jack.jack_port_t = null_init,
        n_captures: usize = 0,

        on_shutdown: ?*fn (arg: ?*anyopaque) void = null,
        // working on setting the callback for jack
        context: *Context,

        //   connectedPorts: [port_names.max_n_ports * 2]?*c_jack.jack_port_t = null_init,

        pub fn init(allocator: std.mem.Allocator, context: *Context, opts: JackClientOptions) !Self {
            // setting jack logs first
            switch (comptime_opts.log_level) {
                JackLogLevel.none => {},
                JackLogLevel.err => c_jack.jack_set_error_function(&jackErrorCallback),
                JackLogLevel.info => {
                    c_jack.jack_set_info_function(&jackErrorCallback);
                    c_jack.jack_set_error_function(&jackErrorCallback);
                },
            }

            if (opts.client_name.len >= c_jack.jack_client_name_size()) {
                return JackClientError.client_name_too_long;
            }

            var jack_options = opts.jack_options;

            if (opts.server_name != null and !opts.jack_options.contains(.server_name)) {
                // we add the option if caller provided a server name but didn't set the option
                jack_options = opts.jack_options.merge(.server_name);
            }

            var open_status: c_jack.jack_status_t = undefined;

            const maybe_client = c_jack.jack_client_open(
                opts.client_name.ptr,
                jack_options.toInt(),
                &open_status,
                if (opts.server_name != null) opts.server_name.?.ptr else null,
            );

            const client = maybe_client orelse {
                if ((open_status & c_jack.JackServerFailed) != 0) {
                    std.log.err("JACK server failed to start", .{});
                    return JackClientError.failed_start_server;
                }

                return JackClientError.failed_open_client;
            };

            if ((open_status & c_jack.JackServerStarted) != 0) {
                std.log.info("JACK server was stopped. Starting server...", .{});
            }

            var maybe_new_name: ?[]const u8 = null;

            if ((open_status & c_jack.JackNameNotUnique) != 0) {
                const new_name = c_jack.jack_get_client_name(maybe_client);
                std.log.warn("Client name: {s} not unique. New name generated and assigned: {s}", .{ opts.client_name, new_name });
                maybe_new_name = std.mem.span(new_name);
            }

            var err = c_jack.jack_set_process_callback(client, &Self.processCallback, null);

            if (err != 0) {
                log.err("Failed to set process callback: {d}", .{err});
                return JackClientError.failed_set_callback;
            }

            err = c_jack.jack_activate(client);

            if (err != 0) {
                log.err("Failed to activate JACK client: {d}", .{err});
                return JackClientError.failed_activate_client;
            }

            return .{
                .client_name = maybe_new_name orelse opts.client_name,
                .server_name = opts.server_name,
                .client = client,
                .allocator = allocator,
                .hardware = try Hardware.init(allocator, client),
                .context = context,
            };
        }

        pub fn registerPortFor(self: *Self, hardware_port: Hardware.JackHardwarePort) !PortHandler {
            return self.registerPort(hardware_port.type);
        }

        pub fn registerPort(self: *Self, port_type: PortType) !PortHandler {
            if (port_names.maxReached(self.n_playbacks)) {
                log.err("Max number of playbacks reached: {d} >= {d}", .{ self.n_playbacks, port_names.max_n_ports });

                return JackClientError.max_ports_reached;
            }

            if (port_names.maxReached(self.n_captures)) {
                log.err("Max number of captures reached: {d} >= {d}", .{ self.n_captures, port_names.max_n_ports });

                return JackClientError.max_ports_reached;
            }

            const port_name = switch (port_type) {
                PortType.playback => port_names.playback[self.n_playbacks],
                PortType.capture => port_names.capture[self.n_captures],
            };

            const maybe_port = c_jack.jack_port_register(self.client, port_name.ptr, audio_type, port_type.toFlag(), 0);

            const port = maybe_port orelse {
                log.err("Failed to register port: {s}", .{port_name});
                return JackClientError.failed_register_port;
            };

            switch (port_type) {
                PortType.playback => {
                    self.playbacks[self.n_playbacks] = port;
                    self.n_playbacks += 1;
                },

                PortType.capture => {
                    self.captures[self.n_captures] = port;
                    self.n_captures += 1;
                },
            }

            return .{
                .name = port_name,
                .port = port,
                .client = self,
                .port_type = port_type,
            };
        }

        pub fn deinit(self: Self) void {
            for (self.captures) |maybe_port| {
                const port = maybe_port orelse continue;
                const err = c_jack.jack_port_unregister(self.client, port);

                if (err != 0) {
                    std.log.err("Failed to unregister port: {d}", .{err});
                }
            }

            for (self.playbacks) |maybe_port| {
                const port = maybe_port orelse continue;
                const err = c_jack.jack_port_unregister(self.client, port);

                if (err != 0) {
                    std.log.err("Failed to unregister port: {d}", .{err});
                }
            }

            const err = c_jack.jack_client_close(self.client);

            if (err != 0) {
                std.log.err("Failed to close JACK client: {d}", .{err});
            }
        }

        fn processCallback(n_frames: c_jack.jack_nframes_t, arg: ?*anyopaque) callconv(.C) c_int {
            _ = n_frames;
            _ = arg;

            return 0;
        }
    };
}

pub const JackOpenOptions = struct {
    flags: c_uint,

    pub const Flag = enum(c_uint) {
        /// Default value when no options are needed
        no_options = c_jack.JackNullOption,
        /// Do not automatically start the JACK server when it is not already running.
        /// This option is always selected if $JACK_NO_START_SERVER is defined in the
        /// calling process environment.
        no_start_server = c_jack.JackNoStartServer,
        /// Use the exact client name requested. Otherwise, JACK automatically
        /// generates a unique one if needed.
        use_exact_name = c_jack.JackUseExactName,
        /// Open with optional (char*)server_name parameter
        server_name = c_jack.JackServerName,
        /// Pass a SessionID Token that allows the session manager to
        /// identify the client again.
        session_id = c_jack.JackSessionID,
    };

    pub fn init(flag: Flag) JackOpenOptions {
        return .{ .flags = @intFromEnum(flag) };
    }

    pub fn initEmpty() JackOpenOptions {
        return .{ .flags = 0 };
    }

    pub fn merge(self: JackOpenOptions, other: Flag) JackOpenOptions {
        return .{ .flags = self.flags | @intFromEnum(other) };
    }

    pub fn contains(self: JackOpenOptions, flag: Flag) bool {
        return (self.flags & @intFromEnum(flag)) != 0;
    }

    pub fn toInt(self: JackOpenOptions) c_uint {
        return self.flags;
    }
};

fn checkCallback(comptime T: type, comptime duplex_mode: DuplexMode) void {
    const has_callback = @hasDecl(T, "callback");

    if (!has_callback) {
        @compileError("Callback not found in type");
    }

    const has_args = switch (duplex_mode) {
        .half_duplex => @TypeOf(T.callback) == fn (*T, AudioData) void,
        .full_duplex => @TypeOf(T.callback) == fn (*T, AudioData, AudioData) void,
    };

    if (!has_args and duplex_mode == DuplexMode.half_duplex) {
        @compileError("Jack Half Duplex Callback must have the following signature: fn(*T, *AudioData) void");
    }

    if (!has_args and duplex_mode == DuplexMode.full_duplex) {
        @compileError("Jack Full Duplex Callback must have the following signature: fn(*T, *AudioData, *AudioData) void");
    }
}

const DuplexMode = enum {
    half_duplex,
    full_duplex,
};

const JackClientOptions = struct {
    client_name: []const u8 = "device",
    server_name: ?[]const u8 = null,
    jack_options: JackOpenOptions = JackOpenOptions.initEmpty(),
};

const JackLogLevel = enum {
    none,
    err,
    info,
};

const JackComptimeOptions = struct {
    duplex_mode: DuplexMode = DuplexMode.full_duplex,
    log_level: JackLogLevel = JackLogLevel.none,
};

const JackClientError = error{
    client_name_too_long,
    failed_open_client,
    failed_start_server,
    failed_set_callback,
    failed_activate_client,
    max_ports_reached,
    failed_register_port,
    failed_connect_port,
};
