const std = @import("std");

const OffsetFile = @import("offset_file.zig");

const MetadataCache = @This();

alloc: std.mem.Allocator,

buf: []u8,
fixed_alloc: std.heap.FixedBufferAllocator,

cache: std.AutoArrayHashMap(u64, [8192]u8),

mut: std.Thread.Mutex = .{},
cache_mut: std.AutoArrayHashMap(u64, std.Thread.Mutex),

fil: OffsetFile,

pub fn init(alloc: std.mem.Allocator, cache_size: u64) !MetadataCache {}
pub fn deinit(self: *MetadataCache) void {
    self.mut.lock();
    defer self.mut.unlock();
    self.cache.deinit();
    self.cache_mut.deinit();
    self.alloc.free(self.buf);
}

pub fn getChunk(self: *MetadataCache, offset: u64) ![8192]u8 {
    var res = self.cache.get(offset);
    if (res != null) return res.?;
    var offset_mut = blk: {
        self.mut.lock();
        defer self.mut.unlock();
        const mut = try self.cache_mut.getOrPut(offset);
        if (!mut.found_existing)
            mut.value_ptr.* = .{};
        break :blk mut.value_ptr;
    };
    offset_mut.lock();
    defer offset_mut.unlock();
}
