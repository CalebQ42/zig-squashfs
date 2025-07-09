const std = @import("std");

const Superblock = @import("superblock.zig").Superblock;

pub fn Reader(comptime T: type) type {
    std.debug.assert(std.meta.hasFn(T, "pread"));

    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: T,

        super: Superblock = undefined,

        pub fn init(alloc: std.mem.Allocator, rdr: T) Self {
            const out = Self{
                .alloc = alloc,
                .rdr = rdr,
            };
            _ = try rdr.pread(std.mem.asBytes(&out.super), 0);
            return out;
        }
    };
}
