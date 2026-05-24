const std = @import("std");

pub fn build(b: *std.Build) !void {
    const use_zig_decomp = b.option(bool, "use_zig_decomp", "Use zig standard library for decompression.") orelse false;
    const allow_lzo = b.option(bool, "allow_lzo", "Compile with lzo support") orelse false;
<<<<<<< HEAD
=======
    const dynamic = b.option(bool, "dynamic", "Dynamicly link C decompression libraries") orelse false;
>>>>>>> dfbfbda (Build is working again (on Zig master branch))
    var debug = b.option(bool, "debug", "Enable options to make debugging easier.");
    const version_string_option = b.option([]const u8, "version", "Version of the library/binary");

    const zig_squashfs_options = b.addOptions();
    zig_squashfs_options.addOption(bool, "use_zig_decomp", use_zig_decomp);
    zig_squashfs_options.addOption(bool, "allow_lzo", allow_lzo);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (optimize == .Debug) debug = true;

    const c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/c.h"),
    });

    const lib = b.addLibrary(.{
        .name = "squashfs",
        .root_module = b.createModule(.{
            .optimize = if (debug == true) .Debug else optimize,
            .target = target,
            .valgrind = debug,
            .root_source_file = b.path("src/root.zig"),
<<<<<<< HEAD
            // .link_libc = true,
            .imports = &.{
                .{ .name = "options", .module = zig_squashfs_options.createModule() },
                .{ .name = "c", .module = c.createModule() },
=======
            .imports = &.{
                .{ .name = "options", .module = zig_squashfs_options.createModule() },
>>>>>>> dfbfbda (Build is working again (on Zig master branch))
            },
        }),
        .use_llvm = debug,
    });

    const deps = try dependencies(b, optimize, target, use_zig_decomp, allow_lzo, dynamic);
    defer b.allocator.free(deps);

<<<<<<< HEAD
    const zng = b.dependency("zlib_ng", .{ .optimize = optimize, .target = target });
    lib.root_module.linkLibrary(zng.artifact("zng"));

    const xz = b.dependency("xz", .{ .optimize = optimize, .target = target });
    lib.root_module.linkLibrary(xz.artifact("lzma"));

    const minilzo = b.dependency("minilzo", .{ .optimize = optimize, .target = target });
    lib.root_module.linkLibrary(minilzo.artifact("minilzo"));

    const lz4 = b.dependency("lz4", .{ .optimize = optimize, .target = target });
    lib.root_module.linkLibrary(lz4.artifact("lz4"));
=======
    for (deps) |d|
        lib.root_module.linkLibrary(d);

    if (!use_zig_decomp) {
        const c = b.addTranslateC(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/c.h"),
        });
        if (allow_lzo) c.defineCMacro("ALLOW_LZO", null);
        lib.root_module.addImport("c", c.createModule());

        if (dynamic)
            dynamicLinkLibraries(c, allow_lzo);
    }
>>>>>>> dfbfbda (Build is working again (on Zig master branch))

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
            },
        }),
        .use_llvm = debug,
    });
    exe.root_module.addOptions("config", unsquashfs_options);

    b.installArtifact(lib);
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/root.zig"),
            .imports = &.{
                .{ .name = "options", .module = zig_squashfs_options.createModule() },
            },
            .valgrind = debug,
        }),
        .use_llvm = debug,
    });

    for (deps) |d|
        mod_tests.root_module.linkLibrary(d);

    if (!use_zig_decomp) {
        const c = b.addTranslateC(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/c.h"),
        });
        mod_tests.root_module.addImport("c", c.createModule());
        if (allow_lzo) c.defineCMacro("ALLOW_LZO", null);

        if (dynamic)
            dynamicLinkLibraries(c, allow_lzo);
    }

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // zls build check steps
    const lib_check = b.addLibrary(.{
        .name = "squashfs",
        .root_module = exe.root_module,
    });
    const exe_check = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = lib.root_module,
    });
    const check = b.step("check", "Check if unsquashfs compiles");
    check.dependOn(&lib_check.step);
    check.dependOn(&exe_check.step);
}

pub fn dynamicLinkLibraries(mod: *std.Build.Step.TranslateC, allow_lzo: bool) void {
    mod.linkSystemLibrary("zstd", .{});
    mod.linkSystemLibrary("zlib-ng", .{});
    mod.linkSystemLibrary("lzma", .{});
    mod.linkSystemLibrary("lz4", .{});
    if (allow_lzo)
        mod.linkSystemLibrary("minilzo", .{});
}
fn dependencies(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    use_zig_decomp: bool,
    allow_lzo: bool,
    dynamic: bool,
) ![]*std.Build.Step.Compile {
    if (use_zig_decomp or dynamic) return &.{};

    var list: std.ArrayList(*std.Build.Step.Compile) = .empty;

    const zstd = b.dependency("zstd", .{ .optimize = optimize, .target = target });
    try list.append(b.allocator, zstd.artifact("zstd"));

    const zng = b.dependency("zlib_ng", .{ .optimize = optimize, .target = target });
    try list.append(b.allocator, zng.artifact("zng"));

    const xz = b.dependency("xz", .{ .optimize = optimize, .target = target });
    try list.append(b.allocator, xz.artifact("lzma"));

    const lz4 = b.dependency("lz4", .{ .optimize = optimize, .target = target });
    try list.append(b.allocator, lz4.artifact("lz4"));

    if (allow_lzo) {
        const minilzo = b.dependency("minilzo", .{ .optimize = optimize, .target = target });
        try list.append(b.allocator, minilzo.artifact("minilzo"));
    }
    return list.toOwnedSlice(b.allocator);
}
