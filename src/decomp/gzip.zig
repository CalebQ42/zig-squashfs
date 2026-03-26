const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");

const Decompressor = @import("../decomp.zig");
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

streams: std.AutoHashMap(std.Thread.Id, zng_stream),
interface: Decompressor = .{ .vtable = &.{
    .decompress = decompress,
    .stateless = stateless,
} },

err: ?ZlibErrors = null,

pub fn init(alloc: std.mem.Allocator) !Self {
    return .{
        .alloc = alloc,
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

fn decompress(decomp: *Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Self = @fieldParentPtr("interface", decomp);

    var stream = try self.getOrCreate();
    stream.next_in = in.ptr;
    stream.avail_in = @truncate(in.len);
    stream.next_out = out.ptr;
    stream.avail_out = @truncate(out.len);
    var res = c.zng_inflateReset(stream);
    switch (res) {
        c.Z_OK => {},
        c.Z_STREAM_ERROR => {
            self.err = ZlibErrors.StreamError;
            return Decompressor.Error.BadInput;
        },
        else => {
            self.err = ZlibErrors.Unknown;
            return Decompressor.Error.BadInput;
        },
    }
    res = c.zng_inflate(stream, c.Z_FINISH);
    switch (res) {
        c.Z_OK => return stream.total_out,
        c.Z_MEM_ERROR => {
            self.err = ZlibErrors.OutOfMemory;
            return Decompressor.Error.OutOfMemory;
        },
        c.Z_BUF_ERROR => {
            self.err = ZlibErrors.OutputBufferTooSmall;
            return Decompressor.Error.OutputTooSmall;
        },
        c.Z_DATA_ERROR => {
            self.err = ZlibErrors.BadData;
            return Decompressor.Error.BadInput;
        },
        else => {
            self.err = ZlibErrors.Unknown;
            return Decompressor.Error.BadInput;
        },
    }
}
inline fn getOrCreate(self: *Self) Decompressor.Error!*zng_stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = .{
        .zalloc = zalloc,
        .zfree = zfree,
        .@"opaque" = @ptrCast(self),
    };
    return res.value_ptr;
}

fn zalloc(self_ptr: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    var self: *Self = @ptrCast(@alignCast(self_ptr));
    return self.alloc.rawAlloc(items * size, .@"1", 0);
}
fn zfree(self_ptr: ?*anyopaque, alloc_ptr: ?*anyopaque) callconv(.c) void {
    var self: *Self = @ptrCast(@alignCast(self_ptr));
    self.alloc.rawFree(@ptrCast(alloc_ptr), .@"1", 0);
}

fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var out_len = out.len;
    const res = c.zng_uncompress(out.ptr, &out_len, in.ptr, in.len);
    return switch (res) {
        c.Z_OK => out_len,
        c.Z_MEM_ERROR => Decompressor.Error.OutOfMemory,
        c.Z_BUF_ERROR => Decompressor.Error.OutputTooSmall,
        c.Z_DATA_ERROR => Decompressor.Error.BadInput,
        else => Decompressor.Error.BadInput,
    };
}
