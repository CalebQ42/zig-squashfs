const std = @import("std");

const c = @import("../../c.zig").c;
const Decompressor = @import("../../decomp.zig");

const Self = @This();

alloc: std.mem.Allocator,
streams: std.AutoHashMap(std.Thread.Id, c.zng_stream),

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
    const self: *Self = @fieldParentPtr("interface", decomp);

    var strm = try self.getOrCreate();
    strm.next_in = in.ptr;
    strm.avail_in = @truncate(in.len);
    strm.next_out = out.ptr;
    strm.total_out = out.len;
    var res = c.zng_inflateReset(strm);
    decodeError(res) catch |err| return zlibErrToDecompErr(err);

    res = c.zng_inflate(strm, c.Z_FULL_FLUSH);
    decodeError(res) catch |err| return zlibErrToDecompErr(err);
    return strm.total_out;
}
fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var strm: c.zng_stream = .{
        .zalloc = zalloc,
        .zfree = zfree,
        .@"opaque" = @constCast(&alloc),

        .next_in = in.ptr,
        .avail_in = @truncate(in.len),
        .next_out = out.ptr,
        .total_out = out.len,
    };
    var res = c.zng_inflateInit(&strm);
    decodeError(res) catch |err| return zlibErrToDecompErr(err);

    res = c.zng_inflate(&strm, c.Z_FULL_FLUSH);
    decodeError(res) catch |err| return zlibErrToDecompErr(err);
    return strm.total_out;
}

fn getOrCreate(self: *Self) !*c.zng_stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = .{
        .zalloc = zalloc,
        .zfree = zfree,
        .@"opaque" = &self.alloc,
    };
    return res.value_ptr;
}

fn zalloc(ptr: ?*anyopaque, size: c_uint, len: c_uint) callconv(.c) ?*anyopaque {
    var alloc: *std.mem.Allocator = @ptrCast(@alignCast(@constCast(ptr)));
    return alloc.rawAlloc(size * len, .@"1", 0);
}
fn zfree(ptr: ?*anyopaque, mem_ptr: ?*anyopaque) callconv(.c) void {
    var alloc: *std.mem.Allocator = @ptrCast(@alignCast(@constCast(ptr)));
    alloc.rawFree(@ptrCast(mem_ptr), .@"1", 0);
}

inline fn decodeError(res: i32) Error!void {
    if (res >= 0) return;
    return switch (res) {
        c.Z_STREAM_ERROR => Error.Stream,
        c.Z_DATA_ERROR => Error.Data,
        c.Z_MEM_ERROR => Error.OutOfMemory,
        c.Z_BUF_ERROR => Error.Buffer,
        c.Z_VERSION_ERROR => Error.Version,
        else => Error.Misc,
    };
}
inline fn zlibErrToDecompErr(err: Error) Decompressor.Error {
    return switch (err) {
        Error.OutOfMemory => Decompressor.Error.OutOfMemory,
        Error.Misc => Decompressor.Error.ReadFailed,
        Error.Stream => Decompressor.Error.ReadFailed,
        Error.Data => Decompressor.Error.ReadFailed,
        Error.Buffer => Decompressor.Error.WriteFailed,
        Error.Version => Decompressor.Error.ReadFailed,
    };
}

const Error = error{
    OutOfMemory,
    Misc,
    Stream,
    Data,
    Buffer,
    Version,
};
