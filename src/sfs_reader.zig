const std = @import("std");

const Superblock = @import("super.zig");
const PRdr = @import("util/p_rdr.zig").PRdr;

pub fn SfsReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: PRdr(T),

        super: Superblock = undefined,

        pub fn root(self: SfsReader) !Self {}
    };
}
