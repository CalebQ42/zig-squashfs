const std = @import("std");
const fs = std.fs;

const File = fs.File;

pub const CustomSfsReader = @import("sfs_reader.zig").SfsReader;
pub const PReader = @import("preader.zig").PReader;

pub const FileSfsReader = CustomSfsReader(PReader(
    File,
    File.PReadError,
    File.pread,
));

test "FileSfsReader" {
    const testFile = "testing/LinuxPATest.sfs";
    const fil = try fs.cwd().openFile(testFile, .{});
    defer fil.close();
    const rdr: FileSfsReader = try .init(std.testing.allocator, fil);
    _ = rdr;
}
