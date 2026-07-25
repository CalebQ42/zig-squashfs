const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
const FileFinish = @import("../extract-multi.zig").FileFinish;
const Multi = @import("../extract-multi.zig");
const DataBlock = @import("../inode.zig").DataBlock;
const Cache = @import("../util/cache.zig");

const Extractor = @This();

data: []u8,
decomp: Decomp.Fn,
block_size: u32,

blocks: []DataBlock,

start: u64,
size: u64,

frag_data: ?[]u8 = null,
frag_offset: u32 = 0,

cache: ?*Cache = null,

pub fn init(data: []u8, decomp: Decomp.Fn, block_size: u32, blocks: []DataBlock, start: u64, size: u64) Extractor {
    return .{
        .data = data,
        .decomp = decomp,
        .block_size = block_size,

        .blocks = blocks,

        .start = start,
        .size = size,
    };
}
pub fn addFrag(self: *Extractor, frag_data: []u8, frag_offset: u32) void {
    self.frag_data = frag_data;
    self.frag_offset = frag_offset;
}
pub fn addCache(self: *Extractor, cache: *Cache) void {
    self.cache = cache;
}

pub fn extractAsync(self: Extractor, alloc: std.mem.Allocator, io: Io, select: *Io.Select(Multi.SelectUnion), finish: *FileFinish) !void {
    if (self.size == 0) return;

    var read_offset: u64 = self.start;
    for (0.., self.blocks) |i, block| {
        try select.concurrent(.reg, blockThread, .{ self, alloc, io, finish.file.file, read_offset, @truncate(i), finish });
        read_offset += block.size;
    }
    if (self.frag_data != null)
        try select.concurrent(.reg, fragThread, .{ self, io, finish.file.file, finish });
}

fn blockThread(
    self: Extractor,
    alloc: std.mem.Allocator,
    io: Io,
    file: Io.File,
    read_offset: u64,
    block_idx: u32,
    finish: *FileFinish,
) Multi.Error!void {
    const size = if (self.frag_data == null and block_idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;

    const block = self.blocks[block_idx];

    var wrt = file.writer(io, &[0]u8{});
    try wrt.seekTo(block_idx * self.block_size);

    if (block.size == 0) {
        try wrt.interface.splatByteAll(0, size);
        try finish.finish(io);
        return;
    }

    const data = self.data[read_offset..][0..block.size];

    if (block.uncompressed) {
        try wrt.interface.writeAll(data);
        try finish.finish(io);
        return;
    }

    if (self.cache != null) {
        const decomp_block = try self.cache.?.get(io, read_offset, block.size);
        try wrt.interface.writeAll(decomp_block);
    } else {
        const tmp = try alloc.alloc(u8, size);
        defer alloc.free(tmp);

        _ = try self.decomp(alloc, data, tmp);
        try wrt.interface.writeAll(tmp);
    }
    try finish.finish(io);
}
fn fragThread(
    self: Extractor,
    io: Io,
    file: Io.File,
    finish: *FileFinish,
) Multi.Error!void {
    const size = self.size % self.block_size;

    var wrt = file.writer(io, &[0]u8{});
    try wrt.seekTo(self.blocks.len * self.block_size);

    try wrt.interface.writeAll(self.frag_data.?[self.frag_offset..][0..size]);
    try finish.finish(io);
}
