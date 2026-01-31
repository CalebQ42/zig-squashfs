//! Directory entry from the directory table.

const std = @import("std");
const Reader = std.Io.Reader;

const InodeType = @import("inode.zig").InodeType;

const Entry = @This();

const Header = extern struct { // use extern due to bad alignment with packed.
    count: u32,
    block_start: u32,
    num: u32,
};

const RawEntry = packed struct {
    offset: u16,
    inode_offset: i16,
    inode_type: InodeType,
    name_size: u16,
};

block_start: u32,
block_offset: u16,
num: u32,
inode_type: InodeType,
name: []const u8,

pub fn readDir(alloc: std.mem.Allocator, rdr: *Reader, size: u32) ![]Entry {
    var cur_red: u32 = 3; // start at 3 due to "." & ".." being counted in the dir size.
    var hdr: Header = undefined;
    var raw: RawEntry = undefined;
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |i|
            i.deinit(alloc);
        out.deinit(alloc);
    }
    while (cur_red < size) {
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        cur_red += @sizeOf(Header);
        try out.ensureUnusedCapacity(alloc, hdr.num + 1);
        for (0..hdr.count + 1) |_| {
            try rdr.readSliceEndian(RawEntry, @ptrCast(&raw), .little);
            const name = try alloc.alloc(u8, raw.name_size + 1);
            try rdr.readSliceEndian(u8, name, .little);
            const val = out.addOneAssumeCapacity();
            val.* = .{
                .block_start = hdr.block_start,
                .block_offset = raw.offset,
                .num = @abs(hdr.num + raw.offset),
                .inode_type = raw.inode_type,
                .name = name,
            };
            cur_red += @sizeOf(RawEntry) + raw.name_size + 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
    alloc.free(self.name);
}
