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

const FULL_EXTRACT_LOCATION = "testing/TestExtractST";

test "FullExtractSingleThreaded" {
    Io.Dir.cwd().deleteTree(io, FULL_EXTRACT_LOCATION) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    try arc.extract(alloc, io, FULL_EXTRACT_LOCATION, .default);
}
