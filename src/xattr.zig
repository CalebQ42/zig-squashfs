const std = @import("std");
const Io = std.Io;

const DecompCache = @import("decomp_cache.zig");
const InodeRef = @import("inode.zig").Ref;
const MetadataReader = @import("meta_rdr.zig");
const XattrEntryTable = @import("lookup.zig").Table(XattrEntry);

const XattrTable = @This();

table_start: u64,

table: XattrEntryTable,

pub fn init(alloc: std.mem.Allocator, cache: *DecompCache, xattr_start: u64) !XattrTable {
    const table_start = std.mem.readInt(u64, cache.map.memory[xattr_start..][0..8], .little);
    const num = std.mem.readInt(u32, cache.map.memory[xattr_start + 8 ..][0..4], .little);
    return .{
        .table_start = table_start,

        .table = .init(alloc, cache, xattr_start + 16, num),
    };
}

pub fn get(self: XattrTable, alloc: std.mem.Allocator, io: Io, idx: u32) !XattrKVs {
    const entry = try self.table.get(io, idx);

    var meta: MetadataReader = .init(io, self.table.cache, self.table_start + entry.ref.block_start);
    defer meta.deinit(io);
    try meta.interface.discardAll(entry.ref.block_offset);

    const xattrs = try alloc.alloc(Xattr, entry.count);
    errdefer alloc.free(xattrs);

    for (xattrs) |*x| {
        var key: KeyEntry = undefined;
        try meta.interface.readSliceEndian(KeyEntry, @ptrCast(&key), .little);

        key.name_size += switch (key.type.prefix) {
            .user => 5,
            .trusted => 8,
            .security => 9,
        };
        x.key = try alloc.allocSentinel(u8, key.name_size, 0);
        errdefer alloc.free(x.key);

        switch (key.type.prefix) {
            .user => @memcpy(x.key[0..5], "user."),
            .trusted => @memcpy(x.key[0..8], "trusted."),
            .security => @memcpy(x.key[0..9], "security."),
        }

        if (!key.type.out_of_line) {
            var size: u32 = undefined;
            try meta.interface.readSliceEndian(u32, @ptrCast(&size), .little);

            x.value = try alloc.alloc(u8, size);
            errdefer alloc.free(x.value);

            try meta.interface.readSliceEndian(u8, x.value, .little);
            continue;
        }
        try meta.interface.discardAll(4);

        var val_ref: InodeRef = undefined;
        try meta.interface.readSliceEndian(InodeRef, @ptrCast(&val_ref), .little);

        var val_meta: MetadataReader = .init(io, self.table.cache, self.table_start + val_ref.block_start);
        defer val_meta.deinit(io);
        try val_meta.interface.discardAll(val_ref.block_offset);

        var size: u32 = undefined;
        try val_meta.interface.readSliceEndian(u32, @ptrCast(&size), .little);

        x.value = try alloc.alloc(u8, size);
        errdefer alloc.free(x.value);

        try val_meta.interface.readSliceEndian(u8, x.value, .little);
    }

    return .{ .xattrs = xattrs };
}

// Types

pub const XattrKVs = struct {
    xattrs: []Xattr,

    pub fn deinit(self: XattrKVs, alloc: std.mem.Allocator) void {
        for (self.xattrs) |kv|
            kv.deinit(alloc);
        alloc.free(self.xattrs);
    }
};
pub const Xattr = struct {
    key: [:0]u8,
    value: []u8,

    pub fn deinit(self: Xattr, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
    }
};
const KeyEntry = extern struct {
    type: packed struct(u16) {
        prefix: enum(u8) {
            user,
            trusted,
            security,
        },
        out_of_line: bool,
        _: u7,
    },
    name_size: u16,
};

const XattrEntry = extern struct {
    ref: InodeRef,
    count: u32,
    size: u32,
};
