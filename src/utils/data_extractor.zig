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

pub fn init(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, block_size: u32, size: u64, blocks: []BlockSize) !DataReader {
    return .{
        .alloc = alloc,

        .data = data,
        .decomp = decomp,
        .block_size = block_size,

        .size = size,
        .blocks = blocks,
    };
}

pub fn addFrag(self: *DataReader, frag: []u8) void {
    self.frag = frag;
}

pub fn extract(self: DataReader, alloc: std.mem.Allocator, io: Io, out: Io.File) !void {}
