const std = @import("std");
const Io = std.Io;

const Decomp = @import("decomp.zig");
const Lookup = @import("lookup.zig");
const MetadataReader = @import("meta_rdr.zig");
const Ref = @import("inode.zig").Ref;

const XattrTable = @This();

table_start: u64,

table: Lookup.Table(Entry),

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, table_start: u64) XattrTable {
    const start = std.mem.readInt(u64, data[table_start..][0..8], .little);
    const table_num = std.mem.readInt(u32, data[table_start + 8 ..][0..4], .little);

    return .{
        .table_start = start,
        .table = .init(alloc, data, decomp, table_start + 16, table_num),
    };
}
pub fn deinit(self: *XattrTable) void {
    self.table.deinit();
}

pub fn get(self: *XattrTable, alloc: std.mem.Allocator, io: Io, idx: u32) !Xattr {
    const entry: Entry = try self.table.get(io, idx);

    var out: std.ArrayList(KeyValue) = try .initCapacity(alloc, entry.count);
    errdefer {
        for (out.items) |kv|
            kv.deinit(alloc);
        out.deinit(alloc);
    }

    var meta: MetadataReader = .init(alloc, self.table.data, self.table.decomp, self.table_start + entry.ref.block_start);
    try meta.interface.discardAll(entry.ref.block_offset);

    for (0..entry.count) |_| {
        var key_entry: KeyEntry = undefined;

        try meta.interface.readSliceEndian(KeyEntry, @ptrCast(&key_entry), .little);

        const prefix = switch (key_entry.type.type) {
            .user => "user.",
            .trusted => "trusted.",
            .security => "security.",
        };

        const key = try alloc.allocSentinel(u8, key_entry.name_size + prefix.len, 0);
        errdefer alloc.free(key);

        @memcpy(key[0..prefix.len], prefix);

        try meta.interface.readSliceEndian(u8, key[prefix.len..][0..key_entry.name_size], .little);

        const value = if (key_entry.type.out_of_line) blk: {
            try meta.interface.discardAll(4);

            var ref: Ref = undefined;
            try meta.interface.readSliceEndian(Ref, @ptrCast(&ref), .little);

            var value_meta: MetadataReader = .init(alloc, self.table.data, self.table.decomp, self.table_start + ref.block_start);
            try value_meta.interface.discardAll(ref.block_offset);

            break :blk try readValue(alloc, &value_meta.interface);
        } else try readValue(alloc, &meta.interface);

        const ptr = out.addOneAssumeCapacity();

        ptr.* = .{
            .key = key,
            .value = value,
        };
    }

    return .{ .kvs = try out.toOwnedSlice(alloc) };
}

fn readValue(alloc: std.mem.Allocator, rdr: *Io.Reader) ![]u8 {
    var size: u32 = undefined;
    try rdr.readSliceEndian(u32, @ptrCast(&size), .little);

    const value = try alloc.alloc(u8, size);
    errdefer alloc.free(value);

    try rdr.readSliceEndian(u8, value, .little);

    return value;
}

// Types

const Xattr = struct {
    kvs: []KeyValue,

    pub fn deinit(self: Xattr, alloc: std.mem.Allocator) void {
        for (self.kvs) |kv|
            kv.deinit(alloc);

        alloc.free(self.kvs);
    }
};

const KeyValue = struct {
    key: [:0]const u8,
    value: []const u8,

    pub fn deinit(self: KeyValue, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
    }
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

const Entry = extern struct {
    ref: Ref,
    count: u32,
    size: u32,
};
