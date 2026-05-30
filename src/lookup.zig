const std = @import("std");
const Io = std.Io;

const DataBlock = @import("inode.zig").DataBlock;
const InodeRef = @import("inode.zig").Ref;
const DecompCache = @import("decomp_cache.zig");
const MetadataReader = @import("meta_rdr.zig");

pub fn stateless(comptime T: anytype, io: Io, cache: *DecompCache, table_start: u64, idx: u32) !T {
    const PER_BLOCK = 8192 / @sizeOf(T);

    const block = idx / PER_BLOCK;
    const block_idx = idx % PER_BLOCK;

    const offset_offset = table_start + (block * 8);
    const offset: u64 = std.mem.readInt(u64, cache.map.memory[offset_offset..][0..2], .little);

    var meta: MetadataReader = .init(io, cache, offset);
    defer meta.deinit(io);
    try meta.discardAll(block_idx * @sizeOf(T));

    var new: T = undefined;
    try meta.interface.readSliceEndian(T, @ptrCast(&new), .little);
    return new;
}

pub fn Table(comptime T: anytype) type {
    return struct {
        const PER_BLOCK = 8192 / @sizeOf(T);

        const LookupTable = @This();

        alloc: std.mem.Allocator,

        cache: *DecompCache,
        table_start: u64,

        num: u32,
        values: std.AutoHashMap(u32, []T),
        mut: Io.RwLock = .init,

        pub fn init(alloc: std.mem.Allocator, cache: *DecompCache, table_start: u64, num_values: u32) LookupTable {
            return .{
                .alloc = alloc,

                .cache = cache,
                .table_start = table_start,

                .num = num_values,
                .values = .init(alloc),
            };
        }
        pub fn deinit(self: *LookupTable) void {
            var iter = self.values.valueIterator();
            while (iter.next()) |v|
                self.alloc.free(v);
            self.values.deinit();
        }

        pub fn get(self: *LookupTable, io: Io, idx: u32) Error!T {
            const block = idx / PER_BLOCK;
            const block_idx = idx % PER_BLOCK;
            {
                try self.mut.lockShared(io);
                defer self.mut.unlockShared(io);

                const val = self.values.get(block);
                if (val != null) return val.*[block_idx];
            }
            try self.mut.lock(io);
            defer self.mut.unlock(io);

            const val = try self.values.getOrPut(block);
            if (val.found_existing)
                return val.value_ptr.*[block_idx];
            errdefer self.values.removeByPtr(val.key_ptr);

            const offset_offset = self.table_start + (block * 8);
            const offset: u64 = std.mem.readInt(u64, self.cache.map.memory[offset_offset..][0..2], .little);

            var meta: MetadataReader = .init(io, self.cache, offset);
            defer meta.deinit(io);

            const size = if (block == ((self.num - 1) / PER_BLOCK))
                self.num % PER_BLOCK
            else
                PER_BLOCK;

            const new_block = try self.alloc.alloc(T, size);
            errdefer self.alloc.free(new_block);
            try meta.interface.readSliceEndian(T, new_block, .little);

            val.value_ptr.* = new_block;

            return new_block[block_idx];
        }
    };
}

// Types

pub const Error = error{} || std.mem.Allocator.Error;

pub const FragmentEntry = extern struct {
    start: u64,
    size: DataBlock,
    _: u32,
};

pub const XattrEntry = extern struct {
    ref: InodeRef,
    count: u32,
    size: u32,
};
