const std = @import("std");

pub const SfsReader = @import("reader.zig").SfsReader;
pub const ExtractionOptions = @import("extract_options.zig");

pub const SfsFile = SfsReader(std.fs.File);

const test_file = "testing/LinuxPATest.sfs";

test "OpenTest" {
    const fil = try std.fs.cwd().openFile(test_file, .{});
    defer fil.close();
    var rdr: SfsFile = try .init(std.testing.allocator, fil, 0);
    defer rdr.deinit();
    std.debug.print("{}\n", .{rdr.super});
    const root = try rdr.archiveRoot();
    defer root.deinit();
}
