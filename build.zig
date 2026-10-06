const std = @import("std");

/// ALSA is vendored as a git submodule and linked statically.
/// On first build, `configure && make` run inside `vendor/alsa` to produce `libasound.a`.

const Alsa = struct {
    const src_dir = "vendor/alsa";
    const lib_path = "src/.libs/libasound.a";
    const include_dir = "include";

    fn install(b: *std.Build) void {
        const project_root = b.build_root.path.?;
        const rel_lib_path = b.pathJoin(&.{ src_dir, lib_path });

        b.build_root.handle.access(b.graph.io, rel_lib_path, .{}) catch {
            const build_alsa = b.step("build-alsa", "Build the vendored ALSA library");

            const config_cmd = b.addSystemCommand(&.{
                b.pathJoin(&.{ project_root, src_dir, "configure" }),
                "--enable-shared=no",
                "--enable-static=yes",
                "--prefix",
                b.pathJoin(&.{ project_root, src_dir }),
            });

            build_alsa.dependOn(&config_cmd.step);

            const make_cmd = b.addSystemCommand(&.{ "make", "-C", b.pathJoin(&.{ project_root, src_dir }) });
            build_alsa.dependOn(&make_cmd.step);

            b.getInstallStep().dependOn(&make_cmd.step);
        };
    }

    fn link(b: *std.Build, mod: *std.Build.Module) void {
        mod.addIncludePath(b.path(b.pathJoin(&.{ src_dir, include_dir })));
        mod.addObjectFile(b.path(b.pathJoin(&.{ src_dir, lib_path })));
        mod.link_libc = true;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    Alsa.install(b);

    ////////////////////////// MODULES ///////////////////////////////////////////
    // One named module per subsystem so files import `@import("buffer")` rather than
    // `@import("../../core/buffer/root.zig")`. A file belongs to exactly one module and a
    // module may only import files below its root, so the imports below are the real
    // dependency graph: a cycle or a missing edge fails at compile time.
    //
    // The test runner only collects `test` blocks from the files of the module it was
    // given, so every module is also its own test root (see TESTS below).

    const Named = struct { name: []const u8, mod: *std.Build.Module };

    const buffer = b.createModule(.{
        .root_source_file = b.path("src/core/buffer/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const common = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dsp = b.createModule(.{
        .root_source_file = b.path("src/dsp/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsp.addImport("common", common);

    const graph = b.createModule(.{
        .root_source_file = b.path("src/graph/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    graph.addImport("buffer", buffer);
    graph.addImport("common", common);

    const alsa = b.createModule(.{
        .root_source_file = b.path("src/backends/alsa/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    alsa.addImport("buffer", buffer);
    Alsa.link(b, alsa);

    const backends = b.createModule(.{
        .root_source_file = b.path("src/backends/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    backends.addImport("alsa", alsa);

    // Frozen until M4; wired only so the tree keeps building.
    const legacy_graph = b.createModule(.{
        .root_source_file = b.path("src/legacy/graph/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    legacy_graph.addImport("common", common);
    legacy_graph.addImport("dsp", dsp);

    const legacy_backends = b.createModule(.{
        .root_source_file = b.path("src/legacy/backends/backends.zig"),
        .target = target,
        .optimize = optimize,
    });
    legacy_backends.addImport("common", common);
    legacy_backends.addImport("utils", utils);
    legacy_backends.addImport("dsp", dsp);
    Alsa.link(b, legacy_backends);

    // One root module shared by the executable, the compile-only check, and the tests.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const modules = [_]Named{
        .{ .name = "buffer", .mod = buffer },
        .{ .name = "utils", .mod = utils },
        .{ .name = "common", .mod = common },
        .{ .name = "dsp", .mod = dsp },
        .{ .name = "graph", .mod = graph },
        .{ .name = "alsa", .mod = alsa },
        .{ .name = "backends", .mod = backends },
        .{ .name = "legacy_graph", .mod = legacy_graph },
        .{ .name = "legacy_backends", .mod = legacy_backends },
    };

    for (modules) |m| root.addImport(m.name, m.mod);

    ////////////////////////// BUILD / RUN ///////////////////////////////////////
    const exe = b.addExecutable(.{

        .name = "delia",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    ////////////////////////// CHECK (zls build-on-save) /////////////////////////

    const exe_check = b.addExecutable(.{
        .name = "delia_check",
        .root_module = root,
    });

    const check = b.step("check", "Check if the app compiles");
    check.dependOn(&exe_check.step);

    ////////////////////////// TESTS /////////////////////////////////////////////

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains this string (repeatable)",
    ) orelse &.{};

    const test_step = b.step("test", "Run unit tests");

    // One test binary per module, root included; the runner would otherwise only see
    // tests in main.zig's own files.
    const test_roots = modules ++ [_]Named{.{ .name = "root", .mod = root }};

    for (test_roots) |m| {
        const unit_tests = b.addTest(.{
            .name = b.fmt("test_{s}", .{m.name}),
            .root_module = m.mod,
            .filters = test_filters,
        });

        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    ////////////////////////// BENCHMARKS ////////////////////////////////////////

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zbench = b.dependency("zbench", .{ .target = target, .optimize = optimize });
    bench_mod.addImport("zbench", zbench.module("zbench"));
    bench_mod.addImport("dsp", dsp);

    const exe_bench = b.addExecutable(.{
        .name = "delia_bench",
        .root_module = bench_mod,
    });

    const bench_run_cmd = b.addRunArtifact(exe_bench);
    const bench_step = b.step("bench", "Run the benchmarks");
    bench_step.dependOn(&bench_run_cmd.step);
}
