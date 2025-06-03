pub const SfsReader = @import("sfs_reader.zig");
pub const SfsFile = @import("sfs_file.zig").SfsFile;

test "library test" {
    const std = @import("std");
    const test_sfs = "testing/LinuxPATest.sfs";
    const sfs_fil = try std.fs.cwd().openFile(test_sfs, .{});
    defer sfs_fil.close();
    const sfs: *SfsReader = try .init(std.testing.allocator, sfs_fil);
    defer sfs.deinit();
}
