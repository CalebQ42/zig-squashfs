const std = @import("std");
const Io = std.Io;

var alloc = std.testing.allocator;
var io = std.testing.io;

const Archive = @import("archive.zig");

const TEST_ARCHIVE = "testing/LinuxPATest.sfs";

test "Open" {
    var archive_file = try Io.Dir.cwd().openFile(io, TEST_ARCHIVE, .{});
    defer archive_file.close(io);

    var arc: Archive = try .init(io, archive_file, 0);
    defer arc.deinit(io);

    std.debug.print("{}\n", .{arc.super});

    var root = try arc.root(alloc);
    defer root.deinit();
}
