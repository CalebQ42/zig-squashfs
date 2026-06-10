const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Limit = Io.Limit;

const Decomp = @import("decomp.zig");

const MetadataReader = @This();

alloc: std.mem.Allocator,

data: []u8,
decomp: Decomp.Fn,

cur_offset: u64,

block: [8192]u8 = undefined,

interface: Reader = .{
    .buffer = &[0]u8{},
    .end = 0,
    .seek = 0,
    .vtable = &.{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    },
},

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, offset: u64) MetadataReader {
    return .{
        .alloc = alloc,

        .data = data,
        .decomp = decomp,

        .cur_offset = offset,
    };
}

fn advance(self: *MetadataReader) Reader.Error!void {
    self.interface.seek = 0;
    errdefer self.interface.end = 0;

    const hdr: Header = @intCast(std.mem.readInt(u16, self.data[self.cur_offset..][0..2], .little));
    defer self.cur_offset += hdr.size;

    const block = self.data[self.cur_offset + 2 ..][0..hdr.size];

    if (hdr.uncompressed) {
        self.interface.end = hdr.size;
        self.interface.buffer = block;
        return;
    }
    const decomp_size = self.decomp(self.alloc, block, &self.block) catch return Reader.Error.ReadFailed;
    self.interface.buffer = self.block[0..decomp_size];
    self.interface.end = decomp_size;
}

fn stream(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
    if (r.seek >= r.end) {
        const self: *MetadataReader = @fieldParentPtr("interface", r);
        try self.advance();
    }
    if (limit == .nothing) return 0;

    const to_write = @min(@intFromEnum(limit), r.end - r.seek);

    const wrote = try w.write(r.buffer[r.seek..][0..to_write]);
    r.seek += wrote;

    return wrote;
}
fn discard(r: *Reader, limit: Limit) Reader.Error!usize {
    if (r.seek >= r.end) {
        const self: *MetadataReader = @fieldParentPtr("interface", r);
        try self.advance();
    }
    if (limit == .nothing) return 0;

    const to_discard = @min(@intFromEnum(limit), r.end - r.seek);
    r.seek += to_discard;

    return to_discard;
}
fn readVec(r: *Reader, vec: [][]u8) Reader.Error!usize {
    if (r.seek >= r.end) {
        const self: *MetadataReader = @fieldParentPtr("interface", r);
        try self.advance();
    }

    var wrote: usize = 0;
    for (vec) |v| {
        const to_cpy = @min(v.len, r.end - r.seek);

        @memcpy(v[0..to_cpy], r.buffer[r.seek..][0..to_cpy]);

        wrote += to_cpy;

        if (r.seek >= r.end) break;
    }

    return wrote;
}

// Types

const Header = packed struct(u16) {
    size: u15,
    uncompressed: bool,
};
