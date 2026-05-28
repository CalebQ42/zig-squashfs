const std = @import("std");
const Io = std.Io;

const Inode = @import("inode.zig");
const DecompCache = @import("util/decomp_cache.zig");
const MetadataReader = @import("util/metadata.zig");

pub fn lookup(comptime T: anytype, io: Io, cache: *DecompCache, table_start: u64, idx: u32) !T {
    const PER_BLOCK = 8192 / @sizeOf(T);

    const block_idx = idx / PER_BLOCK;
    const block_offset = idx % PER_BLOCK;

    if (table_start + (block_idx * 8) > cache.map.memory.len) return error.ReadFailed;
    const offset: u64 = std.mem.readInt(u64, cache.map.memory[table_start + (block_idx * 8) ..][0..8], .little);

    var meta: MetadataReader = .init(io, cache, offset);
    defer meta.deinit();
    try meta.interface.discardAll(block_offset * @sizeOf(T));

    var new: T = undefined;
    try meta.interface.readSliceEndian(T, @ptrCast(&new), .little);
    return new;
}

pub const XattrKV = struct {
    key: [:0]u8,
    value: []u8,

    pub fn deinit(self: XattrKV, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
    }
};

const LookupValue = extern struct {
    ref: Inode.Ref,
    count: u32,
    size: u32,
};
const KeyEntry = extern struct {
    prefix: packed struct(u16) {
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

pub fn xattrLookup(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, xattr_start: u64, idx: u32) ![]XattrKV {
    const table_start = std.mem.readInt(u64, cache.map.memory[xattr_start..][0..8], .little);

    const val: LookupValue = try lookup(
        LookupValue,
        io,
        cache,
        xattr_start + 16,
        idx,
    );

    const out = try alloc.alloc(XattrKV, val.count);
    errdefer alloc.free(out);

    var meta: MetadataReader = .init(io, cache, table_start + val.ref.block_start);
    defer meta.deinit();
    try meta.interface.discardAll(val.ref.block_offset);

    for (out) |*kv| {
        var key_entry: KeyEntry = undefined;
        try meta.interface.readSliceEndian(KeyEntry, @ptrCast(&key_entry), .little);

        const prefix_len: u16 = switch (key_entry.prefix.prefix) {
            .user => 5,
            .trusted => 8,
            .security => 9,
        };
        var key_len = key_entry.name_size;
        key_len += prefix_len;

        kv.key = try alloc.allocSentinel(u8, key_len, 0);
        errdefer alloc.free(kv.key);

        try meta.interface.readSliceEndian(u8, kv.key[prefix_len..], .little);
        switch (key_entry.prefix.prefix) {
            .user => @memcpy(kv.key[0..prefix_len], "user."),
            .trusted => @memcpy(kv.key[0..prefix_len], "trusted."),
            .security => @memcpy(kv.key[0..prefix_len], "security."),
        }

        if (key_entry.prefix.out_of_line) {
            try meta.interface.discardAll(8);

            var ool_ref: Inode.Ref = undefined;
            try meta.interface.readSliceEndian(Inode.Ref, @ptrCast(&ool_ref), .little);

            var ool_meta: MetadataReader = .init(io, cache, table_start + ool_ref.block_start);
            defer ool_meta.deinit();
            try ool_meta.interface.discardAll(ool_ref.block_offset);

            kv.value = try readValue(alloc, &ool_meta.interface);
            errdefer alloc.free(kv.value);
        } else {
            kv.value = try readValue(alloc, &meta.interface);
        }
    }

    return out;
}

fn readValue(alloc: std.mem.Allocator, rdr: *Io.Reader) ![]u8 {
    var val_size: u32 = undefined;
    try rdr.readSliceEndian(u32, @ptrCast(&val_size), .little);

    const val = try alloc.alloc(u8, val_size);
    errdefer alloc.free(val);

    try rdr.readSliceEndian(u8, val, .little);

    return val;
}
