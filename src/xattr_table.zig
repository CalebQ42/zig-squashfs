const std = @import("std");
const Io = std.Io;

const InodeRef = @import("inode.zig").Ref;
const LookupTable = @import("lookup_table.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const XattrCachedTable = @This();

alloc: std.mem.Allocator,

fil: OffsetFile,
decomp: *const Decompressor,

kv_start: u64,

table: LookupTable.CachedTable(TableValue),
value_cache: std.AutoHashMap(InodeRef, []const u8),
value_mut: Io.RWLock = .init,

pub fn init(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *const Decompressor, xattr_start: u64) !XattrCachedTable {
    const start: u64 = std.mem.readInt(u64, fil.map.memory[xattr_start .. xattr_start + 8], .little);
    const num: u64 = std.mem.readInt(u64, fil.map.memory[xattr_start + 8 .. xattr_start + 16], .little);

    return .{
        .alloc = alloc,

        .fil = fil,
        .decomp = decomp,

        .kv_start = start,

        .table = .init(alloc, fil, decomp, xattr_start + 16, num),
        .value_cache = .init(alloc),
    };
}
pub fn deinit(self: *XattrCachedTable, io: Io) void {
    self.table.deinit(io);
    self.value_cache.deinit();
}

pub fn get(self: *XattrCachedTable, alloc: std.mem.Allocator, io: Io, idx: u32) ![]XattrSemiOwned {
    const lookup = try self.table.get(io, idx);

    var rdr = self.fil.readerAt(self.kv_start + lookup.ref.block_start);
    var meta: MetadataReader = .init(alloc, &rdr.interface, self.decomp);
    try meta.interface.discardAll(lookup.ref.block_offset);

    const out = try alloc.alloc(XattrSemiOwned, lookup.count);
    errdefer alloc.free(out);

    for (0..lookup.count) |i| {
        var key_entry: KeyEntry = undefined;
        try meta.interface.readSliceEndian(KeyEntry, @ptrCast(&key_entry), .little);

        const key: [:0]u8 = switch (key_entry.type.namespace) {
            .user => blk: {
                const tmp = try alloc.alloc(u8, key_entry.name_size + 1 + 5);
                errdefer alloc.free(tmp);
                try meta.interface.readSliceEndian(u8, tmp[5 .. tmp.len - 1], .little);
                @memcpy(tmp[0..5], "user.");
                tmp[tmp.len - 1] = 0;
                break :blk @ptrCast(tmp);
            },
            .trusted => blk: {
                const tmp = try alloc.alloc(u8, key_entry.name_size + 1 + 8);
                errdefer alloc.free(tmp);
                try meta.interface.readSliceEndian(u8, tmp[8 .. tmp.len - 1], .little);
                @memcpy(tmp[0..8], "trusted.");
                tmp[tmp.len - 1] = 0;
                break :blk @ptrCast(tmp);
            },
            .security => blk: {
                const tmp = try alloc.alloc(u8, key_entry.name_size + 1 + 9);
                errdefer alloc.free(tmp);
                try meta.interface.readSliceEndian(u8, tmp[9 .. tmp.len - 1], .little);
                @memcpy(tmp[0..9], "security.");
                tmp[tmp.len - 1] = 0;
                break :blk @ptrCast(tmp);
            },
        };
        errdefer alloc.free(key);

        if (key_entry.type.out_of_line) {
            var value: ValueOutOfLineEntry = undefined;
            try meta.interface.readSliceEndian(ValueOutOfLineEntry, @ptrCast(&value), .little);

            out[i] = .{
                .key = key,
                .value = try self.valueAt(io, value.ref),
            };
            continue;
        }
        const val_ref: InodeRef = .{ .block_start = meta.cur_block_start, .block_offset = @truncate(meta.interface.seek) };

        try self.value_mut.lock(io);
        defer self.value_mut.unlock(io);
        if (self.value_cache.contains(val_ref)) {
            out[i] = .{
                .key = key,
                .value = try self.valueAt(io, val_ref),
            };
            continue;
        }

        var val_size: u32 = undefined;
        try meta.interface.readSliceEndian(u32, @ptrCast(&val_size), .little);

        const val = try self.alloc.alloc(u8, val_size);
        errdefer alloc.free(val);
        try meta.interface.readSliceEndian(u8, val, .little);

        try self.value_cache.put(val_ref, val);
        out[i] = .{
            .key = key,
            .value = val,
        };
    }
    return out;
}

fn valueAt(self: *XattrCachedTable, io: Io, ref: InodeRef) ![]const u8 {
    try self.value_mut.lock(io);
    defer self.value_mut.unlock(io);

    if (self.value_cache.contains(ref)) return self.value_cache.get(ref).?;

    var rdr = self.fil.readerAt(self.kv_start + ref.block_start);
    var meta: MetadataReader = .init(self.alloc, &rdr.interface, self.decomp);
    try meta.interface.discardAll(ref.block_offset);

    var val_size: u32 = undefined;
    try meta.interface.readSliceEndian(u32, @ptrCast(&val_size), .little);

    const val = try self.alloc.alloc(u8, val_size);
    errdefer self.alloc.free(val);
    try meta.interface.readSliceEndian(u8, val, .little);

    try self.value_cache.put(ref, val);
    return val;
}

// Types

/// An Xattr return value where the reciever only owns the key value.
pub const XattrSemiOwned = struct {
    key: [:0]const u8,
    value: []const u8,

    pub fn deinit(self: XattrSemiOwned, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
    }
};
/// An Xattr return value where the reciever owns both the key & value.
pub const XattrOwned = struct {
    key: [:0]const u8,
    value: []const u8,

    pub fn deinit(self: XattrSemiOwned, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
    }
};

const TableValue = extern struct {
    ref: InodeRef,
    count: u32,
    size: u32,
};

const KeyEntry = extern struct {
    type: XattrPrefix,
    name_size: u16,
};
const ValueOutOfLineEntry = extern struct {
    _: u32,
    ref: InodeRef,
};

const XattrPrefix = packed struct(u16) {
    namespace: enum(u8) {
        user,
        trusted,
        security,

        fn prefixSize(self: @This()) u16 {
            return switch (self) {
                .user => 5,
                .trusted => 8,
                .security => 9,
            };
        }
    },
    out_of_line: bool,
    _: u7,
};

// Stateless

pub fn statelessLookup(alloc: std.mem.Allocator, io: Io, decomp: *const Decompressor, fil: OffsetFile, table_start: u64, idx: u16) ![]XattrOwned {
    const kv_start: u64 = std.mem.readInt(u64, fil.map.memory[table_start .. table_start + 8], .little);

    const lookup = try LookupTable.lookupValue(TableValue, alloc, io, decomp, fil, table_start + 16, idx);

    var rdr = fil.readerAt(kv_start + lookup.ref.block_start);
    var meta: MetadataReader = .init(alloc, &rdr.interface, decomp);
    try meta.interface.discardAll(lookup.ref.block_offset);

    const out = try alloc.alloc(XattrOwned, lookup.count);
    errdefer alloc.free(out);

    for (0..lookup.count) |i| {
        const key_entry: KeyEntry = undefined;
        try meta.interface.readSliceEndian(KeyEntry, @ptrCast(&key_entry), .little);

        const key = switch (key_entry.type.namespace) {
            .user => blk: {
                const tmp = try alloc.alloc(u8, key_entry.name_size + 1 + 5);
                errdefer alloc.free(tmp);
                try meta.interface.readSliceEndian(u8, tmp[5 .. tmp.len - 1], .little);
                @memset(tmp[0..5], "user.");
                break :blk tmp;
            },
            .trusted => blk: {
                const tmp = try alloc.alloc(u8, key_entry.name_size + 1 + 8);
                errdefer alloc.free(tmp);
                try meta.interface.readSliceEndian(u8, tmp[8 .. tmp.len - 1], .little);
                @memset(tmp[0..8], "trusted.");
                break :blk tmp;
            },
            .security => blk: {
                const tmp = try alloc.alloc(u8, key_entry.name_size + 1 + 9);
                errdefer alloc.free(tmp);
                try meta.interface.readSliceEndian(u8, tmp[9 .. tmp.len - 1], .little);
                @memset(tmp[0..9], "security.");
                break :blk tmp;
            },
        };
        key[key.len - 1] = 0;
        errdefer alloc.free(key);

        if (key_entry.type.out_of_line) {
            const value: ValueOutOfLineEntry = undefined;
            try meta.interface.readSliceEndian(ValueOutOfLineEntry, @ptrCast(&value), .little);

            var ool_rdr = fil.readerAt(kv_start + value.ref.block_start);
            var ool_meta: MetadataReader = .init(alloc, &ool_rdr.interface, decomp);
            try ool_meta.interface.discardAll(value.ref.block_offset);

            var val_size: u32 = undefined;
            try ool_meta.interface.readSliceEndian(val_size, @ptrCast(&val_size), .little);

            const val = try alloc.alloc(u8, val_size);
            errdefer alloc.free(val);
            try ool_meta.interface.readSliceEndian(u8, val, .little);

            out[i] = .{
                .key = key,
                .value = val,
            };
            continue;
        }

        var val_size: u32 = undefined;
        try meta.interface.readSliceEndian(val_size, @ptrCast(&val_size), .little);

        const val = try alloc.alloc(u8, val_size);
        errdefer alloc.free(val);
        try meta.interface.readSliceEndian(u8, val, .little);

        out[i] = .{
            .key = key,
            .value = val,
        };
    }
    return out;
}
