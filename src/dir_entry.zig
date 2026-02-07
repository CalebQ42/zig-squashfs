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
    var out: std.ArrayList(Entry) = try .initCapacity(alloc, 25); // Start out with capacity instead of needing to allocate per header.
    errdefer out.deinit(alloc);
    while (cur_red < size) {
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        cur_red += @sizeOf(Header);
        const count = hdr.count + 1;
        if (out.capacity < count) {
            // Make sure we have at least 25 capacity past current count.
            try out.ensureUnusedCapacity(alloc, ((count % 25) + 2) * 25);
        }
        for (0..count) |_| {
            try rdr.readSliceEndian(RawEntry, @ptrCast(&raw), .little);
            const name = try alloc.alloc(u8, raw.name_size + 1);
            errdefer alloc.free(name);
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
