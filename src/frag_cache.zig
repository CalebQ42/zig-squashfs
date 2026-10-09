const std = @import("std");
const Io = std.Io;

const Lookup = @import("lookup.zig");
const Decomp = @import("decomp.zig");
const BlockSize = @import("inode.zig").BlockSize;

const FragCache = @This();

block_size: u32,

entries: Lookup.Table(Entry),

cache: std.AutoHashMapUnmanaged(u32, []u8) = .empty,

mut: Io.RwLock = .init,

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
        alloc.free(cache.*);
    }
    self.cache.deinit(alloc);
}

pub fn get(self: *FragCache, alloc: std.mem.Allocator, io: Io, idx: u32) ![]u8 {
    {
        try self.mut.lockShared(io);
        defer self.mut.unlockShared(io);
        const cache = self.cache.get(idx);
        if (cache != null) return cache.?;
    }

    const entry = try self.entries.get(alloc, io, idx);

    const data = self.entries.data[entry.start..][0..entry.size.size];

    if (entry.size.uncompressed)
        return data;

    try self.mut.lock(io);
    defer self.mut.unlock(io);

    const new = try self.cache.getOrPut(alloc, idx);
    if (new.found_existing)
        return new.value_ptr.*;
    errdefer self.cache.removeByPtr(new.key_ptr);

    new.value_ptr.* = try alloc.alloc(u8, self.block_size);
    errdefer alloc.free(new.value_ptr.*);

    _ = try self.entries.decomp(alloc, data, new.value_ptr.*);

    return new.value_ptr.*;
}

// Types

pub const Entry = extern struct {
    start: u64,
    size: BlockSize,
    _: u32,
};
const CacheData = struct {
    data: []u8 = &[0]u8{},
    set: Io.Event = .unset,
};
