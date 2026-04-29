const std = @import("std");

const c = @import("c");
const Decompressor = @import("../../decomp.zig");

const Zlib = @This();

streams: std.AutoHashMap(std.Thread.Id, c.zng_stream),

interface: Decompressor,

err: ?Error = null,

pub fn init(alloc: std.mem.Allocator) !Zlib {
    return .{
        .streams = try .init(alloc),
        .interface = &.{
            .alloc = alloc,
            .vtable = .{ .decompress = decompress, .stateless = stateless },
        },
    };
}
pub fn deinit(self: *Zlib) void {
    var values = self.streams.valueIterator();
    while (values.next()) |val| {
        _ = c.zng_deflateEnd(val);
    }
    self.streams.deinit();
}

fn getOrCreate(self: *Zlib) !*c.zng_stream {
    const res = try self.streams.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = .{
        .@"opaque" = self,
        .zalloc = zalloc,
        .zfree = zfree,
    };
    return res.value_ptr;
}

fn decompress(decomp: *const Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Zlib = @fieldParentPtr("interface", decomp);

    var stream = try self.getOrCreate();
    stream.next_in = in.ptr;
    stream.avail_in = in.len;
    stream.next_out = out.ptr;
    stream.avail_out = out.len;
    var res = c.zng_inflateReset(stream);
    decodeError(res) catch |err| {
        self.err = err;
        return Decompressor.Error.ReadFailed;
    };
    res = c.zng_inflate(stream, c.Z_FINISH);
    decodeError(res) catch |err| {
        self.err = err;
        return switch (err) {
            Error.OutOfMemory => err,
            else => Decompressor.Error.ReadFailed,
        };
    };
}

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    _ = alloc;
    var out_len = out.len;
    const res = c.zng_uncompress(out.ptr, &out_len, in.ptr, in.len);
    return switch (res) {
        c.Z_OK => out_len,
        c.Z_MEM_ERROR => Decompressor.Error.OutOfMemory,
        c.Z_BUF_ERROR => Decompressor.Error.WriteFailed,
        else => Decompressor.Error.ReadFailed,
    };
}

inline fn decodeError(res: i32) Error!void {
    return switch (res) {
        c.Z_OK => {},
        c.Z_STREAM_ERROR => Error.Stream,
        c.Z_BUF_ERROR => Error.Buffer,
        c.Z_MEM_ERROR => Error.OutOfMemory,
        c.Z_DATA_ERROR => Error.Data,
        c.Z_VERSION_ERROR => Error.Version,
        else => Error.Unknown,
    };
}

fn zalloc(ptr: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    var self: *Zlib = @ptrCast(ptr);
    return self.interface.alloc.rawAlloc(items * size, .@"1", 0);
}

fn zfree(ptr: ?*anyopaque, addr: ?*anyopaque) callconv(.c) void {
    var self: *Zlib = @ptrCast(ptr);
    self.interface.alloc.rawFree(@ptrCast(addr), .@"1", 0);
}

pub const Error = error{
    OutOfMemory,
    Stream,
    Buffer,
    Data,
    Version,
    Unknown,
};
