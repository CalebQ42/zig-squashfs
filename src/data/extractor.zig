const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
const Finish = @import("../extract-multi.zig").Finish;
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

pub fn extractAsync(self: Extractor, alloc: std.mem.Allocator, io: Io, file: Io.File, group: *Io.Group, err: *?Error, finish: *Finish) Error!void {
    if (self.size == 0) return;

    var read_offset: u64 = self.start;
    for (0.., self.blocks) |i, block| {
        group.async(io, blockThread, .{ self, alloc, io, file, read_offset, @truncate(i), err, finish });
        read_offset += block.size;
    }
    if (self.frag_data != null)
        group.async(io, fragThread, .{ self, io, file, err, finish });
}

fn blockThread(
    self: Extractor,
    alloc: std.mem.Allocator,
    io: Io,
    file: Io.File,
    read_offset: u64,
    block_idx: u32,
    err: *?Error,
    finish: *Finish,
) error{Canceled}!void {
    const size = if (self.frag_data == null and block_idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;

    const block = self.blocks[block_idx];

    var wrt = file.writer(io, &[0]u8{});
    wrt.seekTo(block_idx * self.block_size) catch |inner_err| {
        err.* = inner_err;
        return;
    };

    if (block.size == 0) {
        wrt.interface.splatByteAll(0, size) catch |inner_err| {
            err.* = inner_err;
            return;
        };
        finish.finish(io) catch |inner_err| {
            err.* = inner_err;
        };
        return;
    }

    const data = self.data[read_offset..][0..block.size];

    if (block.uncompressed) {
        wrt.interface.writeAll(data) catch |inner_err| {
            err.* = inner_err;
            return;
        };
        finish.finish(io) catch |inner_err| {
            err.* = inner_err;
        };
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
        wrt.interface.writeAll(decomp_block) catch |inner_err| {
            err.* = inner_err;
        };
    } else {
        const tmp = alloc.alloc(u8, size) catch |inner_err| {
            err.* = inner_err;
            return;
        };
        defer alloc.free(tmp);

        _ = self.decomp(alloc, data, tmp) catch |inner_err| {
            err.* = inner_err;
            return;
        };
        wrt.interface.writeAll(tmp) catch |inner_err| {
            err.* = inner_err;
        };
    }
    finish.finish(io) catch |inner_err| {
        err.* = inner_err;
    };
}
fn fragThread(
    self: Extractor,
    io: Io,
    file: Io.File,
    err: *?Error,
    finish: *Finish,
) error{Canceled}!void {
    const size = self.size % self.block_size;

    var wrt = file.writer(io, &[0]u8{});
    wrt.seekTo(self.blocks.len * self.block_size) catch |inner_err| {
        err.* = inner_err;
        return;
    };

    wrt.interface.writeAll(self.frag_data.?[self.frag_offset..][0..size]) catch |inner_err| {
        err.* = inner_err;
        return;
    };
    finish.finish(io) catch |inner_err| {
        err.* = inner_err;
    };
}

// Types

pub const Error = Io.File.WritePositionalError || Io.File.MemoryMap.CreateError || Decomp.Error || Cache.Error || Io.File.SeekError || Io.Writer.Error;
