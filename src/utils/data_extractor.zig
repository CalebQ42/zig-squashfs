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

pub fn extract(self: DataReader, alloc: std.mem.Allocator, io: Io, out: Io.File) !void {
    var group: Io.Group = .init;
    var err: ?Error = null;

    var offset: u64 = 0;
    for (0..self.blocks.len) |i| {
        group.async(io, groupFn, .{ self, alloc, io, i, offset, out, &err });
        offset += self.blocks[i].size;
    }
    if (self.frag != null)
        group.async(io, groupFn, .{ self, alloc, io, self.blocks.len, 0, out, &err });

    try group.await(io);

    if (err != null)
        return err.?;
}

fn groupFn(self: DataReader, alloc: std.mem.Allocator, io: Io, idx: usize, offset: u64, out: Io.File, res_err: *?Error) Io.Cancelable!void {
    if (res_err.* != null) return;
    self.threadFn(alloc, io, idx, offset, out) catch |err| {
        res_err.* = err;
    };
}

fn threadFn(self: DataReader, alloc: std.mem.Allocator, io: Io, idx: usize, offset: u64, out: Io.File) Error!void {
    var buf: [512]u8 = undefined;
    var wrt = out.writer(io, &buf);
    try wrt.seekToUnbuffered(offset);

    if (self.frag != null and idx == self.blocks.len) {
        try wrt.interface.writeAll(self.frag.?);
        try wrt.flush();
        return;
    }

    const size = if (self.frag == null and idx == self.blocks.len - 1)
        self.size % self.block_size
    else
        self.block_size;
    const block = self.blocks[idx];

    if (block.size == 0) {
        try wrt.interface.splatByteAll(0, size);
        try wrt.flush();
        return;
    }

    const data = self.data[offset..][0..block.size];

    if (block.uncompressed) {
        try wrt.interface.writeAll(data);
        try wrt.flush();
        return;
    }

    const data_buf = try alloc.alloc(u8, size);
    defer alloc.free(data_buf);

    _ = try self.decomp(alloc, data, data_buf);
    try wrt.interface.writeAll(data_buf);
    try wrt.flush();
    return;
}

// Types

const Error = Io.File.SeekError || Io.Writer.Error || Io.File.Writer.Error || std.mem.Allocator.Error || Decomp.Error;
