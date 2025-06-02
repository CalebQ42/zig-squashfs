const std = @import("std");
const fs = std.fs;

const File = fs.File;

pub const CustomSfsReader = @import("sfs_reader.zig").SfsReader;

pub const FileSfsReader = CustomSfsReader(
    File,
    File.PReadError,
    File.pread,
);

pub const SfsFile = @import("sfs_file.zig");

test "FileSfsReader" {
    const testFile = "testing/LinuxPATest.sfs";
    const fil = try fs.cwd().openFile(testFile, .{});
    defer fil.close();
    const rdr: FileSfsReader = try .init(std.testing.allocator, fil);
    _ = rdr;
}
