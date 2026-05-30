const std = @import("std");
const Io = std.Io;

const DecompCache = @import("../decomp_cache.zig");
const DataBlock = @import("../inode.zig").DataBlock;

const Reader = @This();

io: Io,

cache: *DecompCache,
block_size: u32,

size: u64,
blocks: []DataBlock,

frag_data: ?[]u8 = null,
frag_offset: u32 = 0,

cur_offset: u64 = 0,
next_offset: u64,

idx: u32 = 0,
cur_block_sparse: bool = false,

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

pub fn init(io: Io, cache: *DecompCache, block_size: u32, size: u64, start: u64, blocks: []DataBlock) Reader {
    return .{
        .io = io,

        .cache = cache,
        .block_size = block_size,

        .size = size,
        .blocks = blocks,

        .next_offset = start,
    };
}
pub fn deinit(self: Reader) void {
    self.cache.finished(self.io);
}

pub fn addFragment(self: *Reader, data: []u8, offset: u32) void {
    self.frag_data = data;
    self.frag_offset = offset;
}

fn advance(self: *Reader) Io.Reader.Error!void {
    errdefer self.interface.end = 0;
    self.interface.seek = 0;

    if (self.idx > self.blocks.len) return error.EndOfStream;
    defer self.idx += 1;
    self.cache.finished(self.io, self.cur_offset);

    if (self.idx == self.blocks.len) {
        if (self.frag_data == null) return error.EndOfStream;
        self.cur_offset = 0;

        const size = self.size % self.block_size;
        self.interface.buffer = self.frag_data.?[self.frag_offset..][0..size];
        self.interface.end = size;
        return;
    }

    const block = self.blocks[self.idx];

    const size = if (self.idx == self.blocks.len - 1 and self.frag_data == null)
        self.size % self.block_size
    else
        self.block_size;

    if (block.size == 0) {
        self.interface.buffer = &[0]u8{};
        self.cur_block_sparse = true;
        self.interface.end = size;
        return;
    } else {
        self.cur_block_sparse = false;
    }

    self.cur_offset = self.next_offset;
    self.next_offset = self.cur_offset + block.size;

    if (block.uncompressed) {
        self.interface.buffer = self.cache.map.memory[self.cur_offset..][0..size];
        self.interface.end = size;
        return;
    }
    const data = self.cache.get(self.io, self.cur_offset, block.size, size);
    if (data.len != size) {
        std.debug.print("Size of decompression at {} is {} and should be {}\n", .{ self.cur_offset, data.len, size });
        return Io.Reader.Error.ReadFailed;
    }
    self.interface.buffer = data;
    self.interface.end = size;
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const self: *Reader = @fieldParentPtr("interface", r);
    if (r.seek >= r.end) {
        try self.advance();
    }
    const to_write = @min(@intFromEnum(limit), r.end - r.seek);
    const wrote = try if (self.cur_block_sparse)
        w.splatByte(0, to_write)
    else
        w.write(r.buffer[r.seek..][0..to_write]);
    r.seek += wrote;
    return wrote;
}
fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
    if (r.seek >= r.end) {
        const self: *Reader = @fieldParentPtr("interface", r);
        try self.advance();
    }
    const to_discard = @min(@intFromEnum(limit), r.end - r.seek);
    r.seek += to_discard;
    return to_discard;
}
fn readVec(r: *Io.Reader, vec: [][]u8) Io.Reader.Error!usize {
    const self: *Reader = @fieldParentPtr("interface", r);
    if (r.seek >= r.end) {
        try self.advance();
    }
    var total: usize = 0;
    for (vec) |v| {
        const to_copy = @min(v.len, r.end - r.seek);
        if (self.cur_block_sparse) {
            @memset(v[0..to_copy], 0);
        } else {
            @memcpy(v[0..to_copy], r.buffer[r.seek..][0..to_copy]);
        }
        total += to_copy;
        r.seek += to_copy;

        if (r.seek >= r.end) break;
    }
    return total;
}
