const std = @import("std");
const Io = std.Io;

const Inode = @import("inode.zig");

const File = @This();

alloc: std.mem.Allocator,

name: []const u8,
inode: Inode,

pub fn close(self: File) void {
    self.inode.deinit(self.alloc);
    self.alloc.free(self.name);
}
