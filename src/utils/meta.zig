const std = @import("std");
const Io = std.Io;

const util = @import("util.zig");

const Decomp = @import("../decomp.zig");

const MetadataReader = @This();

alloc: std.mem.Allocator,

data: []u8,
decomp: Decomp.Fn,

decomp_block: [8192]u8 = undefined,

interface: Io.Reader = .{
    .buffer = &[0]u8,
    .end = 0,
    .seek = 0,
    .vtable = &.{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    },
},

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn) MetadataReader {
    return .{
        .alloc = alloc,

        .data = data,
        .decomp = decomp,
    };
}

fn advance(self: *MetadataReader) Io.Reader.Error!void {
    self.interface.seek = 0;
    errdefer self.interface.end = 0;

    const hdr = util.readValue(Header, self.data[0..2]);

    const block = self.data[2..][0..hdr.size];

    self.data = self.data[hdr.size + 2 ..];

    if (hdr.uncompressed) {
        self.interface.end = hdr.size;
        self.interface.buffer = block;
        return;
    }

    self.interface.end = self.decomp(self.alloc, block, &self.decomp_block) catch return error.ReadFailed;
    self.interface.buffer = self.decomp_block[0..self.interface.end];
}

fn stream(rdr: *Io.Reader, wrt: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    if (rdr.seek >= rdr.end) {
        var meta: *MetadataReader = @fieldParentPtr("interface", rdr);
        try meta.advance();
    }
    if (limit == .nothing) return 0;

    const size = @min(@intFromEnum(limit), rdr.end - rdr.seek);

    const wrote = try wrt.write(rdr.buffer[rdr.seek..][0..size]);
    rdr.seek += wrote;

    return wrote;
}
fn discard(rdr: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
    if (rdr.seek >= rdr.end) {
        var meta: *MetadataReader = @fieldParentPtr("interface", rdr);
        try meta.advance();
    }
    if (limit == .nothing) return 0;

    const size = @min(@intFromEnum(limit), rdr.end - rdr.seek);
    rdr.seek += size;

    return size;
}
fn readVec(rdr: *Io.Reader, vec: [][]u8) Io.Reader.Error!usize {
    if (rdr.seek >= rdr.end) {
        var meta: *MetadataReader = @fieldParentPtr("interface", rdr);
        try meta.advance();
    }

    var wrote: usize = 0;
    for (vec) |s| {
        const size = @min(rdr.end - rdr.seek, s.len);

        @memcpy(s[0..size], rdr.buffer[rdr.seek..][0..size]);

        wrote += size;
        rdr.seek += size;

        if (rdr.seek >= rdr.end) break;
    }

    return wrote;
}

// Types

const Header = packed struct(u16) {
    size: u15,
    uncompressed: bool,
};
