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

    // One root module shared by the executable, the compile-only check, and the tests.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    Alsa.link(b, root);

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

    const unit_tests = b.addTest(.{
        .root_module = root,
        .filters = test_filters,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    ////////////////////////// BENCHMARKS ////////////////////////////////////////

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zbench = b.dependency("zbench", .{ .target = target, .optimize = optimize });
    bench_mod.addImport("zbench", zbench.module("zbench"));

    const exe_bench = b.addExecutable(.{
        .name = "delia_bench",
        .root_module = bench_mod,
    });

    const bench_run_cmd = b.addRunArtifact(exe_bench);
    const bench_step = b.step("bench", "Run the benchmarks");
    bench_step.dependOn(&bench_run_cmd.step);
}
