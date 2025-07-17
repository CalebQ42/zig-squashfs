const std = @import("std");

pub const SfsReader = @import("reader.zig").SfsReader;
pub const ExtractionOptions = @import("extract_options.zig");

pub const SfsFile = SfsReader(std.fs.File);

const test_file = "testing/LinuxPATest.sfs";

test "OpenFile" {
    const fil = try std.fs.cwd().openFile(test_file, .{});
    defer fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, fil, 0);
    defer rdr.deinit();
    std.debug.print("{}\n", .{rdr.super});
    const root = try rdr.root();
    defer root.deinit();
    var iter = root.iterate();
    while (try iter.next()) |f| {
        defer f.deinit();
        std.debug.print("{s}\n", .{f.name});
    }
    const start = try root.open("Start.exe");
    defer start.deinit();
}

test "ReadFile" {
    const fil = try std.fs.cwd().openFile(test_file, .{});
    defer fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, fil, 0);
    defer rdr.deinit();
    std.debug.print("{}\n", .{rdr.super});
    const root = try rdr.root();
    defer root.deinit();
}
