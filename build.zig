const std = @import("std");

/// version if version isn't provided during build
const def_version = "0.0.0+testing";

pub fn build(b: *std.Build) !void {
    const opt = b.addOptions();
    const ver = b.option([]const u8, "version", "sematic version") orelse def_version;
    const sem_ver = try std.SemanticVersion.parse(ver);
    opt.addOption(std.SemanticVersion, "version", sem_ver);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_squashfs",
        .root_module = lib_mod,
        .version = sem_ver,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/zig_unsquashfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("config", opt);
    const exe = b.addExecutable(.{
        .linkage = .static,
        .name = "zig-unsquashfs",
        .root_module = exe_mod,
        .version = sem_ver,
    });

    b.installArtifact(lib);
    b.installArtifact(exe);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const exe_unit_test = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_test);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
