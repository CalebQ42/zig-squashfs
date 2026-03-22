const std = @import("std");
const builtin = @import("builtin");

const Decompressor = @import("../decomp.zig");
const c = @import("c.zig").c;
const stream = c.lzma_stream;

const Self = @This();

alloc: std.mem.Allocator,
streams: std.AutoHashMap(std.Thread.Id, stream),

xz: bool,
interface: Decompressor = .{ .vtable = &.{
    .decompress = decompress,
    .stateless = stateless,
} },

err: ?LzmaError = null,

pub fn init(alloc: std.mem.Allocator, xz: bool) !Self {
    return .{
        .alloc = alloc,
        .streams = .init(alloc),
        .xz = xz,
    };
}
pub fn deinit(self: Self) void {
    var iter = self.streams.keyIterator();
    while (iter.next()) |key|
        c.lzma_end(self.streams.getPtr(key));
    self.streams.deinit();
}

pub fn decompress(decomp: *Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Self = @fieldParentPtr("interface", decomp);

    var strm = try self.getOrCreate();
    strm.next_in = in.ptr;
    strm.avail_in = in.len;
    strm.next_out = out.ptr;
    strm.avail_out = out.len;

    var res = if (self.xz)
        c.lzma_stream_decoder(strm, in.len * 2, 0)
    else
        c.lzma_alone_decoder(strm, in.len * 2);
    switch (res) {
        c.LZMA_OK => {},
        c.LZMA_MEM_ERROR => {
            self.err = LzmaError.LzmaMemoryError;
            return Decompressor.Error.OutOfMemory;
        },
        c.LZMA_PROG_ERROR => {
            self.err = LzmaError.LzmaProgramError;
            return Decompressor.Error.BadInput;
        },
        else => {
            self.err = LzmaError.Unknown;
            return Decompressor.Error.BadInput;
        },
    }
    while (res == c.LZMA_OK)
        res = c.lzma_code(strm, c.LZMA_RUN);
    switch (res) {
        c.LZMA_STREAM_END => return strm.total_out,
        c.LZMA_MEM_ERROR => {
            self.err = LzmaError.LzmaMemoryError;
            return Decompressor.Error.OutOfMemory;
        },
        c.LZMA_MEMLIMIT_ERROR => {
            self.err = LzmaError.LzmaMemoryLimit;
            return Decompressor.Error.OutOfMemory;
        },
        c.LZMA_FORMAT_ERROR => {
            self.err = LzmaError.LzmaBadFormat;
            return Decompressor.Error.BadInput;
        },
        c.LZMA_DATA_ERROR => {
            self.err = LzmaError.LzmaDataCorrupt;
            return Decompressor.Error.BadInput;
        },
        c.LZMA_BUF_ERROR => {
            self.err = LzmaError.LzmaCannotProgress;
            return Decompressor.Error.BadInput;
        },
        c.LZMA_PROG_ERROR => {
            self.err = LzmaError.LzmaProgramError;
            return Decompressor.Error.BadInput;
        },
        else => {
            self.err = LzmaError.Unknown;
            return Decompressor.Error.BadInput;
        },
    }
}
pub fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var strm = c.lzma_stream{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };

    var res = c.lzma_auto_decoder(&strm, out.len * 2, 0);
    switch (res) {
        c.LZMA_OK => {},
        c.LZMA_MEM_ERROR => return Decompressor.Error.OutOfMemory,
        c.LZMA_PROG_ERROR => return Decompressor.Error.BadInput,
        else => return Decompressor.Error.BadInput,
    }
    while (res == c.LZMA_OK)
        res = c.lzma_code(&strm, c.LZMA_RUN);
    return switch (res) {
        c.LZMA_STREAM_END => strm.total_out,
        c.LZMA_MEM_ERROR => Decompressor.Error.OutOfMemory,
        c.LZMA_MEMLIMIT_ERROR => Decompressor.Error.OutOfMemory,
        c.LZMA_FORMAT_ERROR => Decompressor.Error.BadInput,
        c.LZMA_DATA_ERROR => Decompressor.Error.BadInput,
        c.LZMA_BUF_ERROR => Decompressor.Error.BadInput,
        c.LZMA_PROG_ERROR => Decompressor.Error.BadInput,
        else => Decompressor.Error.BadInput,
    };
}

inline fn getOrCreate(self: *Self) Decompressor.Error!*stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;

    // Ideally, the zero value should be LZMA_STREAM_INIT, but translate-c can't handle it properly.
    // According to lzma, setting it to entirely zero values *should* work.
    // res.value_ptr.* = c.LZMA_STREAM_INIT;
    res.value_ptr.* = std.mem.zeroInit(stream, .{});
    return res.value_ptr;
}

pub const LzmaError = error{
    OutOfMemory,
    LzmaMemoryError,
    LzmaMemoryLimit,
    LzmaBadFormat,
    LzmaDataCorrupt,
    LzmaCannotProgress,
    LzmaProgramError,
    Unknown,
};
