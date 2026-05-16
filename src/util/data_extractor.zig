//! The DataExtractor is meant to extract a regular file's data to a given file asyncronously.

const std = @import("std");
const Io = std.Io;

const FragEntry = @import("../frag.zig").FragEntry;
const BlockSize = @import("../inode_data/file.zig").BlockSize;
const Decompressor = @import("decompressor.zig");
const OffsetFile = @import("offset_file.zig");

// const SharedCache = @import("shared_cache.zig");

const DataExtractor = @This();

fil: OffsetFile,
decomp: *const Decompressor,
cache: *Io.Queue([1024 * 1024]u8),
block_size: u32,

file_size: u64,
start: u64,
blocks: []BlockSize,

frag_offset: u32 = 0,
frag_entry: ?FragEntry = null,

pub fn init(fil: OffsetFile, decomp: *const Decompressor, cache: *Io.Queue([1024 * 1024]u8), block_size: u32, file_size: u64, data_start: u64, blocks: []BlockSize) DataExtractor {
    return .{
        .fil = fil,
        .decomp = decomp,
        .cache = cache,
        .block_size = block_size,

        .file_size = file_size,
        .start = data_start,
        .blocks = blocks,
    };
}
pub fn addFrag(self: *DataExtractor, frag_offset: u32, entry: FragEntry) void {
    self.frag_offset = frag_offset;
    self.frag_entry = entry;
}

fn numBlocks(self: DataExtractor) usize {
    var num = self.blocks.len;
    if (self.frag_entry != null) num += 1;
    return num;
}

/// Starts extracting the data using the given group to spawn async tasks.
pub fn extractAsync(self: DataExtractor, alloc: std.mem.Allocator, io: Io, group: *Io.Group, fil: Io.File) void {
    var read_offset: u64 = self.start;
    for (0..self.blocks.len) |idx| {
        group.async(io, blockThread, .{ self, alloc, io, fil, read_offset, idx });
        read_offset += self.blocks[idx].size;
    }
    if (self.frag_entry != null)
        group.async(io, fragThread, .{ self, alloc, io, fil });
}

fn blockThread(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File, read_offset: u64, idx: usize) !void {
    const block = self.blocks[idx];

    const cur_block_size = if (idx == self.numBlocks() - 1)
        self.file_size % self.block_size
    else
        self.block_size;

    var wrt = fil.writer(io, &[0]u8{});
    try wrt.seekTo(self.block_size * idx);
    defer wrt.flush() catch {};

    if (block.size == 0) {
        try wrt.interface.splatByteAll(0, cur_block_size);
        return;
    }

    var rdr = try self.fil.readerAt(io, read_offset, &[0]u8{});
    if (block.uncompressed) {
        try rdr.interface.streamExact(&wrt.interface, cur_block_size);
        return;
    } else {
        @branchHint(.likely);
        var cache = try self.cache.getOne(io);
        defer self.cache.putOne(io, cache) catch {};

        var tmp = try self.cache.getOne(io);
        defer self.cache.putOne(io, tmp) catch {};

        try rdr.interface.readSliceAll(cache[0..block.size]);
        _ = try self.decomp.Decompress(alloc, cache[0..block.size], tmp[0..cur_block_size]);
        try wrt.interface.writeAll(tmp[0..cur_block_size]);
    }
}
fn fragThread(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File) !void {
    const frag = self.frag_entry.?;
    const cur_block_size = self.file_size % self.block_size;

    var wrt = fil.writer(io, &[0]u8{});
    try wrt.seekTo(self.blocks.len * self.block_size);
    defer wrt.flush() catch {};

    var rdr = try self.fil.readerAt(io, frag.start, &[0]u8{});
    if (frag.size.uncompressed) {
        try rdr.interface.discardAll(self.frag_offset);
        try rdr.interface.streamExact(&wrt.interface, cur_block_size);
        return;
    } else {
        @branchHint(.likely);
        var cache = try self.cache.getOne(io);
        defer self.cache.putOne(io, cache) catch {};

        var tmp = try self.cache.getOne(io);
        defer self.cache.putOne(io, tmp) catch {};

        try rdr.interface.readSliceAll(cache[0..frag.size.size]);
        _ = try self.decomp.Decompress(alloc, cache[0..frag.size.size], tmp[0..self.block_size]);
        try wrt.interface.writeAll(tmp[0..cur_block_size]);
    }
}
