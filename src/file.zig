const std = @import("std");

const Archive = @import("archive.zig");
const Directory = @import("directory.zig");
const Inode = @import("inode.zig");
const MetadataReader = @import("util/metadata.zig");

const File = @This();

alloc: std.mem.Allocator,

archive: Archive,

name: []const u8,
inode: Inode,

pub fn init(alloc: std.mem.Allocator, archive: Archive, entry: Directory.Entry) !File {
    const new_name = try alloc.alloc(u8, entry.name.len);
    errdefer alloc.free(new_name);
    @memcpy(new_name, entry.name);
    var rdr = archive.file.readerAt(archive.super.inode_start + entry.block_start, &[0]u8{});
    var meta
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
}
