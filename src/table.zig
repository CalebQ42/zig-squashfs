const std = @import("std");
const Io = std.Io;

const util = @import("utils/util.zig");

const MetadataReader = @import("utils/meta.zig");
const Decomp = @import("decomp.zig");

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        const ITEMS_PER_BLOCK = 8192 / @sizeOf(T);

        alloc: std.mem.Allocator,

        data: []u8,
        decomp: Decomp.Fn,

        start: u64,
        count: u32,
        block_count: u32,

        table: std.hash_map.AutoHashMapUnmanaged(u32, []T) = .empty,
        mut: Io.Mutex = .init,

        pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, start: u64, count: u32) !Self {
            return .{
                .alloc = alloc,

                .data = data,
                .decomp = decomp,

                .start = start,
                .count = count,
                .block_count = std.math.divCeil(u32, count, ITEMS_PER_BLOCK),
            };
        }
        pub fn deinit(self: *Self) void {
            var iter = self.table.valueIterator();
            while (iter.next()) |block|
                self.alloc.free(block);

            self.table.deinit(self.alloc);
        }

        fn getBlock(self: *Self, io: Io, idx: u32) ![]T {
            const init_get = self.table.get(idx);
            if (init_get != null) return init_get.?;

            self.mut.lock(io);
            defer self.mut.unlock(io);

            const start = util.readValue(u64, self.data[self.start + (idx * 8) ..][0..8]);

            const len = if (idx == self.block_count - 1) self.count % ITEMS_PER_BLOCK else ITEMS_PER_BLOCK;

            const new_block = try self.alloc.alloc(T, len);
            errdefer self.alloc.free(new_block);

            var meta: MetadataReader = .init(self.alloc, self.data[start..], self.decomp);

            try meta.interface.readSliceEndian(T, new_block, .little);

            try self.table.put(self.alloc, idx, new_block);

            return new_block;
        }

        pub fn get(self: *Self, io: Io, idx: u32) !T {
            if (idx >= self.count) return error.InvalidIndex;

            const block_idx = idx / ITEMS_PER_BLOCK;

            const block = self.getBlock(io, block_idx);

            return block[idx % ITEMS_PER_BLOCK];
        }
    };
}
