const std = @import("std");
const Io = std.Io;

const utils = @import("utils/util.zig");
const Inode = @import("inode.zig");

const DirIter = @This();

alloc: std.mem.Allocator,
rdr: *Io.Reader,
name_buf: []u8,

to_read: u32,
hdr: Header = .{},
hdr_idx: u32 = std.math.maxInt(u32),

pub fn init(alloc: std.mem.Allocator, rdr: *Io.Reader, name_buf: []u8, size: u32) DirIter {
    return .{
        .alloc = alloc,
        .rdr = rdr,
        .name_buf = name_buf,
        .to_read = size,
    };
}

/// Reads the next directory entry. If possible, Entry.name will be a reference to DirIter.name_buf if the name fits (Entry.name_size + 1).
/// Otherwise, it will be allocated and must be freed. Entry does not contain all needed info, you need DirIter.hdr as well.
pub fn next(self: *DirIter) !?Entry {
    if (self.to_read <= 3) return null;

    if (self.hdr_idx >= self.hdr.count + 1) {
        self.hdr = try utils.readValueRdr(Header, self.rdr);
        self.to_read -= @sizeOf(Header);
        self.hdr_idx = 0;
    }

    const raw = try utils.readValueRdr(RawEntry, self.rdr);

    const name = if (raw.name_size + 1 > self.name_buf.len)
        try self.alloc.alloc(u8, raw.name_size + 1)
    else
        self.name_buf[0 .. raw.name_size + 1];
    errdefer if (raw.name_size + 1 > self.name_buf.len)
        self.alloc.free(name);

    try self.rdr.readSliceAll(name);

    self.to_read -= @sizeOf(RawEntry) + raw.name_size + 1;
    self.hdr_idx += 1;

    return .{
        .offset = raw.offset,
        .inode_num_offset = raw.inode_num_offset,
        .type = raw.type,
        .name = name,
    };
}

// Types

const Header = extern struct {
    count: u32 = 0,
    start: u32 = 0,
    inode_num: u32 = 0,
};
const RawEntry = extern struct {
    offset: u16,
    inode_num_offset: i16,
    type: Inode.Type,
    name_size: u16,
};
const Entry = struct {
    offset: u16,
    inode_num_offset: i16,
    type: Inode.Type,

    name: []u8 = &.{},
};
