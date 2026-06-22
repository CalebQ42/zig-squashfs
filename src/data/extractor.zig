const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
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

pub fn extractAsync(self: Extractor, alloc: std.mem.Allocator, io: Io, file: Io.File) Error!void {
    if (self.size == 0) return;

    // We write to the last byte to make sure the file has the correct size.
    try file.writePositionalAll(io, &[1]u8{0}, self.size - 1);

    var map = try file.createMemoryMap(io, .{
        .len = self.size,
        .protection = .{ .write = true },
        .populate = false,
    });
    defer map.destroy(io);

    var err: ?Error = null;
    var group: Io.Group = .init;

    var read_offset: u64 = self.start;
    for (0.., self.blocks) |i, block| {
        group.async(io, blockThread, .{ self, alloc, io, map.memory, read_offset, @truncate(i), &err });
        read_offset += block.size;
    }
    if (self.frag_data != null)
        group.async(io, fragThread, .{ self, map.memory });

    try group.await(io);

    if (err != null)
        return err.?;

    try map.write(io);
}

fn blockThread(self: Extractor, alloc: std.mem.Allocator, io: Io, map_data: []u8, read_offset: u64, block_idx: u32, err: *?Error) error{Canceled}!void {
    const size = if (self.frag_data == null and block_idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;

    const offset = block_idx * self.block_size;

    const block = self.blocks[block_idx];

    if (block.size == 0) {
        @memset(map_data[offset..][0..size], 0);
        return;
    }

    const data = self.data[read_offset..][0..block.size];

    if (block.uncompressed) {
        @memcpy(map_data[offset..][0..block.size], data);
        return;
    }

    if (self.cache != null) {
        const decomp_block = self.cache.?.get(io, read_offset, block.size) catch |inner_err| {
            switch (inner_err) {
                error.Canceled => return error.Canceled,
                else => |e| err.* = e,
            }
            return;
        };
        @memcpy(map_data[offset..][0..size], decomp_block[0..size]);
    } else {
        _ = self.decomp(alloc, data, map_data[offset..][0..size]) catch |inner_err| {
            err.* = inner_err;
        };
    }
}
fn fragThread(self: Extractor, map_data: []u8) error{Canceled}!void {
    const size = self.size % self.block_size;
    const offset = self.blocks.len * self.block_size;

    @memcpy(map_data[offset..][0..size], self.frag_data.?[self.frag_offset..][0..size]);
}

// Types

pub const Error = Io.File.WritePositionalError || Io.File.MemoryMap.CreateError || Decomp.Error || Cache.Error;
