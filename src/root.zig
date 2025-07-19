const std = @import("std");

pub const SfsReader = @import("reader.zig").SfsReader;
pub const ExtractionOptions = @import("extract_options.zig");

pub const SfsFile = SfsReader(std.fs.File);

const test_archive = "testing/LinuxPATest.sfs";
const test_file = "Start.exe";
const file_extr_loc = "testing/Start.exe";

test "OpenFile" {
    const sfs_fil = try std.fs.cwd().openFile(test_archive, .{});
    defer sfs_fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, sfs_fil, 0);
    defer rdr.deinit();
    std.debug.print("{}\n", .{rdr.super});
    const root = try rdr.root();
    defer root.deinit();
    var iter = root.iterate();
    while (try iter.next()) |f| {
        defer f.deinit();
        std.debug.print("{s}\n", .{f.name});
    }
}

test "ExtractFile" {
    std.fs.cwd().deleteFile(file_extr_loc) catch {};
    const sfs_fil = try std.fs.cwd().openFile(test_archive, .{});
    defer sfs_fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, sfs_fil, 0);
    defer rdr.deinit();
    const fil = try rdr.open(test_file);
    defer fil.deinit();
    var op: ExtractionOptions = try .init();
    op.verbose = true;
    try fil.extract(op, file_extr_loc);
}
