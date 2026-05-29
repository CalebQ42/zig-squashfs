const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;

const Inode = @import("inode.zig");

const Directory = @This();

entries: []Entry,

pub fn init(alloc: std.mem.Allocator, rdr: *Reader, size: u32) !Directory {
    if (size <= 3) return .{ .entries = &[0]Entry{} };

    var entries: std.ArrayList(Entry) = try .initCapacity(alloc, 50);
    errdefer {
        for (entries.items) |ent|
            ent.deinit(alloc);
        entries.deinit(alloc);
    }

    var read: u32 = 3;
    while (read < size) {
        var hdr: Header = undefined;
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        read += @sizeOf(Header);

        try entries.ensureUnusedCapacity(alloc, hdr.count + 1);
        for (0..hdr.count + 1) |_| {
            var raw: RawEntry = undefined;
            try rdr.readSliceEndian(RawEntry, @ptrCast(&raw), .little);

            const name = try alloc.alloc(u8, raw.name_size + 1);
            errdefer alloc.free(name);
            try rdr.readSliceEndian(u8, name, .little);

            entries.appendAssumeCapacity(.{
                .inode_num = if (raw.inode_num_offset > 0)
                    hdr.inode_num + @abs(raw.inode_num_offset)
                else
                    hdr.inode_num - @abs(raw.inode_num_offset),
                .block_start = hdr.block_start,
                .block_offset = raw.block_offset,
                .type = raw.type,
                .name = name,
            });
        }
    }

    return .{ .entries = try entries.toOwnedSlice(alloc) };
}
pub fn deinit(self: Directory, alloc: std.mem.Allocator) void {
    for (self.entries) |entry|
        entry.deinit(alloc);
    alloc.free(self.entries);
}

// Types

pub const Entry = struct {
    inode_num: u32,
    block_start: u32,
    block_offset: u16,
    type: Inode.Enum,
    name: []const u8,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

const Header = extern struct {
    count: u32,
    block_start: u32,
    inode_num: u32,
};
const RawEntry = extern struct {
    block_offset: u16,
    inode_num_offset: i16,
    type: Inode.Enum,
    name_size: u16,
};
