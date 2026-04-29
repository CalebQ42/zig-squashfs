const std = @import("std");

pub fn build(b: *std.Build) !void {
    // const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use zig standard library for decompression.") orelse false;
    // const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support") orelse false;
    const debug = b.option(bool, "debug", "Enable options to make debugging easier.");
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary");

    // const zig_squashfs_options = b.addOptions();
    // zig_squashfs_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    // zig_squashfs_options.addOption(bool, "allow_lzo", allow_lzo);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "squashfs",
        .root_module = b.createModule(.{
            .optimize = if (debug == true) .Debug else optimize,
            .target = target,
            .valgrind = debug,
            .root_source_file = b.path("src/root.zig"),
        }),
        .use_llvm = debug,
    });

    var version = version_string_option orelse "0.0.0-testing";
    if (version[0] == 'v') version = version[1..];
    const unsquashfs_options = b.addOptions();
    unsquashfs_options.addOption(
        std.SemanticVersion,
        "version",
        try std.SemanticVersion.parse(version),
    );
    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = b.createModule(.{
            .optimize = if (debug == true) .Debug else optimize,
            .target = target,
            .valgrind = debug,
            .root_source_file = b.path("src/bin/unsquashfs.zig"),
            .imports = &.{
                .{ .name = "zig_squashfs", .module = lib.root_module },
                .{ .name = "config", .module = unsquashfs_options.createModule() },
            },
        }),
        .use_llvm = debug,
    });

    b.installArtifact(lib);
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/root.zig"),
        }),
        .test_runner = .{
            .mode = .simple,
            .path = b.path("src/test.zig"),
        },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // zls build check steps
    const lib_check = b.addLibrary(.{
        .name = "squashfs",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/root.zig"),
        }),
    });
    // const exe_check = b.addExecutable(.{
    //     .name = "unsquashfs",
    //     .root_module = b.createModule(.{
    //         .optimize = optimize,
    //         .target = target,
    //         .root_source_file = b.path("src/bin/unsquashfs.zig"),
    //     }),
    // });
    const check = b.step("check", "Check if unsquashfs compiles");
    check.dependOn(&lib_check.step);
    // check.dependOn(&exe_check.step);
}
