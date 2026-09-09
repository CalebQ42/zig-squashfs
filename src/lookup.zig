const std = @import("std");
const Io = std.Io;

const Decomp = @import("decomp.zig");
const Reference = @import("inode.zig").Reference;
const MetadataReader = @import("utils/meta.zig");
const util = @import("utils/util.zig");

pub fn Value(comptime T: type, alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, table_start: u64, idx: u32) !T {
    const ITEMS_PER_BLOCK = 8192 / @sizeOf(T);

    const block_idx = idx / ITEMS_PER_BLOCK;
    const value_idx = idx % ITEMS_PER_BLOCK;

    const start = util.readValue(u64, data[table_start + (block_idx * 8) ..][0..8]);

    var meta: MetadataReader = .init(alloc, data[start..], decomp);
    try meta.interface.discardAll(value_idx * @sizeOf(T));

    return util.readValueRdr(T, &meta.interface);
}

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        const ITEMS_PER_BLOCK = 8192 / @sizeOf(T);

        data: []u8,
        decomp: Decomp.Fn,

        start: u64,
        count: u32,
        block_count: u32,

        table: std.hash_map.AutoHashMapUnmanaged(u32, []T) = .empty,
        mut: Io.Mutex = .init,

        pub fn init(data: []u8, decomp: Decomp.Fn, start: u64, count: u32) !Self {
            return .{
                .data = data,
                .decomp = decomp,

                .start = start,
                .count = count,
                .block_count = try std.math.divCeil(u32, count, ITEMS_PER_BLOCK),
            };
        }
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            var iter = self.table.valueIterator();
            while (iter.next()) |block|
                alloc.free(block.*);

            self.table.deinit(alloc);
        }

        pub fn get(self: *Self, alloc: std.mem.Allocator, io: Io, idx: u32) !T {
            if (idx >= self.count) return error.InvalidIndex;

            const block_idx = idx / ITEMS_PER_BLOCK;
            const value_idx = idx % ITEMS_PER_BLOCK;

            const init_get = self.table.get(block_idx);
            if (init_get != null) return init_get.?[value_idx];

            try self.mut.lock(io);
            defer self.mut.unlock(io);

            const start = util.readValue(u64, self.data[self.start + (block_idx * 8) ..][0..8]);

            const len = if (block_idx == self.block_count - 1) self.count % ITEMS_PER_BLOCK else ITEMS_PER_BLOCK;

            const new_block = try alloc.alloc(T, len);
            errdefer alloc.free(new_block);

            var meta: MetadataReader = .init(alloc, self.data[start..], self.decomp);

            try meta.interface.readSliceEndian(T, new_block, .little);

            try self.table.put(alloc, block_idx, new_block);

            return new_block[value_idx];
        }
    };
}

pub const Xattr = struct {
    kv_start: u64,
    lookup: Table(XattrLookup),

    pub fn init(data: []u8, decomp: Decomp.Fn, start: u64) !Xattr {
        const kv_start = util.readValue(u64, data[start..][0..8]);
        const count = util.readValue(u32, data[start..][8..12]);

        return .{
            .kv_start = kv_start,
            .lookup = try .init(data, decomp, start + 16, count),
        };
    }
    pub fn deinit(self: *Xattr, alloc: std.mem.Allocator) void {
        self.lookup.deinit(alloc);
    }

    pub fn get(self: *Xattr, alloc: std.mem.Allocator, io: Io, idx: u32) ![]KV {
        const lookup = try self.lookup.get(alloc, io, idx);

        var meta: MetadataReader = .init(alloc, self.lookup.data[self.kv_start + lookup.ref.start ..], self.lookup.decomp);
        try meta.interface.discardAll(lookup.ref.offset);

        const kvs = try alloc.alloc(KV, lookup.count);
        errdefer alloc.free(kvs);

        for (kvs) |*kv| {
            const entry = try util.readValueRdr(KeyEntry, &meta.interface);

            const prefix = switch (entry.type.type) {
                .user => "user.",
                .trusted => "trusted.",
                .security => "security.",
            };

            kv.name = try alloc.allocSentinel(u8, entry.name_size + prefix.len, 0);
            errdefer alloc.free(kv.name);

            try meta.interface.readSliceEndian(u8, kv.name[prefix.len..], .little);

            @memcpy(kv.name[0..prefix.len], prefix);

            var value_meta = if (entry.type.out_of_line) blk: {
                const ool_ref = try util.readValueRdr(Reference, &meta.interface);

                var ool_meta: MetadataReader = .init(alloc, self.lookup.data[self.kv_start + ool_ref.start ..], self.lookup.decomp);
                try ool_meta.interface.discardAll(ool_ref.offset);

                break :blk ool_meta;
            } else meta;

            const value_len = try util.readValueRdr(u32, &value_meta.interface);

            kv.value = try alloc.alloc(u8, value_len);
            errdefer alloc.free(kv.value);

            try value_meta.interface.readSliceEndian(u8, kv.value, .little);
        }

        return kvs;
    }

    //types

    pub const KV = struct {
        name: [:0]u8,
        value: []u8,

        pub fn deinit(self: KV, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            alloc.free(self.value);
        }
    };

    const XattrLookup = extern struct {
        ref: Reference,
        count: u32,
        size: u32,
    };

    const KeyEntry = extern struct {
        type: packed struct(u16) {
            type: enum(u8) {
                user,
                trusted,
                security,
            },
            out_of_line: bool,
            _: u7,
        },
        name_size: u16,
    };
};
