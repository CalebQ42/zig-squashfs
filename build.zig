const std = @import("std");

pub fn build(b: *std.Build) !void {
    const use_c_libs_option = b.option(bool, "use_c_libs", "Use C versions of decompression libraries instead of the Zig standard library ones");
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary");

    const zig_squashfs_options = b.addOptions();
    zig_squashfs_options.addOption(bool, "use_c_libs", use_c_libs_option orelse false);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const mod = b.addModule("zig_squashfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (use_c_libs_option == true) true else false,
    });
    mod.addOptions("config", zig_squashfs_options);
    if (use_c_libs_option == true) {
        mod.linkSystemLibrary("zlib", .{});
        mod.linkSystemLibrary("lzma", .{});
        mod.linkSystemLibrary("minilzo", .{});
        mod.linkSystemLibrary("lz4", .{});
        mod.linkSystemLibrary("zstd", .{});
    }

    const unsquashfs_options = b.addOptions();
    unsquashfs_options.addOption(std.SemanticVersion, "version", try std.SemanticVersion.parse(version_string_option orelse "0.0.0-testing"));

    var exe_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/unsquashfs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (use_c_libs_option == true) true else false,
        .imports = &.{
            .{ .name = "zig_squashfs", .module = mod },
        },
    });
    exe_mod.addOptions("config", unsquashfs_options);
    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = exe_mod,
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
