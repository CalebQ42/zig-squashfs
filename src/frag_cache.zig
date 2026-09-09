const std = @import("std");
const Io = std.Io;

const Lookup = @import("lookup.zig");
const Decomp = @import("decomp.zig");
const BlockSize = @import("inode.zig").BlockSize;

const FragCache = @This();

block_size: u32,

entries: Lookup.Table(Entry),

cache: std.AutoHashMapUnmanaged(u32, CacheData) = .empty,

mut: Io.Mutex = .init,

pub fn init(data: []u8, decomp: Decomp.Fn, block_size: u32, start: u64, count: u32) !FragCache {
    return .{
        .block_size = block_size,

        .entries = try .init(data, decomp, start, count),
    };
}
pub fn deinit(self: *FragCache, alloc: std.mem.Allocator) void {
    self.entries.deinit(alloc);
    var iter = self.cache.valueIterator();
    while (iter.next()) |cache| {
        if (cache.allocd)
            alloc.free(cache.data);
    }
    self.cache.deinit(alloc);
}

pub fn get(self: *FragCache, alloc: std.mem.Allocator, io: Io, idx: u32) ![]u8 {
    const cache = self.cache.get(idx);
    if (cache != null) return cache.?.data;

    const entry = try self.entries.get(alloc, io, idx);

    const data = self.entries.data[entry.start..][0..entry.size.size];

    if (entry.size.uncompressed)
        return data;

    try self.mut.lock(io);
    defer self.mut.unlock(io);

    const cache_data = try alloc.alloc(u8, self.block_size);
    errdefer alloc.free(cache_data);

    _ = try self.entries.decomp(alloc, data, cache_data);

    try self.cache.put(alloc, idx, .{
        .data = cache_data,
        .allocd = true,
    });

    return cache_data;
}

// Types

pub const Entry = extern struct {
    start: u64,
    size: BlockSize,
    _: u32,
};
const CacheData = struct {
    data: []u8,
    allocd: bool,
};
