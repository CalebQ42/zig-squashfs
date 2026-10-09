const std = @import("std");
const Io = std.Io;

var alloc = std.testing.allocator;
var io = std.testing.io;

const Archive = @import("archive.zig");

const TEST_ARCHIVE = "testing/LinuxPATest.sfs";

const TEST_FILE = "PortableApps/gVimPortable/GVim-v8.2.2965.glibc2.15-x86_64.AppImage";

test "Open" {
    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    var root = try arc.root(alloc);
    defer root.deinit();

    var test_open = try root.open(alloc, TEST_FILE);
    defer test_open.deinit();
}

test "SingleFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = ".zig-cache/tmp/" ++ tmp.sub_path[0..tmp.sub_path.len] ++ "/GVim-v8.2.2965.glibc2.15-x86_64.AppImage";

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    var root = try arc.root(alloc);
    defer root.deinit();

    var test_open = try root.open(alloc, TEST_FILE);
    defer test_open.deinit();

    try test_open.extract(alloc, io, ext_path, .default);

    try verifyFile(tmp, TEST_FILE, "GVim-v8.2.2965.glibc2.15-x86_64.AppImage");
}

test "ExtractSingleThreaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = ".zig-cache/tmp/" ++ tmp.sub_path[0..tmp.sub_path.len];

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    try arc.extract(alloc, io, ext_path, .single_threaded_default);

    try verifyExtraction(tmp);
}

test "ExtractMultiThreaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = ".zig-cache/tmp/" ++ tmp.sub_path[0..tmp.sub_path.len];

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    try arc.extract(alloc, io, ext_path, .default);

    try verifyExtraction(tmp);
}

test "ExtractSingleThreadedIo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = ".zig-cache/tmp/" ++ tmp.sub_path[0..tmp.sub_path.len];

    const st_io = Io.Threaded.global_single_threaded.io();

    var archive_file = try Io.Dir.cwd().openFile(st_io, TEST_ARCHIVE, .{});
    defer archive_file.close(st_io);

    var arc: Archive = try .init(st_io, archive_file, 0);
    defer arc.deinit(st_io);

    try arc.extract(alloc, st_io, ext_path, .default);

    try verifyExtraction(tmp);
}

fn verifyFile(tmp: std.testing.TmpDir, rel_path: []const u8, ext_loc: []const u8) !void {
    var ref_dir = try refDir();
    defer ref_dir.close(io);

    const ref = try ref_dir.statFile(io, rel_path, .{});

    const compare = tmp.dir.statFile(io, ext_loc, .{}) catch |err| {
        std.debug.print("Error stating {s} for comparison: {}\n", .{ ext_loc, err });
        return err;
    };

    if (compare.kind != ref.kind) {
        std.debug.print("Wrong file type. {s} should be {}, but is {}\n", .{ rel_path, ref.kind, compare.kind });
        return error.Kind;
    }
    switch (compare.kind) {
        .sym_link => {
            var comp_target_buf: [150]u8 = undefined;
            var ref_target_buf: [150]u8 = undefined;

            const comp_target_siz = try tmp.dir.readLink(io, rel_path, &comp_target_buf);
            const ref_target_siz = try ref_dir.readLink(io, rel_path, &ref_target_buf);

            if (!std.mem.eql(u8, comp_target_buf[0..comp_target_siz], ref_target_buf[0..ref_target_siz])) {
                std.debug.print("Wrong symlink target. {s} should be {s}, but is {s}\n", .{ rel_path, ref_target_buf[0..ref_target_siz], comp_target_buf[0..comp_target_siz] });
                return error.SymlinkTarget;
            }
        },
        .file => {
            if (compare.size != ref.size) {
                std.debug.print("Wrong file size. {s} should be {}, but is {} (difference of {})\n", .{ rel_path, ref.size, compare.size, ref.size - compare.size });
                return error.FileSize;
            }
            // TODO: contents check.
        },
        else => {}, // TODO
    }
}

fn verifyExtraction(tmp: std.testing.TmpDir) !void {
    var ref_dir = try refDir();
    defer ref_dir.close(io);

    var walker = try ref_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const ref = try ref_dir.statFile(io, entry.path, .{});

        const compare = tmp.dir.statFile(io, entry.path, .{}) catch |err| {
            std.debug.print("Error stating {s} for comparison: {}\n", .{ entry.path, err });
            return err;
        };

        if (compare.kind != ref.kind) {
            std.debug.print("Wrong file type. {s} should be {}, but is {}\n", .{ entry.path, ref.kind, compare.kind });
            return error.Kind;
        }
        switch (compare.kind) {
            .sym_link => {
                var comp_target_buf: [150]u8 = undefined;
                var ref_target_buf: [150]u8 = undefined;

                const comp_target_siz = try tmp.dir.readLink(io, entry.path, &comp_target_buf);
                const ref_target_siz = try ref_dir.readLink(io, entry.path, &ref_target_buf);

                if (!std.mem.eql(u8, comp_target_buf[0..comp_target_siz], ref_target_buf[0..ref_target_siz])) {
                    std.debug.print("Wrong symlink target. {s} should be {s}, but is {s}\n", .{ entry.path, ref_target_buf[0..ref_target_siz], comp_target_buf[0..comp_target_siz] });
                    return error.SymlinkTarget;
                }
            },
            .file => {
                if (compare.size != ref.size) {
                    std.debug.print("Wrong file size. {s} should be {}, but is {} (difference of {})\n", .{ entry.path, ref.size, compare.size, ref.size - compare.size });
                    return error.FileSize;
                }
                // TODO: contents check.
            },
            else => {}, // TODO
        }
    }
}

fn refDir() !Io.Dir {
    return Io.Dir.cwd().openDir(io, "testing/Reference", .{ .iterate = true }) catch |err| blk: {
        if (err != error.FileNotFound) return err;

        const res = try std.process.run(alloc, io, .{
            .argv = &.{ "unsquashfs", "-f", "-d", "testing/Reference", TEST_ARCHIVE },
        });
        defer {
            alloc.free(res.stdout);
            alloc.free(res.stderr);
        }
        if (!res.term.success()) {
            std.debug.print("Failed to create reference extraction:\n{s}{s}\n", .{ res.stdout, res.stderr });
            return error.ReferenceExtractFailed;
        }

        break :blk try Io.Dir.cwd().openDir(io, "testing/Reference", .{ .iterate = true });
    };
}
