const std = @import("std");
const Io = std.Io;

const utils = @import("utils/util.zig");

const Inode = @import("inode.zig");

const Directory = @This();

entries: []Entry,

pub fn read(alloc: std.mem.Allocator, rdr: *Io.Reader, size: u32) !Directory {
    var red: u32 = 3;

    var out: std.ArrayList(Entry) = try .initCapacity(alloc, 10);
    errdefer out.deinit(alloc);

    while (red < size) {
        const hdr: Header = try utils.readValueRdr(Header, rdr);
        red += @sizeOf(Header);

        try out.ensureUnusedCapacity(alloc, hdr.count + 1);

        for (hdr.count + 1) |_| {
            const raw: RawEntry = try utils.readValueRdr(RawEntry, rdr);

            const name = try alloc.alloc(u8, raw.name_size + 1);
            errdefer alloc.free(name);

            try rdr.readSliceAll(name);

            out.addOneAssumeCapacity().* = .{
                .start = hdr.start,
                .offset = raw.offset,
                .type = raw.type,
                .name = name,
            };

            red += @sizeOf(RawEntry + raw.name_size + 1);
        }
    }

    return out.toOwnedSlice(alloc);
}
pub fn deinit(self: Directory, alloc: std.mem.Allocator) void {
    for (self.entries) |entry|
        entry.deinit(alloc);

    alloc.free(self.entries);
}

// Types

pub const Entry = struct {
    start: u32,
    offset: u16,
    type: Inode.Type,
    name: []const u8,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};
const Header = extern struct {
    count: u32,
    start: u32,
    inode_num: u32,
};
const RawEntry = extern struct {
    offset: u16,
    inode_num_offset: i16,
    type: Inode.Type,
    name_size: u16,
};
