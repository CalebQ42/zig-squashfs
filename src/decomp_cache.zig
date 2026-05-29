const std = @import("std");
const Io = std.Io;
const File = Io.File;
const MemoryMap = File.MemoryMap;
const Atomic = std.atomic.Value;

const Decomp = @import("decomp.zig");

const DecompCache = @This();

alloc: std.mem.Allocator,
map: MemoryMap,
decomp_fn: Decomp.Fn,

cache: std.AutoHashMap(u64, Cache),
mut: std.Io.RwLock = .init,
cond: std.Io.Condition = .init,

max_mem: u64,
cur_mem: u64 = 0,

pub fn init(alloc: std.mem.Allocator, map: MemoryMap, compression: Decomp.Enum, max_mem: u64) DecompCache {
    return .{
        .alloc = alloc,
        .map = map,
        .decomp_fn = try Decomp.DecompFn(compression),

        .cache = .init(alloc),

        .max_mem = max_mem,
    };
}
pub fn deinit(self: *DecompCache, io: Io) void {
    self.mut.lockUncancelable(io);

    var iter = self.cache.valueIterator();
    while (iter.next()) |v|
        self.alloc.free(v.data);
    self.cache.deinit();
}

pub fn get(self: *DecompCache, io: Io, offset: u64, compressed_size: u32, max_size: u32) ![]u8 {
    {
        try self.mut.lockShared(io);
        defer self.mut.unlockShared(io);

        const cache = self.cache.getPtr(offset);
        if (cache != null) {
            _ = cache.?.usage.fetchAdd(1, .acquire);
            return cache.?.data;
        }
    }
    try self.mut.lock(io);
    defer self.mut.unlock(io);

    const cache = try self.cache.getOrPut(offset);
    if (cache.found_existing) {
        _ = cache.?.usage.fetchAdd(1, .acquire);
        return cache.?.data;
    }
    errdefer self.cache.removeByPtr(cache.key_ptr);

    try self.ensureSpace(io, max_size);

    var out = try self.alloc.alloc(u8, max_size);
    errdefer self.alloc.free(out);

    const decomp_size = try self.decomp_fn(self.alloc, self.map.memory[offset..][0..compressed_size], out);
    if (decomp_size != max_size) {
        if (!self.alloc.resize(out, decomp_size)) {
            const new_out = try self.alloc.alloc(u8, decomp_size);
            @memcpy(new_out, out[0..decomp_size]);
            out = new_out;
        } else {
            out.len = decomp_size;
        }
    }
    self.cur_mem += decomp_size;

    cache.value_ptr.data = out;
    _ = cache.value_ptr.usage.fetchAdd(1, .acquire);
    return out;
}
pub fn finished(self: *DecompCache, io: Io, offset: u64) void {
    const cache = self.cache.getPtr(offset);
    if (cache == null) {
        std.debug.print("Finished using cache, but cache does not exist: {}\n", .{offset});
        return;
    }
    const use = cache.?.usage.fetchSub(1, .acquire);
    if (use == 0)
        self.cond.broadcast(io);
}

fn ensureSpace(self: *DecompCache, io: Io, size: u64) !void {
    while (self.cur_mem + size > self.max_mem) {
        var iter = self.cache.valueIterator();
        while (iter.next()) |cache| {
            if (cache.usage.load(.unordered) == 0) {
                self.alloc.free(cache.data);
                self.cur_mem -= cache.data.len;

                if (self.cur_mem + size <= self.max_mem) return;
            }
        }
        if (self.cur_mem + size <= self.max_mem) return;
        try self.cond.wait(io, self.mut.mutex);
    }
}

// Types

const Cache = struct {
    data: []u8,
    usage: Atomic(u32),
};
