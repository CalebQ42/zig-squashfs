const std = @import("std");
const Reader = std.Io.Reader;

const InodeType = @import("inode.zig").Type;

pub fn readDirectory(alloc: std.mem.Allocator, rdr: *Reader, size: u32) []Entry {
    var read: u32 = 3;
    var hdr: Header = undefined;
    var raw: RawEntry = undefined;
    var out: std.ArrayList(Entry) = .initCapacity(alloc, 50);
    errdefer {
        for (out.items) |i|
            alloc.free(i.name);
        out.deinit(alloc);
    }
    while (read < size) {
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        try out.ensureUnusedCapacity(alloc, hdr.count + 1);
        read += @sizeOf(Header);
        for (0..hdr.count + 1) |_| {
            try rdr.readSliceEndian(RawEntry, @ptrCast(&raw), .little);
            read += @sizeOf(RawEntry) + raw.name_size + 1;
            const new = out.addOneAssumeCapacity();
            new.* = .{
                .block_start = hdr.block_start,
                .block_offset = raw.block_offset,
                .num = @abs(hdr.num + raw.num_offset),
                .inode_type = raw.inode_type,
                .name = try alloc.alloc(u8, raw.name_size + 1),
            };
            try rdr.readSliceEndian(u8, new.name, .little);
        }
    }
    return out.toOwnedSlice(alloc);
}

// Types

pub const Entry = struct {
    block_start: u32,
    block_offset: u16,
    num: u32,
    inode_type: InodeType,
    name: []u8,
};

// extern instead of packed due to alignment issues (packed will read it as 16 bytes instead of 12).
const Header = extern struct {
    count: u32,
    block_start: u32,
    num: u32,
};

const RawEntry = packed struct {
    block_offset: u16,
    num_offset: i16,
    inode_type: InodeType,
    name_size: u16,
};
