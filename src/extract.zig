const std = @import("std");
const Io = std.Io;

const Superblock = @import("archive.zig").Superblock;
const Decomp = @import("decomp.zig");
const Inode = @import("inode.zig");
const ExtractionOptions = @import("options.zig");
const Single = @import("extract-single.zig");
const Multi = @import("extract-multi.zig");

pub fn extract(
    alloc: std.mem.Allocator,
    io: Io,
    super: Superblock,
    data: []u8,
    decomp: Decomp.Fn,
    inode: Inode,
    ext_loc: []const u8,
    options: ExtractionOptions,
) !void {
    if (options.single_threaded)
        return Single.extract(alloc, io, super, data, decomp, inode, ext_loc, options);
    return Multi.extract(alloc, io, super, data, decomp, inode, ext_loc, options);
}
