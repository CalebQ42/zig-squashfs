const std = @import("std");

const Archive = @import("archive.zig");
const Decompressor = @import("decomp.zig");
const Directory = @import("directory.zig");
const Inode = @import("inode.zig");
const MetadataReader = @import("util/metadata.zig");
const Utils = @import("util/utils.zig");

pub const Error = error{
    NotDirectory,
    NotRegularFile,
};

const File = @This();

alloc: std.mem.Allocator,

superblock: Archive.MinimalSuperblock,
decomp: Decompressor,

name: []const u8,
inode: Inode,

pub fn init(alloc: std.mem.Allocator, archive: Archive, entry: Directory.Entry) !File {
    const new_name = try alloc.alloc(u8, entry.name.len);
    errdefer alloc.free(new_name);
    @memcpy(new_name, entry.name);
    var rdr = archive.file.readerAt(archive.super.inode_start + entry.block_start, &[0]u8{});
    var meta: MetadataReader = .init(&rdr.interface, &archive.stateless_decomp);
    try meta.interface.discardAll(entry.block_offset);
    return .{
        .alloc = alloc,
        .superblock = archive.super,
        .decomp = .{
            .alloc = alloc,
            .vtable = &.{ .stateless = archive.stateless_decomp.vtable.stateless },
        },
        .name = new_name,
        .inode = try .read(alloc, &meta.interface, archive.super.block_size),
    };
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
}

/// Opens a sub-directory. If the given path is "", ".", "/", or "./", a copy of the File is returned.
pub fn open(self: File, alloc: std.mem.Allocator, path: []const u8) !File {
    switch (self.inode.hdr.inode_type) {
        .dir, .ext_dir => {},
        else => Error.NotDirectory,
    }
    if (Utils.pathIsSelf(path)) {
        const new_name = try alloc.alloc(u8, self.name.len);
        @memcpy(new_name, self.name);
        return .{
            .alloc = alloc,
            .superblock = self.superblock,
            .decomp = .{
                .alloc = alloc,
                .vtable = &.{ .stateless = self.decomp.vtable.stateless },
            },
            .name = new_name,
            .inode = self.inode,
        };
    }

    return error.TODO;
}
