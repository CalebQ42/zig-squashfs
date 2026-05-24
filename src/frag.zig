const std = @import("std");
const Io = std.Io;

const BlockSize = @import("inode_data/file.zig").BlockSize;
const LookupTable = @import("lookup_table.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const FragManager = @This();

pub const FragEntry = extern struct {
    start: u64,
    size: BlockSize,
    _: u32,
};

alloc: std.mem.Allocator,
fil: OffsetFile,
decomp: *Decompressor,
block_size: u32,

entries: []FragEntry,

frag_cache: std.array_hash_map.Auto(u32, []u8),
cache_mut: std.Io.RwLock = .init,

pub fn init(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *Decompressor, frag_start: u64, frag_num: u32, block_size: u32) !FragManager {
    const first_offset: u64 = std.mem.readInt(u64, @ptrCast(fil.map.memory[frag_start .. frag_start + 8]), .little);

    var rdr = fil.readerAt(first_offset);
    var meta: MetadataReader = .init(alloc, &rdr, decomp);

    const entries = try alloc.alloc(FragEntry, frag_num);
    errdefer alloc.free(entries);

    try meta.interface.readSliceEndian(FragEntry, entries, .little);

    return .{
        .alloc = alloc,
        .fil = fil,
        .decomp = decomp,
        .block_size = block_size,

        .entries = entries,

        .frag_cache = .empty,
    };
}
pub fn deinit(self: *FragManager, io: Io) void {
    self.cache_mut.lockUncancelable(io);
    self.alloc.free(self.entries);
    for (self.frag_cache.values()) |v|
        self.alloc.free(v);
    self.frag_cache.deinit(self.alloc);
}

pub fn get(self: *FragManager, io: Io, idx: u32) ![]u8 {
    {
        try self.cache_mut.lockShared(io);
        defer self.cache_mut.unlockShared(io);
        if (self.frag_cache.contains(idx))
            return self.frag_cache.get(idx).?;
    }

    try self.cache_mut.lock(io);
    defer self.cache_mut.unlock(io);

    if (self.frag_cache.contains(idx))
        return self.frag_cache.get(idx).?;

    const entry = self.entries[idx];

    const out = try self.alloc.alloc(u8, if (entry.size.uncompressed) entry.size.size else self.block_size);

    if (entry.size.uncompressed) {
        @memcpy(out, self.fil.map.memory[entry.start .. entry.start + entry.size.size]);
    } else {
        @branchHint(.likely);
        _ = try self.decomp.Decompress(self.alloc, self.fil.map.memory[entry.start .. entry.start + entry.size.size], out);
    }

    try self.frag_cache.put(self.alloc, idx, out);
    return out;
}
