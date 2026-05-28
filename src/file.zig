const std = @import("std");
const Io = std.Io;

const Inode = @import("inode.zig");

name: []const u8,
inode: Inode,
