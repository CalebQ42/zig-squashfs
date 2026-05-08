//! The DataExtractor is meant to extract a regular file's data to a given file asyncronously.

const std = @import("std");
const Io = std.Io;

const FragEntry = @import("../frag.zig").FragEntry;
const BlockSize = @import("../inode_data/file.zig").BlockSize;
const Decompressor = @import("decompressor.zig");
const OffsetFile = @import("offset_file.zig");
const SharedCache = @import("shared_cache.zig");

const DataExtractor = @This();

fil: OffsetFile,
cache: *SharedCache,
decomp: *const Decompressor,
block_size: u32,

file_size: u64,
start: u64,
blocks: []BlockSize,

frag_offset: u32 = 0,
frag_entry: ?FragEntry = null,

pub fn init(fil: OffsetFile, cache: *SharedCache, decomp: *const Decompressor, block_size: u32, file_size: u64, data_start: u64, blocks: []BlockSize) DataExtractor {
    return .{
        .fil = fil,
        .cache = cache,
        .decomp = decomp,
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

pub fn extract(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = fil;
}

fn blockThread(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File, read_offset: u64, offset: u64, idx: u32) !void {
    const block = self.blocks[idx];

    const cur_block_size = if (idx == self.numBlocks() - 1)
        self.file_size % self.block_size
    else
        self.block_size;

    var wrt = fil.writer(io, &[0]u8{});
    try wrt.seekTo(offset);
    defer wrt.flush() catch {};

    if (block.size == 0) {
        try wrt.interface.splatByteAll(0, cur_block_size);
        return;
    }

    var rdr = try self.fil.readerAt(io, read_offset, &[0]u8{});
    if (block.uncompressed) {
        try rdr.interface.streamExact(&wrt, cur_block_size);
        return;
    } else {
        @branchHint(.likely);
        var cache = try self.cache.getCache(io);
        defer self.cache.returnCache(cache);

        var tmp = try self.cache.getCache(io);
        defer self.cache.returnCache(tmp);

        try rdr.interface.readSliceAll(cache.cache[0..block.size]);
        _ = try self.decomp.Decompress(alloc, cache.cache[0..block.size], tmp.cache[0..cur_block_size]);
        try wrt.interface.writeAll(tmp.cache[0..cur_block_size]);
    }
}
fn fragThread(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File, offset: u64) !void {
    const frag = self.frag_entry.?;
    const cur_block_size = self.file_size % self.block_size;

    var wrt = fil.writer(io, &[0]u8{});
    try wrt.seekTo(offset);
    defer wrt.flush() catch {};

    var rdr = try self.fil.readerAt(io, frag.start, &[0]u8{});
    if (frag.size.uncompressed) {
        try rdr.interface.discardAll(self.frag_offset);
        try rdr.interface.streamExact(&wrt, cur_block_size);
        return;
    } else {
        @branchHint(.likely);
        var cache = try self.cache.getCache(io);
        defer self.cache.returnCache(cache);

        var tmp = try self.cache.getCache(io);
        defer self.cache.returnCache(tmp);

        try rdr.interface.readSliceAll(cache.cache[0..frag.size.size]);
        _ = try self.decomp.Decompress(alloc, cache.cache[0..frag.size.size], tmp.cache[0..self.block_size]);
        try wrt.interface.writeAll(tmp.cache[0..cur_block_size]);
    }
}
