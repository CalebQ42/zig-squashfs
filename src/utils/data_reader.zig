const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
const BlockSize = @import("../inode.zig").BlockSize;

const DataReader = @This();

alloc: std.mem.Allocator,

data: []u8,
decomp: Decomp.Fn,
block_size: u32,

size: u64,
blocks: []BlockSize,

frag: ?[]u8 = null,

idx: u32 = 0,
buf: []u8,

interface: Io.Reader = .{
    .buffer = &[0]u8{},
    .seek = 0,
    .end = 0,
    .vtable = &.{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    },
},

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, block_size: u32, size: u64, blocks: []BlockSize) !DataReader {
    return .{
        .alloc = alloc,

        .data = data,
        .decomp = decomp,
        .block_size = block_size,

        .size = size,
        .blocks = blocks,
        .buf = if (blocks.len > 0) try alloc.alloc(u8, 1024 * 1024) else &[0]u8{},
    };
}
pub fn deinit(self: DataReader) void {
    self.alloc.free(self.buf);
}

pub fn addFrag(self: *DataReader, frag: []u8) void {
    self.frag = frag;
}

fn advance(self: *DataReader) Io.Reader.Error!void {
    if (self.idx > self.blocks.len) return error.EndOfStream;
    defer self.idx += 1;

    self.interface.seek = 0;
    errdefer self.interface.end = 0;

    if (self.idx == self.blocks.len) {
        if (self.frag == null) return error.EndOfStream;

        self.interface.buffer = self.frag.?;
        self.interface.end = self.frag.?.len;
        return;
    }

    self.interface.end = if (self.frag == null and self.idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;

    const block = self.blocks[self.idx];

    if (block.size == 0) {
        @memset(self.buf[0..self.interface.end], 0);
        self.interface.buffer = self.buf;
        return;
    }

    if (block.uncompressed) {
        self.interface.buffer = self.data;
        self.data = self.data[self.interface.end..];
        return;
    }

    _ = self.decomp(self.alloc, self.data[0..block.size], self.buf[0..self.interface.end]) catch return error.ReadFailed;
    self.data = self.data[block.size..];

    self.interface.buffer = self.buf;
    return;
}

fn stream(rdr: *Io.Reader, wrt: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    if (rdr.seek >= rdr.end) {
        var meta: *DataReader = @fieldParentPtr("interface", rdr);
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
        var meta: *DataReader = @fieldParentPtr("interface", rdr);
        try meta.advance();
    }
    if (limit == .nothing) return 0;

    const size = @min(@intFromEnum(limit), rdr.end - rdr.seek);
    rdr.seek += size;

    return size;
}
fn readVec(rdr: *Io.Reader, vec: [][]u8) Io.Reader.Error!usize {
    if (rdr.seek >= rdr.end) {
        var meta: *DataReader = @fieldParentPtr("interface", rdr);
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
