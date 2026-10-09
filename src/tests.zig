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

test "ExtractSingleThreaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = ".zig-cache/tmp/" ++ tmp.sub_path[0..tmp.sub_path.len];

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    try arc.extract(alloc, io, ext_path, .single_threaded_default);

    try veryifyExtraction(tmp);
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

    try veryifyExtraction(tmp);
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

    try veryifyExtraction(tmp);
}

fn veryifyExtraction(tmp: std.testing.TmpDir) !void {
    _ = tmp;
    return error.TODO;
}
