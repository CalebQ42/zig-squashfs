const std = @import("std");
const Compile = std.Build.Step.Compile;
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Module = std.Build.Module;

pub fn build(b: *std.Build) !void {
    const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use Zig standard library for decompression instead of C libraries.") orelse false;
    const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support") orelse false;
    const debug = b.option(bool, "debug", "Enable options to make debugging easier.");
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary");

    const zig_squashfs_options = b.addOptions();
    zig_squashfs_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    zig_squashfs_options.addOption(bool, "allow_lzo", allow_lzo);

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
        var zlib = b.dependency("zlib_ng", .{});
        mod.linkLibrary(zlib.artifact("zng"));

        mod.linkSystemLibrary("lzma", .{ .preferred_link_mode = .static });
        if (allow_lzo == true)
            mod.linkSystemLibrary("minilzo", .{ .preferred_link_mode = .static });
        mod.linkSystemLibrary("lz4", .{ .preferred_link_mode = .static });

        const zstd_lib = buildZstdLibrary(b, target, optimize, debug);
        mod.linkLibrary(zstd_lib);
        mod.addIncludePath(b.path("extern/zstd/lib/"));
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
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

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
    check.dependOn(&lib_check.step);
    check.dependOn(&exe_check.step);
}

fn buildZstdLibrary(b: *std.Build, target: ResolvedTarget, optimize: OptimizeMode, debug: ?bool) *Compile {
    var zstd_lib = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = if (debug == true) .Debug else optimize,
            .link_libc = true,
        }),
        .use_llvm = debug,
    });
    zstd_lib.root_module.addCSourceFiles(.{
        .root = b.path("extern/zstd/lib/"),
        .files = &.{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/pool.c",
            "common/threading.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/huf_compress.c",
            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",
            "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",
            "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",
            "compress/zstdmt_compress.c",
            "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",
            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress_block.c",
            "decompress/zstd_decompress.c",
            "dictBuilder/cover.c",
            "dictBuilder/divsufsort.c",
            "dictBuilder/fastcover.c",
            "dictBuilder/zdict.c",
        },
    });
    zstd_lib.root_module.addCSourceFiles(.{
        .root = b.path("extern/zstd/lib/decompress"),
        .files = &.{"huf_decompress_amd64.S"},
    });
    zstd_lib.installHeadersDirectory(b.path("extern/zstd/lib/"), &.{}, .{});
    zstd_lib.installHeadersDirectory(b.path("extern/zstd/lib/common/"), &.{}, .{});
    zstd_lib.installHeadersDirectory(b.path("extern/zstd/lib/compress/"), &.{}, .{});
    zstd_lib.installHeadersDirectory(b.path("extern/zstd/lib/dictBuilder/"), &.{}, .{});
    zstd_lib.installHeadersDirectory(b.path("extern/zstd/lib/"), &.{}, .{});
    return zstd_lib;
}
