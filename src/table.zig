const std = @import("std");
const Mutex = std.Thread.Mutex;

const DecompFn = @import("decomp.zig").DecompFn;
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const TableError = error{
    InvalidIndex,
};

/// A two-layer metadata table.
pub fn Table(T: anytype) type {
    return struct {
        const Self = @This();

        const VALS_PER_BLOCK = 8192 / @sizeOf(T);

        fil: OffsetFile,
        decomp: DecompFn,

        tab_start: u64,
        values: u32,

        pub fn init(fil: OffsetFile, decomp: DecompFn, tab_start: u64, values: u32) Self {
            return .{
                .fil = fil,
                .decomp = decomp,

                .tab_start = tab_start,
                .values = values,
            };
        }

        pub fn get(self: Self, alloc: std.mem.Allocator, idx: u32) !T {
            const block_num = idx / VALS_PER_BLOCK;
            const idx_offset = idx - (block_num * VALS_PER_BLOCK);
            const is_last = (self.values - 1) / VALS_PER_BLOCK == block_num;
            const slice_size = if (is_last) self.values - (block_num * VALS_PER_BLOCK) else VALS_PER_BLOCK;
            var slice: [VALS_PER_BLOCK]T = undefined;
            var rdr = try self.fil.readerAt(self.tab_start + (8 * block_num), &[0]u8{});
            var offset: u64 = 0;
            try rdr.interface.readSliceEndian(u64, @ptrCast(&offset), .little);
            rdr = try self.fil.readerAt(offset, &[0]u8{});
            var meta: MetadataReader = .init(alloc, &rdr.interface, self.decomp);
            try meta.interface.readSliceEndian(T, slice[0..slice_size], .little);
            return slice[idx_offset];
        }
    };
}
