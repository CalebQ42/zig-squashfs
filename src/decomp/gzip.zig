const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const zng_stream = c.zng_stream;

const ZlibErrors = error{
    OutOfMemory,
    OutputBufferTooSmall,
    BadData,
    StreamError,
    Unknown,
};

const Self = @This();

alloc: std.mem.Allocator,
window_size: i16,

streams: std.AutoHashMap(std.Thread.Id, zng_stream),

pub fn init(alloc: std.mem.Allocator, window_size: i16) !Self {
    return .{
        .alloc = alloc,
        .window_size = window_size,
        .streams = .init(alloc),
    };
}
pub fn deinit(self: Self) void {
    var iter = self.streams.keyIterator();
    while (iter.next()) |key| {
        _ = c.inflateEnd(self.streams.getPtr(key).?);
    }
    self.streams.deinit(self.alloc);
}

pub fn decompress(self: *Self, in: []u8, out: []u8) ZlibErrors!usize {
    var stream = try self.getOrCreate();
    stream.next_in = in.ptr;
    stream.avail_in = in.len;
    stream.next_out = out.ptr;
    stream.avail_out = out.len;
    var res = c.zng_inflateReset2(stream, self.window_size);
    switch (res) {
        c.Z_OK => {},
        c.Z_STREAM_ERROR => return ZlibErrors.StreamError,
        else => return ZlibErrors.Unknown,
    }
    res = c.zng_inflate(stream, c.Z_FINISH);
    return switch (res) {
        c.Z_OK => stream.total_out,
        c.Z_MEM_ERROR => ZlibErrors.NotEnoughMemory,
        c.Z_BUF_ERROR => ZlibErrors.OutputBufferTooSmall,
        c.Z_DATA_ERROR => ZlibErrors.BadData,
        else => ZlibErrors.Unknown,
    };
}
inline fn getOrCreate(self: *Self) ZlibErrors!*zng_stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = .{
        .zalloc = zalloc,
        .zfree = zfree,
        .@"opaque" = @ptrCast(self),
    };
    return res.value_ptr;
}

fn zalloc(self_ptr: ?*anyopaque, items: c_uint, size: c_uint) ?*anyopaque {
    var self: *Self = @ptrCast(self_ptr);
    return self.alloc.rawAlloc(items * size, .@"1", 0);
}
fn zfree(self_ptr: ?*anyopaque, alloc_ptr: ?*anyopaque) ?*anyopaque {
    var self: *Self = @ptrCast(self_ptr);
    self.alloc.rawFree(@ptrCast(alloc_ptr), .@"1", 0);
}

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    var out_len: usize = out.len;
    const res = c.zng_uncompress(out.ptr, &out_len, in.ptr, in.len);
    return switch (res) {
        c.Z_OK => out_len,
        c.Z_MEM_ERROR => ZlibErrors.NotEnoughMemory,
        c.Z_BUF_ERROR => ZlibErrors.OutputBufferTooSmall,
        c.Z_DATA_ERROR => ZlibErrors.BadData,
        else => ZlibErrors.Unknown,
    };
}
