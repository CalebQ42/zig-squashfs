const std = @import("std");
const Io = std.Io;

const Decompressor = @import("util/decompressor.zig");
const OffsetFile = @import("util/offset_file.zig");
const MetadataReader = @import("util/metadata.zig");

pub fn lookupValue(comptime T: anytype, alloc: std.mem.Allocator, io: Io, decomp: *Decompressor, file: OffsetFile, table_start: u64, idx: u16) !T {
    const T_PER_BLOCK: u16 = 8192 / @sizeOf(T);

    const block = idx / T_PER_BLOCK;
    const block_offset = idx % T_PER_BLOCK;

    var rdr = try file.readerAt(io, table_start + (8 * block), &[0]u8{});
    var offset: u64 = undefined;
    try rdr.interface.readSliceEndian(u64, @ptrCast(&offset), .little);

    rdr = try file.readerAt(io, offset, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr, decomp);

    try meta.interface.discardAll(@sizeOf(T) * block_offset);
    var out: T = undefined;
    try meta.interface.readSliceEndian(T, @ptrCast(&out), .little);
    return out;
}

pub fn CachedTable(comptime T: anytype) type {
    return struct {
        const T_PER_BLOCK: u16 = 8192 / @sizeOf(T);

        const Table = @This();

        alloc: std.mem.Allocator,
        fil: OffsetFile,
        table_start: u64,
        total_num: u32,

        table: std.AutoHashMap(u32, []T),

        mut: Io.Mutex = .init,

        pub fn init(alloc: std.mem.Allocator, fil: OffsetFile, offset: u64, total_num: u32) Table {
            return .{
                .alloc = alloc,
                .fil = fil,
                .table_start = offset,
                .total_num = total_num,

                .table = .init(alloc),
            };
        }

        pub fn get(self: *Table, io: Io, idx: u32) !T {
            const block = idx / T_PER_BLOCK;
            const block_offset = idx % T_PER_BLOCK;
            if (self.table.contains(block))
                return self.table.get(block).?[block_offset];

            try self.mut.lock(io);
            defer self.mut.unlock(io);

            if (self.table.contains(block))
                return self.table.get(block).?[block_offset];

            var rdr = try self.fil.readerAt(io, self.table_start + (8 * block), &[0]u8{});
            var offset: u64 = undefined;
            try rdr.interface.readSliceEndian(u64, @ptrCast(&offset), .little);

            const len: u16 = if (self.total_num % T_PER_BLOCK != 0 and block == (self.total_num - 1) / T_PER_BLOCK)
                self.total_num % T_PER_BLOCK
            else
                T_PER_BLOCK;

            rdr = try self.fil.readerAt(io, offset, &[0]u8{});
            var meta: MetadataReader = .init(self.alloc, &rdr, self.decomp);

            try self.table.put(block, try meta.interface.readSliceEndianAlloc(self.alloc, T, len, .little));
        }
    };
}
