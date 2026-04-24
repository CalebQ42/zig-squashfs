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

const InodeRef = @import("inode.zig").Ref;

const XattrLookup = packed struct {
    // This isn't actuall an inode ref, but is stored that exact same way.
    ref: InodeRef,
    kv_count: u32,
    size: u32,
};

const XattrKey = packed struct {
    type: enum(u2) {
        user,
        trusted,
        security,
    },
    out_of_line: bool,
    _: u13,
    name_size: u16,
};

pub const XattrValues = std.AutoHashMap([:0]u8, []u8);

pub fn statelessXattr(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *const Decompressor, table_start: u64, idx: u32) !XattrValues {
    const xattr_start = try fil.valueAt(u64, table_start);
    const block = idx / 512;
    const block_idx = idx % 512;

    const block_start = try fil.valueAt(u64, table_start + 8 + (block * 8));
    var rdr = try fil.readerAt(block_start, &[0]u8{});
    var meta_rdr: MetadataReader = .init(&rdr.interface, decomp);
    try meta_rdr.interface.discardAll(16 * block_idx);

    var lookup: XattrLookup = undefined;
    try meta_rdr.interface.readSliceEndian(XattrLookup, @ptrCast(&lookup), .little);

    rdr = try fil.readerAt(xattr_start + lookup.ref.block_start, &[0]u8{});
    meta_rdr = .init(&rdr.interface, decomp);
    try meta_rdr.interface.discardAll(lookup.ref.block_offset);

    var out: XattrValues = try .init(alloc);
    for (0..lookup.kv_count) |_| {
        var key: XattrKey = undefined;
        try meta_rdr.interface.readSliceEndian(XattrKey, @ptrCast(&key), .little);
        const prefix_size = switch (key.type) {
            .user => 4,
            .trusted => 7,
            .security => 8,
        };
        const name: [:0]u8 = try alloc.alloc(u8, prefix_size + key.name_size + 1);
        name[prefix_size + key.name_size] = 0;
        try meta_rdr.interface.readSliceEndian(u8, name[prefix_size .. prefix_size + key.name_size], .little);
        switch (key.type) {
            .user => @memcpy(name[0..4], "user"),
            .trusted => @memcpy(name[0..7], "trusted"),
            .security => @memcpy(name[0..8], "security"),
        }
        if (key.out_of_line) {
            try meta_rdr.interface.discardAll(4);
            var value_offset: InodeRef = undefined;
            try meta_rdr.interface.readSliceEndian(InodeRef, @ptrCast(&value_offset), .little);

            var value_rdr = try fil.readerAt(xattr_start + value_offset.block_start, &[0]u8{});
            var value_meta: MetadataReader = .init(&value_rdr.interface, decomp);
            try value_meta.interface.discardAll(value_offset.block_offset);

            var val_size: u32 = undefined;
            try value_meta.interface.readSliceEndian(u32, @ptrCast(&val_size), .little);
            const value = try alloc.alloc(u8, val_size);
            try value_meta.interface.readSliceEndian(u8, value, .little);
            try out.put(name, value);
        } else {
            var val_size: u32 = undefined;
            try meta_rdr.interface.readSliceEndian(u32, @ptrCast(&val_size), .little);
            const value = try alloc.alloc(u8, val_size);
            try meta_rdr.interface.readSliceEndian(u8, value, .little);
            try out.put(name, value);
        }
    }
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
