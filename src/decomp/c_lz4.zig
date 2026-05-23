const std = @import("std");

const c = @import("c");

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

fn statelessDecomp(_: ?*const Decompressor, _: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.LZ4_decompress_fast(in.ptr, out.ptr, @truncate(out.len));
    if (res < 0) return Error.ReadFailed;
    return @abs(res);
}

// lzma_allocator

fn lzmaAlloc(ptr: ?*anyopaque, size: usize, _: usize) callconv(.c) ?*anyopaque {
    var alloc: *std.mem.Allocator = @ptrCast(@alignCast(@constCast(ptr)));
    return alloc.rawAlloc(size, .@"1", 0);
}
fn lzmaFree(ptr: ?*anyopaque, mem_ptr: ?*anyopaque) callconv(.c) void {
    var alloc: *std.mem.Allocator = @ptrCast(@alignCast(@constCast(ptr)));
    alloc.rawFree(@ptrCast(mem_ptr), .@"1", 0);
}
