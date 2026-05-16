//! DataReader reads a regular file's data linearly from start to finish using Io.Reader interface.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Limit = Io.Limit;

const FragEntry = @import("../frag.zig").FragEntry;
const BlockSize = @import("../inode_data/file.zig").BlockSize;
const Decompressor = @import("decompressor.zig");
const OffsetFile = @import("offset_file.zig");

// const SharedCache = @import("shared_cache.zig");

const DataReader = @This();

alloc: std.mem.Allocator,

fil: OffsetFile,
io: Io,
decomp: *const Decompressor,
cache: *Io.Queue([]u8),
block_size: u32,

file_size: u64,
cur_offset: u64,
blocks: []BlockSize,

frag_offset: u32 = 0,
frag_entry: ?FragEntry = null,

block_idx: usize = 0,
sparse_block: bool = false,

interface: Io.Reader,

pub fn init(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, cache: *Io.Queue([]u8), block_size: u32, file_size: u64, data_start: u64, blocks: []BlockSize) !DataReader {
    return .{
        .alloc = alloc,

        .fil = fil,
        .io = io,
        .decomp = decomp,
        .cache = cache,
        .block_size = block_size,

        .file_size = file_size,
        .cur_offset = data_start,
        .blocks = blocks,

        .interface = .{
            .buffer = try alloc.alloc(u8, block_size),
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = stream,
                .discard = discard,
                .readVec = readVec,
            },
        },
    };
}
pub fn deinit(self: *DataReader) void {
    self.alloc.free(self.interface.buffer);
}
pub fn addFrag(self: *DataReader, frag_offset: u32, entry: FragEntry) void {
    self.frag_offset = frag_offset;
    self.frag_entry = entry;
}

fn numBlocks(self: DataReader) usize {
    var num = self.blocks.len;
    if (self.frag_entry != null) num += 1;
    return num;
}
fn advanceBuffer(self: *DataReader) !void {
    if (self.block_idx >= self.numBlocks()) {
        return Reader.Error.EndOfStream;
    }
    defer self.block_idx += 1;

    self.interface.end = if (self.block_idx == self.numBlocks() - 1)
        self.size % self.block_size
    else
        self.block_size;

    // Fragment
    if (self.block_idx == self.blocks.len) {
        const entry = self.frag_entry.?;
        if (entry.size.uncompressed) {
            var rdr = try self.fil.readerAt(self.io, entry.start + self.frag_offset, &[0]u8{});
            try rdr.interface.readSliceAll(self.interface.buffer[0..self.interface.end]);
        } else {
            @branchHint(.likely);
            const tmp = try self.cache.getOne(self.io);
            defer self.cache.putOne(tmp) catch {};

            var rdr = try self.fil.readerAt(self.io, entry.start, &[0]u8{});
            try rdr.interface.readSliceAll(tmp.cache[0..entry.size.size]);
            _ = try self.decomp.Decompress(self.alloc, tmp.cache[0..entry.size.size], self.interface.buffer[0..self.block_size]);
            @memmove(self.interface.buffer[0..self.interface.end], self.interface.buffer[self.frag_offset .. self.frag_offset + self.interface.end]);
        }
        self.interface.seek = 0;
        return;
    }

    // Normal Block
    const block = self.blocks[self.block_idx];
    if (block.size == 0) {
        self.interface.seek = 0;
        self.sparse_block = true;
        return;
    } else {
        self.sparse_block = false;
    }
    if (block.uncompressed) {
        try self.fil.readAt(self.io, self.cur_offset, self.interface.buffer[0..self.interface.end]);
        self.cur_offset += self.interface.end;
    } else {
        @branchHint(.likely);
        const tmp = try self.cache.getOne(self.io);
        defer self.cache.putOne(tmp) catch {};

        var rdr = try self.fil.readerAt(self.io, self.cur_offset, &[0]u8{});
        try rdr.interface.readSliceAll(tmp.cache[0..block.size]);
        self.cur_offset += block.size;
        _ = try self.decomp.Decompress(self.alloc, tmp.cache[0..block.size], self.interface.buffer[0..self.interface.end]);
    }
    self.interface.seek = 0;
}

fn stream(rdr: *Reader, wrt: *Writer, limit: Limit) Reader.StreamError!usize {
    var data: *DataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek == rdr.end)
        data.advanceBuffer() catch |err| return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => error.EndOfStream,
            else => error.ReadFailed,
        };

    switch (limit) {
        .nothing => return 0,
        .unlimited => {
            const wrote = if (data.sparse_block)
                try wrt.splatByte(0, rdr.end - rdr.seek)
            else
                try wrt.write(rdr.buffer[rdr.seek..rdr.end]);
            rdr.seek += wrote;
            return wrote;
        },
        else => {
            const to_read = @min(rdr.end - rdr.seek, @intFromEnum(limit));
            const wrote = if (data.sparse_block)
                try wrt.splatByte(0, to_read)
            else
                try wrt.write(rdr.buffer[rdr.seek .. rdr.seek + to_read]);
            rdr.seek += wrote;
            return wrote;
        },
    }
}
fn discard(rdr: *Reader, limit: Limit) Reader.Error!usize {
    var data: *DataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek == rdr.end)
        data.advanceBuffer() catch |err| return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => error.EndOfStream,
            else => error.ReadFailed,
        };

    switch (limit) {
        .nothing => return 0,
        .unlimited => {
            const adv = rdr.end - rdr.seek;
            rdr.seek = rdr.end;
            return adv;
        },
        else => {
            const adv = @min(rdr.end - rdr.seek, @intFromEnum(limit));
            rdr.seek += adv;
            return adv;
        },
    }
}
fn readVec(rdr: *Reader, vec: [][]u8) Reader.Error!usize {
    var data: *DataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek == rdr.end)
        data.advanceBuffer() catch |err| return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => error.EndOfStream,
            else => error.ReadFailed,
        };

    var wrote: usize = 0;
    for (vec) |buf| {
        if (rdr.seek == rdr.end) break;

        const to_copy = @min(rdr.end - rdr.seek, buf.len);
        if (data.sparse_block)
            @memset(buf[0..to_copy], 0)
        else
            @memcpy(buf[0..to_copy], rdr.buffer[rdr.seek .. rdr.seek + to_copy]);
        rdr.seek += to_copy;
        wrote += to_copy;
    }
    return wrote;
}
