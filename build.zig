const std = @import("std");

pub fn build(b: *std.Build) !void {
    const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use zig standard library for decompression.") orelse false;
    // const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support") orelse false;
    const debug = b.option(bool, "debug", "Enable options to make debugging easier.") orelse false;
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary");

    const zig_squashfs_options = b.addOptions();
    zig_squashfs_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    // zig_squashfs_options.addOption(bool, "allow_lzo", allow_lzo);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zig_squashfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = if (debug == true) .Debug else optimize,
        .link_libc = !use_zig_decomp,
        .valgrind = debug,
        .error_tracing = debug,
        .strip = if (debug == true) false else null,
    });
    mod.addOptions("config", zig_squashfs_options);
    if (!use_zig_decomp) {
        var zlib_ng = b.dependency("zlib_ng", .{
            .target = target,
            .optimize = optimize,
        });
        mod.linkLibrary(zlib_ng.artifact("zng"));

        mod.linkSystemLibrary("lzma", .{ .preferred_link_mode = .static });

        var minilzo = b.dependency("minilzo", .{
            .target = target,
            .optimize = optimize,
        });
        mod.linkLibrary(minilzo.artifact("minilzo"));

        var lz4 = b.dependency("lz4", .{
            .target = target,
            .optimize = optimize,
        });
        mod.linkLibrary(lz4.artifact("lz4"));

        var zstd = b.dependency("zstd", .{
            .target = target,
            .optimize = optimize,
        });
        mod.linkLibrary(zstd.artifact("zstd"));
    }

    var version = version_string_option orelse "0.0.0-testing";
    if (version[0] == 'v') version = version[1..];
    const unsquashfs_options = b.addOptions();
    unsquashfs_options.addOption(
        std.SemanticVersion,
        "version",
        try std.SemanticVersion.parse(version),
    );

    var exe_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/unsquashfs.zig"),
        .target = target,
        .optimize = if (debug == true) .Debug else optimize,
        .link_libc = !use_zig_decomp,
        .imports = &.{
            .{ .name = "zig_squashfs", .module = mod },
        },
        .valgrind = debug,
        .error_tracing = debug,
        .strip = if (debug == true) false else null,
    });
    exe_mod.addOptions("config", unsquashfs_options);
    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = exe_mod,
        .use_llvm = debug,
    });

    const lib = b.addLibrary(.{
        .name = "squashfs",
        .root_module = mod,
        .use_llvm = debug,
    });

    b.installArtifact(lib);
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = mod,
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
        .root_module = mod,
    });
    const exe_check = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check if unsquashfs compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&lib_check.step);
}
