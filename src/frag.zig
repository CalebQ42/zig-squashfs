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
decomp: *const Decompressor,
block_size: u32,

entries: []FragEntry,

frag_cache: std.array_hash_map.Auto(u32, []u8),
cache_mut: std.Io.Mutex = .init,

pub fn init(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, frag_start: u64, frag_num: u32, block_size: u32) !FragManager {
    var buf: [8 * 1024]u8 = undefined;
    var rdr = try fil.readerAt(io, frag_start, &buf);
    var first_offset: u64 = undefined;
    try rdr.interface.readSliceEndian(u64, @ptrCast(&first_offset), .little);

    rdr = try fil.readerAt(io, first_offset, &buf);
    var meta: MetadataReader = .init(alloc, &rdr.interface, decomp);

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
    if (self.frag_cache.contains(idx))
        return self.frag_cache.get(idx).?;

    try self.cache_mut.lock(io);
    defer self.cache_mut.unlock(io);

    const entry = self.entries[idx];

    const out = try self.alloc.alloc(u8, if (entry.size.uncompressed) entry.size.size else self.block_size);

    var buf: [1024 * 1024]u8 = undefined;
    var rdr = try self.fil.readerAt(io, entry.start, &buf);
    if (entry.size.uncompressed) {
        try rdr.interface.readSliceAll(out);
    } else {
        @branchHint(.likely);
        try rdr.interface.fill(entry.size.size);
        _ = try self.decomp.Decompress(self.alloc, buf[0..entry.size.size], out);
    }

    try self.frag_cache.put(self.alloc, idx, out);
    return out;
}
