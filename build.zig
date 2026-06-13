const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use zig standard library for decompression.") orelse false;
    const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support") orelse false;
    const dynamic = b.option(bool, "dynamic", "Use dynamic instead of static linking.") orelse false;
    const debug = b.option(bool, "debug", "Enable options to make debugging easier.") orelse false;
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary") orelse "0.0.0-testing";

    const version: std.SemanticVersion = try .parse(version_string_option);

    const build_options = b.addOptions();
    build_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    build_options.addOption(bool, "allow_lzo", allow_lzo);
    build_options.addOption(std.SemanticVersion, "version", version);

    const c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("c.h"),
    });
    if (allow_lzo) c.defineCMacro("ALLOW_LZO", null);

    if (!use_zig_decomp and dynamic) {
        c.linkSystemLibrary("z", .{});
        c.linkSystemLibrary("lzma", .{});
        c.linkSystemLibrary("lz4", .{});
        c.linkSystemLibrary("zstd", .{});
        if (allow_lzo)
            c.linkSystemLibrary("minilzo", .{});
    }

    const lib = b.addLibrary(.{
        .name = "squashfs",
        .use_llvm = debug,
        .version = version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .optimize = optimize,
            .target = target,
            .valgrind = debug,
            .imports = &.{
                .{ .name = "c", .module = c.createModule() },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    if (!use_zig_decomp and !dynamic) {
        const zng = b.dependency("zlib_ng", .{ .optimize = optimize, .target = target, .zlib_compat = true });
        lib.root_module.linkLibrary(zng.artifact("zng"));

        const zstd = b.dependency("zstd", .{ .optimize = optimize, .target = target });
        lib.root_module.linkLibrary(zstd.artifact("zstd"));

        const lz4 = b.dependency("lz4", .{ .optimize = optimize, .target = target });
        lib.root_module.linkLibrary(lz4.artifact("lz4"));

        const xz = b.dependency("xz", .{ .optimize = optimize, .target = target });
        lib.root_module.linkLibrary(xz.artifact("lzma"));

        if (allow_lzo) {
            const lzo = b.dependency("minilzo", .{ .optimize = optimize, .target = target });
            lib.root_module.linkLibrary(lzo.artifact("minilzo"));
        }
    }

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .use_llvm = debug,
        .version = version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/unsquashfs.zig"),
            .optimize = optimize,
            .target = target,
            .valgrind = debug,
            .imports = &.{
                .{ .name = "squashfs", .module = lib.root_module },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

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
    });
    const exe_check = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = exe.root_module,
    });
    const check = b.step("check", "Check if unsquashfs compiles");
    check.dependOn(&lib_check.step);
    check.dependOn(&exe_check.step);
}
