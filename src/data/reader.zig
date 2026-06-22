const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
const DataBlock = @import("../inode.zig").DataBlock;
const Cache = @import("../util/cache.zig");

const Reader = @This();

alloc: std.mem.Allocator,

data: []u8,
decomp: Decomp.Fn,
block_size: u32,

blocks: []DataBlock,

size: u64,

offset: u64,
block_idx: u32 = 0,
sparse_block: bool = false,

frag_data: ?[]u8 = null,
frag_offset: u32 = 0,

io: ?Io = null,
cache: ?*Cache = null,

block_alloc: bool = false,

interface: Io.Reader = .{
    .buffer = &[0]u8{},
    .end = 0,
    .seek = 0,
    .vtable = &.{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    },
},

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, block_size: u32, blocks: []DataBlock, size: u64, data_start: u64) Reader {
    return .{
        .alloc = alloc,

        .data = data,
        .decomp = decomp,
        .block_size = block_size,

        .blocks = blocks,

        .size = size,

        .offset = data_start,
    };
}
pub fn deinit(self: *Reader) void {
    if (self.block_alloc)
        self.alloc.free(self.interface.buffer);
}
pub fn addFrag(self: *Reader, frag_data: []u8, frag_offset: u32) void {
    self.frag_data = frag_data;
    self.frag_offset = frag_offset;
}
pub fn addCache(self: *Reader, io: Io, cache: *Cache) void {
    self.io = io;
    self.cache = cache;
}

fn advance(self: *Reader) Io.Reader.Error!void {
    if (self.block_alloc) self.alloc.free(self.interface.buffer);

    if (self.block_idx > self.blocks.len) return error.EndOfStream;
    defer self.block_idx += 1;

    self.interface.seek = 0;
    errdefer self.interface.end = 0;

    if (self.block_idx == self.blocks.len) {
        if (self.frag_data == null) return error.EndOfStream;

        self.sparse_block = false;

        const size = self.size % self.block_size;

        self.interface.buffer = self.frag_data.?[self.frag_offset..][0..size];

        self.interface.end = size;
        return;
    }

    const size = if (self.frag_data == null and self.block_idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;

    const block = self.blocks[self.block_idx];
    defer self.offset += block.size;

    if (block.size == 0) {
        self.sparse_block = true;
        self.interface.end = size;
        return;
    } else {
        self.sparse_block = false;
    }

    if (block.uncompressed) {
        self.interface.buffer = self.data[self.offset..][0..block.size];
        self.interface.end = block.size;
        return;
    }

    if (self.cache == null) {
        self.block_alloc = true;
        self.interface.buffer = self.alloc.alloc(u8, size) catch return error.ReadFailed;
        errdefer {
            self.alloc.free(self.interface.buffer);
            self.interface.buffer = &[0]u8{};
        }

        _ = self.decomp(self.alloc, self.data[self.offset..][0..block.size], self.interface.buffer) catch return error.ReadFailed;
        self.interface.end = size;
    } else {
        self.interface.buffer = self.cache.?.get(self.io.?, self.offset, block.size) catch return error.ReadFailed;
        self.interface.end = self.interface.buffer.len;
    }
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const self: *Reader = @fieldParentPtr("interface", r);
    if (r.seek >= r.end)
        try self.advance();

    if (limit == .nothing) return 0;

    const to_write = @min(@intFromEnum(limit), r.end - r.seek);

    const wrote = if (self.sparse_block)
        try w.splatByte(0, to_write)
    else
        try w.write(r.buffer[r.seek..][0..to_write]);

    r.seek += wrote;
    return wrote;
}
fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
    if (r.seek >= r.end) {
        const self: *Reader = @fieldParentPtr("interface", r);
        try self.advance();
    }
    if (limit == .nothing) return 0;

    const to_discard = @min(@intFromEnum(limit), r.end - r.seek);

    r.seek += to_discard;
    return to_discard;
}
fn readVec(r: *Io.Reader, vec: [][]u8) Io.Reader.Error!usize {
    const self: *Reader = @fieldParentPtr("interface", r);
    if (r.seek >= r.end)
        try self.advance();

    var copied: usize = 0;
    for (vec) |v| {
        const to_cpy = @min(v.len, r.end - r.seek);

        if (self.sparse_block)
            @memset(v[0..to_cpy], 0)
        else
            @memcpy(v[0..to_cpy], r.buffer[r.seek..][0..to_cpy]);

        copied += to_cpy;

        if (r.seek >= r.end) break;
    }

    return copied;
}
