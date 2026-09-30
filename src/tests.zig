const std = @import("std");
const Io = std.Io;

var alloc = std.testing.allocator;
var io = std.testing.io;

const Archive = @import("archive.zig");

const TEST_ARCHIVE = "testing/LinuxPATest.sfs";

const OPEN_TEST_LOCATION = "PortableApps/gVimPortable/GVim-v8.2.2965.glibc2.15-x86_64.AppImage";

test "Open" {
    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    var root = try arc.root(alloc);
    defer root.deinit();

    var test_open = try root.open(alloc, OPEN_TEST_LOCATION);
    defer test_open.deinit();
}

const FULL_EXTRACT_LOCATION_ST = "testing/TestExtractST";

test "FullExtractSingleThreaded" {
    Io.Dir.cwd().deleteTree(io, FULL_EXTRACT_LOCATION_ST) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    try arc.extract(alloc, io, FULL_EXTRACT_LOCATION_ST, .single_threaded_default);
}

const FULL_EXTRACT_LOCATION_MT = "testing/TestExtractMT";

test "FullExtractMultiThreaded" {
    Io.Dir.cwd().deleteTree(io, FULL_EXTRACT_LOCATION_MT) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    try arc.extract(alloc, io, FULL_EXTRACT_LOCATION_MT, .default);
}

const FULL_EXTRACT_LOCATION_ST_IO = "testing/TestExtractST_Io";

test "FullExtractSingleThreadedIo" {
    Io.Dir.cwd().deleteTree(io, FULL_EXTRACT_LOCATION_ST_IO) catch {};

    const st_io = Io.Threaded.global_single_threaded.io();

    var archive_file = try Io.Dir.cwd().openFile(st_io, TEST_ARCHIVE, .{});
    defer archive_file.close(st_io);

    var arc: Archive = try .init(st_io, archive_file, 0);
    defer arc.deinit(st_io);

    try arc.extract(alloc, st_io, FULL_EXTRACT_LOCATION_ST_IO, .default);
}
