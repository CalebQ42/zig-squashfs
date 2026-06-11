const std = @import("std");
const Io = std.Io;

const Decomp = @import("decomp.zig");
const MetadataReader = @import("meta_rdr.zig");
const ProtectedMap = @import("util/protected_map.zig");

pub fn Table(comptime T: anytype) type {
    return struct {
        const VALUES_PER_BLOCK = 8192 / @sizeOf(T);

        const Self = @This();

        data: []u8,
        decomp: Decomp.Fn,

        table_start: u64,
        table_num: u32,

        table: ProtectedMap(u32, []T, getBlock),

        pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, table_start: u64, table_num: u32) Self {
            return .{ .data = data, .decomp = decomp, .table_start = table_start, .table_num = table_num, .table = .init(alloc) };
        }
        pub fn deinit(self: *Self) void {
            var iter = self.table.map.valueIterator();

            while (iter.next()) |val| {
                if (val.err != null) continue;

                self.table.alloc.free(val.value);
            }
            self.table.deinit();
        }

        pub fn get(self: *Self, io: Io, idx: u32) !T {
            const block = idx / VALUES_PER_BLOCK;
            const block_idx = idx % VALUES_PER_BLOCK;

            const values = try self.table.getOrPut(io, block, .{ self.*, block });

            return values[block_idx];
        }

        pub fn getBlock(self: Self, block_idx: u32) ![]T {
            const offset: u64 = std.mem.readInt(u64, self.data[self.table_start + (block_idx * 8) ..][0..8], .little);

            const block = try self.table.alloc(T, if (block_idx == (self.table_num - 1 / VALUES_PER_BLOCK))
                self.table_num % VALUES_PER_BLOCK
            else
                VALUES_PER_BLOCK);

            var meta: MetadataReader = .init(self.table.alloc, self.data, self.decomp, offset);
            try meta.interface.readSliceEndian(T, block, .little);

            return block;
        }
    };
}
