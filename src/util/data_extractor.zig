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
block_size: u32,

file_size: u64,
start: u64,
blocks: []BlockSize,

frag_offset: u32 = 0,
frag_entry: ?FragEntry = null,

err: ?anyerror = null,

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
pub fn extractAsync(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File) !void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    var err: ?anyerror = null;

    var read_offset: u64 = self.start;
    for (0..self.blocks.len) |idx| {
        group.async(io, blockThread, .{ self, alloc, io, fil, read_offset, idx, &err });
        read_offset += self.blocks[idx].size;
    }
    if (self.frag_entry != null)
        group.async(io, fragThread, .{ self, alloc, io, fil, &err });

    group.await(io) catch |cancel| return err orelse cancel;
}

fn blockThread(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File, read_offset: u64, idx: usize, ret_err: *?anyerror) Io.Cancelable!void {
    const block = self.blocks[idx];

    const cur_block_size = if (idx == self.numBlocks() - 1)
        self.file_size % self.block_size
    else
        self.block_size;

    var wrt = fil.writer(io, &[0]u8{});
    wrt.seekTo(self.block_size * idx) catch |err| {
        ret_err.* = err;
        if (err == error.Canceled) io.recancel();
        return Io.Cancelable.Canceled;
    };
    defer wrt.flush() catch {};

    if (block.size == 0) {
        wrt.interface.splatByteAll(0, cur_block_size) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        return;
    }

    var rdr = self.fil.readerAt(io, read_offset, &[0]u8{}) catch |err| {
        ret_err.* = err;
        if (err == error.Canceled) io.recancel();
        return Io.Cancelable.Canceled;
    };
    if (block.uncompressed) {
        rdr.interface.streamExact(&wrt.interface, cur_block_size) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        return;
    } else {
        @branchHint(.likely);

        var cache: [1024 * 1024]u8 = undefined;
        var tmp: [1024 * 1024]u8 = undefined;

        rdr.interface.readSliceAll(cache[0..block.size]) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        _ = self.decomp.Decompress(alloc, cache[0..block.size], tmp[0..cur_block_size]) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        wrt.interface.writeAll(tmp[0..cur_block_size]) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
    }
}
fn fragThread(self: DataExtractor, alloc: std.mem.Allocator, io: Io, fil: Io.File, ret_err: *?anyerror) Io.Cancelable!void {
    const frag = self.frag_entry.?;
    const cur_block_size = self.file_size % self.block_size;

    var wrt = fil.writer(io, &[0]u8{});
    wrt.seekTo(self.blocks.len * self.block_size) catch |err| {
        ret_err.* = err;
        if (err == error.Canceled) io.recancel();
        return Io.Cancelable.Canceled;
    };
    defer wrt.flush() catch {};

    var rdr = self.fil.readerAt(io, frag.start, &[0]u8{}) catch |err| {
        ret_err.* = err;
        if (err == error.Canceled) io.recancel();
        return Io.Cancelable.Canceled;
    };
    if (frag.size.uncompressed) {
        rdr.interface.discardAll(self.frag_offset) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        rdr.interface.streamExact(&wrt.interface, cur_block_size) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        return;
    } else {
        @branchHint(.likely);

        var cache: [1024 * 1024]u8 = undefined;
        var tmp: [1024 * 1024]u8 = undefined;

        rdr.interface.readSliceAll(cache[0..frag.size.size]) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        _ = self.decomp.Decompress(alloc, cache[0..frag.size.size], tmp[0..self.block_size]) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
        wrt.interface.writeAll(tmp[0..cur_block_size]) catch |err| {
            ret_err.* = err;
            if (err == error.Canceled) io.recancel();
            return Io.Cancelable.Canceled;
        };
    }
}
