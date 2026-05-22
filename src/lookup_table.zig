const std = @import("std");
const Io = std.Io;

const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

pub fn lookupValue(comptime T: anytype, alloc: std.mem.Allocator, decomp: *const Decompressor, file: OffsetFile, table_start: u64, idx: u32) !T {
    const T_PER_BLOCK: u16 = 8192 / @sizeOf(T);

    const block = idx / T_PER_BLOCK;
    const block_offset = idx % T_PER_BLOCK;

    const offset_pos = table_start + (8 * block);
    const offset: u64 = std.mem.readInt(u64, file.map.memory[offset_pos .. offset_pos + 8], .little);

    var rdr = file.readerAt(offset);
    var meta: MetadataReader = .init(alloc, &rdr, decomp);

    try meta.interface.discardAll(@sizeOf(T) * block_offset);
    var out: T = undefined;
    try meta.interface.readSliceEndian(T, @ptrCast(&out), .little);
    return out;
}

pub const Error = Io.Cancelable || Io.File.Reader.SeekError || Io.Reader.ReadAllocError;

pub fn CachedTable(comptime T: anytype) type {
    return struct {
        const T_PER_BLOCK: u16 = 8192 / @sizeOf(T);

        const Table = @This();

        alloc: std.mem.Allocator,
        fil: OffsetFile,
        decomp: *const Decompressor,

        table_start: u64,
        total_num: u32,

        table: std.AutoHashMap(u32, []T),

        mut: Io.RwLock = .init,

        pub fn init(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *const Decompressor, offset: u64, total_num: u32) Table {
            return .{
                .alloc = alloc,
                .fil = fil,
                .decomp = decomp,

                .table_start = offset,
                .total_num = total_num,

                .table = .init(alloc),
            };
        }
        pub fn deinit(self: *Table, io: Io) void {
            self.mut.lockUncancelable(io);
            var iter = self.table.valueIterator();
            while (iter.next()) |val|
                self.alloc.free(val.*);
            self.table.deinit();
        }

        pub fn fill(self: *Table, io: Io) Error!void {
            try self.mut.lock(io);
            defer self.mut.unlock(io);

            var num_blocks = self.total_num / T_PER_BLOCK;
            if (self.total_num % T_PER_BLOCK > 0)
                num_blocks += 1;

            for (0..num_blocks) |block| {
                const offset_pos = self.table_start + (8 * block);
                const offset: u64 = std.mem.readInt(u64, self.fil.map.memory[offset_pos .. offset_pos + 8], .little);

                const len: u16 = if (self.total_num % T_PER_BLOCK != 0 and block == (self.total_num - 1) / T_PER_BLOCK)
                    @truncate(self.total_num % T_PER_BLOCK)
                else
                    T_PER_BLOCK;

                var rdr = self.fil.readerAt(offset);
                var meta: MetadataReader = .init(self.alloc, &rdr.interface, self.decomp);

                const slice = try meta.interface.readSliceEndianAlloc(self.alloc, T, len, .little);
                try self.table.put(@truncate(block), slice);
            }
        }

        pub fn get(self: *Table, io: Io, idx: u32) Error!T {
            const block = idx / T_PER_BLOCK;
            const block_offset = idx % T_PER_BLOCK;

            {
                try self.mut.lockShared(io);
                defer self.mut.unlockShared(io);

                if (self.table.contains(block))
                    return self.table.get(block).?[block_offset];
            }

            try self.mut.lock(io);
            defer self.mut.unlock(io);

            if (self.table.contains(block))
                return self.table.get(block).?[block_offset];

            const offset_pos = self.table_start + (8 * block);
            const offset: u64 = std.mem.readInt(u64, self.fil.map.memory[offset_pos .. offset_pos + 8], .little);

            const len: u16 = if (self.total_num % T_PER_BLOCK != 0 and block == (self.total_num - 1) / T_PER_BLOCK)
                @truncate(self.total_num % T_PER_BLOCK)
            else
                T_PER_BLOCK;

            var rdr = self.fil.readerAt(offset);
            var meta: MetadataReader = .init(self.alloc, &rdr.interface, self.decomp);

            const slice = try meta.interface.readSliceEndianAlloc(self.alloc, T, len, .little);
            try self.table.put(@truncate(block), slice);

            return slice[block_offset];
        }
    };
}
