const std = @import("std");
const Io = std.Io;

const Superblock = @import("archive.zig").Superblock;
const Inode = @import("inode.zig");
const Decomp = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");

pub fn extract(
    alloc: std.mem.Allocator,
    io: Io,
    super: Superblock,
    data: []u8,
    decomp: Decomp.Fn,
    inode: Inode,
    ext_loc: []const u8,
    options: ExtractionOptions,
) !void {}
