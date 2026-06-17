const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");

const CacheMap = @import("protected_map.zig").ProtectedMap(u64, CachedBlock, decompressBlock);

const Cache = @This();

alloc: std.mem.Allocator,

data: []u8,
decomp: Decomp.Fn,

cache: CacheMap,

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn) Cache {
    return .{
        .alloc = alloc,

        .data = data,
        .decomp = decomp,

        .cache = .init(alloc),
    };
}
pub fn deinit(self: *Cache) void {
    self.cache.deinit();
}

pub fn get(self: *Cache, io: Io, offset: u64, compressed_size: u32) Error![]u8 {
    const res: *CachedBlock = try self.cache.getOrPut(io, offset, .{ self.alloc, self.data, self.decomp, offset, compressed_size });
    return res.block[0..res.size];
}

fn decompressBlock(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, offset: u64, compressed_size: u32) !CachedBlock {
    const block = data[offset..][0..compressed_size];
    var new_cache: CachedBlock = undefined;

    new_cache.size = @truncate(try decomp(alloc, block, &new_cache.block));

    return new_cache;
}

// Types

pub const Error = CacheMap.Error;

const CachedBlock = struct {
    block: [1024 * 1024]u8,
    size: u32,
};
