const std = @import("std");

pub const SfsReader = @import("sfs_reader.zig").SfsReader;
pub const SfsFile = SfsReader(std.fs.File);

pub fn openFile(alloc: std.mem.Allocator, file: std.fs.File, offset: u64) !SfsFile {
    return .init(alloc, file, offset, try std.Thread.getCpuCount());
}

const testFile = "testing/LinuxPATest.sfs";

test "BasicInit" {
    std.debug.print("starting BasicInit\n", .{});
    var fil = try std.fs.cwd().openFile(testFile, .{});
    defer fil.close();
    var rdr = try openFile(std.testing.allocator, fil, 0);
    defer rdr.deinit();
    std.debug.print("HELLO {*}\n", .{&rdr.decomp});
    // TODO: assert correct reading of the superblock.
    std.debug.print("{}\n", .{rdr.super});
    std.debug.print("{any}\n", .{try rdr.export_table.get(2973)});
    // TODO: test the 3 tables. Check boundries & extent.
    std.debug.print("completed BasicInit\n", .{});
}

const extractLocation = "testing/testExtract";

test "Extraction" {
    std.debug.print("starting Extraction\n", .{});
    var fil = try std.fs.cwd().openFile(testFile, .{});
    defer fil.close();
    var rdr = try openFile(std.testing.allocator, fil, 0);
    defer rdr.deinit();
    //TODO: actual test
    std.debug.print("completed Extraction\n", .{});
}
