const std = @import("std");
const Io = std.Io;
const ArrayHashMap = std.array_hash_map.Auto;
const Atomic = std.atomic.Value;

const Decompress = @import("decompress.zig");
const Fn = Decompress.Fn;
const DecompressType = Decompress.CompressionType;

const DecompCache = @This();

const Cache = struct {
    cache: []u8,
    usage: Atomic(u32),
};

arena: std.heap.ArenaAllocator,
decomp: Fn,

map: Io.File.MemoryMap,

cache: ArrayHashMap(u64, Cache),
mut: Io.RwLock = .init,
cond: Io.Condition = .init,

max_size: u64,
cur_size: u64 = 0,

pub fn init(alloc: std.mem.Allocator, map: Io.File.MemoryMap, decomp_type: DecompressType, max_size: u64) !DecompCache {
    return .{
        .arena = .init(alloc),
        .decomp = try Decompress.getDecompressFn(decomp_type),

        .map = map,

        .cache = .empty,

        .max_size = max_size,
    };
}
pub fn deinit(self: *DecompCache, io: Io) void {
    self.mut.lockUncancelable(io);
    self.cache.deinit(self.arena.child_allocator);
    self.arena.deinit();
    self.map.destroy(io);
}

fn makeRoom(self: *DecompCache, io: Io, size: u32) !void {
    if (size + self.cur_size < self.max_size) return;
    var iter = self.cache.iterator();
    while (iter.next()) |ent| {
        const val = ent.value_ptr;
        if (val.usage.load(.unordered) == 0) {
            self.cur_size -= val.cache.len;
            _ = self.cache.orderedRemove(ent.key_ptr.*);
        }
        if (size + self.cur_size < self.max_size) return;
    }
    try self.cond.wait(io, &self.mut.mutex);
    return self.makeRoom(io, size);
}

pub fn checkinBlock(self: *DecompCache, io: Io, offset: u64) !void {
    self.mut.lockSharedUncancelable(io);
    defer self.mut.unlockShared(io);

    const get = self.cache.getPtr(offset);
    if (get == null) return error.NotACachedBlock;
    const res = get.?.usage.fetchSub(1, .acq_rel);
    if (res == 0) self.cond.broadcast(io);
}
pub fn checkoutBlock(self: *DecompCache, io: Io, offset: u64, data_size: u32, max_result_size: u32) ![]u8 {
    {
        try self.mut.lockShared(io);
        defer self.mut.unlockShared(io);

        const get = self.cache.getPtr(offset);
        if (get != null) {
            _ = get.?.usage.fetchAdd(1, .acq_rel);
            return get.?.cache;
        }
    }
    try self.mut.lock(io);
    defer self.mut.unlock(io);

    try self.makeRoom(io, max_result_size);

    var alloc = self.arena.allocator();
    const buf_alloc = self.arena.child_allocator;

    var out = try alloc.alloc(u8, max_result_size);
    errdefer alloc.free(out);

    const out_size = try self.decomp(buf_alloc, self.map.memory[offset..][0..data_size], out);
    if (out_size != max_result_size) {
        if (alloc.resize(out, out_size)) {
            out.len = out_size;
        } else {
            const new_out = try alloc.alloc(u8, out_size);
            @memcpy(new_out, out[0..out_size]);
            alloc.free(out);
            out = new_out;
        }
    }

    try self.cache.put(buf_alloc, offset, .{
        .cache = out,
        .usage = .init(1),
    });

    return out;
}
