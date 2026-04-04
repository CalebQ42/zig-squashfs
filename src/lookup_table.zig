const std = @import("std");

const Decompressor = @import("decomp.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

pub fn stateless(comptime T: anytype, fil: OffsetFile, decomp: *const Decompressor, table_start: u64, idx: u32) !T {
    const VALS_PER_BLOCK = 8192 / @sizeOf(T);
    const block = idx / VALS_PER_BLOCK;
    const block_idx = idx % VALS_PER_BLOCK;

    const offset = try fil.valueAt(u64, table_start + (8 * block));
    var buf: [8192]u8 = undefined;
    var rdr = try fil.readerAt(offset, &buf);
    var meta_rdr: MetadataReader = .init(&rdr.interface, decomp);
    try meta_rdr.interface.discardAll(@sizeOf(T) * block_idx);

    var out: T = undefined;
    try meta_rdr.interface.readSliceEndian(T, @ptrCast(&out), .little);
    return out;
}

pub fn CachedTable(comptime T: anytype) type {
    return struct {
        const Self = @This();

        const VALS_PER_BLOCK = 8192 / @sizeOf(T);

        alloc: std.mem.Allocator,
        decomp: *const Decompressor,

        fil: OffsetFile,
        table_start: u64,
        num: u32,

        cache: std.AutoHashMap(u32, []T),
        cache_mut: std.Thread.Mutex = .{},

        pub fn init(alloc: std.mem.Allocator, decomp: *const Decompressor, fil: OffsetFile, table_offset: u64, num: u32) !Self {
            return .{
                .alloc = alloc,
                .decomp = decomp,

                .fil = fil,
                .table_start = table_offset,
                .num = num,

                .cache = .init(alloc),
            };
        }
        pub fn deinit(self: *Self) void {
            var values = self.cache.valueIterator();
            while (values.next()) |val|
                self.alloc.free(val);
            self.cache.deinit();
        }

        pub fn get(self: *Self, idx: u32) !T {
            const block = idx / VALS_PER_BLOCK;
            const block_idx = idx % VALS_PER_BLOCK;

            if (self.cache.get(block)) |val|
                return val[block_idx];

            self.cache_mut.lock();
            defer self.cache_mut.unlock();

            // Double check in case another thread was doing your work.
            if (self.cache.get(block)) |val|
                return val[block_idx];

            const offset = try self.fil.valueAt(u64, self.table_start + (8 * block));
            var buf: [8192]u8 = undefined;
            var rdr = try self.fil.readerAt(offset, &buf);
            var meta_rdr: MetadataReader = .init(&rdr.interface, self.decomp);
            const block_size = if (block == (self.num - 1) / VALS_PER_BLOCK)
                self.num % VALS_PER_BLOCK
            else
                VALS_PER_BLOCK;
            const new_block = try self.alloc.alloc(T, block_size);
            errdefer self.alloc.free(new_block);
            try meta_rdr.interface.readSliceEndian(T, new_block, .little);
            try self.cache.put(block, new_block);
            return new_block[block_idx];
        }
    };
}
