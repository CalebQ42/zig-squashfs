const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *std.Build) !void {
    const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use zig standard library for decompression.") orelse false;
    const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support") orelse false;
    var debug = b.option(bool, "debug", "Enable options to make debugging easier.") orelse false;
    const dynamic = b.option(bool, "dynamic", "Use dynamic linking for C libraries (if used).") orelse false;
    var version_string = b.option([]const u8, "version", "Version of the library/binary") orelse "0.0.0-testing";

    const target = b.standardTargetOptions(.{});
    var optimize = b.standardOptimizeOption(.{});

    const zig_squashfs_options = b.addOptions();
    zig_squashfs_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    zig_squashfs_options.addOption(bool, "allow_lzo", allow_lzo);

    version_string = std.mem.trimStart(u8, version_string, "v");
    const version = try std.SemanticVersion.parse(version_string);
    const unsquashfs_options = b.addOptions();
    unsquashfs_options.addOption(
        std.SemanticVersion,
        "version",
        version,
    );

    if (debug) optimize = .Debug;
    if (optimize == .Debug) debug = true;

    const c_import = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (allow_lzo) c_import.defineCMacro("ALLOW_LZO", null);
    if (dynamic) {
        c_import.linkSystemLibrary("zlib-ng", .{});
        c_import.linkSystemLibrary("lzma", .{});
        if (allow_lzo)
            c_import.linkSystemLibrary("minilzo", .{});
        c_import.linkSystemLibrary("lz4", .{});
        c_import.linkSystemLibrary("zstd", .{});
    }

    var lib = b.addLibrary(.{
        .name = "squashfs",
        .root_module = b.addModule("squashfs", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .valgrind = debug,
            .error_tracing = debug,
            .strip = debug,
            .imports = &.{
                .{ .name = "config", .module = zig_squashfs_options.createModule() },
                .{ .name = "c", .module = c_import.createModule() },
            },
        }),
        .use_llvm = debug,
        .version = version,
    });

    const deps = try getDependencies(b, target, optimize, allow_lzo, dynamic);

    for (deps) |d|
        lib.root_module.linkLibrary(d);

    const exe = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/unsquashfs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config", .module = unsquashfs_options.createModule() },
                .{ .name = "squashfs", .module = lib.root_module },
            },
            .valgrind = debug,
            .error_tracing = debug,
            .strip = if (debug == true) false else null,
        }),
        .use_llvm = debug,
        .version = version,
    });

    b.installArtifact(lib);
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .valgrind = debug,
            .error_tracing = debug,
            .strip = debug,
            .imports = &.{
                .{ .name = "config", .module = zig_squashfs_options.createModule() },
                .{ .name = "c", .module = c_import.createModule() },
            },
        }),
        .use_llvm = true, // Helps with lldb degugging
        .test_runner = .{
            .mode = .simple,
            .path = b.path("src/test.zig"),
        },
    });

    for (deps) |d|
        mod_tests.root_module.linkLibrary(d);

    if (dynamic) {
        mod_tests.root_module.linkSystemLibrary("zlib-ng", .{});
        mod_tests.root_module.linkSystemLibrary("lzma", .{});
        mod_tests.root_module.linkSystemLibrary("minilzo", .{});
        mod_tests.root_module.linkSystemLibrary("lz4", .{});
    }

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

fn getDependencies(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, allow_lzo: bool, dynamic: bool) ![]*Step.Compile {
    if (dynamic) return &.{};

    var list: std.ArrayList(*Step.Compile) = .empty;
    errdefer list.clearAndFree(b.allocator);

    var zlib_ng = b.dependency("zlib_ng", .{
        .target = target,
        .optimize = optimize,
    });
    try list.append(b.allocator, zlib_ng.artifact("zng"));

    var xz = b.dependency("xz", .{
        .target = target,
        .optimize = optimize,
    });
    try list.append(b.allocator, xz.artifact("lzma"));

    if (allow_lzo) {
        var minilzo = b.dependency("minilzo", .{
            .target = target,
            .optimize = optimize,
        });
        try list.append(b.allocator, minilzo.artifact("minilzo"));
    }

    var lz4 = b.dependency("lz4", .{
        .target = target,
        .optimize = optimize,
    });
    try list.append(b.allocator, lz4.artifact("lz4"));

    var zstd = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
    });
    try list.append(b.allocator, zstd.artifact("zstd"));

    return list.toOwnedSlice(b.allocator);
}
