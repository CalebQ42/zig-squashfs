const std = @import("std");
const Io = std.Io;

const OffsetFile = @import("util/offset_file.zig");
const MetadataReader = @import("util/metadata.zig");

pub fn CachedTable(comptime T: anytype) type {
    return struct {
        const T_PER_BLOCK: u16 = 8192 / @sizeOf(T);

        const Table = @This();

        alloc: std.mem.Allocator,
        io: Io,
        fil: OffsetFile,
        table_start: u64,
        total_num: u32,

        table: std.AutoHashMap(u32, []T),

        mut: Io.Mutex = .init,

        pub fn init(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, offset: u64, total_num: u32) Table {
            return .{
                .alloc = alloc,
                .io = io,
                .fil = fil,
                .table_start = offset,
                .total_num = total_num,

                .table = .init(alloc),
            };
        }

        pub fn get(self: *Table, idx: u32) !T {
            const block = idx / T_PER_BLOCK;
            const block_offset = idx % T_PER_BLOCK;
            if (self.table.contains(block))
                return self.table.get(block).?[block_offset];

            try self.mut.lock(self.io);
            defer self.mut.unlock(self.io);

            if (self.table.contains(block))
                return self.table.get(block).?[block_offset];

            var rdr = try self.fil.readerAt(self.io, self.table_start + (8 * block), &[0]u8{});
            var offset: u64 = undefined;
            try rdr.interface.readSliceEndian(u64, @ptrCast(&offset), .little);

            const arr_num: u16 = if (self.total_num % T_PER_BLOCK != 0 and block == (self.total_num - 1) / T_PER_BLOCK)
                self.total_num % T_PER_BLOCK
            else
                T_PER_BLOCK;

            rdr = try self.fil.readerAt(self.io, offset, &[0]u8{});
            var meta: MetadataReader = .init(self.alloc, &rdr, self.decomp);

            try self.table.put(
                block,
                try meta.interface.readSliceEndianAlloc(self.alloc, T, arr_num, .little),
            );
        }
    };
}
