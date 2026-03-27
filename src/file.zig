const std = @import("std");

const Inode = @import("inode.zig");

name: []const u8,
inode: Inode,
