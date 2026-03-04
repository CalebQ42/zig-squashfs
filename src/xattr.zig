const std = @import("std");

const DecompFn = @import("decomp.zig").DecompFn;
const Table = @import("table.zig").Table;
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const Ref = packed struct {
    block_offset: u16,
    block_start: u32,
    _: u16,
};
const Entry = packed struct {
    ref: Ref,
    count: u32,
    size: u32,
};
const KeyPrefix = enum(u8) {
    user,
    trusted,
    security,
};
const KeyRaw = packed struct {
    type: packed struct {
        prefix: KeyPrefix,
        out_of_line: bool,
        _: u7,
    },
    name_size: u16,
};

pub const KeyValue = struct {
    key: []u8,
    value: []u8,
};

const XattrTable = @This();

alloc: std.mem.Allocator,
fil: OffsetFile,
decomp: DecompFn,

count: u32,
start: u64,

table: Table(Entry),

pub fn init(alloc: std.mem.Allocator, fil: OffsetFile, decomp: DecompFn, table_start: u64) !XattrTable {
    var info = packed struct {
        start: u64 = undefined,
        count: u32 = undefined,
        _: u32 = undefined,
    }{};
    var rdr = try fil.readerAt(table_start, &[0]u8{});
    try rdr.interface.readSliceEndian(@TypeOf(info), @ptrCast(&info), .little);
    return .{
        .alloc = alloc,
        .fil = fil,
        .decomp = decomp,
        .count = info.count,
        .start = info.start,
        .table = try .init(alloc, fil, decomp, table_start + 16, info.count),
    };
}
pub fn deinit(self: XattrTable) void {
    self.table.deinit();
}

pub fn get(self: *XattrTable, alloc: std.mem.Allocator, idx: u32) ![]KeyValue {
    const entry: Entry = try self.table.get(idx);
    const out = try alloc.alloc(KeyValue, entry.count);

    for (out) |*kv| {
        var rdr = try self.fil.readerAt(self.start + entry.ref.block_start, &[0]u8{});
        var meta: MetadataReader = .init(alloc, &rdr.interface, self.decomp);
        try meta.interface.discardAll(entry.ref.block_offset);

        var key_raw: KeyRaw = undefined;
        try meta.interface.readSliceEndian(KeyRaw, @ptrCast(&key_raw), .little);

        switch (key_raw.type.prefix) {
            .user => {
                kv.key = try alloc.alloc(u8, key_raw.name_size + 5);
                @memcpy(kv.key[0..5], "user.");
                try meta.interface.readSliceAll(kv.key[5..]);
            },
            .security => {
                kv.key = try alloc.alloc(u8, key_raw.name_size + 9);
                @memcpy(kv.key[0..9], "security.");
                try meta.interface.readSliceAll(kv.key[9..]);
            },
            .trusted => {
                kv.key = try alloc.alloc(u8, key_raw.name_size + 8);
                @memcpy(kv.key[0..8], "trusted.");
                try meta.interface.readSliceAll(kv.key[8..]);
            },
        }
        if (key_raw.type.out_of_line) {
            try meta.interface.discardAll(4);
            var ref: Ref = undefined;
            try meta.interface.readSliceEndian(Ref, @ptrCast(&ref), .little);

            rdr = try self.fil.readerAt(self.start + ref.block_start, &[0]u8{});
            meta = .init(alloc, &rdr.interface, self.decomp);
            try meta.interface.discardAll(ref.block_offset);
        }
        var value_size: u32 = undefined;
        try meta.interface.readSliceEndian(u32, @ptrCast(&value_size), .little);
        kv.value = try alloc.alloc(u8, value_size);
        try meta.interface.readSliceAll(kv.value);
    }

    return out;
}
