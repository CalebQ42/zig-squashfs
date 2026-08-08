const std = @import("std");

pub fn build(b: *std.Build) !void {
    const zig_decomp = b.option(bool, "zig_decomp", "Use zig standard library for decompression.") orelse false;
    const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support.") orelse false;
    const static = b.option(bool, "static", "Statically link libraries.") orelse false;
    const debug = b.option(bool, "debug", "Enable options to make debugging easier.") orelse false;
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary") orelse "0.0.0-testing";

    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = if (debug) .Debug else b.standardOptimizeOption(.{});

    const version: std.SemanticVersion = try .parse(if (version_string_option[0] == 'v') version_string_option[1..] else version_string_option);

    const build_config = b.addOptions();
    build_config.addOption(bool, "zig_decomp", zig_decomp);
    build_config.addOption(bool, "allow_lzo", allow_lzo);
    build_config.addOption(bool, "debug", debug);
    build_config.addOption(std.SemanticVersion, "version", version);

    const c_h = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/c.h"),
    });
    if (allow_lzo) c_h.defineCMacro("ALLOW_LZO", null);
    const c = c_h.createModule();

    if (static) {
        const zng = b.dependency("zlib_ng", .{
            .target = target,
            .optimize = optimize,
            .zlib_compat = true,
        });
        c.linkLibrary(zng.artifact("zng"));

        const zstd = b.dependency("zstd", .{ .optimize = optimize, .target = target });
        c.linkLibrary(zstd.artifact("zstd"));

        const lz4 = b.dependency("lz4", .{ .optimize = optimize, .target = target });
        c.linkLibrary(lz4.artifact("lz4"));

        const xz = b.dependency("xz", .{ .optimize = optimize, .target = target });
        c.linkLibrary(xz.artifact("lzma"));

        if (allow_lzo) {
            const lzo = b.dependency("minilzo", .{ .optimize = optimize, .target = target });
            c.linkLibrary(lzo.artifact("minilzo"));
        }
    } else {
        c.linkSystemLibrary("z", .{});
        c.linkSystemLibrary("zstd", .{});
        c.linkSystemLibrary("lz4", .{});
        c.linkSystemLibrary("lzma", .{});
        if (allow_lzo)
            c.linkSystemLibrary("minilzo", .{});
    }

    const lib = b.addLibrary(.{
        .name = "squashfs",
        .root_module = b.addModule("zig_squashfs", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .valgrind = debug,
            .imports = &.{
                .{ .name = "c", .module = c },
                .{ .name = "build_config", .module = build_config.createModule() },
            },
        }),
        .use_llvm = debug,
        .version = version,
    });

    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/unsquashfs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "squashfs", .module = lib.root_module },
                .{ .name = "build_config", .module = build_config.createModule() },
            },
            .valgrind = debug,
        }),
        .use_llvm = debug,
        .version = version,
    });

    b.installArtifact(lib);
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = lib.root_module,
        .use_llvm = debug,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // zls build check steps
    const lib_check = b.addLibrary(.{
        .name = "squashfs",
        .root_module = lib.root_module,
        .use_llvm = debug,
    });
    const exe_check = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = exe.root_module,
        .use_llvm = debug,
    });
    const check = b.step("check", "Check if unsquashfs compiles");
    check.dependOn(&lib_check.step);
    check.dependOn(&exe_check.step);
}
