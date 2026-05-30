const std = @import("std");
const Io = std.Io;

const DecompCache = @import("../decomp_cache.zig");
const DataBlock = @import("../inode.zig").DataBlock;

const Extractor = @This();

cache: *DecompCache,
block_size: u32,

start: u64,
size: u64,
blocks: []DataBlock,

frag_data: ?[]u8 = null,
frag_offset: u32 = 0,

pub fn init(cache: *DecompCache, block_size: u32, size: u64, start: u64, blocks: []DataBlock) Extractor {
    return .{
        .cache = cache,
        .block_size = block_size,

        .start = start,
        .size = size,
        .blocks = blocks,
    };
}

pub fn addFragment(self: *Extractor, data: []u8, offset: u32) void {
    self.frag_data = data;
    self.frag_offset = offset;
}

pub fn asyncExtract(self: Extractor, io: Io, fil: Io.File) Error!void {
    try fil.writePositionalAll(io, &.{&.{0}}, self.size - 1);

    var map = try fil.createMemoryMap(io, .{ .len = self.size, .protection = .{ .write = true } });
    defer map.destroy(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    var ret_err: ?Error = null;

    var offset = self.start;
    for (0..self.blocks.len) |i| {
        group.async(io, blockThread, .{ self, io, map, offset, i, &ret_err });

        offset += self.blocks[i].size;
    }
    if (self.frag_data != null)
        group.async(io, fragThread, .{ self, map });

    group.await(io) catch |err| return ret_err orelse err;

    try map.write(io);
}

fn blockThread(self: Extractor, io: Io, map: Io.File.MemoryMap, read_offset: u64, idx: usize, ret_err: *?Error) error{Canceled}!void {
    const write_pos = idx * self.block_size;
    const size = if (self.frag_data == null and idx == self.block_size.len - 1)
        self.size % self.block_size
    else
        self.block_size;
    const block = self.blocks[idx];

    if (block.size == 0) {
        @memset(map.memory[write_pos..][0..size], 0);
        return;
    }
    if (block.uncompressed) {
        @memcpy(map[write_pos..][0..size], self.cache.map.memory[read_offset..][0..size]);
        return;
    }
    const data = self.cache.get(io, read_offset, block.size, size) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            ret_err.* = e;
            return error.Canceled;
        },
    };
    defer self.cache.finished(io, read_offset);
    if (data.len != size) {
        std.debug.print("Size of decompression at {} is {} and should be {}\n", .{ read_offset, data.len, size });
        return Error.BadDecompressionSize;
    }
    @memcpy(map[write_pos..][0..size], data);
}
fn fragThread(self: Extractor, map: Io.File.MemoryMap) error{Canceled}!void {
    const write_pos = self.blocks.len * self.block_size;
    const size = self.size % self.block_size;

    @memcpy(map.memory[write_pos..][0..size], self.frag_data.?[self.frag_offset..][0..size]);
}

// Types

pub const Error = error{BadDecompressionSize} || Io.File.WritePositionalError || Io.File.MemoryMap.CreateError;
