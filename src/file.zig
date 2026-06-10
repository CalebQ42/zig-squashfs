//! A squashfs file/directory. Basically a wrapper around an Inode.

const std = @import("std");

const Inode = @import("inode.zig");

const File = @This();

alloc: std.mem.Allocator,

name: []const u8,
inode: Inode,

/// The given allocator should have been used to create the name and inode.
pub fn init(alloc: std.mem.Allocator, name: []const u8, inode: Inode) File {
    return .{
        .alloc = alloc,

        .name = name,
        .inode = inode,
    };
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
    self.inode.deinit(self.alloc);
}
