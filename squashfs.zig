const std = @import("std");
const fs = std.fs;

const Superblock = @import("superblock.zig").Superblock;
const inode = @import("inode.zig");
const MetadataReader = @import("metadata_reader.zig").MetadataReader;
const File = @import("file.zig").File;

pub const Reader = struct {
    super: Superblock,
    rdr: fs.File,
    root: File,
    alloc: std.heap.GeneralPurposeAllocator(.{}),

    pub fn deinit(self: *Reader) void {
        self.rdr.close();
        // _ = self.alloc.deinit();
    }
};

pub fn newReader(filename: []const u8) !Reader {
    const file = try std.fs.cwd().openFile(filename, .{});
    errdefer file.close();
    var alloc: std.heap.GeneralPurposeAllocator(.{}) = .init;
    errdefer _ = alloc.deinit();
    const super = try file.reader().readStruct(Superblock);
    try super.valid();
    try file.seekTo(super.inode_table + super.root_inode.block_start);
    var root_reader: MetadataReader = try .init(super.comp, file.reader().any(), alloc.allocator());
    defer root_reader.deinit();
    try root_reader.skip(super.root_inode.offset);
    const root_inode = try inode.readInode(root_reader.any(), super.block_size, alloc.allocator());
    return Reader{
        .super = super,
        .rdr = file,
        .root = root_inode,
        .alloc = alloc,
    };
}
