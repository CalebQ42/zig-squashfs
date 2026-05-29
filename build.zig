const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) !void {
    const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use zig standard library for decompression.") orelse false;
    const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo decompression support.") orelse false;
    const dynamic = b.option(bool, "dynamic", "Dynamic link C decompression libraries.") orelse false;
    const debug = b.option(bool, "debug", "Enable options to make debugging easier.") orelse false;
    const version_string = b.option([]const u8, "version", "Version of the library/binary") orelse "0.0.0-testing";

    const version: std.SemanticVersion = try .parse(version_string);

    const zig_squashfs_options = b.addOptions();
    zig_squashfs_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    zig_squashfs_options.addOption(bool, "allow_lzo", allow_lzo);

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/c.h"),
    });
    if (allow_lzo)
        c.defineCMacro("ALLOW_LZO", null);
    if (dynamic) {
        c.linkSystemLibrary("z", .{});
        c.linkSystemLibrary("lzma", .{});
        c.linkSystemLibrary("lz4", .{});
        c.linkSystemLibrary("zstd", .{});
        if (allow_lzo)
            c.linkSystemLibrary("minilzo", .{});
    }

    const deps = try getDependencies(b, optimize, target, allow_lzo);

    const lib = b.addLibrary(.{
        .name = "squashfs",
        .use_llvm = debug,
        .version = version,
        .root_module = b.createModule(.{
            .imports = &.{
                .{ .name = "options", .module = zig_squashfs_options.createModule() },
                .{ .name = "c", .module = c.createModule() },
            },
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/root.zig"),
            .valgrind = debug,
        }),
    });

    for (deps) |d|
        lib.root_module.linkLibrary(d);

    b.installArtifact(lib);

    const exe_config = b.addOptions();
    exe_config.addOption(std.SemanticVersion,"version", version);

    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .use_llvm = debug,
        .version = version,
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/bin/unsquashfs.zig"),
            .valgrind = debug,
            .imports = &.{
                .{ .name = "config", .module = exe_config.createModule() },
                .{ .name = "squashfs", .module = lib.root_module }
            },
        }),
    });

    b.installArtifact(exe);

    const lib_test = b.addTest(.{
        .name = "squashfs-test",
        .root_module = lib.root_module,
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&lib_test.step);

    // zls check step
    const lib_check = b.addLibrary(.{
        .name = "squashfs-check",
        .root_module = lib.root_module,
    });
    const exe_check = b.addLibrary(.{
        .name = "unsquashfs-check",
        .root_module = exe.root_module,
    });

    const check = b.step("check", "Check if squashfs compiles");
    check.dependOn(&lib_check.step);
    check.dependOn(&exe_check.step);
}

fn getDependencies(b: *Build, optimize: std.builtin.OptimizeMode, target: Build.ResolvedTarget, allow_lzo: bool) ![]*Build.Step.Compile {
    const alloc = b.allocator;

    var list: std.ArrayList(*Build.Step.Compile) = .empty;

    const zlib_ng = b.dependency("zlib_ng", .{ .optimize = optimize, .target = target });
    try list.append(alloc, zlib_ng.artifact("zng"));

    const xz = b.dependency("xz", .{ .optimize = optimize, .target = target });
    try list.append(alloc, xz.artifact("lzma"));

    const lz4 = b.dependency("lz4", .{ .optimize = optimize, .target = target });
    try list.append(alloc, lz4.artifact("lz4"));

    const zstd = b.dependency("zstd", .{ .optimize = optimize, .target = target });
    try list.append(alloc, zstd.artifact("zstd"));

    if (allow_lzo) {
        const minilzo = b.dependency("minilzo", .{ .optimize = optimize, .target = target });
        try list.append(alloc, minilzo.artifact("minilzo"));
    }

    return list.toOwnedSlice(b.allocator);
}
