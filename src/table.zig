const std = @import("std");
const Mutex = std.Thread.Mutex;

const DecompMgr = @import("decomp.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const TableError = error{
    InvalidIndex,
};

pub fn Table(T: anytype) type {
    return struct {
        const This = @This();

        const VALS_PER_BLOCK = 8192 / @sizeOf(T);

        alloc: std.mem.Allocator,
        fil: OffsetFile,
        decomp: *DecompMgr,
        tab_start: u64,

        mut: Mutex = .{},

        tab: std.AutoHashMap(u32, []T),
        values: u32,

        pub fn init(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *DecompMgr, tab_start: u64, values: u32) !This {
            return .{
                .alloc = alloc,
                .fil = fil,
                .decomp = decomp,
                .tab_start = tab_start,

                .tab = .init(alloc),
                .values = values,
            };
        }

        pub fn deinit(self: *This) void {
            self.tab.deinit();
        }

        pub fn get(self: *This, idx: u32) !T {
            if (idx >= self.values) return TableError.InvalidIndex;
            const block_num = idx / VALS_PER_BLOCK;
            const idx_offset = idx - (block_num * VALS_PER_BLOCK);
            if (self.tab.contains(block_num)) {
                const block = self.tab.get(block_num).?;
                return block[idx_offset];
            }
            self.mut.lock();
            defer self.mut.unlock();
            // Double check in case of race condition..
            if (self.tab.contains(block_num)) {
                const block = self.tab.get(block_num).?;
                return block[idx_offset];
            }
            const is_last = (self.values - 1) / VALS_PER_BLOCK == block_num;
            const slice_size = if (is_last) self.values - (block_num * VALS_PER_BLOCK) else VALS_PER_BLOCK;
            const slice = try self.alloc.alloc(slice_size);
            var rdr = try self.fil.readerAt(self.tab_start + (8 * block_num), &[0]u8{});
            const offset: u64 = 0;
            try rdr.interface.readSliceAll(@ptrCast(&idx_offset));
            rdr = try self.fil.readerAt(offset, &[0]u8{});
            var meta: MetadataReader = .init(&rdr.interface, self.decomp);
            try meta.interface.readSliceAll(@ptrCast(slice));
            //TODO: read & decompress block.
            self.tab.put(block_num, slice);
        }
    };
}
