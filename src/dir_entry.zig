const std = @import("std");
const Reader = std.Io.Reader;

const Inode = @import("inode.zig");

const Header = extern struct {
    count: u32,
    block_start: u32,
    num: u32,
};
const Entry = extern struct {
    block_offset: u16,
    num_offset: i16,
    inode_type: Inode.Type,
    name_size: u16,
};

const DirEntry = @This();

inode_type: Inode.Type,
name: []const u8,

block_start: u32,
block_offset: u32,
num: u32,

pub fn deinit(self: DirEntry, alloc: std.mem.Allocator) void {
    alloc.free(self.name);
}

pub fn readEntries(alloc: std.mem.Allocator, rdr: *Reader, size: u32) ![]DirEntry {
    var out: std.ArrayList(DirEntry) = try .initCapacity(alloc, 50);
    errdefer out.deinit(alloc);

    var tot_read: u32 = 3;
    while (tot_read < size) {
        var hdr: Header = undefined;
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        tot_read += @sizeOf(Header);

        try out.ensureUnusedCapacity(alloc, hdr.count + 1);

        for (0..hdr.count + 1) |_| {
            var ent: Entry = undefined;
            try rdr.readSliceEndian(Entry, @ptrCast(&ent), .little);
            tot_read += @sizeOf(Entry) + ent.name_size + 1;

            const name = try alloc.alloc(u8, ent.name_size + 1);
            errdefer alloc.free(name);

            try rdr.readSliceEndian(u8, name, .little);

            out.appendAssumeCapacity(.{
                .inode_type = ent.inode_type,
                .name = name,

                .block_offset = ent.block_offset,
                .block_start = hdr.block_start,
                .num = @intCast(@as(i64, @intCast(hdr.num)) + ent.num_offset),
            });
        }
    }

    return out.toOwnedSlice(alloc);
}
