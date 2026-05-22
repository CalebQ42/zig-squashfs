//! The DataExtractor is meant to extract a regular file's data to a given file asyncronously.

const std = @import("std");
const Io = std.Io;

const FragEntry = @import("../frag.zig").FragEntry;
const BlockSize = @import("../inode_data/file.zig").BlockSize;
const Decompressor = @import("decompressor.zig");
const OffsetFile = @import("offset_file.zig");

// const SharedCache = @import("shared_cache.zig");

pub const Error = Decompressor.Error || Io.File.MemoryMap.CreateError || Io.File.WritePositionalError;

const DataExtractor = @This();

fil: OffsetFile,
decomp: *const Decompressor,
block_size: u32,

file_size: u64,
start: u64,
blocks: []BlockSize,

frag_offset: u32 = 0,
frag_block: ?[]u8 = null,

err: ?Error = null,

pub fn init(fil: OffsetFile, decomp: *const Decompressor, block_size: u32, file_size: u64, data_start: u64, blocks: []BlockSize) DataExtractor {
    return .{
        .fil = fil,
        .decomp = decomp,
        .block_size = block_size,

        .file_size = file_size,
        .start = data_start,
        .blocks = blocks,
    };
}
pub fn addFrag(self: *DataExtractor, frag_offset: u32, block: []u8) void {
    self.frag_offset = frag_offset;
    self.frag_block = block;
}

fn numBlocks(self: DataExtractor) usize {
    var num = self.blocks.len;
    if (self.frag_block != null) num += 1;
    return num;
}

/// Starts extracting the data using the given group to spawn async tasks.
pub fn extractAsync(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File) Error!void {
    var map = try fil.createMemoryMap(io, .{ .len = self.file_size, .protection = .{ .write = true } });
    defer map.destroy(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    var err: ?Error = null;

    var read_offset: u64 = self.start;
    for (0..self.blocks.len) |idx| {
        group.async(io, blockThread, .{ self, alloc, fil, read_offset, idx, &err });
        read_offset += self.blocks[idx].size;
    }
    if (self.frag_block != null)
        group.async(io, fragThread, .{ self, map });

    group.await(io) catch |cancel| return err orelse cancel;

    try map.write(io);
}

fn blockThread(self: DataExtractor, alloc: std.mem.Allocator, map: Io.File.MemoryMap, read_offset: u64, idx: usize, ret_err: *?Error) Io.Cancelable!void {
    const block = self.blocks[idx];

    const cur_block_size = if (idx == self.numBlocks() - 1)
        self.file_size % self.block_size
    else
        self.block_size;

    const write_offset = self.block_size * idx;

    if (block.size == 0) {
        @memset(map.memory[write_offset .. write_offset + cur_block_size], 0);
        return;
    }

    if (block.uncompressed) {
        @memcpy(map.memory[write_offset .. write_offset + cur_block_size], self.fil.map.memory[read_offset .. read_offset + cur_block_size]);
    } else {
        @branchHint(.likely);

        _ = self.decomp.Decompress(alloc, self.fil.map.memory[read_offset .. read_offset + block.size], map.memory[write_offset .. write_offset + cur_block_size]) catch |err| {
            ret_err.* = err;
            return Io.Cancelable.Canceled;
        };
    }
}
fn fragThread(self: DataExtractor, map: Io.File.MemoryMap) Io.Cancelable!void {
    const cur_block_size = self.file_size % self.block_size;

    const write_offset = self.blocks.len * self.block_size;

    @memcpy(map.memory[write_offset .. write_offset + cur_block_size], self.frag_block.?[self.frag_offset .. self.frag_offset + cur_block_size]);
}
