const std = @import("std");
const Io = std.Io;

const Super = @import("archive.zig").Super;
const Inode = @import("inode.zig");
const Options = @import("options.zig");
const Lookup = @import("lookup.zig");
const Decomp = @import("decomp.zig");

const single = @import("extract/single.zig").extract;
const multi = @import("extract/multi.zig").extract;

pub fn extract(alloc: std.mem.Allocator, io: Io, data: []u8, super: Super, decomp: *Decomp, inode: Inode, filepath: []const u8, options: Options) !void {
    return if (options.single_threaded)
        single(alloc, io, data, super, decomp, inode, filepath, options)
    else
        multi(alloc, io, data, super, decomp, inode, filepath, options);
}
