const std = @import("std");
const Io = std.Io;

const BlockSize = @import("../inode_data/file.zig").BlockSize;
const Decompress = @import("decompress.zig");

const DataExtract = @This();

decomp: Decompress.Fn,
map: Io.File.MemoryMap,

block_size: u32,
block_start: u64,
size: u64,
blocks: []BlockSize,

frag_data: ?[]u8 = null,
frag_offset: u32 = undefined,

pub fn init(decomp: Decompress.Fn, map: Io.File.MemoryMap, block_size: u32, block_start: u64, size: u64, blocks: []BlockSize) DataExtract {
    return .{
        .decomp = decomp,
        .map = map,

        .block_size = block_size,
        .block_start = block_start,
        .size = size,
        .blocks = blocks,
    };
}
pub fn addFrag(self: *DataExtract, frag_block: []u8, frag_offset: u32) void {
    self.frag_data = frag_block;
    self.frag_offset = frag_offset;
}

pub const Error = error{} || Io.File.MemoryMap.CreateError || Io.File.WritePositionalError || Decompress.Error;

pub fn asyncExtract(self: DataExtract, alloc: std.mem.Allocator, io: Io, fil: Io.File) Error!void {
    var err: ?Error = null;

    var map = try fil.createMemoryMap(io, .{ .len = self.size, .protection = .{ .write = true }, .undefined_contents = true });
    defer map.destroy(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    var offset: u64 = self.block_start;
    for (0..self.blocks.len) |i| {
        group.async(io, blockThread, .{ self, alloc, map, offset, i, &err });
        offset += self.blocks[i].size;
    }
    if (self.frag_data != null)
        group.async(io, fragThread, .{ self, map });

    try group.await(io);
    if (err != null) return err.?;
    return map.write(io);
}
fn blockThread(self: DataExtract, alloc: std.mem.Allocator, map: Io.File.MemoryMap, read_offset: u64, idx: usize, ret_err: *?Error) error{Canceled}!void {
    const block = self.blocks[idx];
    const write_offset = idx * self.block_size;

    const size = if (self.frag_data == null and idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;

    if (block.size == 0) {
        @memset(map.memory[write_offset..][0..size], 0);
        return;
    } else if (block.uncompressed) {
        @memcpy(self.map.memory[read_offset..][0..size], map.memory[write_offset..][0..size]);
    }
    var tmp: [1024 * 1024]u8 = undefined;
    _ = self.decomp(alloc, self.map.memory[read_offset..][0..block.size], tmp[0..size]) catch |err| {
        ret_err.* = err;
        return error.Canceled;
    };
    @memcpy(map.memory[write_offset..][0..size], tmp[0..size]);
}
fn fragThread(self: DataExtract, map: Io.File.MemoryMap) error{Canceled}!void {
    const size = self.size % self.block_size;
    @memcpy(map.memory[self.blocks.len * self.block_size ..][0..size], self.frag_data.?[self.frag_offset..][0..size]);
}
