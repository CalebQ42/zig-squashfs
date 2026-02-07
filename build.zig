const std = @import("std");

pub fn build(b: *std.Build) void {
    const static = b.option(bool, "static_build", "Build static");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const linkage: std.builtin.LinkMode = .static; // TODO: Add argument to set link mode.
    const use_c_libs: bool = false;
    _ = use_c_libs;
    const mod = b.addModule("zig_squashfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .linkage = linkage,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/unsquashfs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_squashfs", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
