const std = @import("std");
const Reader = std.Io.Reader;

const Inode = @import("inode.zig");

const DirEntry = @This();

block_start: u32,
block_offset: u16,
type: Inode.Type,
name: []const u8,

pub fn deinit(self: DirEntry, alloc: std.mem.Allocator) void {
    alloc.free(self.name);
}

pub fn readDirectory(alloc: std.mem.Allocator, rdr: *Reader, size: u32) ![]DirEntry {
    var hdr: Header = undefined;
    var raw: RawEntry = undefined;
    var out: std.ArrayList(DirEntry) = try .initCapacity(alloc, 30);
    errdefer {
        for (out.items) |ent|
            alloc.free(ent.name);
        out.deinit(alloc);
    }

    var tot_red: u32 = 3;
    while (tot_red < size) {
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        try out.ensureUnusedCapacity(alloc, hdr.count + 1);

        tot_red += @sizeOf(Header);

        for (0..hdr.count + 1) |_| {
            try rdr.readSliceEndian(RawEntry, @ptrCast(&raw), .little);

            const new_name = try alloc.alloc(u8, raw.name_size + 1);
            try rdr.readSliceEndian(u8, new_name, .little);

            const new = out.addOneAssumeCapacity();
            new.* = .{
                .block_start = hdr.block_start,
                .block_offset = raw.block_offset,
                .type = raw.type,
                .name = new_name,
            };

            tot_red += @sizeOf(RawEntry) + raw.name_size + 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// Types

const Header = extern struct {
    count: u32,
    block_start: u32,
    num: u32,
};

const RawEntry = extern struct {
    block_offset: u16,
    num_offset: i16,
    type: Inode.Type,
    name_size: u16,
};
