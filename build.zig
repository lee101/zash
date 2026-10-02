const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this text");

    const lib_mod = b.addModule("zash", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zash",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zash", .module = lib_mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run zash");
    run_step.dependOn(&run_cmd.step);

    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const lib_tests = b.addTest(.{ .root_module = lib_mod, .filters = filters });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all inline tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
