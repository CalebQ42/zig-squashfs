const std = @import("std");

const c = @import("../../c_libs.zig").c;
const Decompressor = @import("../../decomp.zig");

const Xz = @This();

streams: std.AutoHashMap(std.Thread.Id, c.lzma_stream),

interface: Decompressor,

err: ?Error = null,

pub fn init(alloc: std.mem.Allocator) !Xz {
    return .{
        .streams = try .init(alloc),
        .interface = &.{
            .alloc = alloc,
            .vtable = .{ .decompress = decompress, .stateless = stateless },
        },
    };
}
pub fn deinit(self: *Xz) void {
    var values = self.streams.valueIterator();
    while (values.next()) |val| {
        c.xz_end(val);
    }
    self.streams.deinit();
}

fn getOrCreate(self: *Xz) !*c.xz_stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = .{
        .alloc = .{
            .alloc = lzmaAlloc,
            .free = lzmaFree,
            .@"opaque" = &self.interface.alloc,
        },
    };
    return res.value_ptr;
}

fn decompress(decomp: *const Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Xz = @fieldParentPtr("interface", decomp);

    const stream = try self.getOrCreate();
    stream.next_in = in.ptr;
    stream.avail_in = in.len;
    stream.next_out = out.ptr;
    stream.avail_out = out.len;
    var res = c.lzma_alone_decoder(stream, out.len);
    decodeResult(res) catch |err| {
        self.err = err;
        return xzErrorToDecompError(err);
    };
    while (true) {
        res = c.lzma_code(&stream, c.LZMA_RUN);
        if (res == c.LZMA_OK) continue;
        if (res == c.LZMA_STREAM_END) break;
        decodeResult(res) catch |err| {
            self.err = err;
            return xzErrorToDecompError(err);
        };
    }
    return stream.total_out;
}
pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var stream: c.lzma_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
        .allocator = &.{
            .alloc = lzmaAlloc,
            .free = lzmaFree,
            .@"opaque" = @ptrCast(@constCast(&alloc)),
        },
    };
    var res = c.lzma_alone_decoder(&stream, out.len);
    decodeResult(res) catch |err| return xzErrorToDecompError(err);
    while (true) {
        res = c.lzma_code(&stream, c.LZMA_RUN);
        if (res == c.LZMA_OK) continue;
        if (res == c.LZMA_STREAM_END) break;
        decodeResult(res) catch |err| return xzErrorToDecompError(err);
    }
    return stream.total_out;
}

inline fn decodeResult(res: c_uint) Error!void {
    return switch (res) {
        c.LZMA_OK => {},
        c.LZMA_STREAM_END => {},
        c.LZMA_NO_CHECK => {},
        c.LZMA_UNSUPPORTED_CHECK => Error.UnsupportedCheck,
        c.LZMA_MEM_ERROR => Error.OutOfMemory,
        c.LZMA_MEMLIMIT_ERROR => Error.OutOfMemory,
        c.LZMA_FORMAT_ERROR => Error.Format,
        c.LZMA_OPTIONS_ERROR => Error.Options,
        c.LZMA_DATA_ERROR => Error.Data,
        c.LZMA_BUF_ERROR => Error.BufferExhausted,
        c.LZMA_PROG_ERROR => Error.Programming,
        c.LZMA_SEEK_NEEDED => Error.SeekNeeded,
        else => Error.Unknown,
    };
}
fn xzErrorToDecompError(err: Error) Decompressor.Error {
    switch (err) {
        Error.OutOfMemory => return Decompressor.Error.OutOfMemory,
        Error.UnsupportedCheck => return Decompressor.Error.ReadFailed,
        Error.Format => return Decompressor.Error.ReadFailed,
        Error.Options => return Decompressor.Error.ReadFailed,
        Error.Data => return Decompressor.Error.ReadFailed,
        Error.BufferExhausted => return Decompressor.Error.WriteFailed,
        Error.Programming => return Decompressor.Error.ReadFailed,
        Error.SeekNeeded => return Decompressor.Error.ReadFailed,
        Error.Unknown => return Decompressor.Error.ReadFailed,
    }
}

fn lzmaAlloc(ptr: ?*anyopaque, _: usize, size: usize) callconv(.c) ?*anyopaque {
    var alloc: *std.mem.Allocator = @alignCast(@ptrCast(ptr));
    return alloc.rawAlloc(size, .@"1", 0);
}
fn lzmaFree(ptr: ?*anyopaque, alloc_ptr: ?*anyopaque) callconv(.c) void {
    if (alloc_ptr == null) return;
    var alloc: *std.mem.Allocator = @alignCast(@ptrCast(ptr));
    alloc.rawFree(@ptrCast(alloc_ptr), .@"1", 0);
}

pub const Error = error{
    OutOfMemory,
    UnsupportedCheck,
    Format,
    Options,
    Data,
    BufferExhausted,
    Programming,
    SeekNeeded,
    Unknown,
};
