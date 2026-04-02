const std = @import("std");

const c = @import("../../c.zig").c;
const Decompressor = @import("../../decomp.zig");

const Self = @This();

alloc: std.mem.Allocator,
streams: std.AutoHashMap(std.Thread.Id, c.lzma_stream),

interface: Decompressor,

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .alloc = alloc,
        .streams = .init(alloc),
        .interface = .{
            .vtable = &.{
                .decompress = decompress,
                .stateless = stateless,
            },
        },
    };
}
pub fn deinit(self: *Self) void {
    self.streams.deinit();
}

fn decompress(decomp: *Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Self = @fieldParentPtr("interface", decomp);

    var strm = try self.getOrCreate();
    strm.next_in = in.ptr;
    strm.avail_in = in.len;
    strm.next_out = out.ptr;
    strm.avail_out = out.len;
    var res = c.lzma_alone_decoder(strm, out.len * 2);
    decodeResult(res) catch |err| return lzmaErrToDecompErr(err);
    while (res == c.LZMA_OK)
        res = c.lzma_code(strm, c.LZMA_RUN);
    decodeResult(res) catch |err| return lzmaErrToDecompErr(err);
    return strm.total_out;
}
fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var strm: c.lzma_stream = .{
        .allocator = &.{
            .alloc = lzmaAlloc,
            .free = lzmaFree,
            .@"opaque" = @ptrCast(@constCast(&alloc)),
        },
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };
    var res = c.lzma_alone_decoder(&strm, out.len * 2);
    decodeResult(res) catch |err| return lzmaErrToDecompErr(err);
    while (res == c.LZMA_OK)
        res = c.lzma_code(&strm, c.LZMA_RUN);
    decodeResult(res) catch |err| return lzmaErrToDecompErr(err);
    return strm.total_out;
}

inline fn getOrCreate(self: *Self) !*c.lzma_stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = .{ .allocator = &.{
        .alloc = lzmaAlloc,
        .free = lzmaFree,
        .@"opaque" = @ptrCast(&self.alloc),
    } };
    return res.value_ptr;
}
inline fn decodeResult(res: usize) Error!void {
    return switch (res) {
        c.LZMA_OK, c.LZMA_STREAM_END => {},
        c.LZMA_NO_CHECK => Error.NoCheck,
        c.LZMA_UNSUPPORTED_CHECK => Error.UnsupportedCheck,
        c.LZMA_GET_CHECK => Error.GetCheck,
        c.LZMA_MEM_ERROR, c.LZMA_MEMLIMIT_ERROR => Error.OutOfMemory,
        c.LZMA_FORMAT_ERROR => Error.Format,
        c.LZMA_OPTIONS_ERROR => Error.Options,
        c.LZMA_DATA_ERROR => Error.Data,
        c.LZMA_BUF_ERROR => Error.Buffer,
        c.LZMA_PROG_ERROR => Error.Program,
        c.LZMA_SEEK_NEEDED => Error.SeekNeeded,
        else => Error.Unknown,
    };
}
inline fn lzmaErrToDecompErr(err: Error) Decompressor.Error {
    return switch (err) {
        Error.OutOfMemory => Decompressor.Error.OutOfMemory,
        Error.NoCheck => Decompressor.Error.ReadFailed,
        Error.UnsupportedCheck => Decompressor.Error.ReadFailed,
        Error.GetCheck => Decompressor.Error.ReadFailed,
        Error.Format => Decompressor.Error.ReadFailed,
        Error.Options => Decompressor.Error.ReadFailed,
        Error.Data => Decompressor.Error.ReadFailed,
        Error.Buffer => Decompressor.Error.WriteFailed,
        Error.Program => Decompressor.Error.ReadFailed,
        Error.SeekNeeded => Decompressor.Error.ReadFailed,
        else => Decompressor.Error.ReadFailed,
    };
}

fn lzmaAlloc(ptr: ?*anyopaque, size: usize, _: usize) callconv(.c) ?*anyopaque {
    var alloc: *std.mem.Allocator = @ptrCast(@alignCast(@constCast(ptr)));
    return alloc.rawAlloc(size, .@"1", 0);
}
fn lzmaFree(ptr: ?*anyopaque, mem_ptr: ?*anyopaque) callconv(.c) void {
    var alloc: *std.mem.Allocator = @ptrCast(@alignCast(@constCast(ptr)));
    alloc.rawFree(@ptrCast(mem_ptr), .@"1", 0);
}

const Error = error{
    OutOfMemory,
    NoCheck,
    UnsupportedCheck,
    GetCheck,
    Format,
    Options,
    Data,
    Buffer,
    Program,
    SeekNeeded,
    Unknown,
};
