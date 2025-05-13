const std = @import("std");
const fs = std.fs;

const Superblock = @import("superblock.zig").Superblock;
const Inode = @import("inode.zig").Inode;

pub const Reader = struct {
    super: Superblock,
    rdr: fs.File,
    root: Inode,
    alloc: std.heap.GeneralPurposeAllocator(.{}),

    pub fn close(self: Reader) void {
        self.rdr.close();
        self.alloc.deinit();
    }
};

pub fn newReader(filename: []const u8) !Reader {
    const file = try std.fs.cwd().openFile(filename, .{});
    errdefer file.close();
    const alloc = std.heap.GeneralPurposeAllocator(.{});
    errdefer alloc.deinit();
    const super = try file.reader().readStruct(Superblock);
    try super.valid();

    return Reader{
        .super = super,
        .rdr = file,
        .alloc = alloc,
    };
}
