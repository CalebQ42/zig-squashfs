const std = @import("std");
const Reader = std.Io.Reader;

const Inode = @import("inode.zig");

const Directory = @This();

entries: []Entry,

pub fn init(alloc: std.mem.Allocator, rdr: *Reader, size: u64) !Directory {
    if (size <= 3) return Directory{ .entries = &[0]Entry{} };

    var hdr: Header = undefined;
    var raw: RawEntry = undefined;

    var read: u64 = 3;

    var out: std.ArrayList(Entry) = .initCapacity(alloc, 50);
    errdefer {
        for (out.items) |entry|
            entry.deinit(alloc);
        out.deinit(alloc);
    }

    while (read < size) {
        try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
        read += @sizeOf(Header);

        try out.ensureUnusedCapacity(alloc, hdr.count + 1);

        for (0..hdr.count + 1) |_| {
            try rdr.readSliceEndian(Entry, @ptrCast(&raw), .little);

            const name = try alloc.alloc(u8, raw.name_size + 1);

            try rdr.readSliceEndian(u8, name, .little);

            const entry = out.addOneAssumeCapacity(alloc);

            entry.* = .{
                .name = name,
                .block_start = hdr.block_start,
                .block_offset = raw.block_offset,
                .type = raw.type,
            };

            read += @sizeOf(RawEntry) + raw.name_size + 1;
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

pub const Error = error{OutOfMemory} || Reader.Error;

pub const Entry = struct {
    name: []const u8,
    block_start: u32,
    block_offset: u16,
    type: Inode.type,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

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
