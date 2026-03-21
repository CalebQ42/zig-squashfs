const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const stream = c.lzma_stream;

const Self = @This();

alloc: std.mem.Allocator,
streams: std.AutoHashMap(std.Thread.Id, stream),

xz: bool,

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

pub fn decompress(self: *Self, in: []u8, out: []u8) LzmaError!usize {
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
        c.LZMA_MEM_ERROR => return LzmaError.LzmaMemoryError,
        c.LZMA_PROG_ERROR => return LzmaError.LzmaProgramError,
        else => return LzmaError.UnknownResult,
    }
    while (res == c.LZMA_OK)
        res = c.lzma_code(strm, c.LZMA_RUN);
    return switch (res) {
        c.LZMA_STREAM_END => strm.total_out,
        c.LZMA_MEM_ERROR => LzmaError.LzmaMemoryError,
        c.LZMA_MEMLIMIT_ERROR => LzmaError.LzmaMemoryLimit,
        c.LZMA_FORMAT_ERROR => LzmaError.LzmaBadFormat,
        c.LZMA_DATA_ERROR => LzmaError.LzmaDataCorrupt,
        c.LZMA_BUF_ERROR => LzmaError.LzmaCannotProgress,
        c.LZMA_PROG_ERROR => LzmaError.LzmaProgramError,
        else => LzmaError.UnknownResult,
    };
}

inline fn getOrCreate(self: *Self) LzmaError!*stream {
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
